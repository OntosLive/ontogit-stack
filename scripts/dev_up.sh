#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
WEBUI_DIR="/home/ontoslive/ontos_work/open-webui-src"

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

(cd "$STACK_DIR" && docker compose up -d --build)
(cd "$WEBUI_DIR" && docker compose up -d --build)

"${STACK_DIR}/scripts/dev_doctor.sh"
