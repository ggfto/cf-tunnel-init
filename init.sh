#!/bin/sh
# Provisiona um Cloudflare Tunnel LOCALLY-MANAGED pela API — sem `cloudflared tunnel
# login`, sem cert.pem, nada para copiar no host na mao. Roda como init container; o
# cloudflared sobe depois e le o que isto escreveu no volume compartilhado.
#
# Idempotente de proposito, porque roda a cada `up`: cria o tunnel so se faltar, e faz
# upsert de cada registro de DNS em vez de supor que ele nao existe.
#
# O ingress e RENDERIZADO A PARTIR DO AMBIENTE, e nao lido de um arquivo versionado.
# Esse e o ponto: mudar onde o servico responde e uma edicao de variavel e um redeploy,
# nao um commit.
set -eu

: "${CF_API_TOKEN:?defina CF_API_TOKEN (escopos: Account > Cloudflare Tunnel: Edit + Zone > DNS: Edit)}"
: "${CF_ACCOUNT_ID:?defina CF_ACCOUNT_ID}"
: "${CF_ZONE_ID:?defina CF_ZONE_ID}"
: "${TUNNEL_NAME:?defina TUNNEL_NAME — um tunnel por stack, entao precisa ser unico na conta}"

OUT="${CF_OUTPUT_DIR:-/etc/cloudflared}"
PROXIED="${CF_DNS_PROXIED:-true}"
CRED="$OUT/creds.json"
CFG="$OUT/config.yml"
INGRESS_JSON="$OUT/ingress.json"
API="https://api.cloudflare.com/client/v4"
ACCT="$API/accounts/$CF_ACCOUNT_ID"

# cf METODO URL [CORPO_JSON]
cf() {
  if [ -n "${3:-}" ]; then
    curl -fsS -X "$1" "$2" \
      -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data "$3"
  else
    curl -fsS -X "$1" "$2" -H "Authorization: Bearer $CF_API_TOKEN"
  fi
}

mkdir -p "$OUT"

# --- o ingress -------------------------------------------------------------------------
# Duas formas de declarar, da mais simples para a mais completa:
#
#   CF_HOSTNAME=app.exemplo.com
#   CF_SERVICE=http://web:8080
#
#   CF_INGRESS='[{"hostname":"app.exemplo.com","path":"^/auth(/.*)?$","service":"http://kc:8080"},
#                {"hostname":"app.exemplo.com","service":"http://web:8080"},
#                {"hostname":"agents.exemplo.com","service":"tcp://gateway:9443"}]'
#
# JSON numa variavel so, e nao YAML multilinha, porque campos de variavel de stack no
# Portainer sao de uma linha. A ORDEM DAS REGRAS IMPORTA: o cloudflared usa a primeira
# que casar, entao regras com `path` precisam vir antes do catch-all daquele hostname.
if [ -n "${CF_INGRESS:-}" ]; then
  echo "$CF_INGRESS" > "$INGRESS_JSON"
elif [ -n "${CF_HOSTNAME:-}" ] && [ -n "${CF_SERVICE:-}" ]; then
  jq -n --arg h "$CF_HOSTNAME" --arg s "$CF_SERVICE" \
    '[{hostname: $h, service: $s}]' > "$INGRESS_JSON"
else
  echo "ERRO: defina CF_INGRESS, ou CF_HOSTNAME junto com CF_SERVICE." >&2
  exit 1
fi

jq -e 'type == "array" and length > 0' "$INGRESS_JSON" >/dev/null 2>&1 \
  || { echo "ERRO: CF_INGRESS precisa ser um array JSON nao vazio." >&2; exit 1; }

jq -e 'all(.[]; has("service"))' "$INGRESS_JSON" >/dev/null 2>&1 \
  || { echo "ERRO: toda regra de ingress precisa de um \"service\"." >&2; exit 1; }

# O catch-all e obrigatorio e tem que ser o ultimo. Acrescentamos so se ainda nao houver
# uma regra sem hostname, para nao duplicar quando o usuario ja declarou a dele.
if ! jq -e 'any(.[]; has("hostname") | not)' "$INGRESS_JSON" >/dev/null 2>&1; then
  jq '. + [{service: "http_status:404"}]' "$INGRESS_JSON" > "$INGRESS_JSON.tmp" \
    && mv "$INGRESS_JSON.tmp" "$INGRESS_JSON"
fi

echo "==> [$TUNNEL_NAME] procurando o tunnel..."
TID=$(cf GET "$ACCT/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" | jq -r '.result[0].id // empty')
if [ -z "$TID" ]; then
  echo "==> nao encontrado; criando (config_src=local)..."
  TID=$(cf POST "$ACCT/cfd_tunnel" "{\"name\":\"$TUNNEL_NAME\",\"config_src\":\"local\"}" | jq -r '.result.id')
