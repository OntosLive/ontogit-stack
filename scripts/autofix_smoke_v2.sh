#!/usr/bin/env bash
set -u -o pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
TOOLS_DIR="${STACK_DIR}/tools"
LOG_DIR="${STACK_DIR}/ops/logs"
MARKER_DIR="${STACK_DIR}/ops/state"
LOG_TS="$(date +%Y%m%d_%H%M%S)"
LOG_PATH="${LOG_DIR}/autofix_v2_${LOG_TS}.log"

MAX_ITERS="${MAX_ITERS:-2}"
AUTO_ROLLBACK="${AUTO_ROLLBACK:-YES}"
RESTORE_DATA="${RESTORE_DATA:-NO}"
BOOT_POINTER=""
FAIL_CLASS="unknown"

TIMEOUT_SAVE="${TIMEOUT_SAVE:-120}"
TIMEOUT_UP="${TIMEOUT_UP:-900}"
TIMEOUT_DOCTOR="${TIMEOUT_DOCTOR:-180}"
TIMEOUT_SMOKE="${TIMEOUT_SMOKE:-600}"
TIMEOUT_ROLLBACK="${TIMEOUT_ROLLBACK:-180}"

if ! [[ "${MAX_ITERS}" =~ ^[0-9]+$ ]]; then MAX_ITERS=2; fi
if [ "${MAX_ITERS}" -lt 1 ]; then MAX_ITERS=1; fi
if [ "${MAX_ITERS}" -gt 2 ]; then MAX_ITERS=2; fi

mkdir -p "${LOG_DIR}"
mkdir -p "${MARKER_DIR}"
exec > >(tee -a "${LOG_PATH}") 2>&1

banner() { echo; echo "==> $*"; }

on_signal() {
  echo
  echo "[autofix_v2] received signal; stopping child processes"
  trap - INT TERM
  pkill -TERM -P $$ >/dev/null 2>&1 || true
  sleep 1
  pkill -KILL -P $$ >/dev/null 2>&1 || true
  echo "[autofix_v2] exiting cleanly after signal"
  exit 130
}
trap on_signal INT TERM

run_with_timeout() {
  local t="$1"
  shift
  timeout --preserve-status "${t}" "$@"
}

echo "[autofix_v2] log: ${LOG_PATH}"
echo "[autofix_v2] MAX_ITERS=${MAX_ITERS} AUTO_ROLLBACK=${AUTO_ROLLBACK} RESTORE_DATA=${RESTORE_DATA}"

DOCKER_CMD="docker"
if ! docker ps >/dev/null 2>&1; then
  if sudo -n docker ps >/dev/null 2>&1; then
    DOCKER_CMD="sudo -E docker"
    echo "[autofix_v2] docker requires sudo; using 'sudo -E docker'"
  else
    banner "waiting for sudo password (sudo -v)"
    if sudo -v >/dev/null 2>&1 && sudo -E docker ps >/dev/null 2>&1; then
      DOCKER_CMD="sudo -E docker"
      echo "[autofix_v2] sudo validated; continuing with 'sudo -E docker'"
    else
      echo "[autofix_v2] docker is unavailable via direct and sudo access"
    fi
  fi
fi

