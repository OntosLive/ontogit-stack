#!/usr/bin/env bash
set -euo pipefail

LOCAL_PATH="/home/ontoslive/ontos_data/openwebui-data"
VPS_LINK_PATH="/home/ontoslive/ontos_data/openwebui-data-vps-current"
STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"

DOCKER_CMD="docker"
if ! docker ps >/dev/null 2>&1; then
  if sudo -n docker ps >/dev/null 2>&1 || sudo -E docker ps >/dev/null 2>&1; then
    DOCKER_CMD="sudo -E docker"
  else
    echo "Docker is not accessible (direct or via sudo)."
    exit 1
  fi
fi

echo "time: $(date -Iseconds)"
echo "host: $(hostname)"
SECRET_STATUS="missing"
if [ -n "${ONTOS_SERVICE_AUTH_SECRET:-}" ]; then
  SECRET_STATUS="present"
elif [ -f "${STACK_DIR}/.env.local" ] && rg -q '^ONTOS_SERVICE_AUTH_SECRET=\S' "${STACK_DIR}/.env.local"; then
  SECRET_STATUS="present"
fi
echo "service_auth_secret: ${SECRET_STATUS}"

PS_LINE="$($DOCKER_CMD ps --filter name='^open-webui$' --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | head -n1 || true)"
if [ -z "${PS_LINE}" ]; then
  echo "open-webui container not found (expected name: open-webui)"
  exit 1
fi

echo "open-webui: ${PS_LINE}"

PROJECT_LABEL="$($DOCKER_CMD inspect open-webui --format '{{ index .Config.Labels "com.docker.compose.project" }}' 2>/dev/null || true)"
CONFIG_LABEL="$($DOCKER_CMD inspect open-webui --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' 2>/dev/null || true)"
echo "compose.project: ${PROJECT_LABEL:-unknown}"
echo "compose.config_files: ${CONFIG_LABEL:-unknown}"

echo "mounts:"
$DOCKER_CMD inspect open-webui --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'

DATA_MOUNT="$($DOCKER_CMD inspect open-webui --format '{{range .Mounts}}{{if eq .Destination "/app/backend/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
if [ -z "${DATA_MOUNT}" ]; then
  echo "active_universe: unknown (no /app/backend/data mount found)"
else
  echo "data_mount_host_path: ${DATA_MOUNT}"
  if [ "${DATA_MOUNT}" = "${LOCAL_PATH}" ]; then
    echo "active_universe: local (openwebui-data)"
  elif [ "${DATA_MOUNT}" = "${VPS_LINK_PATH}" ]; then
    echo "active_universe: vps-current (openwebui-data-vps-current)"
  else
    echo "active_universe: custom (${DATA_MOUNT})"
  fi
fi

NETWORKS="$($DOCKER_CMD inspect open-webui --format '{{range $name, $_ := .NetworkSettings.Networks}}{{printf "%s\n" $name}}{{end}}' 2>/dev/null || true)"
echo "networks:"
if [ -n "${NETWORKS}" ]; then
  printf '%s\n' "${NETWORKS}"
else
  echo "unknown"
fi
