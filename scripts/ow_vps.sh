#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
WEBUI_DIR="/home/ontoslive/ontos_work/open-webui-src"

DOCKER_CMD="docker"
if ! docker ps >/dev/null 2>&1; then
  if sudo -n docker ps >/dev/null 2>&1 || sudo -E docker ps >/dev/null 2>&1; then
    DOCKER_CMD="sudo -E docker"
    echo "Using sudo docker (password may be required)"
  else
    echo "Docker is not accessible (direct or via sudo)."
    exit 1
  fi
fi

cd "${WEBUI_DIR}"
$DOCKER_CMD compose -f docker-compose.yaml -f docker-compose.dev.yaml -f docker-compose.vpsdata.override.yaml up -d --force-recreate open-webui

"${STACK_DIR}/scripts/ow_whereami.sh"
