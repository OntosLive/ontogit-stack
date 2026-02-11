#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
POLICY_HOST_PATH="/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml"
OPENWEBUI_BASE_URL="${OPENWEBUI_BASE_URL:-http://127.0.0.1:3000}"
OPENWEBUI_ADMIN_TOKEN="${OPENWEBUI_ADMIN_TOKEN:-}"
USER_ID="${USER_ID:-}"
USER_EMAIL="${USER_EMAIL:-}"
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

resolve_user_id_by_email() {
  local email="$1"
  local whereami_out=""
  local data_mount=""
  local db_path=""
  whereami_out="$("${STACK_DIR}/scripts/ow_whereami.sh" 2>/dev/null || true)"
  data_mount="$(printf '%s\n' "${whereami_out}" | awk -F': ' '/^data_mount_host_path:/{print $2; exit}')"
  if [ -z "${data_mount}" ]; then
    echo "Could not detect OpenWebUI data mount via ./scripts/ow_whereami.sh"
    return 1
  fi
  db_path="${data_mount}/webui.db"
  if [ ! -f "${db_path}" ]; then
    echo "OpenWebUI DB not found at ${db_path}"
    return 1
  fi
  python3 - "${db_path}" "${email}" <<'PY'
import sqlite3, sys
db_path, email = sys.argv[1], sys.argv[2]
try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("SELECT id FROM user WHERE email = ? LIMIT 1", (email,))
    row = cur.fetchone()
    con.close()
    print((row[0] if row and row[0] else ""))
except Exception:
    print("")
PY
}

ROLE_FETCH_METHOD=""
ROLE_FETCH_HTTP_CODE=""
ROLE_FETCH_BODY=""
ROLE_FETCH_CONTAINER=""
ROLE_FETCH_RC=""
ROLE_FETCH_STDERR=""

_select_docker_role_fetch_container() {
  local name=""
  name="$($DOCKER_CMD ps --format '{{.Names}}' | awk '$0=="ontogit-stack-usage-writer-1"{print; exit}')"
  if [ -n "${name}" ]; then
    echo "${name}"
    return 0
  fi
  name="$($DOCKER_CMD ps --format '{{.Names}}' | awk '$0=="ontogit-stack-memory-service-1"{print; exit}')"
  if [ -n "${name}" ]; then
    echo "${name}"
    return 0
  fi
  name="$($DOCKER_CMD ps --format '{{.Names}}' | awk '$0=="ontogit-stack-header-injector-1"{print; exit}')"
  if [ -n "${name}" ]; then
    echo "${name}"
    return 0
  fi
  return 1
}

_role_fetch_docker() {
  local role_url="$1"
  local container_name=""
  local body_file="${TMP_DIR}/role_fetch_docker_body.$$"
  local err_file="${TMP_DIR}/role_fetch_docker_err.$$"
  local rc=0
  container_name="$(_select_docker_role_fetch_container || true)"
  if [ -z "${container_name}" ]; then
    ROLE_FETCH_BODY=""
    ROLE_FETCH_CONTAINER=""
    return 1
  fi
  ROLE_FETCH_CONTAINER="${container_name}"
  $DOCKER_CMD exec \
    -e ROLE_URL="${role_url}" \
    -e ONTOS_SERVICE_AUTH_SECRET="${SERVICE_SECRET}" \
    -e USER_ID="${USER_ID}" \
    "${container_name}" \
    python3 - <<'PY' > "${body_file}" 2> "${err_file}" || rc=$?
import os, urllib.request, sys
url = os.environ["ROLE_URL"]
req = urllib.request.Request(url, headers={
  "X-Ontos-Service-Auth": os.environ["ONTOS_SERVICE_AUTH_SECRET"],
  "X-OpenWebUI-User-Id": os.environ["USER_ID"],
})
try:
  with urllib.request.urlopen(req, timeout=10) as r:
    body = r.read().decode("utf-8", "replace")
    print(body)
except Exception:
  print("", end="")
  sys.exit(2)
PY
  if [ "${rc}" -ne 0 ]; then
    ROLE_FETCH_BODY=""
    ROLE_FETCH_HTTP_CODE="docker_exec_${rc}"
    ROLE_FETCH_RC="${rc}"
    ROLE_FETCH_STDERR="$(head -c 200 "${err_file}" 2>/dev/null || true)"
    return 1
  fi
  ROLE_FETCH_BODY="$(cat "${body_file}" 2>/dev/null || true)"
  ROLE_FETCH_RC="0"
  ROLE_FETCH_STDERR=""
  return 0
}

get_role_json() {
  local role_url="http://open-webui:8080/api/v1/ontogit/user_role"

  ROLE_FETCH_METHOD=""
  ROLE_FETCH_HTTP_CODE=""
  ROLE_FETCH_BODY=""
  ROLE_FETCH_CONTAINER=""
  ROLE_FETCH_RC=""
  ROLE_FETCH_STDERR=""

  ROLE_FETCH_METHOD="docker"
  _role_fetch_docker "${role_url}"
  if [ -n "${ROLE_FETCH_BODY}" ]; then
    ROLE_FETCH_HTTP_CODE="${ROLE_FETCH_HTTP_CODE:-n/a}"
    return 0
  fi
  return 1
}

