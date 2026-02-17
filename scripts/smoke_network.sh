#!/usr/bin/env bash
set -euo pipefail

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-ontogit-stack}"
EXPECTED_NETWORK="${EXPECTED_NETWORK:-${COMPOSE_PROJECT_NAME}_default}"
NETWORK_REGEX="^${COMPOSE_PROJECT_NAME}(_${COMPOSE_PROJECT_NAME})?_default$"
WEBUI_CONTAINER="${WEBUI_CONTAINER:-${COMPOSE_PROJECT_NAME}-open-webui-1}"
PROXY_CONTAINER="${PROXY_CONTAINER:-${COMPOSE_PROJECT_NAME}-openai-proxy-1}"
export COMPOSE_PROJECT_NAME

DOCKER_CMD=(docker)
if ! "${DOCKER_CMD[@]}" ps >/dev/null 2>&1; then
  echo "ERROR: docker daemon is not accessible via plain docker (sudo fallback disabled)." >&2
  exit 1
fi

die() {
  echo "ERROR: $*" >&2
  exit 1
}

validate_network_uniqueness() {
  local name=""
  local -a bad_networks=()
  while IFS= read -r name; do
    [ -n "${name}" ] || continue
    if [ "${name}" != "${EXPECTED_NETWORK}" ]; then
      bad_networks+=("${name}")
    fi
  done < <("${DOCKER_CMD[@]}" network ls --format '{{.Name}}' | rg "${NETWORK_REGEX}" || true)

  if ! "${DOCKER_CMD[@]}" network inspect "${EXPECTED_NETWORK}" >/dev/null 2>&1; then
    die "expected network not found: ${EXPECTED_NETWORK}"
  fi
  if [ "${#bad_networks[@]}" -gt 0 ]; then
    die "duplicate default network(s) found: ${bad_networks[*]} (expected only ${EXPECTED_NETWORK})"
  fi
}

require_container() {
  local name="$1"
  "${DOCKER_CMD[@]}" inspect "$name" >/dev/null 2>&1 || die "container not found: $name"
}

container_networks() {
  local name="$1"
  "${DOCKER_CMD[@]}" inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$name" | sed '/^$/d'
}

echo "==> Checking shared network between ${WEBUI_CONTAINER} and ${PROXY_CONTAINER}"
validate_network_uniqueness
require_container "$WEBUI_CONTAINER"
require_container "$PROXY_CONTAINER"

webui_nets="$(container_networks "$WEBUI_CONTAINER")"
proxy_nets="$(container_networks "$PROXY_CONTAINER")"

[ -n "$webui_nets" ] || die "${WEBUI_CONTAINER} has no networks"
[ -n "$proxy_nets" ] || die "${PROXY_CONTAINER} has no networks"

shared_nets="$(comm -12 <(printf '%s\n' "$webui_nets" | sort -u) <(printf '%s\n' "$proxy_nets" | sort -u))"
[ -n "$shared_nets" ] || die "no shared networks between ${WEBUI_CONTAINER} and ${PROXY_CONTAINER}"
printf '%s\n' "$shared_nets" | rg -qx "${EXPECTED_NETWORK}" \
  || die "shared network is not ${EXPECTED_NETWORK}; got: $(printf '%s' "$shared_nets" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
echo "OK: shared network(s): $(printf '%s' "$shared_nets" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

echo "==> Checking DNS resolution from ${WEBUI_CONTAINER}"
"${DOCKER_CMD[@]}" exec "$WEBUI_CONTAINER" getent hosts openai-proxy >/dev/null \
  || die "DNS resolution failed inside ${WEBUI_CONTAINER}: getent hosts openai-proxy"
echo "OK: openai-proxy resolves inside ${WEBUI_CONTAINER}"

echo "==> Checking HTTP connectivity from ${WEBUI_CONTAINER} to openai-proxy:8088"
probe="$("${DOCKER_CMD[@]}" exec "$WEBUI_CONTAINER" sh -lc 'curl -fsS http://openai-proxy:8088/v1/models | head -c 80')" \
  || die "HTTP probe failed: curl http://openai-proxy:8088/v1/models"
echo "OK: HTTP probe returned: ${probe}"

echo "NETWORK SMOKE OK"
