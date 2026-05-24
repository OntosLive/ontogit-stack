# ALBA Source of Truth

This file is the canonical recovery and deployment entrypoint for ALBA / Ontos.Live.

## Absolute rule

There is exactly one valid way to deploy ALBA Open WebUI:

```bash
cd /home/ontoslive/ontos_work/ontogit-stack
./scripts/deploy_openwebui.sh
```

Do not deploy from `open-webui-src` directly.

## Canonical responsibilities

- `ontogit-stack` is the deployment/control repository.
- `open-webui-src` is source material used to build the custom image.
- `scripts/deploy_openwebui.sh` is the only deploy ritual.
- `docker-compose.webui-ontogate.yml` is the only Open WebUI compose overlay for ALBA.

## Canonical Open WebUI container

The correct runtime container must be created by the `ontogit-stack` compose project and must use an image named like:

```text
open-webui-ontogate:<tag>
```

The wrong container/image pattern is:

```text
open-webui
ghcr.io/open-webui/open-webui
```

If this appears on port 3000, it is the vanilla Open WebUI and must be stopped before canonical deploy.

## Canonical volume

The ALBA data volume mount is:

```text
/home/ontoslive/ontos_data/openwebui-data-vps-current:/app/backend/data
```

Do not replace it with the vanilla Open WebUI data mount unless explicitly migrating data.

## Canonical port

The public local port for nginx is:

```text
3000:8080
```

nginx must proxy `alba.ontos.live` to:

```text
http://127.0.0.1:3000
```

## Canonical supporting services

The Open WebUI container must use:

```text
OPENAI_API_BASE_URL=http://header-injector:8089
```

The compose overlay must include environment files:

```text
.env.stt
.env.local
```

## Recovery checklist after VPS stop/reboot/payment suspension

1. Restore SSH/network access first.
2. Confirm firewall allows established traffic, loopback, SSH, HTTP and HTTPS.
3. Stop accidental vanilla Open WebUI container if present:

```bash
docker stop open-webui 2>/dev/null || true
docker rm open-webui 2>/dev/null || true
```

4. Deploy only through the canonical script:

```bash
cd /home/ontoslive/ontos_work/ontogit-stack
./scripts/deploy_openwebui.sh
```

5. Verify:

```bash
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}"
curl -I --max-time 10 http://127.0.0.1:3000
curl -I --max-time 10 https://alba.ontos.live
```

Expected container/image pattern:

```text
ontogit-stack-open-webui-1    open-webui-ontogate:<tag>
```

## Explicitly forbidden deploy commands

Do not run:

```bash
cd /root/open-webui-src && docker compose up -d open-webui
cd /home/ontoslive/ontos_work/open-webui-src && docker compose up -d open-webui
```

Those commands bypass the ALBA ontogate image, canonical volume, header injector, STT env, local env and branding.

## Last verified recovery state

On the 2026-05-24 recovery, the host was canonized into this shape:

```text
canonical deploy repo: /home/ontoslive/ontos_work/ontogit-stack
canonical webui source repo: /home/ontoslive/ontos_work/open-webui-src
runtime container owning port 3000: ontogit-stack-open-webui-1
runtime image: open-webui-ontogate:e677d7c98
runtime volume: /home/ontoslive/ontos_data/openwebui-data-vps-current:/app/backend/data
local check: http://127.0.0.1:3000 -> 200 OK
public check: https://alba.ontos.live -> 200 OK
```

Legacy/non-canonical paths were isolated by renaming, not deleting:

```text
/home/ontoslive/ontos_work/ontogit-stack.NON_GIT_20260524_110824
/root/ontogit-stack.LEGACY_20260524_110824
/root/open-webui-src.LEGACY_20260524_110824
/root/open-webui.ACCIDENTAL.20260312_031220.LEGACY_20260524_110824
```

The vanilla image pattern `ghcr.io/open-webui/open-webui:main` was removed during recovery. If it returns and owns port 3000, it is a false runtime.

## Operator rule for assistants and agents

Before suggesting any ALBA deploy command, read this file first.

If this file conflicts with another README or compose file, this file wins.
