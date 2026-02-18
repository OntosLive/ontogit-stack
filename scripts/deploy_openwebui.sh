#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
SMOKE_CMD=(bash "${STACK_DIR}/scripts/ops/smoke_v1.sh")
WEBUI_SRC="/home/ontoslive/ontos_work/open-webui-src"
COMPOSE_PIN_FILE="${STACK_DIR}/docker-compose.webui-ontogate.yml"
COMMIT_REF="${COMMIT:-HEAD}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ontogit-stack}"
EXPECTED_NETWORK="${COMPOSE_PROJECT_NAME}_default"
NETWORK_REGEX="^${COMPOSE_PROJECT_NAME}(_${COMPOSE_PROJECT_NAME})?_default$"
TS="$(date +%Y%m%d_%H%M%S)"
ART_DIR="${STACK_DIR}/ops/state/${TS}_deploy_openwebui"
WORKTREE_DIR="$(mktemp -d /tmp/openwebui_worktree.XXXXXX)"
PRE_FILE="${ART_DIR}/compose_pin_before.yml"
POST_FILE="${ART_DIR}/compose_pin_after.yml"
DIFF_FILE="${ART_DIR}/compose_pin.diff"
LOG_FILE="${ART_DIR}/deploy.log"
DOCKER_CMD=()
COMPOSE_CMD=()
COMPOSE_ENV=()
export COMPOSE_PROJECT_NAME

preflight_networks() {
  local line=""
  local name=""
  local -a bad_networks=()
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    name="${line%%$'\t'*}"
    if [ "${name}" != "${EXPECTED_NETWORK}" ]; then
      bad_networks+=("${name}")
    fi
  done < <("${DOCKER_CMD[@]}" network ls --format '{{.Name}}' | rg "${NETWORK_REGEX}" || true)

  if [ "${#bad_networks[@]}" -gt 0 ]; then
    echo "ERROR: duplicate ontogit-stack default network(s) detected: ${bad_networks[*]}" | tee -a "${LOG_FILE}"
    echo "Remediation:" | tee -a "${LOG_FILE}"
    echo "  1) Stop stack: docker compose -f docker-compose.yml -f docker-compose.webui-ontogate.yml down" | tee -a "${LOG_FILE}"
    echo "  2) Remove empty stray network(s): docker network rm ${bad_networks[*]}" | tee -a "${LOG_FILE}"
    echo "  3) Redeploy via ritual: ./scripts/deploy_openwebui.sh" | tee -a "${LOG_FILE}"
    exit 1
  fi
}

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

echo "[pre] smoke_v1 BEFORE" | tee -a "${LOG_FILE}"
if ! "${SMOKE_CMD[@]}" | tee -a "${LOG_FILE}"; then
  echo "smoke_v1 BEFORE failed; abort deploy" | tee -a "${LOG_FILE}"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found in PATH" | tee -a "${LOG_FILE}"
  exit 1
fi

DOCKER_CMD=(docker)
if ! "${DOCKER_CMD[@]}" ps >/dev/null 2>&1; then
  echo "ERROR: docker daemon is not accessible via plain docker (sudo fallback disabled)." | tee -a "${LOG_FILE}"
  echo "Fix: ensure this user can run docker (docker group / socket permissions), then re-run ./scripts/deploy_openwebui.sh." | tee -a "${LOG_FILE}"
  exit 1
fi

COMPOSE_CMD=("${DOCKER_CMD[@]}" "compose")
if ! "${COMPOSE_CMD[@]}" version >/dev/null 2>&1; then
  echo "ERROR: docker compose is not accessible via plain docker compose (sudo fallback disabled)." | tee -a "${LOG_FILE}"
  exit 1
fi
if [ -f "${STACK_DIR}/.env.local" ]; then
  COMPOSE_ENV=(--env-file "${STACK_DIR}/.env.local")
fi

echo "[0/8] Network preflight (${EXPECTED_NETWORK})" | tee -a "${LOG_FILE}"
preflight_networks

echo "[1/8] Resolve commit ${COMMIT_REF}" | tee -a "${LOG_FILE}"
RESOLVED_SHA="$(git -C "${WEBUI_SRC}" rev-parse --verify "${COMMIT_REF}^{commit}")"
TAG="$(git -C "${WEBUI_SRC}" rev-parse --short=9 "${RESOLVED_SHA}")"
IMAGE="open-webui-ontogate:${TAG}"
echo "resolved_sha=${RESOLVED_SHA}" | tee -a "${LOG_FILE}"
echo "tag=${TAG}" | tee -a "${LOG_FILE}"

echo "[2/8] Create temporary worktree" | tee -a "${LOG_FILE}"
git -C "${WEBUI_SRC}" worktree add --detach "${WORKTREE_DIR}" "${RESOLVED_SHA}" | tee -a "${LOG_FILE}"

