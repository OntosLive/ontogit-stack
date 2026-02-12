#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
POLICY_HOST_PATH="/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml"
TMP_DIR="$(mktemp -d /tmp/ontogit_smoke_enforcement_soft.XXXXXX)"
HI_PORT="${HI_PORT:-8089}"
LIMIT_USD="10"
SMOKE_NO_RECREATE="${SMOKE_NO_RECREATE:-0}"

DOCKER=()
pick_docker() {
  if docker ps >/dev/null 2>&1; then
    DOCKER=(docker)
    return 0
  fi
  local -a sudo_runner=(sudo -n env)
  if [ -n "${DOCKER_HOST:-}" ]; then
    sudo_runner+=("DOCKER_HOST=${DOCKER_HOST}")
  fi
  if [ -n "${DOCKER_CONTEXT:-}" ]; then
    sudo_runner+=("DOCKER_CONTEXT=${DOCKER_CONTEXT}")
  fi
  if "${sudo_runner[@]}" docker ps >/dev/null 2>&1; then
    DOCKER=("${sudo_runner[@]}" docker)
    echo "Using sudo -n docker"
    return 0
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
    ONTOGIT_LIMIT_MODE=soft \
    "${DOCKER[@]}" compose up -d --force-recreate --no-deps "$@"
  )
}

if [ "${SMOKE_NO_RECREATE}" != "1" ]; then
cat > "${POLICY_HOST_PATH}" <<YAML
version: 1
admin_users: []
default_role: "basic"
roles:
  basic:
    daily:
      request_limit: 0
      token_limit: 0
    monthly:
      limit_usd: ${LIMIT_USD}
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
    if [ $(( $(date +%s) - start )) -ge 60 ]; then
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

seed_usage() {
  local user_id="$1"
  local cost="$2"
  local ts
  ts="$(date +%s)"
  curl -sS -X POST -H 'Content-Type: application/json' \
    -d "{\"ts\":${ts},\"user_id\":\"${user_id}\",\"model\":\"smoke\",\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2,\"cost_usd\":${cost}}" \
    "http://127.0.0.1:8091/usage" >/dev/null
}

assert_stage() {
  local user_id="$1"
  local expected_warn="$2"
  local tag="$3"
  local hdr="${TMP_DIR}/${tag}.headers"
  local body="${TMP_DIR}/${tag}.body"
  local code warn role used limit

  get_header_value() {
    local file="$1"
    local name="$2"
    awk -v key="$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')" '
      {
        line=$0
        gsub(/\r$/, "", line)
        low=line
        for (i=1; i<=length(low); i++) {
          c=substr(low,i,1)
          if (c >= "A" && c <= "Z") {
            low=substr(low,1,i-1) tolower(c) substr(low,i+1)
          }
        }
        if (index(low, key ":") == 1) {
          val=substr(line, length(key) + 2)
          sub(/^[[:space:]]+/, "", val)
          print val
          exit
        }
      }
    ' "${file}" 2>/dev/null || true
  }

  curl -sS -D "${hdr}" -o "${body}" --retry 25 --retry-delay 1 --retry-connrefused --max-time 5 \
    -H "Content-Type: application/json" \
    -H "X-OpenWebUI-User-Id: ${user_id}" \
    -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"soft smoke"}]}' \
    "http://127.0.0.1:${HI_PORT}/v1/chat/completions" >/dev/null 2>&1 || true

  code="$(awk 'BEGIN{c=""} /^HTTP\/1/{c=$2} END{print c}' "${hdr}" 2>/dev/null || true)"
  warn="$(get_header_value "${hdr}" "x-ontogit-limit-warn")"
  role="$(get_header_value "${hdr}" "x-ontogit-limit-role")"
  used="$(get_header_value "${hdr}" "x-ontogit-limit-used-usd")"
  limit="$(get_header_value "${hdr}" "x-ontogit-limit-limit-usd")"

  if [ -z "${code}" ]; then
    echo "FAIL(${tag}): missing HTTP code"
    sed -n '1,30p' "${hdr}" 2>/dev/null || true
    exit 1
  fi
  if [ "${code}" = "429" ]; then
    echo "FAIL(${tag}): soft mode should not return 429"
    sed -n '1,30p' "${hdr}" 2>/dev/null || true
    exit 1
  fi
  if [ "${warn}" != "${expected_warn}" ]; then
    echo "FAIL(${tag}): expected warn=${expected_warn}, got ${warn:-<missing>}"
    sed -n '1,40p' "${hdr}" 2>/dev/null || true
    exit 1
  fi
  if [ -z "${role}" ] || [ -z "${used}" ] || [ -z "${limit}" ]; then
    echo "FAIL(${tag}): missing soft-mode limit headers"
    sed -n '1,40p' "${hdr}" 2>/dev/null || true
    exit 1
  fi
}

echo "==> recreate usage-writer + header-injector in soft mode"
maybe_recreate usage-writer header-injector

wait_http_200 "http://127.0.0.1:8091/limits/ping"
wait_header_injector_ready

TS="$(date +%s)"
TEST_USER="enforce_soft_${TS}"
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
  echo "Expected positive limit_usd for ${TEST_USER}; got ${LIMIT_PRE}. Configure limits before running soft smoke."
  exit 1
fi
SEED_70="$(python3 - "${LIMIT_PRE}" <<'PY'
import sys
print(f"{float(sys.argv[1]) * 0.75:.6f}")
PY
)"
SEED_90="$(python3 - "${LIMIT_PRE}" <<'PY'
import sys
print(f"{float(sys.argv[1]) * 0.20:.6f}")
PY
)"
SEED_EXCEEDED="$(python3 - "${LIMIT_PRE}" <<'PY'
import sys
print(f"{float(sys.argv[1]) * 0.15:.6f}")
PY
)"

echo "==> stage none (<70%)"
assert_stage "${TEST_USER}" "none" "stage_none"

echo "==> stage 70%"
seed_usage "${TEST_USER}" "${SEED_70}"
assert_stage "${TEST_USER}" "70" "stage70"

echo "==> stage 90%"
seed_usage "${TEST_USER}" "${SEED_90}"
assert_stage "${TEST_USER}" "90" "stage90"

echo "==> stage exceeded"
seed_usage "${TEST_USER}" "${SEED_EXCEEDED}"
assert_stage "${TEST_USER}" "exceeded" "stage_exceeded"

echo "OK: smoke_enforcement_soft passed"
