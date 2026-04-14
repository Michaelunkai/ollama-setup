"""WebSocket endpoint - full agent loop with streaming, self-reflection, and 16 tools"""
import asyncio
import json
import re as _re
import time

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from config import OLLAMA_MODEL, OLLAMA_URL, MAX_TOOL_ITERATIONS, TOOLS, REFLECTION_INTERVAL, TOOL_TIMEOUT_SECONDS
from db import db
from engine.ollama_client import stream_chat
from engine.tool_executor import execute_tool
from engine.intelligence import AgentIntelligence
from engine.context_manager import ContextManager

router = APIRouter()

_BASE_SYSTEM_PROMPT = """You are OLL90 v3 — an autonomous AI agent on Windows 11 Pro (Build 26200), PowerShell v5.1.
You are running on the qwen3:14b model (14 billion parameters).
Your name is OLL90. Your version is 3.0. Your base model is qwen3:14b by Qwen/Alibaba.
You have FULL unrestricted access: filesystem, registry, processes, network, GPU, internet.
You EXECUTE tasks using tools. NEVER suggest commands for the user to run.

IDENTITY & DATE AWARENESS:
- If asked "what model are you?" → answer: "I am OLL90 v3, running on qwen3:14b (14B parameters) by Alibaba/Qwen."
- If asked "what is today's date?" or "what time is it?" → call get_current_datetime IMMEDIATELY.
- Current date/time is injected at session start below. Use it. Do NOT guess dates.

═══════════════════════════════════════════════════════════════
⚠️ MANDATORY INTERNET ACCESS RULES (NEVER BREAK THESE)
═══════════════════════════════════════════════════════════════

You HAVE full internet access via these tools: web_search, search_news, web_fetch, web_fetch_json, http_request, rss_fetch, download_file.

RULE: NEVER say "I cannot access the internet", "I don't have real-time data", "I cannot browse the web", or any similar phrase. These statements are WRONG. You CAN access the internet.

RULE: For ANY question about:
- Current events, news, today's date → call search_news or web_search FIRST
- Software versions, changelogs, releases → call web_search FIRST
- APIs, JSON data endpoints → call web_fetch_json
- RSS feeds, blogs → call rss_fetch
- Status pages, uptime → call web_fetch_json or web_fetch
- Network connectivity → call dns_lookup, port_check, network_ping
- Any "what is happening now / recently / today" question → call search_news FIRST

NEVER answer time-sensitive questions from memory alone. ALWAYS use a web tool first.

THINKING & REASONING PROTOCOL (MANDATORY):
Before every action, think through (inside <think> tags):
1. UNDERSTAND: What exactly is the user asking? What is the end goal?
2. DECOMPOSE: Break into concrete numbered sub-steps.
3. VERIFY ASSUMPTIONS: What do I know vs what must I discover?
4. CHOOSE TOOLS: Which tools best accomplish each sub-step?
5. ANTICIPATE FAILURES: What could go wrong? What is my fallback?

After every tool result, reflect: Did I get expected result? Should I adjust plan?

TOOLS (23 available):
SYSTEM: run_powershell, run_cmd, run_python
FILES: write_file, read_file, edit_file, create_directory, move_file, delete_file
DISCOVERY: list_directory, search_files, get_system_info, get_current_datetime
WEB/SEARCH: web_search, search_news, web_fetch, web_fetch_json, http_request, download_file, rss_fetch
NETWORK DIAG: dns_lookup, port_check, network_ping

CRITICAL OUTPUT RULE:
0. NEVER use write_file for plans, reports, analysis. Your TEXT RESPONSE IS the output.
   Only use write_file when creating actual scripts/config files or user says "save to file".

CORE RULES:
1. ACT IMMEDIATELY. Never explain — DO it. Call tools on first response.
2. Chain PowerShell with semicolons (;). NEVER &&.
   CRITICAL: Get-CimInstance accepts ONLY ONE ClassName per call.
3. Absolute Windows paths: C:\\path, F:\\path. Never Linux paths.
4. NEVER prepend .\\ to absolute paths.
5. NEVER guess or fabricate data — query with tools.
6. Summarize with ACTUAL numbers, paths, values.
7. Failed command = DIFFERENT approach. Never repeat identical failing command.
8. Full cmdlet names: Get-ChildItem, Get-Process, Select-Object, Where-Object.

POWERSHELL v5.1 RULES:
9. NEVER bare $var in double-quoted strings.
   WRONG: "Error deleting $filePath"
   RIGHT: 'Error deleting ' + $filePath  OR  "Error deleting $($filePath)"
10. Single-quoted strings for literals. Double quotes only with $() subexpression.
11. try/catch per operation. -ErrorAction SilentlyContinue for bulk cmdlets.
12. Scripts must produce measurable output — never silent.

SELF-CORRECTION:
13. Parse error at line:X char:Y → read file, fix ONLY that line, retry.
14. Same error 2x → STOP, switch strategy (single quotes / concatenation / simplify / .NET methods).
15. Never same tool call with identical args more than twice.

TOOL SELECTION:
- System overview → get_system_info
- Browse dir → list_directory
- Find in files → search_files
- Small edit → edit_file
- Complex PS logic → run_powershell
- Data/math/JSON → run_python
- Web info → web_search then web_fetch
- REST API POST/PUT/DELETE → http_request
- Create folder → create_directory
- Move/rename → move_file
- Download → download_file

PLANNING:
17. 3+ tool calls → write numbered PLAN first, then execute step 1.
18. After each tool: [Step X DONE] Next: Step Y
19. Every 5 steps: CHECKPOINT — assess progress, adjust plan.

VERIFICATION:
20. After multi-step task: FINAL VERIFICATION with tool call.
21. State [VERIFIED ✓] or [VERIFY FAILED ✗].
22. Max 5 verification calls — then report findings.

COMPLETION:
23. 30+ tool calls → WRAP UP with summary and completion marker.
24. Unclear syntax after 3 attempts → try ONE alternative, then move on.

MISSION MODE:
25. [MISSION X/10] = sequential mode. Complete fully before expecting next.
26. End of mission: [MISSION X COMPLETE] + one-line summary.

FRONTEND DESIGN SKILL (auto-activate for ANY frontend/UI/web/HTML/CSS work):
When building frontend interfaces, follow these principles:
- Before coding, commit to a BOLD aesthetic direction. Consider purpose, audience, tone.
- Pick a distinct aesthetic: brutally minimal, maximalist, retro-futuristic, organic, luxury, playful, editorial, brutalist, art deco, soft/pastel, industrial, etc.
- Typography: Choose beautiful, unique fonts. NEVER use generic fonts (Inter, Roboto, Arial, system fonts). Use Google Fonts with distinctive display + body pairings.
- Color: Commit to a cohesive palette with CSS variables. Dominant colors + sharp accents > timid evenly-distributed palettes. NEVER use cliched purple gradients on white.
- Motion: CSS animations, staggered reveals, scroll-triggered effects, hover surprises. Use CSS-only when possible.
- Spatial Composition: Unexpected layouts, asymmetry, overlap, diagonal flow, grid-breaking elements, generous negative space OR controlled density.
- Backgrounds: Create atmosphere with gradient meshes, noise textures, geometric patterns, layered transparencies, dramatic shadows, grain overlays.
- NEVER produce generic AI aesthetics: no cookie-cutter cards-in-grid, no predictable layouts, no overused patterns.
- Match complexity to vision: maximalist = elaborate code + effects; minimalist = precision + subtle details.
- Every design should be DIFFERENT. Vary themes, fonts, aesthetics between generations."""


