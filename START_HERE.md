# START HERE

This repo contains the **OntoGit stack** and its **OpenWebUI integration**. It is the single entry point for local dev and ops.

**Spec**: `docs/ONTOGIT_CANON.md` (authoritative canon for headers/env/recall route/limits/usage).

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

## If you're a new executor
1) Read this `START_HERE.md`
2) Read `docs/ONTOGIT_CANON.md`
3) Run `scripts/dev_doctor.sh`

## Docker access note
If Docker requires sudo in this environment, run scripts with `sudo` (or they will auto-detect and use `sudo` for read-only docker commands where possible).

## Dev profiles
- `DEV_PROFILE=minimal` (default): ontogit-stack + OpenWebUI image, **no** ollama, **no** build.
- `DEV_PROFILE=full`: includes ollama (and allows build if `DEV_BUILD=1`).
