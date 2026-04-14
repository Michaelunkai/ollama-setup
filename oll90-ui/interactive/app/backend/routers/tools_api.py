"""REST endpoint for manual tool execution"""
from fastapi import APIRouter

from models import ToolExecuteRequest, ToolResult
from engine.tool_executor import execute_tool

router = APIRouter()


@router.post("/tools/execute")
async def execute_tool_endpoint(body: ToolExecuteRequest) -> ToolResult:
    return await execute_tool(body.tool, body.args)


@router.get("/tools")
async def list_tools():
    from config import TOOLS
    return [
        {
            "name": t["function"]["name"],
            "description": t["function"]["description"][:100] + "..."
        }
        for t in TOOLS
    ]
