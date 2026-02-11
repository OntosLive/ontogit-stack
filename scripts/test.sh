#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE_URL="http://127.0.0.1:8089"
USAGE_URL="http://127.0.0.1:8091"
DB_PATH="$STACK_DIR/openwebui-data/usage.db"
ENV_FILE="$STACK_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing .env at $ENV_FILE"
  exit 1
fi

JWT_SECRET="$(grep -E '^ONTOS_JWT_SECRET=' "$ENV_FILE" | head -n1 | cut -d= -f2-)"
if [ -z "$JWT_SECRET" ] || [ "$JWT_SECRET" = "change-me" ]; then
  echo "ONTOS_JWT_SECRET is not set to a non-default value in .env"
  exit 1
fi

gen_jwt() {
  python3 - "$JWT_SECRET" "$1" <<'PY'
import sys, json, time, base64, hmac, hashlib
secret = sys.argv[1]
sub = sys.argv[2]
now = int(time.time())
header = {"alg":"HS256","typ":"JWT"}
payload = {"sub": sub, "iat": now, "exp": now + 3600}
def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("utf-8")
h = b64url(json.dumps(header, separators=(",",":")).encode("utf-8"))
p = b64url(json.dumps(payload, separators=(",",":")).encode("utf-8"))
sig = hmac.new(secret.encode("utf-8"), f"{h}.{p}".encode("utf-8"), hashlib.sha256).digest()
s = b64url(sig)
print(f"{h}.{p}.{s}")
PY
}

fetch_limit() {
  python3 - "$1" <<'PY'
import json, sys, urllib.request
user_id = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:8091/limits/{user_id}") as r:
    data = json.loads(r.read().decode("utf-8"))
    print(float(data.get("limit_usd") or 0.0))
PY
}

assert_headers() {
  local file="$1"
  for h in "x-ontogit-user" "x-ontogit-used-usd" "x-ontogit-limit-usd" "x-ontogit-warn"; do
    if ! grep -qi "^$h:" "$file"; then
      echo "Missing header: $h"
      exit 1
    fi
  done
}

echo "==> restart header-injector with AUTH_REQUIRED=1"
(cd "$STACK_DIR" && AUTH_REQUIRED=1 docker compose up -d --build --no-deps header-injector >/dev/null)
for i in $(seq 1 40); do
  code="$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/models" || true)"
  if [ "$code" != "000" ]; then break; fi
  sleep 0.5
done

echo "==> cleanup usage_events for test users"
sqlite3 "$DB_PATH" "delete from usage_events where user_id in ('andrey','u1','u2');"

echo "==> assign roles via usage-writer"
curl -s -o /tmp/u1_role.json -w "%{http_code}" -H "Content-Type: application/json" \
  -X PUT -d '{"role":"low","active":1}' "$USAGE_URL/users/u1" | tail -n1 >/tmp/u1_role.code
curl -s -o /tmp/u2_role.json -w "%{http_code}" -H "Content-Type: application/json" \
  -X PUT -d '{"role":"high","active":1}' "$USAGE_URL/users/u2" | tail -n1 >/tmp/u2_role.code
if [ "$(cat /tmp/u1_role.code)" != "200" ] || [ "$(cat /tmp/u2_role.code)" != "200" ]; then
  echo "Failed to set roles for u1/u2"
  exit 1
fi

echo "==> generate JWTs"
jwt_u1="$(gen_jwt u1)"
jwt_u2="$(gen_jwt u2)"

echo "==> /v1/models without token should be 401"
code="$(curl -s -o /tmp/models_noauth.json -w "%{http_code}" "$BASE_URL/v1/models")"
echo "status=$code"
if [ "$code" != "401" ]; then
  echo "Expected 401 from /v1/models without token, got $code"
  exit 1
fi

echo "==> /v1/models with token should be 200 and headers present"
curl -s -D /tmp/models_u1.hdr -o /tmp/models_u1.json -H "X-Ontogit-Auth: Bearer $jwt_u1" "$BASE_URL/v1/models" >/dev/null
code="$(awk 'NR==1{print $2}' /tmp/models_u1.hdr)"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 from /v1/models with token, got $code"
  exit 1
fi
assert_headers /tmp/models_u1.hdr

echo "==> /v1/chat/completions for u1/u2 (200 + headers)"
payload='{"model":"gpt-4o-mini","messages":[{"role":"user","content":"ping"}],"max_tokens":1}'
curl -s -D /tmp/chat_u1.hdr -o /tmp/chat_u1.json -H "Content-Type: application/json" \
  -H "X-Ontogit-Auth: Bearer $jwt_u1" -d "$payload" "$BASE_URL/v1/chat/completions" >/dev/null
code="$(awk 'NR==1{print $2}' /tmp/chat_u1.hdr)"
echo "u1 status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 for u1, got $code"
  exit 1
fi
assert_headers /tmp/chat_u1.hdr

curl -s -D /tmp/chat_u2.hdr -o /tmp/chat_u2.json -H "Content-Type: application/json" \
  -H "X-Ontogit-Auth: Bearer $jwt_u2" -d "$payload" "$BASE_URL/v1/chat/completions" >/dev/null
code="$(awk 'NR==1{print $2}' /tmp/chat_u2.hdr)"
echo "u2 status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 for u2, got $code"
  exit 1
fi
assert_headers /tmp/chat_u2.hdr

echo "==> insert test usage for u1 to reach limit"
limit_u1="$(fetch_limit u1)"
now="$(date +%s)"
sqlite3 "$DB_PATH" "insert into usage_events(ts,user_id,cost_usd) values($now,'u1',$limit_u1);"

echo "==> u1 should be 429 with limit_exceeded JSON and headers"
curl -s -D /tmp/chat_u1_blocked.hdr -o /tmp/chat_u1_blocked.json -H "Content-Type: application/json" \
  -H "X-Ontogit-Auth: Bearer $jwt_u1" -d "$payload" "$BASE_URL/v1/chat/completions" >/dev/null
code="$(awk 'NR==1{print $2}' /tmp/chat_u1_blocked.hdr)"
echo "u1 status=$code"
if [ "$code" != "429" ]; then
  echo "Expected 429 for u1 after limit, got $code"
  exit 1
fi
assert_headers /tmp/chat_u1_blocked.hdr
if ! grep -q '"error":"limit_exceeded"' /tmp/chat_u1_blocked.json; then
  echo "Expected limit_exceeded in 429 body"
  exit 1
fi

echo "==> u2 should still be 200"
curl -s -D /tmp/chat_u2_after.hdr -o /tmp/chat_u2_after.json -H "Content-Type: application/json" \
  -H "X-Ontogit-Auth: Bearer $jwt_u2" -d "$payload" "$BASE_URL/v1/chat/completions" >/dev/null
code="$(awk 'NR==1{print $2}' /tmp/chat_u2_after.hdr)"
echo "u2 status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 for u2 after u1 limit, got $code"
  exit 1
fi
assert_headers /tmp/chat_u2_after.hdr

echo "OK"
