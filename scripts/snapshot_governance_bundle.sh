#!/usr/bin/env bash
set -uo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
STATE_DIR="${STACK_DIR}/ops/state"
TS="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${STATE_DIR}/${TS}-govbundle"
POLICY_SRC="/home/ontoslive/ontos_data/ontogit-user/onto_policy.yml"

mkdir -p "${OUT_DIR}"

FAIL_COUNT=0

run_step_stdout() {
  local file="$1"
  local cmd="$2"
  local out="${OUT_DIR}/${file}"
  local err="${out}.err"

  if bash -lc "${cmd}" >"${out}" 2>"${err}"; then
    rm -f "${err}"
    return 0
  fi

  FAIL_COUNT=$((FAIL_COUNT + 1))
  {
    echo "step_failed=1"
    echo "command=${cmd}"
  } >>"${err}"
  return 1
}

run_step_combined() {
  local file="$1"
  local cmd="$2"
  local out="${OUT_DIR}/${file}"
  local err="${out}.err"

  if bash -lc "${cmd}" >"${out}" 2>&1; then
    rm -f "${err}"
    return 0
  fi

  FAIL_COUNT=$((FAIL_COUNT + 1))
  {
    echo "step_failed=1"
    echo "command=${cmd}"
  } >"${err}"
  return 1
}

run_step_stdout "whereami.txt" "cd '${STACK_DIR}' && ./scripts/ow_whereami.sh"
run_step_stdout "docker_ps.txt" "sudo -E docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
run_step_stdout "git_rev_ontogit-stack.txt" "git -C '${STACK_DIR}' rev-parse HEAD && git -C '${STACK_DIR}' status --porcelain"

if [ -f "${POLICY_SRC}" ]; then
  if cp "${POLICY_SRC}" "${OUT_DIR}/policy.yml"; then
    if ! sha256sum "${OUT_DIR}/policy.yml" >"${OUT_DIR}/policy.sha256" 2>"${OUT_DIR}/policy.sha256.err"; then
      FAIL_COUNT=$((FAIL_COUNT + 1))
    else
      rm -f "${OUT_DIR}/policy.sha256.err"
    fi
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "failed to copy ${POLICY_SRC}" >"${OUT_DIR}/policy.yml.err"
  fi
else
  echo "policy missing: ${POLICY_SRC}" >"${OUT_DIR}/policy.yml"
  echo "policy missing: no checksum" >"${OUT_DIR}/policy.sha256"
fi

run_step_stdout "openapi_usage_writer.json" "curl -sS http://127.0.0.1:8091/openapi.json"
run_step_stdout "openapi_header_injector.json" "curl -sS http://127.0.0.1:8089/openapi.json"
run_step_combined "smoke_governance_fast.txt" "cd '${STACK_DIR}' && SMOKE_NO_RECREATE=1 ./scripts/smoke_governance.sh"
run_step_combined "smoke_enforcement_hard.txt" "cd '${STACK_DIR}' && ./scripts/smoke_enforcement_hard.sh"

echo "${OUT_DIR}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi

exit 0
