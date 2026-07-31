#!/usr/bin/env bash
# gerar-pki.sh — gera uma PKI mTLS (CA + certificado de servidor + N certificados
# de cliente) prontos para uso com TPipeServer/TPipeClient em ptTls.
#
# Gera PEM (backend OpenSSL) e PFX (backend Schannel) para cada certificado,
# igual ao layout de tests/pki/ do próprio pascal-pipes-faa.
#
# Uso:
#   ./gerar-pki.sh -o DIR -s SERVER_CN [-a SAN_LIST] [-p SENHA] [-l DIAS_LEAF] [-c DIAS_CA] CLIENTE_CN [CLIENTE_CN ...]
#
# Exemplo (caso PDV de loja sobre VPN):
#   ./gerar-pki.sh -o ./pki -s retaguarda.empresa.local pdv-001 pdv-002 pdv-003
#
# Requer openssl no PATH (no Windows/Git Bash normalmente já está em
# C:\Program Files\Git\mingw64\bin).

set -euo pipefail

# Git Bash (MSYS) reescreve argumentos que começam com "/" como caminho do
# Windows — sem isso "/CN=..." vira "C:/Program Files/Git/CN=...". Não afeta
# quem roda em Linux puro (a variável simplesmente não existe lá).
export MSYS_NO_PATHCONV=1

OUT_DIR=""
SERVER_CN=""
SAN_LIST=""
SENHA=""
DIAS_LEAF=825
DIAS_CA=3650

while getopts "o:s:a:p:l:c:" opt; do
  case "$opt" in
    o) OUT_DIR="$OPTARG" ;;
    s) SERVER_CN="$OPTARG" ;;
    a) SAN_LIST="$OPTARG" ;;
    p) SENHA="$OPTARG" ;;
    l) DIAS_LEAF="$OPTARG" ;;
    c) DIAS_CA="$OPTARG" ;;
    *) echo "opção inválida" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [[ -z "$OUT_DIR" || -z "$SERVER_CN" || $# -eq 0 ]]; then
  echo "Uso: $0 -o DIR -s SERVER_CN [-a SAN_LIST] [-p SENHA] [-l DIAS_LEAF] [-c DIAS_CA] CLIENTE_CN [CLIENTE_CN ...]" >&2
  echo "Exemplo: $0 -o ./pki -s retaguarda.empresa.local pdv-001 pdv-002" >&2
  exit 1
fi

if [[ -z "$SAN_LIST" ]]; then
  SAN_LIST="DNS:${SERVER_CN},DNS:localhost,IP:127.0.0.1"
fi

if [[ -z "$SENHA" ]]; then
  SENHA="$(openssl rand -base64 18)"
  GEROU_SENHA=1
else
  GEROU_SENHA=0
fi

mkdir -p "$OUT_DIR"
cd "$OUT_DIR"

echo "== CA =="
if [[ -f ca_cert.pem ]]; then
  echo "ca_cert.pem já existe, reaproveitando (apague o diretório para gerar uma CA nova)."
else
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$DIAS_CA" \
    -keyout ca_key.pem -out ca_cert.pem \
    -subj "/CN=PKI-Interna-$(date +%Y%m%d)"
fi

gen_leaf() {
  # $1 = nome do arquivo (sem extensão), $2 = CN, $3 = conteúdo do extfile
  local nome="$1" cn="$2" ext="$3"
  openssl req -newkey rsa:2048 -nodes -sha256 \
    -keyout "${nome}_key.pem" -out "${nome}.csr" \
    -subj "/CN=${cn}"
  printf '%s\n' "$ext" > "${nome}_ext.cnf"
  openssl x509 -req -in "${nome}.csr" -CA ca_cert.pem -CAkey ca_key.pem -CAcreateserial \
    -out "${nome}_cert.pem" -days "$DIAS_LEAF" -sha256 -extfile "${nome}_ext.cnf"
  rm -f "${nome}.csr" "${nome}_ext.cnf"
}

gen_pfx() {
  # $1 = nome do arquivo (sem extensão)
  local nome="$1"
  openssl pkcs12 -export -out "${nome}.pfx" \
    -inkey "${nome}_key.pem" -in "${nome}_cert.pem" -certfile ca_cert.pem \
    -passout "pass:${SENHA}"
}

echo "== Servidor (CN=${SERVER_CN}, SAN=${SAN_LIST}) =="
gen_leaf "srv" "$SERVER_CN" "subjectAltName = ${SAN_LIST}
extendedKeyUsage = serverAuth"
gen_pfx "srv"

for CLI_CN in "$@"; do
  echo "== Cliente (CN=${CLI_CN}) =="
  gen_leaf "$CLI_CN" "$CLI_CN" "extendedKeyUsage = clientAuth"
  gen_pfx "$CLI_CN"
done

echo
echo "PKI gerada em: $(pwd)"
echo "  CA:        ca_cert.pem (+ ca_key.pem — guardar fora do servidor/cliente)"
echo "  Servidor:  srv_cert.pem / srv_key.pem / srv.pfx"
for CLI_CN in "$@"; do
  echo "  Cliente:   ${CLI_CN}_cert.pem / ${CLI_CN}_key.pem / ${CLI_CN}.pfx"
done
if [[ "$GEROU_SENHA" -eq 1 ]]; then
  # Também salva em arquivo: quem roda dando duplo-clique no .sh (em vez de
  # num terminal já aberto) perde a saída assim que a janela fecha sozinha.
  printf '%s\n' "$SENHA" > senha-pfx.txt
  echo
  echo "Senha dos .pfx (gerada automaticamente): ${SENHA}"
  echo "Também salva em: $(pwd)/senha-pfx.txt (é um segredo — não versionar, apagar depois de guardar em outro lugar seguro)"
else
  echo
  echo "Senha dos .pfx: a que você passou em -p"
fi
