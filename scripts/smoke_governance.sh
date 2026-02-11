#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
GOV_SMOKE_PRO_EMAIL="${GOV_SMOKE_PRO_EMAIL:-kontrabaobab@yandex.ru}"
GOV_SMOKE_ADMIN_EMAIL="${GOV_SMOKE_ADMIN_EMAIL:-test@test.ru}"
GOV_SMOKE_BASIC_EMAIL="${GOV_SMOKE_BASIC_EMAIL:-}"
SMOKE_NO_RECREATE="${SMOKE_NO_RECREATE:-1}"

echo "==> Governance smoke identities"
echo "pro=${GOV_SMOKE_PRO_EMAIL}"
echo "admin=${GOV_SMOKE_ADMIN_EMAIL}"
if [ -n "${GOV_SMOKE_BASIC_EMAIL}" ]; then
  echo "basic=${GOV_SMOKE_BASIC_EMAIL}"
else
  echo "basic=<skipped>"
fi

get_data_mount() {
  local out=""
  out="$(cd "${STACK_DIR}" && ./scripts/ow_whereami.sh 2>/dev/null || true)"
  printf '%s\n' "${out}" | awk -F': ' '/^data_mount_host_path:/{print $2; exit}'
}

has_group() {
  local db_path="$1"
  local email="$2"
  local group_name="$3"
  python3 - "${db_path}" "${email}" "${group_name}" <<'PY'
import sqlite3, sys
db_path, email, group_name = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute(
        'SELECT COUNT(*) FROM "group" g '
        'JOIN group_member gm ON gm.group_id = g.id '
        'JOIN user u ON u.id = gm.user_id '
        'WHERE lower(u.email)=lower(?) AND g.name=?',
        (email, group_name),
    )
    n = int((cur.fetchone() or [0])[0] or 0)
    con.close()
    print("1" if n > 0 else "0")
except Exception:
    print("0")
PY
}

(
  cd "${STACK_DIR}" && \
  SMOKE_NO_RECREATE="${SMOKE_NO_RECREATE}" USER_EMAIL="${GOV_SMOKE_PRO_EMAIL}" ./scripts/smoke_role_source.sh
)

echo "==> PRECEDENCE (admin > pro > basic) for ${GOV_SMOKE_ADMIN_EMAIL}"
DATA_MOUNT="$(get_data_mount)"
DB_PATH="${DATA_MOUNT}/webui.db"
if [ -n "${DATA_MOUNT}" ] && [ -f "${DB_PATH}" ]; then
  HAS_ADMIN="$(has_group "${DB_PATH}" "${GOV_SMOKE_ADMIN_EMAIL}" "role:admin")"
  HAS_PRO="$(has_group "${DB_PATH}" "${GOV_SMOKE_ADMIN_EMAIL}" "role:pro")"
  if [ "${HAS_ADMIN}" != "1" ] || [ "${HAS_PRO}" != "1" ]; then
    echo "Instruction: in OpenWebUI, add ${GOV_SMOKE_ADMIN_EMAIL} to BOTH groups: role:admin and role:pro"
  fi
else
  echo "Instruction: ensure ${GOV_SMOKE_ADMIN_EMAIL} is in BOTH groups role:admin and role:pro before precedence check"
fi

PRECEDENCE_OUT="$(
  cd "${STACK_DIR}" && \
  SMOKE_NO_RECREATE="${SMOKE_NO_RECREATE}" USER_EMAIL="${GOV_SMOKE_ADMIN_EMAIL}" ./scripts/smoke_role_source.sh
)"
printf '%s\n' "${PRECEDENCE_OUT}"
if ! printf '%s\n' "${PRECEDENCE_OUT}" | rg -q 'role=admin'; then
  echo "Precedence failed: expected role=admin for ${GOV_SMOKE_ADMIN_EMAIL} when in role:admin + role:pro"
  exit 1
fi

(
  cd "${STACK_DIR}" && \
  SMOKE_NO_RECREATE="${SMOKE_NO_RECREATE}" USER_EMAIL="${GOV_SMOKE_ADMIN_EMAIL}" ./scripts/smoke_role_source.sh
)

if [ -n "${GOV_SMOKE_BASIC_EMAIL}" ]; then
  (
    cd "${STACK_DIR}" && \
    SMOKE_NO_RECREATE="${SMOKE_NO_RECREATE}" USER_EMAIL="${GOV_SMOKE_BASIC_EMAIL}" ./scripts/smoke_role_source.sh
  )
fi

echo "GOVERNANCE OK"