def get_system_prompt() -> str:
    """Return system prompt with current date/time injected."""
    from datetime import datetime
    now = datetime.now()
    date_line = f"\nCURRENT DATE/TIME: {now.strftime('%A, %Y-%m-%d %H:%M:%S')} (local time)\n"
    return _BASE_SYSTEM_PROMPT + date_line


# Keep SYSTEM_PROMPT as static fallback (used when session has no custom prompt)
SYSTEM_PROMPT = _BASE_SYSTEM_PROMPT


class WebSocketDead(Exception):
    """Raised when WS connection is confirmed dead."""
    pass


async def send_event(ws: WebSocket, event: dict):
    """Send an event to the client. Retries once on transient error before declaring dead."""
    for attempt in range(2):
        try:
            await ws.send_json(event)
            return
        except (WebSocketDisconnect, RuntimeError) as e:
            if attempt == 1:
                raise WebSocketDead()
            # transient error — retry once
            await asyncio.sleep(0.1)
        except Exception:
            raise WebSocketDead()


async def _run_tool(tool_name: str, tool_args: dict):
    return await asyncio.wait_for(execute_tool(tool_name, tool_args), timeout=TOOL_TIMEOUT_SECONDS)


async def handle_user_message(
    ws: WebSocket,
    session_id: str,
    user_text: str,
    cancel_event: asyncio.Event,
    session: dict,
):
    task_start = time.time()

    db_messages = await db.get_messages(session_id)
    messages = []

    sys_prompt = (session.get("system_prompt") if session else None) or get_system_prompt()
    messages.append({"role": "system", "content": sys_prompt})

    for m in db_messages:
        msg = {"role": m["role"], "content": m["content"]}
        if m.get("tool_calls_json"):
            try:
                msg["tool_calls"] = json.loads(m["tool_calls_json"])
            except json.JSONDecodeError:
                pass
        messages.append(msg)

    messages.append({"role": "user", "content": user_text})
    await db.append_message(session_id, "user", user_text)

    intel = AgentIntelligence(user_text)
    ctx_mgr = ContextManager()

    total_tool_calls = 0
    error_count = 0

    for iteration in range(1, MAX_TOOL_ITERATIONS + 1):
        elapsed = time.time() - task_start
        elapsed_str = f"{int(elapsed // 60):02d}:{int(elapsed % 60):02d}"

        await send_event(ws, {
            "type": "status",
            "step": iteration,
            "max_steps": MAX_TOOL_ITERATIONS,
            "elapsed": elapsed_str,
            "tokens": ctx_mgr.get_usage_str()
        })

        if ctx_mgr.needs_compaction(messages):
            messages = ctx_mgr.compact(messages)
            await send_event(ws, {"type": "info", "message": "Context compacted to fit window"})

        accumulated_content = []

        async def on_token(content: str, state: str):
            accumulated_content.append(content)
            await send_event(ws, {
                "type": "token",
                "content": content,
                "thinking": state == "thinking"
            })

        async def on_thinking_start():
            await send_event(ws, {"type": "thinking_start"})

        async def on_thinking_end(token_count: int):
            await send_event(ws, {"type": "thinking_end", "token_count": token_count})

        response = None
        try:
            response = await stream_chat(
                messages=messages,
                tools=TOOLS,
                on_token=on_token,
                on_thinking_start=on_thinking_start,
                on_thinking_end=on_thinking_end,
                cancel_event=cancel_event,
                model=OLLAMA_MODEL,
                url=OLLAMA_URL,
            )
        except Exception as e:
            await send_event(ws, {"type": "error", "message": f"Ollama error: {str(e)}"})
            return

        if response is None:
            return

        if cancel_event.is_set():
            if accumulated_content:
                partial = "".join(accumulated_content)
                messages.append({"role": "assistant", "content": partial})
                await db.append_message(session_id, "assistant", partial)
            await send_event(ws, {"type": "cancelled"})
            return

        ctx_mgr.update_from_response(response.prompt_eval_count, response.eval_count)

        if response.tool_calls:
            assistant_msg = {
                "role": "assistant",
                "content": response.content,
                "tool_calls": response.tool_calls,
            }
            messages.append(assistant_msg)
            await db.append_message(session_id, "assistant", response.content, response.tool_calls)

            tool_jobs = []
            for tc in response.tool_calls:
                func = tc.get("function", {})
                tool_name = func.get("name", "unknown")
                tool_args = func.get("arguments", {})
                if isinstance(tool_args, str):
                    try:
                        tool_args = json.loads(tool_args)
                    except json.JSONDecodeError:
                        tool_args = {"command": tool_args}

                intel.turn_tool_calls += 1
                total_tool_calls += 1
                call_id = total_tool_calls

                if tool_name in ("read_file", "write_file", "edit_file") and "path" in tool_args:
                    tool_args["path"] = intel.sanitize_path(tool_args["path"])

                rep_msg = intel.check_tool_repetition(tool_name, tool_args)
                if rep_msg:
                    messages.append({"role": "system", "content": rep_msg})
                    await db.append_message(session_id, "system", rep_msg)

                blocked_msg = None
                if tool_name == "write_file" and "path" in tool_args and "content" in tool_args:
                    blocked_msg = intel.check_write_interceptor(
                        tool_args["path"], tool_args.get("content", "")
                    )

                await send_event(ws, {
                    "type": "tool_call_start",
                    "tool": tool_name,
                    "args": tool_args,
                    "call_id": call_id,
                })

                tool_jobs.append((call_id, tool_name, tool_args, blocked_msg))

            non_blocked_indices = [i for i, j in enumerate(tool_jobs) if j[3] is None]
            coroutines = [_run_tool(tool_jobs[i][1], tool_jobs[i][2]) for i in non_blocked_indices]

            gather_results: dict[int, object] = {}
            if coroutines:
                raw = await asyncio.gather(*coroutines, return_exceptions=True)
                for idx, result in zip(non_blocked_indices, raw):
                    gather_results[idx] = result

            for job_idx, (call_id, tool_name, tool_args, blocked_msg) in enumerate(tool_jobs):
                if blocked_msg:
                    await send_event(ws, {
                        "type": "tool_call_result",
                        "tool": tool_name,
                        "result": blocked_msg,
                        "success": False,
                        "blocked": True,
                        "duration_ms": 0,
                        "call_id": call_id,
                    })
                    messages.append({"role": "tool", "content": blocked_msg})
                    await db.append_message(session_id, "tool", blocked_msg)
                else:
                    r = gather_results.get(job_idx)
                    if isinstance(r, Exception):
                        err_msg = f"Tool execution error: {str(r)}"
                        await send_event(ws, {
                            "type": "tool_call_result",
                            "tool": tool_name,
                            "result": err_msg,
                            "success": False,
                            "duration_ms": 0,
                            "call_id": call_id,
                        })
                        messages.append({"role": "tool", "content": err_msg})
                        await db.append_message(session_id, "tool", err_msg)
                        error_count += 1
                    else:
                        processed_result, loop_msg = intel.process_tool_result(
                            tool_name, r.output, r.stderr
                        )
                        hint = intel.analyze_stderr(r.stderr) if r.stderr else None
                        if r.stderr and r.stderr.strip():
                            error_count += 1

                        await send_event(ws, {
                            "type": "tool_call_result",
                            "tool": tool_name,
                            "result": r.output[:2000],
                            "stderr": r.stderr[:1000] if r.stderr else "",
                            "success": r.success,
                            "hint": hint,
                            "duration_ms": r.duration_ms,
                            "output_chars": len(r.output),
                            "call_id": call_id,
                        })

                        messages.append({"role": "tool", "content": processed_result})
                        await db.append_message(session_id, "tool", processed_result)

                        if loop_msg:
                            await send_event(ws, {
                                "type": "loop_detected",
                                "error_signature": intel.recent_errors[-1] if intel.recent_errors else "",
                                "count": 3,
                            })
                            messages.append({"role": "system", "content": loop_msg})
                            await db.append_message(session_id, "system", loop_msg)

            # Self-reflection injection every REFLECTION_INTERVAL tool calls
            if intel.should_reflect():
                reflection_msg = intel.get_reflection_prompt()
                messages.append({"role": "system", "content": reflection_msg})
                await db.append_message(session_id, "system", reflection_msg)
                await send_event(ws, {"type": "reflection", "message": reflection_msg})

            # Progress nudge every 15 tool calls
            if total_tool_calls > 0 and total_tool_calls % 15 == 0:
                if total_tool_calls >= 60:
                    progress_msg = (
                        f"[PROGRESS] {total_tool_calls} tool calls made. "
                        f"WRAP UP NOW: summarize accomplishments, note issues, "
                        f"output completion marker [MISSION X COMPLETE]."
                    )
                else:
                    progress_msg = (
                        f"[PROGRESS] {total_tool_calls} tool calls, "
                        f"iteration {iteration}/{MAX_TOOL_ITERATIONS}. "
                        f"Stay focused. If stuck, change approach."
                    )
                messages.append({"role": "system", "content": progress_msg})

            continue

        # Text response (no tool calls)
        full_content = response.content
        visible_content = _re.sub(r"<think>[\s\S]*?</think>", "", full_content).strip()

        # Re-prompt if tools ran but no visible summary
        if total_tool_calls > 0 and not visible_content and not getattr(intel, "_summary_reprompted", False):
            intel._summary_reprompted = True
            summary_msg = (
                "[AGENT] You executed tools but provided no text summary. "
                "Present results with actual numbers, paths, and values."
            )
            if full_content:
                messages.append({"role": "assistant", "content": full_content})
                await db.append_message(session_id, "assistant", full_content)
            messages.append({"role": "user", "content": summary_msg})
            await db.append_message(session_id, "user", summary_msg)
            await send_event(ws, {"type": "reprompt", "reason": "empty_response", "message": summary_msg})
            continue

        messages.append({"role": "assistant", "content": full_content})
        await db.append_message(session_id, "assistant", full_content)

        thinking_msg = intel.check_thinking_only(full_content)
        if thinking_msg:
            messages.append({"role": "user", "content": thinking_msg})
            await db.append_message(session_id, "user", thinking_msg)
            await send_event(ws, {"type": "reprompt", "reason": "thinking_only", "message": thinking_msg})
            continue

        shallow_msg = intel.check_shallow_scan(intel.turn_tool_calls)
        if shallow_msg:
            messages.append({"role": "user", "content": shallow_msg})
            await db.append_message(session_id, "user", shallow_msg)
            await send_event(ws, {"type": "reprompt", "reason": "shallow_scan", "message": shallow_msg})
            continue

        # Check reasoning quality on longer tasks
        quality_msg = intel.check_reasoning_quality(visible_content)
        if quality_msg and total_tool_calls >= 10 and not getattr(intel, "_quality_reprompted", False):
            intel._quality_reprompted = True
            messages.append({"role": "user", "content": quality_msg})
            await db.append_message(session_id, "user", quality_msg)
            await send_event(ws, {"type": "reprompt", "reason": "reasoning_quality", "message": quality_msg})
            continue

        # Final response — done
        elapsed = time.time() - task_start
        elapsed_str = f"{int(elapsed // 60):02d}:{int(elapsed % 60):02d}"
        await send_event(ws, {
            "type": "done",
            "total_steps": iteration,
            "total_tool_calls": total_tool_calls,
            "had_errors": error_count > 0,
            "error_count": error_count,
            "duration": elapsed_str,
            "tokens_per_sec": round(response.tokens_per_sec, 1),
        })
        break
    else:
        elapsed = time.time() - task_start
        elapsed_str = f"{int(elapsed // 60):02d}:{int(elapsed % 60):02d}"
        await send_event(ws, {
            "type": "done",
            "total_steps": MAX_TOOL_ITERATIONS,
            "total_tool_calls": total_tool_calls,
            "had_errors": True,
            "error_count": error_count,
            "duration": elapsed_str,
            "warning": f"Reached max iterations ({MAX_TOOL_ITERATIONS})",
            "tokens_per_sec": 0,
        })


