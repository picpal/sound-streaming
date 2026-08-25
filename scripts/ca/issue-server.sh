#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DDNS="$1"; LAN_NAME="$2"; LAN_IP="$3"
openssl ecparam -name prime256v1 -genkey -noout -out out/server.key
openssl req -new -key out/server.key -subj "/CN=${DDNS}" -out out/server.csr
cat > out/server.ext <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:${DDNS},DNS:${LAN_NAME},IP:${LAN_IP}
EOF
openssl x509 -req -in out/server.csr -CA out/ca.crt -CAkey out/ca.key -CAcreateserial \
  -days 1095 -sha256 -extfile out/server.ext -out out/server.crt
openssl verify -CAfile out/ca.crt out/server.crt
