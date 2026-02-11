#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
WEBUI_DIR="/home/ontoslive/ontos_work/open-webui-src"
DATA_ONTOS_USER="/home/ontoslive/ontos_data/ontogit-user"
DATA_WEBUI="/home/ontoslive/ontos_data/openwebui-data"

header() { echo; echo "==> $*"; }

DOCKER_CMD="docker"
if ! docker ps >/dev/null 2>&1; then
  if sudo -n docker ps >/dev/null 2>&1; then
    DOCKER_CMD="sudo -n docker"
    echo "Docker requires sudo in this environment"
  else
    echo "Docker not доступен (direct or sudo). Some checks may fail."
  fi
fi

repo_status() {
  local dir="$1"
  echo "dir: $dir"
  if [ -d "$dir/.git" ]; then
    local branch
    branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    echo "branch: ${branch:-unknown}"
    git -C "$dir" status --short || true
  else
    echo "not a git repo"
  fi
}

container_id() {
  local name="$1"
  $DOCKER_CMD ps --format '{{.ID}} {{.Names}} {{.Image}}' | rg -i "$name" | head -n1 | awk '{print $1}'
}

container_ports() {
  local cid="$1"
  $DOCKER_CMD ps --format '{{.ID}} {{.Names}} {{.Status}} {{.Ports}}' | rg -i "^${cid}" || true
}

header "repo status"
repo_status "$STACK_DIR"
repo_status "$WEBUI_DIR"

header "docker ps"
$DOCKER_CMD ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

header "containers"
mem_id="$(container_id memory-service)"
web_id="$(container_id open-webui)"
echo "memory-service id: ${mem_id:-not running}"
if [ -n "${mem_id:-}" ]; then
  container_ports "$mem_id"
  echo "mounts:"
  $DOCKER_CMD inspect "$mem_id" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' | rg -e '/ontogit_user'
fi
echo "open-webui id: ${web_id:-not running}"
if [ -n "${web_id:-}" ]; then
  container_ports "$web_id"
  echo "mounts:"
  $DOCKER_CMD inspect "$web_id" --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' | rg -e '/app/backend/data'
fi

header "host data checks"
if [ -f "${DATA_ONTOS_USER}/usage.db" ]; then
  echo "usage.db: $(ls -lh "${DATA_ONTOS_USER}/usage.db" | awk '{print $5, $9}')"
else
  echo "usage.db: missing (${DATA_ONTOS_USER}/usage.db)"
fi
if [ -d "${DATA_WEBUI}" ]; then
  echo "openwebui-data:"
  ls -la "${DATA_WEBUI}" | head -n 5
else
  echo "openwebui-data: missing (${DATA_WEBUI})"
fi

header "http checks"
health_code="$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8090/health || true)"
commit_code="$(curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8090/commit -H "Content-Type: application/json" -d '{"title":"t","body":"b"}' || true)"
echo "/health status: ${health_code} (may be 200 if service-auth set)"
echo "/commit status: ${commit_code} (should be 401 without service-auth)"

header "summary"
ok_mounts="FAIL"
if [ -d "${DATA_ONTOS_USER}" ] && [ -d "${DATA_WEBUI}" ]; then ok_mounts="OK"; fi
secret_present="FAIL"
if [ -f "${STACK_DIR}/.env.local" ] && rg -q "^ONTOS_SERVICE_AUTH_SECRET=\\S" "${STACK_DIR}/.env.local"; then secret_present="OK"; fi
usage_db_present="FAIL"
if [ -f "${DATA_ONTOS_USER}/usage.db" ]; then usage_db_present="OK"; fi
echo "mounts: ${ok_mounts}"
echo "secret in ${STACK_DIR}/.env.local: ${secret_present}"
echo "usage.db: ${usage_db_present}"
