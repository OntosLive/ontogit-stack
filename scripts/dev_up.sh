#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
WEBUI_DIR="/home/ontoslive/ontos_work/open-webui-src"
PROFILE="${DEV_PROFILE:-minimal}"
BUILD="${DEV_BUILD:-0}"

DOCKER_CMD="docker"
if ! docker ps >/dev/null 2>&1; then
  if sudo -n docker ps >/dev/null 2>&1 || sudo -E docker ps >/dev/null 2>&1; then
    DOCKER_CMD="sudo -E docker"
    echo "Using sudo docker (password may be required)"
  fi
fi

if [ -f "${STACK_DIR}/.env.local" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${STACK_DIR}/.env.local"
  set +a
fi
if [ -f "${WEBUI_DIR}/.env.local" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${WEBUI_DIR}/.env.local"
  set +a
fi

PROFILE_FILE="/home/ontoslive/.cache/ontogit/dev_profile"
BUILD_FILE="/home/ontoslive/.cache/ontogit/dev_build"
echo "$PROFILE" > "$PROFILE_FILE"
echo "$BUILD" > "$BUILD_FILE"

STACK_ARGS=()
WEBUI_ARGS=()
if [ "$PROFILE" = "full" ]; then
  STACK_ARGS+=(--profile full)
  WEBUI_ARGS+=(--profile full)
fi

if [ "$BUILD" = "1" ]; then
  STACK_BUILD_ARGS=(--build)
  WEBUI_BUILD_ARGS=(--build)
else
  STACK_BUILD_ARGS=()
  WEBUI_BUILD_ARGS=()
fi

(cd "$STACK_DIR" && $DOCKER_CMD compose up -d "${STACK_BUILD_ARGS[@]}" "${STACK_ARGS[@]}") || {
  echo "docker compose up failed for ontogit-stack"
  exit 1
}
(cd "$WEBUI_DIR" && $DOCKER_CMD compose -f docker-compose.yaml -f docker-compose.dev.yaml up -d --pull always "${WEBUI_BUILD_ARGS[@]}" "${WEBUI_ARGS[@]}") || {
  echo "docker compose up failed for open-webui-src"
  exit 1
}

"${STACK_DIR}/scripts/dev_doctor.sh"
