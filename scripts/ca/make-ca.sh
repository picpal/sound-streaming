#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"; mkdir -p out
openssl ecparam -name prime256v1 -genkey -noout -out out/ca.key
openssl req -new -x509 -key out/ca.key -sha256 -days 3650 \
  -subj "/CN=Youtumu Home Root CA" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign" \
  -out out/ca.crt
echo "CA created: out/ca.crt"
