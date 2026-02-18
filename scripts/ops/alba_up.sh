#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
OPS_DIR="${STACK_DIR}/scripts/ops"
UNIT_NAME="alba-revtunnel.service"
UNIT_SRC="${STACK_DIR}/${UNIT_NAME}"
UNIT_DST="/etc/systemd/system/${UNIT_NAME}"
VPS_HOST="${ALBA_VPS_HOST:-194.31.175.16}"
VPS_USER="${ALBA_VPS_USER:-ontoslive}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new)

die() {
  echo "FAIL: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return
  fi
  die "root privileges required for: $*"
}

need_cmd curl
need_cmd systemctl

log "Check local OpenWebUI: http://127.0.0.1:3000/api/version"
LOCAL_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/api/version || true)"
[ "${LOCAL_CODE}" = "200" ] || die "local OpenWebUI is not ready on 127.0.0.1:3000 (code=${LOCAL_CODE:-ERR})"

log "Apply STT guardrail"
(
  cd "${STACK_DIR}"
  bash "${OPS_DIR}/stt_guard.sh"
)

log "Generate canonical tunnel unit via scripts/ops/alba_local_tunnel_unit_install.sh"
(
  cd "${STACK_DIR}"
  bash "${OPS_DIR}/alba_local_tunnel_unit_install.sh"
)
[ -f "${UNIT_SRC}" ] || die "generated unit file not found: ${UNIT_SRC}"

log "Install unit ${UNIT_NAME} (idempotent)"
if run_as_root test -f "${UNIT_DST}"; then
  if run_as_root cmp -s "${UNIT_SRC}" "${UNIT_DST}"; then
    echo "unit unchanged: ${UNIT_DST}"
  else
    TS="$(date +%Y%m%d_%H%M%S)"
    run_as_root cp -a "${UNIT_DST}" "${UNIT_DST}.bak.${TS}"
    run_as_root cp -a "${UNIT_SRC}" "${UNIT_DST}"
    echo "unit updated: ${UNIT_DST}"
  fi
else
  run_as_root cp -a "${UNIT_SRC}" "${UNIT_DST}"
  echo "unit installed: ${UNIT_DST}"
fi

log "Enable/start ${UNIT_NAME}"
run_as_root systemctl daemon-reload
run_as_root systemctl enable --now "${UNIT_NAME}"
ACTIVE_STATE="$(run_as_root systemctl is-active "${UNIT_NAME}" || true)"
[ "${ACTIVE_STATE}" = "active" ] || die "${UNIT_NAME} is not active (state=${ACTIVE_STATE:-unknown})"

log "Run status snapshot"
(
  cd "${STACK_DIR}"
  bash "${OPS_DIR}/alba_status.sh"
)

log "Verify public domain"
DOMAIN_CODE="$(curl -fsS -o /dev/null -w '%{http_code}' https://alba.ontos.live/api/version || true)"
[ "${DOMAIN_CODE}" = "200" ] || die "public check failed: https://alba.ontos.live/api/version (code=${DOMAIN_CODE:-ERR})"

log "Verify VPS-side tunnel endpoint (127.0.0.1:3010) when SSH is available"
if command -v ssh >/dev/null 2>&1; then
  VPS_CODE="$(
    ssh "${SSH_OPTS[@]}" "${VPS_USER}@${VPS_HOST}" \
      "curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:3010/api/version || true" 2>/dev/null || true
  )"
  if [ -n "${VPS_CODE}" ]; then
    [ "${VPS_CODE}" = "200" ] || die "VPS tunnel check failed: http://127.0.0.1:3010/api/version (code=${VPS_CODE})"
    echo "vps_3010_check=200"
  else
    echo "WARN: skipped direct VPS check (ssh unavailable). Run on VPS:"
    echo "  ss -ltnp | grep :3010"
    echo "  curl -fsS http://127.0.0.1:3010/api/version"
  fi
else
  echo "WARN: ssh not installed; cannot run direct VPS check. Run on VPS:"
  echo "  ss -ltnp | grep :3010"
  echo "  curl -fsS http://127.0.0.1:3010/api/version"
fi

echo "ALL GREEN: local=200 tunnel_service=active domain=200"
