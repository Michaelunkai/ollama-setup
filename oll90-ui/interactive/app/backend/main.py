"""oll90 Backend - FastAPI app entry point"""
import os
import sys

# Ensure backend directory is on Python path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
import uvicorn

from config import PORT, HOST, OLLAMA_MODEL
from db import db
from routers import sessions, status, tools_api, ws

app = FastAPI(title="oll90 Backend", version="3.0.0")

# CORS for frontend dev server
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(sessions.router, prefix="/api", tags=["sessions"])
app.include_router(status.router, prefix="/api", tags=["status"])
app.include_router(tools_api.router, prefix="/api", tags=["tools"])
app.include_router(ws.router, tags=["websocket"])


@app.on_event("startup")
async def startup():
    await db.init()
    print(f"[oll90] Database initialized at {db.db_path}")
    print(f"[oll90] Backend running on http://{HOST}:{PORT}")


@app.get("/")
async def root():
    from engine.tool_executor import TOOL_MAP
    return {"name": "oll90", "version": "3.0.0", "model": OLLAMA_MODEL, "tools": len(TOOL_MAP), "status": "running"}


if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host=HOST,
        port=PORT,
        reload=False,
        log_level="info",
        ws_ping_interval=20,
        ws_ping_timeout=300,
        timeout_keep_alive=1200,
    )
