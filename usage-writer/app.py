from fastapi import FastAPI, Request
from datetime import datetime, timezone
import sqlite3, time, json, os

DB = os.environ.get("USAGE_DB", "/ontogit_user/usage.db")
app = FastAPI()

def init_db():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    con = sqlite3.connect(DB)
    cur = con.cursor()
    cur.execute("""
    CREATE TABLE IF NOT EXISTS usage_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts INTEGER NOT NULL,
      user_id TEXT,
      chat_id TEXT,
      model TEXT,
      prompt_tokens INTEGER,
      completion_tokens INTEGER,
      total_tokens INTEGER,
      cost_usd REAL,
      raw_json TEXT
    )
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS idx_usage_events_ts ON usage_events(ts)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_usage_events_user ON usage_events(user_id)")
    con.commit()
    con.close()

@app.on_event("startup")
def _startup():
    init_db()

@app.post("/usage")
async def usage(req: Request):
    body = await req.json()
    ts = int(body.get("ts") or time.time())
    user_id = body.get("user_id")
    chat_id = body.get("chat_id")
    model = body.get("model")
    pt = int(body.get("prompt_tokens") or 0)
    ct = int(body.get("completion_tokens") or 0)
    tt = int(body.get("total_tokens") or (pt + ct))
    cost = body.get("cost_usd")
    raw = json.dumps(body, ensure_ascii=False)

    con = sqlite3.connect(DB)
    cur = con.cursor()
    cur.execute("""
      INSERT INTO usage_events(ts,user_id,chat_id,model,prompt_tokens,completion_tokens,total_tokens,cost_usd,raw_json)
      VALUES(?,?,?,?,?,?,?,?,?)
    """, (ts, user_id, chat_id, model, pt, ct, tt, cost, raw))
    con.commit()
    con.close()
    return {"ok": True}


@app.get("/sum_usd")
async def sum_usd(user_id: str = "", from_ts: int | None = None, to_ts: int | None = None):
    if not user_id:
        return {"user_id": user_id, "sum_usd": 0.0, "from_ts": from_ts, "to_ts": to_ts}

    if from_ts is None:
        now = datetime.now(timezone.utc)
        from_ts = int(datetime(now.year, now.month, 1, tzinfo=timezone.utc).timestamp())
    if to_ts is None:
        to_ts = int(time.time())

    con = sqlite3.connect(DB)
    cur = con.cursor()
    cur.execute(
        """
        SELECT COALESCE(SUM(cost_usd), 0)
        FROM usage_events
        WHERE user_id = ? AND ts >= ? AND ts <= ?
        """,
        (user_id, from_ts, to_ts),
    )
    row = cur.fetchone()
    con.close()

    total = float(row[0] or 0.0)
    return {"user_id": user_id, "sum_usd": total, "from_ts": int(from_ts), "to_ts": int(to_ts)}
