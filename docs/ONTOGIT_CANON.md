# ONTOGIT Canon (Service/Auth/Usage)

**Entry point: ontogit-stack/START_HERE.md**

## A) Контуры (Service-auth vs User-auth)
- **Service-auth**: межсервисный допуск между gateway и memory-service.
- **User-auth**: идентификация пользователя (JWT) для приложений и usage.
- Контуры НЕ пересекаются. Нельзя использовать service-secret как user-id.

## B) Канонические имена заголовков и env
**CANON (единственные допустимые):**
- Service auth header: `X-Ontos-Service-Auth`
- Service env: `ONTOS_SERVICE_AUTH_SECRET`
- User header: `X-Ontogit-User`
- JWT header: `X-Ontogit-Auth: Bearer <JWT>`

**Source of truth (secret):**
- `ONTOS_SERVICE_AUTH_SECRET` должен быть установлен **и в memory-service, и в OpenWebUI backend**.
- Значение должно совпадать в обоих сервисах.
- В OpenWebUI backend секрет задаётся через `docker-compose.yaml` или `.env` (см. `.env.example` в open-webui-src).

**Запреты:**
- Никогда не использовать `X-Ontos-Auth`
- Не вводить альтернативы типа `X-Memory-Service-Auth`
- Не логировать значения секретов/JWT

## C) Канонический маршрут RECALL
- Клиенты **не** вызывают memory-service `/recall` напрямую.
- Клиенты вызывают **OpenWebUI backend**: `/api/v1/ontogit_recall`
- Backend добавляет `X-Ontos-Service-Auth` + `X-Ontogit-User` и форвардит в memory-service `/recall`.

### User-id source (no constant injection)
- Source of truth для user id: внутренний authenticated user id из OpenWebUI backend.
- OpenWebUI backend прокидывает его в OpenAI proxy как `X-OpenWebUI-User-Id`.
- OpenAI proxy использует `X-OpenWebUI-User-Id` как primary source и маппит в `X-Ontogit-User` для usage/limits/memory-service.
- Для совместимости допускается `X-Ontogit-User` с тем же значением.
- Запрещена константная подстановка user id на прокси-уровне (например, `andrey` в nginx).
- Если user id определить нельзя, прокси использует `user_id="unknown"`; memory-service выставляет warning.
- Dev fallback допустим только при явной настройке `ONTOGIT_DEV_FALLBACK_USER_ID`.
- JWT-путь для вычисления user id в proxy-слое не является каноническим и вне текущего production-процесса.

## D) Ошибки/коды
- **Service-auth fail** → `401` без деталей (пустое тело или `{"error":"unauthorized"}`).
- Если `ONTOS_SERVICE_AUTH_SECRET` не задан, memory-service работает в режиме **deny-all** (все запросы → `401`).
- Отсутствие `X-Ontogit-User` **не** даёт `401` → используется `user_id="unknown"`.
- Зарезервировано:
  - `429 {"error":"rate_limited"}`
  - `403 {"error":"quota_exceeded"}`

## Warnings (тексты)
- `OntoGit memory-service auth missing/mismatch`
- `User id not propagated; usage will be aggregated`
- `Quota exceeded`
- `Rate limited`

## Limits (daily, per user)
- Env:
  - `ONTOGIT_DAILY_TOKEN_LIMIT` (int, optional)
  - `ONTOGIT_DAILY_REQUEST_LIMIT` (int, optional)
  - `ONTOGIT_LIMIT_MODE` = `soft|hard` (default `soft`)
- `ONTOGIT_ADMIN_USERS` = comma-separated `user_id` list (admin bypass)
- `hard` → `429 {"error":"quota_exceeded"}`
- `soft` → request проходит, но выставляется `X-Ontogit-Warn: quota_exceeded`

### Default policy
- Лимиты **не заданы** (значит отключены).
- `ONTOGIT_LIMIT_MODE=soft`.

## Policy-as-code v1 (optional)
- Runtime path: `/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml` (mounted as `/ontogit_user/onto_policy.yml`).
- Example template: `policy/onto_policy.example.yml`.
- If policy file is missing/invalid: behavior stays on existing env defaults (no change).
- Roles: `basic` / `pro` / `admin`; user role resolves from `users.role` with `default_role` fallback.
- `admin_users` in policy is an admin override; memory-service uses union of policy + `ONTOGIT_ADMIN_USERS`.
- Daily limits (memory-service): per-role `request_limit` / `token_limit` (`0` or `null` = unlimited).
- Monthly limits (usage/openai): per-role `limit_usd`, `warn_70`, `warn_90`.

