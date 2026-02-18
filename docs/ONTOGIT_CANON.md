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
- Compose project name is fixed: `COMPOSE_PROJECT_NAME=ontogit-stack` (repo `.env`).
- One-button health ritual: `bash scripts/health.sh`.
- Compose default network is pinned to `ontogit-stack_default`, and deploy rituals fail-fast if stray matching default networks are detected.
- Daily beta report: `scripts/report_daily.sh` (docs: `docs/REPORTS.md`)
- Backup/restore: `scripts/backup.sh`, `scripts/restore.sh` (docs: `docs/BACKUP_RESTORE.md`)
- Principle: deploy only through ritual, not manual compose/image edits.

## Branding / App Identity (Ontos.Live)
- Runtime title: `Ontos.Live`.
- PWA manifest:
  - `name=Ontos.Live`
  - `short_name=alba`
  - icons: `alba-icon-192.png`, `alba-icon-512.png`.
- UI/loader/about rule:
  - do not show `Open WebUI` in user-facing branding text.
  - use `Ontos.Live` branding tokens/files in `src/lib/config/branding.ts`, `src/app.html`, `static/static/loader.js`, `static/static/site.webmanifest`.
- Cache-bust rule (mandatory for branding updates):
  - rename icon/manifest assets when branding changes.
  - hard-reload browser after deploy (manifest/icon/loader are aggressively cached).

## Kelia UI Profile (server-driven)
- `ui_profile` is user-scoped, not app-scoped.
- `ui_profile=kelia` is derived from OpenWebUI group membership:
  - accepted group names: `келья`, `kelia` (case-insensitive).
- Global `ui_profile` in app config is forbidden.
- Kelia v1.1 specification:
  - Sidebar:
    - required: `New chat`, `Search`, `Chat list (history)`.
    - forbidden: folders/channels/notes/workspace/models entries.
    - chat list style: no chat icons, no date/time labels.
  - Chat stream:
    - flat timeline (ChatGPT-like).
    - no headers (`Вы`/author/timestamp), no avatars, no edit pencil.
    - no message TTS/read-aloud controls.
  - Reactions:
    - only `мурашки` button.
    - hide like/dislike.
    - `мурашки` action = feedback + `POST /api/v1/ontogit_commit` with `reason=goosebumps`.
  - Input:
    - keep STT mic (voice input).
    - disable voice output/call/TTS modes.
    - attachments disabled.
    - settings reduced to `Ontos.Live UI`: theme, language, UI scale.
  - Top-right chat menu:
    - hide/trim `...` actions in Kelia (no share/upload/tags/overview entries).

## STT Canon (local whisper CUDA)
- Base mode:
  - `WHISPER_MODEL=medium`
  - CUDA device
  - `WHISPER_COMPUTE_TYPE=float16`.
- Web Speech (`SpeechRecognition`) is OFF by default.
- Web Speech can be enabled only by explicit debug flag; implicit fallback is forbidden.
- MIME selection rule for recording:
  - select first valid MIME from intersection of:
    - backend `supported_content_types`
    - `MediaRecorder.isTypeSupported(...)`.
  - if intersection is empty: return explicit error; do not fallback to Web Speech.
- Guardrail:
  - canonical script: `scripts/ops/stt_guard.sh`.
  - canonicalizes STT config and removes user overrides `settings.ui.audio.stt.engine='web'`.
- Known class-0 incident:
  - symptom `one word / wrong language / garbage transcript` is commonly caused by OS/browser default microphone switching.

## Release Canon (One EntryPoint)
- Single OpenWebUI release entrypoint: `scripts/deploy_openwebui.sh`.
- Manual `docker build`, manual compose image pin edits, manual partial deploy flows are forbidden.
- `scripts/deploy_openwebui.sh` is smoke-gated:
  - `smoke_v1 BEFORE` (abort on fail)
  - deploy
  - `smoke_v1 AFTER` (abort on fail).
- Mandatory post-release check: successful `smoke_v1 AFTER`.

## Incident Playbooks + Smoke
- Incident Playbooks are treated as system scenes (canonical operational memory).
- Canonical smoke command:
```bash
cd /home/ontoslive/ontos_work/ontogit-stack
bash scripts/ops/smoke_v1.sh
```
- `smoke_v1` artifacts:
  - `ops/state/<ts>_smoke_v1/details.log`
  - `ops/state/<ts>_smoke_v1/summary.txt`.
