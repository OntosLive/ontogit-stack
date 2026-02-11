# Governance v1

Canonical OpenWebUI role groups:
- `role:admin`
- `role:pro`
- default role: `basic`

Role precedence:
- `admin` > `pro` > `basic`

Policy mapping:
- Host: `/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml`
- Container: `/ontogit_user/onto_policy.yml`

Smoke tests:
```bash
USER_EMAIL=kontrabaobab@yandex.ru ./scripts/smoke_role_source.sh
USER_EMAIL=test@test.ru ./scripts/smoke_role_source.sh
```

Inspect limits directly:
```bash
curl -sS http://127.0.0.1:8091/limits/<uuid>
```
