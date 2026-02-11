#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"

(
  cd "${STACK_DIR}" && \
  USER_EMAIL=kontrabaobab@yandex.ru ./scripts/smoke_role_source.sh
)
(
  cd "${STACK_DIR}" && \
  USER_EMAIL=test@test.ru ./scripts/smoke_role_source.sh
)

echo "GOVERNANCE OK"
