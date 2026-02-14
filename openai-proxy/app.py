from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
import httpx, os, json, time, logging, asyncio, random, uuid
from urllib.parse import urlparse
from common.policy import load_policy, get_user_role

logger = logging.getLogger("openai-proxy")


def _normalize_upstream_base(raw: str) -> str:
    base = (raw or "").strip().rstrip("/")
    if not base:
        return "https://api.openai.com/v1"
    if base.endswith("/v1"):
        return base
    return f"{base}/v1"


def _build_upstream_url(base: str, path: str) -> str:
    clean_path = (path or "").lstrip("/")
    if base.endswith("/v1") and (clean_path == "v1" or clean_path.startswith("v1/")):
        clean_path = clean_path[3:] if clean_path.startswith("v1/") else ""
    clean_path = clean_path.lstrip("/")
    return base if not clean_path else f"{base}/{clean_path}"


OPENAI_BASE = _normalize_upstream_base(
    os.environ.get("OPENAI_API_BASE_URL")
    or os.environ.get("UPSTREAM")
    or os.environ.get("TARGET_BASE_URL")
    or os.environ.get("OPENAI_BASE")
    or "https://api.openai.com/v1"
)
OPENAI_KEY  = os.environ.get("OPENAI_API_KEY", "")
DEV_FALLBACK_USER_ID = os.environ.get(
    "ONTOGIT_DEV_FALLBACK_USER_ID",
    os.environ.get("ONTOGIT_FALLBACK_USER_ID", os.environ.get("DEFAULT_USER_ID", "")),
).strip()
USAGE_WRITER_URL = os.environ.get("USAGE_WRITER_URL", "http://usage-writer:8091/usage")
USAGE_WRITER_BASE = os.environ.get("USAGE_WRITER_BASE", "http://usage-writer:8091")
USAGE_USED_URL = os.environ.get("USAGE_USED_URL", f"{USAGE_WRITER_BASE}/used")
USAGE_LIMITS_URL = os.environ.get("USAGE_LIMITS_URL", f"{USAGE_WRITER_BASE}/limits")
USAGE_TELEMETRY_URL = os.environ.get("USAGE_TELEMETRY_URL", f"{USAGE_WRITER_BASE}/telemetry")
FORCE_NON_STREAM = os.environ.get("FORCE_NON_STREAM", "1") == "1"
POLICY_PATH = os.environ.get("POLICY_PATH", "/ontogit_user/onto_policy.yml")
ROLE_SOURCE = (os.environ.get("ONTOGIT_ROLE_SOURCE", "") or "").strip().lower()
TELEMETRY_ENABLED = os.environ.get("ONTOGIT_TELEMETRY", "0") == "1"
_MAX_CONCURRENCY = int(os.environ.get("OPENAI_PROXY_MAX_CONCURRENCY", "8") or "8")
if _MAX_CONCURRENCY < 5:
    _MAX_CONCURRENCY = 5
if _MAX_CONCURRENCY > 10:
    _MAX_CONCURRENCY = 10
UPSTREAM_SEMAPHORE = asyncio.Semaphore(_MAX_CONCURRENCY)
RETRY_DELAYS = (0.2, 0.6, 1.5)

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


async def post_telemetry(event: dict):
    try:
        async with httpx.AsyncClient(timeout=2.0) as c:
            await c.post(USAGE_TELEMETRY_URL, json=event)
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


async def _request_upstream_with_retry(method: str, url: str, params: dict, body: bytes | None, headers: dict):
    last_exc: Exception | None = None
    for attempt in range(len(RETRY_DELAYS) + 1):
        try:
            async with httpx.AsyncClient(timeout=None) as client:
                return await client.request(
                    method,
                    url,
                    params=params,
                    content=body if body else None,
                    headers=headers,
                )
        except (httpx.ConnectError, httpx.TimeoutException) as exc:
            last_exc = exc
            if attempt >= len(RETRY_DELAYS):
                break
            delay = RETRY_DELAYS[attempt] + random.uniform(0.0, 0.2)
            await asyncio.sleep(delay)
    if last_exc is not None:
        raise last_exc
    raise httpx.HTTPError("upstream request failed")


