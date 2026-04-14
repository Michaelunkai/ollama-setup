"""Pydantic models for oll90 backend API"""
from pydantic import BaseModel, Field
from typing import Optional
from datetime import datetime


class SessionCreate(BaseModel):
    name: Optional[str] = None
    system_prompt: Optional[str] = None


class SessionInfo(BaseModel):
    id: str
    name: str
    created_at: str
    updated_at: str
    message_count: int = 0
    estimated_tokens: int = 0


class MessageRecord(BaseModel):
    id: int
    session_id: str
    role: str
    content: str
    tool_calls_json: Optional[str] = None
    created_at: str


class ToolExecuteRequest(BaseModel):
    tool: str
    args: dict = Field(default_factory=dict)


class ToolResult(BaseModel):
    output: str = ""
    stderr: str = ""
    success: bool = True
    hint: Optional[str] = None
    duration_ms: int = 0
    blocked: bool = False


class StatusResponse(BaseModel):
    ollama_running: bool = False
    model_loaded: bool = False
    model_name: str = ""
    vram_used_mb: float = 0
    vram_total_mb: float = 0
    gpu_name: str = ""
    gpu_util_percent: float = 0
    gpu_temp_c: float = 0
    context_size: int = 0


class WSClientMessage(BaseModel):
    type: str  # "message", "cancel", "slash_command"
    content: Optional[str] = None
    command: Optional[str] = None
    session_id: Optional[str] = None
