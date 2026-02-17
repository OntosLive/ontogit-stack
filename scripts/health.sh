#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ontogit-stack}"
EXPECTED_NETWORK="${COMPOSE_PROJECT_NAME}_default"
NETWORK_REGEX="^${COMPOSE_PROJECT_NAME}(_${COMPOSE_PROJECT_NAME})?_default$"
export COMPOSE_PROJECT_NAME

DOCKER_CMD=(docker)
if ! "${DOCKER_CMD[@]}" ps >/dev/null 2>&1; then
  echo "ERROR: docker daemon is not accessible via plain docker (sudo fallback disabled)." >&2
  exit 1
fi

COMPOSE_CMD=("${DOCKER_CMD[@]}" compose)
if ! "${COMPOSE_CMD[@]}" version >/dev/null 2>&1; then
  echo "ERROR: docker compose is not accessible via: ${COMPOSE_CMD[*]}" >&2
  exit 1
fi

die() {
  echo "ERROR: $*" >&2
  exit 1
}

echo "==> Validate default network uniqueness (${EXPECTED_NETWORK})"
mapfile -t matched_networks < <("${DOCKER_CMD[@]}" network ls --format '{{.Name}}' | rg "${NETWORK_REGEX}" || true)
[ "${#matched_networks[@]}" -gt 0 ] || die "no matching default network found for ${COMPOSE_PROJECT_NAME}"

found_expected=0
stray_networks=()
for name in "${matched_networks[@]}"; do
  [ -n "${name}" ] || continue
  if [ "${name}" = "${EXPECTED_NETWORK}" ]; then
    found_expected=1
  else
    stray_networks+=("${name}")
  fi
done

[ "${found_expected}" = "1" ] || die "expected network is missing: ${EXPECTED_NETWORK}"
[ "${#stray_networks[@]}" -eq 0 ] || die "stray duplicate network(s) detected: ${stray_networks[*]}"
echo "OK: only ${EXPECTED_NETWORK} is present"

echo "==> Run network smoke"
bash "${STACK_DIR}/scripts/smoke_network.sh"

echo "==> Host check: OpenWebUI /api/version"
curl -fsS http://127.0.0.1:3000/api/version >/dev/null \
  || die "host check failed: http://127.0.0.1:3000/api/version"
echo "OK: OpenWebUI /api/version"

echo "==> Host check: openai-proxy /v1/models"
curl -fsS http://127.0.0.1:8088/v1/models >/dev/null \
  || die "host check failed: http://127.0.0.1:8088/v1/models"
echo "OK: openai-proxy /v1/models"

echo "==> Compose exec DNS+HTTP from open-webui"
(
  cd "${STACK_DIR}"
  "${COMPOSE_CMD[@]}" -f docker-compose.yml -f docker-compose.webui-ontogate.yml exec -T open-webui \
    sh -lc 'set -e; if command -v wget >/dev/null 2>&1; then out="$(wget -qO- http://openai-proxy:8088/v1/models | head -c 500)"; else out="$(curl -fsS http://openai-proxy:8088/v1/models | head -c 500)"; fi; [ -n "$out" ]; printf "%s\n" "$out"'
) || die "compose exec probe failed from open-webui"

echo "✅ HEALTH OK"
