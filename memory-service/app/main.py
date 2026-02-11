
# ONTOS_FACTS_V1
from .facts_mvp import router as facts_router
import os
import uuid
import subprocess
import hmac
import sqlite3
import time
from pathlib import Path
from datetime import datetime, timezone
from typing import List

import yaml
from fastapi import FastAPI, HTTPException, Request, Response
from pydantic import BaseModel, Field
from app.recall_mvp import embed_and_upsert_scene, recall_hits
from app.prefs_mvp import router as prefs_router  # ONTOS_PREFS_V1
from common.policy import load_policy, get_user_role, get_daily_limits

# uvicorn запускает: app.main:app
app = FastAPI(title="ontogit-memory-service")
app.include_router(prefs_router)
app.include_router(facts_router)

ONTOGIT_DIR = Path(os.environ.get("ONTOGIT_DIR", "/ontogit")).resolve()

ENABLE_GIT_COMMIT = os.environ.get("ENABLE_GIT_COMMIT", "false").lower() in ("1", "true", "yes", "on")
GIT_AUTHOR_NAME = os.environ.get("GIT_AUTHOR_NAME", "OntoGit")
GIT_AUTHOR_EMAIL = os.environ.get("GIT_AUTHOR_EMAIL", "ontogit@local")
from .ontogit_constants import (
    SERVICE_AUTH_ENV,
    SERVICE_AUTH_HEADER,
    USER_ID_HEADER,
    DAILY_TOKEN_LIMIT_ENV,
    DAILY_REQUEST_LIMIT_ENV,
    LIMIT_MODE_ENV,
    ADMIN_USERS_ENV,
    WARN_SERVICE_AUTH,
    WARN_USER_ID_MISSING,
)

SERVICE_AUTH_SECRET = os.environ.get(SERVICE_AUTH_ENV, "")
USAGE_DB = os.environ.get("USAGE_DB", "/ontogit_user/usage.db")
POLICY_PATH = os.environ.get("POLICY_PATH", "/ontogit_user/onto_policy.yml")
_WARNED_MISSING_USER = False
_WARNED_MISSING_SECRET = False
_WARNED_BAD_SERVICE_AUTH = False
_WARNED_LIMIT_LOG = False

DAILY_TOKEN_LIMIT = int(os.environ.get(DAILY_TOKEN_LIMIT_ENV, "0") or 0)
DAILY_REQUEST_LIMIT = int(os.environ.get(DAILY_REQUEST_LIMIT_ENV, "0") or 0)
LIMIT_MODE = (os.environ.get(LIMIT_MODE_ENV, "soft") or "soft").lower()
ADMIN_USERS = {
    u.strip()
    for u in (os.environ.get(ADMIN_USERS_ENV, "") or "").split(",")
    if u.strip()
}


@app.middleware("http")
async def service_auth_middleware(request: Request, call_next):
    global _WARNED_MISSING_SECRET
    global _WARNED_BAD_SERVICE_AUTH
    if not SERVICE_AUTH_SECRET:
        if not _WARNED_MISSING_SECRET:
            _WARNED_MISSING_SECRET = True
            print(f"[memory-service] {WARN_SERVICE_AUTH} (missing secret; deny-all enabled)")
        return Response(status_code=401)
    provided = request.headers.get(SERVICE_AUTH_HEADER)
    if not provided:
        if not _WARNED_BAD_SERVICE_AUTH:
            _WARNED_BAD_SERVICE_AUTH = True
            print(f"[memory-service] {WARN_SERVICE_AUTH} (header missing)")
        return Response(status_code=401)
    if not hmac.compare_digest(provided, SERVICE_AUTH_SECRET):
        if not _WARNED_BAD_SERVICE_AUTH:
            _WARNED_BAD_SERVICE_AUTH = True
            print(f"[memory-service] {WARN_SERVICE_AUTH} (mismatch)")
        return Response(status_code=401)
    return await call_next(request)


