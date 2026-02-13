#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
COMMIT_REF="${COMMIT:-HEAD}"
OPENAI_PROXY_PORT="${OPENAI_PROXY_PORT:-8088}"
TS="$(date +%Y%m%d_%H%M%S)"
ART_DIR="${STACK_DIR}/ops/state/${TS}_deploy_openai_proxy"
LOG_FILE="${ART_DIR}/deploy.log"
WORKTREE_DIR=""
WORKTREE_CREATED=0
DOCKER_BIN=""
DOCKER_CMD=()
COMPOSE_CMD=()

beep_fallback() {
  printf '\a' || true
}

notify_ok() {
  if command -v paplay >/dev/null 2>&1; then
    paplay /usr/share/sounds/freedesktop/stereo/complete.oga >/dev/null 2>&1 || beep_fallback
  else
    beep_fallback
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "openai-proxy deploy" "Success: ${IMAGE_TAG}" >/dev/null 2>&1 || true
  fi
}

notify_fail() {
  local msg="$1"
  if command -v paplay >/dev/null 2>&1; then
    paplay /usr/share/sounds/freedesktop/stereo/dialog-error.oga >/dev/null 2>&1 || beep_fallback
  else
    beep_fallback
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "openai-proxy deploy" "Failed: ${msg}" >/dev/null 2>&1 || true
  fi
}

cleanup() {
  set +e
  if [ "${WORKTREE_CREATED}" = "1" ] && [ -n "${WORKTREE_DIR}" ]; then
    if git -C "${STACK_DIR}" worktree list | awk '{print $1}' | grep -Fxq "${WORKTREE_DIR}"; then
      git -C "${STACK_DIR}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
    fi
    rm -rf "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  fi
}

on_error() {
  local line="$1"
  local code="$2"
  notify_fail "line ${line}, exit ${code}"
  echo "ERROR line=${line} exit=${code}" | tee -a "${LOG_FILE}" >/dev/null
}

trap 'on_error "$LINENO" "$?"' ERR
trap cleanup EXIT

mkdir -p "${ART_DIR}"

DOCKER_BIN="$(command -v docker || true)"
if [ -z "${DOCKER_BIN}" ]; then
  echo "docker not found in PATH" | tee -a "${LOG_FILE}"
  exit 1
fi

DOCKER_CMD=("${DOCKER_BIN}")
if ! "${DOCKER_CMD[@]}" ps >/dev/null 2>&1; then
  echo "docker ps failed; falling back to sudo ${DOCKER_BIN} (Docker Desktop WSL should run docker as user; sudo may break socket/context)." | tee -a "${LOG_FILE}"
  DOCKER_CMD=(sudo "${DOCKER_BIN}")
fi

COMPOSE_CMD=("${DOCKER_BIN}" "compose")
if ! "${COMPOSE_CMD[@]}" version >/dev/null 2>&1; then
  echo "docker compose failed without sudo; falling back to sudo ${DOCKER_BIN} compose." | tee -a "${LOG_FILE}"
  COMPOSE_CMD=(sudo "${DOCKER_BIN}" "compose")
fi

echo "[1/8] Resolve commit ${COMMIT_REF}" | tee -a "${LOG_FILE}"
RESOLVED_SHA="$(git -C "${STACK_DIR}" rev-parse --verify "${COMMIT_REF}^{commit}")"
SHORT_SHA="$(git -C "${STACK_DIR}" rev-parse --short=9 "${RESOLVED_SHA}")"
IMAGE_TAG="ontogit-openai-proxy:${SHORT_SHA}"
CURRENT_HEAD="$(git -C "${STACK_DIR}" rev-parse HEAD)"

echo "resolved_sha=${RESOLVED_SHA}" | tee -a "${LOG_FILE}"
echo "image_tag=${IMAGE_TAG}" | tee -a "${LOG_FILE}"

echo "[2/8] Build image for openai-proxy" | tee -a "${LOG_FILE}"
if [ "${RESOLVED_SHA}" = "${CURRENT_HEAD}" ]; then
  (
    cd "${STACK_DIR}"
    "${COMPOSE_CMD[@]}" -f docker-compose.yml build openai-proxy
  ) | tee -a "${LOG_FILE}"
  # Explicit tag for traceability.
  "${DOCKER_CMD[@]}" build -f "${STACK_DIR}/openai-proxy/Dockerfile" -t "${IMAGE_TAG}" "${STACK_DIR}" | tee -a "${LOG_FILE}"
else
  WORKTREE_DIR="$(mktemp -d /tmp/ontogit_stack_openai_proxy.XXXXXX)"
  git -C "${STACK_DIR}" worktree add --detach "${WORKTREE_DIR}" "${RESOLVED_SHA}" | tee -a "${LOG_FILE}"
  WORKTREE_CREATED=1
  "${DOCKER_CMD[@]}" build -f "${WORKTREE_DIR}/openai-proxy/Dockerfile" -t "${IMAGE_TAG}" "${WORKTREE_DIR}" | tee -a "${LOG_FILE}"
  # Force compose service image to use exact commit build without changing compose files.
  "${DOCKER_CMD[@]}" tag "${IMAGE_TAG}" "ontogit-stack-openai-proxy:latest" | tee -a "${LOG_FILE}" >/dev/null
