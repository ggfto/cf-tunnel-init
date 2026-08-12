# syntax=docker/dockerfile:1

# curl e jq entram na imagem em vez de um `apk add` em tempo de execucao: um init
# container que precisa da rede antes de conseguir fazer seu trabalho transforma um
# soluco do mirror de pacotes em deploy quebrado.
FROM alpine:3.21

# su-exec permite conferir a leitura do creds.json COMO o uid do cloudflared,
# em vez de deduzir a permissao a partir de dono e modo.
RUN apk add --no-cache curl jq ca-certificates su-exec

COPY init.sh /init.sh
COPY verificar-creds.sh /usr/local/bin/verificar-creds.sh
# Normaliza CRLF: um contexto de build vindo de checkout Windows quebraria o shebang.
RUN sed -i 's/\r$//' /init.sh /usr/local/bin/verificar-creds.sh \
    && chmod +x /init.sh /usr/local/bin/verificar-creds.sh

ENTRYPOINT ["/init.sh"]
