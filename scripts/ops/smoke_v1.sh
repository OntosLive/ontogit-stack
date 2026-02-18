#!/usr/bin/env bash
set -uo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
TS="$(date +%Y%m%d_%H%M%S)"
STATE_DIR="${STACK_DIR}/ops/state/${TS}_smoke_v1"
DETAILS_LOG="${STATE_DIR}/details.log"
SUMMARY_FILE="${STATE_DIR}/summary.txt"

mkdir -p "${STATE_DIR}"
touch "${DETAILS_LOG}"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SUMMARY_LINES=()

COMPOSE_CMD=(docker compose)
COMPOSE_FILES=(-f "${STACK_DIR}/docker-compose.yml" -f "${STACK_DIR}/docker-compose.webui-ontogate.yml")

log() {
  printf '%s\n' "$*" | tee -a "${DETAILS_LOG}" >/dev/null
}

add_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  SUMMARY_LINES+=("PASS | $1")
}

add_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  SUMMARY_LINES+=("FAIL | $1")
}

add_warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  SUMMARY_LINES+=("WARN | $1")
}

run_step() {
  local label="$1"
  shift
  local tmp_out
  tmp_out="$(mktemp)"
  log ""
  log "===== ${label} ====="
  log "CMD: $*"
  if "$@" >"${tmp_out}" 2>&1; then
    cat "${tmp_out}" >>"${DETAILS_LOG}"
    rm -f "${tmp_out}"
    add_pass "${label}"
    return 0
  fi
  cat "${tmp_out}" >>"${DETAILS_LOG}"
  if [[ "${label}" == "bash scripts/health.sh" ]] && rg -qi "docker daemon is not accessible|cannot connect to the docker daemon|permission denied while trying to connect to the docker daemon|docker daemon is not running" "${tmp_out}"; then
    rm -f "${tmp_out}"
    add_warn "${label} (docker daemon unavailable)"
    return 0
  fi
  rm -f "${tmp_out}"
  add_fail "${label}"
  return 1
}

resolve_webui_db() {
  if [ -n "${WEBUI_DB:-}" ] && [ -f "${WEBUI_DB}" ]; then
    printf '%s\n' "${WEBUI_DB}"
    return 0
  fi

  if [ -n "${OPENWEBUI_DATA_DIR:-}" ] && [ -f "${OPENWEBUI_DATA_DIR}/webui.db" ]; then
    printf '%s\n' "${OPENWEBUI_DATA_DIR}/webui.db"
    return 0
  fi

  local compose_file="${STACK_DIR}/docker-compose.webui-ontogate.yml"
  if [ -f "${compose_file}" ]; then
    local mount_dir=""
    mount_dir="$(
      awk '
        /\/app\/backend\/data/ {
          line=$0
          sub(/^[[:space:]-]+/, "", line)
          sub(/:.*/, "", line)
          print line
          exit
        }
      ' "${compose_file}"
    )"
    if [ -n "${mount_dir}" ] && [ -f "${mount_dir}/webui.db" ]; then
      printf '%s\n' "${mount_dir}/webui.db"
      return 0
    fi
  fi

  local fallback="/home/ontoslive/ontos_data/openwebui-data-vps-current/webui.db"
  if [ -f "${fallback}" ]; then
    printf '%s\n' "${fallback}"
    return 0
  fi

  return 1
}