async def _ws_heartbeat(ws: WebSocket, last_pong: dict, interval: int = 20):
    """Send application-level pings every 20s. Never stops on missing pongs —
    lets the WS transport layer detect dead connections rather than killing
    live ones during long tool runs (up to 180s)."""
    try:
        while True:
            await asyncio.sleep(interval)
            try:
                await ws.send_json({"type": "ping", "ts": int(time.time())})
            except Exception:
                return  # WS transport-level error — connection is truly gone
    except asyncio.CancelledError:
        pass


@router.websocket("/ws/{session_id}")
async def websocket_endpoint(ws: WebSocket, session_id: str):
    await ws.accept()

    session = await db.get_session(session_id)
    if not session:
        try:
            await ws.send_json({"type": "error", "message": f"Session {session_id} not found"})
        except Exception:
            pass
        await ws.close()
        return

    try:
        await ws.send_json({"type": "connected", "session_id": session_id})
    except Exception:
        return

    last_pong = {"ts": time.time()}
    heartbeat_task = asyncio.create_task(_ws_heartbeat(ws, last_pong, interval=20))

    current_cancel_event: asyncio.Event | None = None
    agent_task: asyncio.Task | None = None

    try:
        while True:
            data = await ws.receive_json()
            msg_type = data.get("type", "")

            if msg_type == "pong":
                last_pong["ts"] = time.time()
                continue

            if msg_type == "message":
                content = data.get("content", "").strip()
                if content:
                    if current_cancel_event:
                        current_cancel_event.set()
                    if agent_task and not agent_task.done():
                        try:
                            await asyncio.wait_for(asyncio.shield(agent_task), timeout=2.0)
                        except (asyncio.TimeoutError, asyncio.CancelledError, Exception):
                            agent_task.cancel()

                    current_cancel_event = asyncio.Event()
                    agent_task = asyncio.create_task(
                        handle_user_message(ws, session_id, content, current_cancel_event, session)
                    )

            elif msg_type == "cancel":
                if current_cancel_event:
                    current_cancel_event.set()

            elif msg_type == "slash_command":
                cmd = data.get("command", "")
                if cmd == "/clear":
                    await send_event(ws, {"type": "info", "message": "Chat cleared"})
                elif cmd == "/history":
                    msgs = await db.get_messages(session_id)
                    total_chars = sum(len(m.get("content", "")) for m in msgs)
                    est_tokens = total_chars // 4
                    await send_event(ws, {
                        "type": "info",
                        "message": f"History: {len(msgs)} messages, ~{est_tokens} tokens"
                    })
                elif cmd == "/tools":
                    tool_names = [t["function"]["name"] for t in TOOLS]
                    groups = {"System": [], "Files": [], "Discovery": [], "Web": [], "Network": []}
                    sys_tools = {"run_powershell", "run_cmd", "run_python"}
                    file_tools = {"write_file", "read_file", "edit_file", "create_directory", "move_file", "delete_file"}
                    disc_tools = {"list_directory", "search_files", "get_system_info", "get_current_datetime"}
                    net_tools = {"dns_lookup", "port_check", "network_ping"}
                    for t in tool_names:
                        if t in sys_tools: groups["System"].append(t)
                        elif t in file_tools: groups["Files"].append(t)
                        elif t in disc_tools: groups["Discovery"].append(t)
                        elif t in net_tools: groups["Network"].append(t)
                        else: groups["Web"].append(t)
                    msg_parts = [f"{len(tool_names)} tools available:"]
                    for grp, names in groups.items():
                        if names:
                            msg_parts.append(f"  {grp}: {', '.join(names)}")
                    await send_event(ws, {"type": "info", "message": "\n".join(msg_parts)})
                elif cmd == "/status":
                    from engine.ollama_client import check_health
                    healthy = await check_health(OLLAMA_URL)
                    status_msg = (
                        f"Model: {OLLAMA_MODEL}\n"
                        f"Ollama: {'running' if healthy else 'DOWN'}\n"
                        f"Max iterations: {MAX_TOOL_ITERATIONS}\n"
                        f"Tool timeout: {TOOL_TIMEOUT_SECONDS}s\n"
                        f"Tools: {len(TOOLS)}"
                    )
                    await send_event(ws, {"type": "info", "message": status_msg})
                elif cmd == "/help":
                    help_msg = (
                        "Commands:\n"
                        "  /clear     - Clear conversation (Ctrl+L)\n"
                        "  /new       - New session (Ctrl+N)\n"
                        "  /history   - Show message count & tokens\n"
                        "  /tools     - List all available tools\n"
                        "  /status    - Show model & system status\n"
                        "  /export    - Export session as markdown\n"
                        "  /rename    - Rename current session\n"
                        "  /sidebar   - Toggle sidebar (Ctrl+B)\n"
                        "  /shortcuts - Show keyboard shortcuts\n"
                        "\nKeyboard shortcuts:\n"
                        "  Ctrl+K  - Command palette\n"
                        "  Ctrl+L  - Clear chat\n"
                        "  Ctrl+B  - Toggle sidebar\n"
                        "  Ctrl+N  - New session\n"
                        "  Enter   - Send message\n"
                        "  Shift+Enter - New line\n"
                        "  Up/Down - Input history"
                    )
                    await send_event(ws, {"type": "info", "message": help_msg})
                elif cmd == "/shortcuts":
                    await send_event(ws, {"type": "info", "message": (
                        "Keyboard shortcuts:\n"
                        "  Ctrl+K  - Command palette\n"
                        "  Ctrl+L  - Clear chat\n"
                        "  Ctrl+B  - Toggle sidebar\n"
                        "  Ctrl+N  - New session\n"
                        "  Enter   - Send message\n"
                        "  Shift+Enter - New line\n"
                        "  Up/Down - Input history\n"
                        "  Escape  - Close palette"
                    )})
                elif cmd == "/export":
                    msgs = await db.get_messages(session_id)
                    lines = [f"# Session Export", f"Messages: {len(msgs)}", ""]
                    for m in msgs:
                        role = m.get("role", "").upper()
                        content = m.get("content", "")
                        if role == "USER":
                            lines.append(f"**USER:** {content}")
                        elif role == "ASSISTANT":
                            lines.append(f"**AGENT:** {content[:500]}")
                        elif role == "TOOL":
                            lines.append(f"[TOOL] {content[:200]}")
                    await send_event(ws, {"type": "export", "content": "\n\n".join(lines), "format": "markdown"})
                elif cmd == "/rename":
                    await send_event(ws, {"type": "info", "message": "Double-click session name in sidebar to rename"})
                else:
                    await send_event(ws, {"type": "info", "message": f"Unknown command: {cmd}. Type /help for list."})

    except (WebSocketDisconnect, WebSocketDead):
        pass
    except Exception:
        pass
    finally:
        heartbeat_task.cancel()
        if agent_task and not agent_task.done():
            agent_task.cancel()
        try:
            await ws.close()
        except Exception:
            pass
