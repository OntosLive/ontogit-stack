from fastapi import FastAPI, Request
from datetime import datetime, timezone, timedelta
import sqlite3, time, json, os
import urllib.request, urllib.error
from common.policy import load_policy, get_user_role, get_monthly_limits

DB = os.environ.get("USAGE_DB", "/ontogit_user/usage.db")
POLICY_PATH = os.environ.get("POLICY_PATH", "/ontogit_user/onto_policy.yml")
ROLE_SOURCE = (os.environ.get("ROLE_SOURCE", "") or "").strip().lower()
OPENWEBUI_BASE_URL = os.environ.get("OPENWEBUI_BASE_URL", "http://open-webui:8080")
ONTOGIT_ROLE_ENDPOINT = os.environ.get("ONTOGIT_ROLE_ENDPOINT", "/api/v1/ontogit/user_role")
SERVICE_AUTH_SECRET = os.environ.get("ONTOS_SERVICE_AUTH_SECRET", "")
ROLE_CACHE_TTL = int(os.environ.get("ONTOGIT_ROLE_CACHE_TTL", "60") or 60)
DEFAULT_ROLE = os.environ.get("DEFAULT_ROLE", "default")
DEFAULT_LIMIT_USD = float(os.environ.get("DEFAULT_LIMIT_USD", "15"))
DEFAULT_WARN_70 = float(os.environ.get("DEFAULT_WARN_70", "0.7"))
DEFAULT_WARN_90 = float(os.environ.get("DEFAULT_WARN_90", "0.9"))
ROLE_LOW_LIMIT_USD = float(os.environ.get("ROLE_LOW_LIMIT_USD", "5"))
ROLE_HIGH_LIMIT_USD = float(os.environ.get("ROLE_HIGH_LIMIT_USD", "50"))
app = FastAPI()
ROLE_CACHE: dict[str, tuple[float, str]] = {}

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
    CREATE TABLE IF NOT EXISTS usage_telemetry_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts INTEGER NOT NULL,
      user_id TEXT,
      model TEXT,
      request_id TEXT,
      tokens_in INTEGER,
      tokens_out INTEGER,
      total_tokens INTEGER,
      http_status INTEGER,
      error_type TEXT,
      retry_count INTEGER,
      latency_ms INTEGER
    )
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS idx_telemetry_ts ON usage_telemetry_events(ts)")
    cur.execute("CREATE INDEX IF NOT EXISTS idx_telemetry_user ON usage_telemetry_events(user_id)")

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


def _usd_est_from_tokens(tokens_in: int | None, tokens_out: int | None) -> float:
    ti = int(tokens_in or 0)
    to = int(tokens_out or 0)
    return (ti / 1000.0) * 0.0025 + (to / 1000.0) * 0.01


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


@app.post("/telemetry")
async def telemetry(req: Request):
    body = await req.json()
    ts = int(body.get("ts") or time.time())
    con = sqlite3.connect(DB)
    cur = con.cursor()
    cur.execute(
        """
        INSERT INTO usage_telemetry_events(
          ts,user_id,model,request_id,tokens_in,tokens_out,total_tokens,http_status,error_type,
          retry_count,latency_ms
        )
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
        """,
        (
            ts,
            body.get("user_id"),
            body.get("model"),
            body.get("request_id"),
            body.get("tokens_in"),
            body.get("tokens_out"),
            body.get("total_tokens"),
            body.get("http_status"),
            body.get("error_type"),
            body.get("retry_count"),
            body.get("latency_ms"),
        ),
    )
    con.commit()
    con.close()
    return {"ok": True}


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


def _get_limits_for_user(con: sqlite3.Connection, user_id: str) -> tuple[str, int, float, float, float]:
    role, active = _ensure_user(con, user_id)
    policy = load_policy(POLICY_PATH)
    if not policy:
        limit_usd, warn_70, warn_90 = _get_role(con, role)
        return role, active, limit_usd, warn_70, warn_90

    role_from_source = _get_role_from_source(user_id)
    resolved_role = get_user_role(user_id, policy, assigned_role=(role_from_source or role))
    limit_usd, warn_70, warn_90 = get_monthly_limits(resolved_role, policy)
    return resolved_role, active, float(limit_usd or 0.0), float(warn_70), float(warn_90)


def _get_role_from_source(user_id: str) -> str | None:
    if ROLE_SOURCE != "openwebui":
        return None
    if not user_id or not SERVICE_AUTH_SECRET:
        return None

    now = time.time()
    cached = ROLE_CACHE.get(user_id)
    if cached and cached[0] > now:
        return cached[1]

    url = f"{OPENWEBUI_BASE_URL.rstrip('/')}/{ONTOGIT_ROLE_ENDPOINT.lstrip('/')}"
    req = urllib.request.Request(
        url,
        headers={
            "X-Ontos-Service-Auth": SERVICE_AUTH_SECRET,
            "X-OpenWebUI-User-Id": user_id,
        },
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=3.0) as resp:
            if getattr(resp, "status", 200) != 200:
                return None
            data = json.loads(resp.read().decode("utf-8"))
            role = str((data or {}).get("role") or "").strip()
            if not role:
                return None
            ROLE_CACHE[user_id] = (now + max(1, ROLE_CACHE_TTL), role)
            return role
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError):
        return None


