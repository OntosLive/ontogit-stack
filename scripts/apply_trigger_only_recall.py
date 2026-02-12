#!/usr/bin/env python3
import hashlib
import re
import sqlite3
from pathlib import Path

DB_PATH = Path("/home/ontoslive/ontos_data/openwebui-data-vps-current/webui.db")
FUNCTION_ID = "ontogit_recall_inlet"

# Edit this list to change trigger markers later.
TRIGGER_MARKERS = [
    "//recall",
    "@recall",
    "мурашки",
    "дрожь",
    "точка возврата",
]


def _sha(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:12]


def _replace_defaults(code: str) -> str:
    trigger_csv = ",".join(TRIGGER_MARKERS)
    code = re.sub(
        r'(recall_enable_default:\s*bool\s*=\s*Field\(default=)(True|False)',
        r"\1False",
        code,
    )
    code = re.sub(
        r'(mode:\s*str\s*=\s*Field\(default=)"[^"]*"',
        r'\1"trigger_only"',
        code,
    )
    code = re.sub(
        r'(trigger_words_csv:\s*str\s*=\s*Field\(default=)"[^"]*"',
        rf'\1"{trigger_csv}"',
        code,
    )
    code = re.sub(
        r'(tension_phrases_csv:\s*str\s*=\s*Field\(default=)"[^"]*"',
        r'\1""',
        code,
    )
    return code


def _replace_recall_block(code: str) -> str:
    start_marker = "# --- recall modes (control plane, silent) ---"
    end_marker = "# --- end recall modes ---"
    start = code.find(start_marker)
    end = code.find(end_marker)
    if start < 0 or end < 0 or end <= start:
        raise RuntimeError("recall block markers not found")

    replacement = """            # --- recall modes (control plane, silent) ---
            try:
                if len(t) < int(self.valves.recall_min_chars):
                    do_recall = False
                else:
                    trig_words = self._parse_csv(self.valves.trigger_words_csv)
                    do_recall = self._contains_any(t, trig_words)

                if do_recall:
                    tags_any = self._parse_csv(self.valves.recall_tags_any_csv)
                    payload = {
                        "query": t[:800],
                        "k": int(self.valves.recall_k),
                        "user_id": uid,
                        "force": True,
                        "tags_any": tags_any,
                        "min_importance": int(self.valves.recall_min_importance),
                    }

                    hits = self._bg_recall(payload)
                    pack = self._build_recall_pack(hits)
                    if pack:
                        msgs = body.get("messages") if isinstance(body, dict) else None
                        if isinstance(msgs, list) and msgs:
                            idx = None
                            for i in range(len(msgs)-1, -1, -1):
                                if isinstance(msgs[i], dict) and msgs[i].get("role") == "user":
                                    idx = i
                                    break
                            if idx is None:
                                idx = len(msgs)
                            msgs.insert(idx, {"role":"system", "content": pack})
                            body["messages"] = msgs
            except Exception as e:
                self._log("recall inject error:", repr(e))
            # --- end recall modes ---"""

    return code[:start] + replacement + code[end + len(end_marker) :]


def main() -> None:
    conn = sqlite3.connect(DB_PATH)
    try:
        cur = conn.cursor()
        row = cur.execute(
            "select content from function where id = ?",
            (FUNCTION_ID,),
        ).fetchone()
        if not row:
            raise RuntimeError(f"function {FUNCTION_ID!r} not found")

        original = row[0]
        patched = _replace_defaults(original)
        patched = _replace_recall_block(patched)

        if patched == original:
            print("no_changes")
            return

        cur.execute(
            "update function set content = ? where id = ?",
            (patched, FUNCTION_ID),
        )
        conn.commit()
        print(
            f"updated function={FUNCTION_ID} sha_before={_sha(original)} sha_after={_sha(patched)} triggers={TRIGGER_MARKERS}"
        )
    finally:
        conn.close()


if __name__ == "__main__":
    main()
