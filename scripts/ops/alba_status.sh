#!/usr/bin/env bash
set -euo pipefail

BACKEND=""
MODE="unknown"

if [ -f /etc/nginx/snippets/alba_switch_map.conf ]; then
  BACKEND="$(rg -o "127\.0\.0\.1:(3000|3010)" /etc/nginx/snippets/alba_switch_map.conf 2>/dev/null | head -n 1 || true)"
fi

if [ -z "${BACKEND}" ] && command -v nginx >/dev/null 2>&1; then
  BACKEND="$(nginx -T 2>/dev/null | rg -o "127\.0\.0\.1:(3000|3010)" | head -n 1 || true)"
fi

case "${BACKEND}" in
  127.0.0.1:3000) MODE="blue" ;;
  127.0.0.1:3010) MODE="green" ;;
  *) MODE="unknown" ;;
esac

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
echo "curl checks"
for target in \
  "http://127.0.0.1:3010/api/version" \
  "http://127.0.0.1:3011/" \
  "http://127.0.0.1:3012/" \
  "https://alba.ontos.live/api/version"; do
  code="$(curl -fsS -o /dev/null -w '%{http_code}' "${target}" 2>/dev/null || true)"
  printf '%s -> %s\n' "${target}" "${code:-ERR}"
done
