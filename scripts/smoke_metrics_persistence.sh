#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
SMOKE_NO_RECREATE="${SMOKE_NO_RECREATE:-1}"
BEFORE_FILE="/tmp/metrics_persist_before.prom"
AFTER_FILE="/tmp/metrics_persist_after.prom"

DOCKER=()
pick_docker() {
  if docker ps >/dev/null 2>&1; then
    DOCKER=(docker)
    echo "docker runner: docker"
    return 0
  fi
  if sudo -n env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_CONFIG docker ps >/dev/null 2>&1; then
    DOCKER=(sudo -n env -u DOCKER_HOST -u DOCKER_CONTEXT -u DOCKER_CONFIG docker)
    echo "docker runner: sudo-clean"
    return 0
  fi
  if sudo -n docker ps >/dev/null 2>&1; then
    DOCKER=(sudo -n docker)
    echo "docker runner: sudo-plain"
    return 0
  fi
  if [ -n "${DOCKER_HOST:-}" ] || [ -n "${DOCKER_CONTEXT:-}" ]; then
    local -a sudo_runner=(sudo -n env)
    if [ -n "${DOCKER_HOST:-}" ]; then
      sudo_runner+=("DOCKER_HOST=${DOCKER_HOST}")
    fi
    if [ -n "${DOCKER_CONTEXT:-}" ]; then
      sudo_runner+=("DOCKER_CONTEXT=${DOCKER_CONTEXT}")
    fi
    if "${sudo_runner[@]}" docker ps >/dev/null 2>&1; then
      DOCKER=("${sudo_runner[@]}" docker)
      echo "docker runner: sudo-preserved"
      return 0
    fi
  fi
  echo "docker ps failed; try: sudo usermod -aG docker ${USER:-$(id -un 2>/dev/null || echo your_user)} && newgrp docker"
  echo "WSL/Docker Desktop may still require sudo; scripts use sudo -n automatically when available."
  return 1
}

extract_metric() {
  local file="$1"
  local metric="$2"
  local line
  line="$(grep -F "${metric} " "${file}" | head -n1 || true)"
  if [ -z "${line}" ]; then
    echo ""
    return 1
  fi
  awk '{print $NF}' <<<"${line}"
}

capture_metrics() {
  local out_file="$1"
  local i
  for i in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:8089/metrics > "${out_file}"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

show_metric_snippet() {
  local file="$1"
  local key="$2"
  echo "--- snippet for ${key} in ${file} ---"
  grep -n -F "${key}" "${file}" | head -n 5 || true
}

compare_metric() {
  local name="$1"
  local before="$2"
  local after="$3"
  if ! python3 - "$before" "$after" <<'PY'
import sys
b=float(sys.argv[1])
a=float(sys.argv[2])
raise SystemExit(0 if a >= b else 1)
PY
  then
    echo "FAIL: ${name} decreased after restart (before=${before}, after=${after})"
    return 1
  fi
  echo "${name}: before=${before} after=${after}"
}

pick_docker || exit 1

cd "${STACK_DIR}"

echo "==> generate activity"
SMOKE_NO_RECREATE=1 ./scripts/smoke_enforcement_soft.sh
SMOKE_NO_RECREATE=1 ./scripts/smoke_enforcement_hard.sh

echo "==> capture metrics before"
capture_metrics "${BEFORE_FILE}"

REQ_SOFT_BEFORE="$(extract_metric "${BEFORE_FILE}" 'ontogit_requests_total{mode="soft"}' || true)"
WARN90_BEFORE="$(extract_metric "${BEFORE_FILE}" 'ontogit_warn_total{level="90"}' || true)"
WARNEX_BEFORE="$(extract_metric "${BEFORE_FILE}" 'ontogit_warn_total{level="exceeded"}' || true)"

if [ -z "${REQ_SOFT_BEFORE}" ] || [ -z "${WARN90_BEFORE}" ] || [ -z "${WARNEX_BEFORE}" ]; then
  echo "FAIL: missing required metric(s) in before snapshot"
  show_metric_snippet "${BEFORE_FILE}" "ontogit_requests_total"
  show_metric_snippet "${BEFORE_FILE}" "ontogit_warn_total"
  exit 1
fi

echo "==> restart header-injector"
"${DOCKER[@]}" compose restart header-injector >/dev/null

echo "==> capture metrics after"
capture_metrics "${AFTER_FILE}"

REQ_SOFT_AFTER="$(extract_metric "${AFTER_FILE}" 'ontogit_requests_total{mode="soft"}' || true)"
WARN90_AFTER="$(extract_metric "${AFTER_FILE}" 'ontogit_warn_total{level="90"}' || true)"
WARNEX_AFTER="$(extract_metric "${AFTER_FILE}" 'ontogit_warn_total{level="exceeded"}' || true)"

if [ -z "${REQ_SOFT_AFTER}" ] || [ -z "${WARN90_AFTER}" ] || [ -z "${WARNEX_AFTER}" ]; then
  echo "FAIL: missing required metric(s) in after snapshot"
  show_metric_snippet "${AFTER_FILE}" "ontogit_requests_total"
  show_metric_snippet "${AFTER_FILE}" "ontogit_warn_total"
  exit 1
fi

compare_metric 'ontogit_requests_total{mode="soft"}' "${REQ_SOFT_BEFORE}" "${REQ_SOFT_AFTER}"
compare_metric 'ontogit_warn_total{level="90"}' "${WARN90_BEFORE}" "${WARN90_AFTER}"
compare_metric 'ontogit_warn_total{level="exceeded"}' "${WARNEX_BEFORE}" "${WARNEX_AFTER}"

echo "PASS: metrics persistence smoke passed"