print_role_diag_and_exit() {
  local preview=""
  preview="$(printf '%s' "${ROLE_FETCH_BODY:-}" | head -c 300)"
  echo "Failed to resolve role from OpenWebUI"
  echo "diag.OPENWEBUI_BASE_URL=${OPENWEBUI_BASE_URL}"
  echo "diag.method=${ROLE_FETCH_METHOD:-unknown}"
  echo "diag.container=${ROLE_FETCH_CONTAINER:-n/a}"
  echo "diag.http_code=${ROLE_FETCH_HTTP_CODE:-n/a}"
  if [ -n "${ROLE_FETCH_RC:-}" ]; then
    echo "diag.rc=${ROLE_FETCH_RC}"
  fi
  if [ -n "${ROLE_FETCH_STDERR:-}" ]; then
    echo "diag.stderr_preview=${ROLE_FETCH_STDERR}"
  fi
  echo "diag.body_preview=${preview}"
  echo "hint: curl -i http://127.0.0.1:3000/api/v1/ontogit/user_role"
  exit 1
}

parse_limits_line() {
  local raw="$1"
  python3 - "${raw}" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    d = json.loads(raw or "{}")
except Exception:
    print("")
    sys.exit(0)
role = d.get("role", "")
limit = d.get("limit_usd", "")
if not isinstance(role, str):
    role = ""
print(f"{role} {limit}")
PY
}

has_limit_usd() {
  local raw="$1"
  python3 - "${raw}" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    d = json.loads(raw or "{}")
except Exception:
    print("0")
    sys.exit(0)
print("1" if "limit_usd" in d else "0")
PY
}

wait_limits_json() {
  local user_id="$1"
  local out=""
  local ok="0"
  local i=1
  while [ "${i}" -le 25 ]; do
    out="$(curl -sS --retry 2 --retry-delay 1 --retry-connrefused --max-time 10 "http://127.0.0.1:8091/limits/${user_id}" || true)"
    ok="$(has_limit_usd "${out}")"
    if [ "${ok}" = "1" ]; then
      printf '%s' "${out}"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  printf '%s' "${out}"
  return 1
}

if [ -z "${USER_ID}" ] && [ -n "${USER_EMAIL}" ]; then
  USER_ID="$(resolve_user_id_by_email "${USER_EMAIL}")"
  if [ -z "${USER_ID}" ]; then
    echo "Could not resolve USER_ID from USER_EMAIL=${USER_EMAIL}"
    echo "Hint: verify email exists in current OpenWebUI universe and rerun."
    exit 1
  fi
fi
if [ -z "${USER_ID}" ] && [ -n "${OPENWEBUI_ADMIN_TOKEN}" ]; then
  AUTHS_JSON="$(curl -sS --retry 10 --retry-delay 1 --retry-connrefused --max-time 10 \
    -H "Authorization: Bearer ${OPENWEBUI_ADMIN_TOKEN}" \
    "${OPENWEBUI_BASE_URL}/api/v1/auths/" || true)"
  USER_ID="$(python3 - "${AUTHS_JSON}" <<'PY'
import json, sys
raw = sys.argv[1]
try:
    data = json.loads(raw or "{}")
except Exception:
    print("")
    sys.exit(0)
print((data or {}).get("id", ""))
PY
)"
fi
if [ -z "${USER_ID}" ]; then
  echo "Provide USER_ID=<openwebui-user-uuid>, USER_EMAIL=<email>, or OPENWEBUI_ADMIN_TOKEN"
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

if ! get_role_json; then
  print_role_diag_and_exit
fi
ROLE_JSON="${ROLE_FETCH_BODY}"
ROLE="$(python3 - "${ROLE_JSON}" <<'PY'
import json,sys
raw = sys.argv[1]
try:
    data = json.loads(raw or "{}")
except Exception:
    print("")
    sys.exit(0)
role = (data or {}).get("role", "")
print(role if isinstance(role, str) else "")
PY
)"
if [ -z "${ROLE}" ]; then
  print_role_diag_and_exit
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
LIMITS_ROLE_ON_JSON="$(wait_limits_json "${USER_ID}" || true)"
LIMITS_ROLE_ON="$(parse_limits_line "${LIMITS_ROLE_ON_JSON}")"
if [ -z "${LIMITS_ROLE_ON}" ] || [ "$(has_limit_usd "${LIMITS_ROLE_ON_JSON}")" != "1" ]; then
  echo "Failed to parse /limits response with ROLE_SOURCE enabled"
  echo "diag.body_preview=$(printf '%s' "${LIMITS_ROLE_ON_JSON}" | head -c 300)"
  exit 1
fi
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
LIMITS_ROLE_OFF_JSON="$(wait_limits_json "${USER_ID}" || true)"
LIMITS_ROLE_OFF="$(parse_limits_line "${LIMITS_ROLE_OFF_JSON}")"
if [ -z "${LIMITS_ROLE_OFF}" ] || [ "$(has_limit_usd "${LIMITS_ROLE_OFF_JSON}")" != "1" ]; then
  echo "Failed to parse /limits response with ROLE_SOURCE disabled"
  echo "diag.body_preview=$(printf '%s' "${LIMITS_ROLE_OFF_JSON}" | head -c 300)"
  exit 1
fi
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
