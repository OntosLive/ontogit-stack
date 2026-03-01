#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/home/ontoslive/ontos_work/ontogit-stack"
STATE_BASE="${STACK_DIR}/ops/state"
TS="${ONTOGIT_PAYLOAD_AUDIT_TS:-$(date +%Y%m%d_%H%M%S)}"
STATE_DIR="${STATE_BASE}/${TS}_payload_audit_v1"

OPENWEBUI_BASE_URL="${OPENWEBUI_BASE_URL:-http://127.0.0.1:8080}"
OPENWEBUI_CHAT_PATH="${OPENWEBUI_CHAT_PATH:-/api/chat/completions}"
OPENWEBUI_TOKEN="${OPENWEBUI_TOKEN:-}"
OPENWEBUI_MODEL="${OPENWEBUI_MODEL:-}"
AUDIT_PROMPT="${ONTOGIT_PAYLOAD_AUDIT_PROMPT:-ping}"
REQUEST_ID="${ONTOGIT_PAYLOAD_AUDIT_REQUEST_ID:-payload-audit-${TS}-$(date +%s)}"

mkdir -p "${STATE_DIR}"

if [ -z "${OPENWEBUI_TOKEN}" ]; then
  echo "payload_audit_v1: missing OPENWEBUI_TOKEN" >&2
  exit 1
fi

if [ -z "${OPENWEBUI_MODEL}" ]; then
  echo "payload_audit_v1: missing OPENWEBUI_MODEL" >&2
  exit 1
fi

REQ_JSON="${STATE_DIR}/request_${REQUEST_ID}.json"
RESP_JSON="${STATE_DIR}/response_${REQUEST_ID}.json"
cat > "${REQ_JSON}" <<JSON
{
  "model": "${OPENWEBUI_MODEL}",
  "messages": [
    {"role": "user", "content": "${AUDIT_PROMPT}"}
  ],
  "stream": false
}
JSON

HTTP_CODE="$(curl -sS -o "${RESP_JSON}" -w '%{http_code}' \
  -X POST "${OPENWEBUI_BASE_URL}${OPENWEBUI_CHAT_PATH}" \
  -H "Authorization: Bearer ${OPENWEBUI_TOKEN}" \
  -H "Content-Type: application/json" \
  -H "X-Ontogit-Audit-Only: 1" \
  -H "X-Ontogit-Audit-Ts: ${TS}" \
  -H "X-Request-Id: ${REQUEST_ID}" \
  --data-binary @"${REQ_JSON}")"

if [ "${HTTP_CODE}" != "200" ]; then
  echo "payload_audit_v1: request failed http=${HTTP_CODE}" >&2
  echo "payload_audit_v1: response follows" >&2
  cat "${RESP_JSON}" >&2
  exit 1
fi

ARTIFACT_PATH="$(python3 - <<'PY' "${RESP_JSON}"
import json, sys
p = sys.argv[1]
with open(p, 'r', encoding='utf-8') as f:
    data = json.load(f)
print(data.get('artifact_path', ''))
PY
)"

if [ -z "${ARTIFACT_PATH}" ]; then
  echo "payload_audit_v1: backend did not return artifact_path" >&2
  cat "${RESP_JSON}" >&2
  exit 1
fi

if [ ! -f "${ARTIFACT_PATH}" ]; then
  echo "payload_audit_v1: artifact file not found: ${ARTIFACT_PATH}" >&2
  exit 1
fi

cp -f "${ARTIFACT_PATH}" "${STATE_DIR}/summary_${REQUEST_ID}.json"

echo "OK"
echo "artifact_file=${ARTIFACT_PATH}"
echo "artifact_dir=$(dirname "${ARTIFACT_PATH}")"
echo "state_dir=${STATE_DIR}"
