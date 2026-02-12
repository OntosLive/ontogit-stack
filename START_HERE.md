# START HERE

This repo contains the **OntoGit stack** and its **OpenWebUI integration**. It is the single entry point for local dev and ops.

**Spec**: `docs/ONTOGIT_CANON.md` (authoritative canon for headers/env/recall route/limits/usage).

## Governance
- Governance: see `docs/governance/README.md`
- Run: `./scripts/smoke_governance.sh`

## Codex-first workflow
- Codex is the preferred executor for repo changes.
- When requesting changes, provide a clear Codex task prompt.
- Operator runs provided scripts and shares outputs/logs; Codex edits repo files via reviewable diffs.
- Never edit secrets; never run `dev_reset` unless explicitly requested.

## Two spaces: Local (WSL2) vs Server (VPS)
- We develop and run in two parallel environments:
- A) Local / WSL2 (fast iteration)
- B) Server / VPS (persistent users/chats)
- These are different storage universes unless explicitly migrated.
- OpenWebUI universe = `/app/backend/data` (host mount); different mounts = different universe.
- Never assume accounts/chats transfer automatically.

### Link protocol
1. Identify compose project + config files via docker labels.
2. Identify data mount for `/app/backend/data`.
3. For migration: stop service, backup target, copy `webui.db*` + `.webui_secret_key` + `uploads/`.
4. Validate by opening UI and confirming existing users.

## Operator switches
- `scripts/ow_whereami.sh` - what universe is active right now.
- `scripts/ow_local.sh` - switch OpenWebUI to local universe mounts.
- `scripts/ow_vps.sh` - switch OpenWebUI to VPS universe mounts.
- Universes are defined by the host path mounted to `/app/backend/data`.

**Dev Ops scripts**:
- `scripts/dev_bootstrap.sh`
- `scripts/dev_up.sh`
- `scripts/dev_doctor.sh`
- `scripts/smoke_ontogit.sh`
- `scripts/autofix_smoke.sh`
- `scripts/autofix_smoke_v2.sh`
- `scripts/guard_headers.sh`

## Invariants (non‑negotiable)
- Service auth header: `X-Ontos-Service-Auth`
- User header: `X-Ontogit-User`
- JWT header: `X-Ontogit-Auth: Bearer <JWT>`
- Recall must go through backend proxy: `/api/v1/ontogit_recall`
- Service-auth failure → `401` (no details)
- Usage DB is append‑only
- Limits are per‑user (daily), admin bypass via `ONTOGIT_ADMIN_USERS`

## Quick start (3 commands)
```bash
/home/ontoslive/ontos_work/ontogit-stack/scripts/dev_bootstrap.sh
/home/ontoslive/ontos_work/ontogit-stack/scripts/dev_up.sh
/home/ontoslive/ontos_work/ontogit-stack/scripts/dev_doctor.sh
```

## How to verify
```bash
/home/ontoslive/ontos_work/ontogit-stack/scripts/dev_doctor.sh
/home/ontoslive/ontos_work/ontogit-stack/scripts/smoke_ontogit.sh
 /home/ontoslive/ontos_work/ontogit-stack/scripts/guard_headers.sh
```

## Autopilot: scripts/autofix_smoke.sh
```bash
/home/ontoslive/ontos_work/ontogit-stack/scripts/autofix_smoke.sh
```
- Default (safe): runs `dev_up.sh` (minimal) -> `dev_doctor.sh` -> `smoke_ontogit.sh`, writes `ops/logs/autofix_<ts>.log`, does not edit files.
- Optional apply mode (whitelist only): `APPLY=YES /home/ontoslive/ontos_work/ontogit-stack/scripts/autofix_smoke.sh`

## Autopilot v2 (savepoint + rollback)
```bash
/home/ontoslive/ontos_work/ontogit-stack/scripts/autofix_smoke_v2.sh
AUTO_ROLLBACK=YES /home/ontoslive/ontos_work/ontogit-stack/scripts/autofix_smoke_v2.sh
```
- v2 always creates a local checkpoint before any auto-edit and prints `BOOT_POINTER=...`.
- Checkpoints live at `/home/ontoslive/ontogit/ops/state/<ts>-checkpoint`.
- Current stable pointer file: `/home/ontoslive/ontogit/ops/state/LATEST_POINTER.txt`.
- One-liner to read pointer: `cat /home/ontoslive/ontogit/ops/state/LATEST_POINTER.txt`
- If failures persist, v2 can auto-rollback to the printed BOOT_POINTER (`AUTO_ROLLBACK=YES`).
- Git hygiene choice: `LATEST_POINTER.txt` is generated at runtime and ignored from git.

## Local data dirs
- `/home/ontoslive/ontos_data/ontogit-user` → `/ontogit_user` (usage.db)
- `/home/ontoslive/ontos_data/openwebui-data` → `/app/backend/data`

## OpenWebUI runtime image (version source of truth)
- The frontend `package.json` version may differ from the backend banner; runtime is defined by the Docker image tag.
- Current image tag: `open-webui-ontogate:5f3b84105`
- Run (pins the runtime image via compose override):
```bash
docker compose -f docker-compose.yml -f docker-compose.webui-ontogate.yml up -d --force-recreate open-webui
```

## If you're a new executor
1) Read this `START_HERE.md`
2) Read `docs/ONTOGIT_CANON.md`
3) Run `scripts/dev_doctor.sh`

## Docker access note
If Docker requires sudo in this environment, run scripts with `sudo` (or they will auto-detect and use `sudo` for read-only docker commands where possible).

## WSL / Docker Desktop (sudo -n for smokes)
- Why: smoke scripts may need `sudo -n docker`; interactive sudo will fail in automated runs.
```bash
sudo -n true && echo sudo_n_ok
sudo -n "$(command -v docker)" ps >/dev/null && echo OK_nopasswd || echo FAIL_nopasswd
```
```bash
DOCKER_BIN="$(command -v docker)"
sudo tee /etc/sudoers.d/ontogit-docker-nopasswd >/dev/null <<EOF
ontoslive ALL=(root) NOPASSWD: $DOCKER_BIN
EOF
sudo chmod 0440 /etc/sudoers.d/ontogit-docker-nopasswd
sudo visudo -cf /etc/sudoers.d/ontogit-docker-nopasswd
```
```bash
SMOKE_NO_RECREATE=1 ./scripts/smoke_enforcement_soft.sh
SMOKE_NO_RECREATE=1 ./scripts/smoke_enforcement_hard.sh
```

## Dev profiles
- `DEV_PROFILE=minimal` (default): ontogit-stack + OpenWebUI image, **no** ollama, **no** build.
- `DEV_PROFILE=full`: includes ollama (and allows build if `DEV_BUILD=1`).
