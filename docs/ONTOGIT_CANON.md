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
  - `dev_reset.sh` — опасный сброс локальных данных (требует `DEV_RESET_I_UNDERSTAND=YES`)
- Data dirs (host):
  - `/home/ontoslive/ontos_data/ontogit-user` → `/ontogit_user`
  - `/home/ontoslive/ontos_data/openwebui-data` → `/app/backend/data`
