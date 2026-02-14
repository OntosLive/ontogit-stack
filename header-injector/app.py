from fastapi import FastAPI, Request, Response
import os
import httpx
import asyncio
import json
import logging
import threading
import hashlib
from pathlib import Path
from urllib.parse import quote

UPSTREAM = os.environ.get("OPENAI_PROXY_URL", "http://openai-proxy:8088")
USAGE_WRITER_BASE = os.environ.get("USAGE_WRITER_BASE", "http://usage-writer:8091").rstrip("/")
USAGE_LIMITS_URL = os.environ.get("USAGE_LIMITS_URL", f"{USAGE_WRITER_BASE}/limits")
USAGE_USED_URL = os.environ.get("USAGE_USED_URL", f"{USAGE_WRITER_BASE}/used")
LIMIT_MODE = (os.environ.get("ONTOGIT_LIMIT_MODE", "soft") or "soft").strip().lower()
RECALL_DEDUP = (os.environ.get("ONTOGIT_RECALL_DEDUP", "") or "").strip() == "1"
RECALL_DEDUP_MAX = 50
FALLBACK_USER = os.environ.get(
    "ONTOGIT_DEV_FALLBACK_USER_ID",
    os.environ.get("ONTOGIT_FALLBACK_USER_ID", os.environ.get("FALLBACK_USER", "")),
).strip()
METRICS_STATE_PATH = os.environ.get("METRICS_STATE_PATH", "/ontogit_user/metrics_state.json")
METRICS_STATE_SAVE_EVERY = int(os.environ.get("METRICS_STATE_SAVE_EVERY", "10") or 10)
HISTORY_WINDOW_PAIRS = int(os.environ.get("HISTORY_WINDOW_PAIRS", "20") or 20)

app = FastAPI()
log = logging.getLogger("header_injector")
METRICS_LOCK = threading.Lock()
REQUESTS_TOTAL: dict[str, int] = {"soft": 0, "hard": 0}
BLOCKED_TOTAL = 0
WARN_TOTAL: dict[str, int] = {"none": 0, "70": 0, "90": 0, "exceeded": 0}
METRICS_STATE_STOP = threading.Event()
METRICS_STATE_THREAD: threading.Thread | None = None
RECALL_DEDUP_LOCK = threading.Lock()
RECALL_DEDUP_STATE: dict[str, list[str]] = {}


def _estimate_tokens(text: str) -> int:
    if not text:
        return 0
    # Approximate tokens: 1 token ~= 4 chars
    return max(1, int(len(text) / 4))


def _message_text(message: dict) -> str:
    content = message.get("content")
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                parts.append(str(item.get("text") or ""))
        return "\n".join([p for p in parts if p])
    if isinstance(content, str):
        return content
    return ""


def _messages_token_est(messages: list[dict]) -> int:
    total = 0
    for m in messages:
        total += _estimate_tokens(_message_text(m))
    return total


def _count_pairs(messages: list[dict]) -> int:
    roles = [m.get("role") for m in messages if isinstance(m, dict) and m.get("role") in ("user", "assistant")]
    return len(roles) // 2


def _trim_history_pairs(messages: list[dict], max_pairs: int) -> tuple[list[dict], int, int]:
    before_pairs = _count_pairs(messages)
    if max_pairs <= 0:
        return messages, before_pairs, before_pairs

    system_msgs = [m for m in messages if isinstance(m, dict) and m.get("role") == "system"]
    convo_msgs = [m for m in messages if isinstance(m, dict) and m.get("role") in ("user", "assistant")]
    keep = max_pairs * 2
    if len(convo_msgs) <= keep:
        return messages, before_pairs, before_pairs
    trimmed_tail = convo_msgs[-keep:]
    after_pairs = min(before_pairs, max_pairs)
    return system_msgs + trimmed_tail, before_pairs, after_pairs


def _extract_recall_block(text: str) -> tuple[str, int] | None:
    if not text:
        return None
    markers = ["ontogit recall", "ontogit_recall", "recall:", "user context:"]
    low = text.lower()
    for marker in markers:
        idx = low.find(marker)
        if idx >= 0:
            return text[idx:], idx
    return None


def _dedup_seen(conversation_id: str, recall_hash: str) -> bool:
    if not conversation_id or not recall_hash or recall_hash == "none":
        return False
    with RECALL_DEDUP_LOCK:
        history = RECALL_DEDUP_STATE.get(conversation_id)
        if history is None:
            RECALL_DEDUP_STATE[conversation_id] = [recall_hash]
            return False
        if recall_hash in history:
            return True
        history.append(recall_hash)
        if len(history) > RECALL_DEDUP_MAX:
            history[:] = history[-RECALL_DEDUP_MAX :]
        return False


