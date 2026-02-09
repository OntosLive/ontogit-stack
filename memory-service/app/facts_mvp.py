# ONTOS_FACTS_QDRANT_1536_V2
from __future__ import annotations

import os
import uuid
import subprocess

# ONTOS_FACTS_QDRANT_URLLIB_FALLBACK
import json
import urllib.request

def _http_post_json(url: str, payload: dict, timeout: int = 10) -> dict:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8", errors="ignore")
        return json.loads(body) if body else {}

def _qdrant_search_http(collection: str, vector: list, limit: int, flt: dict | None):
    url = f"{QDRANT_URL.rstrip('/')}/collections/{collection}/points/search"
    payload = {"vector": vector, "limit": int(limit), "with_payload": True, "with_vector": False}
    if flt:
        payload["filter"] = flt
    data = _http_post_json(url, payload, timeout=10)
    return data.get("result", [])

from datetime import datetime
from typing import List, Optional, Dict, Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from qdrant_client import QdrantClient
from qdrant_client.http import models as rest

from .recall_mvp import embed_text  # async embeddings via OpenAI (env: EMBED_*)

router = APIRouter(prefix="/facts", tags=["facts"])

FACTS_DIR = os.environ.get("ONTOGIT_FACTS_DIR", "/ontogit/facts")  # container path
FACTS_COLLECTION = os.environ.get("ONTOGIT_FACTS_COLLECTION", "ontogit_facts")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://qdrant:6333")
ONTOGIT_REPO = os.environ.get("ONTOGIT_REPO", "/ontogit")  # container repo root

# ONTOS_FACTS_PATHMAP_V1
ONTOGIT_HOST_DIR = os.environ.get("ONTOGIT_HOST_DIR", "/root/ontogit")  # host-visible path (for API responses)

def _to_host_path(container_abs_path: str) -> str:
    # Convert /ontogit/... -> /root/ontogit/... for operator convenience.
    if not isinstance(container_abs_path, str):
        return container_abs_path
    if container_abs_path.startswith("/ontogit/"):
        return ONTOGIT_HOST_DIR.rstrip("/") + container_abs_path[len("/ontogit"):]
    if container_abs_path == "/ontogit":
        return ONTOGIT_HOST_DIR
    return container_abs_path


def _utc_ts() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"

def _ym_path(ts_iso: str) -> str:
    y = ts_iso[0:4]
    m = ts_iso[5:7]
    return os.path.join(y, m)

def _safe_slug(s: str) -> str:
    s = (s or "").strip().lower()
    s = "".join(ch if ch.isalnum() or ch in "-_." else "-" for ch in s)
    s = "-".join([p for p in s.split("-") if p])
    return s[:60] or "fact"

def _qdrant() -> QdrantClient:
    return QdrantClient(url=QDRANT_URL)

def _ensure_collection() -> None:
    qc = _qdrant()
    try:
        qc.get_collection(FACTS_COLLECTION)
        return
    except Exception:
        pass
    qc.create_collection(
        collection_name=FACTS_COLLECTION,
        vectors_config=rest.VectorParams(size=1536, distance=rest.Distance.COSINE),
        on_disk_payload=True,
    )

def _git_commit(abs_path: str, msg: str) -> None:
    try:
        subprocess.run(["git", "-C", ONTOGIT_REPO, "add", abs_path], check=False)
        subprocess.run(["git", "-C", ONTOGIT_REPO, "commit", "-m", msg], check=False)
    except Exception:
        return

class FactCommitReq(BaseModel):
    fact: str = Field(..., description="Small stable assertion (1-2 sentences). Manual-only.")
    tags: List[str] = Field(default_factory=list)
    importance: int = Field(default=3, ge=0, le=5)
    nodes: List[str] = Field(default_factory=list)
    vector_direction: Optional[str] = Field(default=None, description="forward|reverse (optional)")
    form: str = Field(default="fact", description="always 'fact' for L3")
    user_id: str = Field(default="default")
    source_scene_id: Optional[str] = Field(default=None, description="Optional link to a scene_id that produced this fact")

class FactCommitResp(BaseModel):
    fact_id: str
    git_path: str
    timestamp: str

class FactRecallReq(BaseModel):
    query: str = Field(..., description="Semantic query (embeddings).")
    k: int = Field(default=5, ge=1, le=20)
    tags_any: List[str] = Field(default_factory=list)
    min_importance: int = Field(default=0, ge=0, le=5)
    nodes_any: List[str] = Field(default_factory=list)
    vector_direction: Optional[str] = None
    form: Optional[str] = "fact"

