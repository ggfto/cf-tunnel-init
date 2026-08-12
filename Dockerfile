# syntax=docker/dockerfile:1

# curl e jq entram na imagem em vez de um `apk add` em tempo de execucao: um init
# container que precisa da rede antes de conseguir fazer seu trabalho transforma um
# soluco do mirror de pacotes em deploy quebrado.
FROM alpine:3.21

RUN apk add --no-cache curl jq ca-certificates

COPY init.sh /init.sh
# Normaliza CRLF: um contexto de build vindo de checkout Windows quebraria o shebang.
RUN sed -i 's/\r$//' /init.sh && chmod +x /init.sh

ENTRYPOINT ["/init.sh"]
