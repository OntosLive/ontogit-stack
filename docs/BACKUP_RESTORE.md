# Backup & Restore (Beta Safety)

These rituals create a **recoverable snapshot** of the beta environment. No prompt/response text is logged.

## Backup
```bash
cd /home/ontoslive/ontos_work/ontogit-stack
./scripts/backup.sh
```

Artifacts in `ops/state/<ts>_backup/`:
- `openwebui-data.tar.gz` — OpenWebUI data volume
- `ontogit-user.tar.gz` — policy + usage.db
- `ontogit-repo.tar.gz` — scenes git repo (`/root/ontogit`, via sudo)
- `qdrant.tar.gz` — qdrant volume (`qdrant_storage`)
- `docker_ps.txt`, `docker_images.txt`
- `config/compose.config.yml`, `config/docker-compose.yml`, `config/docker-compose.webui-ontogate.yml`, `config/onto_policy.yml`
- `how_to_repeat.txt`

## Restore (careful)
```bash
cd /home/ontoslive/ontos_work/ontogit-stack
BACKUP_DIR=ops/state/<ts>_backup ./scripts/restore.sh
```
What it does:
1) Stops services **only if** matching archives are present (memory-service for scenes, qdrant for qdrant).
2) Restores archives into their target dirs / volumes (scenes repo uses sudo).
3) Brings compose up.
4) Health checks: OpenWebUI `/api/version`, proxy `/v1/models`, usage-writer `/report/daily`.

## Partial restore (examples)
- Policy only: copy `config/onto_policy.yml` back to `/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml`.
- Usage DB only: extract just `ontogit-user.tar.*` to `/home/ontoslive/ontos_data/ontogit-user/`.
- OpenWebUI data only: extract `openwebui-data.tar.*` to the active OpenWebUI data mount.

## Notes
- OpenWebUI data mount is discovered from the running container; fallback is
  `/home/ontoslive/ontos_data/openwebui-data-vps-current`.
- Scenes repo defaults to `/root/ontogit` (override with `SCENES_DIR=...`), and requires sudo.
- Qdrant uses docker volume `qdrant_storage`.
