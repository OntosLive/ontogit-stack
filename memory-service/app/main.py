import os, re, json, hashlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional, List, Dict

import httpx
import yaml
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from qdrant_client import QdrantClient
from qdrant_client.http.models import VectorParams, Distance, PointStruct, Filter, FieldCondition, MatchValue

APP = FastAPI(title="ontogit-memory-service")

ONTOGIT_DIR = Path(os.environ.get("ONTOGIT_DIR", "/ontogit")).resolve()
QDRANT_URL = os.environ.get("QDRANT_URL", "http://127.0.0.1:6333")
QDRANT_COLLECTION = os.environ.get("QDRANT_COLLECTION", "ontogit_scenes")

EMBED_BASE_URL = os.environ.get("EMBED_BASE_URL", "").rstrip("/")
EMBED_API_KEY = os.environ.get("EMBED_API_KEY", "")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "")

qdrant = QdrantClient(url=QDRANT_URL)

def _slug(s: str) -> str:
    s = s.strip().lower()
    s = re.sub(r"[^\w\s-]+", "", s, flags=re.UNICODE)
    s = re.sub(r"[\s_]+", "-", s)
    s = re.sub(r"-{2,}", "-", s).strip("-")
    return s[:64] or "scene"

async def embed(text: str) -> List[float]:
    if not EMBED_BASE_URL or not EMBED_MODEL:
        raise HTTPException(500, "Embedding is not configured (EMBED_BASE_URL/EMBED_MODEL).")
    url = f"{EMBED_BASE_URL}/embeddings"
    headers = {"Content-Type": "application/json"}
    if EMBED_API_KEY:
        headers["Authorization"] = f"Bearer {EMBED_API_KEY}"
    payload = {"model": EMBED_MODEL, "input": text}
    async with httpx.AsyncClient(timeout=60) as client:
        r = await client.post(url, headers=headers, json=payload)
        if r.status_code >= 400:
            raise HTTPException(r.status_code, f"Embedding error: {r.text[:400]}")
        data = r.json()
    return data["data"][0]["embedding"]

def ensure_repo():
    ONTOGIT_DIR.mkdir(parents=True, exist_ok=True)
    if not (ONTOGIT_DIR / ".git").exists():
        os.system(f'git -C "{ONTOGIT_DIR}" init')
        os.system(f'git -C "{ONTOGIT_DIR}" config user.name "{os.environ.get("GIT_AUTHOR_NAME","OntoGit")}"')
        os.system(f'git -C "{ONTOGIT_DIR}" config user.email "{os.environ.get("GIT_AUTHOR_EMAIL","ontogit@local")}"')

def ensure_collection(dim: int):
    try:
        qdrant.get_collection(QDRANT_COLLECTION)
        return
    except Exception:
        pass
    qdrant.create_collection(
        collection_name=QDRANT_COLLECTION,
        vectors_config=VectorParams(size=dim, distance=Distance.COSINE),
    )

def write_scene(meta: Dict[str, Any], body: str) -> Path:
    ts = meta.get("timestamp") or datetime.now(timezone.utc).isoformat()
    meta["timestamp"] = ts
    scene_id = meta.get("scene_id") or f"{ts[:10]}-{_slug(meta.get('title','scene'))}"
    meta["scene_id"] = scene_id

    dt = datetime.fromisoformat(ts.replace("Z","+00:00"))
    p = ONTOGIT_DIR / "scenes" / f"{dt.year:04d}" / f"{dt.month:02d}"
    p.mkdir(parents=True, exist_ok=True)
    fpath = p / f"{scene_id}.md"

    front = yaml.safe_dump(meta, sort_keys=False, allow_unicode=True).strip()
    content = f"---\n{front}\n---\n\n{body.strip()}\n"
    fpath.write_text(content, encoding="utf-8")
    return fpath

def git_commit(path: Path, message: str):
    ensure_repo()
    os.system(f'git -C "{ONTOGIT_DIR}" add "{path}"')
    # если нет изменений — тихо выходим
    rc = os.system(f'git -C "{ONTOGIT_DIR}" diff --cached --quiet')
    if rc == 0:
        return
    os.system(f'git -C "{ONTOGIT_DIR}" commit -m "{message.replace(\'"\', \'\\\"\')}"')

class RecallReq(BaseModel):
    query: str
    k: int = 5
    user_id: str = "default"

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
    vector: str = ""
    archetype: str = ""
    tags: List[str] = Field(default_factory=list)
    quote: str = ""
    importance: int = 3
    body: str

@APP.get("/health")
def health():
    return {"ok": True}

@APP.post("/recall", response_model=RecallResp)
async def recall(req: RecallReq):
    v = await embed(req.query)
    ensure_collection(len(v))

    flt = Filter(must=[FieldCondition(key="user_id", match=MatchValue(value=req.user_id))])
    res = qdrant.search(
        collection_name=QDRANT_COLLECTION,
        query_vector=v,
        limit=req.k,
        query_filter=flt,
        with_payload=True,
    )

    hits: List[RecallHit] = []
    for r in res:
        payload = r.payload or {}
        hits.append(RecallHit(
            score=float(r.score),
            scene_id=str(payload.get("scene_id","")),
            title=str(payload.get("title","")),
            git_path=str(payload.get("git_path","")),
            quote=str(payload.get("quote",""))[:180],
            tags=list(payload.get("tags",[]) or []),
        ))
    return RecallResp(hits=hits)

@APP.post("/commit")
async def commit(req: CommitReq):
    if not req.body.strip():
        raise HTTPException(400, "body is empty")

    meta = {
        "scene_id": "",
        "title": req.title.strip() or req.body.strip().splitlines()[0][:80],
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "pulse": "",
        "vector": req.vector.strip(),
        "archetype": req.archetype.strip(),
        "quote": req.quote.strip(),
        "tags": req.tags,
        "importance": int(req.importance),
    }
    fpath = write_scene(meta, req.body)

    # индексируем
    text_for_embed = f"{meta['title']}\n\n{req.body}"
    vec = await embed(text_for_embed)
    ensure_collection(len(vec))

    pid = int(hashlib.sha256((meta["scene_id"] + req.user_id).encode("utf-8")).hexdigest()[:16], 16)
    payload = {
        "user_id": req.user_id,
        "scene_id": meta["scene_id"],
        "title": meta["title"],
        "quote": meta["quote"],
        "tags": meta["tags"],
        "git_path": str(fpath.relative_to(ONTOGIT_DIR)),
        "timestamp": meta["timestamp"],
        "importance": meta["importance"],
    }
    qdrant.upsert(
        collection_name=QDRANT_COLLECTION,
        points=[PointStruct(id=pid, vector=vec, payload=payload)],
    )

    git_commit(fpath, f"scene: {meta['scene_id']} | {meta['title']}")
    return {"ok": True, "scene_id": meta["scene_id"], "path": payload["git_path"]}