fi
[ -n "$TID" ] || { echo "ERRO: a API nao devolveu um id de tunnel" >&2; exit 1; }
echo "==> tunnel id: $TID"

# As credenciais sao DERIVADAS do token do tunnel em vez de armazenadas: o token e um
# JSON em base64 cujos campos sao exatamente o que o creds.json precisa. Ou seja, este
# volume pode ser jogado fora e reconstruido da API no proximo boot, e o unico segredo
# duravel e o CF_API_TOKEN.
echo "==> buscando o token e escrevendo o creds.json..."
TOKEN=$(cf GET "$ACCT/cfd_tunnel/$TID/token" | jq -r '.result')
echo "$TOKEN" | base64 -d | jq '{AccountTag: .a, TunnelID: .t, TunnelSecret: .s}' > "$CRED"

# O arquivo precisa ser legivel pelo cloudflared, que na imagem oficial roda como
# nonroot (uid 65532) — e este init roda como root. Um `chmod 600` sozinho deixaria
# o runner em crash loop com "permission denied", entao damos a posse a ele.
# Se o chown nao for possivel (init sem privilegio), cai para 0644 e avisa, porque
# um segredo legivel e melhor que um tunnel que nunca sobe.
if chown "${CF_CREDS_UID:-65532}:${CF_CREDS_GID:-65532}" "$CRED" 2>/dev/null; then
    chmod 600 "$CRED"
else
    chmod 644 "$CRED"
    echo "    ! nao foi possivel dar posse do creds.json ao uid ${CF_CREDS_UID:-65532}; usando 0644"
fi

echo "==> montando o config.yml..."
{
  echo "tunnel: $TID"
  echo "credentials-file: $CRED"
  echo "ingress:"
  # Valores serializados com tojson para sobreviverem ao YAML: regras de `path` sao
  # expressoes regulares cheias de $ ? * — sem aspas o parser as interpretaria.
  jq -r '.[] | "  - " + ([to_entries[] | "\(.key): \(.value|tojson)"] | join("\n    "))' "$INGRESS_JSON"
} > "$CFG"

echo "--- $CFG ---"
cat "$CFG"
echo "-------------------------------"

# --- DNS -------------------------------------------------------------------------------
# Todo hostname do ingress vira um CNAME proxied para o tunnel. `sort -u` porque o mesmo
# hostname costuma aparecer em mais de uma regra (uma com path, outra catch-all) e nao ha
# motivo para chamar a API duas vezes.
echo "==> garantindo os CNAMEs (-> $TID.cfargotunnel.com)..."
CONTENT="$TID.cfargotunnel.com"
DNS_FAIL=0
for H in $(jq -r '.[].hostname // empty' "$INGRESS_JSON" | sort -u); do
  RESP=$(cf GET "$API/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=$H" 2>/dev/null) \
    || { echo "    ! $H: consulta de DNS falhou (token sem Zone:DNS:Edit? CF_ZONE_ID certo?)"; DNS_FAIL=1; continue; }
  RID=$(echo "$RESP" | jq -r '.result[0].id // empty')
  BODY=$(jq -n --arg n "$H" --arg c "$CONTENT" --argjson p "$PROXIED" \
    '{type: "CNAME", name: $n, content: $c, proxied: $p}')
  if [ -z "$RID" ]; then
    cf POST "$API/zones/$CF_ZONE_ID/dns_records" "$BODY" >/dev/null 2>&1 \
      && echo "    + $H" || { echo "    ! $H: criar o CNAME falhou (403 = token sem DNS:Edit)"; DNS_FAIL=1; }
  else
    cf PUT "$API/zones/$CF_ZONE_ID/dns_records/$RID" "$BODY" >/dev/null 2>&1 \
      && echo "    ~ $H" || { echo "    ! $H: atualizar o CNAME falhou (403 = token sem DNS:Edit)"; DNS_FAIL=1; }
  fi
done

# Falhar o init em vez de deixar o runner subir meio roteado: um tunnel cujo DNS nunca
# resolveu e indistinguivel de um tunnel simplesmente fora do ar, e voce depuraria a
# metade errada.
if [ "$DNS_FAIL" != 0 ]; then
  echo "ERRO: os CNAMEs nao foram configurados. De ao CF_API_TOKEN 'Zone > DNS: Edit' nesta zona e redeploy." >&2
  exit 1
fi

echo "==> pronto: config.yml e creds.json em $OUT (tunnel $TUNNEL_NAME / $TID)."
