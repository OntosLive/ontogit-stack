# ONTOS_FACTS_V1
from __future__ import annotations

import os
import uuid
from datetime import datetime
from typing import List, Optional, Dict, Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

# We reuse the existing qdrant + git conventions:
# - git is source of truth (facts saved as md)
# - qdrant is index (payload for filtering; embeddings later)
#
# Manual-only: this router exposes /facts/commit and /facts/recall but does NOT auto-trigger anything.

router = APIRouter(prefix="/facts", tags=["facts"])

FACTS_DIR = os.environ.get("ONTOGIT_FACTS_DIR", "/root/ontogit/facts")
FACTS_COLLECTION = os.environ.get("ONTOGIT_FACTS_COLLECTION", "ontogit_facts")

def _utc_ts() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"

def _ym_path(ts_iso: str) -> str:
    # ts like 2026-02-08T20:22:44Z -> 2026/02
    y = ts_iso[0:4]
    m = ts_iso[5:7]
    return os.path.join(y, m)

def _safe_slug(s: str) -> str:
    s = (s or "").strip().lower()
    s = "".join(ch if ch.isalnum() or ch in "-_." else "-" for ch in s)
    s = "-".join([p for p in s.split("-") if p])
    return s[:60] or "fact"

class FactCommitReq(BaseModel):
    fact: str = Field(..., description="Small stable assertion (1-2 sentences).")
    tags: List[str] = Field(default_factory=list)
    importance: int = Field(default=3, ge=0, le=5)
    nodes: List[str] = Field(default_factory=list)
    vector_direction: Optional[str] = Field(default=None, description="forward|reverse (optional)")
    form: str = Field(default="fact", description="always 'fact' for L3")
    user_id: str = Field(default="default")
    source_scene_id: Optional[str] = Field(default=None, description="Optional: link to a scene_id that produced this fact")

class FactCommitResp(BaseModel):
    fact_id: str
    git_path: str
    timestamp: str

class FactRecallReq(BaseModel):
    query: str = Field(..., description="Search query (payload-only for now; embeddings later).")
    k: int = Field(default=5, ge=1, le=20)
    tags_any: List[str] = Field(default_factory=list)
    min_importance: int = Field(default=0, ge=0, le=5)
    nodes_any: List[str] = Field(default_factory=list)
    vector_direction: Optional[str] = None
    form: Optional[str] = "fact"

# --- integration helpers ---
def _get_main_module_refs():
    """
    Import from the existing app modules without creating hard coupling.
    We expect memory-service/app/main.py to have:
      - qdrant_client (or a getter)
      - ensure_collection-like helper may exist; if not, we do best-effort upsert.
      - git commit helper may exist; if not, we just write file and rely on repo being mounted.
    """
    try:
        from . import main as main_mod  # type: ignore
        return main_mod
    except Exception:
        return None

def _qdrant_upsert(point_id: str, payload: Dict[str, Any]) -> None:
    main_mod = _get_main_module_refs()
    if not main_mod:
        return
    qc = getattr(main_mod, "qdrant_client", None)
    if qc is None:
        # some implementations store client on app.state
        app = getattr(main_mod, "app", None)
        qc = getattr(getattr(app, "state", object()), "qdrant", None)
    if qc is None:
        return
    # Best-effort: use Qdrant client if present.
    try:
        # Lazy import to avoid hard dependency on qdrant-client types here
        from qdrant_client.http import models as rest
        qc.upsert(
            collection_name=FACTS_COLLECTION,
            points=[rest.PointStruct(id=point_id, payload=payload, vector=None)],
        )
    except Exception:
        # If collection not present or vector required, ignore (we still have git as truth).
        return

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

    fm_lines = ["---"]
    for k,v in front.items():
        if isinstance(v, list):
            fm_lines.append(f"{k}: [{', '.join([str(x) for x in v])}]")
        else:
            fm_lines.append(f"{k}: {v}")
    fm_lines += ["---", ""]
    body = "\n".join(fm_lines) + req.fact.strip() + "\n"

    with open(abs_path, "w", encoding="utf-8") as f:
        f.write(body)

    return fact_id, abs_path

def _git_commit(file_path: str, msg: str) -> None:
    main_mod = _get_main_module_refs()
    if not main_mod:
        return
    commit_fn = getattr(main_mod, "git_commit_file", None)
    if callable(commit_fn):
        try:
            commit_fn(file_path, msg)
            return
        except Exception:
            pass
    # fallback: try shelling out if repo mounted and git exists
    try:
        import subprocess
        repo = os.environ.get("ONTOGIT_REPO", "/root/ontogit")
        subprocess.run(["git", "-C", repo, "add", file_path], check=False)
        subprocess.run(["git", "-C", repo, "commit", "-m", msg], check=False)
    except Exception:
        return

@router.get("/health")
def facts_health():
    return {"ok": True, "collection": FACTS_COLLECTION, "dir": FACTS_DIR}

@router.post("/commit", response_model=FactCommitResp)
def facts_commit(req: FactCommitReq):
    if not req.fact or len(req.fact.strip()) < 4:
        raise HTTPException(status_code=400, detail="fact is too short")
    ts = _utc_ts()
    fact_id, abs_path = _write_fact_md(req, ts)

    payload = {
        "fact_id": fact_id,
        "timestamp": ts,
        "user_id": req.user_id,
        "tags": req.tags,
        "importance": req.importance,
        "nodes": req.nodes,
        "vector_direction": req.vector_direction,
        "form": "fact",
        "source_scene_id": req.source_scene_id,
        "text": req.fact.strip(),
        "type": "fact",
    }

    # upsert best-effort (git is truth)
    _qdrant_upsert(point_id=str(uuid.uuid5(uuid.NAMESPACE_URL, fact_id)), payload=payload)

    # git commit best-effort
    _git_commit(abs_path, f"fact: {fact_id}")

    return FactCommitResp(fact_id=fact_id, git_path=abs_path, timestamp=ts)

@router.post("/recall")
def facts_recall(req: FactRecallReq):
    # MVP: payload filtering only (no embeddings). We'll return the latest facts matching simple contains,
    # relying on git as source of truth. Later: qdrant+embeddings hybrid.
    # To keep it safe and deterministic: scan last N files on disk.
    base = FACTS_DIR
    if not os.path.isdir(base):
        return {"hits": []}

    # gather recent files
    files = []
    for root, _, names in os.walk(base):
        for n in names:
            if n.endswith(".md"):
                files.append(os.path.join(root, n))
    files.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    files = files[:500]

    q = (req.query or "").lower().strip()
    hits = []
    for fp in files:
        try:
            txt = open(fp, "r", encoding="utf-8").read()
        except Exception:
            continue
        if q and q not in txt.lower():
            continue
        # cheap filters
        if req.form and "form: fact" not in txt:
            continue
        if req.tags_any:
            ok = False
            for t in req.tags_any:
                if t and t in txt:
                    ok = True
                    break
            if not ok:
                continue
        # importance filter (best-effort)
        if req.min_importance > 0:
            m = re.search(r"importance:\s*([0-5])", txt)
            if m and int(m.group(1)) < req.min_importance:
                continue

        # extract fact line (content after frontmatter)
        parts = txt.split("---", 2)
        fact = txt
        if len(parts) >= 3:
            fact = parts[2].strip()

        hits.append({"git_path": fp, "fact": fact[:500], "score": 1.0})
        if len(hits) >= req.k:
            break

    return {"hits": hits}