fi

echo "[3/8] Restart only openai-proxy" | tee -a "${LOG_FILE}"
(
  cd "${STACK_DIR}"
  if [ "${RESOLVED_SHA}" = "${CURRENT_HEAD}" ]; then
    "${COMPOSE_CMD[@]}" -f docker-compose.yml up -d --no-deps --build openai-proxy
  else
    "${COMPOSE_CMD[@]}" -f docker-compose.yml up -d --no-deps --no-build openai-proxy
  fi
) | tee -a "${LOG_FILE}"

echo "[4/8] Wait for running/healthy (timeout 90s)" | tee -a "${LOG_FILE}"
CID="$("${COMPOSE_CMD[@]}" -f "${STACK_DIR}/docker-compose.yml" ps -q openai-proxy)"
if [ -z "${CID}" ]; then
  echo "openai-proxy container id not found" | tee -a "${LOG_FILE}"
  exit 1
fi

DEADLINE=$((SECONDS + 90))
while :; do
  HEALTH="$("${DOCKER_CMD[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${CID}")"
  RUNNING="$("${DOCKER_CMD[@]}" inspect -f '{{.State.Running}}' "${CID}")"
  echo "health=${HEALTH} running=${RUNNING}" | tee -a "${LOG_FILE}"

  if [ "${HEALTH}" = "healthy" ]; then
    break
  fi
  if [ "${HEALTH}" = "no-healthcheck" ] && [ "${RUNNING}" = "true" ]; then
    break
  fi
  if [ "${RUNNING}" != "true" ]; then
    echo "container is not running" | tee -a "${LOG_FILE}"
    exit 1
  fi
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    echo "timeout waiting for healthy/running" | tee -a "${LOG_FILE}"
    exit 1
  fi
  sleep 2
done

echo "[5/8] Determine host port" | tee -a "${LOG_FILE}"
PORT_MAP="$("${DOCKER_CMD[@]}" port "${CID}" 8088/tcp 2>/dev/null | head -n1 || true)"
if [ -n "${PORT_MAP}" ]; then
  HOST_PORT="$(echo "${PORT_MAP}" | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')"
else
  HOST_PORT="${OPENAI_PROXY_PORT}"
fi
if [ -z "${HOST_PORT}" ]; then
  HOST_PORT="${OPENAI_PROXY_PORT}"
fi
echo "host_port=${HOST_PORT}" | tee -a "${LOG_FILE}"

echo "[6/8] Smoke /v1/models" | tee -a "${LOG_FILE}"
SMOKE_HOST="127.0.0.1"
SMOKE_PORT="${HOST_PORT:-${OPENAI_PROXY_PORT}}"
SMOKE_URL="http://${SMOKE_HOST}:${SMOKE_PORT}/v1/models"
echo "url=${SMOKE_URL}" > "${ART_DIR}/smoke_http.txt"
SMOKE_CODE=""
SMOKE_OK=0
for i in $(seq 1 10); do
  SMOKE_CODE="$(curl -sS -o "${ART_DIR}/smoke_body.json" -w '%{http_code}' "${SMOKE_URL}" || true)"
  {
    echo "url=${SMOKE_URL}"
    echo "http_code=${SMOKE_CODE}"
  } > "${ART_DIR}/smoke_http.txt"
  if [ "${SMOKE_CODE}" = "200" ]; then
    SMOKE_OK=1
    break
  fi
  sleep 0.5
done
if [ "${SMOKE_OK}" != "1" ]; then
  echo "smoke failed after retries with http_code=${SMOKE_CODE}" | tee -a "${LOG_FILE}"
  exit 1
fi

echo "[7/8] Collect artifacts" | tee -a "${LOG_FILE}"
"${DOCKER_CMD[@]}" ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' > "${ART_DIR}/docker_ps.txt"
"${DOCKER_CMD[@]}" logs --tail 200 "${CID}" > "${ART_DIR}/docker_logs_tail.txt" 2>&1 || true
{
  echo "container_id=${CID}"
  echo "container_image=$("${DOCKER_CMD[@]}" inspect -f '{{.Config.Image}}' "${CID}")"
  echo "image_id=$("${DOCKER_CMD[@]}" inspect -f '{{.Image}}' "${CID}")"
  echo "deployed_tag=${IMAGE_TAG}"
  echo "resolved_sha=${RESOLVED_SHA}"
} > "${ART_DIR}/docker_image.txt"
cat > "${ART_DIR}/how_to_repeat.txt" <<TXT
cd /home/ontoslive/ontos_work/ontogit-stack
./scripts/deploy_openai_proxy.sh
COMMIT=<sha> ./scripts/deploy_openai_proxy.sh
OPENAI_PROXY_PORT=8088 ./scripts/deploy_openai_proxy.sh
TXT

echo "[8/8] Done" | tee -a "${LOG_FILE}"
notify_ok

echo "Deploy complete"
echo "image_tag=${IMAGE_TAG}"
echo "artifacts=${ART_DIR}"
