#!/usr/bin/env bash
set -euo pipefail

BASE_URL="http://127.0.0.1:8089"

echo "==> wait for header-injector to be ready"
for i in $(seq 1 40); do
  code="$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/v1/models" || true)"
  if [ "$code" != "000" ]; then break; fi
  sleep 0.5
done
DB_PATH="./openwebui-data/usage.db"
ENV_FILE="/home/ontoslive/ontos_work/ontogit-stack/.env"

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

echo "==> /v1/models (should be 200)"
code="$(curl -s -o /tmp/models.json -w "%{http_code}" "$BASE_URL/v1/models")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 from /v1/models, got $code"
  exit 1
fi

echo "==> /v1/chat/completions (create usage)"
payload='{"model":"gpt-4o-mini","messages":[{"role":"user","content":"ping"}],"max_tokens":1}'
code="$(curl -s -o /tmp/chat.json -w "%{http_code}" -H "Content-Type: application/json" -d "$payload" "$BASE_URL/v1/chat/completions")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 from /v1/chat/completions, got $code"
  exit 1
fi

echo "==> sqlite check user_id=andrey"
uid="$(sqlite3 "$DB_PATH" "select user_id from usage_events order by id desc limit 1;")"
echo "user_id=$uid"
if [ "$uid" != "andrey" ]; then
  echo "Expected user_id=andrey in usage_events, got $uid"
  exit 1
fi

echo "==> invalid JWT should be 401"
code="$(curl -s -o /tmp/bad_token.json -w "%{http_code}" -H "X-Ontogit-Auth: Bearer bad.token.value" "$BASE_URL/v1/models")"
echo "status=$code"
if [ "$code" != "401" ]; then
  echo "Expected 401 for invalid token, got $code"
  exit 1
fi

echo "==> JWT multi-user: u1/u2 chat completions"
jwt_u1="$(gen_jwt u1)"
jwt_u2="$(gen_jwt u2)"
code="$(curl -s -o /tmp/chat_u1.json -w "%{http_code}" -H "Content-Type: application/json" -H "X-Ontogit-Auth: Bearer $jwt_u1" -d "$payload" "$BASE_URL/v1/chat/completions")"
echo "u1 status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 for u1, got $code"
  exit 1
fi
code="$(curl -s -o /tmp/chat_u2.json -w "%{http_code}" -H "Content-Type: application/json" -H "X-Ontogit-Auth: Bearer $jwt_u2" -d "$payload" "$BASE_URL/v1/chat/completions")"
echo "u2 status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 for u2, got $code"
  exit 1
fi

echo "==> sqlite check last two user_id = u2, u1"
last2="$(sqlite3 "$DB_PATH" "select user_id from usage_events order by id desc limit 2;")"
echo "$last2" | tr '\n' ' ' | sed 's/$/\n/'
if [ "$(echo "$last2" | head -n1)" != "u2" ] || [ "$(echo "$last2" | tail -n1)" != "u1" ]; then
  echo "Expected last two user_id to be u2 then u1"
  exit 1
fi

echo "==> insert test usage for u1 to reach >= \$15"
now="$(date +%s)"
sqlite3 "$DB_PATH" "insert into usage_events(ts,user_id,cost_usd) values($now,'u1',15.0);"

echo "==> u1 should be 429, u2 should be 200"
code="$(curl -s -o /tmp/chat_u1_blocked.json -w "%{http_code}" -H "Content-Type: application/json" -H "X-Ontogit-Auth: Bearer $jwt_u1" -d "$payload" "$BASE_URL/v1/chat/completions")"
echo "u1 status=$code"
if [ "$code" != "429" ]; then
  echo "Expected 429 for u1 after limit, got $code"
  exit 1
fi
code="$(curl -s -o /tmp/chat_u2_ok.json -w "%{http_code}" -H "Content-Type: application/json" -H "X-Ontogit-Auth: Bearer $jwt_u2" -d "$payload" "$BASE_URL/v1/chat/completions")"
echo "u2 status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 for u2 after u1 limit, got $code"
  exit 1
fi

echo "==> /v1/models should be 200 for both tokens"
code="$(curl -s -o /tmp/models_u1.json -w "%{http_code}" -H "X-Ontogit-Auth: Bearer $jwt_u1" "$BASE_URL/v1/models")"
echo "u1 models status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 from /v1/models for u1, got $code"
  exit 1
fi
code="$(curl -s -o /tmp/models_u2.json -w "%{http_code}" -H "X-Ontogit-Auth: Bearer $jwt_u2" "$BASE_URL/v1/models")"
echo "u2 models status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 from /v1/models for u2, got $code"
  exit 1
fi

echo "==> insert test usage to reach >= \$15"
now="$(date +%s)"
sqlite3 "$DB_PATH" "insert into usage_events(ts,user_id,cost_usd) values($now,'andrey',15.0);"

echo "==> /v1/chat/completions should be 429 (blocked)"
code="$(curl -s -o /tmp/chat_blocked.json -w "%{http_code}" -H "Content-Type: application/json" -d "$payload" "$BASE_URL/v1/chat/completions")"
echo "status=$code"
if [ "$code" != "429" ]; then
  echo "Expected 429 from /v1/chat/completions, got $code"
  exit 1
fi

echo "==> /v1/models should still be 200"
code="$(curl -s -o /tmp/models2.json -w "%{http_code}" "$BASE_URL/v1/models")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 from /v1/models, got $code"
  exit 1
fi

echo "OK"