echo "[3/8] Build image ${IMAGE}" | tee -a "${LOG_FILE}"
BUILD_ERR_FILE="${ART_DIR}/build_stderr.txt"
if "${DOCKER_CMD[@]}" image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "image exists locally; skip build: ${IMAGE}" | tee -a "${LOG_FILE}"
else
  if ! "${DOCKER_CMD[@]}" build -t "${IMAGE}" "${WORKTREE_DIR}" 2>"${BUILD_ERR_FILE}" | tee -a "${LOG_FILE}"; then
    if rg -qi 'docker hub|registry-1\.docker\.io|token|timeout' "${BUILD_ERR_FILE}"; then
      echo "Docker Hub unreachable; try again or docker login" | tee -a "${LOG_FILE}"
    fi
    exit 1
  fi
fi

echo "[4/8] Update compose pin in ${COMPOSE_PIN_FILE}" | tee -a "${LOG_FILE}"
cp "${COMPOSE_PIN_FILE}" "${PRE_FILE}"
perl -0pi -e 's#(^\s*image:\s*)open-webui-ontogate:[^\s]+#$1open-webui-ontogate:'"${TAG}"'#m' "${COMPOSE_PIN_FILE}"
cp "${COMPOSE_PIN_FILE}" "${POST_FILE}"
diff -u "${PRE_FILE}" "${POST_FILE}" > "${DIFF_FILE}" || true

grep -n "image:\s*open-webui-ontogate:" "${COMPOSE_PIN_FILE}" | tee -a "${LOG_FILE}"

echo "[5/8] Recreate only open-webui" | tee -a "${LOG_FILE}"
cd "${STACK_DIR}"
PORT_HOGS="$("${DOCKER_CMD[@]}" ps --format '{{.Names}}\t{{.Ports}}' | awk -F'\t' '$2 ~ /0\\.0\\.0\\.0:3000->/ {print $1}')"
if [ -n "${PORT_HOGS}" ]; then
  for name in ${PORT_HOGS}; do
    if [ "${name}" != "ontogit-stack-open-webui-1" ]; then
      echo "stopping container holding 0.0.0.0:3000 -> ${name}" | tee -a "${LOG_FILE}"
      "${DOCKER_CMD[@]}" stop "${name}" | tee -a "${LOG_FILE}"
    fi
  done
fi
"${COMPOSE_CMD[@]}" "${COMPOSE_ENV[@]}" -f docker-compose.yml -f docker-compose.webui-ontogate.yml up -d --force-recreate open-webui | tee -a "${LOG_FILE}"

echo "[6/8] Wait for healthy OR /api/version=200 (timeout 120s)" | tee -a "${LOG_FILE}"
CID="$("${COMPOSE_CMD[@]}" "${COMPOSE_ENV[@]}" -f docker-compose.yml -f docker-compose.webui-ontogate.yml ps -q open-webui)"
if [ -z "${CID}" ]; then
  echo "open-webui container id not found" | tee -a "${LOG_FILE}"
  exit 1
fi

LAST_STATE_HEALTH=""
LAST_CURL_STATUS=""
LAST_CURL_URL="http://127.0.0.1:3000/api/version"
READY_ERR_FILE="${ART_DIR}/ready_curl_err.txt"
> "${READY_ERR_FILE}"
DEADLINE=$((SECONDS + 120))
while :; do
  LAST_STATE_HEALTH="$("${DOCKER_CMD[@]}" inspect -f 'running={{.State.Running}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${CID}")"
  RUNNING="$(echo "${LAST_STATE_HEALTH}" | sed -n 's/.*running=\([^ ]*\).*/\1/p')"
  HEALTH="$(echo "${LAST_STATE_HEALTH}" | sed -n 's/.*health=\([^ ]*\).*/\1/p')"

  LAST_CURL_STATUS="$(curl -fsS -o "${ART_DIR}/api_version.json" -w '%{http_code}' "${LAST_CURL_URL}" 2>>"${READY_ERR_FILE}" || true)"

  if [ "${HEALTH}" = "healthy" ]; then
    break
  fi
  if [ "${HEALTH}" = "none" ]; then
    if [ "${LAST_CURL_STATUS}" = "200" ]; then
      break
    fi
  else
    if [ "${LAST_CURL_STATUS}" = "200" ]; then
      break
    fi
  fi
  if [ "${RUNNING}" != "true" ]; then
    echo "container is not running" >> "${LOG_FILE}"
    echo "READY FAIL" | tee -a "${LOG_FILE}"
    exit 1
  fi
  if [ "$SECONDS" -ge "$DEADLINE" ]; then
    echo "timeout waiting for healthy OR api/version=200" >> "${LOG_FILE}"
    echo "READY FAIL" | tee -a "${LOG_FILE}"
    exit 1
  fi
  sleep 2
done
echo "READY OK" | tee -a "${LOG_FILE}"

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

echo "[post] smoke_v1 AFTER" | tee -a "${LOG_FILE}"
if ! "${SMOKE_CMD[@]}" | tee -a "${LOG_FILE}"; then
  echo "smoke_v1 AFTER failed" | tee -a "${LOG_FILE}"
  exit 1
fi

notify_ok

echo "Deploy complete"
echo "image=${IMAGE}"
echo "artifacts=${ART_DIR}"