def _init_usage_db():
    os.makedirs(os.path.dirname(USAGE_DB), exist_ok=True)
    con = sqlite3.connect(USAGE_DB)
    cur = con.cursor()
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS memory_usage_events (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          ts INTEGER NOT NULL,
          user_id TEXT,
          endpoint TEXT,
          status_code INTEGER,
          request_id TEXT,
          tokens_in INTEGER,
          tokens_out INTEGER
        )
        """
    )
    cur.execute("CREATE INDEX IF NOT EXISTS idx_memory_usage_ts ON memory_usage_events(ts)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_memory_usage_user ON memory_usage_events(user_id)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_memory_usage_endpoint ON memory_usage_events(endpoint)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_memory_usage_user_ts ON memory_usage_events(user_id, ts)")
    con.commit()
    con.close()


def _day_start_ts() -> int:
    now = datetime.now(timezone.utc)
    return int(datetime(now.year, now.month, now.day, tzinfo=timezone.utc).timestamp())


def _count_tokens(text: str) -> int:
    return len((text or "").split())


def _get_daily_usage(con: sqlite3.Connection, user_id: str) -> tuple[int, int]:
    cur = con.cursor()
    cur.execute(
        """
        SELECT COUNT(*), COALESCE(SUM(COALESCE(tokens_in,0) + COALESCE(tokens_out,0)), 0)
        FROM memory_usage_events
        WHERE user_id = ? AND ts >= ?
        """,
        (user_id, _day_start_ts()),
    )
    row = cur.fetchone()
    reqs = int(row[0] or 0)
    toks = int(row[1] or 0)
    return reqs, toks


def _check_limits(user_id: str, tokens_in: int, tokens_out: int) -> tuple[bool, str]:
    policy = load_policy(POLICY_PATH)
    request_limit = DAILY_REQUEST_LIMIT
    token_limit = DAILY_TOKEN_LIMIT
    admin_users = set(ADMIN_USERS)

    if policy:
        admin_users |= set(policy.get("admin_users") or set())
        assigned_role = _get_assigned_role(user_id, policy.get("default_role") or "basic")
        role = get_user_role(user_id, policy, assigned_role=assigned_role)
        req_limit, tok_limit = get_daily_limits(role, policy)
        request_limit = int(req_limit or 0)
        token_limit = int(tok_limit or 0)

    if request_limit <= 0 and token_limit <= 0:
        return False, ""
    if user_id in admin_users:
        return False, "admin_bypass"
    con = sqlite3.connect(USAGE_DB)
    reqs, toks = _get_daily_usage(con, user_id)
    con.close()
    reqs_next = reqs + 1
    toks_next = toks + max(0, int(tokens_in)) + max(0, int(tokens_out))
    if request_limit > 0 and reqs_next > request_limit:
        return True, "request_limit"
    if token_limit > 0 and toks_next > token_limit:
        return True, "token_limit"
    return False, ""


def _get_assigned_role(user_id: str, default_role: str) -> str:
    try:
        con = sqlite3.connect(USAGE_DB)
        cur = con.cursor()
        cur.execute("SELECT role FROM users WHERE user_id = ?", (user_id,))
        row = cur.fetchone()
        con.close()
        if row and row[0]:
            return str(row[0])
    except Exception:
        pass
    return str(default_role or "basic")


def _record_usage(request: Request, endpoint: str, status_code: int, tokens_in: int | None = None, tokens_out: int | None = None):
    global _WARNED_MISSING_USER
    user_id = _get_user_id(request)
    if user_id == "unknown" and not _WARNED_MISSING_USER:
        _WARNED_MISSING_USER = True
        print(f"[memory-service] {WARN_USER_ID_MISSING}")

    req_id = (request.headers.get("x-request-id") or "").strip() or None
    if not req_id:
        req_id = str(uuid.uuid4())
    con = sqlite3.connect(USAGE_DB)
    cur = con.cursor()
    cur.execute(
        """
        INSERT INTO memory_usage_events(ts,user_id,endpoint,status_code,request_id,tokens_in,tokens_out)
        VALUES(?,?,?,?,?,?,?)
        """,
        (int(time.time()), user_id, endpoint, int(status_code), req_id, tokens_in, tokens_out),
    )
    con.commit()
    con.close()


def _get_user_id(request: Request) -> str:
    if hasattr(request.state, "ontogit_user_id"):
        return request.state.ontogit_user_id
    user_id = (request.headers.get(USER_ID_HEADER) or "").strip() or "unknown"
    request.state.ontogit_user_id = user_id
    return user_id


def _append_warn_header(response: Response, code: str):
    # Backward compatibility: normalize legacy internal warn token to canonical public text.
    if code == "user_id_missing":
        code = WARN_USER_ID_MISSING
    prev = response.headers.get("X-Ontogit-Warn")
    if not prev:
        response.headers["X-Ontogit-Warn"] = code
    elif code not in prev.split(","):
        response.headers["X-Ontogit-Warn"] = prev + "," + code


@app.on_event("startup")
def _startup_usage():
    _init_usage_db()


def ensure_repo():
    ONTOGIT_DIR.mkdir(parents=True, exist_ok=True)

    # если репо уже есть — просто гарантируем конфиг
    if (ONTOGIT_DIR / ".git").exists():
        subprocess.run(["git", "-C", str(ONTOGIT_DIR), "config", "user.name", GIT_AUTHOR_NAME], check=False)
        subprocess.run(["git", "-C", str(ONTOGIT_DIR), "config", "user.email", GIT_AUTHOR_EMAIL], check=False)
        return

    # если репо нет — создаём только если включён автокоммит
    if ENABLE_GIT_COMMIT:
        subprocess.run(["git", "-C", str(ONTOGIT_DIR), "init"], check=False)
        subprocess.run(["git", "-C", str(ONTOGIT_DIR), "config", "user.name", GIT_AUTHOR_NAME], check=False)
        subprocess.run(["git", "-C", str(ONTOGIT_DIR), "config", "user.email", GIT_AUTHOR_EMAIL], check=False)


def write_scene(meta: dict, body: str) -> Path:
    ts = datetime.now(timezone.utc)
    meta["timestamp"] = ts.isoformat()

    scene_id = meta.get("scene_id") or (ts.strftime("%Y-%m-%d_%H%M%S") + "-" + uuid.uuid4().hex[:6])
    meta["scene_id"] = scene_id


    # canonical quote: if empty, derive from body
    if not meta.get("quote"):
        body_preview = " ".join((body or "").strip().split())
        meta["quote"] = body_preview[:240]
    p = ONTOGIT_DIR / "scenes" / f"{ts.year:04d}" / f"{ts.month:02d}"
    p.mkdir(parents=True, exist_ok=True)

    fpath = p / f"{scene_id}.md"
    # force canonical quote from body (last-mile)

    body_preview = " ".join((body or "").strip().split())

    meta["quote"] = body_preview[:240]


    # diag: compute preview and force meta fields



    body_preview = " ".join((body or "").strip().split())



    meta["quote"] = body_preview[:240]



    meta["body_preview"] = body_preview[:240]



    print("[write_scene] quote=", repr(meta.get("quote")), "preview=", repr(body_preview[:60]))




    front = yaml.safe_dump(meta, sort_keys=False, allow_unicode=True).strip()
    content = f"---\n{front}\n---\n\n{body.strip()}\n"
    fpath.write_text(content, encoding="utf-8")
    return fpath


def git_commit(path: Path, message: str):
    if not ENABLE_GIT_COMMIT:
        return
    ensure_repo()
    subprocess.run(["git", "-C", str(ONTOGIT_DIR), "add", str(path)], check=False)
    r = subprocess.run(["git", "-C", str(ONTOGIT_DIR), "diff", "--cached", "--quiet"])
    if r.returncode == 0:
        return
    subprocess.run(["git", "-C", str(ONTOGIT_DIR), "commit", "-m", message], check=False)



def split_frontmatter(text: str) -> tuple[dict, str]:
    """
    Parse optional YAML frontmatter:
      ---\n<yaml>\n---\n<body>
    Return (frontmatter_dict, body_without_frontmatter).
    """
    t = text or ""
    t2 = t.lstrip()
    if not t2.startswith("---\n"):
        return {}, t
    end = t2.find("\n---\n", 4)
    if end == -1:
        return {}, t
    yml = t2[4:end]
    body = t2[end+5:]
    try:
        fm = yaml.safe_load(yml) or {}
        if isinstance(fm, dict):
            return fm, body
    except Exception:
        pass
    return {}, t

class RecallReq(BaseModel):
    query: str
    k: int = 5
    user_id: str = "default"



    tags_any: List[str] = Field(default_factory=list)
    min_importance: int = 0
    nodes_any: List[str] = Field(default_factory=list)
    vector_direction: str = ""
    form: str = ""
    force: bool = False
class RecallHit(BaseModel):
    score: float
    scene_id: str
    title: str
    git_path: str
    quote: str = ""
    tags: List[str] = Field(default_factory=list)


class RecallResp(BaseModel):
    hits: List[RecallHit]


class CommitReq(BaseModel):
    user_id: str = "default"
    title: str = ""
    body: str
    tags: List[str] = Field(default_factory=list)
    importance: int = 3


@app.get("/health")
def health():
    return {"ok": True, "ontogit_dir": str(ONTOGIT_DIR), "git_commit": ENABLE_GIT_COMMIT}


@app.post("/recall", response_model=RecallResp)
async def recall(req: RecallReq, request: Request, response: Response):
    # RECALL_SERVER_GATE_V1
    q = (req.query or '').strip()
    user_id = _get_user_id(request)
    tokens_in = _count_tokens(req.query or "")
    limit_exceeded, _ = _check_limits(user_id, tokens_in, 0)
    if limit_exceeded and LIMIT_MODE == "hard":
        _record_usage(request, "recall", 429, tokens_in=tokens_in, tokens_out=0)
        return Response(content='{"error":"quota_exceeded"}', status_code=429, media_type="application/json")
    if limit_exceeded and LIMIT_MODE != "hard":
        _append_warn_header(response, "quota_exceeded")
    if user_id == "unknown":
        _append_warn_header(response, WARN_USER_ID_MISSING)
    # Backstop: do NOT spend embeddings/qdrant on short/ack queries unless forced
    if not getattr(req, 'force', False):
        if len(q) < int(os.getenv('RECALL_MIN_CHARS', '20')):
            _record_usage(request, "recall", 200, tokens_in=tokens_in, tokens_out=0)
            return RecallResp(hits=[])
        if q.lower() in ('ok','ок','ага','угу','да','понятно','принято','ага.','ок.','да.','угу.','понял'):
            _record_usage(request, "recall", 200, tokens_in=tokens_in, tokens_out=0)
            return RecallResp(hits=[])
    # END SERVER GATE

    try:
        results = await recall_hits(
            req.query,
            int(req.k),
            user_id=user_id,
            tags_any=req.tags_any,
            min_importance=int(req.min_importance),
            nodes_any=req.nodes_any,
            vector_direction=req.vector_direction,
            form=req.form,
        )
    except Exception as e:
        _record_usage(request, "recall", 200, tokens_in=tokens_in, tokens_out=0)
        return RecallResp(hits=[])
    hits = []
    for r in results:
        payload = r.get("payload") or {}
        hits.append(RecallHit(
            score=float(r.get("score", 0.0)),
            scene_id=str(payload.get("scene_id") or r.get("id")),
            title=str(payload.get("title") or ""),
            git_path=str(payload.get("git_path") or payload.get("path") or ""),
            quote=str(payload.get("quote") or payload.get("body_preview") or ""),
            tags=list(payload.get("tags") or []),
        ))
    _record_usage(request, "recall", 200, tokens_in=tokens_in, tokens_out=0)
    return RecallResp(hits=hits)


@app.post("/commit")
async def commit(req: CommitReq, request: Request, response: Response):
    status_code = 200
    user_id = _get_user_id(request)
    tokens_in = _count_tokens(req.body or "")
    limit_exceeded, _ = _check_limits(user_id, tokens_in, 0)
    if limit_exceeded and LIMIT_MODE == "hard":
        _record_usage(request, "commit", 429, tokens_in=tokens_in, tokens_out=0)
        return Response(content='{"error":"quota_exceeded"}', status_code=429, media_type="application/json")
    if limit_exceeded and LIMIT_MODE != "hard":
        _append_warn_header(response, "quota_exceeded")
    if user_id == "unknown":
        _append_warn_header(response, WARN_USER_ID_MISSING)
    try:
        if not req.body or not req.body.strip():
            status_code = 400
            raise HTTPException(status_code=400, detail="body is empty")
        # Parse optional YAML frontmatter in body (8-layer schema)
        fm, body_text = split_frontmatter(req.body)
        body_text = (body_text or "").strip()
        if not body_text:
            status_code = 400
            raise HTTPException(status_code=400, detail="body is empty")

        # Title: req.title -> fm.title -> first body line
        title = (req.title or "").strip() or str(fm.get("title") or "").strip() or body_text.splitlines()[0][:80]

        # Base meta (scene-template fields)
        meta = {
            "scene_id": "",
            "title": title,
            "timestamp": "",
            "pulse": str(fm.get("pulse") or ""),
            "vector": fm.get("vector") if "vector" in fm else "",
            "archetype": str(fm.get("archetype") or ""),
            "quote": str(fm.get("quote") or ""),
            "tags": (req.tags if req.tags else (fm.get("tags") or [])),
            "importance": int(req.importance) if req.importance is not None else int(fm.get("importance") or 3),
            "user_id": user_id,
        }

        # Merge 8-layer blocks if provided
        for k in ["excitation","distinction","form","subjectivity","structure_links","archetypes","vector"]:
            if k in fm:
                meta[k] = fm[k]

        # Canonical quote/body_preview from CLEAN body
        body_preview = " ".join(body_text.split())
        meta["body_preview"] = body_preview[:240]
        if not meta.get("quote"):
            meta["quote"] = meta["body_preview"]

        fpath = write_scene(meta, body_text)
        git_commit(fpath, f"scene: {meta['scene_id']} | {title}")

        # MVP: embeddings + upsert (do not fail commit if embedding/qdrant fails)
        try:
            await embed_and_upsert_scene(
                scene_id=meta['scene_id'],
                title=meta['title'],
                git_path=str(fpath.relative_to(ONTOGIT_DIR)),
                user_id=meta.get("user_id","default"),
                tags=list(meta.get("tags") or []),
                importance=int(meta.get("importance") or 3),
                body=body_text,
                quote=str(meta.get('quote','')),
                meta=meta,
            )
        except Exception:
            pass

        return {"ok": True, "scene_id": meta["scene_id"], "path": str(fpath.relative_to(ONTOGIT_DIR))}
    except HTTPException:
        raise
    except Exception:
        status_code = 500
        raise
    finally:
        _record_usage(request, "commit", status_code, tokens_in=tokens_in, tokens_out=0)
