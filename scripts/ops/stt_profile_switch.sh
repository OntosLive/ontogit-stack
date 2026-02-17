#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 gpu|cpu" >&2
  exit 2
fi

MODE="$1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ontogit-stack}"
export COMPOSE_PROJECT_NAME
TS="$(date +%Y%m%d_%H%M%S)"
STATE_DIR="${STACK_DIR}/ops/state/${TS}_stt_profile_switch"
mkdir -p "${STATE_DIR}"

COMPOSE_FILE="${STACK_DIR}/docker-compose.webui-ontogate.yml"
ENV_LINK="${STACK_DIR}/.env.stt"

PROFILE_FILE=""
case "${MODE}" in
  gpu) PROFILE_FILE="${STACK_DIR}/profiles/stt_gpu.env" ;;
  cpu) PROFILE_FILE="${STACK_DIR}/profiles/stt_cpu.env" ;;
  *)
    echo "unknown mode: ${MODE} (use gpu or cpu)" >&2
    exit 2
    ;;
esac

if [ ! -f "${PROFILE_FILE}" ]; then
  echo "profile not found: ${PROFILE_FILE}" >&2
  exit 1
fi

cp -a "${COMPOSE_FILE}" "${STATE_DIR}/docker-compose.webui-ontogate.yml"
if [ -e "${ENV_LINK}" ]; then
  cp -a "${ENV_LINK}" "${STATE_DIR}/.env.stt"
fi

echo "mode=${MODE}" > "${STATE_DIR}/profile.txt"
echo "profile=${PROFILE_FILE}" >> "${STATE_DIR}/profile.txt"

if [ -e "${ENV_LINK}" ]; then
  cp -a "${ENV_LINK}" "${ENV_LINK}.bak.${TS}"
fi
ln -sfn "${PROFILE_FILE}" "${ENV_LINK}"

set -a
. "${ENV_LINK}"
set +a

if [ ! -f "${COMPOSE_FILE}" ]; then
  echo "compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

cp -a "${COMPOSE_FILE}" "${COMPOSE_FILE}.bak.${TS}"

if [ "${MODE}" = "gpu" ]; then
  ENV_BLOCK="      USE_CUDA_DOCKER: \"true\"\n      NVIDIA_VISIBLE_DEVICES: \"all\"\n      NVIDIA_DRIVER_CAPABILITIES: \"compute,utility\""
  GPU_BLOCK="    runtime: nvidia\n    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]"
else
  ENV_BLOCK="      USE_CUDA_DOCKER: \"false\""
  GPU_BLOCK=""
fi

TMP_FILE="${COMPOSE_FILE}.tmp.${TS}"
awk -v env_begin="# ALBA_GPU_ENV_BEGIN" -v env_end="# ALBA_GPU_ENV_END" -v env_block="${ENV_BLOCK}" '
  $0 ~ env_begin {print; print env_block; in_env=1; next}
  $0 ~ env_end {in_env=0; print; next}
  in_env==1 {next}
  {print}
' "${COMPOSE_FILE}" > "${TMP_FILE}"

awk -v gpu_begin="# ALBA_GPU_BEGIN" -v gpu_end="# ALBA_GPU_END" -v gpu_block="${GPU_BLOCK}" '
  $0 ~ gpu_begin {print; if (gpu_block != "") print gpu_block; in_gpu=1; next}
  $0 ~ gpu_end {in_gpu=0; print; next}
  in_gpu==1 {next}
  {print}
' "${TMP_FILE}" > "${COMPOSE_FILE}"
rm -f "${TMP_FILE}"

OUTDIR="${STATE_DIR}" "${SCRIPT_DIR}/stt_profile_apply_openwebui.sh" "${ALBA_STT_MODEL}"

DOCKER_BIN="$(command -v docker || true)"
if [ -z "${DOCKER_BIN}" ]; then
  echo "docker not found in PATH" >&2
  exit 1
fi

DOCKER_CMD=("${DOCKER_BIN}")
if ! "${DOCKER_CMD[@]}" ps >/dev/null 2>&1; then
  DOCKER_CMD=(sudo "${DOCKER_BIN}")
fi

COMPOSE_CMD=("${DOCKER_CMD[@]}" compose)
if ! "${COMPOSE_CMD[@]}" version >/dev/null 2>&1; then
  COMPOSE_CMD=(sudo "${DOCKER_BIN}" compose)
fi

cd "${STACK_DIR}"
"${COMPOSE_CMD[@]}" -f docker-compose.yml -f docker-compose.webui-ontogate.yml up -d --force-recreate open-webui

echo "OK"
echo "state_dir=${STATE_DIR}"
