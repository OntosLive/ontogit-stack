# ONTOGIT Canon (Service/Auth/Usage)

**Entry point: ontogit-stack/START_HERE.md**

## TL;DR (One Screen)
- Source of Truth сцены: markdown в git-репо (`frontmatter + body`), не Qdrant и не `webui.db`.
- Канонический маршрут: клиенты идут в OpenWebUI backend (`/api/v1/ontogit_recall`, `/api/v1/ontogit_commit`), backend форвардит в memory-service.
- `memory-service` на commit: парсит frontmatter, пишет scene `.md`, делает git commit, апсертит индекс в Qdrant.
- Recall budget уже включён и зафиксирован: `ONTOGIT_RECALL_MAX_TOKENS=1500`.
- OpenAI upstream ConnectError фиксирован: `e0216cd` (приоритет env + fallback + safe JSON error).
- OpenWebUI async `task_id`-ответы отключены для chat completions: `8dfad3c` (`ENABLE_WEBSOCKET_SUPPORT=false`).
- Текущая recall-политика этапа: Pulse OFF, recall только ручной (явный жест пользователя, например `//recall`, или явное UI-действие).
- 8-слойная модель остаётся каноном; L0–L1 фиксируется как «паспорт сцены» поверх существующих полей.
- Минимальный L0–L1 паспорт: `scene_id`, `status`, `hook`, `archetype`, `vector`, `body_marker`, `links`.
- `status=closed` фиксируем только явным closure в сцене (что закрыто и почему), без эвристических авто-оценок.
- На текущем этапе важнее наполнение базы (10–20 сцен-ядра), чем «умные» автотриггеры.
- Где править канон: этот файл `docs/ONTOGIT_CANON.md`.

## Ops Rituals (canonical)
- Deploy OpenWebUI only via ritual script: `scripts/deploy_openwebui.sh`
- Deployment guide: `docs/DEPLOY_WEBUI.md`
- Deployment artifacts: `ops/state/<ts>_deploy_openwebui/`
- Deploy openai-proxy only via ritual script: `scripts/deploy_openai_proxy.sh`
- Deployment guide: `docs/DEPLOY_OPENAI_PROXY.md`
- Deployment artifacts: `ops/state/<ts>_deploy_openai_proxy/`
- Principle: deploy only through ritual, not manual compose/image edits.

## 0) Текущий этап и ограничения
- Никаких новых автоматических «чувствительных» триггеров на возбуждение/резонанс.
- Recall на текущем этапе считается ручным инструментом, не автономным агентом.
- Pulse-policy считается отключённой для рабочего режима (см. раздел **Recall Policy (Current Stage)**).
- `webui.db` и runtime hooks не являются источником истины сцены.

## 1) Подтверждённые факты (ссылки на реализацию)
- Канонический маршрут recall/commit через OpenWebUI backend:
  - `docs/ONTOGIT_CANON.md:27`
  - `open-webui-src/backend/open_webui/routers/ontogit.py:138`
  - `open-webui-src/backend/open_webui/routers/ontogit.py:143`
- `memory-service` commit-пайплайн:
  - принимает commit: `memory-service/app/main.py:570`
  - парсит frontmatter: `memory-service/app/main.py:589`
  - формирует `meta`: `memory-service/app/main.py:598`
  - пишет markdown scene: `memory-service/app/main.py:375`
  - индексирует в Qdrant: `memory-service/app/main.py:627`, `memory-service/app/recall_mvp.py:55`
- Поля сцены реально поддержаны сейчас (часть хранится в frontmatter, часть в Qdrant payload):
  - `scene_id`, `title`, `pulse`, `vector`, `archetype`, `tags`, `importance`, `quote`, `body_preview`
  - см. `memory-service/app/main.py:598` и `memory-service/app/recall_mvp.py:58`
  - 8-слойные блоки в merge: `excitation`, `distinction`, `form`, `subjectivity`, `structure_links`, `archetypes`, `vector` (`memory-service/app/main.py:613`)
- Recall budget подтверждён:
  - env/read: `memory-service/app/main.py:65`
  - логи `recall_budget ... budget=1500 ...`: `memory-service/app/main.py:520`, `memory-service/app/main.py:564`
- Upstream ConnectError fix подтверждён: commit `e0216cd`
  - выбор upstream по приоритету env + fallback: `openai-proxy/app.py` (в рабочем репо ontogit-stack)
  - safe JSON error вместо падения.
- Async `task_id`-режим OpenWebUI подтверждён и зафиксирован:
  - условие async-ветки: `open-webui-src/backend/open_webui/main.py:1789`
  - возврат `{"status": True, "task_id": ...}`: `open-webui-src/backend/open_webui/main.py:1799`
  - отключение websocket в нашем запуске: commit `8dfad3c` (`docker-compose.webui-ontogate.yml`)
  - цель: `/api/chat/completions` возвращает sync completion (`choices`), а не `task_id`.

