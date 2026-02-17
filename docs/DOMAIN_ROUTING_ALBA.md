# DOMAIN ROUTING: alba.ontos.live

## Scope
This runbook restores and verifies the canonical Alba door+tunnel path where VPS nginx proxies to `127.0.0.1:3010`, and that port is fed by a reverse SSH tunnel from local OpenWebUI `127.0.0.1:3000`.

Canonical references:
- `START_HERE.md`
- `docs/ONTOGIT_CANON.md`
- `guides/DEPLOY_DOOR_TUNNEL.md`
- `guides/NGINX_SWITCH_BLUE_GREEN.md`
- `scripts/ops/alba_local_tunnel_unit_install.sh`
- `scripts/ops/alba_status.sh`

## Topology (canonical)
```text
Internet
  -> https://alba.ontos.live
  -> VPS nginx (public 443)
  -> upstream $alba_backend
     -> blue:  127.0.0.1:3000 (VPS-local OpenWebUI)
     -> green: 127.0.0.1:3010 (reverse SSH tunnel endpoint on VPS)

Green tunnel source:
local machine (where OpenWebUI runs on 127.0.0.1:3000)
  autossh/systemd `alba-revtunnel.service`
  -R 127.0.0.1:3010:127.0.0.1:3000
  -R 127.0.0.1:3011:127.0.0.1:8088
  -R 127.0.0.1:3012:127.0.0.1:8091
  -> VPS 194.31.175.16
```

## Historical implementation (source-of-truth)
The historical and canonical implementation is `autossh` under systemd, unit name `alba-revtunnel.service`.

Evidence in repo:
- `scripts/ops/alba_local_tunnel_unit_install.sh:4`
- `scripts/ops/alba_local_tunnel_unit_install.sh:22`
- `scripts/ops/alba_local_tunnel_unit_install.sh:27`
- `guides/DEPLOY_DOOR_TUNNEL.md:36`
- `guides/DEPLOY_DOOR_TUNNEL.md:25`
- commit introducing this: `471bcd8`.

## Exact canonical unit
Place on the **local machine** (the host that has OpenWebUI on `127.0.0.1:3000`):
- File path: `/etc/systemd/system/alba-revtunnel.service`

```ini
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
```

## Restore procedure (canonical)
Run on the local machine:

```bash
cd /home/ontoslive/ontos_work/ontogit-stack
./scripts/ops/alba_local_tunnel_unit_install.sh
```

Install and start:

```bash
TS="$(date +%Y%m%d_%H%M%S)"
if [ -f /etc/systemd/system/alba-revtunnel.service ]; then
  sudo cp -a /etc/systemd/system/alba-revtunnel.service /etc/systemd/system/alba-revtunnel.service.bak.${TS}
fi
sudo cp -a ./alba-revtunnel.service /etc/systemd/system/alba-revtunnel.service
sudo systemctl daemon-reload
sudo systemctl enable --now alba-revtunnel.service
sudo systemctl status --no-pager alba-revtunnel.service
```

If needed:

```bash
sudo journalctl -u alba-revtunnel.service -n 200 --no-pager
```

## VPS nginx switch target
VPS nginx should point to green backend when using tunnel:
- Snippet path: `/etc/nginx/snippets/alba_switch_map.conf`
- Green target: `default 127.0.0.1:3010;`

Reference helper:
- `scripts/ops/alba_door_switch.sh` (generates exact snippet and reload commands)
- `scripts/ops/alba_status.sh` (reads current backend mode and probes)

## Verification checklist
1. On VPS, tunnel listener exists:
```bash
ss -ltnp | grep :3010
```

2. On VPS, upstream is alive through tunnel:
```bash
curl -fsS http://127.0.0.1:3010/api/version
```

3. From internet, domain works end-to-end:
```bash
curl -fsS https://alba.ontos.live/api/version
```

Optional full status from VPS:
```bash
cd /home/ontoslive/ontos_work/ontogit-stack
./scripts/ops/alba_status.sh
```

## Likely 502 cause when local `127.0.0.1:3000` works
If nginx is switched to green (`127.0.0.1:3010`) and `alba-revtunnel.service` is down or not forwarding, nginx has no healthy upstream on VPS loopback and returns `502 Bad Gateway`.

## Safe minimal recovery path
1. Restore/start `alba-revtunnel.service` on local machine (commands above).
2. Confirm VPS `127.0.0.1:3010/api/version` is HTTP 200.
3. Confirm public `https://alba.ontos.live/api/version` is HTTP 200.

Rollback:
- Restore previous unit backup from `/etc/systemd/system/alba-revtunnel.service.bak.<TS>`.
- `sudo systemctl daemon-reload && sudo systemctl restart alba-revtunnel.service`.
