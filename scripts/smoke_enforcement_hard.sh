#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
POLICY_HOST_PATH="/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml"
TMP_DIR="$(mktemp -d /tmp/ontogit_smoke_enforcement_hard.XXXXXX)"
HI_PORT="${HI_PORT:-8089}"
SMOKE_NO_RECREATE="${SMOKE_NO_RECREATE:-0}"

DOCKER=()
pick_docker() {
  if docker ps >/dev/null 2>&1; then
    DOCKER=(docker)
    echo "docker runner: docker"
    return 0
  fi
  if sudo -n docker ps >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
    echo "docker runner: sudo -n docker"
    return 0
  fi
  if [ -n "${DOCKER_HOST:-}" ] || [ -n "${DOCKER_CONTEXT:-}" ]; then
    local -a sudo_runner=(sudo -n env)
    if [ -n "${DOCKER_HOST:-}" ]; then
      sudo_runner+=("DOCKER_HOST=${DOCKER_HOST}")
    fi
    if [ -n "${DOCKER_CONTEXT:-}" ]; then
      sudo_runner+=("DOCKER_CONTEXT=${DOCKER_CONTEXT}")
    fi
    if "${sudo_runner[@]}" docker ps >/dev/null 2>&1; then
      DOCKER=("${sudo_runner[@]}" docker)
      echo "docker runner: sudo -n env ... docker"
      return 0
    fi
  fi
  echo "docker ps failed; try: sudo usermod -aG docker ${USER:-$(id -un 2>/dev/null || echo your_user)} && newgrp docker"
  echo "WSL/Docker Desktop may still require sudo; scripts use sudo -n automatically when available."
  return 1
}
pick_docker || exit 1

BACKUP_FILE="${TMP_DIR}/onto_policy.backup.$(date +%s).yml"
HAD_POLICY=0
if [ "${SMOKE_NO_RECREATE}" != "1" ] && [ -f "${POLICY_HOST_PATH}" ]; then
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
  if [ "${SMOKE_NO_RECREATE}" != "1" ]; then
    (
      cd "${STACK_DIR}" && \
      ONTOGIT_LIMIT_MODE=soft \
      "${DOCKER[@]}" compose up -d --force-recreate --no-deps usage-writer header-injector >/dev/null
    ) || true
  fi
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

maybe_recreate() {
  if [ "${SMOKE_NO_RECREATE}" = "1" ]; then
    echo "SMOKE_NO_RECREATE=1: skipping recreate for $*"
    return 0
  fi
  (
    cd "${STACK_DIR}" && \
    ONTOGIT_LIMIT_MODE=hard \
    "${DOCKER[@]}" compose up -d --force-recreate --no-deps "$@"
  )
}

if [ "${SMOKE_NO_RECREATE}" != "1" ]; then
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
fi

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
    code="$(curl -sS --retry 50 --retry-delay 1 --retry-connrefused --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HI_PORT}/openapi.json" 2>/dev/null || true)"
    if [ "${code}" != "000" ]; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge 180 ]; then
      echo "Timeout waiting for header-injector readiness"
      return 1
    fi
    sleep 1
  done
}

echo "==> recreate usage-writer + header-injector in hard mode"
maybe_recreate usage-writer header-injector

wait_http_200 "http://127.0.0.1:8091/limits/ping"
wait_header_injector_ready

TS="$(date +%s)"
TEST_USER="enforce_hard_${TS}"
LIMITS_PRE_JSON="$(curl -sS "http://127.0.0.1:8091/limits/${TEST_USER}")"
LIMIT_PRE="$(python3 - "${LIMITS_PRE_JSON}" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1] or "{}")
except Exception:
    print("0")
    raise SystemExit(0)
print(float(d.get("limit_usd") or 0.0))
PY
)"
if python3 - "${LIMIT_PRE}" <<'PY'
import sys
raise SystemExit(0 if float(sys.argv[1] or 0.0) > 0 else 1)
PY
then :; else
  echo "Expected positive limit_usd for ${TEST_USER}; got ${LIMIT_PRE}. Configure limits before running hard smoke."
  exit 1
fi
SEED_COST="$(python3 - "${LIMIT_PRE}" <<'PY'
import sys
print(f"{float(sys.argv[1]) + 1.0:.6f}")
PY
)"

echo "==> seed usage above policy limit for ${TEST_USER}"
curl -sS -X POST -H 'Content-Type: application/json' \
  -d "{\"ts\":${TS},\"user_id\":\"${TEST_USER}\",\"model\":\"smoke\",\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2,\"cost_usd\":${SEED_COST}}" \
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
HDR="${TMP_DIR}/hard_gate.headers"
BODY="${TMP_DIR}/hard_gate.body"
curl -sS -D "${HDR}" -o "${BODY}" --retry 25 --retry-delay 1 --retry-connrefused --max-time 5 \
  -H "Content-Type: application/json" \
  -H "X-OpenWebUI-User-Id: ${TEST_USER}" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"smoke hard gate"}]}' \
  "http://127.0.0.1:${HI_PORT}/v1/chat/completions" >/dev/null 2>&1 || true
CODE="$(awk 'BEGIN{c=""} /^HTTP\/1/{c=$2} END{print c}' "${HDR}" 2>/dev/null || true)"

if [ -z "${CODE}" ]; then
  echo "FAIL: unable to parse HTTP code from hard gate response"
  echo "--- headers (first 30 lines) ---"
  sed -n '1,30p' "${HDR}" 2>/dev/null || true
  echo "--- body (first 300 chars) ---"
  head -c 300 "${BODY}" 2>/dev/null || true
  echo
  exit 1
fi

if [ "${CODE}" != "429" ]; then
  echo "FAIL: expected 429 from header-injector hard gate, got ${CODE}"
  echo "--- headers (first 30 lines) ---"
  sed -n '1,30p' "${HDR}" 2>/dev/null || true
  echo "--- body (first 300 chars) ---"
  head -c 300 "${BODY}" 2>/dev/null || true
  echo
  exit 1
fi

echo "OK: smoke_enforcement_hard passed"
