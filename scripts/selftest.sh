#!/bin/bash
set -u
CA=scripts/ca/out/ca.crt; C=scripts/ca/out/test-client
HOST=youtumu.duckdns.org
RESOLVE="--resolve $HOST:8443:127.0.0.1"
pass=0; fail=0
chk() { local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then echo "PASS: $name"; pass=$((pass+1));
  else echo "FAIL: $name (want=$want got=$got)"; fail=$((fail+1)); fi }

# 1. 인증서 없는 접속 → TLS 단계 실패
curl -s $RESOLVE --cacert "$CA" "https://$HOST:8443/healthz" -o /dev/null 2>/dev/null
chk "no-client-cert rejected" "1" "$([ $? -ne 0 ] && echo 1 || echo 0)"

# 2. 다른 CA의 client cert → 거부
TMP=$(mktemp -d)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$TMP/k.pem" -out "$TMP/c.pem" -days 1 -subj "/CN=rogue" 2>/dev/null
curl -s $RESOLVE --cacert "$CA" --cert "$TMP/c.pem" --key "$TMP/k.pem" "https://$HOST:8443/healthz" -o /dev/null 2>/dev/null
chk "rogue-cert rejected" "1" "$([ $? -ne 0 ] && echo 1 || echo 0)"

# 3. 정상 인증서 → 200
code=$(curl -s $RESOLVE --cacert "$CA" --cert "$C.crt" --key "$C.key" -o /dev/null -w "%{http_code}" "https://$HOST:8443/healthz" 2>/dev/null)
chk "valid-cert 200" "200" "$code"

echo "---- pass=$pass fail=$fail"; [ $fail -eq 0 ]
