#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
POLICY_HOST_PATH="/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml"
TMP_DIR="/tmp/ontogit_smoke_enforcement_hard"
mkdir -p "${TMP_DIR}"

DOCKER_CMD="docker"
if ! docker ps >/dev/null 2>&1; then
  if sudo -n docker ps >/dev/null 2>&1 || sudo -E docker ps >/dev/null 2>&1; then
    DOCKER_CMD="sudo -E docker"
    echo "Using sudo docker (password may be required)"
  else
    echo "Docker is not accessible (direct or via sudo)."
    exit 1
  fi
fi

BACKUP_FILE="${TMP_DIR}/onto_policy.backup.$(date +%s).yml"
HAD_POLICY=0
if [ -f "${POLICY_HOST_PATH}" ]; then
  cp "${POLICY_HOST_PATH}" "${BACKUP_FILE}"
  HAD_POLICY=1
fi

restore_policy() {
  if [ "${HAD_POLICY}" -eq 1 ]; then
    cp "${BACKUP_FILE}" "${POLICY_HOST_PATH}"
  else
    rm -f "${POLICY_HOST_PATH}"
  fi
}

cleanup() {
  restore_policy
  (
    cd "${STACK_DIR}" && \
    ONTOGIT_LIMIT_MODE=soft \
    $DOCKER_CMD compose up -d --force-recreate --no-deps usage-writer header-injector >/dev/null
  ) || true
}
trap cleanup EXIT

cat > "${POLICY_HOST_PATH}" <<'YAML'
version: 1
admin_users: []
default_role: "basic"
roles:
  basic:
    daily:
      request_limit: 0
      token_limit: 0
    monthly:
      limit_usd: 1
      warn_70: 0.7
      warn_90: 0.9
  pro:
    daily:
      request_limit: 0
      token_limit: 0
    monthly:
      limit_usd: 50
      warn_70: 0.7
      warn_90: 0.9
  admin:
    daily:
      request_limit: 0
      token_limit: 0
    monthly:
      limit_usd: 0
YAML

wait_http_200() {
  local url="$1"
  local start
  local code
  start="$(date +%s)"
  while true; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${url}" || true)"
    if [ "${code}" = "200" ]; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge 45 ]; then
      echo "Timeout waiting for ${url}"
      return 1
    fi
    sleep 1
  done
}

wait_header_injector_ready() {
  local start
  local code
  start="$(date +%s)"
  while true; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8089/openapi.json" || true)"
    if [ "${code}" != "000" ]; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge 45 ]; then
      echo "Timeout waiting for header-injector readiness"
      return 1
    fi
    sleep 1
  done
}

echo "==> recreate usage-writer + header-injector in hard mode"
(
  cd "${STACK_DIR}" && \
  ONTOGIT_LIMIT_MODE=hard \
  $DOCKER_CMD compose up -d --force-recreate --no-deps usage-writer header-injector
)

wait_http_200 "http://127.0.0.1:8091/limits/ping"
wait_header_injector_ready

TS="$(date +%s)"
TEST_USER="enforce_hard_${TS}"

echo "==> seed usage above policy limit for ${TEST_USER}"
curl -sS -X POST -H 'Content-Type: application/json' \
  -d "{\"ts\":${TS},\"user_id\":\"${TEST_USER}\",\"model\":\"smoke\",\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2,\"cost_usd\":2.0}" \
  "http://127.0.0.1:8091/usage" >/dev/null

LIMITS_JSON="$(curl -sS "http://127.0.0.1:8091/limits/${TEST_USER}")"
USED_JSON="$(curl -sS "http://127.0.0.1:8091/used/${TEST_USER}")"
python3 - "${LIMITS_JSON}" "${USED_JSON}" <<'PY'
import json, sys
limits = json.loads(sys.argv[1])
used = json.loads(sys.argv[2])
limit = float(limits.get("limit_usd") or 0.0)
used_v = float(used.get("used_usd") or 0.0)
if limit <= 0:
    raise SystemExit(f"expected positive limit for smoke user, got {limit}")
if used_v < limit:
    raise SystemExit(f"expected used>=limit before enforcement test, got used={used_v} limit={limit}")
PY

echo "==> verify hard enforcement blocks before model forwarding"
CODE="$(curl -sS -o /dev/null -w '%{http_code}' --retry 25 --retry-delay 1 --retry-connrefused --max-time 5 \
  -H "Content-Type: application/json" \
  -H "X-OpenWebUI-User-Id: ${TEST_USER}" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"smoke hard gate"}]}' \
  "http://127.0.0.1:8089/v1/chat/completions")"

if [ "${CODE}" != "429" ]; then
  echo "FAIL: expected 429 from header-injector hard gate, got ${CODE}"
  exit 1
fi

echo "OK: smoke_enforcement_hard passed"
