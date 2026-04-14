"""REST endpoints for session management"""
from fastapi import APIRouter, HTTPException

from db import db
from models import SessionCreate

router = APIRouter()


@router.get("/sessions")
async def list_sessions():
    return await db.list_sessions()


@router.post("/sessions")
async def create_session(body: SessionCreate = None):
    if body is None:
        body = SessionCreate()
    return await db.create_session(body.name, body.system_prompt)


@router.get("/sessions/{session_id}")
async def get_session(session_id: str):
    session = await db.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    return session


@router.get("/sessions/{session_id}/messages")
async def get_messages(session_id: str):
    session = await db.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    return await db.get_messages(session_id)


@router.delete("/sessions/{session_id}")
async def delete_session(session_id: str):
    await db.delete_session(session_id)
    return {"status": "deleted"}


@router.post("/sessions/{session_id}/clear")
async def clear_session_messages(session_id: str):
    session = await db.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    await db.clear_messages(session_id)
    return {"status": "cleared"}


@router.get("/sessions/{session_id}/export")
async def export_session(session_id: str, format: str = "markdown"):
    session = await db.get_session(session_id)
    if not session:
        raise HTTPException(status_code=404, detail="Session not found")
    messages = await db.get_messages(session_id)

    if format == "json":
        return {
            "session": session,
            "messages": messages,
        }

    # Markdown format
    lines = [f"# {session['name']}", f"*Created: {session['created_at']}*", ""]
    for m in messages:
        role = m["role"].upper()
        content = m["content"]
        if role == "TOOL":
            lines.append(f"**[TOOL]**\n```\n{content[:2000]}\n```\n")
        elif role == "SYSTEM":
            lines.append(f"*[SYSTEM] {content[:500]}*\n")
        elif role == "USER":
            lines.append(f"**USER:** {content}\n")
        elif role == "ASSISTANT":
            lines.append(f"**AGENT:** {content}\n")
    return {"markdown": "\n".join(lines)}


@router.patch("/sessions/{session_id}")
async def rename_session(session_id: str, body: dict):
    name = body.get("name")
    if not name:
        raise HTTPException(status_code=400, detail="name required")
    await db.rename_session(session_id, name)
    return {"status": "renamed"}
