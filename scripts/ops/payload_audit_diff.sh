#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <fileA.json> <fileB.json>" >&2
  exit 1
fi

A="$1"
B="$2"

python3 - <<'PY' "$A" "$B"
import json
import sys
from pathlib import Path

pa = Path(sys.argv[1])
pb = Path(sys.argv[2])

a = json.loads(pa.read_text(encoding='utf-8'))
b = json.loads(pb.read_text(encoding='utf-8'))

def g(d, path, default=0):
    cur = d
    for k in path:
        if not isinstance(cur, dict) or k not in cur:
            return default
        cur = cur[k]
    return cur

fields = [
    ("model", ["model"]),
    ("messages.count", ["messages", "count"]),
    ("messages.chars_total", ["messages", "chars_total"]),
    ("messages.by_role.system", ["messages", "by_role", "system"]),
    ("messages.by_role.user", ["messages", "by_role", "user"]),
    ("messages.by_role.assistant", ["messages", "by_role", "assistant"]),
    ("tools.count", ["tools", "count"]),
    ("tools.chars_total", ["tools", "chars_total"]),
    ("has_tool_choice", ["has_tool_choice"]),
    ("has_retrieval_context", ["has_retrieval_context"]),
    ("retrieval_chars_total", ["retrieval_chars_total"]),
]

print(f"A={pa}")
print(f"B={pb}")
print("--- key diff ---")
for label, path in fields:
    av = g(a, path, None)
    bv = g(b, path, None)
    if isinstance(av, (int, float)) and isinstance(bv, (int, float)):
        dv = bv - av
    else:
        dv = "n/a"
    print(f"{label}: A={av} | B={bv} | delta={dv}")

print("--- other_large_fields ---")
a_large = g(a, ["other_large_fields"], [])
b_large = g(b, ["other_large_fields"], [])
print("A:", json.dumps(a_large, ensure_ascii=False))
print("B:", json.dumps(b_large, ensure_ascii=False))
PY
