#!/usr/bin/env bash
set -euo pipefail

BACKEND=""
MODE="unknown"

http_code() {
  local url="$1"
  curl -sS -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null || true
}

is_reachable_code() {
  local code="$1"
  [ -n "${code}" ] && [ "${code}" != "000" ]
}

port_3010_listening=0
if ss -lnt 2>/dev/null | rg -q '[:.]3010[[:space:]]'; then
  port_3010_listening=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  if sudo ss -lnt 2>/dev/null | rg -q '[:.]3010[[:space:]]'; then
    port_3010_listening=1
  fi
fi

port_3000_listening=0
if ss -lnt 2>/dev/null | rg -q '[:.]3000[[:space:]]'; then
  port_3000_listening=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  if sudo ss -lnt 2>/dev/null | rg -q '[:.]3000[[:space:]]'; then
    port_3000_listening=1
  fi
fi

domain_code="$(http_code "https://alba.ontos.live/api/version")"
local_root_code="$(http_code "http://127.0.0.1:3000")"
local_api_code="$(http_code "http://127.0.0.1:3000/api/version")"

if [ -f /etc/nginx/snippets/alba_switch_map.conf ]; then
  BACKEND="$(
    grep -Eo '127\.0\.0\.1:(3000|3010)' /etc/nginx/snippets/alba_switch_map.conf 2>/dev/null \
      | head -n 1 || true
  )"
fi

if [ -z "${BACKEND}" ] && command -v nginx >/dev/null 2>&1; then
  BACKEND="$(
    nginx -T 2>/dev/null \
      | grep -Eo '127\.0\.0\.1:(3000|3010)' \
      | head -n 1 || true
  )"
fi

case "${BACKEND}" in
  127.0.0.1:3000) MODE="blue" ;;
  127.0.0.1:3010) MODE="green" ;;
  *) MODE="unknown" ;;
esac

# Runtime mode (canonical for operators)
if [ "${port_3010_listening}" = "1" ] || is_reachable_code "${domain_code}"; then
  MODE="door_tunnel"
elif is_reachable_code "${local_root_code}" || [ "${port_3000_listening}" = "1" ]; then
  MODE="local_only"
fi

echo "alba_backend=${BACKEND:-unknown}"
echo "mode=${MODE}"

echo ""
echo "ss -lntp"
if ss -lntp >/dev/null 2>&1; then
  ss -lntp
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  sudo ss -lntp
else
  echo "ss requires sudo"
fi

echo ""
echo "curl checks (3011=/v1/models, 3012=/report/daily?days=7)"
if [ "${MODE}" = "local_only" ]; then
  printf '%s -> %s\n' "http://127.0.0.1:3000" "${local_root_code:-ERR}"
  printf '%s -> %s\n' "http://127.0.0.1:3000/api/version" "${local_api_code:-ERR}"
  printf '%s -> %s\n' "http://127.0.0.1:3010/api/version" "skip(local_only)"
  printf '%s -> %s\n' "http://127.0.0.1:3011/v1/models" "skip(local_only)"
  printf '%s -> %s\n' "http://127.0.0.1:3012/report/daily?days=7" "skip(local_only)"
  printf '%s -> %s\n' "https://alba.ontos.live/api/version" "skip(local_only)"
else
  for target in \
    "http://127.0.0.1:3010/api/version" \
    "http://127.0.0.1:3011/v1/models" \
    "http://127.0.0.1:3012/report/daily?days=7" \
    "https://alba.ontos.live/api/version"; do
    code="$(http_code "${target}")"
    printf '%s -> %s\n' "${target}" "${code:-ERR}"
  done
fi
