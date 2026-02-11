from fastapi import FastAPI, Request
from datetime import datetime, timezone
import sqlite3, time, json, os

DB = os.environ.get("USAGE_DB", "/ontogit_user/usage.db")
DEFAULT_ROLE = os.environ.get("DEFAULT_ROLE", "default")
DEFAULT_LIMIT_USD = float(os.environ.get("DEFAULT_LIMIT_USD", "15"))
DEFAULT_WARN_70 = float(os.environ.get("DEFAULT_WARN_70", "0.7"))
DEFAULT_WARN_90 = float(os.environ.get("DEFAULT_WARN_90", "0.9"))
ROLE_LOW_LIMIT_USD = float(os.environ.get("ROLE_LOW_LIMIT_USD", "5"))
ROLE_HIGH_LIMIT_USD = float(os.environ.get("ROLE_HIGH_LIMIT_USD", "50"))
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
    cur.execute("""
    CREATE TABLE IF NOT EXISTS roles (
      name TEXT PRIMARY KEY,
      limit_usd REAL NOT NULL,
      warn_70 REAL NOT NULL,
      warn_90 REAL NOT NULL
    )
    """)
    cur.execute("""
    CREATE TABLE IF NOT EXISTS users (
      user_id TEXT PRIMARY KEY,
      role TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 1,
      FOREIGN KEY(role) REFERENCES roles(name)
    )
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS idx_usage_events_ts ON usage_events(ts)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_usage_events_user ON usage_events(user_id)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_users_role ON users(role)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_users_active ON users(active)")

    cur.execute("""
      INSERT OR IGNORE INTO roles(name,limit_usd,warn_70,warn_90)
      VALUES(?,?,?,?)
    """, (DEFAULT_ROLE, DEFAULT_LIMIT_USD, DEFAULT_WARN_70, DEFAULT_WARN_90))
    cur.execute("""
      INSERT OR IGNORE INTO roles(name,limit_usd,warn_70,warn_90)
      VALUES(?,?,?,?)
    """, ("low", ROLE_LOW_LIMIT_USD, DEFAULT_WARN_70, DEFAULT_WARN_90))
    cur.execute("""
      INSERT OR IGNORE INTO roles(name,limit_usd,warn_70,warn_90)
      VALUES(?,?,?,?)
    """, ("high", ROLE_HIGH_LIMIT_USD, DEFAULT_WARN_70, DEFAULT_WARN_90))
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


def _month_start_ts() -> int:
    now = datetime.now(timezone.utc)
    return int(datetime(now.year, now.month, 1, tzinfo=timezone.utc).timestamp())


def _get_used(con: sqlite3.Connection, user_id: str) -> float:
    cur = con.cursor()
    cur.execute(
        """
        SELECT COALESCE(SUM(cost_usd), 0)
        FROM usage_events
        WHERE user_id = ? AND ts >= ?
        """,
        (user_id, _month_start_ts()),
    )
    row = cur.fetchone()
    return float(row[0] or 0.0)


def _ensure_user(con: sqlite3.Connection, user_id: str) -> tuple[str, int]:
    cur = con.cursor()
    cur.execute("SELECT role, active FROM users WHERE user_id = ?", (user_id,))
    row = cur.fetchone()
    if row:
        return row[0], int(row[1])
    cur.execute("INSERT INTO users(user_id, role, active) VALUES(?,?,1)", (user_id, DEFAULT_ROLE))
    con.commit()
    return DEFAULT_ROLE, 1


def _get_role(con: sqlite3.Connection, role: str) -> tuple[float, float, float]:
    cur = con.cursor()
    cur.execute("SELECT limit_usd, warn_70, warn_90 FROM roles WHERE name = ?", (role,))
    row = cur.fetchone()
    if row:
        return float(row[0]), float(row[1]), float(row[2])
    cur.execute(
        "INSERT OR IGNORE INTO roles(name,limit_usd,warn_70,warn_90) VALUES(?,?,?,?)",
        (role, DEFAULT_LIMIT_USD, DEFAULT_WARN_70, DEFAULT_WARN_90),
    )
    con.commit()
    return DEFAULT_LIMIT_USD, DEFAULT_WARN_70, DEFAULT_WARN_90


@app.get("/used/{user_id}")
async def used(user_id: str):
    con = sqlite3.connect(DB)
    total = _get_used(con, user_id)
    con.close()
    return {"user_id": user_id, "used_usd": total}


@app.get("/limits/{user_id}")
async def limits(user_id: str):
    con = sqlite3.connect(DB)
    role, active = _ensure_user(con, user_id)
    limit_usd, warn_70, warn_90 = _get_role(con, role)
    con.close()
    return {
        "user_id": user_id,
        "role": role,
        "active": bool(active),
        "limit_usd": limit_usd,
        "warn_70": warn_70,
        "warn_90": warn_90,
    }


@app.put("/users/{user_id}")
async def put_user(user_id: str, req: Request):
    body = await req.json()
    role = body.get("role") or DEFAULT_ROLE
    active = 1 if int(body.get("active", 1)) else 0

    con = sqlite3.connect(DB)
    _get_role(con, role)
    cur = con.cursor()
    cur.execute(
        """
        INSERT INTO users(user_id, role, active)
        VALUES(?,?,?)
        ON CONFLICT(user_id) DO UPDATE SET role=excluded.role, active=excluded.active
        """,
        (user_id, role, active),
    )
    con.commit()
    con.close()
    return {"user_id": user_id, "role": role, "active": bool(active)}
