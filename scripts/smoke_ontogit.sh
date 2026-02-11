#!/usr/bin/env bash
set -euo pipefail

SERVICE_SECRET="${ONTOS_SERVICE_AUTH_SECRET:-}"
if [ -z "$SERVICE_SECRET" ]; then
  echo "Missing ONTOS_SERVICE_AUTH_SECRET in environment"
  exit 1
fi

BASE_URL="http://127.0.0.1:8090"
DB_PATH="/home/ontoslive/ontos_data/ontogit-user/usage.db"
STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"

DOCKER_CMD="docker"
if ! docker ps >/dev/null 2>&1; then
  if sudo -n docker ps >/dev/null 2>&1 || sudo -E docker ps >/dev/null 2>&1; then
    DOCKER_CMD="sudo -E docker"
    echo "Using sudo docker (password may be required)"
  fi
fi

ENV_FILE="${STACK_DIR}/.env.local"
ENV_ARGS=()
if $DOCKER_CMD compose --help 2>/dev/null | rg -q -- '--env-file'; then
  ENV_ARGS=(--env-file "$ENV_FILE")
else
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi
fi

wait_for_health() {
  local start
  start="$(date +%s)"
  while true; do
    code="$(curl -m 3 -s -m 2 -o /dev/null -w "%{http_code}" "$BASE_URL/health" || true)"
    if [ "$code" = "200" ] || [ "$code" = "401" ]; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge 15 ]; then
      echo "Timeout waiting for memory-service health"
      return 1
    fi
    sleep 1
  done
}

echo "==> /health without service-auth should be 401"
code="$(curl -m 3 -s -o /tmp/health_noauth.json -w "%{http_code}" "$BASE_URL/health")"
echo "status=$code"
if [ "$code" != "401" ]; then
  echo "Expected 401 on /health without service-auth, got $code"
  exit 1
fi

echo "==> /health with service-auth should be 200"
code="$(curl -m 3 -s -o /tmp/health_auth.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" "$BASE_URL/health")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 on /health with service-auth, got $code"
  exit 1
fi

echo "==> /recall with service-auth + user-id"
code="$(curl -m 3 -s -o /tmp/recall.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: u1" -H "Content-Type: application/json" -d '{"query":"test","k":1}' "$BASE_URL/recall")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 on /recall, got $code"
  exit 1
fi

echo "==> /commit with service-auth + user-id"
code="$(curl -m 3 -s -o /tmp/commit.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: u1" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 on /commit, got $code"
  exit 1
fi

echo "==> hard limit test (daily request limit=1)"
export ONTOGIT_DAILY_REQUEST_LIMIT=1
export ONTOGIT_LIMIT_MODE=hard
export ONTOGIT_ADMIN_USERS=admin

echo "==> recreate memory-service with hard limits"
(cd "$STACK_DIR" && ONTOGIT_DAILY_REQUEST_LIMIT=1 ONTOGIT_LIMIT_MODE=hard $DOCKER_CMD compose "${ENV_ARGS[@]}" up -d --force-recreate memory-service)
wait_for_health

mem_id="$($DOCKER_CMD ps --format '{{.ID}} {{.Names}}' | rg -i 'memory-service' | head -n1 | awk '{print $1}')"
if [ -z "$mem_id" ]; then
  echo "memory-service container not found"
  exit 1
fi
if ! $DOCKER_CMD exec "$mem_id" env | rg -q '^ONTOGIT_DAILY_REQUEST_LIMIT=1$'; then
  echo "memory-service missing ONTOGIT_DAILY_REQUEST_LIMIT=1 after recreate"
  exit 1
fi

echo "==> clear today's usage for user1/admin"
today_start="$(date -u +"%s" -d "$(date -u +%Y-%m-%d) 00:00:00")"
table_exists="$(sqlite3 "$DB_PATH" "select name from sqlite_master where type='table' and name='memory_usage_events';")"
if [ "$table_exists" != "memory_usage_events" ]; then
  echo "memory_usage_events table not found in $DB_PATH"
  exit 1
fi
sqlite3 "$DB_PATH" "delete from memory_usage_events where user_id in ('user1','admin') and ts >= ${today_start};"

echo "==> non-admin user should hit 429 on second request"
code="$(curl -m 3 -s -o /tmp/commit_user1_a.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: user1" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 on /commit for user1 first request, got $code"
  exit 1
fi
code="$(curl -m 3 -s -o /tmp/commit_user1_b.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: user1" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
if [ "$code" != "429" ]; then
  echo "Expected 429 on /commit for user1 second request, got $code"
  exit 1
fi

echo "==> admin user should bypass limits"
code="$(curl -m 3 -s -o /tmp/commit_admin_a.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: admin" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 on /commit for admin first request, got $code"
  exit 1
fi
code="$(curl -m 3 -s -o /tmp/commit_admin_b.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: admin" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
if [ "$code" != "200" ]; then
  echo "Expected 200 on /commit for admin second request, got $code"
  exit 1
fi

echo "==> restore normal mode (no limits)"
unset ONTOGIT_DAILY_REQUEST_LIMIT
unset ONTOGIT_LIMIT_MODE
unset ONTOGIT_ADMIN_USERS
(cd "$STACK_DIR" && ONTOGIT_DAILY_REQUEST_LIMIT= ONTOGIT_LIMIT_MODE= ONTOGIT_ADMIN_USERS= $DOCKER_CMD compose "${ENV_ARGS[@]}" up -d --force-recreate memory-service)
wait_for_health

echo "==> last 5 usage events"
sqlite3 "$DB_PATH" "select user_id, endpoint, status_code from memory_usage_events order by id desc limit 5;"
