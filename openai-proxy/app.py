from fastapi import FastAPI, Request, Response
import httpx, os, json, time

OPENAI_BASE = os.environ.get("OPENAI_BASE", "https://api.openai.com")
OPENAI_KEY  = os.environ.get("OPENAI_API_KEY", "")
DEFAULT_USER_ID = os.environ.get("DEFAULT_USER_ID", "")
USAGE_WRITER_URL = os.environ.get("USAGE_WRITER_URL", "http://usage-writer:8091/usage")
USAGE_WRITER_BASE = os.environ.get("USAGE_WRITER_BASE", "http://usage-writer:8091")
USAGE_USED_URL = os.environ.get("USAGE_USED_URL", f"{USAGE_WRITER_BASE}/used")
USAGE_LIMITS_URL = os.environ.get("USAGE_LIMITS_URL", f"{USAGE_WRITER_BASE}/limits")
FORCE_NON_STREAM = os.environ.get("FORCE_NON_STREAM", "1") == "1"

app = FastAPI()


def _pick_first_header(req: Request, keys: list[str]):
    for k in keys:
        v = req.headers.get(k)
        if v:
            return v
    return None


async def post_usage(event: dict):
    try:
        async with httpx.AsyncClient(timeout=3.0) as c:
            await c.post(USAGE_WRITER_URL, json=event)
    except Exception:
        pass

async def get_used(user_id: str) -> float | None:
    if not user_id:
        return None
    try:
        async with httpx.AsyncClient(timeout=3.0) as c:
            r = await c.get(f"{USAGE_USED_URL}/{user_id}")
            if r.status_code == 200:
                data = r.json()
                return float(data.get("used_usd") or 0.0)
    except Exception:
        pass
    return None

async def get_limits(user_id: str) -> dict | None:
    if not user_id:
        return None
    try:
        async with httpx.AsyncClient(timeout=3.0) as c:
            r = await c.get(f"{USAGE_LIMITS_URL}/{user_id}")
            if r.status_code == 200:
                return r.json()
    except Exception:
        pass
    return None


def _limit_headers(user_id: str, used: float | None, limit: float, warn_level: str) -> dict:
    used_val = float(used or 0.0)
    return {
        "X-Ontogit-User": user_id or "",
        "X-Ontogit-Used-USD": f"{used_val:.6f}",
        "X-Ontogit-Limit-USD": f"{limit:.6f}",
        "X-Ontogit-Warn": warn_level,
    }

@app.api_route("/{path:path}", methods=["GET","POST","PUT","PATCH","DELETE","OPTIONS"])
async def proxy(path: str, req: Request):
    url = f"{OPENAI_BASE}/{path}"

    # прокидываем минимум нужного
    headers = {}
    ct = req.headers.get("content-type")
    if ct:
        headers["Content-Type"] = ct

    # AUTH (строго)
    if OPENAI_KEY:
        headers["Authorization"] = f"Bearer {OPENAI_KEY}"

    body = await req.body()

    # Если JSON — нормализуем stream/stream_options
    if body and ct and "application/json" in ct:
        try:
            obj = json.loads(body.decode("utf-8"))
            if isinstance(obj, dict):
                if FORCE_NON_STREAM:
                    # выключаем стрим и вычищаем stream_options
                    if obj.get("stream") is True:
                        obj["stream"] = False
                    if obj.get("stream") is not True and "stream_options" in obj:
                        obj.pop("stream_options", None)
                body = json.dumps(obj).encode("utf-8")
        except Exception:
            pass

    user_id = _pick_first_header(req, ["x-ontogit-user","x-openwebui-user-id","x-user-id","x-webui-user-id","x-forwarded-user","x-auth-user"]) or DEFAULT_USER_ID or "unknown"
    used = await get_used(user_id) if user_id else None
    limits = await get_limits(user_id) if user_id else None
    limit_usd = float((limits or {}).get("limit_usd") or 0.0)
    warn_70 = float((limits or {}).get("warn_70") or 0.7)
    warn_90 = float((limits or {}).get("warn_90") or 0.9)

    warn_level = "none"
    if limit_usd > 0 and used is not None:
        if used >= limit_usd * warn_90:
            warn_level = "monthly:90"
        elif used >= limit_usd * warn_70:
            warn_level = "monthly:70"

    limit_headers = _limit_headers(user_id, used, limit_usd, warn_level)

    # block only /v1/chat/completions when over limit
    if req.method.upper() == "POST" and path == "v1/chat/completions" and user_id:
        if limit_usd > 0 and used is not None and used >= limit_usd:
            return Response(
                content=json.dumps({"error": "limit_exceeded", "user_id": user_id, "used_usd": float(used or 0.0), "limit_usd": limit_usd}),
                status_code=429,
                media_type="application/json",
                headers=limit_headers,
            )

    async with httpx.AsyncClient(timeout=None) as client:
        upstream = await client.request(
            req.method,
            url,
            params=dict(req.query_params),
            content=body if body else None,
            headers=headers,
        )

    resp_bytes = upstream.content

    # попытаться вытащить usage и записать
    if upstream.headers.get("content-type", "").startswith("application/json"):
        try:
            resp_json = upstream.json()
            usage = resp_json.get("usage")
            if isinstance(usage, dict):
                pt = int(usage.get("prompt_tokens") or usage.get("input_tokens") or 0)
                ct2 = int(usage.get("completion_tokens") or usage.get("output_tokens") or 0)
                tt = int(usage.get("total_tokens") or (pt + ct2))
                model = resp_json.get("model") or "unknown"
                event = {
                    "ts": int(time.time()),
                    "user_id": user_id,
                    "chat_id": _pick_first_header(req, ["x-openwebui-chat-id","x-chat-id","x-conversation-id","x-openwebui-conversation-id"]),
                    "model": model,
                    "prompt_tokens": pt,
                    "completion_tokens": ct2,
                    "total_tokens": tt,
                    "cost_usd": (pt/1000.0)*0.0025 + (ct2/1000.0)*0.01,
                }
                await post_usage(event)
        except Exception:
            pass

    return Response(
        content=resp_bytes,
        status_code=upstream.status_code,
        media_type=upstream.headers.get("content-type"),
        headers=limit_headers,
    )