def _limit_headers(user_id: str, used: float | None, limit: float, warn_level: str, role: str | None = None) -> dict:
    used_val = float(used or 0.0)
    headers = {
        "X-Ontogit-User": user_id or "",
        "X-Ontogit-Used-USD": f"{used_val:.6f}",
        "X-Ontogit-Limit-USD": f"{limit:.6f}",
        "X-Ontogit-Warn": warn_level,
    }
    if role:
        headers["X-Ontogit-Role"] = role
    return headers


def _resolve_user_id(req: Request) -> str | None:
    user_id = _pick_first_header(
        req,
        ["x-openwebui-user-id", "x-ontogit-user", "x-user-id", "x-webui-user-id", "x-forwarded-user", "x-auth-user"],
    )
    if user_id:
        return user_id

    if DEV_FALLBACK_USER_ID:
        return DEV_FALLBACK_USER_ID
    return "unknown"

@app.api_route("/{path:path}", methods=["GET","POST","PUT","PATCH","DELETE","OPTIONS"])
async def proxy(path: str, req: Request):
    url = _build_upstream_url(OPENAI_BASE, path)

    # прокидываем минимум нужного
    headers = {}
    ct = req.headers.get("content-type")
    if ct:
        headers["Content-Type"] = ct

    # AUTH (строго)
    if OPENAI_KEY:
        headers["Authorization"] = f"Bearer {OPENAI_KEY}"

    body = await req.body()
    req_id = _pick_first_header(req, ["x-request-id"]) or f"req_{uuid.uuid4().hex}"
    model_hint = None
    model = None
    tokens_in = None
    tokens_out = None
    total_tokens = None
    history_before = _pick_first_header(req, ["x-ontogit-history-before"])
    history_after = _pick_first_header(req, ["x-ontogit-history-after"])
    retry_count = 0
    error_type = ""
    http_status = None
    t0 = time.time()

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
                model_hint = obj.get("model")
                body = json.dumps(obj).encode("utf-8")
        except Exception:
            pass

    user_id = _resolve_user_id(req)
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

    policy = load_policy(POLICY_PATH)
    role_header = None
    if ROLE_SOURCE == "openwebui" and user_id:
        role_header = str((limits or {}).get("role") or "").strip() or None
    elif policy and user_id:
        assigned_role = str((limits or {}).get("role") or "")
        role_header = get_user_role(user_id, policy, assigned_role=assigned_role)

    limit_headers = _limit_headers(user_id, used, limit_usd, warn_level, role=role_header)

    # block only /v1/chat/completions when over limit
    if req.method.upper() == "POST" and path == "v1/chat/completions" and user_id:
        if limit_usd > 0 and used is not None and used >= limit_usd:
            http_status = 429
            error_type = "429"
            resp = JSONResponse(
                status_code=429,
                content={
                    "error": {
                        "message": "Monthly quota exceeded",
                        "type": "quota_exceeded",
                        "code": "quota_exceeded",
                        "user_id": user_id,
                        "used_usd": float(used or 0.0),
                        "limit_usd": float(limit_usd),
                    }
                },
                headers=limit_headers,
            )
            if TELEMETRY_ENABLED:
                latency_ms = int((time.time() - t0) * 1000)
                asyncio.create_task(
                    post_telemetry(
                        {
                            "ts": int(time.time()),
                            "user_id": user_id,
                            "model": model_hint,
                            "request_id": req_id,
                            "tokens_in": tokens_in,
                            "tokens_out": tokens_out,
                            "total_tokens": total_tokens,
                            "http_status": http_status,
                            "error_type": error_type,
                            "retry_count": retry_count,
                            "latency_ms": latency_ms,
                            "history_pairs_before": int(history_before) if history_before else None,
                            "history_pairs_after": int(history_after) if history_after else None,
                        }
                    )
                )
            return resp

    upstream_host = urlparse(url).hostname or "unknown"
    try:
        async with UPSTREAM_SEMAPHORE:
            upstream = await _request_upstream_with_retry(
                req.method,
                url,
                dict(req.query_params),
                body,
                headers,
            )
    except httpx.ConnectError:
        logger.error("upstream_connect_error host=%s code=connect_error", upstream_host)
        http_status = 502
        error_type = "connect_error"
        resp = JSONResponse(
            status_code=502,
            content={
                "error": {
                    "type": "upstream_connect_error",
                    "code": "connect_error",
                    "hostname": upstream_host,
                    "message": "Upstream is unreachable",
                }
            },
            headers=limit_headers,
        )
        if TELEMETRY_ENABLED:
            latency_ms = int((time.time() - t0) * 1000)
            asyncio.create_task(
                post_telemetry(
                    {
                        "ts": int(time.time()),
                        "user_id": user_id,
                        "model": model_hint,
                        "request_id": req_id,
                        "tokens_in": tokens_in,
                        "tokens_out": tokens_out,
                        "total_tokens": total_tokens,
                        "http_status": http_status,
                        "error_type": error_type,
                            "retry_count": retry_count,
                            "latency_ms": latency_ms,
                            "history_pairs_before": int(history_before) if history_before else None,
                            "history_pairs_after": int(history_after) if history_after else None,
                        }
                    )
                )
        return resp
    except httpx.TimeoutException:
        logger.error("upstream_timeout_error host=%s code=timeout_error", upstream_host)
        http_status = 504
        error_type = "504"
        resp = JSONResponse(
            status_code=504,
            content={
                "error": {
                    "type": "upstream_timeout_error",
                    "code": "timeout_error",
                    "hostname": upstream_host,
                    "message": "Upstream timeout",
                }
            },
            headers=limit_headers,
        )
        if TELEMETRY_ENABLED:
            latency_ms = int((time.time() - t0) * 1000)
            asyncio.create_task(
                post_telemetry(
                    {
                        "ts": int(time.time()),
                        "user_id": user_id,
                        "model": model_hint,
                        "request_id": req_id,
                        "tokens_in": tokens_in,
                        "tokens_out": tokens_out,
                        "total_tokens": total_tokens,
                        "http_status": http_status,
                        "error_type": error_type,
                            "retry_count": retry_count,
                            "latency_ms": latency_ms,
                            "history_pairs_before": int(history_before) if history_before else None,
                            "history_pairs_after": int(history_after) if history_after else None,
                        }
                    )
                )
        return resp
    except httpx.HTTPError:
        logger.error("upstream_http_error host=%s code=http_error", upstream_host)
        http_status = 502
        error_type = "502"
        resp = JSONResponse(
            status_code=502,
            content={
                "error": {
                    "type": "upstream_http_error",
                    "code": "http_error",
                    "hostname": upstream_host,
                    "message": "Upstream request failed",
                }
            },
            headers=limit_headers,
        )
        if TELEMETRY_ENABLED:
            latency_ms = int((time.time() - t0) * 1000)
            asyncio.create_task(
                post_telemetry(
                    {
                        "ts": int(time.time()),
                        "user_id": user_id,
                        "model": model_hint,
                        "request_id": req_id,
                        "tokens_in": tokens_in,
                        "tokens_out": tokens_out,
                        "total_tokens": total_tokens,
                        "http_status": http_status,
                        "error_type": error_type,
                            "retry_count": retry_count,
                            "latency_ms": latency_ms,
                            "history_pairs_before": int(history_before) if history_before else None,
                            "history_pairs_after": int(history_after) if history_after else None,
                        }
                    )
                )
        return resp

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
                tokens_in = pt
                tokens_out = ct2
                total_tokens = tt
        except Exception:
            pass

    if TELEMETRY_ENABLED:
        http_status = int(upstream.status_code)
        if http_status in (429, 502, 504):
            error_type = str(http_status)
        latency_ms = int((time.time() - t0) * 1000)
        asyncio.create_task(
            post_telemetry(
                {
                    "ts": int(time.time()),
                    "user_id": user_id,
                    "model": model or model_hint or "unknown",
                    "request_id": req_id,
                    "tokens_in": tokens_in,
                    "tokens_out": tokens_out,
                    "total_tokens": total_tokens,
                    "http_status": http_status,
                    "error_type": error_type,
                    "retry_count": retry_count,
                    "latency_ms": latency_ms,
                    "history_pairs_before": int(history_before) if history_before else None,
                    "history_pairs_after": int(history_after) if history_after else None,
                }
            )
        )

    return Response(
        content=resp_bytes,
        status_code=upstream.status_code,
        media_type=upstream.headers.get("content-type"),
        headers=limit_headers,
    )
