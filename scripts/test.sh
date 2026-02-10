#!/usr/bin/env bash
set -euo pipefail

BASE_URL="http://127.0.0.1:8089"
DB_PATH="./openwebui-data/usage.db"

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
