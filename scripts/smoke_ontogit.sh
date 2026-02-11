#!/usr/bin/env bash
set -euo pipefail

SERVICE_SECRET="${ONTOS_SERVICE_AUTH_SECRET:-}"
if [ -z "$SERVICE_SECRET" ]; then
  echo "Missing ONTOS_SERVICE_AUTH_SECRET in environment"
  exit 1
fi

BASE_URL="http://127.0.0.1:8090"
DB_PATH="./openwebui-data/usage.db"

echo "==> /health without service-auth should be 401"
code="$(curl -s -o /tmp/health_noauth.json -w "%{http_code}" "$BASE_URL/health")"
echo "status=$code"
if [ "$code" != "401" ]; then
  echo "Expected 401 on /health without service-auth, got $code"
  exit 1
fi

echo "==> /health with service-auth should be 200"
code="$(curl -s -o /tmp/health_auth.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" "$BASE_URL/health")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 on /health with service-auth, got $code"
  exit 1
fi

echo "==> /recall with service-auth + user-id"
code="$(curl -s -o /tmp/recall.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: u1" -H "Content-Type: application/json" -d '{"query":"test","k":1}' "$BASE_URL/recall")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 on /recall, got $code"
  exit 1
fi

echo "==> /commit with service-auth + user-id"
code="$(curl -s -o /tmp/commit.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: u1" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 on /commit, got $code"
  exit 1
fi

echo "==> hard limit test (daily request limit=1)"
export ONTOGIT_DAILY_REQUEST_LIMIT=1
export ONTOGIT_LIMIT_MODE=hard
export ONTOGIT_ADMIN_USERS=admin

echo "==> non-admin user should hit 429 on second request"
code="$(curl -s -o /tmp/commit_user1_a.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: user1" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 on /commit for user1 first request, got $code"
  exit 1
fi
code="$(curl -s -o /tmp/commit_user1_b.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: user1" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
if [ "$code" != "429" ]; then
  echo "Expected 429 on /commit for user1 second request, got $code"
  exit 1
fi

echo "==> admin user should bypass limits"
code="$(curl -s -o /tmp/commit_admin_a.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: admin" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 on /commit for admin first request, got $code"
  exit 1
fi
code="$(curl -s -o /tmp/commit_admin_b.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: admin" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 on /commit for admin second request, got $code"
  exit 1
fi

echo "==> last 5 usage events"
sqlite3 "$DB_PATH" "select user_id, endpoint, status_code from memory_usage_events order by id desc limit 5;"
