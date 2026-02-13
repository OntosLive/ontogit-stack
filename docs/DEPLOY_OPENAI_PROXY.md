# Deploy openai-proxy (one command)

Script: `scripts/deploy_openai_proxy.sh`

## Run
```bash
cd /home/ontoslive/ontos_work/ontogit-stack
./scripts/deploy_openai_proxy.sh
```

Deploy specific commit from `ontogit-stack`:
```bash
cd /home/ontoslive/ontos_work/ontogit-stack
COMMIT=<sha> ./scripts/deploy_openai_proxy.sh
```

Optional host port override for smoke:
```bash
OPENAI_PROXY_PORT=8088 ./scripts/deploy_openai_proxy.sh
```

## What it does
- Resolves `COMMIT` (`HEAD` by default) and computes `ontogit-openai-proxy:<shortsha>`.
- Builds and recreates only `openai-proxy`.
- Waits for `running`/`healthy` with timeout.
- Runs smoke request: `GET /v1/models`.
- Saves artifacts to `ops/state/<ts>_deploy_openai_proxy/`.
- Sends sound/desktop notification on success/failure.

## Artifacts
- `docker_ps.txt`
- `docker_logs_tail.txt` (last 200 lines)
- `docker_image.txt`
- `smoke_http.txt`
- `smoke_body.json`
- `how_to_repeat.txt`
- `deploy.log`

## Notes
- Docker Desktop WSL: run docker as your user; sudo may break socket/context. The script prefers user docker and falls back to sudo only if needed.

## Verify manually
```bash
curl -fsS http://127.0.0.1:8088/v1/models
```

## If connect_error or 429 appears
- Check `docker_logs_tail.txt` for upstream DNS/timeout messages and retry behavior.
- Check that upstream base URL resolves in docker network (`OPENAI_API_BASE_URL`).
- If `429`, verify limits/policy mode and current request storm source before redeploy.
