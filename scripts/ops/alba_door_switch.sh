#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 blue|green" >&2
  exit 2
fi

MODE="$1"
BACKEND=""
case "${MODE}" in
  blue) BACKEND="127.0.0.1:3000" ;;
  green) BACKEND="127.0.0.1:3010" ;;
  *)
    echo "unknown mode: ${MODE} (use blue or green)" >&2
    exit 2
    ;;
esac

TS="$(date +%Y%m%d_%H%M%S)"
STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
ART_DIR="${STACK_DIR}/ops/state/${TS}_alba_switch"
mkdir -p "${ART_DIR}"

INSTR_FILE="${ART_DIR}/how_to_apply.txt"
if [ -f "${INSTR_FILE}" ]; then
  cp -a "${INSTR_FILE}" "${INSTR_FILE}.bak.${TS}"
fi

cat > "${INSTR_FILE}" <<TXT
Mode: ${MODE}
Target: ${BACKEND}

Apply on VPS:

# Backup existing snippet first
if [ -f /etc/nginx/snippets/alba_switch_map.conf ]; then
  sudo cp -a /etc/nginx/snippets/alba_switch_map.conf /etc/nginx/snippets/alba_switch_map.conf.bak.${TS}
fi

# Write new snippet
sudo tee /etc/nginx/snippets/alba_switch_map.conf >/dev/null <<'EOF'
map \$host \$alba_backend {
    default ${BACKEND};
}
EOF

# Validate and reload
sudo nginx -t
sudo systemctl reload nginx
TXT

cat <<EOF
map \$host \$alba_backend {
    default ${BACKEND};
}
EOF
