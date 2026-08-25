#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
PUB="$1"; OUT="$2"; TMP=$(mktemp -d)
openssl ecparam -name prime256v1 -genkey -noout -out "$TMP/dummy.key"
openssl req -new -key "$TMP/dummy.key" -subj "/CN=watch-s7" -out "$TMP/dummy.csr"
cat > "$TMP/client.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
EOF
openssl x509 -req -in "$TMP/dummy.csr" -force_pubkey "$PUB" -CA out/ca.crt -CAkey out/ca.key \
  -CAcreateserial -days 1095 -sha256 -extfile "$TMP/client.ext" -out "$OUT"
rm -rf "$TMP"
openssl verify -CAfile out/ca.crt "$OUT"
