"""10-task validation suite for oll90 web UI - runs via WebSocket API"""
import asyncio
import json
import sys
import time
import urllib.request

BACKEND = "http://localhost:8090"
WS_BASE = "ws://localhost:8090"

TASKS = [
    "Get the OS version and CPU name of this machine using system tools.",
    "List the top 5 processes by RAM usage right now. Show name, PID, and MB used.",
    "Create a Python file at C:\\Temp\\fib_test.py that prints the first 15 Fibonacci numbers, then run it and show me the output, then delete the file.",
    "Search F:\\Downloads for all .md files and list them with their sizes in KB.",
    "Create a file C:\\Temp\\hello.py with a function greet(name) that returns 'Hello, name!'. Then add a second function farewell(name) that returns 'Goodbye, name!' by editing the file. Run both functions and show output.",
    "Fetch the Hacker News front page (https://news.ycombinator.com) and extract the top 3 story titles from the HTML.",
    "Get the current GPU temperature, VRAM used/total, and GPU utilization. Then write a markdown report to C:\\Temp\\gpu_report.md with this info including timestamp.",
    "Find all .py files in F:\\study\\AI_ML\\AI_and_Machine_Learning\\Artificial_Intelligence\\cli\\claudecode\\ollama-setup\\oll90-ui\\interactive\\app\\backend, count the lines in each file, and show a sorted table of filename and line count.",
    "Check disk free space on both C: and F: drives. Calculate what percentage of each drive is free. Tell me which drive needs cleanup sooner and why.",
    "Perform a full system audit: get GPU model+VRAM, CPU model+cores, top 10 processes by CPU%, 5 largest files on C:\\Windows\\System32, and list active network adapters with their IP addresses. Format everything as a structured report with sections.",
]

async def run_task(session_id: str, task_num: int, task_text: str) -> dict:
    import websockets
    url = f"{WS_BASE}/ws/{session_id}"
    result = {"task": task_num, "text": task_text[:60], "status": "FAIL", "steps": 0, "tools": 0, "duration": "?", "error": None}

    print(f"\n{'='*70}")
    print(f"TASK {task_num}: {task_text[:80]}")
    print('='*70)

    start = time.time()
    try:
        async with websockets.connect(url, max_size=10_000_000, ping_timeout=300) as ws:
            # Wait for connected event
            raw = await asyncio.wait_for(ws.recv(), timeout=10)
            evt = json.loads(raw)
            if evt.get("type") != "connected":
                result["error"] = f"Expected connected, got: {evt}"
                return result

            # Send task
            await ws.send(json.dumps({"type": "message", "content": task_text}))

            # Collect events until done/error/cancelled
            steps = 0
            tools = 0
            final_response = []

            while True:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=300)
                except asyncio.TimeoutError:
                    result["error"] = "Timeout waiting for response"
                    break

                evt = json.loads(raw)
                etype = evt.get("type", "")

                if etype == "status":
                    steps = evt.get("step", steps)
                    print(f"  [step {steps}] elapsed={evt.get('elapsed','?')} tokens={evt.get('tokens','?')}", end="\r")

                elif etype == "token":
                    if not evt.get("thinking"):
                        final_response.append(evt.get("content", ""))

                elif etype == "thinking_start":
                    print(f"\n  <thinking...>", end="")

                elif etype == "thinking_end":
                    print(f" {evt.get('token_count',0)} tokens>", end="")

                elif etype == "tool_call_start":
                    tools += 1
                    print(f"\n  [TOOL {tools}] {evt.get('tool','?')} args={str(evt.get('args',''))[:60]}")

                elif etype == "tool_call_result":
                    success = evt.get("success", False)
                    blocked = evt.get("blocked", False)
                    dur = evt.get("duration_ms", 0)
                    chars = evt.get("output_chars", 0)
                    label = "BLOCKED" if blocked else ("OK" if success else "ERR")
                    stderr = evt.get("stderr", "")
                    hint = evt.get("hint", "")
                    print(f"    -> {label} {dur}ms {chars}chars" + (f" hint={hint[:40]}" if hint else "") + (f" stderr={stderr[:60]}" if stderr else ""))

                elif etype == "reconnecting":
                    print(f"\n  [RECONNECTING attempt {evt.get('attempt', '?')}]")

                elif etype == "loop_detected":
                    print(f"\n  [LOOP DETECTED]")

                elif etype == "reprompt":
                    print(f"\n  [REPROMPT: {evt.get('reason','?')}]")

                elif etype == "info":
                    print(f"\n  [INFO] {evt.get('message','')}")

                elif etype == "error":
                    result["error"] = evt.get("message", "unknown error")
                    print(f"\n  [ERROR] {result['error']}")
                    break

                elif etype == "cancelled":
                    result["error"] = "cancelled"
                    print(f"\n  [CANCELLED]")
                    break

                elif etype == "done":
                    result["status"] = "PASS"
                    result["steps"] = evt.get("total_steps", steps)
                    result["tools"] = evt.get("total_tool_calls", tools)
                    result["duration"] = evt.get("duration", "?")
                    result["tok_s"] = evt.get("tokens_per_sec", 0)
                    had_errors = evt.get("had_errors", False)
                    warning = evt.get("warning", "")
                    if warning:
                        result["status"] = "WARN"
                        result["warning"] = warning
                    elapsed = time.time() - start
                    print(f"\n  -> {'PASS' if not had_errors else 'PASS(errs)'} | steps={result['steps']} tools={result['tools']} time={result['duration']} tok/s={result['tok_s']}")
                    # Print first 500 chars of final response
                    resp_text = "".join(final_response).strip()
                    if resp_text:
                        print(f"  RESPONSE: {resp_text[:600]}")
                    break
    except Exception as e:
        result["error"] = str(e)
        print(f"\n  [EXCEPTION] {e}")

    return result


async def main():
    import websockets

    # Create a fresh session for the validation run
    req = urllib.request.Request(
        f"{BACKEND}/api/sessions",
        data=json.dumps({"name": "10-task-validation"}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    with urllib.request.urlopen(req) as resp:
        session = json.loads(resp.read())

    session_id = session["id"]
    print(f"Session: {session_id}")
    print(f"Running {len(TASKS)} tasks in the SAME session (cumulative context)")

    results = []
    for i, task in enumerate(TASKS, 1):
        r = await run_task(session_id, i, task)
        results.append(r)
        # Brief pause between tasks
        if i < len(TASKS):
            await asyncio.sleep(2)

    # Summary
    print(f"\n{'='*70}")
    print("VALIDATION SUMMARY")
    print('='*70)
    passed = 0
    for r in results:
        status = r["status"]
        if status == "PASS":
            passed += 1
        err = f" ERR={r['error']}" if r.get("error") else ""
        warn = f" WARN={r.get('warning','')}" if r.get("warning") else ""
        print(f"  Task {r['task']:2d}: {status:4s} | steps={r.get('steps',0):2d} tools={r.get('tools',0):2d} time={r.get('duration','?'):6s} tok/s={r.get('tok_s',0):5.1f}{err}{warn}")

    print(f"\nResult: {passed}/{len(TASKS)} PASSED")
    return passed == len(TASKS)


if __name__ == "__main__":
    ok = asyncio.run(main())
    sys.exit(0 if ok else 1)