## Governance v1 (optional, env-gated)
- OpenWebUI is identity/group source (`user_id` = OpenWebUI `user.id`).
- OpenWebUI role endpoint: `GET /api/v1/ontogit/user_role` (requires `X-Ontos-Service-Auth` + `X-OpenWebUI-User-Id`).
- Group mapping defaults: `admin -> admin`, `pro -> pro`, else `basic`.
- Enable role source in usage-writer with `ONTOGIT_ROLE_SOURCE=openwebui`.
- If role source is off/unavailable: limits behavior remains unchanged.

### Staging example
```
ONTOGIT_DAILY_REQUEST_LIMIT=100
ONTOGIT_DAILY_TOKEN_LIMIT=20000
ONTOGIT_LIMIT_MODE=hard
ONTOGIT_ADMIN_USERS=admin,admin2
```

## E) Usage invariants (append-only)
- `usage.db` — append-only.
- Таблица `memory_usage_events`:
  - `ts, user_id, endpoint, status_code, request_id, tokens_in, tokens_out`
- Никаких DROP/пересозданий, только `CREATE TABLE IF NOT EXISTS`.
- Индексы минимум: `(user_id)`, `(endpoint)`, `(ts)`.
- Не хранить payload текста.

## F) Smoke checklist
1) `401` на `/health` без `X-Ontos-Service-Auth`
2) `200` на `/health` с `X-Ontos-Service-Auth`
3) `/commit` и `/recall` работают через backend proxy
4) В `usage.db` есть события с корректным `user_id`

## Local Dev Ops Pack
- Скрипты (ontogit-stack/scripts):
  - `dev_bootstrap.sh` — создать локальные папки и `.env.local`
  - `dev_up.sh` / `dev_down.sh`
  - `dev_doctor.sh` — статус/порты/маунты/DB
  - `autofix_smoke.sh` — автопилот smoke + лог + классификация ошибок
  - `dev_reset.sh` — опасный сброс локальных данных (требует `DEV_RESET_I_UNDERSTAND=YES`)
- Data dirs (host):
  - `/home/ontoslive/ontos_data/ontogit-user` → `/ontogit_user`
  - `/home/ontoslive/ontos_data/openwebui-data` → `/app/backend/data`

## Environment topology
- Local (WSL2) and Server (VPS) are separate environments; data is not shared by default.
- Canonical mount check for OpenWebUI:
  - `sudo -E docker inspect open-webui --format 'project={{ index .Config.Labels "com.docker.compose.project" }} files={{ index .Config.Labels "com.docker.compose.project.config_files" }} mounts={{ range .Mounts }}{{ .Source }}->{{ .Destination }};{{ end }}'`

## Codex-first workflow
- Codex is the preferred executor for repository changes.
- Prefer Codex task prompts over ad-hoc manual shell editing.
- Operator role: run provided scripts and share outputs/logs; Codex role: edit files via reviewable diffs.
- Never edit secrets; never run `dev_reset` unless explicitly requested.

## Autopilot modes (`scripts/autofix_smoke.sh`)
- Safe mode (default):
  - Runs `dev_up.sh` with `DEV_PROFILE=minimal`, then `dev_doctor.sh`, then `smoke_ontogit.sh`.
  - Captures output to `ops/logs/autofix_<ts>.log`.
  - Does not edit files.
  - Prints one-line result: `OK (smoke passed)` or `FAIL (smoke failed; see <log path>)`.
- Apply mode (`APPLY=YES`):
  - Max `MAX_ITERS=2`.
  - Allowed edits only:
    - `smoke_ontogit.sh` stability adjustments (`wait_for_health`/timeouts/env-file handling).
    - `docker-compose.yml` memory-service env pass-through for `ONTOGIT_*` limits.
    - sudo-docker strategy fixes (`sudo -E docker`).
  - Forbidden: touch `.env.local`, run `dev_reset`, run `rm -rf`, generate/replace secrets.

## Dev profiles
- `DEV_PROFILE=minimal` (default): ontogit-stack + OpenWebUI image, **no** ollama, **no** build.
- `DEV_PROFILE=full`: includes ollama, optional build with `DEV_BUILD=1`.
