#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
WEBUI_DIR="/home/ontoslive/ontos_work/open-webui-src"
DATA_BASE="/home/ontoslive/ontos_data"
DATA_ONTOS_USER="${DATA_BASE}/ontogit-user"
DATA_WEBUI="${DATA_BASE}/openwebui-data"

echo "==> create data dirs"
mkdir -p "$DATA_ONTOS_USER" "$DATA_WEBUI"
chown ontoslive:ontoslive "$DATA_ONTOS_USER" "$DATA_WEBUI"
chmod 700 "$DATA_ONTOS_USER" "$DATA_WEBUI"

echo "==> create .env.local if missing"
if [ ! -f "${STACK_DIR}/.env.local" ]; then
  cp "${STACK_DIR}/scripts/dev_env.example" "${STACK_DIR}/.env.local"
  echo "created ${STACK_DIR}/.env.local"
fi
if [ ! -f "${WEBUI_DIR}/.env.local" ]; then
  cp "${WEBUI_DIR}/.env.local.example" "${WEBUI_DIR}/.env.local"
  echo "created ${WEBUI_DIR}/.env.local"
fi

echo "==> edit secrets"
echo "Set ONTOS_SERVICE_AUTH_SECRET in:"
echo "  ${STACK_DIR}/.env.local"
echo "  ${WEBUI_DIR}/.env.local"
