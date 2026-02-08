import os
import uuid
import httpx
from typing import Any, List

# читаем строго из env (compose уже задаёт QDRANT_URL, QDRANT_COLLECTION, EMBED_*)
EMBED_BASE_URL = os.getenv("EMBED_BASE_URL", "https://api.openai.com/v1").rstrip("/")
EMBED_API_KEY = os.getenv("EMBED_API_KEY", "")
EMBED_MODEL = os.getenv("EMBED_MODEL", "text-embedding-3-small")

QDRANT_URL = os.getenv("QDRANT_URL", "http://host.docker.internal:6333").rstrip("/")
QDRANT_COLLECTION = os.getenv("QDRANT_COLLECTION", "ontogit_scenes")

# deterministic point id for qdrant (uuid5)
_QDRANT_NS = uuid.UUID("00000000-0000-0000-0000-000000000001")
def point_uuid(scene_id: str) -> str:
    return str(uuid.uuid5(_QDRANT_NS, scene_id))


async def embed_text(text: str) -> List[float]:
    if not EMBED_API_KEY:
        raise RuntimeError("EMBED_API_KEY is not set")
    payload = {"model": EMBED_MODEL, "input": text}
    headers = {"Authorization": f"Bearer {EMBED_API_KEY}", "Content-Type": "application/json"}
    async with httpx.AsyncClient(timeout=30.0) as client:
        r = await client.post(f"{EMBED_BASE_URL}/embeddings", headers=headers, json=payload)
        r.raise_for_status()
        data = r.json()
        return data["data"][0]["embedding"]

async def qdrant_ensure_collection(dim: int) -> None:
    async with httpx.AsyncClient(timeout=10.0) as client:
        r = await client.get(f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}")
        if r.status_code == 200:
            return
        body = {"vectors": {"size": dim, "distance": "Cosine"}}
        rc = await client.put(f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}", json=body)
        rc.raise_for_status()

async def qdrant_upsert(scene_id: str, vector: List[float], payload: dict) -> None:
    body = {"points": [{"id": point_uuid(scene_id), "vector": vector, "payload": payload}]}
    async with httpx.AsyncClient(timeout=15.0) as client:
        r = await client.put(f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points?wait=true", json=body)
        r.raise_for_status()

async def qdrant_search(vector: List[float], k: int, qfilter: dict | None = None) -> list[dict]:
    body = {"vector": vector, "limit": int(k), "with_payload": True}
    if qfilter:
        body["filter"] = qfilter
    async with httpx.AsyncClient(timeout=15.0) as client:
        r = await client.post(f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points/search", json=body)
        r.raise_for_status()
        return r.json().get("result", [])

async def embed_and_upsert_scene(scene_id: str, title: str, git_path: str, user_id: str, tags: list, importance: int, body: str, quote: str = "", meta: dict | None = None) -> None:
    vec = await embed_text(body)
    await qdrant_ensure_collection(len(vec))
    payload = {
        "scene_id": scene_id,
        "title": title,
        "git_path": git_path,
        "path": git_path,
        "user_id": user_id,
        "tags": tags or [],
        "importance": int(importance),
        "quote": quote or "",
        "body_preview": (body.strip().replace("\n", " ")[:400]),
    }

    # ---- layered fields (from scene YAML meta) ----
    try:
        m = meta or {}
        # form
        if "form" in m:
            payload["form"] = m.get("form") or ""
        # vector direction/target
        v = m.get("vector")
        if isinstance(v, dict):
            payload["vector_direction"] = v.get("direction") or ""
            payload["vector_target"] = v.get("target") or ""
        elif isinstance(v, str):
            payload["vector_direction"] = v
        # structure_links nodes
        sl = m.get("structure_links")
        if isinstance(sl, dict):
            nodes = sl.get("nodes")
            if isinstance(nodes, list):
                payload["nodes"] = nodes
        # excitation level
        ex = m.get("excitation")
        if isinstance(ex, dict) and "level" in ex:
            payload["excitation_level"] = ex.get("level")
    except Exception:
        pass
    # ----------------------------------------------
    await qdrant_upsert(scene_id, vec, payload)

async def recall_hits(query: str, k: int, user_id: str = "default", tags_any: list[str] | None = None, min_importance: int = 0, nodes_any: list[str] | None = None, vector_direction: str = "", form: str = "") -> list[dict]:
    vec = await embed_text(query)
    qfilter = {"must": []}

    # user_id match (always)
    if user_id:
        qfilter["must"].append({"key": "user_id", "match": {"value": user_id}})

    # importance >= min_importance
    if int(min_importance) > 0:
        qfilter["must"].append({"key": "importance", "range": {"gte": int(min_importance)}})

    # nodes_any: match any node
    if nodes_any:
        should_nodes = [{"key": "nodes", "match": {"value": n}} for n in nodes_any if n]
        if should_nodes:
            qfilter.setdefault("should", []).extend(should_nodes)

    # vector_direction exact match
    if vector_direction:
        qfilter["must"].append({"key": "vector_direction", "match": {"value": vector_direction}})

    # form exact match
    if form:
        qfilter["must"].append({"key": "form", "match": {"value": form}})

    # tags_any: match any tag
    if tags_any:
        should = [{"key": "tags", "match": {"value": t}} for t in tags_any if t]
        if should:
            qfilter["should"] = should

    return await qdrant_search(vec, k, qfilter=qfilter if (qfilter.get("must") or qfilter.get("should")) else None)