@app.get("/used/{user_id}")
async def used(user_id: str):
    con = sqlite3.connect(DB)
    total = _get_used(con, user_id)
    con.close()
    return {"user_id": user_id, "used_usd": total}


@app.get("/limits/{user_id}")
async def limits(user_id: str):
    con = sqlite3.connect(DB)
    role, active, limit_usd, warn_70, warn_90 = _get_limits_for_user(con, user_id)
    con.close()
    return {
        "user_id": user_id,
        "role": role,
        "active": bool(active),
        "limit_usd": limit_usd,
        "warn_70": warn_70,
        "warn_90": warn_90,
    }


def _day_start_ts_days_ago(days_ago: int) -> int:
    now = datetime.now(timezone.utc)
    target = now - timedelta(days=days_ago)
    return int(datetime(target.year, target.month, target.day, tzinfo=timezone.utc).timestamp())


def _day_start_ts_from_ts(ts: int) -> int:
    dt = datetime.fromtimestamp(int(ts), timezone.utc)
    return int(datetime(dt.year, dt.month, dt.day, tzinfo=timezone.utc).timestamp())


@app.get("/report/daily")
async def report_daily(days: int = 7):
    days = max(1, min(90, int(days or 7)))
    start_ts = _day_start_ts_days_ago(days - 1)
    end_ts = int(time.time())

    con = sqlite3.connect(DB)
    cur = con.cursor()
    cur.execute(
        """
        SELECT ts,user_id,tokens_in,tokens_out,total_tokens,http_status,error_type
        FROM usage_telemetry_events
        WHERE ts >= ? AND ts <= ?
        """,
        (start_ts, end_ts),
    )
    rows = cur.fetchall()
    con.close()

    buckets: dict[int, dict[str, float | int | set]] = {}
    for ts, user_id, tin, tout, total, http_status, error_type in rows:
        day_ts = _day_start_ts_from_ts(ts)
        b = buckets.setdefault(
            day_ts,
            {"dau": set(), "requests": 0, "tokens": 0, "usd_est": 0.0, "errors": 0},
        )
        if user_id:
            b["dau"].add(user_id)
        b["requests"] += 1
        total_tokens = int(total or 0)
        if total_tokens <= 0:
            total_tokens = int((tin or 0) + (tout or 0))
        b["tokens"] += total_tokens
        b["usd_est"] += _usd_est_from_tokens(tin, tout)
        if (http_status and int(http_status) >= 400) or (error_type and str(error_type).strip()):
            b["errors"] += 1

    out = []
    for i in range(days):
        day_ts = _day_start_ts_days_ago(days - 1 - i)
        b = buckets.get(day_ts)
        if not b:
            out.append({"day_ts": day_ts, "dau": 0, "requests": 0, "tokens": 0, "usd_est": 0.0, "errors": 0})
            continue
        out.append(
            {
                "day_ts": day_ts,
                "dau": len(b["dau"]),
                "requests": int(b["requests"]),
                "tokens": int(b["tokens"]),
                "usd_est": float(b["usd_est"]),
                "errors": int(b["errors"]),
            }
        )
    return {"days": days, "items": out}


@app.get("/report/users")
async def report_users(days: int = 7, limit: int = 20):
    days = max(1, min(90, int(days or 7)))
    limit = max(1, min(200, int(limit or 20)))
    start_ts = _day_start_ts_days_ago(days - 1)
    end_ts = int(time.time())

    con = sqlite3.connect(DB)
    cur = con.cursor()
    cur.execute(
        """
        SELECT user_id,tokens_in,tokens_out,total_tokens,http_status,error_type
        FROM usage_telemetry_events
        WHERE ts >= ? AND ts <= ?
        """,
        (start_ts, end_ts),
    )
    rows = cur.fetchall()
    con.close()

    agg: dict[str, dict[str, float | int]] = {}
    for user_id, tin, tout, total, http_status, error_type in rows:
        if not user_id:
            continue
        u = agg.setdefault(user_id, {"requests": 0, "tokens": 0, "usd_est": 0.0, "errors": 0})
        u["requests"] += 1
        total_tokens = int(total or 0)
        if total_tokens <= 0:
            total_tokens = int((tin or 0) + (tout or 0))
        u["tokens"] += total_tokens
        u["usd_est"] += _usd_est_from_tokens(tin, tout)
        if (http_status and int(http_status) >= 400) or (error_type and str(error_type).strip()):
            u["errors"] += 1

    items = [
        {
            "user_id": uid,
            "requests": int(v["requests"]),
            "tokens": int(v["tokens"]),
            "usd_est": float(v["usd_est"]),
            "errors": int(v["errors"]),
        }
        for uid, v in agg.items()
    ]
    items.sort(key=lambda x: (x["usd_est"], x["tokens"]), reverse=True)
    return {"days": days, "items": items[:limit]}


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
