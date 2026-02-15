#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
BASE_DIR="$(pwd)"
OUTDIR="${OUTDIR:-${BASE_DIR}/ops/state}"
ART_DIR="${OUTDIR}/${TS}_alba_capture"
NGINX_DIR="${ART_DIR}/nginx"

mkdir -p "${ART_DIR}" "${NGINX_DIR}"

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [ -f "${src}" ]; then
    mkdir -p "$(dirname "${dst}")"
    cp -a "${src}" "${dst}"
  fi
}

copy_if_exists "/etc/nginx/snippets/alba_switch_map.conf" "${NGINX_DIR}/alba_switch_map.conf"
copy_if_exists "/etc/nginx/sites-enabled/alba.ontos.live" "${NGINX_DIR}/alba.ontos.live.sites-enabled"
copy_if_exists "/etc/nginx/sites-available/alba.ontos.live" "${NGINX_DIR}/alba.ontos.live.sites-available"

if command -v nginx >/dev/null 2>&1; then
  nginx -T > "${NGINX_DIR}/nginx_T.txt" 2> "${NGINX_DIR}/nginx_T.err" || true
fi

DOCKER_BIN="$(command -v docker || true)"
DOCKER_CMD=()
if [ -n "${DOCKER_BIN}" ]; then
  DOCKER_CMD=("${DOCKER_BIN}")
  if ! "${DOCKER_CMD[@]}" ps >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
      DOCKER_CMD=(sudo "${DOCKER_BIN}")
    fi
  fi
  "${DOCKER_CMD[@]}" ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' > "${ART_DIR}/docker_ps.txt" || true
fi

if ss -lntp >/dev/null 2>&1; then
  ss -lntp > "${ART_DIR}/ss_lntp.txt"
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  sudo ss -lntp > "${ART_DIR}/ss_lntp.txt"
else
  echo "ss requires sudo" > "${ART_DIR}/ss_lntp.txt"
fi

curl_check() {
  local url="$1"
  local name="$2"
  local code
  code="$(curl -fsS -o "${ART_DIR}/${name}.body" -w '%{http_code}' "${url}" 2>"${ART_DIR}/${name}.err" || true)"
  echo "${url} -> ${code}" > "${ART_DIR}/${name}.status"
}

curl_check "http://127.0.0.1:3010/api/version" "curl_3010_api_version"
curl_check "http://127.0.0.1:3011/" "curl_3011_root"
curl_check "http://127.0.0.1:3012/" "curl_3012_root"
curl_check "https://alba.ontos.live/api/version" "curl_alba_api_version"

echo "artifacts=${ART_DIR}"
