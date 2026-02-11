#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
POLICY_HOST_PATH="/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml"
OPENWEBUI_BASE_URL="${OPENWEBUI_BASE_URL:-http://127.0.0.1:3000}"
OPENWEBUI_ADMIN_TOKEN="${OPENWEBUI_ADMIN_TOKEN:-}"
USER_ID="${USER_ID:-}"
TMP_DIR="/tmp/ontogit_smoke_role_source"
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

ENV_FILE="${STACK_DIR}/.env.local"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

SERVICE_SECRET="${ONTOS_SERVICE_AUTH_SECRET:-}"
if [ -z "${SERVICE_SECRET}" ]; then
  echo "Missing ONTOS_SERVICE_AUTH_SECRET in environment"
  exit 1
fi

if [ -z "${USER_ID}" ] && [ -n "${OPENWEBUI_ADMIN_TOKEN}" ]; then
  USER_ID="$(curl -sS -H "Authorization: Bearer ${OPENWEBUI_ADMIN_TOKEN}" "${OPENWEBUI_BASE_URL}/api/v1/auths/" | python3 -c 'import sys,json; print((json.load(sys.stdin) or {}).get("id", ""))')"
fi
if [ -z "${USER_ID}" ]; then
  echo "Provide USER_ID=<openwebui-user-uuid> (or OPENWEBUI_ADMIN_TOKEN to auto-fetch)"
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
  (
    cd "${STACK_DIR}" && \
    ONTOGIT_ROLE_SOURCE= \
    $DOCKER_CMD compose up -d --force-recreate usage-writer >/dev/null
  ) || true
}
trap cleanup EXIT

cat > "${POLICY_HOST_PATH}" <<'YAML'
version: 1
admin_users: ["admin"]
default_role: "basic"
roles:
  basic:
    daily:
      request_limit: 100
      token_limit: 100000
    monthly:
      limit_usd: 11
      warn_70: 0.7
      warn_90: 0.9
  pro:
    daily:
      request_limit: 200
      token_limit: 200000
    monthly:
      limit_usd: 55
      warn_70: 0.7
      warn_90: 0.9
  admin:
    daily:
      request_limit: 0
      token_limit: 0
    monthly:
      limit_usd: 0
YAML

ROLE_JSON="$(curl -sS -H "X-Ontos-Service-Auth: ${SERVICE_SECRET}" -H "X-OpenWebUI-User-Id: ${USER_ID}" "${OPENWEBUI_BASE_URL}/api/v1/ontogit/user_role")"
ROLE="$(python3 -c 'import sys,json; print((json.load(sys.stdin) or {}).get("role", ""))' <<<"${ROLE_JSON}")"
if [ -z "${ROLE}" ]; then
  echo "Failed to resolve role from OpenWebUI: ${ROLE_JSON}"
  exit 1
fi

FALLBACK_ROLE="pro"
if [ "${ROLE}" = "pro" ]; then
  FALLBACK_ROLE="basic"
fi

curl -sS -X PUT -H 'Content-Type: application/json' \
  -d "{\"role\":\"${FALLBACK_ROLE}\",\"active\":1}" \
  "http://127.0.0.1:8091/users/${USER_ID}" >/dev/null

(
  cd "${STACK_DIR}" && \
  ONTOGIT_ROLE_SOURCE=openwebui \
  OPENWEBUI_BASE_URL=http://open-webui:8080 \
  $DOCKER_CMD compose up -d --force-recreate usage-writer
)

sleep 3
LIMITS_ROLE_ON="$(curl -sS "http://127.0.0.1:8091/limits/${USER_ID}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("role",""), d.get("limit_usd", ""))')"
EXPECTED=""
case "${ROLE}" in
  admin) EXPECTED="0" ;;
  pro) EXPECTED="55" ;;
  *) EXPECTED="11" ;;
esac
ACTUAL_LIMIT_ON="$(awk '{print $2}' <<<"${LIMITS_ROLE_ON}")"
if [ "${ACTUAL_LIMIT_ON}" != "${EXPECTED}" ] && [ "${ACTUAL_LIMIT_ON}" != "${EXPECTED}.0" ]; then
  echo "ROLE_SOURCE enabled mismatch: expected limit ${EXPECTED} from role ${ROLE}, got ${LIMITS_ROLE_ON}"
  exit 1
fi

(
  cd "${STACK_DIR}" && \
  ONTOGIT_ROLE_SOURCE= \
  $DOCKER_CMD compose up -d --force-recreate usage-writer
)

sleep 3
LIMITS_ROLE_OFF="$(curl -sS "http://127.0.0.1:8091/limits/${USER_ID}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("role",""), d.get("limit_usd", ""))')"
EXPECTED_OFF="55"
if [ "${FALLBACK_ROLE}" = "basic" ]; then
  EXPECTED_OFF="11"
fi
ACTUAL_LIMIT_OFF="$(awk '{print $2}' <<<"${LIMITS_ROLE_OFF}")"
if [ "${ACTUAL_LIMIT_OFF}" != "${EXPECTED_OFF}" ] && [ "${ACTUAL_LIMIT_OFF}" != "${EXPECTED_OFF}.0" ]; then
  echo "ROLE_SOURCE disabled mismatch: expected fallback limit ${EXPECTED_OFF}, got ${LIMITS_ROLE_OFF}"
  exit 1
fi

echo "OK: smoke_role_source passed (role=${ROLE}, fallback_role=${FALLBACK_ROLE})"
