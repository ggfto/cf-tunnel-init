#!/bin/sh
# verificar-creds.sh <arquivo> <uid> [gid]
#
# Confere que o uid informado consegue MESMO ler o arquivo, executando a leitura
# como ele em vez de deduzir a partir de dono e modo.
#
# Existe porque o init roda como root e o cloudflared nao: um creds.json com
# 0600 root:root passa em qualquer inspecao superficial e mesmo assim poe o
# runner em crash loop com "permission denied". Como o init ja saiu 0 e com log
# de sucesso, o erro so aparece no container seguinte — e do lado de fora vira
# um 530 generico da Cloudflare, longe da causa.
set -eu

ARQ="${1:?uso: verificar-creds.sh <arquivo> <uid> [gid]}"
UID_ALVO="${2:?uso: verificar-creds.sh <arquivo> <uid> [gid]}"
GID_ALVO="${3:-$UID_ALVO}"

if [ ! -f "$ARQ" ]; then
    echo "ERRO: $ARQ nao existe" >&2
    exit 1
fi

if ! su-exec "$UID_ALVO:$GID_ALVO" cat "$ARQ" >/dev/null 2>&1; then
    echo "ERRO: o uid $UID_ALVO nao consegue ler $ARQ ($(stat -c 'dono %u:%g modo %a' "$ARQ"))." >&2
    echo "      O cloudflared entraria em crash loop com 'permission denied'." >&2
    echo "      Ajuste CF_CREDS_UID/CF_CREDS_GID para o usuario que roda o runner." >&2
    exit 1
fi

echo "==> $ARQ legivel pelo uid $UID_ALVO ($(stat -c 'dono %u:%g modo %a' "$ARQ"))"
