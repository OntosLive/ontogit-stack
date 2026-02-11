#!/usr/bin/env bash
set -euo pipefail

MSG="${1:-autofix-v2 pre-change savepoint}"
TS="$(date +%Y-%m-%d_%H%M%S)"
OUT_BASE="/home/ontoslive/ontogit/ops/state"
OUT="${OUT_BASE}/${TS}-checkpoint"
LATEST_POINTER_FILE="${OUT_BASE}/LATEST_POINTER.txt"

STACK_REPO="/home/ontoslive/ontos_work/ontogit-stack"
WEBUI_REPO="/home/ontoslive/ontos_work/open-webui-src"
USAGE_DB="/home/ontoslive/ontos_data/ontogit-user/usage.db"
WEBUI_DB_BASE="/home/ontoslive/ontos_data/openwebui-data/webui.db"

mkdir -p "${OUT}"
mkdir -p "${OUT}/repos/ontogit-stack" "${OUT}/repos/open-webui-src" "${OUT}/data"

copy_repo_files() {
  local repo="$1"
  local repo_name="$2"
  shift 2
  local list_file="${OUT}/repos/${repo_name}/files.list"
  : > "${list_file}"

  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    echo "${rel}" >> "${list_file}"
    mkdir -p "${OUT}/repos/${repo_name}/$(dirname "${rel}")"
    cp -a "${repo}/${rel}" "${OUT}/repos/${repo_name}/${rel}"
  done < <(git -C "${repo}" ls-files -- "$@")
}

copy_repo_files "${STACK_REPO}" "ontogit-stack" \
  docker-compose.yml \
  START_HERE.md \
  docs/ONTOGIT_CANON.md \
  scripts

copy_repo_files "${WEBUI_REPO}" "open-webui-src" \
  docker-compose.yaml \
  docker-compose.dev.yaml \
  docs/ONTOGIT_CANON.md

if [ -f "${USAGE_DB}" ]; then
  cp -a "${USAGE_DB}" "${OUT}/data/usage.db"
fi

if [ -f "${WEBUI_DB_BASE}" ]; then
  cp -a "${WEBUI_DB_BASE}" "${OUT}/data/webui.db"
fi
if [ -f "${WEBUI_DB_BASE}-wal" ]; then
  cp -a "${WEBUI_DB_BASE}-wal" "${OUT}/data/webui.db-wal"
fi
if [ -f "${WEBUI_DB_BASE}-shm" ]; then
  cp -a "${WEBUI_DB_BASE}-shm" "${OUT}/data/webui.db-shm"
fi

cat > "${OUT}/MANIFEST.txt" <<EOF
message=${MSG}
timestamp=${TS}
boot_pointer=${OUT}
ontogit_stack_sha=$(git -C "${STACK_REPO}" rev-parse HEAD 2>/dev/null || echo "n/a")
open_webui_sha=$(git -C "${WEBUI_REPO}" rev-parse HEAD 2>/dev/null || echo "n/a")
usage_db_saved=$( [ -f "${OUT}/data/usage.db" ] && echo "yes" || echo "no" )
webui_db_saved=$( [ -f "${OUT}/data/webui.db" ] && echo "yes" || echo "no" )
EOF

printf '%s\n' "${OUT}" > "${LATEST_POINTER_FILE}"

echo "[SAVE_LOCAL] checkpoint created: ${OUT}"
echo "[SAVE_LOCAL] latest pointer updated: ${LATEST_POINTER_FILE}"
echo "[SAVE_LOCAL] saved repo files:"
echo "  - ${OUT}/repos/ontogit-stack/files.list"
echo "  - ${OUT}/repos/open-webui-src/files.list"
echo "[SAVE_LOCAL] saved data:"
if [ -f "${OUT}/data/usage.db" ]; then echo "  - usage.db"; else echo "  - usage.db (not present)"; fi
if [ -f "${OUT}/data/webui.db" ]; then echo "  - webui.db (+wal/shm if present)"; else echo "  - webui.db (not present)"; fi
echo "BOOT_POINTER=${OUT}"
