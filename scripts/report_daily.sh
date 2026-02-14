#!/usr/bin/env bash
set -euo pipefail

DAYS="${DAYS:-7}"
BASE_URL="http://127.0.0.1:8091/report/daily"
TS="$(date +%Y%m%d_%H%M%S)"
ART_DIR="/home/ontoslive/ontos_work/ontogit-stack/ops/state/${TS}_report_daily"
RAW_FILE="${ART_DIR}/raw.json"
TABLE_FILE="${ART_DIR}/table.txt"
LOG_FILE="${ART_DIR}/report.log"

mkdir -p "${ART_DIR}"

notify_ok() {
  if command -v paplay >/dev/null 2>&1; then
    paplay /usr/share/sounds/freedesktop/stereo/complete.oga >/dev/null 2>&1 || true
  else
    printf '\a' || true
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "ontogit report" "Daily report ready (${DAYS}d)" >/dev/null 2>&1 || true
  fi
}

notify_fail() {
  local msg="$1"
  if command -v paplay >/dev/null 2>&1; then
    paplay /usr/share/sounds/freedesktop/stereo/dialog-error.oga >/dev/null 2>&1 || true
  else
    printf '\a' || true
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "ontogit report" "Daily report failed: ${msg}" >/dev/null 2>&1 || true
  fi
}

URL="${BASE_URL}?days=${DAYS}"
if ! curl -fsS "${URL}" -o "${RAW_FILE}"; then
  echo "ERROR: failed to fetch ${URL}" | tee -a "${LOG_FILE}"
  notify_fail "fetch failed"
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  jq -r '
    ["date","dau","requests","tokens","usd_est","errors"],
    (.items[] | [
      (.day_ts | tonumber | strftime("%Y-%m-%d")),
      .dau, .requests, .tokens, (.usd_est|tonumber|tostring), .errors
    ])
    | @tsv
  ' "${RAW_FILE}" | column -t > "${TABLE_FILE}"
else
  python3 - "${RAW_FILE}" <<'PY' > "${TABLE_FILE}"
import json, datetime
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
print("date\tdau\trequests\ttokens\tusd_est\terrors")
for item in data.get("items", []):
    ts = int(item.get("day_ts") or 0)
    day = datetime.datetime.utcfromtimestamp(ts).strftime("%Y-%m-%d") if ts else "unknown"
    print(
        f"{day}\t{item.get('dau',0)}\t{item.get('requests',0)}\t"
        f"{item.get('tokens',0)}\t{item.get('usd_est',0)}\t{item.get('errors',0)}"
    )
PY
fi

cat "${TABLE_FILE}"

cat > "${ART_DIR}/how_to_repeat.txt" <<TXT
DAYS=7 ./scripts/report_daily.sh
DAYS=${DAYS} ./scripts/report_daily.sh
TXT

notify_ok
exit 0
