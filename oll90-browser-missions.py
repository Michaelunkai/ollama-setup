# -*- coding: utf-8 -*-
"""
Opens Chrome, navigates to oll90, sends 4 missions live via browser automation.
User can watch the entire process in the browser window.
"""
import sys, io, time
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8', errors='replace')

from playwright.sync_api import sync_playwright

FRONTEND = "http://localhost:3090"
TIMEOUT = 300_000  # 5 min per mission

MISSIONS = [
    "list all top-level folders in C:\\ and F:\\ (non-recursive, one level only). Show each drive separately with folder names.",
    "use web_search to find the top 5 most visited websites globally right now. Show titles, URLs, and a one-line description for each.",
    "get full system info: CPU model and cores, GPU model and VRAM, total RAM, all disk drives with free space, and top 5 processes by memory usage right now.",
    "use run_powershell to find all .py files under F:\\study\\AI_ML\\AI_and_Machine_Learning\\Artificial_Intelligence\\cli\\claudecode\\ollama-setup\\oll90-ui\\interactive\\app\\backend and count total lines. Show top 5 largest files by line count.",
]

def send_mission(page, mission_num, prompt):
    print(f"\n{'='*60}")
    print(f"MISSION {mission_num}: {prompt[:70]}...")
    print('='*60)

    # Click "New Chat" button in sidebar
    try:
        page.click('button:has-text("New Chat")', timeout=5000)
        time.sleep(0.5)
    except Exception:
        try:
            # Try finding the + or new session button
            page.click('[title*="new" i], [aria-label*="new" i], button:has-text("+")', timeout=3000)
            time.sleep(0.5)
        except Exception:
            print("  Could not find New Chat button, using existing session")

    # Find the input textarea/input
    input_sel = 'textarea, input[type="text"], [contenteditable="true"]'
    page.wait_for_selector(input_sel, timeout=10000)
    inp = page.locator(input_sel).last
    inp.click()
    inp.fill(prompt)
    print(f"  Typed prompt ({len(prompt)} chars)")

    # Submit
    inp.press("Enter")
    print(f"  Submitted. Watching for response...")

    # Wait for "done" — no streaming cursor / spinner, response visible
    # We detect completion by waiting for the input to become enabled again
    # and some response text to appear
    start = time.time()
    done = False

    # Wait up to TIMEOUT ms for response to appear and complete
    try:
        # Wait for any assistant message to appear
        page.wait_for_selector(
            '[class*="agent"], [class*="assistant"], [class*="message"]:not([class*="user"])',
            timeout=30000
        )
        print("  Response started streaming...")

        # Wait for input to become active again (means generation finished)
        page.wait_for_function(
            """() => {
                const inp = document.querySelector('textarea, input[type="text"]');
                return inp && !inp.disabled;
            }""",
            timeout=TIMEOUT
        )
        elapsed = time.time() - start
        print(f"  DONE in {elapsed:.1f}s")
        done = True
    except Exception as e:
        elapsed = time.time() - start
        print(f"  Timeout/error after {elapsed:.1f}s: {e}")

    # Pause so user can read the result
    time.sleep(3)
    return done


def main():
    print("="*60)
    print("  OLL90 BROWSER MISSION DEMO")
    print("  Opening Chrome — watch the browser window!")
    print("="*60)

    with sync_playwright() as p:
        browser = p.chromium.launch(
            headless=False,
            channel="chrome",
            args=["--start-maximized"]
        )
        ctx = browser.new_context(no_viewport=True)
        page = ctx.new_page()

        print(f"\nNavigating to {FRONTEND}...")
        page.goto(FRONTEND, wait_until="networkidle", timeout=30000)
        time.sleep(2)
        print("Page loaded.")

        passed = 0
        for i, mission in enumerate(MISSIONS, 1):
            ok = send_mission(page, i, mission)
            if ok:
                passed += 1

        print(f"\n{'='*60}")
        print(f"  FINAL: {passed}/{len(MISSIONS)} MISSIONS COMPLETED IN BROWSER")
        print(f"{'='*60}")

        print("\nBrowser will stay open for 30s so you can review results...")
        time.sleep(30)
        browser.close()


if __name__ == "__main__":
    main()
