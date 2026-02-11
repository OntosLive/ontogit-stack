# OntoGate Service Auth

## Env Vars
- `ONTOS_SERVICE_AUTH_SECRET`: shared secret for memory-service. Must be set for the service to accept requests.
  - Also set this in OpenWebUI backend so it can forward the header to memory-service.
- `USAGE_DB`: path for memory-service usage events (default `/ontogit_user/usage.db`).
- Limits (optional, per user/day):
  - `ONTOGIT_DAILY_TOKEN_LIMIT` (int)
  - `ONTOGIT_DAILY_REQUEST_LIMIT` (int)
  - `ONTOGIT_LIMIT_MODE` = `soft|hard` (default `soft`)

## Canon
See `docs/ONTOGIT_CANON.md` for the single source of truth (headers/env/recall route).
Recall must go through OpenWebUI backend: `/api/v1/ontogit_recall`.

## Required Headers (memory-service)
Send one of:
- `X-Ontos-Service-Auth: <SECRET>` (preferred)
Also send user identity for usage attribution:
- `X-Ontogit-User: <user_id>`

Do not use `X-Ontos-Auth` for service auth to avoid confusion with JWT user auth.

## Verify (curl)
```bash
# should be 401 (missing header)
curl -i http://127.0.0.1:8090/health

# should be 200 (with header)
curl -i -H "X-Ontos-Service-Auth: <SECRET>" http://127.0.0.1:8090/health

# /recall should be 401 without header
curl -i -X POST http://127.0.0.1:8090/recall -H "Content-Type: application/json" -d '{"query":"test","k":1}'

# /recall should be 200 with header
curl -i -X POST http://127.0.0.1:8090/recall -H "Content-Type: application/json" -H "X-Ontos-Service-Auth: <SECRET>" -H "X-Ontogit-User: user1" -d '{"query":"test","k":1}'

# /commit should be 401 without header
curl -i -X POST http://127.0.0.1:8090/commit -H "Content-Type: application/json" -d '{"title":"t","body":"b"}'

# /commit should be 200 with header
curl -i -X POST http://127.0.0.1:8090/commit -H "Content-Type: application/json" -H "X-Ontos-Service-Auth: <SECRET>" -H "X-Ontogit-User: user1" -d '{"title":"t","body":"b"}'

# verify usage in sqlite
sqlite3 /ontogit_user/usage.db "select user_id, endpoint, status_code from memory_usage_events order by id desc limit 5;"
```
