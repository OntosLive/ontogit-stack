#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
WEBUI_SRC="/home/ontoslive/ontos_work/open-webui-src"
COMPOSE_PIN_FILE="${STACK_DIR}/docker-compose.webui-ontogate.yml"
COMMIT_REF="${COMMIT:-HEAD}"
TS="$(date +%Y%m%d_%H%M%S)"
ART_DIR="${STACK_DIR}/ops/state/${TS}_deploy_openwebui"
WORKTREE_DIR="$(mktemp -d /tmp/openwebui_worktree.XXXXXX)"
PRE_FILE="${ART_DIR}/compose_pin_before.yml"
POST_FILE="${ART_DIR}/compose_pin_after.yml"
DIFF_FILE="${ART_DIR}/compose_pin.diff"
LOG_FILE="${ART_DIR}/deploy.log"
DOCKER_BIN=""
DOCKER_CMD=()
COMPOSE_CMD=()

cleanup() {
  set +e
  if git -C "${WEBUI_SRC}" worktree list | awk '{print $1}' | grep -Fxq "${WORKTREE_DIR}"; then
    git -C "${WEBUI_SRC}" worktree remove --force "${WORKTREE_DIR}" >/dev/null 2>&1 || true
  fi
  rm -rf "${WORKTREE_DIR}" >/dev/null 2>&1 || true
}

notify_ok() {
  if command -v paplay >/dev/null 2>&1; then
    paplay /usr/share/sounds/freedesktop/stereo/complete.oga >/dev/null 2>&1 || true
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "open-webui deploy" "Success: tag ${TAG}" >/dev/null 2>&1 || true
  fi
}

notify_fail() {
  local msg="$1"
  if command -v paplay >/dev/null 2>&1; then
    paplay /usr/share/sounds/freedesktop/stereo/dialog-error.oga >/dev/null 2>&1 || true
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "open-webui deploy" "Failed: ${msg}" >/dev/null 2>&1 || true
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
RESOLVED_SHA="$(git -C "${WEBUI_SRC}" rev-parse --verify "${COMMIT_REF}^{commit}")"
TAG="$(git -C "${WEBUI_SRC}" rev-parse --short=9 "${RESOLVED_SHA}")"
IMAGE="open-webui-ontogate:${TAG}"
echo "resolved_sha=${RESOLVED_SHA}" | tee -a "${LOG_FILE}"
echo "tag=${TAG}" | tee -a "${LOG_FILE}"

echo "[2/8] Create temporary worktree" | tee -a "${LOG_FILE}"
git -C "${WEBUI_SRC}" worktree add --detach "${WORKTREE_DIR}" "${RESOLVED_SHA}" | tee -a "${LOG_FILE}"

echo "[3/8] Build image ${IMAGE}" | tee -a "${LOG_FILE}"
"${DOCKER_CMD[@]}" build -t "${IMAGE}" "${WORKTREE_DIR}" | tee -a "${LOG_FILE}"

echo "[4/8] Update compose pin in ${COMPOSE_PIN_FILE}" | tee -a "${LOG_FILE}"
cp "${COMPOSE_PIN_FILE}" "${PRE_FILE}"
perl -0pi -e 's#(^\s*image:\s*)open-webui-ontogate:[^\s]+#$1open-webui-ontogate:'"${TAG}"'#m' "${COMPOSE_PIN_FILE}"
cp "${COMPOSE_PIN_FILE}" "${POST_FILE}"
diff -u "${PRE_FILE}" "${POST_FILE}" > "${DIFF_FILE}" || true

grep -n "image:\s*open-webui-ontogate:" "${COMPOSE_PIN_FILE}" | tee -a "${LOG_FILE}"

echo "[5/8] Recreate only open-webui" | tee -a "${LOG_FILE}"
cd "${STACK_DIR}"
"${COMPOSE_CMD[@]}" -f docker-compose.yml -f docker-compose.webui-ontogate.yml up -d --force-recreate open-webui | tee -a "${LOG_FILE}"

echo "[6/8] Wait for healthy OR /api/version=200 (timeout 120s)" | tee -a "${LOG_FILE}"
CID="$("${COMPOSE_CMD[@]}" -f docker-compose.yml -f docker-compose.webui-ontogate.yml ps -q open-webui)"
if [ -z "${CID}" ]; then
  echo "open-webui container id not found" | tee -a "${LOG_FILE}"
  exit 1
fi

LAST_STATE_HEALTH=""
LAST_CURL_STATUS=""
LAST_CURL_URL="http://127.0.0.1:3000/api/version"
DEADLINE=$((SECONDS + 120))
while :; do
  LAST_STATE_HEALTH="$("${DOCKER_CMD[@]}" inspect -f 'running={{.State.Running}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${CID}")"
  RUNNING="$(echo "${LAST_STATE_HEALTH}" | sed -n 's/.*running=\([^ ]*\).*/\1/p')"
  HEALTH="$(echo "${LAST_STATE_HEALTH}" | sed -n 's/.*health=\([^ ]*\).*/\1/p')"

  LAST_CURL_STATUS="$(curl -sS -o "${ART_DIR}/api_version.json" -w '%{http_code}' "${LAST_CURL_URL}" || true)"
  echo "${LAST_STATE_HEALTH} curl_status=${LAST_CURL_STATUS}" | tee -a "${LOG_FILE}"

  if [ "${HEALTH}" = "healthy" ]; then
    break
  fi
  if [ "${LAST_CURL_STATUS}" = "200" ]; then
    break
  fi
  if [ "${RUNNING}" != "true" ]; then
    echo "container is not running" | tee -a "${LOG_FILE}"
    exit 1
  fi
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    echo "timeout waiting for healthy OR api/version=200" | tee -a "${LOG_FILE}"
    exit 1
  fi
  sleep 2
done

echo "[7/8] Record wait result" | tee -a "${LOG_FILE}"
{
  echo "${LAST_STATE_HEALTH}"
} > "${ART_DIR}/wait_state_health.txt"
{
  echo "url=${LAST_CURL_URL}"
  echo "http_code=${LAST_CURL_STATUS}"
} > "${ART_DIR}/api_version_curl.txt"

echo "[8/8] Collect artifacts" | tee -a "${LOG_FILE}"
"${DOCKER_CMD[@]}" ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' > "${ART_DIR}/docker_ps.txt"
"${DOCKER_CMD[@]}" inspect "${CID}" > "${ART_DIR}/openwebui_inspect.json"
"${DOCKER_CMD[@]}" images | grep 'open-webui-ontogate' > "${ART_DIR}/docker_images_openwebui_ontogate.txt" || true
cat > "${ART_DIR}/how_to_repeat.txt" <<TXT
COMMIT=<sha> ./scripts/deploy_openwebui.sh
# or deploy current HEAD of open-webui-src:
./scripts/deploy_openwebui.sh
TXT

notify_ok

echo "Deploy complete"
echo "image=${IMAGE}"
echo "artifacts=${ART_DIR}"
