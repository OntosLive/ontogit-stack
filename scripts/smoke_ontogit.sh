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
WARN_USER_MISSING="User id not propagated; usage will be aggregated"
SMOKE_NO_RECREATE="${SMOKE_NO_RECREATE:-0}"

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

expect_status() {
  local got="$1"
  local want="$2"
  local what="$3"
  if [ "$got" != "$want" ]; then
    echo "Expected ${want} on ${what}, got ${got}"
    exit 1
  fi
}

expect_header_contains() {
  local file="$1"
  local header="$2"
  local needle="$3"
  local what="$4"
  if ! rg -qi "^${header}:.*${needle}" "$file"; then
    echo "Expected header ${header} containing '${needle}' on ${what}"
    echo "Headers:"
    cat "$file"
    exit 1
  fi
}

check_usage_event_exists() {
  local uid="$1"
  local endpoint="$2"
  local status="$3"
  local cnt
  cnt="$(sqlite3 "$DB_PATH" "select count(*) from memory_usage_events where user_id='${uid}' and endpoint='${endpoint}' and status_code=${status};")"
  if [ "${cnt:-0}" -lt 1 ]; then
    echo "Expected usage event for user_id=${uid}, endpoint=${endpoint}, status=${status}"
    exit 1
  fi
}

maybe_recreate_memory_service() {
  if [ "${SMOKE_NO_RECREATE}" = "1" ]; then
    echo "SMOKE_NO_RECREATE=1: skipping memory-service recreate ($*)"
    return 0
  fi
  (
    cd "$STACK_DIR" && \
    "$@" $DOCKER_CMD compose "${ENV_ARGS[@]}" up -d --force-recreate memory-service
  )
}

echo "==> /health without service-auth should be 401"
code="$(curl -m 3 -s -o /tmp/health_noauth.json -w "%{http_code}" "$BASE_URL/health")"
echo "status=$code"
expect_status "$code" "401" "/health without service-auth"

echo "==> /health with service-auth should be 200"
code="$(curl -m 3 -s -o /tmp/health_auth.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" "$BASE_URL/health")"
echo "status=$code"
expect_status "$code" "200" "/health with service-auth"

echo "==> /recall with service-auth + user-id"
SMOKE_USER="user_smoke_$(date +%s)"
code="$(curl -m 3 -s -o /tmp/recall.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: ${SMOKE_USER}" -H "Content-Type: application/json" -d '{"query":"test","k":1}' "$BASE_URL/recall")"
echo "status=$code"
expect_status "$code" "200" "/recall"

echo "==> /commit with service-auth + user-id"
code="$(curl -m 3 -s -o /tmp/commit.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: ${SMOKE_USER}" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
expect_status "$code" "200" "/commit"

table_exists="$(sqlite3 "$DB_PATH" "select name from sqlite_master where type='table' and name='memory_usage_events';")"
if [ "$table_exists" != "memory_usage_events" ]; then
  echo "memory_usage_events table not found in $DB_PATH"
  exit 1
fi
check_usage_event_exists "${SMOKE_USER}" "commit" "200"

echo "==> missing X-Ontogit-User should warn (not 401)"
code="$(curl -m 3 -s -D /tmp/recall_unknown.headers -o /tmp/recall_unknown.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "Content-Type: application/json" -d '{"query":"missing user warning","k":1}' "$BASE_URL/recall")"
echo "status=$code"
expect_status "$code" "200" "/recall without user header"
expect_header_contains "/tmp/recall_unknown.headers" "X-Ontogit-Warn" "${WARN_USER_MISSING}" "/recall without user header"
check_usage_event_exists "unknown" "recall" "200"

echo "==> soft limit test (second request returns 200 + X-Ontogit-Warn: quota_exceeded)"
SOFT_USER="user_soft_$(date +%s)"
if [ "${SMOKE_NO_RECREATE}" = "1" ]; then
  echo "SMOKE_NO_RECREATE=1: skipping soft/hard/admin mode-switch checks"
  echo "==> last 5 usage events"
  sqlite3 "$DB_PATH" "select user_id, endpoint, status_code from memory_usage_events order by id desc limit 5;"
  exit 0
fi
maybe_recreate_memory_service env ONTOGIT_DAILY_REQUEST_LIMIT=1 ONTOGIT_LIMIT_MODE=soft ONTOGIT_ADMIN_USERS=admin
wait_for_health

code="$(curl -m 3 -s -D /tmp/commit_soft_a.headers -o /tmp/commit_soft_a.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: ${SOFT_USER}" -H "Content-Type: application/json" -d '{"title":"soft-a","body":"soft-a"}' "$BASE_URL/commit")"
echo "status=$code"
expect_status "$code" "200" "/commit soft user first request"
code="$(curl -m 3 -s -D /tmp/commit_soft_b.headers -o /tmp/commit_soft_b.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: ${SOFT_USER}" -H "Content-Type: application/json" -d '{"title":"soft-b","body":"soft-b"}' "$BASE_URL/commit")"
echo "status=$code"
expect_status "$code" "200" "/commit soft user second request"
expect_header_contains "/tmp/commit_soft_b.headers" "X-Ontogit-Warn" "quota_exceeded" "/commit soft user second request"
check_usage_event_exists "${SOFT_USER}" "commit" "200"

echo "==> hard limit test (daily request limit=1)"
HARD_USER="user_hard_$(date +%s)"
echo "==> recreate memory-service with hard limits"
maybe_recreate_memory_service env ONTOGIT_DAILY_REQUEST_LIMIT=1 ONTOGIT_LIMIT_MODE=hard ONTOGIT_ADMIN_USERS=admin
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

echo "==> non-admin user should hit 429 on second request"
code="$(curl -m 3 -s -o /tmp/commit_hard_a.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: ${HARD_USER}" -H "Content-Type: application/json" -d '{"title":"hard-a","body":"hard-a"}' "$BASE_URL/commit")"
echo "status=$code"
expect_status "$code" "200" "/commit hard user first request"
code="$(curl -m 3 -s -o /tmp/commit_hard_b.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: ${HARD_USER}" -H "Content-Type: application/json" -d '{"title":"hard-b","body":"hard-b"}' "$BASE_URL/commit")"
echo "status=$code"
if [ "$code" != "429" ]; then
  echo "Expected 429 on /commit for hard user second request, got $code"
  exit 1
fi
if ! rg -q '"error":"quota_exceeded"' /tmp/commit_hard_b.json; then
  echo "Expected {\"error\":\"quota_exceeded\"} body on hard-limit block"
  cat /tmp/commit_hard_b.json
  exit 1
fi
check_usage_event_exists "${HARD_USER}" "commit" "429"

echo "==> admin user should bypass limits"
code="$(curl -m 3 -s -o /tmp/commit_admin_a.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: admin" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
expect_status "$code" "200" "/commit admin first request"
code="$(curl -m 3 -s -o /tmp/commit_admin_b.json -w "%{http_code}" -H "X-Ontos-Service-Auth: $SERVICE_SECRET" -H "X-Ontogit-User: admin" -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' "$BASE_URL/commit")"
echo "status=$code"
expect_status "$code" "200" "/commit admin second request"

echo "==> restore normal mode (no limits)"
maybe_recreate_memory_service env ONTOGIT_DAILY_REQUEST_LIMIT= ONTOGIT_LIMIT_MODE= ONTOGIT_ADMIN_USERS=
wait_for_health

echo "==> last 5 usage events"
sqlite3 "$DB_PATH" "select user_id, endpoint, status_code from memory_usage_events order by id desc limit 5;"
