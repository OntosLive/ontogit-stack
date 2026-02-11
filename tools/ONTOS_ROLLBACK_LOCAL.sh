#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "Usage: $0 <BOOT_POINTER>"
  exit 2
fi

BOOT_POINTER="$1"
RESTORE_DATA="${RESTORE_DATA:-NO}"

STACK_REPO="/home/ontoslive/ontos_work/ontogit-stack"
WEBUI_REPO="/home/ontoslive/ontos_work/open-webui-src"
USAGE_DB_TARGET="/home/ontoslive/ontos_data/ontogit-user/usage.db"
WEBUI_DB_TARGET_BASE="/home/ontoslive/ontos_data/openwebui-data/webui.db"

if [ ! -d "${BOOT_POINTER}" ]; then
  echo "[ROLLBACK] checkpoint not found: ${BOOT_POINTER}"
  exit 1
fi

restore_repo_from_list() {
  local repo="$1"
  local repo_name="$2"
  local list="${BOOT_POINTER}/repos/${repo_name}/files.list"
  local restored=0

  if [ ! -f "${list}" ]; then
    echo "[ROLLBACK] no file list for ${repo_name}"
    return 0
  fi

  while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    local src="${BOOT_POINTER}/repos/${repo_name}/${rel}"
    local dst="${repo}/${rel}"
    if [ ! -f "${src}" ]; then
      continue
    fi
    if git -C "${repo}" ls-files --error-unmatch "${rel}" >/dev/null 2>&1; then
      mkdir -p "$(dirname "${dst}")"
      cp -a "${src}" "${dst}"
      echo "[ROLLBACK] restored ${repo_name}/${rel}"
      restored=$((restored + 1))
    fi
  done < "${list}"

  echo "[ROLLBACK] ${repo_name}: restored ${restored} tracked files"
}

restore_repo_from_list "${STACK_REPO}" "ontogit-stack"
restore_repo_from_list "${WEBUI_REPO}" "open-webui-src"

if [ "${RESTORE_DATA}" = "YES" ]; then
  mkdir -p "$(dirname "${USAGE_DB_TARGET}")" "$(dirname "${WEBUI_DB_TARGET_BASE}")"
  if [ -f "${BOOT_POINTER}/data/usage.db" ]; then
    cp -a "${BOOT_POINTER}/data/usage.db" "${USAGE_DB_TARGET}"
    echo "[ROLLBACK] restored usage.db"
  fi
  if [ -f "${BOOT_POINTER}/data/webui.db" ]; then
    cp -a "${BOOT_POINTER}/data/webui.db" "${WEBUI_DB_TARGET_BASE}"
    echo "[ROLLBACK] restored webui.db"
  fi
  if [ -f "${BOOT_POINTER}/data/webui.db-wal" ]; then
    cp -a "${BOOT_POINTER}/data/webui.db-wal" "${WEBUI_DB_TARGET_BASE}-wal"
    echo "[ROLLBACK] restored webui.db-wal"
  fi
  if [ -f "${BOOT_POINTER}/data/webui.db-shm" ]; then
    cp -a "${BOOT_POINTER}/data/webui.db-shm" "${WEBUI_DB_TARGET_BASE}-shm"
    echo "[ROLLBACK] restored webui.db-shm"
  fi
else
  echo "[ROLLBACK] RESTORE_DATA=NO, skipping usage.db/webui.db restore"
fi

echo "[ROLLBACK] done"
