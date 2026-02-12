#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
POLICY_HOST_PATH="/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml"
TMP_DIR="/tmp/ontogit_smoke_policy"
mkdir -p "${TMP_DIR}"
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

ENV_FILE="${STACK_DIR}/.env.local"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

SERVICE_SECRET="${ONTOS_SERVICE_AUTH_SECRET:-}"
if [ -z "${SERVICE_SECRET}" ]; then
  echo "Missing ONTOS_SERVICE_AUTH_SECRET (expected in ${ENV_FILE})"
  exit 1
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
  if [ "${SMOKE_NO_RECREATE}" != "1" ]; then
    (
      cd "${STACK_DIR}" && \
      ONTOGIT_LIMIT_MODE=soft \
      "${DOCKER[@]}" compose up -d --force-recreate usage-writer memory-service >/dev/null
    ) || true
  fi
}
trap cleanup EXIT

maybe_recreate() {
  local mode="$1"
  shift
  if [ "${SMOKE_NO_RECREATE}" = "1" ]; then
    echo "SMOKE_NO_RECREATE=1: skipping recreate for $* (requested mode=${mode})"
    return 0
  fi
  (
    cd "${STACK_DIR}" && \
    ONTOGIT_LIMIT_MODE="${mode}" \
    "${DOCKER[@]}" compose up -d --force-recreate "$@"
  )
}

cat > "${POLICY_HOST_PATH}" <<'YAML'
version: 1
admin_users: ["admin", "andrey"]
default_role: "basic"
roles:
  basic:
    daily:
      request_limit: 1
      token_limit: 100000
    monthly:
      limit_usd: 10
      warn_70: 0.7
      warn_90: 0.9
  pro:
    daily:
      request_limit: 5
      token_limit: 500000
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

wait_http() {
  local url="$1"
  local code=""
  local start
  start="$(date +%s)"
  while true; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${url}" || true)"
    if [ "${code}" = "200" ] || [ "${code}" = "401" ]; then
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge 30 ]; then
      echo "Timeout waiting for ${url}"
      return 1
    fi
    sleep 1
  done
}

assert_limits() {
  local user_id="$1"
  local want_role="$2"
  local want_limit="$3"
  local out_file="${TMP_DIR}/limits_${user_id}.json"
  curl -s "http://127.0.0.1:8091/limits/${user_id}" > "${out_file}"
python3 - "$out_file" "$want_role" "$want_limit" <<'PY'
import json, sys
p, want_role, want_limit = sys.argv[1:4]
d = json.load(open(p, encoding='utf-8'))
if str(d.get('role')) != want_role:
    raise SystemExit(f"role mismatch: {d.get('role')} != {want_role}")
if float(d.get('limit_usd') or 0.0) != float(want_limit):
    raise SystemExit(f"limit_usd mismatch: {d.get('limit_usd')} != {want_limit}")
PY
}

BASE_URL="http://127.0.0.1:8090"
TS="$(date +%s)"
BASIC_USER="policy_basic_${TS}"
PRO_USER="policy_pro_${TS}"

echo "==> recreate usage-writer + memory-service with policy file"
maybe_recreate soft usage-writer memory-service

wait_http "${BASE_URL}/health"
wait_http "http://127.0.0.1:8091/limits/ping"

echo "==> set pro user role and validate per-role monthly limits"
curl -s -X PUT -H 'Content-Type: application/json' \
  -d '{"role":"pro","active":1}' \
  "http://127.0.0.1:8091/users/${PRO_USER}" >/dev/null
assert_limits "${BASIC_USER}" "basic" "10"
assert_limits "${PRO_USER}" "pro" "50"
assert_limits "admin" "admin" "0"

echo "==> soft mode check: second basic request stays 200 + quota_exceeded warn"
code="$(curl -s -o "${TMP_DIR}/soft_a.json" -w '%{http_code}' -H "X-Ontos-Service-Auth: ${SERVICE_SECRET}" -H "X-Ontogit-User: ${BASIC_USER}" -H 'Content-Type: application/json' -d '{"title":"soft-a","body":"soft-a"}' "${BASE_URL}/commit")"
[ "${code}" = "200" ] || { echo "soft first request expected 200, got ${code}"; exit 1; }
code="$(curl -s -D "${TMP_DIR}/soft_b.headers" -o "${TMP_DIR}/soft_b.json" -w '%{http_code}' -H "X-Ontos-Service-Auth: ${SERVICE_SECRET}" -H "X-Ontogit-User: ${BASIC_USER}" -H 'Content-Type: application/json' -d '{"title":"soft-b","body":"soft-b"}' "${BASE_URL}/commit")"
[ "${code}" = "200" ] || { echo "soft second request expected 200, got ${code}"; exit 1; }
rg -qi '^X-Ontogit-Warn:.*quota_exceeded' "${TMP_DIR}/soft_b.headers" || { echo "missing quota_exceeded warn in soft mode"; cat "${TMP_DIR}/soft_b.headers"; exit 1; }

echo "==> hard mode check: second basic request returns 429"
HARD_USER="policy_hard_${TS}"
maybe_recreate hard memory-service
wait_http "${BASE_URL}/health"

code="$(curl -s -o "${TMP_DIR}/hard_a.json" -w '%{http_code}' -H "X-Ontos-Service-Auth: ${SERVICE_SECRET}" -H "X-Ontogit-User: ${HARD_USER}" -H 'Content-Type: application/json' -d '{"title":"hard-a","body":"hard-a"}' "${BASE_URL}/commit")"
[ "${code}" = "200" ] || { echo "hard first request expected 200, got ${code}"; exit 1; }
code="$(curl -s -o "${TMP_DIR}/hard_b.json" -w '%{http_code}' -H "X-Ontos-Service-Auth: ${SERVICE_SECRET}" -H "X-Ontogit-User: ${HARD_USER}" -H 'Content-Type: application/json' -d '{"title":"hard-b","body":"hard-b"}' "${BASE_URL}/commit")"
[ "${code}" = "429" ] || { echo "hard second request expected 429, got ${code}"; exit 1; }
rg -q '"error":"quota_exceeded"' "${TMP_DIR}/hard_b.json" || { echo "hard mode 429 body missing quota_exceeded"; cat "${TMP_DIR}/hard_b.json"; exit 1; }

echo "OK: smoke_policy passed"
