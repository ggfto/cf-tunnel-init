# cf-tunnel-init

Init container que provisiona um **Cloudflare Tunnel locally-managed pela API** e escreve
`config.yml` + `creds.json` num volume compartilhado. O `cloudflared` sobe depois e lê de lá.

Sem `cloudflared tunnel login`, sem `cert.pem`, sem criar tunnel no painel, sem token em
linha de comando. O único segredo durável é o `CF_API_TOKEN` — o volume é descartável e
reconstruído da API no próximo boot.

## Uso

```yaml
services:
  tunnel-init:
    image: ghcr.io/ggfto/cf-tunnel-init:latest
    environment:
      CF_API_TOKEN: ${CF_API_TOKEN:?}
      CF_ACCOUNT_ID: ${CF_ACCOUNT_ID:?}
      CF_ZONE_ID: ${CF_ZONE_ID:?}
      TUNNEL_NAME: ${TUNNEL_NAME:-meu-stack}
      CF_HOSTNAME: ${APP_HOSTNAME:?}
      CF_SERVICE: http://web:8080
    volumes:
      - cf-runtime:/etc/cloudflared
    restart: "no"

  tunnel:
    image: cloudflare/cloudflared:latest
    command: tunnel --no-autoupdate --config /etc/cloudflared/config.yml run
    volumes:
      - cf-runtime:/etc/cloudflared:ro   # só o init escreve aqui
    depends_on:
      tunnel-init:
        condition: service_completed_successfully
    restart: unless-stopped

volumes:
  cf-runtime:
```

## Variáveis

| Variável | Obrigatória | Efeito |
|----------|:---:|--------|
| `CF_API_TOKEN` | ✅ | escopos **Account → Cloudflare Tunnel: Edit** e **Zone → DNS: Edit** |
| `CF_ACCOUNT_ID` | ✅ | id da conta |
| `CF_ZONE_ID` | ✅ | id da zona dos hostnames |
| `TUNNEL_NAME` | ✅ | um tunnel por stack; precisa ser único na conta |
| `CF_HOSTNAME` + `CF_SERVICE` | ◑ | forma simples: uma regra só |
| `CF_INGRESS` | ◑ | forma completa: array JSON de regras |
| `CF_DNS_PROXIED` | | `true` (padrão) ou `false` |
| `CF_OUTPUT_DIR` | | onde escrever (padrão `/etc/cloudflared`) |

Use `CF_HOSTNAME`/`CF_SERVICE` **ou** `CF_INGRESS` — pelo menos um dos dois.

### Ingress completo

```bash
CF_INGRESS='[{"hostname":"hive.exemplo.com","path":"^/auth(/.*)?$","service":"http://keycloak:8080"},
             {"hostname":"hive.exemplo.com","service":"http://web:8080"},
             {"hostname":"agents.exemplo.com","service":"tcp://gateway:9443"}]'
```

JSON de uma linha, e não YAML, porque campos de variável de stack no Portainer são de
uma linha só.

**A ordem das regras importa:** o cloudflared usa a primeira que casar, então regras com
`path` precisam vir antes do catch-all daquele hostname. O `http_status:404` final é
acrescentado automaticamente se você não declarar uma regra sem `hostname`.

Cuidado com `path`: é regex e **não** é ancorado no fim. `^/auth` também capturaria
`/authorize` e `/authentic`. Use `^/auth(/.*)?$`.

Use `tcp://` quando o serviço precisar do TLS ponta a ponta — mTLS com certificado de
cliente, por exemplo. Um ingress `http://` termina o TLS na borda da Cloudflare e engole
o certificado.

## O que ele faz

1. Procura o tunnel por nome; cria com `config_src: local` se faltar (idempotente)
2. Busca o token e **deriva** o `creds.json` dele — o token é um JSON em base64 cujos
   campos `a`/`t`/`s` são exatamente `AccountTag`/`TunnelID`/`TunnelSecret`
3. Renderiza o `config.yml` a partir do ambiente
4. Faz upsert de um CNAME proxied por hostname
5. **Falha** se algum CNAME não subir — um tunnel cujo DNS nunca resolveu é
   indistinguível de um tunnel fora do ar, e você depuraria a metade errada
6. **Falha** se o `creds.json` não for legível pelo uid do cloudflared

## Origem

Generalizado a partir do `cloudflared-init` do
[HiveKeeper](https://github.com/ggfto/HiveKeeper), onde o ingress era fixo no script.
Aqui ele vem do ambiente, o que torna a imagem reutilizável entre stacks.

## Permissões do `creds.json`

O init roda como root e o `cloudflared` oficial roda como `nonroot` (uid 65532).
Por isso o `creds.json` é gravado com posse desse uid e modo `0600`. Se o chown
não for possível, cai para `0644` e avisa no log — um segredo legível é melhor
que um tunnel em crash loop com `permission denied`.

Ajuste com `CF_CREDS_UID` / `CF_CREDS_GID` se rodar o cloudflared como outro
usuário.

O init **falha** se o uid alvo não conseguir ler o `creds.json` — a leitura é
testada de fato, como aquele uid, não deduzida de dono e modo. Sem isso o init
sairia com sucesso e o erro só apareceria no container seguinte, em crash loop,
aparecendo de fora como um 530 genérico da Cloudflare.
