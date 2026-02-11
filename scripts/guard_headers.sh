#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> check forbidden header names"
if rg -n "X-Ontos-Auth|X-Memory-Service-Auth" "$ROOT" "$ROOT/../open-webui-src" -g '!docs/**'; then
  echo "Forbidden header name found."
  exit 1
fi

echo "OK"
