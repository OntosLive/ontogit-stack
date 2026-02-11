#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
WEBUI_DIR="/home/ontoslive/ontos_work/open-webui-src"
DATA_DIR="/home/ontoslive/ontos_data"
VPS_CURRENT_LINK="${DATA_DIR}/openwebui-data-vps-current"
VPS_GLOB="${DATA_DIR}/openwebui-data-vps-20*"
VPS_OVERRIDE_FILE="${WEBUI_DIR}/docker-compose.vpsdata.override.yaml"

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

if [ ! -e "${VPS_CURRENT_LINK}" ]; then
  NEWEST_VPS_DIR="$(ls -1dt ${VPS_GLOB} 2>/dev/null | head -n1 || true)"
  if [ -z "${NEWEST_VPS_DIR}" ] || [ ! -d "${NEWEST_VPS_DIR}" ]; then
    echo "No VPS data directory found."
    echo "Import a VPS tgz into /home/ontoslive/ontos_data/openwebui-data-vps-<TS> first"
    exit 1
  fi
  ln -s "${NEWEST_VPS_DIR}" "${VPS_CURRENT_LINK}"
fi

if [ ! -L "${VPS_CURRENT_LINK}" ]; then
  echo "Expected symlink at ${VPS_CURRENT_LINK}, but found a non-symlink path."
  exit 1
fi

cat > "${VPS_OVERRIDE_FILE}" <<EOF
services:
  open-webui:
    volumes:
      - /home/ontoslive/ontos_data/openwebui-data-vps-current:/app/backend/data
EOF

cd "${WEBUI_DIR}"
$DOCKER_CMD compose -f docker-compose.yaml -f docker-compose.dev.yaml -f docker-compose.vpsdata.override.yaml up -d --force-recreate open-webui

"${STACK_DIR}/scripts/ow_whereami.sh"
echo "vps-current symlink:"
ls -la "${VPS_CURRENT_LINK}"
echo "open-webui mounts:"
$DOCKER_CMD inspect open-webui --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
echo "OpenWebUI URL: http://127.0.0.1:3000"