if [ -f "${STACK_DIR}/.env.local" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${STACK_DIR}/.env.local"
  set +a
fi

if [ ! -x "${TOOLS_DIR}/ONTOS_SAVE_LOCAL.sh" ] || [ ! -x "${TOOLS_DIR}/ONTOS_ROLLBACK_LOCAL.sh" ]; then
  echo "[autofix_v2] required tools are missing or not executable under ${TOOLS_DIR}"
  echo "FAIL (smoke failed; see ${LOG_PATH})"
  exit 1
fi

banner "creating pre-change savepoint"
savepoint_out="$(run_with_timeout "${TIMEOUT_SAVE}" "${TOOLS_DIR}/ONTOS_SAVE_LOCAL.sh" "autofix_smoke_v2 pre-change savepoint" 2>&1)"
save_rc=$?
echo "${savepoint_out}"
if [ "${save_rc}" -ne 0 ]; then
  echo "[autofix_v2] savepoint creation failed; aborting before any modification"
  echo "FAIL (smoke failed; see ${LOG_PATH})"
  exit 1
fi
BOOT_POINTER="$(printf '%s\n' "${savepoint_out}" | rg '^BOOT_POINTER=' | tail -n1 | cut -d= -f2-)"
if [ -z "${BOOT_POINTER}" ]; then
  echo "[autofix_v2] failed to capture BOOT_POINTER from savepoint output"
  echo "FAIL (smoke failed; see ${LOG_PATH})"
  exit 1
fi
echo "[autofix_v2] BOOT_POINTER=${BOOT_POINTER}"

run_cycle() {
  local iter="$1"
  banner "iteration ${iter}/${MAX_ITERS}: running compose up (dev_up.sh minimal)"
  run_with_timeout "${TIMEOUT_UP}" env DEV_PROFILE=minimal DEV_BUILD=0 "${STACK_DIR}/scripts/dev_up.sh" || return 11
  banner "iteration ${iter}/${MAX_ITERS}: running doctor"
  run_with_timeout "${TIMEOUT_DOCTOR}" "${STACK_DIR}/scripts/dev_doctor.sh" || return 12
  banner "iteration ${iter}/${MAX_ITERS}: running smoke (curl waits bounded by timeout)"
  run_with_timeout "${TIMEOUT_SMOKE}" "${STACK_DIR}/scripts/smoke_ontogit.sh" || return 13
  return 0
}

classify_failure() {
  local reason action
  FAIL_CLASS="unknown"
  reason="unknown smoke failure"
  action="Run: ${DOCKER_CMD} logs --tail 200 memory-service && ${STACK_DIR}/scripts/dev_doctor.sh"

  if rg -q "(${MARKER_DIR}/dev_profile|${MARKER_DIR}/dev_build): Permission denied|Permission denied.*(${MARKER_DIR}/dev_profile|${MARKER_DIR}/dev_build)" "${LOG_PATH}"; then
    FAIL_CLASS="cache_permission"
    reason="permission problem for repo-local dev profile/build markers"
    action="Run: mkdir -p ${MARKER_DIR} && sudo chown -R $USER:$USER ${MARKER_DIR}"
  elif rg -q "Missing ONTOS_SERVICE_AUTH_SECRET in environment" "${LOG_PATH}"; then
    FAIL_CLASS="missing_secret"
    reason="missing ONTOS_SERVICE_AUTH_SECRET"
    action="Run: ${STACK_DIR}/scripts/dev_bootstrap.sh && set -a && . ${STACK_DIR}/.env.local && set +a"
  elif rg -q "permission denied while trying to connect to the Docker daemon|Cannot connect to the Docker daemon|docker is unavailable via direct and sudo access" "${LOG_PATH}"; then
    FAIL_CLASS="docker_access"
    reason="docker daemon access problem"
    action="Run: sudo -E docker ps && ${STACK_DIR}/scripts/dev_up.sh"
  elif rg -q "Timeout waiting for memory-service health|Failed to connect to 127.0.0.1:8090|Connection refused" "${LOG_PATH}"; then
    FAIL_CLASS="health_timeout"
    reason="memory-service did not become healthy in time"
    action="Run: ${DOCKER_CMD} logs --tail 200 memory-service && ${STACK_DIR}/scripts/dev_doctor.sh"
  elif rg -q "missing ONTOGIT_DAILY_REQUEST_LIMIT=1 after recreate" "${LOG_PATH}"; then
    FAIL_CLASS="missing_pass_through"
    reason="memory-service env pass-through is missing during smoke recreate"
    action="Run: rg -n \"ONTOGIT_DAILY_REQUEST_LIMIT|ONTOGIT_LIMIT_MODE|ONTOGIT_ADMIN_USERS\" ${STACK_DIR}/docker-compose.yml"
  elif rg -q "unknown flag: --env-file|unknown flag --env-file" "${LOG_PATH}"; then
    FAIL_CLASS="env_file_flag"
    reason="docker compose does not support --env-file in this environment"
    action="Run: ${STACK_DIR}/scripts/smoke_ontogit.sh after exporting env from ${STACK_DIR}/.env.local"
  fi

  echo "[autofix_v2] reason: ${reason}"
  echo "[autofix_v2] next action: ${action}"
}

apply_fix_by_class() {
  local class="$1"
  case "${class}" in
    health_timeout)
      if rg -q '\-ge 15' "${STACK_DIR}/scripts/smoke_ontogit.sh"; then
        sed -i 's/\-ge 15/\-ge 45/g' "${STACK_DIR}/scripts/smoke_ontogit.sh"
        echo "[autofix_v2][apply] patched smoke timeout: 15s -> 45s"
        return 0
      fi
      if rg -q 'curl -m 3 -s -m 2 -o /dev/null -w "%{http_code}" "\$BASE_URL/health"' "${STACK_DIR}/scripts/smoke_ontogit.sh"; then
        sed -i 's/curl -m 3 -s -m 2 -o \/dev\/null -w "%{http_code}" "\$BASE_URL\/health"/curl -m 5 -s -o \/dev\/null -w "%{http_code}" "\$BASE_URL\/health"/g' "${STACK_DIR}/scripts/smoke_ontogit.sh"
        echo "[autofix_v2][apply] patched smoke health curl timeout flags"
        return 0
      fi
      return 1
      ;;
    missing_pass_through)
      if rg -q 'ONTOGIT_DAILY_REQUEST_LIMIT=\$\{ONTOGIT_DAILY_REQUEST_LIMIT-\}' "${STACK_DIR}/docker-compose.yml"; then
        return 1
      fi
      sed -i '/ONTOGIT_HOST_DIR=\/root\/ontogit/a\    - ONTOGIT_DAILY_REQUEST_LIMIT=${ONTOGIT_DAILY_REQUEST_LIMIT-}\n    - ONTOGIT_DAILY_TOKEN_LIMIT=${ONTOGIT_DAILY_TOKEN_LIMIT-}\n    - ONTOGIT_LIMIT_MODE=${ONTOGIT_LIMIT_MODE-soft}\n    - ONTOGIT_ADMIN_USERS=${ONTOGIT_ADMIN_USERS-}' "${STACK_DIR}/docker-compose.yml"
      echo "[autofix_v2][apply] added ONTOGIT_* env pass-through in docker-compose memory-service"
      return 0
      ;;
    docker_access)
      local changed=1
      for f in "${STACK_DIR}/scripts/dev_up.sh" "${STACK_DIR}/scripts/dev_doctor.sh" "${STACK_DIR}/scripts/dev_down.sh" "${STACK_DIR}/scripts/smoke_ontogit.sh"; do
        [ -f "${f}" ] || continue
        if rg -q 'sudo -n docker ps >/dev/null 2>&1 \|\| sudo -E docker ps >/dev/null 2>&1' "${f}"; then
          continue
        fi
        if rg -q 'sudo -n docker ps' "${f}"; then
          sed -i 's/sudo -n docker ps >/sudo -n docker ps >\/dev\/null 2>\&1 || sudo -E docker ps >/g' "${f}"
          echo "[autofix_v2][apply] patched sudo docker strategy in $(basename "${f}")"
          changed=0
          break
        fi
      done
      return "${changed}"
      ;;
    env_file_flag)
      if rg -q 'if \$DOCKER_CMD compose --help 2>/dev/null | rg -q -- '\''--env-file'\''' "${STACK_DIR}/scripts/smoke_ontogit.sh"; then
        return 1
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

