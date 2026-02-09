# ONTOS_PREFS_V1 (ENGINEERING ONLY)
# Separate prefs DB. No Qdrant. No OntoGit facts/scenes.
from __future__ import annotations

import os
import sqlite3
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

router = APIRouter(prefix="/prefs", tags=["prefs"])

PREFS_DB_PATH = os.getenv("PREFS_DB_PATH", "/ontogit_user/prefs.db")
DEFAULT_VOICE = os.getenv("PREFS_TTS_DEFAULT_VOICE", "alloy")
VOICES_OPENAI = ["alloy","ash","ballad","coral","echo","fable","nova","onyx","sage","shimmer","verse","marin","cedar"]

def _now() -> str:
    return datetime.utcnow().replace(microsecond=0).isoformat() + "Z"

def _db():
    os.makedirs(os.path.dirname(PREFS_DB_PATH), exist_ok=True)
    con = sqlite3.connect(PREFS_DB_PATH)
    con.execute("""
      CREATE TABLE IF NOT EXISTS user_prefs (
        user_id TEXT PRIMARY KEY,
        tts_voice TEXT,
        updated_at TEXT
      )
    """)
    return con

def _uid(x: Optional[str]) -> str:
    uid=(x or "").strip()
    if not uid:
        raise HTTPException(status_code=400, detail="Missing X-User-Id header")
    return uid

class VoiceSetReq(BaseModel):
    voice: str = Field(...)

@router.get("/voices")
def voices():
    return {"provider":"openai","voices":[{"id":v,"label":v} for v in VOICES_OPENAI],"default":DEFAULT_VOICE}

@router.get("/voice")
def get_voice(x_user_id: Optional[str] = Header(default=None, alias="X-User-Id")):
    uid=_uid(x_user_id)
    con=_db(); cur=con.cursor()
    row=cur.execute("SELECT tts_voice,updated_at FROM user_prefs WHERE user_id=?", (uid,)).fetchone()
    con.close()
    if not row or not row[0]:
        return {"user_id":uid,"voice":DEFAULT_VOICE,"default":True,"updated_at":None}
    return {"user_id":uid,"voice":row[0],"default":False,"updated_at":row[1]}

@router.post("/voice")
def set_voice(req: VoiceSetReq, x_user_id: Optional[str] = Header(default=None, alias="X-User-Id")):
    uid=_uid(x_user_id)
    v=(req.voice or "").strip().lower()
    if v not in VOICES_OPENAI:
        raise HTTPException(status_code=400, detail=f"Unsupported voice: {v}")
    con=_db(); cur=con.cursor()
    cur.execute(
        "INSERT INTO user_prefs(user_id,tts_voice,updated_at) VALUES (?,?,?) "
        "ON CONFLICT(user_id) DO UPDATE SET tts_voice=excluded.tts_voice, updated_at=excluded.updated_at",
        (uid, v, _now())
    )
    con.commit(); con.close()
    return {"ok":True,"user_id":uid,"voice":v}
