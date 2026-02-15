# Alba Door + Tunnel (Blue/Green)

This is the canonical door+tunnel model for `alba.ontos.live`.

## Topology

- Door = VPS nginx + HTTPS (public).
- Backend = local runtime behind the door via two paths:
- Blue: server-local OpenWebUI on VPS `127.0.0.1:3000`.
- Green: local machine via SSH reverse tunnel `127.0.0.1:3010` (from local `127.0.0.1:3000`).

```
[Internet] -> https://alba.ontos.live (VPS nginx)
                         |
                         +-> blue: 127.0.0.1:3000 (VPS local)
                         +-> green: 127.0.0.1:3010 (SSH reverse tunnel)
```

## SSH Reverse Tunnel (green)

Command (run on the local machine):

```bash
ssh -N \
  -R 127.0.0.1:3010:127.0.0.1:3000 \
  -R 127.0.0.1:3011:127.0.0.1:8088 \
  -R 127.0.0.1:3012:127.0.0.1:8091 \
  <vps-user>@194.31.175.16
```

Ports:
- `3010` -> OpenWebUI `3000`
- `3011` -> usage-writer `8088`
- `3012` -> header-injector `8091`

## Recommended: systemd + autossh

Prefer an `autossh` systemd unit for resilience. See `scripts/ops/alba_local_tunnel_unit_install.sh` to generate a ready unit file.

## Smoke tests (VPS)

```bash
ss -lntp
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3010/api/version
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3011/
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3012/
curl -fsS -o /dev/null -w '%{http_code}\n' https://alba.ontos.live/api/version
```

## Security notes

- Bind tunnel ports to `127.0.0.1` only (never `0.0.0.0`).
- Optional: add basic-auth at nginx for the door if needed.

## STT Profiles

Switch profiles with one command:

```bash
./scripts/ops/stt_profile_switch.sh gpu
./scripts/ops/stt_profile_switch.sh cpu
```