def _write_fact_md(req: FactCommitReq, ts: str) -> (str, str):
    fact_id = f"{ts.replace(':','').replace('-','')}-{uuid.uuid4().hex[:8]}"
    slug = _safe_slug(req.fact[:50])
    rel_dir = _ym_path(ts)
    rel_path = os.path.join(rel_dir, f"{fact_id}-{slug}.md")
    abs_dir = os.path.join(FACTS_DIR, rel_dir)
    abs_path = os.path.join(FACTS_DIR, rel_path)
    os.makedirs(abs_dir, exist_ok=True)

    front = {
        "fact_id": fact_id,
        "timestamp": ts,
        "user_id": req.user_id,
        "tags": req.tags,
        "importance": req.importance,
        "nodes": req.nodes,
        "vector_direction": req.vector_direction or "",
        "form": "fact",
        "source_scene_id": req.source_scene_id or "",
    }

    fm = ["---"]
    for k, v in front.items():
        if isinstance(v, list):
            fm.append(f"{k}: [{', '.join([str(x) for x in v])}]")
        else:
            fm.append(f"{k}: {v}")
    fm += ["---", ""]
    body = "\n".join(fm) + req.fact.strip() + "\n"

    with open(abs_path, "w", encoding="utf-8") as f:
        f.write(body)

    return fact_id, abs_path

@router.get("/health")
def facts_health():
    return {"ok": True, "collection": FACTS_COLLECTION, "dir": FACTS_DIR, "qdrant": QDRANT_URL}

@router.post("/commit", response_model=FactCommitResp)
async def facts_commit(req: FactCommitReq):
    if not req.fact or len(req.fact.strip()) < 4:
        raise HTTPException(status_code=400, detail="fact too short")

    ts = _utc_ts()
    fact_id, abs_path = _write_fact_md(req, ts)

    payload: Dict[str, Any] = {
        "type": "fact",
        "fact_id": fact_id,
        "timestamp": ts,
        "user_id": req.user_id,
        "tags": req.tags,
        "importance": req.importance,
        "nodes": req.nodes,
        "vector_direction": req.vector_direction,
        "form": "fact",
        "source_scene_id": req.source_scene_id,
        "git_path": abs_path,
        "git_path_host": _to_host_path(abs_path),
        "git_path_container": abs_path,
        "text": req.fact.strip(),
    }

    _ensure_collection()
    qc = _qdrant()
    vec = await embed_text(req.fact.strip())
    point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, fact_id))
    qc.upsert(
        collection_name=FACTS_COLLECTION,
        points=[rest.PointStruct(id=point_id, vector=vec, payload=payload)],
    )

    _git_commit(abs_path, f"fact: {fact_id}")

    return FactCommitResp(fact_id=fact_id, git_path=_to_host_path(abs_path), timestamp=ts)

@router.post("/recall")
async def facts_recall(req: FactRecallReq):
    _ensure_collection()
    qc = _qdrant()

    q = (req.query or "").strip()
    if not q:
        return {"hits": []}

    must = []
    if req.form:
        must.append(rest.FieldCondition(key="form", match=rest.MatchValue(value=req.form)))
    if req.vector_direction:
        must.append(rest.FieldCondition(key="vector_direction", match=rest.MatchValue(value=req.vector_direction)))
    if req.tags_any:
        must.append(rest.FieldCondition(key="tags", match=rest.MatchAny(any=req.tags_any)))
    if req.nodes_any:
        must.append(rest.FieldCondition(key="nodes", match=rest.MatchAny(any=req.nodes_any)))
    if req.min_importance > 0:
        must.append(rest.FieldCondition(key="importance", range=rest.Range(gte=req.min_importance)))

    flt = rest.Filter(must=must) if must else None

    vec = await embed_text(q)
    # try native client search; fallback to HTTP if client lacks .search()
    try:
        res = qc.search(
            collection_name=FACTS_COLLECTION,
            query_vector=vec,
            query_filter=flt,
            limit=req.k,
            with_payload=True,
            with_vectors=False,
        )
        native = True
    except AttributeError:
        native = False
        # build qdrant REST filter dict
        flt_dict = None
        if flt is not None:
            # qdrant REST filter expects {"must":[...]}
            flt_dict = {"must": []}
            for cond in must:
                # cond is rest.FieldCondition; serialize minimally
                d = cond.dict()
                flt_dict["must"].append(d)
        res = _qdrant_search_http(FACTS_COLLECTION, vec, req.k, flt_dict)

    hits = []
    for r in res:
        pl = (r.payload if native else (r.get('payload') or {})) or {}
        hits.append({
            "fact_id": pl.get("fact_id"),
            "git_path": (pl.get("git_path_host") or pl.get("git_path")),
            "timestamp": pl.get("timestamp"),
            "tags": pl.get("tags", []),
            "importance": pl.get("importance", 0),
            "nodes": pl.get("nodes", []),
            "vector_direction": pl.get("vector_direction"),
            "fact": (pl.get("text") or "")[:500],
            "score": float(getattr(r, "score", 0.0) if native else (r.get('score') or 0.0)),
        })
    return {"hits": hits}