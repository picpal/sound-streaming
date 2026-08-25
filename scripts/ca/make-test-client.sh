#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
openssl ecparam -name prime256v1 -genkey -noout -out out/test-client.key
openssl req -new -key out/test-client.key -subj "/CN=test-client" -out out/test-client.csr
printf "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n" > out/tc.ext
openssl x509 -req -in out/test-client.csr -CA out/ca.crt -CAkey out/ca.key -CAcreateserial \
  -days 365 -sha256 -extfile out/tc.ext -out out/test-client.crt
