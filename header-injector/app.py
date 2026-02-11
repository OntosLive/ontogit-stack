from fastapi import FastAPI, Request, Response
import base64, hashlib, hmac, json, os, time
import httpx

UPSTREAM = os.environ.get("OPENAI_PROXY_URL", "http://openai-proxy:8088")
JWT_SECRET = os.environ.get("ONTOS_JWT_SECRET", "")
FALLBACK_USER = "andrey"

app = FastAPI()


def _b64url_decode(data: str) -> bytes:
    pad = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + pad)


def _verify_jwt(token: str) -> str | None:
    try:
        header_b64, payload_b64, sig_b64 = token.split(".")
        header = json.loads(_b64url_decode(header_b64).decode("utf-8"))
        if header.get("alg") != "HS256":
            return None
        if not JWT_SECRET:
            return None
        signing_input = f"{header_b64}.{payload_b64}".encode("utf-8")
        expected = hmac.new(JWT_SECRET.encode("utf-8"), signing_input, hashlib.sha256).digest()
        sig = _b64url_decode(sig_b64)
        if not hmac.compare_digest(sig, expected):
            return None
        payload = json.loads(_b64url_decode(payload_b64).decode("utf-8"))
        sub = payload.get("sub")
        exp = int(payload.get("exp") or 0)
        iat = int(payload.get("iat") or 0)
        now = int(time.time())
        if not sub:
            return None
        if exp <= now:
            return None
        if iat and iat > now + 60:
            return None
        return str(sub)
    except Exception:
        return None


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
async def proxy(path: str, req: Request):
    auth = req.headers.get("x-ontogit-auth")
    if auth:
        if not auth.lower().startswith("bearer "):
            return Response(content=json.dumps({"error": "invalid_token"}), status_code=401, media_type="application/json")
        token = auth.split(" ", 1)[1].strip()
        user_id = _verify_jwt(token)
        if not user_id:
            return Response(content=json.dumps({"error": "invalid_token"}), status_code=401, media_type="application/json")
    else:
        user_id = FALLBACK_USER

    headers = dict(req.headers)
    headers.pop("host", None)
    headers.pop("x-ontogit-auth", None)
    headers["X-Ontogit-User"] = user_id

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
    )
