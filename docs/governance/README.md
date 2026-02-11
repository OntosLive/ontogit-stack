# Governance

## Overview
- Identity and group membership source of truth: OpenWebUI.
- Limits source of truth: OntoGit policy-as-code.
- Runtime role source in this setup: `role-source=openwebui`.

## Canonical Role Groups
- `role:admin`
- `role:pro`
- default role is `basic` (no `role:*` groups)

## Role Precedence
- `role:admin` > `role:pro` > `basic`

## Canon Limits Table
- `basic` = `11` USD/month
- `pro` = `55` USD/month
- `admin` = `0` (unlimited)

## Policy Source Of Truth
- Host path: `/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml`
- Container path: `/ontogit_user/onto_policy.yml`
- `usage-writer` reads `POLICY_PATH=/ontogit_user/onto_policy.yml`

## Endpoints
- OpenWebUI: `http://127.0.0.1:3000`
- user_role (internal via docker): `http://open-webui:8080/api/v1/ontogit/user_role`
- usage-writer limits: `http://127.0.0.1:8091/limits/{user_id}`

## Operator Checklist
- A) Add user and assign group `role:pro` or `role:admin` in OpenWebUI.
- B) One-shot verify: `./scripts/smoke_governance.sh`.
- C) Verify one user: `USER_EMAIL=<email> ./scripts/smoke_role_source.sh`.
- D) Change limits: edit policy file -> recreate `usage-writer` -> run smoke.
- E) Break-glass admin: set `admin_users` UUID list in policy -> recreate `usage-writer` -> run smoke.

## Troubleshooting First Aid
1. Docker exec role check (replace `<uuid>`):
```bash
sudo -E docker exec -i ontogit-stack-usage-writer-1 \
  sh -lc 'python3 - <<"PY"\nimport os, urllib.request\nurl="http://open-webui:8080/api/v1/ontogit/user_role"\nreq=urllib.request.Request(url, headers={"X-Ontos-Service-Auth": os.environ["ONTOS_SERVICE_AUTH_SECRET"], "X-OpenWebUI-User-Id": "<uuid>"})\nwith urllib.request.urlopen(req, timeout=10) as r:\n    print(r.status)\n    print(r.read().decode("utf-8","replace"))\nPY'
```
2. Inspect policy in container:
```bash
sudo -E docker exec -i ontogit-stack-usage-writer-1 sh -lc 'ls -l /ontogit_user/onto_policy.yml && sed -n "1,120p" /ontogit_user/onto_policy.yml'
```
3. Check limits endpoint:
```bash
curl -sS http://127.0.0.1:8091/limits/<uuid>
```
