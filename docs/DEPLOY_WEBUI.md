# Deploy OpenWebUI (Pinned Image)

Script: `scripts/deploy_openwebui.sh`

## What it does
- Resolves `COMMIT` in `open-webui-src` (`HEAD` by default).
- Creates a temporary git worktree for that commit.
- Builds image: `open-webui-ontogate:<shortsha>`.
- Updates pin in `docker-compose.webui-ontogate.yml`.
- Recreates only `open-webui` service.
- Waits up to 60s for `healthy` (or `running` if no healthcheck).
- Verifies `GET http://127.0.0.1:3000/api/version`.
- Saves deployment artifacts to `ops/state/<ts>_deploy_openwebui/`.
- Sends desktop notification/sound on success or failure.

## Usage
```bash
cd /home/ontoslive/ontos_work/ontogit-stack
./scripts/deploy_openwebui.sh
```

Deploy a specific commit from `open-webui-src`:
```bash
cd /home/ontoslive/ontos_work/ontogit-stack
COMMIT=<sha> ./scripts/deploy_openwebui.sh
```

## Artifacts
Each run writes:
- `deploy.log`
- `compose_pin_before.yml`
- `compose_pin_after.yml`
- `compose_pin.diff`
- `docker_ps.txt`
- `openwebui_inspect.json`
- `docker_images_openwebui_ontogate.txt`
- `api_version.json`
- `how_to_repeat.txt`

## Notes
- The script is idempotent for repeated deploys of the same commit.
- Temporary worktree is always cleaned up (even on failure).
- Docker Desktop WSL: run docker as your user; sudo may break socket/context. The script prefers user docker and falls back to sudo only if needed.
