#!/usr/bin/env bash
set -euo pipefail

UNIT_NAME="alba-revtunnel.service"
OUT_FILE="./${UNIT_NAME}"
TS="$(date +%Y%m%d_%H%M%S)"

if [ -f "${OUT_FILE}" ]; then
  cp -a "${OUT_FILE}" "${OUT_FILE}.bak.${TS}"
fi

cat > "${OUT_FILE}" <<'UNIT'
[Unit]
Description=Alba reverse tunnel (autossh)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=ontoslive
Environment="AUTOSSH_GATETIME=0"
ExecStart=/usr/bin/autossh -M 0 -N \
  -o "ServerAliveInterval 30" \
  -o "ServerAliveCountMax 3" \
  -o "ExitOnForwardFailure yes" \
  -i /home/ontoslive/.ssh/id_ed25519 \
  -R 127.0.0.1:3010:127.0.0.1:3000 \
  -R 127.0.0.1:3011:127.0.0.1:8088 \
  -R 127.0.0.1:3012:127.0.0.1:8091 \
  ontoslive@194.31.175.16
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

echo "Generated ${OUT_FILE}"

echo ""
echo "Install on local machine (with backup):"
cat <<TXT
if [ -f /etc/systemd/system/${UNIT_NAME} ]; then
  sudo cp -a /etc/systemd/system/${UNIT_NAME} /etc/systemd/system/${UNIT_NAME}.bak.${TS}
fi
sudo cp -a ${OUT_FILE} /etc/systemd/system/${UNIT_NAME}
sudo systemctl daemon-reload
sudo systemctl enable --now ${UNIT_NAME}
TXT
