#!/usr/bin/env bash
set -euo pipefail

SERVICE_SECRET="${ONTOS_SERVICE_AUTH_SECRET:-}"
if [ -z "$SERVICE_SECRET" ]; then
  echo "Missing ONTOS_SERVICE_AUTH_SECRET in environment"
  exit 1
fi

BASE_URL="${BASE_URL:-http://127.0.0.1:8090}"
DB_PATH="/home/ontoslive/ontos_data/ontogit-user/usage.db"

U1="ui_user_a_$(date +%s)"
U2="ui_user_b_$(date +%s)"

post_commit() {
  local uid="$1"
  local code
  code="$(
    curl -m 5 -s -o /tmp/commit_${uid}.json -w "%{http_code}" \
      -H "X-Ontos-Service-Auth: ${SERVICE_SECRET}" \
      -H "X-Ontogit-User: ${uid}" \
      -H "Content-Type: application/json" \
      -d "{\"title\":\"${uid}\",\"body\":\"${uid} body\"}" \
      "${BASE_URL}/commit"
  )"
  if [ "$code" != "200" ]; then
    echo "Expected 200 on /commit for ${uid}, got ${code}"
    cat "/tmp/commit_${uid}.json" || true
    exit 1
  fi
}

post_commit "${U1}"
post_commit "${U2}"

cnt_u1="$(sqlite3 "$DB_PATH" "select count(*) from memory_usage_events where user_id='${U1}' and endpoint='commit';")"
cnt_u2="$(sqlite3 "$DB_PATH" "select count(*) from memory_usage_events where user_id='${U2}' and endpoint='commit';")"
distinct_last20="$(sqlite3 "$DB_PATH" "select count(distinct user_id) from (select user_id from memory_usage_events order by id desc limit 20);")"

if [ "${cnt_u1:-0}" -lt 1 ] || [ "${cnt_u2:-0}" -lt 1 ]; then
  echo "User propagation check failed (events not found for both users)"
  sqlite3 "$DB_PATH" "select user_id, endpoint, status_code from memory_usage_events order by id desc limit 20;"
  exit 1
fi

echo "OK: found commit usage events for two distinct user_ids"
echo "user1=${U1}, events=${cnt_u1}"
echo "user2=${U2}, events=${cnt_u2}"
echo "distinct users in last 20 events=${distinct_last20}"
sqlite3 "$DB_PATH" "select user_id, endpoint, status_code from memory_usage_events order by id desc limit 20;"
