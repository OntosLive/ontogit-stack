# START HERE

This repo contains the **OntoGit stack** and its **OpenWebUI integration**. It is the single entry point for local dev and ops.

**Spec**: `docs/ONTOGIT_CANON.md` (authoritative canon for headers/env/recall route/limits/usage).

**Dev Ops scripts**:
- `scripts/dev_bootstrap.sh`
- `scripts/dev_up.sh`
- `scripts/dev_doctor.sh`
- `scripts/smoke_ontogit.sh`
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

## Local data dirs
- `/home/ontoslive/ontos_data/ontogit-user` → `/ontogit_user` (usage.db)
- `/home/ontoslive/ontos_data/openwebui-data` → `/app/backend/data`

## If you're a new executor
1) Read this `START_HERE.md`
2) Read `docs/ONTOGIT_CANON.md`
3) Run `scripts/dev_doctor.sh`

## Docker access note
If Docker requires sudo in this environment, run scripts with `sudo` (or they will auto-detect and use `sudo` for read-only docker commands where possible).