## 2) Source of Truth (канон хранения)
- **Source of Truth сцены**: markdown scene в git-репо (`frontmatter + body`), формируется в `memory-service/app/main.py:375`.
- **Qdrant**: индекс для recall/ранжирования, не источник истины (`memory-service/app/recall_mvp.py:55`).
- **OpenWebUI `webui.db`**: состояние UI/функций/хуков (таблица `function` и др.), не канон сцен.
- Практический путь сцен задаётся `ONTOGIT_DIR` и шаблоном `scenes/YYYY/MM/<scene_id>.md` (`memory-service/app/main.py:387`).

## 3) Recall Policy (Current Stage)
- Pulse OFF для рабочего контура.
- Recall только по явному действию пользователя:
  - явная команда (`//recall`) или
  - явное UI-действие recall.
- Budget `1500` — уже действующий предохранитель (`memory-service/app/main.py:65`).
- Dedup допустим только как технический анти-дубль, без «интеллектуального автозапуска».
- Принцип этапа:
  - сначала наполняем базу сцен и связей;
  - затем улучшаем использование;
  - авто-эвристики «чувствительности» на этом этапе запрещены.

## 4) L0–L1 как паспорт в 8-слойной модели
- 8-слойный канон не меняем.
- L0–L1 — это минимальный «паспорт сцены», который маппится на уже существующие поля.

### Паспорт L0–L1 (минимум)
- `scene_id: str` — стабильный ключ сцены.
- `status: open | in_progress | closed`
- `hook: str` — конкретный незавершённый узел возврата.
- `archetype: str | list[str]`
- `vector: direction|target|polarity` (или строка направления, если без структуры).
- `body_marker: str` — короткий телесный/сценический маркер (<=240).
- `links: list[{type, to_scene_id}]` — связи между сценами.

### Маппинг паспорта на текущую 8-слойную реализацию
- `scene_id` -> уже есть как top-level (`memory-service/app/main.py:600`).
- `status` -> **минимальное добавление**: top-level поле frontmatter (`open` по умолчанию).
- `hook` -> **минимальное добавление**: top-level поле frontmatter (строка).
- `archetype` -> уже есть top-level `archetype`; расширенный вариант через `archetypes` (`memory-service/app/main.py:605`, `memory-service/app/main.py:613`).
- `vector` -> уже есть (`vector_direction`, `vector_target`) в индексе (`memory-service/app/recall_mvp.py:77`).
- `body_marker` -> маппится на `quote`/`body_preview` (`memory-service/app/main.py:618`, `memory-service/app/recall_mvp.py:67`).
- `links` -> маппится на `structure_links.nodes` как базовая версия (`memory-service/app/recall_mvp.py:84`); при необходимости расширяется до структурированных link-объектов без ломки 8-слойной модели.

### Правила статуса и hook
- `status=closed` только при явном closure-коммите:
  - что именно закрыто;
  - чем закрыто (решение/событие/связь).
- `hook` — это конкретный незавершённый узел/напряжение/вектор возврата, а не общая тема.
- Запрещены «универсальные оценки состояния» без явных опор различения.

## 5) Filling Protocol (practical)
- Создание новой незавершённой сцены:
  - commit через канонический маршрут `/api/v1/ontogit_commit`;
  - минимум frontmatter: `scene_id,status,hook,archetype,vector,quote(or body_marker),structure_links`.
- Обновление сцены:
  - новый commit как акт фиксации сдвига L0 -> L1;
  - не перезаписывать историю «магически», а фиксировать переходы.
- Использование `//recall`:
  - ожидаем выдачу опор/сцен/связей;
  - не ожидаем «угадывание человека» или автотерапевтическую интерпретацию.
- Рекомендуемый старт:
  - собрать 10–20 «сцен-ядер» (незавершённые узлы с явными hook/links).

## 6) Артефакты и карта архитектуры
- Канон и политика: `docs/ONTOGIT_CANON.md` (этот файл).
- Реализация маршрута recall/commit через backend:
  - `open-webui-src/backend/open_webui/routers/ontogit.py`
- Реализация scene commit/recall:
  - `memory-service/app/main.py`
  - `memory-service/app/recall_mvp.py`
- Runtime hooks/OpenWebUI function storage:
  - `webui.db` таблица `function` (например `ontogit_recall_inlet`, `ontogit_usage_hook`).
- Лимиты/usage:
  - `usage-writer/app.py`
  - `usage.db` таблицы `memory_usage_events`, `usage_events`, `users`, `roles`.

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