- `smoke_v1` status model:
  - `PASS`, `WARN`, `FAIL` with counts in summary.
  - exit code `1` only if `FAIL>0`; `WARN` does not fail smoke.
- STT source-of-truth for smoke:
  - `docker compose -f docker-compose.yml -f docker-compose.webui-ontogate.yml config` (`open-webui.environment`) for `WHISPER_*`.
  - DB check only for `$.audio.stt.whisper_model` (config id=1).
  - hard requirement: `web_override_count == 0` for user settings override.
- `health.sh` degradation rule inside smoke:
  - if docker tooling is unavailable (daemon/socket/permission class errors), mark as `WARN`, not `FAIL`.
- `alba_status.sh` is mode-aware:
  - `mode=door_tunnel` if `3010` listening or `https://alba.ontos.live/api/version` reachable.
  - `mode=local_only` if local `127.0.0.1:3000` reachable and no door-tunnel evidence.
  - mode-irrelevant checks are skipped (no false `000` negatives in `local_only`).

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
- Canonical policy file: `policy/onto_policy.yml` (see `docs/QUOTAS.md`).
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

## Smoke-test v1
- Canonical command:
```bash
cd /home/ontoslive/ontos_work/ontogit-stack
bash scripts/ops/smoke_v1.sh
```
- Purpose:
  - Runs source-of-truth checks:
    - `bash scripts/ops/alba_status.sh`
    - `bash scripts/health.sh`
  - Performs STT env-first checks:
    - compose source-of-truth (`open-webui.environment`) for `WHISPER_MODEL`, `WHISPER_BEAM_SIZE`, `WHISPER_BEST_OF`, `WHISPER_VAD_FILTER`
    - DB model check (`config.id=1`, `$.audio.stt.whisper_model`)
    - no users with `settings.ui.audio.stt.engine == "web"`
- Artifacts:
  - `ops/state/<ts>_smoke_v1/details.log` (detailed execution log)
  - `ops/state/<ts>_smoke_v1/summary.txt` (short summary)
- Summary semantics:
  - includes `PASS/WARN/FAIL` lines and counts.
  - `WARN` does not fail smoke; only `FAIL` fails smoke.
- Exit code:
  - `0` if `FAIL=0`
  - `1` if `FAIL>0`

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

## Collaboration Model (User + Assistant + Codex)
- Source-of-truth questions (`where/how in system`) are resolved by Codex via repo/canon extraction.
- Role split:
  - User: vector, priority, acceptance.
  - Assistant: architecture/canon decisions.
  - Codex: code/config extraction, patching, command execution, diffs.
- Canon-first rule:
  - patch -> commit -> canon update -> one build/release.
  - avoid rebuild per micro-change unless explicitly required by incident handling.

## Handoff (2026-02-18)
- Current deployed image tag: `open-webui-ontogate:0cc00978f`.
- Canonical release entrypoint: `./scripts/deploy_openwebui.sh`.
- Last smoke state dirs:
  - pre: `/home/ontoslive/ontos_work/ontogit-stack/ops/state/20260218_175526_smoke_v1`
  - post: `/home/ontoslive/ontos_work/ontogit-stack/ops/state/20260218_175822_smoke_v1`
- Last smoke result (both pre/post): `pass=4 warn=0 fail=0`
  - `PASS | bash scripts/ops/alba_status.sh`
  - `PASS | bash scripts/health.sh`
  - `PASS | No users with settings.ui.audio.stt.engine='web'`
  - `PASS | STT env-first: db_model=medium compose_model=medium compose_beam=5 compose_best_of=3 compose_vad=0`
- Open tasks (Kelia v1.1 UI):
  - keep chat list in sidebar for Kelia.
  - remove chat headers/timestamps/avatars/edit/TTS in message stream.
  - keep STT mic in input; keep voice output modes disabled.
  - keep `мурашки` visible as sole reaction (no like/dislike).
  - hide top-right `...` chat menu in Kelia.
  - remove chat icons/time labels in sidebar list.
- Reminder:
  - do not rebuild per change.
  - canonical flow: patch -> commit -> canon -> one build.
