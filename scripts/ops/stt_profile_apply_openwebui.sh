#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
OUTDIR="${OUTDIR:-${STACK_DIR}/ops/state/${TS}_stt_apply}"
LOG_FILE="${OUTDIR}/apply.log"

mkdir -p "${OUTDIR}"

echo "stt_profile_apply_openwebui: ts=${TS}" | tee -a "${LOG_FILE}"

MODEL_ARG="${1:-}"
MODEL="${MODEL_ARG:-${ALBA_STT_MODEL:-}}"
if [ -z "${MODEL}" ]; then
  echo "ERROR: model not set (pass as arg or set ALBA_STT_MODEL)" | tee -a "${LOG_FILE}" >&2
  exit 2
fi

DB_PATH=""
if [ -n "${WEBUI_DB:-}" ]; then
  DB_PATH="${WEBUI_DB}"
elif [ -n "${OPENWEBUI_DATA_DIR:-}" ]; then
  DB_PATH="${OPENWEBUI_DATA_DIR}/webui.db"
else
  COMPOSE_FILE="${STACK_DIR}/docker-compose.webui-ontogate.yml"
  if [ -f "${COMPOSE_FILE}" ]; then
    line="$(grep -E ':/app/backend/data' "${COMPOSE_FILE}" | head -n 1 || true)"
    if [ -n "${line}" ]; then
      host_path="$(echo "${line}" | sed -E 's/^[[:space:]-]*//; s/:.*$//')"
      DB_PATH="${host_path}/webui.db"
    fi
  fi
fi

if [ -z "${DB_PATH}" ] || [ ! -f "${DB_PATH}" ]; then
  echo "ERROR: webui.db not found (set WEBUI_DB or OPENWEBUI_DATA_DIR)" | tee -a "${LOG_FILE}" >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "ERROR: sqlite3 not found" | tee -a "${LOG_FILE}" >&2
  exit 1
fi

DB_BAK="${DB_PATH}.bak.${TS}"
cp -a "${DB_PATH}" "${DB_BAK}"

echo "db=${DB_PATH}" | tee -a "${LOG_FILE}"
echo "db_backup=${DB_BAK}" | tee -a "${LOG_FILE}"

TABLE=""
for t in configs config settings; do
  if sqlite3 "${DB_PATH}" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='${t}';" | grep -q 1; then
    TABLE="${t}"
    break
  fi
done

if [ -z "${TABLE}" ]; then
  echo "ERROR: no configs table found" | tee -a "${LOG_FILE}" >&2
  exit 1
fi

COLS="$(sqlite3 "${DB_PATH}" "PRAGMA table_info(${TABLE});" | awk -F'|' '{print $2}' | tr '\n' ' ')"
if ! echo "${COLS}" | grep -qw key; then
  echo "ERROR: ${TABLE} has no 'key' column" | tee -a "${LOG_FILE}" >&2
  exit 1
fi
if ! echo "${COLS}" | grep -qw value; then
  echo "ERROR: ${TABLE} has no 'value' column" | tee -a "${LOG_FILE}" >&2
  exit 1
fi

KEY="audio.stt.whisper_model"
MODEL_ESC="${MODEL//\'/\'\'}"
OLD="$(sqlite3 "${DB_PATH}" "SELECT value FROM ${TABLE} WHERE key='${KEY}' LIMIT 1;")"

if [ -z "${OLD}" ]; then
  sqlite3 "${DB_PATH}" "INSERT INTO ${TABLE} (key, value) VALUES ('${KEY}', '${MODEL_ESC}');"
  ACTION="insert"
else
  sqlite3 "${DB_PATH}" "UPDATE ${TABLE} SET value='${MODEL_ESC}' WHERE key='${KEY}';"
  ACTION="update"
fi

NEW="$(sqlite3 "${DB_PATH}" "SELECT value FROM ${TABLE} WHERE key='${KEY}' LIMIT 1;")"

echo "key=${KEY}" | tee -a "${LOG_FILE}"
echo "action=${ACTION}" | tee -a "${LOG_FILE}"
echo "old=${OLD}" | tee -a "${LOG_FILE}"
echo "new=${NEW}" | tee -a "${LOG_FILE}"

echo "OK" | tee -a "${LOG_FILE}"
