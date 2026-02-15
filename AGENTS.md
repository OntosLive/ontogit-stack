# AGENTS

- Do not touch `/etc/nginx` or any system files.
- Do not run `git add -A`; commit only files changed for the task.
- All ops scripts must be idempotent and must back up target files before replacement (use `.bak.<ts>`).
- Do not touch unrelated keys in any DB; when editing DBs, always back up before changes.
