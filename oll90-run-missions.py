# -*- coding: utf-8 -*-
"""
oll90 Mission Runner - runs 4 missions via WebSocket and verifies all complete.
Mission 1: list all folders in all drives (from screenshot)
Missions 2-4: complex web/system tasks
"""
import asyncio, json, time, sys, httpx, websockets, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

BACKEND = "http://127.0.0.1:8090"
WS_URL  = "ws://127.0.0.1:8090"
TIMEOUT = 300  # 5 min per mission

MISSIONS = [
    "list all top-level folders in C:\\ and F:\\ (non-recursive, one level only). Show each drive separately with folder names and sizes.",
    "use web_search to find the top 5 most visited websites globally right now. Show titles, URLs, and a one-line description for each.",
    "get full system info: CPU model and cores, GPU model and VRAM used, total RAM, all disk drives with free space percentage, and top 5 processes by memory usage right now.",
    "use run_powershell to find all .py files under F:\\study\\AI_ML\\AI_and_Machine_Learning\\Artificial_Intelligence\\cli\\claudecode\\ollama-setup\\oll90-ui\\interactive\\app\\backend and count total lines. Show top 5 largest files by line count.",
]

PASS = 0
FAIL = 0

def pr(msg): print(msg, flush=True)

async def run_mission(n, prompt):
    global PASS, FAIL
    pr(f"\n{'='*60}")
    pr(f"MISSION {n}: {prompt[:80]}...")
    pr('='*60)

    async with httpx.AsyncClient(timeout=15) as c:
        sid = (await c.post(f"{BACKEND}/api/sessions", json={"name": f"mission-{n}"})).json()["id"]

    got_token = False
    got_done  = False
    tool_calls = 0
    tokens_recv = []
    start = time.time()
    final_summary = ""

    try:
        async with websockets.connect(
            f"{WS_URL}/ws/{sid}",
            open_timeout=15,
            close_timeout=10,
            ping_interval=None,
            max_size=10*1024*1024,
        ) as ws:
            # wait for connected
            raw = await asyncio.wait_for(ws.recv(), timeout=10)
            evt = json.loads(raw)
            assert evt["type"] == "connected", f"Expected connected, got {evt}"

            # send mission
            await ws.send(json.dumps({"type": "message", "content": prompt}))
            pr(f"  Sent. Waiting for response (timeout={TIMEOUT}s)...")

            deadline = time.time() + TIMEOUT
            while time.time() < deadline:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=10)
                except asyncio.TimeoutError:
                    continue
                try:
                    evt = json.loads(raw)
                except Exception:
                    continue

                t = evt.get("type", "")

                if t == "ping":
                    await ws.send(json.dumps({"type": "pong"}))

                elif t == "token":
                    got_token = True
                    c_ = evt.get("content", "")
                    tokens_recv.append(c_)
                    if len(tokens_recv) % 50 == 0:
                        pr(f"  ... {len(tokens_recv)} tokens so far ({int(time.time()-start)}s)")

                elif t == "tool_call_start":
                    tool_calls += 1
                    pr(f"  [tool] {evt.get('tool')} #{tool_calls}")

                elif t == "done":
                    got_done = True
                    elapsed = time.time() - start
                    tps = evt.get("tokens_per_sec", 0)
                    steps = evt.get("total_steps", 0)
                    tc = evt.get("total_tool_calls", 0)
                    final_summary = "".join(tokens_recv)
                    pr(f"\n  DONE in {elapsed:.1f}s | {tc} tool calls | {steps} iters | {tps} tok/s")
                    pr(f"  Response preview: {final_summary[:300].strip()}")
                    break

                elif t == "error":
                    pr(f"  [ERROR] {evt.get('message')}")

                elif t == "status":
                    pass  # suppress status spam

    except Exception as e:
        pr(f"  [EXCEPTION] {e}")

    elapsed = time.time() - start

    ok = got_token and got_done
    if ok:
        pr(f"\n  [PASS] Mission {n} completed in {elapsed:.1f}s with {tool_calls} tool calls")
        PASS += 1
    else:
        pr(f"\n  [FAIL] Mission {n}: got_token={got_token} got_done={got_done} after {elapsed:.1f}s")
        FAIL += 1

    # cleanup session
    try:
        async with httpx.AsyncClient(timeout=10) as c:
            await c.delete(f"{BACKEND}/api/sessions/{sid}")
    except Exception:
        pass

    return ok


async def main():
    pr("=" * 60)
    pr("  OLL90 MISSION RUNNER - 4 MISSIONS")
    pr("=" * 60)

    # Verify backend alive
    try:
        async with httpx.AsyncClient(timeout=10) as c:
            r = await c.get(f"{BACKEND}/api/sessions")
            assert r.status_code == 200
        pr("[OK] Backend alive")
    except Exception as e:
        pr(f"[FATAL] Backend not running: {e}")
        sys.exit(1)

    for i, mission in enumerate(MISSIONS, 1):
        await run_mission(i, mission)

    pr("\n" + "=" * 60)
    total = PASS + FAIL
    pr(f"  FINAL: {PASS}/{total} MISSIONS PASSED  |  {FAIL} FAILED")
    pr("=" * 60)
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == "__main__":
    asyncio.run(main())
