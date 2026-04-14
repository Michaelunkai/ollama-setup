"""Async streaming Ollama client with ThinkTagTracker"""
import json
import asyncio
from typing import Optional, Callable, Awaitable

import httpx

from config import OLLAMA_URL, OLLAMA_MODEL


class ThinkTagTracker:
    """State machine to detect <think>...</think> blocks in streaming tokens."""
    OPENING = "<think>"
    CLOSING = "</think>"

    def __init__(self):
        self.state = "normal"  # "normal" or "thinking"
        self.buffer = ""

    def feed(self, text: str) -> list[tuple[str, str]]:
        """Process incoming text. Returns list of (content, state) tuples.
        state is 'normal', 'thinking', 'thinking_start', or 'thinking_end'."""
        results = []
        self.buffer += text

        while self.buffer:
            if self.state == "normal":
                idx = self.buffer.find("<")
                if idx == -1:
                    # No potential tag start
                    results.append((self.buffer, "normal"))
                    self.buffer = ""
                elif idx > 0:
                    # Text before the <
                    results.append((self.buffer[:idx], "normal"))
                    self.buffer = self.buffer[idx:]
                else:
                    # Buffer starts with <
                    if len(self.buffer) >= len(self.OPENING):
                        if self.buffer.startswith(self.OPENING):
                            self.state = "thinking"
                            self.buffer = self.buffer[len(self.OPENING):]
                            results.append(("", "thinking_start"))
                        else:
                            # Not a think tag, emit the <
                            results.append(("<", "normal"))
                            self.buffer = self.buffer[1:]
                    else:
                        # Partial tag possible, wait for more input
                        if self.OPENING.startswith(self.buffer):
                            break  # Wait for more data
                        else:
                            results.append(("<", "normal"))
                            self.buffer = self.buffer[1:]

            elif self.state == "thinking":
                idx = self.buffer.find("<")
                if idx == -1:
                    results.append((self.buffer, "thinking"))
                    self.buffer = ""
                elif idx > 0:
                    results.append((self.buffer[:idx], "thinking"))
                    self.buffer = self.buffer[idx:]
                else:
                    if len(self.buffer) >= len(self.CLOSING):
                        if self.buffer.startswith(self.CLOSING):
                            self.state = "normal"
                            self.buffer = self.buffer[len(self.CLOSING):]
                            results.append(("", "thinking_end"))
                        else:
                            results.append(("<", "thinking"))
                            self.buffer = self.buffer[1:]
                    else:
                        if self.CLOSING.startswith(self.buffer):
                            break  # Wait for more data
                        else:
                            results.append(("<", "thinking"))
                            self.buffer = self.buffer[1:]

        return results

    def flush(self) -> list[tuple[str, str]]:
        """Flush remaining buffer."""
        if self.buffer:
            state = "thinking" if self.state == "thinking" else "normal"
            result = [(self.buffer, state)]
            self.buffer = ""
            return result
        return []


class OllamaStreamResponse:
    """Accumulated response from streaming."""
    def __init__(self):
        self.content = ""
        self.tool_calls = []
        self.done = False
        self.eval_count = 0
        self.eval_duration = 0
        self.prompt_eval_count = 0
        self.total_duration = 0

    @property
    def tokens_per_sec(self) -> float:
        if self.eval_duration > 0:
            return self.eval_count / (self.eval_duration / 1_000_000_000)
        return 0.0


async def stream_chat(
    messages: list[dict],
    tools: list[dict],
    on_token: Callable[[str, str], Awaitable[None]],  # (content, state)
    on_thinking_start: Callable[[], Awaitable[None]],
    on_thinking_end: Callable[[int], Awaitable[None]],  # token_count
    cancel_event: asyncio.Event = None,
    model: str = OLLAMA_MODEL,
    url: str = OLLAMA_URL,
    timeout: int = 600,
) -> OllamaStreamResponse:
    """Stream a chat completion from Ollama.

    Args:
        messages: Conversation history
        tools: Tool definitions
        on_token: Called with (content, state) for each token
        on_thinking_start: Called when <think> tag opens
        on_thinking_end: Called with thinking token count when </think> closes
        cancel_event: Set to cancel streaming
        model: Model name
        url: Ollama URL
        timeout: Request timeout in seconds
    """
    body = {
        "model": model,
        "messages": messages,
        "stream": True,
        "think": False,
        "options": {
            "num_predict": -1,
        },
    }
    if tools:
        body["tools"] = tools

    response = OllamaStreamResponse()
    tracker = ThinkTagTracker()
    thinking_tokens = 0

    # Per-line idle timeout: if Ollama stops sending data for 90s, treat as stale stream.
    # This prevents the event loop from blocking indefinitely on a hung Ollama generation.
    LINE_IDLE_TIMEOUT = 90

    async with httpx.AsyncClient(timeout=httpx.Timeout(timeout, connect=30, read=timeout)) as client:
        async with client.stream("POST", f"{url}/api/chat", json=body) as resp:
            resp.raise_for_status()

            aiter = resp.aiter_lines().__aiter__()
            while True:
                if cancel_event and cancel_event.is_set():
                    break
                try:
                    line = await asyncio.wait_for(aiter.__anext__(), timeout=LINE_IDLE_TIMEOUT)
                except asyncio.TimeoutError:
                    # No data from Ollama for LINE_IDLE_TIMEOUT seconds — stream is stale
                    raise RuntimeError(f"Ollama stream idle for {LINE_IDLE_TIMEOUT}s — aborting")
                except StopAsyncIteration:
                    break

                if not line.strip():
                    continue

                try:
                    chunk = json.loads(line)
                except json.JSONDecodeError:
                    continue

                msg = chunk.get("message", {})

                # Handle content tokens
                content = msg.get("content", "")
                if content:
                    response.content += content
                    # Process through think tag tracker
                    segments = tracker.feed(content)
                    for seg_content, seg_state in segments:
                        if seg_state == "thinking_start":
                            await on_thinking_start()
                        elif seg_state == "thinking_end":
                            await on_thinking_end(thinking_tokens)
                            thinking_tokens = 0
                        elif seg_content:
                            if seg_state == "thinking":
                                thinking_tokens += 1
                            await on_token(seg_content, seg_state)

                # Handle tool calls (arrive in final chunk)
                if "tool_calls" in msg:
                    response.tool_calls = msg["tool_calls"]

                # Handle done
                if chunk.get("done"):
                    response.done = True
                    response.eval_count = chunk.get("eval_count", 0)
                    response.eval_duration = chunk.get("eval_duration", 0)
                    response.prompt_eval_count = chunk.get("prompt_eval_count", 0)
                    response.total_duration = chunk.get("total_duration", 0)

                    # Flush tracker buffer
                    for seg_content, seg_state in tracker.flush():
                        if seg_content:
                            await on_token(seg_content, seg_state)
                    break

    return response


async def check_health(url: str = OLLAMA_URL) -> bool:
    """Check if Ollama is running."""
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.get(f"{url}/api/version")
            return resp.status_code == 200
    except Exception:
        return False


async def get_model_info(url: str = OLLAMA_URL, model: str = OLLAMA_MODEL) -> Optional[dict]:
    """Get loaded model info from Ollama."""
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{url}/api/ps")
            if resp.status_code == 200:
                data = resp.json()
                models = data.get("models", [])
                for m in models:
                    if m.get("name", "").startswith(model.split(":")[0]):
                        return m
    except Exception:
        pass
    return None
