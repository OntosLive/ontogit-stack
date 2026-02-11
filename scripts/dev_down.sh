#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
WEBUI_DIR="/home/ontoslive/ontos_work/open-webui-src"

(cd "$STACK_DIR" && docker compose down)
(cd "$WEBUI_DIR" && docker compose down)
