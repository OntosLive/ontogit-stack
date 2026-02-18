#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
COMPOSE_FILE="${STACK_DIR}/docker-compose.webui-ontogate.yml"
EXPECTED_DATA_DIR="${OPENWEBUI_DATA_DIR_EXPECTED:-/home/ontoslive/ontos_data/openwebui-data-vps-current}"
TS="$(date +%Y%m%d_%H%M%S)"
STATE_DIR="${STACK_DIR}/ops/state/${TS}_stt_guard"
LOG_FILE="${STATE_DIR}/stt_guard.log"

mkdir -p "${STATE_DIR}"

log() {
  echo "stt_guard: $*" | tee -a "${LOG_FILE}"
}

die() {
  echo "stt_guard: FAIL: $*" | tee -a "${LOG_FILE}" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

need_cmd sqlite3

if [ -f "${STACK_DIR}/.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${STACK_DIR}/.env.local"
  set +a
fi
if [ -f "${STACK_DIR}/.env.stt" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${STACK_DIR}/.env.stt"
  set +a
fi

CANON_ENGINE="${ALBA_STT_ENGINE_CANON:-}"
CANON_MODEL="${ALBA_STT_MODEL:-medium}"
CANON_BEAM="${ALBA_STT_BEAM:-5}"
CANON_BEST_OF="${ALBA_STT_BEST_OF:-3}"
CANON_TEMPERATURE="${WHISPER_TEMPERATURE:-0.0}"
CANON_VAD_RAW="${WHISPER_VAD_FILTER:-false}"
CANON_SUPPORTED_TYPES='["audio/webm","audio/webm;codecs=opus","audio/wav","audio/mpeg","audio/mp4","audio/ogg","video/webm"]'

CANON_VAD_BOOL=0
case "${CANON_VAD_RAW,,}" in
  1|true|yes|on) CANON_VAD_BOOL=1 ;;
esac

if [ ! -f "${COMPOSE_FILE}" ]; then
  die "compose file not found: ${COMPOSE_FILE}"
fi

WEBUI_DATA_DIR="$(
  awk '
    /\/app\/backend\/data/ {
      line=$0
      sub(/^[[:space:]-]+/, "", line)
      sub(/:.*/, "", line)
      print line
      exit
    }
  ' "${COMPOSE_FILE}"
)"
[ -n "${WEBUI_DATA_DIR}" ] || die "cannot resolve /app/backend/data mount from compose file"

if [ "${WEBUI_DATA_DIR}" != "${EXPECTED_DATA_DIR}" ]; then
  die "unexpected OpenWebUI data dir: ${WEBUI_DATA_DIR} (expected ${EXPECTED_DATA_DIR})"
fi

DB_PATH="${WEBUI_DATA_DIR}/webui.db"
[ -f "${DB_PATH}" ] || die "webui.db not found: ${DB_PATH}"

log "db=${DB_PATH}"
log "compose_data_dir=${WEBUI_DATA_DIR}"
log "canon_engine='${CANON_ENGINE}' canon_model=${CANON_MODEL} canon_beam=${CANON_BEAM} canon_best_of=${CANON_BEST_OF} canon_temp=${CANON_TEMPERATURE} canon_vad=${CANON_VAD_BOOL}"

CONFIG_COUNT="$(sqlite3 "${DB_PATH}" "select count(*) from config;")"
if [ "${CONFIG_COUNT}" = "0" ]; then
  log "config row missing; creating default row"
  sqlite3 "${DB_PATH}" "insert into config(data,version,created_at,updated_at) values(json('{}'),0,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP);"
fi

CURRENT_ENGINE="$(sqlite3 "${DB_PATH}" "select coalesce(json_extract(data,'$.audio.stt.engine'),'') from config order by id desc limit 1;")"
log "current_engine='${CURRENT_ENGINE}'"

if [ -z "${CURRENT_ENGINE}" ]; then
  log "applying canonical local whisper STT fields because engine is empty"
  sqlite3 "${DB_PATH}" "
    update config
    set
      data = json_set(
        coalesce(data, json('{}')),
        '\$.audio.stt.engine', '${CANON_ENGINE}',
        '\$.audio.stt.whisper_model', '${CANON_MODEL}',
        '\$.audio.stt.whisper_vad_filter', json('${CANON_VAD_BOOL}'),
        '\$.audio.stt.whisper_beam_size', ${CANON_BEAM},
        '\$.audio.stt.whisper_best_of', ${CANON_BEST_OF},
        '\$.audio.stt.whisper_temperature', ${CANON_TEMPERATURE},
        '\$.audio.stt.supported_content_types', json('${CANON_SUPPORTED_TYPES}')
      ),
      updated_at = CURRENT_TIMESTAMP
    where id = (select id from config order by id desc limit 1);
  "
else
  log "engine is non-empty; leaving persisted provider untouched"
fi

WEB_OVERRIDE_COUNT="$(sqlite3 "${DB_PATH}" "select count(*) from user where json_extract(settings,'$.ui.audio.stt.engine')='web';")"
if [ "${WEB_OVERRIDE_COUNT}" -gt 0 ]; then
  log "removing per-user web STT overrides: count=${WEB_OVERRIDE_COUNT}"
  sqlite3 "${DB_PATH}" "
    update user
    set
      settings = json_remove(settings, '\$.ui.audio.stt.engine'),
      updated_at = strftime('%s','now')
    where json_extract(settings,'$.ui.audio.stt.engine')='web';
  "
else
  log "no per-user web STT overrides found"
fi

sqlite3 "${DB_PATH}" "
  select
    datetime(updated_at),
    coalesce(json_extract(data,'$.audio.stt.engine'),''),
    coalesce(json_extract(data,'$.audio.stt.whisper_model'),''),
    coalesce(json_extract(data,'$.audio.stt.whisper_vad_filter'),''),
    coalesce(json_extract(data,'$.audio.stt.whisper_beam_size'),''),
    coalesce(json_extract(data,'$.audio.stt.whisper_best_of'),''),
    coalesce(json_extract(data,'$.audio.stt.whisper_temperature'),'')
  from config
  order by id desc
  limit 1;
" | sed -n '1p' | awk -F'|' '{
  printf "stt_guard: final updated_at=%s engine=%s model=%s vad=%s beam=%s best_of=%s temp=%s\n", $1, $2, $3, $4, $5, $6, $7
}' | tee -a "${LOG_FILE}"

echo "OK"
echo "state_dir=${STATE_DIR}"
