from fastapi import FastAPI, Request, Response
import os
import httpx
import asyncio
import json
from urllib.parse import quote

UPSTREAM = os.environ.get("OPENAI_PROXY_URL", "http://openai-proxy:8088")
USAGE_WRITER_BASE = os.environ.get("USAGE_WRITER_BASE", "http://usage-writer:8091").rstrip("/")
USAGE_LIMITS_URL = os.environ.get("USAGE_LIMITS_URL", f"{USAGE_WRITER_BASE}/limits")
USAGE_USED_URL = os.environ.get("USAGE_USED_URL", f"{USAGE_WRITER_BASE}/used")
LIMIT_MODE = (os.environ.get("ONTOGIT_LIMIT_MODE", "soft") or "soft").strip().lower()
FALLBACK_USER = os.environ.get(
    "ONTOGIT_DEV_FALLBACK_USER_ID",
    os.environ.get("ONTOGIT_FALLBACK_USER_ID", os.environ.get("FALLBACK_USER", "")),
).strip()

app = FastAPI()


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
    headers = {
        "X-Ontogit-Limit-Used-Usd": f"{used_usd:.6f}",
        "X-Ontogit-Limit-Limit-Usd": f"{limit_usd:.6f}",
    }
    if limit_usd > 0:
        if used_usd >= limit_usd * warn_90:
            headers["X-Ontogit-Limit-Warn"] = "1"
            headers["X-Ontogit-Limit-Warn-Level"] = "warn_90"
        elif used_usd >= limit_usd * warn_70:
            headers["X-Ontogit-Limit-Warn"] = "1"
            headers["X-Ontogit-Limit-Warn-Level"] = "warn_70"
    return headers


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
async def proxy(path: str, req: Request):
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
    url = f"{UPSTREAM}/{path}"

    async with httpx.AsyncClient(timeout=None) as client:
        upstream = await client.request(
            req.method,
            url,
            params=dict(req.query_params),
            content=body if body else None,
            headers=headers,
        )

    return Response(
        content=upstream.content,
        status_code=upstream.status_code,
        media_type=upstream.headers.get("content-type"),
        headers=_build_limit_headers(limit_state) if LIMIT_MODE == "soft" else {},
    )