status=1
iter=1
while [ "${iter}" -le "${MAX_ITERS}" ]; do
  if run_cycle "${iter}"; then
    status=0
    break
  fi

  classify_failure
  class="${FAIL_CLASS}"
  if [ "${iter}" -ge "${MAX_ITERS}" ]; then
    break
  fi

  echo "[autofix_v2] attempting one whitelisted fix for class=${class}"
  if ! apply_fix_by_class "${class}"; then
    echo "[autofix_v2] no eligible auto-fix applied for class=${class}"
    break
  fi

  iter=$((iter + 1))
done

if [ "${status}" -eq 0 ]; then
  echo "[autofix_v2] log: ${LOG_PATH}"
  echo "[autofix_v2] BOOT_POINTER=${BOOT_POINTER}"
  echo "OK (smoke passed)"
  exit 0
fi

if [ "${AUTO_ROLLBACK}" = "YES" ]; then
  banner "persistent failure: running rollback from BOOT_POINTER=${BOOT_POINTER}"
  run_with_timeout "${TIMEOUT_ROLLBACK}" env RESTORE_DATA="${RESTORE_DATA}" "${TOOLS_DIR}/ONTOS_ROLLBACK_LOCAL.sh" "${BOOT_POINTER}" || true
else
  echo "[autofix_v2] rollback not run automatically (AUTO_ROLLBACK=${AUTO_ROLLBACK})"
  echo "[autofix_v2] manual rollback:"
  echo "RESTORE_DATA=${RESTORE_DATA} ${TOOLS_DIR}/ONTOS_ROLLBACK_LOCAL.sh \"${BOOT_POINTER}\""
fi

echo "[autofix_v2] log: ${LOG_PATH}"
echo "[autofix_v2] BOOT_POINTER=${BOOT_POINTER}"
echo "FAIL (smoke failed; see ${LOG_PATH})"
exit 1
