# Product quotas (monthly)

Цель: ограничить месячное потребление per-user, чтобы приглашённые пользователи не могли “сжечь” ключ, и у админа был понятный workflow.

## Где живёт policy
- Runtime путь (в контейнерах): `/ontogit_user/onto_policy.yml`
- Хост путь (монтируется в `usage-writer` и `memory-service`): `/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml`
- Каноничный файл в репо: `policy/onto_policy.yml` (version-control)

Синхронизация:
```bash
cp /home/ontoslive/ontos_work/ontogit-stack/policy/onto_policy.yml /home/ontoslive/ontos_data/ontogit-user/onto_policy.yml
```
Файл читается на каждый запрос в `usage-writer`/`openai-proxy`, поэтому обычно перезапуск не нужен. При сомнениях:
```bash
docker compose -f /home/ontoslive/ontos_work/ontogit-stack/docker-compose.yml up -d --force-recreate usage-writer openai-proxy memory-service
```

## Роли и дефолтные лимиты (monthly)
- `basic` (user): `limit_usd=15`, `warn_70=0.7`, `warn_90=0.9`
- `admin`: `limit_usd=50`, `warn_70=0.7`, `warn_90=0.9`
- `low`: `limit_usd=5`
- `high` / `pro`: `limit_usd=50`

Примечание: в OpenWebUI роли обычно приходят как `role:admin`, `role:pro`, иначе `basic`.

## Что видит пользователь
`openai-proxy` всегда ставит лимитные заголовки:
- `X-Ontogit-Used-USD`
- `X-Ontogit-Limit-USD`
- `X-Ontogit-Warn` = `monthly:70` или `monthly:90`

При превышении лимита на `POST /v1/chat/completions`:
- HTTP `429`
- JSON:
```json
{
  "error": {
    "message": "Monthly quota exceeded",
    "type": "quota_exceeded",
    "code": "quota_exceeded",
    "user_id": "<user_id>",
    "used_usd": 12.34,
    "limit_usd": 15.0
  }
}
```

## Как админ повышает лимит конкретному пользователю
Вариант A (рекомендуемый, если включён role-source=openwebui):
1) В OpenWebUI назначить группу `role:pro` или `role:admin`.
2) Проверить роль через `GET /api/v1/ontogit/user_role`.

Вариант B (прямой override через usage-writer):
```bash
curl -sS -X PUT http://127.0.0.1:8091/users/<user_id> \
  -H 'Content-Type: application/json' \
  -d '{"role":"high","active":1}'
```

## Как изменить лимит
1) Правка `policy/onto_policy.yml`.
2) Синхронизировать в `/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml`.
3) (Опционально) перезапуск `usage-writer`/`openai-proxy`.

## Куда смотреть при споре “почему ограничило”
- `usage-writer`:
  - `GET http://127.0.0.1:8091/limits/<user_id>`
  - `GET http://127.0.0.1:8091/used/<user_id>`
- `usage.db` (read-only): `/home/ontoslive/ontos_data/ontogit-user/usage.db`
- Логи:
  - `docker logs ontogit-stack-openai-proxy-1`
  - `docker logs ontogit-stack-usage-writer-1`