def _recall_marker_text() -> str:
    return "[OntoGit] recall already applied"


def _pick_first_header(req: Request, keys: list[str]) -> str | None:
    for k in keys:
        v = req.headers.get(k)
        if v and v.strip():
            return v.strip()
    return None


def _resolve_user_id(req: Request, existing_ontogit: str | None, openwebui_uid: str | None) -> str:
    if existing_ontogit:
        return existing_ontogit
    if openwebui_uid:
        return openwebui_uid
    if FALLBACK_USER:
        return FALLBACK_USER
    return "unknown"


def _is_llm_request(path: str, method: str) -> bool:
    normalized = path.strip("/")
    return method.upper() == "POST" and normalized == "v1/chat/completions"


async def _fetch_limit_state(user_id: str) -> dict | None:
    if not user_id:
        return None
    user_q = quote(user_id, safe="")
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            limits_req = client.get(f"{USAGE_LIMITS_URL}/{user_q}")
            used_req = client.get(f"{USAGE_USED_URL}/{user_q}")
            limits_resp, used_resp = await asyncio.gather(limits_req, used_req)
    except Exception:
        return None

    if limits_resp.status_code != 200 or used_resp.status_code != 200:
        return None
    try:
        limits = limits_resp.json()
        used = used_resp.json()
        limit_usd = float((limits or {}).get("limit_usd") or 0.0)
        warn_70 = float((limits or {}).get("warn_70") or 0.7)
        warn_90 = float((limits or {}).get("warn_90") or 0.9)
        used_usd = float((used or {}).get("used_usd") or 0.0)
        role = str((limits or {}).get("role") or "basic")
    except Exception:
        return None
    return {
        "role": role,
        "limit_usd": limit_usd,
        "warn_70": warn_70,
        "warn_90": warn_90,
        "used_usd": used_usd,
    }


def _build_limit_headers(limit_state: dict | None) -> dict[str, str]:
    if not limit_state:
        return {}
    limit_usd = float(limit_state.get("limit_usd") or 0.0)
    used_usd = float(limit_state.get("used_usd") or 0.0)
    warn_70 = float(limit_state.get("warn_70") or 0.7)
    warn_90 = float(limit_state.get("warn_90") or 0.9)
    role = str(limit_state.get("role", "") or "")
    warn_level = _compute_warn_level(limit_usd, used_usd, warn_70, warn_90)
    headers = {
        "X-Ontogit-Limit-Used-Usd": f"{used_usd:.6f}",
        "X-Ontogit-Limit-Limit-Usd": f"{limit_usd:.6f}",
        "X-Ontogit-Limit-Role": role,
        "X-Ontogit-Limit-Warn": warn_level,
    }
    return headers


def _compute_warn_level(limit_usd: float, used_usd: float, warn_70: float, warn_90: float) -> str:
    if limit_usd <= 0:
        return "none"
    ratio = used_usd / limit_usd
    if used_usd >= limit_usd:
        return "exceeded"
    if ratio >= warn_90:
        return "90"
    if ratio >= warn_70:
        return "70"
    return "none"


def _inc_requests(mode: str) -> None:
    m = mode if mode in ("soft", "hard") else "soft"
    with METRICS_LOCK:
        REQUESTS_TOTAL[m] = int(REQUESTS_TOTAL.get(m, 0)) + 1


def _inc_blocked() -> None:
    global BLOCKED_TOTAL
    with METRICS_LOCK:
        BLOCKED_TOTAL += 1


def _inc_warn(level: str) -> None:
    l = level if level in ("none", "70", "90", "exceeded") else "none"
    with METRICS_LOCK:
        WARN_TOTAL[l] = int(WARN_TOTAL.get(l, 0)) + 1


def _metrics_snapshot() -> dict:
    with METRICS_LOCK:
        return {
            "version": 1,
            "requests_total": {
                "soft": int(REQUESTS_TOTAL.get("soft", 0)),
                "hard": int(REQUESTS_TOTAL.get("hard", 0)),
            },
            "blocked_total": int(BLOCKED_TOTAL),
            "warn_total": {
                "none": int(WARN_TOTAL.get("none", 0)),
                "70": int(WARN_TOTAL.get("70", 0)),
                "90": int(WARN_TOTAL.get("90", 0)),
                "exceeded": int(WARN_TOTAL.get("exceeded", 0)),
            },
        }


