from fastapi import FastAPI, Request, Response
import os
import httpx

UPSTREAM = os.environ.get("OPENAI_PROXY_URL", "http://openai-proxy:8088")
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