run_stt_checks() {
  local db_path="$1"
  log ""
  log "===== STT DB Checks ====="
  log "DB: ${db_path}"

  if ! command -v sqlite3 >/dev/null 2>&1; then
    add_fail "sqlite3 is required for DB checks"
    return 1
  fi

  local db_model compose_model compose_beam compose_best_of compose_vad
  local compose_cfg openwebui_env_lines
  db_model="$(sqlite3 "${db_path}" "select coalesce(json_extract(data,'$.audio.stt.whisper_model'),'') from config where id=1 limit 1;" 2>>"${DETAILS_LOG}" || true)"

  compose_cfg="$("${COMPOSE_CMD[@]}" "${COMPOSE_FILES[@]}" config 2>>"${DETAILS_LOG}" || true)"
  if [ -z "${compose_cfg}" ]; then
    add_fail "Cannot read docker compose config for open-webui environment"
    return 1
  fi

  openwebui_env_lines="$(
    awk '
      function ltrim(s){ sub(/^[ \t]+/, "", s); return s }
      function indent(s){ match(s, /^[ ]*/); return RLENGTH }
      {
        line=$0
        ind=indent(line)

        if (!in_open && line ~ /^[[:space:]]*open-webui:[[:space:]]*$/) {
          in_open=1
          open_indent=ind
          next
        }

        if (in_open && ind <= open_indent && line ~ /^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*$/) {
          in_open=0
        }

        if (in_open && !in_env && line ~ /^[[:space:]]*environment:[[:space:]]*$/) {
          in_env=1
          env_indent=ind
          next
        }

        if (in_open && in_env && ind <= env_indent && line ~ /^[[:space:]]*[A-Za-z0-9_.-]+:/) {
          in_env=0
        }

        if (in_open && in_env) {
          print ltrim(line)
        }
      }
    ' <<< "${compose_cfg}"
  )"

  parse_compose_env_value() {
    local key="$1"
    local value=""
    value="$(
      awk -v k="${key}" '
        {
          line=$0
          if (match(line, "^- *" k "=(.*)$", m)) {
            print m[1]
            exit
          }
          if (match(line, "^" k ":[[:space:]]*(.*)$", m)) {
            print m[1]
            exit
          }
        }
      ' <<< "${openwebui_env_lines}"
    )"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s' "${value}"
  }

  compose_model="$(parse_compose_env_value "WHISPER_MODEL")"
  compose_beam="$(parse_compose_env_value "WHISPER_BEAM_SIZE")"
  compose_best_of="$(parse_compose_env_value "WHISPER_BEST_OF")"
  compose_vad="$(parse_compose_env_value "WHISPER_VAD_FILTER")"
  if [ -z "${compose_vad}" ]; then
    compose_vad="0"
  fi

  log "db_model=${db_model}"
  log "compose_model=${compose_model}"
  log "compose_beam=${compose_beam}"
  log "compose_best_of=${compose_best_of}"
  log "compose_vad=${compose_vad}"

  local users_web_count=0
  if sqlite3 "${db_path}" "select name from sqlite_master where type='table' and name='user';" | rg -qx "user"; then
    users_web_count="$(sqlite3 "${db_path}" "select count(*) from user where json_extract(settings,'$.ui.audio.stt.engine')='web';" 2>>"${DETAILS_LOG}" || echo 0)"
    log "table=user web_override_count=${users_web_count}"
  elif sqlite3 "${db_path}" "select name from sqlite_master where type='table' and name='users';" | rg -qx "users"; then
    users_web_count="$(sqlite3 "${db_path}" "select count(*) from users where json_extract(settings,'$.ui.audio.stt.engine')='web';" 2>>"${DETAILS_LOG}" || echo 0)"
    log "table=users web_override_count=${users_web_count}"
  else
    add_fail "Users table not found (expected 'user' or 'users')"
    return 1
  fi

  if [ "${users_web_count}" = "0" ]; then
    add_pass "No users with settings.ui.audio.stt.engine='web'"
  else
    add_fail "Users with settings.ui.audio.stt.engine='web' found: ${users_web_count}"
  fi

  if {
    [ "${db_model}" = "medium" ] || { [ -z "${db_model}" ] && [ "${compose_model}" = "medium" ]; }
  } && [ -n "${compose_beam}" ] && [ -n "${compose_best_of}" ] && [ "${users_web_count}" = "0" ]; then
    add_pass "STT env-first: db_model=${db_model} compose_model=${compose_model} compose_beam=${compose_beam} compose_best_of=${compose_best_of} compose_vad=${compose_vad}"
  else
    add_fail "STT env-first: db_model=${db_model} compose_model=${compose_model} compose_beam=${compose_beam} compose_best_of=${compose_best_of} compose_vad=${compose_vad}"
  fi

  return 0
}

log "smoke_v1 started"
log "state_dir=${STATE_DIR}"

run_step "bash scripts/ops/alba_status.sh" bash "${STACK_DIR}/scripts/ops/alba_status.sh"
run_step "bash scripts/health.sh" bash "${STACK_DIR}/scripts/health.sh"

DB_PATH=""
if DB_PATH="$(resolve_webui_db)"; then
  run_stt_checks "${DB_PATH}"
else
  add_fail "webui.db not found (set WEBUI_DB or OPENWEBUI_DATA_DIR)"
fi

{
  echo "smoke_v1 summary"
  echo "state_dir=${STATE_DIR}"
  echo "details_log=${DETAILS_LOG}"
  echo "timestamp=${TS}"
  echo "pass=${PASS_COUNT}"
  echo "warn=${WARN_COUNT}"
  echo "fail=${FAIL_COUNT}"
  echo ""
  printf '%s\n' "${SUMMARY_LINES[@]}"
} >"${SUMMARY_FILE}"

cat "${SUMMARY_FILE}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