def _load_metrics_state() -> None:
    p = Path(METRICS_STATE_PATH)
    if not p.is_file():
        return
    try:
        raw = json.loads(p.read_text(encoding="utf-8"))
        if not isinstance(raw, dict) or int(raw.get("version") or 0) != 1:
            log.warning("metrics_state_load_skipped_invalid_version")
            return
        req = raw.get("requests_total") or {}
        warn = raw.get("warn_total") or {}
        blocked = int(raw.get("blocked_total") or 0)
        with METRICS_LOCK:
            REQUESTS_TOTAL["soft"] = int(req.get("soft") or 0)
            REQUESTS_TOTAL["hard"] = int(req.get("hard") or 0)
            WARN_TOTAL["none"] = int(warn.get("none") or 0)
            WARN_TOTAL["70"] = int(warn.get("70") or 0)
            WARN_TOTAL["90"] = int(warn.get("90") or 0)
            WARN_TOTAL["exceeded"] = int(warn.get("exceeded") or 0)
            global BLOCKED_TOTAL
            BLOCKED_TOTAL = blocked
    except Exception:
        log.warning("metrics_state_load_failed", exc_info=True)


def _save_metrics_state() -> None:
    p = Path(METRICS_STATE_PATH)
    tmp = p.with_name(f"{p.name}.tmp")
    try:
        payload = _metrics_snapshot()
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps(payload, ensure_ascii=True, sort_keys=True), encoding="utf-8")
        os.replace(tmp, p)
    except Exception:
        log.warning("metrics_state_save_failed", exc_info=True)


def _metrics_state_loop() -> None:
    interval = METRICS_STATE_SAVE_EVERY if METRICS_STATE_SAVE_EVERY > 0 else 10
    while not METRICS_STATE_STOP.wait(interval):
        _save_metrics_state()


@app.on_event("startup")
def _startup_metrics_state() -> None:
    global METRICS_STATE_THREAD
    _load_metrics_state()
    METRICS_STATE_STOP.clear()
    t = threading.Thread(target=_metrics_state_loop, name="metrics-state-saver", daemon=True)
    t.start()
    METRICS_STATE_THREAD = t


@app.on_event("shutdown")
def _shutdown_metrics_state() -> None:
    METRICS_STATE_STOP.set()
    t = METRICS_STATE_THREAD
    if t is not None:
        t.join(timeout=2.0)
    _save_metrics_state()


