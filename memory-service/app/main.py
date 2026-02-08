import os
import uuid
import subprocess
from pathlib import Path
from datetime import datetime, timezone
from typing import List

import yaml
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from app.recall_mvp import embed_and_upsert_scene, recall_hits

# uvicorn запускает: app.main:app
app = FastAPI(title="ontogit-memory-service")

ONTOGIT_DIR = Path(os.environ.get("ONTOGIT_DIR", "/ontogit")).resolve()

ENABLE_GIT_COMMIT = os.environ.get("ENABLE_GIT_COMMIT", "false").lower() in ("1", "true", "yes", "on")
GIT_AUTHOR_NAME = os.environ.get("GIT_AUTHOR_NAME", "OntoGit")
GIT_AUTHOR_EMAIL = os.environ.get("GIT_AUTHOR_EMAIL", "ontogit@local")


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
async def recall(req: RecallReq):
    # RECALL_SERVER_GATE_V1
    q = (req.query or '').strip()
    # Backstop: do NOT spend embeddings/qdrant on short/ack queries unless forced
    if not getattr(req, 'force', False):
        if len(q) < int(os.getenv('RECALL_MIN_CHARS', '20')):
            return RecallResp(hits=[])
        if q.lower() in ('ok','ок','ага','угу','да','понятно','принято','ага.','ок.','да.','угу.','понял'):
            return RecallResp(hits=[])
    # END SERVER GATE

    try:
        results = await recall_hits(req.query, int(req.k), user_id=req.user_id, tags_any=req.tags_any, min_importance=int(req.min_importance), nodes_any=req.nodes_any, vector_direction=req.vector_direction, form=req.form)
    except Exception as e:
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
    return RecallResp(hits=hits)


@app.post("/commit")
async def commit(req: CommitReq):
    if not req.body or not req.body.strip():
        raise HTTPException(status_code=400, detail="body is empty")
    # Parse optional YAML frontmatter in body (8-layer schema)
    fm, body_text = split_frontmatter(req.body)
    body_text = (body_text or "").strip()
    if not body_text:
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
        "user_id": req.user_id or str(fm.get("user_id") or "default"),
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
