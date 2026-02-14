#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
TS="$(date +%Y%m%d_%H%M%S)"
ART_DIR="${STACK_DIR}/ops/state/${TS}_backup"
CONFIG_DIR="${ART_DIR}/config"

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
    notify-send "ontogit backup" "Success: ${TS}" >/dev/null 2>&1 || true
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
    notify-send "ontogit backup" "Failed: ${msg}" >/dev/null 2>&1 || true
  fi
}

mkdir -p "${ART_DIR}" "${CONFIG_DIR}"

DOCKER_BIN="$(command -v docker || true)"
if [ -z "${DOCKER_BIN}" ]; then
  echo "docker not found in PATH" > "${ART_DIR}/backup.log"
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
NEED_SUDO=0

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

_pack_dir_gz() {
  local src="$1"
  local out="$2"
  if [ ! -d "${src}" ]; then
    return 1
  fi
  tar -C "${src}" -czf "${out}" .
}

_pack_volume_gz() {
  local vol="$1"
  local out="$2"
  if ! "${DOCKER_CMD[@]}" volume inspect "${vol}" >/dev/null 2>&1; then
    return 1
  fi
  "${DOCKER_CMD[@]}" run --rm -v "${vol}:/data:ro" -v "${ART_DIR}:/backup" alpine \
    tar -C /data -czf "/backup/$(basename "${out}")" .
}

"${DOCKER_CMD[@]}" ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' > "${ART_DIR}/docker_ps.txt"
"${DOCKER_CMD[@]}" images --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}' \
  | rg -i 'ontogit|open-webui|qdrant' > "${ART_DIR}/docker_images.txt" || true

(cd "${STACK_DIR}" && "${COMPOSE_CMD[@]}" -f docker-compose.yml -f docker-compose.webui-ontogate.yml config) > "${CONFIG_DIR}/compose.config.yml"
cp "${STACK_DIR}/docker-compose.yml" "${CONFIG_DIR}/docker-compose.yml"
cp "${STACK_DIR}/docker-compose.webui-ontogate.yml" "${CONFIG_DIR}/docker-compose.webui-ontogate.yml"
if [ -f "${STACK_DIR}/policy/onto_policy.yml" ]; then
  cp "${STACK_DIR}/policy/onto_policy.yml" "${CONFIG_DIR}/onto_policy.yml"
fi

if _pack_dir_gz "${OPENWEBUI_DATA}" "${ART_DIR}/openwebui-data.tar.gz"; then
  :
fi
if _pack_dir_gz "${ONTOGIT_USER_DIR}" "${ART_DIR}/ontogit-user.tar.gz"; then
  :
fi
if [ -d "${SCENES_DIR}" ]; then
  if sudo -n true >/dev/null 2>&1; then
    sudo tar -C "${SCENES_DIR}" -czf "${ART_DIR}/ontogit-repo.tar.gz" .
  else
    echo "need sudo to backup /root/ontogit" >> "${ART_DIR}/backup.log"
    NEED_SUDO=1
  fi
fi
if _pack_volume_gz "${QDRANT_VOL}" "${ART_DIR}/qdrant.tar.gz"; then
  :
fi

cat > "${ART_DIR}/how_to_repeat.txt" <<TXT
./scripts/backup.sh
SCENES_DIR=${SCENES_DIR} ./scripts/backup.sh
archived: openwebui-data.tar.gz ontogit-user.tar.gz ontogit-repo.tar.gz qdrant.tar.gz
TXT

if [ "${NEED_SUDO}" -ne 0 ]; then
  notify_fail "need sudo to backup /root/ontogit"
  exit 1
fi

notify_ok
exit 0
