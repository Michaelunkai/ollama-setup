# -*- coding: utf-8 -*-
"""
oll90 WebSocket Stability Test
Verifies no disconnection occurs under all realistic conditions.
Run: python oll90-test-ws-stability.py
PASS = all checks green. Any FAIL = bug to fix.
"""
import asyncio
import json
import time
import sys
import httpx
import websockets
import io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

BACKEND = "http://127.0.0.1:8090"
WS_URL  = "ws://127.0.0.1:8090"

PASS = 0
FAIL = 0

def check(name, condition, detail=""):
    global PASS, FAIL
    if condition:
        print(f"  [PASS] {name}")
        PASS += 1
    else:
        print(f"  [FAIL] {name}{': ' + detail if detail else ''}")
        FAIL += 1

# ──────────────────────────────────────────────────────────────
async def test_backend_alive():
    print("\n[1] Backend health")
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.get(f"{BACKEND}/api/sessions")
        check("Backend responds HTTP 200", r.status_code == 200)

# ──────────────────────────────────────────────────────────────
async def test_ws_connects_and_pings():
    print("\n[2] WebSocket connect + ping/pong")
    async with httpx.AsyncClient(timeout=10) as c:
        sid = (await c.post(f"{BACKEND}/api/sessions", json={"name": "ws-stab-test"})).json()["id"]

    pings_received = []
    try:
        async with websockets.connect(f"{WS_URL}/ws/{sid}", open_timeout=10, close_timeout=5) as ws:
            # Expect 'connected' event
            raw = await asyncio.wait_for(ws.recv(), timeout=5)
            evt = json.loads(raw)
            check("WS connects, gets 'connected' event", evt.get("type") == "connected")

            # Wait up to 25s for a server ping (backend pings every 20s)
            deadline = time.time() + 25
            while time.time() < deadline:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=5)
                    evt = json.loads(raw)
                    if evt.get("type") == "ping":
                        pings_received.append(time.time())
                        # Reply with pong
                        await ws.send(json.dumps({"type": "pong"}))
                        break
                except asyncio.TimeoutError:
                    pass

            check("Server sends ping within 25s", len(pings_received) > 0)

            # Verify second ping arrives within 25s (heartbeat continuous)
            deadline2 = time.time() + 25
            got_second = False
            while time.time() < deadline2:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=5)
                    evt = json.loads(raw)
                    if evt.get("type") == "ping":
                        got_second = True
                        await ws.send(json.dumps({"type": "pong"}))
                        break
                except asyncio.TimeoutError:
                    pass
            check("Server sends second ping (heartbeat keeps running)", got_second)

    finally:
        async with httpx.AsyncClient(timeout=10) as c:
            await c.delete(f"{BACKEND}/api/sessions/{sid}")

# ──────────────────────────────────────────────────────────────
async def test_simple_message_response():
    print("\n[3] Simple message - agent responds")
    async with httpx.AsyncClient(timeout=10) as c:
        sid = (await c.post(f"{BACKEND}/api/sessions", json={"name": "ws-msg-test"})).json()["id"]

    got_token = False
    got_done = False
    try:
        async with websockets.connect(f"{WS_URL}/ws/{sid}", open_timeout=10, close_timeout=5) as ws:
            # Wait for connected
            await asyncio.wait_for(ws.recv(), timeout=5)

            # Send a simple question
            await ws.send(json.dumps({"type": "message", "content": "reply with only the number 42"}))

            # Collect events for up to 120s
            deadline = time.time() + 120
            while time.time() < deadline:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=5)
                    evt = json.loads(raw)
                    if evt.get("type") == "token" and evt.get("content"):
                        got_token = True
                    if evt.get("type") == "done":
                        got_done = True
                        break
                    if evt.get("type") == "ping":
                        await ws.send(json.dumps({"type": "pong"}))
                except asyncio.TimeoutError:
                    pass

        check("Agent produces token within 120s", got_token)
        check("Agent sends 'done' event", got_done)
    finally:
        async with httpx.AsyncClient(timeout=10) as c:
            await c.delete(f"{BACKEND}/api/sessions/{sid}")

# ──────────────────────────────────────────────────────────────
async def test_no_reload_mode():
    print("\n[4] Uvicorn reload=False (no restart on file writes)")
    import re, pathlib
    main_py = pathlib.Path(__file__).parent / "oll90-ui/interactive/app/backend/main.py"
    if main_py.exists():
        src = main_py.read_text(encoding="utf-8")
        has_reload_false = bool(re.search(r'reload\s*=\s*False', src))
        has_reload_true  = bool(re.search(r'reload\s*=\s*True', src))
        check("reload=False in main.py", has_reload_false and not has_reload_true)
    else:
        check("main.py found", False, str(main_py))

