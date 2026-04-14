"""SQLite session storage using stdlib sqlite3 + asyncio.to_thread"""
import sqlite3
import asyncio
import uuid
import json
import os
from datetime import datetime
from typing import Optional

from config import DB_PATH


class Database:
    def __init__(self, db_path: str = DB_PATH):
        self.db_path = db_path
        self._ensure_dir()

    def _ensure_dir(self):
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)

    def _get_conn(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        return conn

    def _init_tables(self):
        conn = self._get_conn()
        try:
            conn.executescript("""
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    system_prompt TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL DEFAULT '',
                    tool_calls_json TEXT,
                    created_at TEXT NOT NULL,
                    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id);
            """)
            conn.commit()
        finally:
            conn.close()

    async def init(self):
        await asyncio.to_thread(self._init_tables)

    def _create_session(self, name: Optional[str], system_prompt: Optional[str]) -> dict:
        sid = str(uuid.uuid4())
        now = datetime.utcnow().isoformat()
        name = name or f"Session {now[:16]}"
        conn = self._get_conn()
        try:
            conn.execute(
                "INSERT INTO sessions (id, name, system_prompt, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                (sid, name, system_prompt, now, now)
            )
            conn.commit()
            return {"id": sid, "name": name, "created_at": now, "updated_at": now, "message_count": 0, "estimated_tokens": 0}
        finally:
            conn.close()

    async def create_session(self, name: Optional[str] = None, system_prompt: Optional[str] = None) -> dict:
        return await asyncio.to_thread(self._create_session, name, system_prompt)

    def _list_sessions(self) -> list:
        conn = self._get_conn()
        try:
            rows = conn.execute("""
                SELECT s.id, s.name, s.created_at, s.updated_at,
                       COUNT(m.id) as message_count,
                       COALESCE(SUM(LENGTH(m.content)), 0) as total_chars
                FROM sessions s
                LEFT JOIN messages m ON m.session_id = s.id
                GROUP BY s.id
                ORDER BY s.updated_at DESC
            """).fetchall()
            return [
                {
                    "id": r["id"], "name": r["name"],
                    "created_at": r["created_at"], "updated_at": r["updated_at"],
                    "message_count": r["message_count"],
                    "estimated_tokens": r["total_chars"] // 4
                }
                for r in rows
            ]
        finally:
            conn.close()

    async def list_sessions(self) -> list:
        return await asyncio.to_thread(self._list_sessions)

    def _get_messages(self, session_id: str) -> list:
        conn = self._get_conn()
        try:
            rows = conn.execute(
                "SELECT id, session_id, role, content, tool_calls_json, created_at FROM messages WHERE session_id = ? ORDER BY id",
                (session_id,)
            ).fetchall()
            return [dict(r) for r in rows]
        finally:
            conn.close()

    async def get_messages(self, session_id: str) -> list:
        return await asyncio.to_thread(self._get_messages, session_id)

    def _get_session(self, session_id: str) -> Optional[dict]:
        conn = self._get_conn()
        try:
            row = conn.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
            return dict(row) if row else None
        finally:
            conn.close()

    async def get_session(self, session_id: str) -> Optional[dict]:
        return await asyncio.to_thread(self._get_session, session_id)

    def _append_message(self, session_id: str, role: str, content: str, tool_calls: list = None):
        conn = self._get_conn()
        try:
            now = datetime.utcnow().isoformat()
            tc_json = json.dumps(tool_calls) if tool_calls else None
            conn.execute(
                "INSERT INTO messages (session_id, role, content, tool_calls_json, created_at) VALUES (?, ?, ?, ?, ?)",
                (session_id, role, content, tc_json, now)
            )
            conn.execute("UPDATE sessions SET updated_at = ? WHERE id = ?", (now, session_id))
            conn.commit()
        finally:
            conn.close()

    async def append_message(self, session_id: str, role: str, content: str, tool_calls: list = None):
        await asyncio.to_thread(self._append_message, session_id, role, content, tool_calls)

    def _delete_session(self, session_id: str):
        conn = self._get_conn()
        try:
            conn.execute("DELETE FROM messages WHERE session_id = ?", (session_id,))
            conn.execute("DELETE FROM sessions WHERE id = ?", (session_id,))
            conn.commit()
        finally:
            conn.close()

    async def delete_session(self, session_id: str):
        await asyncio.to_thread(self._delete_session, session_id)

    def _rename_session(self, session_id: str, name: str):
        conn = self._get_conn()
        try:
            now = datetime.utcnow().isoformat()
            conn.execute("UPDATE sessions SET name = ?, updated_at = ? WHERE id = ?", (name, now, session_id))
            conn.commit()
        finally:
            conn.close()

    async def rename_session(self, session_id: str, name: str):
        await asyncio.to_thread(self._rename_session, session_id, name)

    def _clear_messages(self, session_id: str):
        conn = self._get_conn()
        try:
            now = datetime.utcnow().isoformat()
            conn.execute("DELETE FROM messages WHERE session_id = ?", (session_id,))
            conn.execute("UPDATE sessions SET updated_at = ? WHERE id = ?", (now, session_id))
            conn.commit()
        finally:
            conn.close()

    async def clear_messages(self, session_id: str):
        await asyncio.to_thread(self._clear_messages, session_id)


db = Database()