@app.get("/metrics")
async def metrics():
    with METRICS_LOCK:
        req = dict(REQUESTS_TOTAL)
        warn = dict(WARN_TOTAL)
        blocked = int(BLOCKED_TOTAL)
    lines = [
        '# TYPE ontogit_requests_total counter',
        f'ontogit_requests_total{{mode="soft"}} {int(req.get("soft", 0))}',
        f'ontogit_requests_total{{mode="hard"}} {int(req.get("hard", 0))}',
        '# TYPE ontogit_gate_block_total counter',
        f'ontogit_gate_block_total {blocked}',
        '# TYPE ontogit_warn_total counter',
        f'ontogit_warn_total{{level="none"}} {int(warn.get("none", 0))}',
        f'ontogit_warn_total{{level="70"}} {int(warn.get("70", 0))}',
        f'ontogit_warn_total{{level="90"}} {int(warn.get("90", 0))}',
        f'ontogit_warn_total{{level="exceeded"}} {int(warn.get("exceeded", 0))}',
    ]
    return Response(content="\n".join(lines) + "\n", media_type="text/plain; version=0.0.4")


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
async def proxy(path: str, req: Request):
    _inc_requests(LIMIT_MODE)
    headers = dict(req.headers)
    headers.pop("host", None)

    existing_ontogit = _pick_first_header(req, ["x-ontogit-user"])
    openwebui_uid = _pick_first_header(req, ["x-openwebui-user-id"])
    if not existing_ontogit:
        if openwebui_uid:
            headers["X-Ontogit-User"] = openwebui_uid
        elif FALLBACK_USER:
            headers["X-Ontogit-User"] = FALLBACK_USER

    user_id = _resolve_user_id(req, existing_ontogit, openwebui_uid)
    limit_state = await _fetch_limit_state(user_id) if _is_llm_request(path, req.method) else None
    if limit_state and LIMIT_MODE == "hard":
        limit_usd = float(limit_state.get("limit_usd") or 0.0)
        used_usd = float(limit_state.get("used_usd") or 0.0)
        if limit_usd > 0 and used_usd >= limit_usd:
            _inc_blocked()
            return Response(
                content=json.dumps(
                    {
                        "detail": "limit exceeded",
                        "role": str(limit_state.get("role") or "basic"),
                        "limit_usd": limit_usd,
                        "used_usd": used_usd,
                    }
                ),
                status_code=429,
                media_type="application/json",
                headers=_build_limit_headers(limit_state),
            )

    body = await req.body()
    body_bytes = body
    tokens_before = None
    tokens_after = None
    tokens_recall = None
    recall_hash = "none"
    conversation_id = (
        _pick_first_header(
            req,
            [
                "x-openwebui-chat-id",
                "x-chat-id",
                "x-conversation-id",
                "x-openwebui-conversation-id",
            ],
        )
        or "unknown"
    )

    if body and headers.get("content-type", "").startswith("application/json"):
        try:
            payload = await req.json()
        except Exception:
            payload = {}
        payload = payload or {}
        if isinstance(payload, dict):
            model = payload.get("model")
            messages = payload.get("messages")
            if not model or not isinstance(messages, list):
                pass
            else:
                messages, pairs_before, pairs_after = _trim_history_pairs(messages, HISTORY_WINDOW_PAIRS)
                if pairs_before != pairs_after:
                    req_id = _pick_first_header(req, ["x-request-id"]) or "unknown"
                    log.info(
                        "history_window conversation_id=%s request_id=%s pairs_before=%s pairs_after=%s",
                        conversation_id,
                        req_id,
                        pairs_before,
                        pairs_after,
                    )
                headers["X-Ontogit-History-Before"] = str(pairs_before)
                headers["X-Ontogit-History-After"] = str(pairs_after)
                tokens_after = _messages_token_est(messages)
                recall_block = None
                recall_msg_idx = None
                recall_marker_idx = None

                for i, m in enumerate(messages):
                    if isinstance(m, dict) and m.get("role") == "system":
                        text = _message_text(m)
                        found = _extract_recall_block(text)
                        if found:
                            recall_block, recall_marker_idx = found
                            recall_msg_idx = i
                            break

                if recall_block:
                    tokens_recall = _estimate_tokens(recall_block)
                    tokens_before = max(0, (tokens_after or 0) - tokens_recall)
                    recall_hash = hashlib.sha256(recall_block.encode("utf-8")).hexdigest()

                    if RECALL_DEDUP and _dedup_seen(conversation_id, recall_hash):
                        # Replace recall block with minimal marker to prevent duplication
                        original = _message_text(messages[recall_msg_idx])
                        if recall_marker_idx is not None:
                            new_text = original[:recall_marker_idx] + _recall_marker_text()
                        else:
                            new_text = _recall_marker_text()
                        messages[recall_msg_idx]["content"] = new_text
                        tokens_after = _messages_token_est(messages)
                        tokens_recall = 0

                if tokens_before is None:
                    tokens_before = tokens_after
                if tokens_recall is None:
                    tokens_recall = 0

                log.info(
                    "ontogit_recall_diag conversation_id=%s tokens_before=%s tokens_recall_injected=%s tokens_after=%s recall_hash=%s",
                    conversation_id,
                    tokens_before,
                    tokens_recall,
                    tokens_after,
                    recall_hash,
                )

                payload["messages"] = messages
                body_bytes = json.dumps(payload).encode("utf-8")
    url = f"{UPSTREAM}/{path}"

    async with httpx.AsyncClient(timeout=None) as client:
        upstream = await client.request(
            req.method,
            url,
            params=dict(req.query_params),
            content=body_bytes if body_bytes else None,
            headers=headers,
        )

    response_status = upstream.status_code
    if LIMIT_MODE == "soft" and response_status == 429:
        response_status = 200
        log.warning("soft_mode_no_block: rewrote upstream 429 to 200")
    if LIMIT_MODE == "soft":
        if limit_state:
            warn_level = _compute_warn_level(
                float(limit_state.get("limit_usd") or 0.0),
                float(limit_state.get("used_usd") or 0.0),
                float(limit_state.get("warn_70") or 0.7),
                float(limit_state.get("warn_90") or 0.9),
            )
            _inc_warn(warn_level)
        else:
            _inc_warn("none")

    return Response(
        content=upstream.content,
        status_code=response_status,
        media_type=upstream.headers.get("content-type"),
        headers=_build_limit_headers(limit_state) if LIMIT_MODE == "soft" else {},
    )