# ──────────────────────────────────────────────────────────────
async def test_heartbeat_config():
    print("\n[5] Heartbeat config: never stops, 20s interval")
    import pathlib, re
    ws_py = pathlib.Path(__file__).parent / "oll90-ui/interactive/app/backend/routers/ws.py"
    if ws_py.exists():
        src = ws_py.read_text(encoding="utf-8")
        # Extract just the _ws_heartbeat function body
        m = re.search(r'def _ws_heartbeat.*?(?=\nasync def |\nclass |\Z)', src, re.DOTALL)
        hb_body = m.group(0) if m else ""
        # Must NOT contain the old stop-on-no-pong pattern
        has_bad_stop = "last_pong" in hb_body and "> 120" in hb_body
        check("Heartbeat does not stop on missing pongs", not has_bad_stop, hb_body[:200] if has_bad_stop else "")
        check("Heartbeat interval=20", "interval=20" in src)
    else:
        check("ws.py found", False)

# ──────────────────────────────────────────────────────────────
async def test_frontend_watchdog_config():
    print("\n[6] Frontend watchdog — 300s threshold")
    import pathlib
    wsjs = pathlib.Path(__file__).parent / "oll90-ui/interactive/app/frontend/src/services/websocket.js"
    if wsjs.exists():
        src = wsjs.read_text(encoding="utf-8")
        check("Frontend watchdog threshold is 300s", "300000" in src)
        check("Frontend max silent reconnects >= 10", "_maxSilentReconnects = 10" in src)
    else:
        check("websocket.js found", False)

# ──────────────────────────────────────────────────────────────
async def test_stream_timeout():
    print("\n[7] Ollama client timeout = 600s")
    import pathlib
    oc = pathlib.Path(__file__).parent / "oll90-ui/interactive/app/backend/engine/ollama_client.py"
    if oc.exists():
        src = oc.read_text(encoding="utf-8")
        check("stream_chat timeout=600", "timeout: int = 600" in src)
        check("num_predict=-1", '"num_predict": -1' in src)
        check("httpx read=timeout", "read=timeout" in src)
    else:
        check("ollama_client.py found", False)

# ──────────────────────────────────────────────────────────────
async def test_ws_survives_long_silence():
    """Hold WS open for 60s without any messages — must NOT disconnect."""
    print("\n[8] WS survives 60s idle (no messages, only pings)")
    async with httpx.AsyncClient(timeout=10) as c:
        sid = (await c.post(f"{BACKEND}/api/sessions", json={"name": "ws-idle-test"})).json()["id"]

    disconnected = False
    pings_seen = 0
    try:
        async with websockets.connect(
            f"{WS_URL}/ws/{sid}",
            open_timeout=10,
            close_timeout=5,
            ping_interval=None,  # disable built-in ping (we test app-level)
        ) as ws:
            await asyncio.wait_for(ws.recv(), timeout=5)  # connected event

            start = time.time()
            while time.time() - start < 60:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=5)
                    evt = json.loads(raw)
                    if evt.get("type") == "ping":
                        pings_seen += 1
                        await ws.send(json.dumps({"type": "pong"}))
                except asyncio.TimeoutError:
                    pass
                except websockets.exceptions.ConnectionClosed:
                    disconnected = True
                    break

        check("WS did NOT disconnect during 60s idle", not disconnected)
        check(f"Received ≥3 server pings during 60s idle ({pings_seen} received)", pings_seen >= 3)
    finally:
        async with httpx.AsyncClient(timeout=10) as c:
            await c.delete(f"{BACKEND}/api/sessions/{sid}")

# ──────────────────────────────────────────────────────────────
async def main():
    print("=" * 60)
    print("  OLL90 WEBSOCKET STABILITY TEST")
    print("=" * 60)

    await test_backend_alive()
    await test_no_reload_mode()
    await test_heartbeat_config()
    await test_frontend_watchdog_config()
    await test_stream_timeout()
    await test_ws_connects_and_pings()
    await test_simple_message_response()
    await test_ws_survives_long_silence()

    print("\n" + "=" * 60)
    total = PASS + FAIL
    print(f"  RESULT: {PASS}/{total} PASSED  |  {FAIL} FAILED")
    print("=" * 60)
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == "__main__":
    asyncio.run(main())
