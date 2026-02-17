#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
BACKUP_DIR="${BACKUP_DIR:-}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ontogit-stack}"
export COMPOSE_PROJECT_NAME

if [ -z "${BACKUP_DIR}" ]; then
  echo "BACKUP_DIR is required (e.g., BACKUP_DIR=ops/state/<ts>_backup)"
  exit 1
fi
if [ ! -d "${BACKUP_DIR}" ]; then
  echo "BACKUP_DIR not found: ${BACKUP_DIR}"
  exit 1
fi

DOCKER_BIN=""
DOCKER_CMD=()
COMPOSE_CMD=()

notify_ok() {
  if command -v paplay >/dev/null 2>&1; then
    paplay /usr/share/sounds/freedesktop/stereo/complete.oga >/dev/null 2>&1 || true
  else
    printf '\a' || true
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "ontogit restore" "Success: ${BACKUP_DIR}" >/dev/null 2>&1 || true
  fi
}

notify_fail() {
  local msg="$1"
  if command -v paplay >/dev/null 2>&1; then
    paplay /usr/share/sounds/freedesktop/stereo/dialog-error.oga >/dev/null 2>&1 || true
  else
    printf '\a' || true
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "ontogit restore" "Failed: ${msg}" >/dev/null 2>&1 || true
  fi
}

DOCKER_BIN="$(command -v docker || true)"
if [ -z "${DOCKER_BIN}" ]; then
  echo "docker not found in PATH"
  notify_fail "docker not found"
  exit 1
fi

DOCKER_CMD=("${DOCKER_BIN}")
if ! "${DOCKER_CMD[@]}" ps >/dev/null 2>&1; then
  DOCKER_CMD=(sudo "${DOCKER_BIN}")
fi
COMPOSE_CMD=("${DOCKER_BIN}" "compose")
if ! "${COMPOSE_CMD[@]}" version >/dev/null 2>&1; then
  COMPOSE_CMD=(sudo "${DOCKER_BIN}" "compose")
fi

OPENWEBUI_DATA_DEFAULT="/home/ontoslive/ontos_data/openwebui-data-vps-current"
OPENWEBUI_DATA_FALLBACK="/home/ontoslive/ontos_data/openwebui-data"
ONTOGIT_USER_DIR="/home/ontoslive/ontos_data/ontogit-user"
SCENES_DIR="${SCENES_DIR:-/root/ontogit}"
QDRANT_VOL="qdrant_storage"

data_mount="$("${DOCKER_CMD[@]}" inspect open-webui --format '{{range .Mounts}}{{if eq .Destination "/app/backend/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
if [ -z "${data_mount}" ]; then
  data_mount="$("${DOCKER_CMD[@]}" inspect ontogit-stack-open-webui-1 --format '{{range .Mounts}}{{if eq .Destination "/app/backend/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
fi
if [ -n "${data_mount}" ]; then
  OPENWEBUI_DATA="${data_mount}"
elif [ -d "${OPENWEBUI_DATA_DEFAULT}" ]; then
  OPENWEBUI_DATA="${OPENWEBUI_DATA_DEFAULT}"
else
  OPENWEBUI_DATA="${OPENWEBUI_DATA_FALLBACK}"
fi

_extract_archive() {
  local archive="$1"
  local dest="$2"
  if [ ! -f "${archive}" ]; then
    return 1
  fi
  mkdir -p "${dest}"
  tar -C "${dest}" -xzf "${archive}"
}

_restore_volume() {
  local archive="$1"
  local vol="$2"
  if [ ! -f "${archive}" ]; then
    return 1
  fi
  if ! "${DOCKER_CMD[@]}" volume inspect "${vol}" >/dev/null 2>&1; then
    return 1
  fi
  "${DOCKER_CMD[@]}" run --rm -i -v "${vol}:/data" -v "${BACKUP_DIR}:/backup" alpine \
    tar -C /data -xzf "/backup/$(basename "${archive}")"
}

needs_stop=()
if ls "${BACKUP_DIR}"/openwebui-data.tar.gz >/dev/null 2>&1; then
  needs_stop+=("open-webui")
fi
if ls "${BACKUP_DIR}"/ontogit-user.tar.gz >/dev/null 2>&1; then
  needs_stop+=("usage-writer" "memory-service")
fi
if ls "${BACKUP_DIR}"/qdrant.tar.gz >/dev/null 2>&1; then
  needs_stop+=("qdrant")
fi
if ls "${BACKUP_DIR}"/ontogit-repo.tar.gz >/dev/null 2>&1; then
  needs_stop+=("memory-service")
fi

if [ "${#needs_stop[@]}" -gt 0 ]; then
  (cd "${STACK_DIR}" && "${COMPOSE_CMD[@]}" -f docker-compose.yml -f docker-compose.webui-ontogate.yml stop "${needs_stop[@]}") || true
fi

_extract_archive "${BACKUP_DIR}"/openwebui-data.tar.gz "${OPENWEBUI_DATA}" || true
_extract_archive "${BACKUP_DIR}"/ontogit-user.tar.gz "${ONTOGIT_USER_DIR}" || true
if [ -f "${BACKUP_DIR}/ontogit-repo.tar.gz" ]; then
  if sudo -n true >/dev/null 2>&1; then
    sudo mkdir -p "${SCENES_DIR}"
    sudo tar -C "${SCENES_DIR}" -xzf "${BACKUP_DIR}/ontogit-repo.tar.gz"
  else
    notify_fail "need sudo to restore /root/ontogit"
    exit 1
  fi
fi
_restore_volume "${BACKUP_DIR}"/qdrant.tar.gz "${QDRANT_VOL}" || true

(cd "${STACK_DIR}" && "${COMPOSE_CMD[@]}" -f docker-compose.yml -f docker-compose.webui-ontogate.yml up -d)

if ! curl -fsS http://127.0.0.1:3000/api/version >/dev/null; then
  notify_fail "open-webui health failed"
  exit 1
fi
if ! curl -fsS http://127.0.0.1:8088/v1/models >/dev/null; then
  notify_fail "openai-proxy health failed"
  exit 1
fi
if ! curl -fsS "http://127.0.0.1:8091/report/daily?days=1" >/dev/null; then
  notify_fail "usage-writer report failed"
  exit 1
fi

notify_ok
exit 0
