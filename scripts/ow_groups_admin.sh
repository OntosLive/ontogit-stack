#!/usr/bin/env bash
set -euo pipefail

OPENWEBUI_BASE_URL="${OPENWEBUI_BASE_URL:-http://127.0.0.1:3000}"
ADMIN_TOKEN="${OPENWEBUI_ADMIN_TOKEN:-}"
ASSIGN_ROLE="${ASSIGN_ROLE:-}"
ASSIGN_USER_ID="${ASSIGN_USER_ID:-}"
ASSIGN_EMAIL="${ASSIGN_EMAIL:-}"

if [ -z "${ADMIN_TOKEN}" ]; then
  echo "Missing OPENWEBUI_ADMIN_TOKEN"
  exit 1
fi

api_get() {
  curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${OPENWEBUI_BASE_URL}$1"
}

api_post() {
  local path="$1"
  local body="$2"
  curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" -H 'Content-Type: application/json' -d "${body}" "${OPENWEBUI_BASE_URL}${path}"
}

GROUPS_JSON="$(api_get /api/v1/groups/)"

ensure_group() {
  local name="$1"
  local id
  id="$(python3 - "$name" <<'PY'
import json,sys
name=sys.argv[1]
obj=json.loads(sys.stdin.read() or '[]')
for g in obj:
    if str(g.get('name','')).strip()==name:
        print(g.get('id',''))
        break
PY
<<<"${GROUPS_JSON}")"
  if [ -n "${id}" ]; then
    echo "group ${name}: exists (${id})"
    return 0
  fi
  api_post /api/v1/groups/create "{\"name\":\"${name}\",\"description\":\"\"}" >/dev/null
  GROUPS_JSON="$(api_get /api/v1/groups/)"
  id="$(python3 - "$name" <<'PY'
import json,sys
name=sys.argv[1]
obj=json.loads(sys.stdin.read() or '[]')
for g in obj:
    if str(g.get('name','')).strip()==name:
        print(g.get('id',''))
        break
PY
<<<"${GROUPS_JSON}")"
  if [ -z "${id}" ]; then
    echo "Failed to create group: ${name}"
    exit 1
  fi
  echo "group ${name}: created (${id})"
}

ensure_group basic
ensure_group pro
ensure_group admin

if [ -n "${ASSIGN_ROLE}" ]; then
  case "${ASSIGN_ROLE}" in
    basic|pro|admin) ;;
    *) echo "ASSIGN_ROLE must be one of: basic, pro, admin"; exit 1 ;;
  esac

  if [ -z "${ASSIGN_USER_ID}" ] && [ -n "${ASSIGN_EMAIL}" ]; then
    USERS_JSON="$(api_get /api/v1/users/all)"
    ASSIGN_USER_ID="$(python3 - "${ASSIGN_EMAIL}" <<'PY'
import json,sys
email=sys.argv[1].lower()
obj=json.loads(sys.stdin.read() or '[]')
for u in obj:
    if str(u.get('email','')).lower()==email:
        print(u.get('id',''))
        break
PY
<<<"${USERS_JSON}")"
  fi

  if [ -z "${ASSIGN_USER_ID}" ]; then
    echo "Provide ASSIGN_USER_ID or ASSIGN_EMAIL when ASSIGN_ROLE is set"
    exit 1
  fi

  GROUP_ID="$(python3 - "${ASSIGN_ROLE}" <<'PY'
import json,sys
name=sys.argv[1]
obj=json.loads(sys.stdin.read() or '[]')
for g in obj:
    if str(g.get('name','')).strip()==name:
        print(g.get('id',''))
        break
PY
<<<"${GROUPS_JSON}")"

  if [ -z "${GROUP_ID}" ]; then
    echo "Target group not found: ${ASSIGN_ROLE}"
    exit 1
  fi

  api_post "/api/v1/groups/id/${GROUP_ID}/users/add" "{\"user_ids\":[\"${ASSIGN_USER_ID}\"]}" >/dev/null
  echo "assigned user ${ASSIGN_USER_ID} -> ${ASSIGN_ROLE} (${GROUP_ID})"
fi

echo "OK"
