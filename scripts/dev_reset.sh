#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
WEBUI_DIR="/home/ontoslive/ontos_work/open-webui-src"
DATA_ONTOS_USER="/home/ontoslive/ontos_data/ontogit-user"
DATA_WEBUI="/home/ontoslive/ontos_data/openwebui-data"

if [ "${DEV_RESET_I_UNDERSTAND:-}" != "YES" ]; then
  echo "Refusing to reset. Set DEV_RESET_I_UNDERSTAND=YES to proceed."
  exit 1
fi

DOCKER_CMD="docker"
if ! docker ps >/dev/null 2>&1; then
  if sudo -n docker ps >/dev/null 2>&1; then
    DOCKER_CMD="sudo -E -n docker"
  fi
fi

(cd "$STACK_DIR" && $DOCKER_CMD compose down)
(cd "$WEBUI_DIR" && $DOCKER_CMD compose down)

echo "Deleting local data dirs:"
echo "  $DATA_ONTOS_USER"
echo "  $DATA_WEBUI"
rm -rf "$DATA_ONTOS_USER" "$DATA_WEBUI"

echo "Reset complete."
