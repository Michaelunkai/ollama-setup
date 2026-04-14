"""Tool executor - 54 async tools for the oll90 v3 agent"""

import asyncio
import os
import re
import shutil
import subprocess
import uuid
import tempfile
import time
import glob as glob_mod
import html
import json as json_mod
from pathlib import Path
from typing import Optional

from config import TOOL_TIMEOUT_SECONDS, MAX_OUTPUT_CHARS
from models import ToolResult


def _expand_env_vars(path: str) -> str:
    """Expand $env:VARNAME and %VARNAME% in file paths."""
    import re as _re

    # Expand $env:VARNAME (PowerShell style)
    def _replace_env(m):
        val = os.environ.get(m.group(1), m.group(0))
        return val

    path = _re.sub(r"\$env:(\w+)", _replace_env, path, flags=_re.IGNORECASE)
    # Expand %VARNAME% (CMD style)
    path = os.path.expandvars(path)
    return path


def _get_temp_dir() -> str:
    """Get temp directory, preferring C:\\Temp for Windows."""
    t = "C:\\Temp"
    if os.path.isdir(t):
        return t
    return tempfile.gettempdir()


_BACKEND_PID = os.getpid()

# Safety: critical paths that delete_file will refuse to touch
_PROTECTED_PATHS = [
    "c:\\windows",
    "c:\\users",
    "c:\\program files",
    "c:\\program files (x86)",
    "c:\\programdata",
    "c:\\recovery",
    "c:\\system volume information",
    "c:\\$recycle.bin",
    "c:\\boot",
]


def _is_protected_path(path: str) -> bool:
    """Check if path is a critical system path."""
    normalized = path.lower().replace("/", "\\").rstrip("\\")
    for protected in _PROTECTED_PATHS:
        if normalized == protected or normalized.startswith(protected + "\\"):
            # Allow deleting files INSIDE protected dirs (not the dirs themselves)
            if normalized == protected:
                return True
    return False


def _safe_guard_command(command: str) -> str:
    """Prevent the agent from killing the oll90 backend's own Python process."""
    import re

    # Pattern 1: Stop-Process -Name python
    command = re.sub(
        r'Stop-Process\s+-Name\s+["\']?python\w*["\']?\s*(?:-Force\s*)?(?:-ErrorAction\s+\w+\s*)?',
        f"Get-Process python -ErrorAction SilentlyContinue | Where-Object {{ $_.Id -ne {_BACKEND_PID} }} | Stop-Process -Force -ErrorAction SilentlyContinue ",
        command,
        flags=re.IGNORECASE,
    )

    # Pattern 2: Get-Process python | ... Stop-Process
    command = re.sub(
        r"(Get-Process\s+python\w*)\s*(-ErrorAction\s+\w+)?\s*(\|)",
        rf"\1 \2 | Where-Object {{ $_.Id -ne {_BACKEND_PID} }} \3",
        command,
        flags=re.IGNORECASE,
    )

    # Pattern 3: taskkill /IM python.exe
    command = re.sub(
        r"taskkill\s+/(?:IM|im)\s+python\w*\.exe",
        f'powershell -Command "Get-Process python -EA 0 | Where-Object {{ $_.Id -ne {_BACKEND_PID} }} | Stop-Process -Force -EA 0"',
        command,
        flags=re.IGNORECASE,
    )

    return command


def _run_powershell_sync(command: str) -> ToolResult:
    """Synchronous PowerShell execution via temp .ps1 file (runs in thread)."""
    start = time.time()
    command = _safe_guard_command(command)
    temp_dir = _get_temp_dir()
    script_path = os.path.join(temp_dir, f"oll90_{uuid.uuid4().hex[:8]}.ps1")

    try:
        with open(script_path, "w", encoding="utf-8") as f:
            f.write(command)

        proc = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                script_path,
            ],
            capture_output=True,
            timeout=TOOL_TIMEOUT_SECONDS,
            creationflags=0x08000000,  # CREATE_NO_WINDOW
        )

        stdout = proc.stdout.decode("utf-8", errors="replace") if proc.stdout else ""
        stderr = proc.stderr.decode("utf-8", errors="replace") if proc.stderr else ""

        if len(stdout) > MAX_OUTPUT_CHARS:
            stdout = (
                stdout[:MAX_OUTPUT_CHARS]
                + f"\n... [TRUNCATED at {MAX_OUTPUT_CHARS} chars]"
            )

        return ToolResult(
            output=stdout,
            stderr=stderr,
            success=(proc.returncode == 0 or not stderr.strip()),
            duration_ms=int((time.time() - start) * 1000),
        )
    except subprocess.TimeoutExpired:
        return ToolResult(
            output="[ERROR] Command timed out after {0}s".format(TOOL_TIMEOUT_SECONDS),
            stderr="Timeout",
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )
    finally:
        try:
            os.unlink(script_path)
        except OSError:
            pass


async def run_powershell(command: str) -> ToolResult:
    """Execute a PowerShell command via temp .ps1 file (thread-safe for any event loop)."""
    return await asyncio.to_thread(_run_powershell_sync, command)


def _run_cmd_sync(command: str) -> ToolResult:
    """Synchronous CMD execution (runs in thread)."""
    start = time.time()
    try:
        proc = subprocess.run(
            ["cmd.exe", "/c", command],
            capture_output=True,
            timeout=TOOL_TIMEOUT_SECONDS,
            creationflags=0x08000000,
        )

        stdout = proc.stdout.decode("utf-8", errors="replace") if proc.stdout else ""
        stderr = proc.stderr.decode("utf-8", errors="replace") if proc.stderr else ""

        if len(stdout) > MAX_OUTPUT_CHARS:
            stdout = stdout[:MAX_OUTPUT_CHARS] + "\n... [TRUNCATED]"

        return ToolResult(
            output=stdout,
            stderr=stderr,
            success=(proc.returncode == 0),
            duration_ms=int((time.time() - start) * 1000),
        )
    except subprocess.TimeoutExpired:
        return ToolResult(
            output="[ERROR] Command timed out after {0}s".format(TOOL_TIMEOUT_SECONDS),
            stderr="Timeout",
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def run_cmd(command: str) -> ToolResult:
    """Execute a CMD.exe command (thread-safe for any event loop)."""
    return await asyncio.to_thread(_run_cmd_sync, command)


def _run_python_sync(code: str) -> ToolResult:
    """Synchronous Python execution via temp .py file (runs in thread)."""
    start = time.time()
    temp_dir = _get_temp_dir()
    script_path = os.path.join(temp_dir, f"oll90_py_{uuid.uuid4().hex[:8]}.py")

    try:
        with open(script_path, "w", encoding="utf-8") as f:
            f.write(code)

        python_exe = (
            r"C:\Users\micha\AppData\Local\Programs\Python\Python312\python.exe"
        )
        if not os.path.isfile(python_exe):
            python_exe = "python"

        proc = subprocess.run(
            [python_exe, script_path],
            capture_output=True,
            timeout=TOOL_TIMEOUT_SECONDS,
            creationflags=0x08000000,
        )

        stdout = proc.stdout.decode("utf-8", errors="replace") if proc.stdout else ""
        stderr = proc.stderr.decode("utf-8", errors="replace") if proc.stderr else ""

        if len(stdout) > MAX_OUTPUT_CHARS:
            stdout = (
                stdout[:MAX_OUTPUT_CHARS]
                + f"\n... [TRUNCATED at {MAX_OUTPUT_CHARS} chars]"
            )

        return ToolResult(
            output=stdout,
            stderr=stderr,
            success=(proc.returncode == 0),
            duration_ms=int((time.time() - start) * 1000),
        )
    except subprocess.TimeoutExpired:
        return ToolResult(
            output="[ERROR] Script timed out after {0}s".format(TOOL_TIMEOUT_SECONDS),
            stderr="Timeout",
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )
    finally:
        try:
            os.unlink(script_path)
        except OSError:
            pass


async def run_python(code: str) -> ToolResult:
    """Execute Python code via temp .py file (thread-safe)."""
    return await asyncio.to_thread(_run_python_sync, code)


async def write_file(path: str, content: str) -> ToolResult:
    """Write content to an absolute path with UTF-8 no BOM."""
    start = time.time()
    path = _expand_env_vars(path)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(content)
        size = os.path.getsize(path)
        return ToolResult(
            output=f"File written: {path} ({size} bytes)",
            success=True,
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def read_file(path: str) -> ToolResult:
    """Read file content by absolute path."""
    start = time.time()
    path = _expand_env_vars(path)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        if len(content) > MAX_OUTPUT_CHARS:
            content = (
                content[:MAX_OUTPUT_CHARS]
                + f"\n... [TRUNCATED at {MAX_OUTPUT_CHARS} chars]"
            )
        return ToolResult(
            output=content, success=True, duration_ms=int((time.time() - start) * 1000)
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def edit_file(path: str, old_text: str, new_text: str) -> ToolResult:
    """Edit a file by replacing exact text."""
    start = time.time()
    path = _expand_env_vars(path)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()

        count = content.count(old_text)
        if count == 0:
            return ToolResult(
                output="",
                stderr="old_text not found in file",
                success=False,
                duration_ms=int((time.time() - start) * 1000),
            )
        if count > 1:
            return ToolResult(
                output="",
                stderr=f"old_text found {count} times (must be unique)",
                success=False,
                duration_ms=int((time.time() - start) * 1000),
            )

        new_content = content.replace(old_text, new_text, 1)
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(new_content)

        return ToolResult(
            output=f"Edited {path}: replaced {len(old_text)} chars with {len(new_text)} chars",
            success=True,
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def create_directory(path: str) -> ToolResult:
    """Create a directory and all parent directories."""
    start = time.time()
    path = _expand_env_vars(path)
    try:
        os.makedirs(path, exist_ok=True)
        return ToolResult(
            output=f"Directory created: {path}",
            success=True,
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def move_file(source: str, destination: str) -> ToolResult:
    """Move or rename a file or directory."""
    start = time.time()
    source = _expand_env_vars(source)
    destination = _expand_env_vars(destination)
    try:
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        shutil.move(source, destination)
        return ToolResult(
            output=f"Moved: {source} -> {destination}",
            success=True,
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def delete_file(path: str) -> ToolResult:
    """Delete a file or empty directory with safety guards."""
    start = time.time()
    path = _expand_env_vars(path)

    if _is_protected_path(path):
        return ToolResult(
            output="",
            stderr=f"BLOCKED: Cannot delete protected system path: {path}",
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )

    try:
        p = Path(path)
        if p.is_file():
            p.unlink()
            return ToolResult(
                output=f"Deleted file: {path}",
                success=True,
                duration_ms=int((time.time() - start) * 1000),
            )
        elif p.is_dir():
            # Only delete empty directories for safety
            entries = list(p.iterdir())
            if entries:
                return ToolResult(
                    output="",
                    stderr=f"Directory not empty ({len(entries)} items). Use run_powershell with Remove-Item -Recurse for non-empty dirs.",
                    success=False,
                    duration_ms=int((time.time() - start) * 1000),
                )
            p.rmdir()
            return ToolResult(
                output=f"Deleted empty directory: {path}",
                success=True,
                duration_ms=int((time.time() - start) * 1000),
            )
        else:
            return ToolResult(
                output="",
                stderr=f"Path does not exist: {path}",
                success=False,
                duration_ms=int((time.time() - start) * 1000),
            )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


def _list_directory_sync(path: str, recursive: bool, pattern: str) -> ToolResult:
    """Synchronous directory listing (runs in thread to avoid blocking event loop)."""
    from datetime import datetime
    start = time.time()
    try:
        p = Path(path)
        if not p.is_dir():
            return ToolResult(output="", stderr=f"Not a directory: {path}", success=False,
                              duration_ms=int((time.time() - start) * 1000))

        items = list(p.rglob(pattern) if recursive else p.glob(pattern))
        items = items[:500]  # Limit

        lines = []
        for item in sorted(items):
            try:
                stat = item.stat()
                kind = "D" if item.is_dir() else "F"
                size = stat.st_size if item.is_file() else 0
                if size > 1_073_741_824:
                    size_str = f"{size / 1_073_741_824:.1f} GB"
                elif size > 1_048_576:
                    size_str = f"{size / 1_048_576:.1f} MB"
                elif size > 1024:
                    size_str = f"{size / 1024:.1f} KB"
                else:
                    size_str = f"{size} B"
                mtime = datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M")
                lines.append(f"[{kind}] {size_str:>10s}  {mtime}  {item.name}")
            except (PermissionError, OSError):
                lines.append(f"[?]            ????-??-?? ??:??  {item.name}")

        output = f"Directory: {path}\n{len(lines)} items\n\n" + "\n".join(lines)
        return ToolResult(output=output, success=True, duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return ToolResult(output="", stderr=str(e), success=False,
                          duration_ms=int((time.time() - start) * 1000))


async def list_directory(
    path: str, recursive: bool = False, pattern: str = "*"
) -> ToolResult:
    """List files and directories. Runs in thread to avoid blocking the event loop."""
    return await asyncio.to_thread(_list_directory_sync, path, recursive, pattern)


def _search_files_sync(path: str, pattern: str, file_glob: str) -> ToolResult:
    """Synchronous file search (runs in thread to avoid blocking event loop)."""
    start = time.time()
    try:
        p = Path(path)
        if not p.is_dir():
            return ToolResult(output="", stderr=f"Not a directory: {path}", success=False,
                              duration_ms=int((time.time() - start) * 1000))

        compiled = re.compile(pattern, re.IGNORECASE)
        matches = []
        files_searched = 0
        max_results = 50

        for file_path in p.rglob(file_glob):
            if not file_path.is_file():
                continue
            if file_path.stat().st_size > 1_048_576:
                continue
            files_searched += 1
            try:
                with open(file_path, "r", encoding="utf-8", errors="replace") as f:
                    for line_num, line in enumerate(f, 1):
                        if compiled.search(line):
                            matches.append(f"{file_path}:{line_num}: {line.rstrip()[:200]}")
                            if len(matches) >= max_results:
                                break
            except (PermissionError, OSError):
                continue
            if len(matches) >= max_results:
                break

        header = f"Searched {files_searched} files in {path}\n{len(matches)} matches for /{pattern}/\n\n"
        return ToolResult(output=header + "\n".join(matches), success=True,
                          duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return ToolResult(output="", stderr=str(e), success=False,
                          duration_ms=int((time.time() - start) * 1000))


async def search_files(path: str, pattern: str, file_glob: str = "*.*") -> ToolResult:
    """Search file contents for a regex pattern. Runs in thread to avoid blocking event loop."""
    return await asyncio.to_thread(_search_files_sync, path, pattern, file_glob)


async def get_system_info() -> ToolResult:
    """Snapshot of CPU, RAM, GPU, disks, and OS info via PowerShell."""
    cmd = (
        "$os = Get-CimInstance Win32_OperatingSystem; "
        "$cpu = Get-CimInstance Win32_Processor; "
        "$gpu = try { nvidia-smi --query-gpu=name,memory.total,memory.used,temperature.gpu,utilization.gpu --format=csv,noheader 2>$null } catch { 'N/A' }; "
        "$disks = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | "
        "  Select-Object DeviceID,@{N='FreeGB';E={[math]::Round($_.FreeSpace/1GB,1)}},@{N='TotalGB';E={[math]::Round($_.Size/1GB,1)}}; "
        "$ram_total = [math]::Round($os.TotalVisibleMemorySize/1MB, 1); "
        "$ram_free  = [math]::Round($os.FreePhysicalMemory/1MB, 1); "
        "Write-Output ('OS: ' + $os.Caption + ' Build ' + $os.BuildNumber); "
        "Write-Output ('CPU: ' + $cpu.Name + ' (' + $cpu.NumberOfLogicalProcessors + ' threads)'); "
        "Write-Output ('RAM: ' + ($ram_total - $ram_free) + ' GB used / ' + $ram_total + ' GB total'); "
        "Write-Output ('GPU: ' + $gpu); "
        "Write-Output ('Disks: ' + ($disks | ForEach-Object { $_.DeviceID + ' ' + $_.FreeGB + 'GB free / ' + $_.TotalGB + 'GB' } | Out-String).Trim())"
    )
    return await run_powershell(cmd)


async def web_search(query: str, max_results: int = 8) -> ToolResult:
    """Search the web using DuckDuckGo and return titles + snippets + URLs."""
    start = time.time()
    try:
        import httpx
        import urllib.parse

        encoded = urllib.parse.quote_plus(query)
        search_url = f"https://html.duckduckgo.com/html/?q={encoded}"
        async with httpx.AsyncClient(follow_redirects=True, timeout=15) as client:
            resp = await client.get(
                search_url,
                headers={
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                },
            )
        text = resp.text
        results = []
        title_matches = re.findall(
            r'class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>', text, re.DOTALL
        )
        snippet_matches = re.findall(
            r'class="result__snippet"[^>]*>(.*?)</span>', text, re.DOTALL
        )
        for i, (url_raw, title_raw) in enumerate(title_matches[:max_results]):
            title = re.sub(r"<[^>]+>", "", title_raw).strip()
            snippet = (
                re.sub(r"<[^>]+>", "", snippet_matches[i]).strip()
                if i < len(snippet_matches)
                else ""
            )
            url_decoded = html.unescape(url_raw)
            if "uddg=" in url_decoded:
                m = re.search(r"uddg=([^&]+)", url_decoded)
                if m:
                    url_decoded = urllib.parse.unquote(m.group(1))
            results.append(f"{i + 1}. {title}\n   {snippet}\n   {url_decoded}")
        if not results:
            import asyncio as _aio

            await _aio.sleep(2)
            simplified = " ".join(query.replace('"', "").split()[:5])
            if simplified != query:
                encoded2 = urllib.parse.quote_plus(simplified)
                search_url2 = f"https://html.duckduckgo.com/html/?q={encoded2}"
                async with httpx.AsyncClient(
                    follow_redirects=True, timeout=25
                ) as client2:
                    resp2 = await client2.get(
                        search_url2,
                        headers={
                            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
                        },
                    )
                text2 = resp2.text
                title_matches2 = re.findall(
                    r'class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>',
                    text2,
                    re.DOTALL,
                )
                snippet_matches2 = re.findall(
                    r'class="result__snippet"[^>]*>(.*?)</span>', text2, re.DOTALL
                )
                for i, (url_raw, title_raw) in enumerate(title_matches2[:max_results]):
                    title = re.sub(r"<[^>]+>", "", title_raw).strip()
                    snippet = (
                        re.sub(r"<[^>]+>", "", snippet_matches2[i]).strip()
                        if i < len(snippet_matches2)
                        else ""
                    )
                    url_decoded = html.unescape(url_raw)
                    if "uddg=" in url_decoded:
                        m = re.search(r"uddg=([^&]+)", url_decoded)
                        if m:
                            url_decoded = urllib.parse.unquote(m.group(1))
                    results.append(f"{i + 1}. {title}\n   {snippet}\n   {url_decoded}")

            if not results:
                return ToolResult(
                    output=f"No results found for: {query} (also tried simplified: {simplified})",
                    success=True,
                    duration_ms=int((time.time() - start) * 1000),
                )
        output = f"Search: {query}\n{len(results)} results:\n\n" + "\n\n".join(results)
        return ToolResult(
            output=output, success=True, duration_ms=int((time.time() - start) * 1000)
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def download_file(url: str, path: str) -> ToolResult:
    """Download a file from URL and save to absolute path."""
    start = time.time()
    try:
        import httpx

        os.makedirs(os.path.dirname(path), exist_ok=True)
        async with httpx.AsyncClient(follow_redirects=True, timeout=60) as client:
            resp = await client.get(url, headers={"User-Agent": "oll90-agent/3.0"})
            resp.raise_for_status()
            with open(path, "wb") as f:
                f.write(resp.content)
        size = os.path.getsize(path)
        return ToolResult(
            output=f"Downloaded {url} -> {path} ({size} bytes)",
            success=True,
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def web_fetch(url: str) -> ToolResult:
    """HTTP GET a URL and return text with HTML tags stripped (max 25K chars)."""
    start = time.time()
    try:
        import httpx

        async with httpx.AsyncClient(follow_redirects=True, timeout=15) as client:
            resp = await client.get(url, headers={"User-Agent": "oll90-agent/3.0"})
        text = resp.text
        text = re.sub(
            r"<style[^>]*>.*?</style>", "", text, flags=re.DOTALL | re.IGNORECASE
        )
        text = re.sub(
            r"<script[^>]*>.*?</script>", "", text, flags=re.DOTALL | re.IGNORECASE
        )
        text = re.sub(r"<[^>]+>", "", text)
        text = html.unescape(text)
        text = re.sub(r"\n{3,}", "\n\n", text).strip()
        if len(text) > 25000:
            text = text[:25000] + "\n... [TRUNCATED at 25000 chars]"
        return ToolResult(
            output=f"URL: {url}\nStatus: {resp.status_code}\n\n{text}",
            success=(resp.status_code < 400),
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def http_request(
    method: str, url: str, headers: dict = None, body: str = None
) -> ToolResult:
    """Full HTTP client — GET/POST/PUT/DELETE/PATCH with headers and body."""
    start = time.time()
    try:
        import httpx

        method = method.upper()
        if method not in ("GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"):
            return ToolResult(
                output="",
                stderr=f"Invalid HTTP method: {method}",
                success=False,
                duration_ms=0,
            )

        req_headers = {"User-Agent": "oll90-agent/3.0"}
        if headers:
            req_headers.update(headers)

        async with httpx.AsyncClient(follow_redirects=True, timeout=30) as client:
            resp = await client.request(
                method,
                url,
                headers=req_headers,
                content=body.encode("utf-8") if body else None,
            )

        resp_body = resp.text
        if len(resp_body) > MAX_OUTPUT_CHARS:
            resp_body = resp_body[:MAX_OUTPUT_CHARS] + "\n... [TRUNCATED]"

        resp_headers = dict(resp.headers)
        output = (
            f"HTTP {method} {url}\n"
            f"Status: {resp.status_code}\n"
            f"Headers: {json_mod.dumps(resp_headers, indent=2)[:2000]}\n\n"
            f"Body:\n{resp_body}"
        )
        return ToolResult(
            output=output,
            success=(resp.status_code < 400),
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


# Tool dispatch map — 16 tools
async def get_current_datetime() -> ToolResult:
    """Return current date, time, day-of-week, UTC offset."""
    from datetime import datetime, timezone
    import time as _time

    now_local = datetime.now()
    now_utc = datetime.now(timezone.utc)
    offset_hrs = round(
        (now_local - now_utc.replace(tzinfo=None)).total_seconds() / 3600, 1
    )
    sign = "+" if offset_hrs >= 0 else ""
    output = (
        f"DateTime: {now_local.strftime('%Y-%m-%d %H:%M:%S')}\n"
        f"Day: {now_local.strftime('%A')}\n"
        f"UTC: {now_utc.strftime('%Y-%m-%d %H:%M:%S')} UTC\n"
        f"Local offset: UTC{sign}{offset_hrs}\n"
        f"Unix timestamp: {int(_time.time())}"
    )
    return ToolResult(output=output, success=True)


async def search_news(query: str, max_results: int = 8) -> ToolResult:
    """Search for recent news via DuckDuckGo News. Returns titles, snippets, URLs, dates."""
    start = time.time()
    try:
        import httpx
        import urllib.parse

        encoded = urllib.parse.quote_plus(query)
        url = f"https://html.duckduckgo.com/html/?q={encoded}&iar=news&ia=news"
        async with httpx.AsyncClient(follow_redirects=True, timeout=20) as client:
            resp = await client.get(
                url,
                headers={
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0"
                },
            )
        text = resp.text
        results = []
        title_matches = re.findall(
            r'class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>', text, re.DOTALL
        )
        snippet_matches = re.findall(
            r'class="result__snippet"[^>]*>(.*?)</span>', text, re.DOTALL
        )
        date_matches = re.findall(
            r'class="result__timestamp"[^>]*>(.*?)</span>', text, re.DOTALL
        )
        for i, (url_raw, title_raw) in enumerate(title_matches[:max_results]):
            title = re.sub(r"<[^>]+>", "", title_raw).strip()
            snippet = (
                re.sub(r"<[^>]+>", "", snippet_matches[i]).strip()
                if i < len(snippet_matches)
                else ""
            )
            date_str = (
                re.sub(r"<[^>]+>", "", date_matches[i]).strip()
                if i < len(date_matches)
                else ""
            )
            url_decoded = html.unescape(url_raw)
            if "uddg=" in url_decoded:
                m = re.search(r"uddg=([^&]+)", url_decoded)
                if m:
                    url_decoded = urllib.parse.unquote(m.group(1))
            line = f"{i + 1}. {title}"
            if date_str:
                line += f" [{date_str}]"
            line += f"\n   {snippet}\n   {url_decoded}"
            results.append(line)
        if not results:
            # Fallback: regular search with "news" appended
            return await web_search(query + " news latest", max_results)
        output = f"News search: {query}\n{len(results)} results:\n\n" + "\n\n".join(
            results
        )
        return ToolResult(
            output=output, success=True, duration_ms=int((time.time() - start) * 1000)
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def web_fetch_json(url: str) -> ToolResult:
    """Fetch a URL and parse as JSON. Returns pretty-printed JSON or raw text fallback."""
    start = time.time()
    try:
        import httpx

        async with httpx.AsyncClient(follow_redirects=True, timeout=15) as client:
            resp = await client.get(
                url,
                headers={
                    "User-Agent": "oll90-agent/3.0",
                    "Accept": "application/json, text/plain, */*",
                },
            )
        try:
            data = resp.json()
            text = json_mod.dumps(data, indent=2, ensure_ascii=False)
        except Exception:
            text = resp.text
        if len(text) > MAX_OUTPUT_CHARS:
            text = text[:MAX_OUTPUT_CHARS] + "\n... [TRUNCATED]"
        output = f"URL: {url}\nStatus: {resp.status_code}\nContent-Type: {resp.headers.get('content-type', '?')}\n\n{text}"
        return ToolResult(
            output=output,
            success=(resp.status_code < 400),
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def dns_lookup(hostname: str) -> ToolResult:
    """DNS lookup — resolve hostname to IPs, get all address records."""
    start = time.time()
    try:
        import socket

        try:
            hostname_clean = (
                hostname.replace("https://", "").replace("http://", "").split("/")[0]
            )
            results = socket.getaddrinfo(hostname_clean, None)
            ips = sorted(set(r[4][0] for r in results))
            canonical = socket.getfqdn(hostname_clean)
            output = (
                f"Host: {hostname_clean}\nCanonical: {canonical}\nIPs: {', '.join(ips)}"
            )
        except socket.gaierror as e:
            return ToolResult(
                output="",
                stderr=f"DNS resolution failed: {e}",
                success=False,
                duration_ms=int((time.time() - start) * 1000),
            )
        return ToolResult(
            output=output, success=True, duration_ms=int((time.time() - start) * 1000)
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def port_check(host: str, port: int, timeout_sec: float = 3.0) -> ToolResult:
    """Check if a TCP port is open on a host. Returns open/closed + latency."""
    start = time.time()
    try:
        import socket as _sock

        host_clean = host.replace("https://", "").replace("http://", "").split("/")[0]
        s = _sock.socket(_sock.AF_INET, _sock.SOCK_STREAM)
        s.settimeout(timeout_sec)
        t0 = time.time()
        result = s.connect_ex((host_clean, int(port)))
        latency_ms = round((time.time() - t0) * 1000, 1)
        s.close()
        if result == 0:
            output = f"Port {host_clean}:{port} OPEN (latency {latency_ms}ms)"
            success = True
        else:
            output = f"Port {host_clean}:{port} CLOSED or FILTERED (errno {result})"
            success = False
        return ToolResult(
            output=output,
            success=success,
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def network_ping(host: str, count: int = 4) -> ToolResult:
    """Ping a host using PowerShell Test-Connection. Returns RTT stats."""
    host_clean = host.replace("https://", "").replace("http://", "").split("/")[0]
    count = min(max(1, count), 10)
    cmd = (
        f'$r = Test-Connection -ComputerName "{host_clean}" -Count {count} -ErrorAction SilentlyContinue; '
        f"if ($r) {{ "
        f"  $avg = [math]::Round(($r | Measure-Object -Property ResponseTime -Average).Average, 1); "
        f"  $min = ($r | Measure-Object -Property ResponseTime -Minimum).Minimum; "
        f"  $max = ($r | Measure-Object -Property ResponseTime -Maximum).Maximum; "
        f'  Write-Output ("Host: {host_clean}"); '
        f'  Write-Output ("Packets: sent={count} received=" + $r.Count + " lost=" + ({count} - $r.Count)); '
        f'  Write-Output ("RTT ms: min=" + $min + " avg=" + $avg + " max=" + $max) '
        f'}} else {{ Write-Output "PING FAILED: host unreachable or blocked" }}'
    )
    return await run_powershell(cmd)


async def rss_fetch(url: str, max_items: int = 10) -> ToolResult:
    """Fetch and parse an RSS/Atom feed. Returns titles, dates, links, summaries."""
    start = time.time()
    try:
        import httpx

        async with httpx.AsyncClient(follow_redirects=True, timeout=15) as client:
            resp = await client.get(url, headers={"User-Agent": "oll90-agent/3.0"})
        xml = resp.text
        # Parse RSS items
        items = []
        # Try RSS 2.0 format
        item_blocks = re.findall(
            r"<item[^>]*>(.*?)</item>", xml, re.DOTALL | re.IGNORECASE
        )
        if not item_blocks:
            # Try Atom format
            item_blocks = re.findall(
                r"<entry[^>]*>(.*?)</entry>", xml, re.DOTALL | re.IGNORECASE
            )
        for block in item_blocks[:max_items]:

            def tag(name):
                m = re.search(
                    rf"<{name}[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</{name}>",
                    block,
                    re.DOTALL | re.IGNORECASE,
                )
                return re.sub(r"<[^>]+>", "", m.group(1)).strip() if m else ""

            title = tag("title")
            link_m = re.search(
                r'<link[^>]*href=["\']([^"\']+)["\']', block
            ) or re.search(r"<link[^>]*>(.*?)</link>", block, re.DOTALL)
            link = link_m.group(1).strip() if link_m else ""
            pub_date = tag("pubDate") or tag("published") or tag("updated")
            description = tag("description") or tag("summary") or tag("content")
            if len(description) > 200:
                description = description[:200] + "..."
            entry = f"- {title}"
            if pub_date:
                entry += f" [{pub_date}]"
            if link:
                entry += f"\n  {link}"
            if description:
                entry += f"\n  {description}"
            items.append(entry)
        if not items:
            return ToolResult(
                output=f"No items found in feed: {url}\nRaw (first 1000 chars):\n{xml[:1000]}",
                success=False,
                duration_ms=int((time.time() - start) * 1000),
            )
        # Feed title
        feed_title_m = re.search(
            r"<title[^>]*>(.*?)</title>", xml, re.DOTALL | re.IGNORECASE
        )
        feed_title = (
            re.sub(r"<[^>]+>", "", feed_title_m.group(1)).strip()
            if feed_title_m
            else url
        )
        output = (
            f"Feed: {feed_title}\nURL: {url}\n{len(items)} items:\n\n"
            + "\n\n".join(items)
        )
        return ToolResult(
            output=output, success=True, duration_ms=int((time.time() - start) * 1000)
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


async def open_browser(url: str, new_tab: bool = True) -> ToolResult:
    """Open a URL in Google Chrome. Opens new tab by default, or new window if new_tab=false."""
    start = time.time()
    chrome_path = r"C:\Program Files\Google\Chrome\Application\chrome.exe"

    if not os.path.isfile(chrome_path):
        return ToolResult(
            output="",
            stderr=f"Chrome not found at {chrome_path}. Try Firefox or Edge instead.",
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )

    try:
        if not url.startswith("http://") and not url.startswith("https://"):
            url = "https://" + url

        args = [f"--start-maximized"]
        if new_tab:
            args.append("--new-tab")

        args.append(url)

        proc = subprocess.Popen([chrome_path] + args, creationflags=0x08000000)

        return ToolResult(
            output=f"Opened Chrome: {url} (PID: {proc.pid})",
            success=True,
            duration_ms=int((time.time() - start) * 1000),
        )
    except Exception as e:
        return ToolResult(
            output="",
            stderr=str(e),
            success=False,
            duration_ms=int((time.time() - start) * 1000),
        )


# ── NEW TOOLS (30 additions) ──────────────────────────────────────────────


async def clipboard_read() -> ToolResult:
    """Read text from the Windows clipboard."""
    cmd = "Get-Clipboard"
    return await run_powershell(cmd)


async def clipboard_write(text: str) -> ToolResult:
    """Write text to the Windows clipboard."""
    escaped = text.replace("'", "''")
    cmd = f"Set-Clipboard -Value '{escaped}'; Write-Output 'Clipboard set'"
    return await run_powershell(cmd)


async def network_info(action: str = "interfaces") -> ToolResult:
    """Get network info. Actions: interfaces, connections, dns."""
    cmds = {
        "interfaces": "Get-NetAdapter | Select-Object Name,Status,MacAddress,LinkSpeed | Format-Table -AutoSize | Out-String -Width 200",
        "connections": "Get-NetTCPConnection -State Established | Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,OwningProcess -First 30 | Format-Table -AutoSize | Out-String -Width 200",
        "dns": "Get-DnsClientServerAddress | Where-Object { $_.ServerAddresses } | Select-Object InterfaceAlias,ServerAddresses | Format-Table -AutoSize | Out-String -Width 200",
    }
    cmd = cmds.get(action, cmds["interfaces"])
    return await run_powershell(cmd)


async def hash_file(path: str, algorithm: str = "SHA256") -> ToolResult:
    """Compute file hash. Algorithms: MD5, SHA256, SHA512."""
    start = time.time()
    path = _expand_env_vars(path)
    algo = algorithm.upper()
    if algo not in ("MD5", "SHA256", "SHA512", "SHA1"):
        algo = "SHA256"
    try:
        import hashlib
        h = hashlib.new(algo.replace("SHA", "sha").replace("MD5", "md5").replace("sha", "sha"))
        # Use hashlib directly
        ha = hashlib.new(algo.lower() if algo == "MD5" else f"sha{algo[3:]}" if algo.startswith("SHA") else algo.lower())
        with open(path, "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                ha.update(chunk)
        digest = ha.hexdigest()
        size = os.path.getsize(path)
        return ToolResult(
            output=f"File: {path}\nSize: {size} bytes\n{algo}: {digest}",
            success=True, duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return ToolResult(output="", stderr=str(e), success=False,
                          duration_ms=int((time.time() - start) * 1000))


async def event_log(log_name: str = "System", count: int = 20) -> ToolResult:
    """Read Windows Event Log entries."""
    count = min(max(1, count), 100)
    cmd = (
        f"Get-EventLog -LogName {log_name} -Newest {count} "
        f"| Select-Object TimeGenerated,EntryType,Source,Message "
        f"| Format-Table -AutoSize -Wrap | Out-String -Width 300"
    )
    return await run_powershell(cmd)


async def git_command(command: str, repo_path: str = ".") -> ToolResult:
    """Run a git command in a specified directory."""
    start = time.time()
    repo_path = _expand_env_vars(repo_path)
    try:
        proc = subprocess.run(
            ["git"] + command.split(),
            capture_output=True, timeout=60, cwd=repo_path,
            creationflags=0x08000000)
        stdout = proc.stdout.decode("utf-8", errors="replace") if proc.stdout else ""
        stderr = proc.stderr.decode("utf-8", errors="replace") if proc.stderr else ""
        if len(stdout) > MAX_OUTPUT_CHARS:
            stdout = stdout[:MAX_OUTPUT_CHARS] + "\n... [TRUNCATED]"
        return ToolResult(output=stdout, stderr=stderr,
                          success=(proc.returncode == 0),
                          duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return ToolResult(output="", stderr=str(e), success=False,
                          duration_ms=int((time.time() - start) * 1000))


async def process_manager(action: str = "list", name: str = "", pid: int = 0) -> ToolResult:
    """List/kill/start processes. Actions: list, kill, start."""
    if action == "kill":
        if pid:
            cmd = f"Stop-Process -Id {pid} -Force -ErrorAction SilentlyContinue; Write-Output 'Killed PID {pid}'"
        elif name:
            cmd = f"Stop-Process -Name '{name}' -Force -ErrorAction SilentlyContinue; Write-Output 'Killed {name}'"
        else:
            return ToolResult(output="", stderr="Need name or pid to kill", success=False)
        return await run_powershell(cmd)
    elif action == "start":
        if not name:
            return ToolResult(output="", stderr="Need name/path to start", success=False)
        cmd = f"Start-Process '{name}' -PassThru | Select-Object Id,ProcessName"
        return await run_powershell(cmd)
    else:
        cmd = ("Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 30 "
               "Id,ProcessName,@{{N='MemMB';E={{[math]::Round($_.WorkingSet64/1MB,1)}}}},CPU "
               "| Format-Table -AutoSize | Out-String -Width 200")
        return await run_powershell(cmd)


async def service_control(action: str = "list", name: str = "") -> ToolResult:
    """List/start/stop/restart Windows services."""
    if action in ("start", "stop", "restart") and name:
        cmd = f"{action.capitalize()}-Service -Name '{name}' -Force -ErrorAction SilentlyContinue; Get-Service '{name}' | Select-Object Name,Status"
        if action == "restart":
            cmd = f"Restart-Service -Name '{name}' -Force -ErrorAction SilentlyContinue; Get-Service '{name}' | Select-Object Name,Status"
        return await run_powershell(cmd)
    else:
        cmd = ("Get-Service | Where-Object {{ $_.Status -eq 'Running' }} "
               "| Select-Object Name,DisplayName,Status | Sort-Object DisplayName "
               "| Format-Table -AutoSize | Out-String -Width 200")
        return await run_powershell(cmd)


async def compress_files(source: str, destination: str) -> ToolResult:
    """Create ZIP archive from a file or directory."""
    source = _expand_env_vars(source)
    destination = _expand_env_vars(destination)
    cmd = f"Compress-Archive -Path '{source}' -DestinationPath '{destination}' -Force; Write-Output 'Created: {destination}'"
    return await run_powershell(cmd)


async def extract_archive(source: str, destination: str) -> ToolResult:
    """Extract a ZIP archive to a directory."""
    source = _expand_env_vars(source)
    destination = _expand_env_vars(destination)
    cmd = f"Expand-Archive -Path '{source}' -DestinationPath '{destination}' -Force; Write-Output 'Extracted to: {destination}'"
    return await run_powershell(cmd)


async def json_transform(json_text: str, expression: str) -> ToolResult:
    """Query/transform JSON data with a Python expression. Variable 'data' holds parsed JSON."""
    start = time.time()
    try:
        data = json_mod.loads(json_text)
        result = eval(expression, {"data": data, "json": json_mod, "len": len, "sorted": sorted, "list": list, "dict": dict, "str": str, "int": int, "float": float})
        output = json_mod.dumps(result, indent=2, ensure_ascii=False) if isinstance(result, (dict, list)) else str(result)
        return ToolResult(output=output, success=True, duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return ToolResult(output="", stderr=str(e), success=False,
                          duration_ms=int((time.time() - start) * 1000))


async def speak(text: str) -> ToolResult:
    """Text-to-speech via Windows System.Speech."""
    escaped = text.replace("'", "''")
    cmd = f"Add-Type -AssemblyName System.Speech; $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; $s.Speak('{escaped}'); Write-Output 'Spoken'"
    return await run_powershell(cmd)


async def notify(title: str, message: str) -> ToolResult:
    """Windows balloon toast notification."""
    title_esc = title.replace("'", "''")
    msg_esc = message.replace("'", "''")
    cmd = (
        "Add-Type -AssemblyName System.Windows.Forms; "
        "$n = New-Object System.Windows.Forms.NotifyIcon; "
        "$n.Icon = [System.Drawing.SystemIcons]::Information; "
        "$n.Visible = $true; "
        f"$n.ShowBalloonTip(5000, '{title_esc}', '{msg_esc}', 'Info'); "
        "Start-Sleep -Seconds 3; $n.Dispose(); Write-Output 'Notification sent'"
    )
    return await run_powershell(cmd)


async def screenshot(path: str = "") -> ToolResult:
    """Capture desktop screenshot to PNG."""
    if not path:
        path = os.path.join(_get_temp_dir(), f"screenshot_{uuid.uuid4().hex[:8]}.png")
    path = _expand_env_vars(path)
    cmd = (
        "Add-Type -AssemblyName System.Windows.Forms; "
        "Add-Type -AssemblyName System.Drawing; "
        "$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; "
        "$bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height); "
        "$g = [System.Drawing.Graphics]::FromImage($bmp); "
        "$g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size); "
        f"$bmp.Save('{path}', [System.Drawing.Imaging.ImageFormat]::Png); "
        "$g.Dispose(); $bmp.Dispose(); "
        f"Write-Output 'Screenshot saved: {path}'"
    )
    return await run_powershell(cmd)


async def scheduled_task(action: str = "list", name: str = "") -> ToolResult:
    """List/run/delete Windows scheduled tasks."""
    if action == "run" and name:
        cmd = f"Start-ScheduledTask -TaskName '{name}'; Write-Output 'Started: {name}'"
    elif action == "delete" and name:
        cmd = f"Unregister-ScheduledTask -TaskName '{name}' -Confirm:$false; Write-Output 'Deleted: {name}'"
    else:
        cmd = "Get-ScheduledTask | Where-Object {{ $_.State -ne 'Disabled' }} | Select-Object TaskName,State,TaskPath -First 40 | Format-Table -AutoSize | Out-String -Width 200"
    return await run_powershell(cmd)


async def traceroute(host: str, max_hops: int = 15) -> ToolResult:
    """Trace network route to a host."""
    host_clean = host.replace("https://", "").replace("http://", "").split("/")[0]
    max_hops = min(max(1, max_hops), 30)
    cmd = f"Test-NetConnection -ComputerName '{host_clean}' -TraceRoute -Hops {max_hops} | Select-Object -ExpandProperty TraceRoute"
    return await run_powershell(cmd)


async def whois_lookup(domain: str) -> ToolResult:
    """WHOIS lookup for a domain via web API."""
    start = time.time()
    try:
        import httpx
        async with httpx.AsyncClient(follow_redirects=True, timeout=15) as client:
            resp = await client.get(f"https://whois.freeaitools.casa/?domain={domain}",
                                     headers={"User-Agent": "oll90-agent/3.0"})
        text = resp.text
        text = re.sub(r"<[^>]+>", "", text)
        text = re.sub(r"\n{3,}", "\n\n", text).strip()
        if len(text) > 5000:
            text = text[:5000] + "\n... [TRUNCATED]"
        if not text or len(text) < 50:
            # Fallback to PowerShell whois
            return await run_powershell(f"nslookup {domain}")
        return ToolResult(output=f"WHOIS: {domain}\n\n{text}", success=True,
                          duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return await run_powershell(f"nslookup {domain}")


async def ssl_cert_info(hostname: str) -> ToolResult:
    """Get SSL certificate details for a domain."""
    hostname = hostname.replace("https://", "").replace("http://", "").split("/")[0]
    start = time.time()
    try:
        import ssl
        import socket
        ctx = ssl.create_default_context()
        with ctx.wrap_socket(socket.socket(), server_hostname=hostname) as s:
            s.settimeout(10)
            s.connect((hostname, 443))
            cert = s.getpeercert()
        lines = []
        lines.append(f"Host: {hostname}")
        lines.append(f"Subject: {dict(x[0] for x in cert.get('subject', []))}")
        lines.append(f"Issuer: {dict(x[0] for x in cert.get('issuer', []))}")
        lines.append(f"Valid from: {cert.get('notBefore', '?')}")
        lines.append(f"Valid until: {cert.get('notAfter', '?')}")
        lines.append(f"Serial: {cert.get('serialNumber', '?')}")
        sans = cert.get('subjectAltName', [])
        if sans:
            lines.append(f"SANs: {', '.join(v for _, v in sans[:10])}")
        return ToolResult(output="\n".join(lines), success=True,
                          duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return ToolResult(output="", stderr=str(e), success=False,
                          duration_ms=int((time.time() - start) * 1000))


async def ip_geolocation(ip: str = "") -> ToolResult:
    """Get geolocation info for an IP address (or your own IP if empty)."""
    start = time.time()
    try:
        import httpx
        url = f"http://ip-api.com/json/{ip}" if ip else "http://ip-api.com/json/"
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(url)
        data = resp.json()
        lines = [f"{k}: {v}" for k, v in data.items()]
        return ToolResult(output="\n".join(lines), success=True,
                          duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return ToolResult(output="", stderr=str(e), success=False,
                          duration_ms=int((time.time() - start) * 1000))


async def speed_test() -> ToolResult:
    """Quick download speed test (~10MB file)."""
    start = time.time()
    try:
        import httpx
        url = "http://speedtest.tele2.net/10MB.zip"
        t0 = time.time()
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.get(url)
        elapsed = time.time() - t0
        size_mb = len(resp.content) / 1_048_576
        speed_mbps = (size_mb * 8) / elapsed if elapsed > 0 else 0
        return ToolResult(
            output=f"Downloaded {size_mb:.1f} MB in {elapsed:.1f}s\nSpeed: {speed_mbps:.1f} Mbps",
            success=True, duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return ToolResult(output="", stderr=str(e), success=False,
                          duration_ms=int((time.time() - start) * 1000))


async def wifi_info() -> ToolResult:
    """Get WiFi profile, signal strength, and connection info."""
    cmd = "netsh wlan show interfaces"
    return await run_powershell(cmd)


async def url_shorten(url: str) -> ToolResult:
    """Shorten a URL via is.gd API."""
    start = time.time()
    try:
        import httpx
        import urllib.parse
        encoded = urllib.parse.quote(url, safe="")
        api_url = f"https://is.gd/create.php?format=simple&url={encoded}"
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(api_url)
        short = resp.text.strip()
        return ToolResult(output=f"Original: {url}\nShort: {short}", success=True,
                          duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return ToolResult(output="", stderr=str(e), success=False,
                          duration_ms=int((time.time() - start) * 1000))


async def base64_tool(action: str = "encode", text: str = "") -> ToolResult:
    """Encode or decode base64 strings."""
    start = time.time()
    import base64
    try:
        if action == "decode":
            result = base64.b64decode(text).decode("utf-8", errors="replace")
        else:
            result = base64.b64encode(text.encode("utf-8")).decode("ascii")
        return ToolResult(output=result, success=True,
                          duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return ToolResult(output="", stderr=str(e), success=False,
                          duration_ms=int((time.time() - start) * 1000))


async def regex_test(pattern: str, text: str, flags: str = "") -> ToolResult:
    """Test a regex pattern against text. Returns all matches."""
    start = time.time()
    try:
        re_flags = 0
        if "i" in flags:
            re_flags |= re.IGNORECASE
        if "m" in flags:
            re_flags |= re.MULTILINE
        if "s" in flags:
            re_flags |= re.DOTALL
        matches = list(re.finditer(pattern, text, re_flags))
        lines = [f"Pattern: /{pattern}/{''.join(flags)}",
                 f"Text length: {len(text)} chars",
                 f"Matches: {len(matches)}"]
        for i, m in enumerate(matches[:20]):
            groups = m.groups()
            line = f"  [{i}] pos {m.start()}-{m.end()}: {repr(m.group())}"
            if groups:
                line += f" groups={groups}"
            lines.append(line)
        return ToolResult(output="\n".join(lines), success=True,
                          duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return ToolResult(output="", stderr=str(e), success=False,
                          duration_ms=int((time.time() - start) * 1000))


async def env_var(action: str = "list", name: str = "", value: str = "") -> ToolResult:
    """Get/set/list environment variables."""
    if action == "set" and name:
        os.environ[name] = value
        return ToolResult(output=f"Set {name}={value}", success=True)
    elif action == "get" and name:
        val = os.environ.get(name, "[not set]")
        return ToolResult(output=f"{name}={val}", success=True)
    else:
        lines = [f"{k}={v}" for k, v in sorted(os.environ.items())]
        output = "\n".join(lines)
        if len(output) > MAX_OUTPUT_CHARS:
            output = output[:MAX_OUTPUT_CHARS] + "\n... [TRUNCATED]"
        return ToolResult(output=output, success=True)


async def registry_query(key_path: str, value_name: str = "") -> ToolResult:
    """Read Windows registry key or value."""
    if value_name:
        cmd = f"Get-ItemProperty -Path 'Registry::{key_path}' -Name '{value_name}' | Select-Object -ExpandProperty '{value_name}'"
    else:
        cmd = f"Get-ItemProperty -Path 'Registry::{key_path}' | Format-List | Out-String -Width 200"
    return await run_powershell(cmd)


async def disk_usage(path: str) -> ToolResult:
    """Get disk usage for a directory tree (top-level subdirs)."""
    path = _expand_env_vars(path)
    cmd = (
        f"Get-ChildItem '{path}' -Directory -ErrorAction SilentlyContinue | "
        "ForEach-Object { $size = (Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue | "
        "Measure-Object -Property Length -Sum).Sum; "
        "[PSCustomObject]@{Name=$_.Name; SizeMB=[math]::Round($size/1MB,1)} } | "
        "Sort-Object SizeMB -Descending | Format-Table -AutoSize | Out-String -Width 200"
    )
    return await run_powershell(cmd)


async def firewall_status() -> ToolResult:
    """Check Windows Firewall status for all profiles."""
    cmd = "Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction | Format-Table -AutoSize | Out-String -Width 200"
    return await run_powershell(cmd)


async def web_screenshot(url: str, path: str = "") -> ToolResult:
    """Take a screenshot of a webpage using headless Chrome."""
    if not path:
        path = os.path.join(_get_temp_dir(), f"webshot_{uuid.uuid4().hex[:8]}.png")
    path = _expand_env_vars(path)
    chrome_path = r"C:\Program Files\Google\Chrome\Application\chrome.exe"
    if not os.path.isfile(chrome_path):
        return ToolResult(output="", stderr="Chrome not found", success=False)
    start = time.time()
    try:
        if not url.startswith("http"):
            url = "https://" + url
        proc = subprocess.run(
            [chrome_path, "--headless", "--disable-gpu", f"--screenshot={path}",
             "--window-size=1920,1080", "--no-sandbox", url],
            capture_output=True, timeout=30, creationflags=0x08000000)
        if os.path.isfile(path):
            size = os.path.getsize(path)
            return ToolResult(output=f"Screenshot saved: {path} ({size} bytes)",
                              success=True, duration_ms=int((time.time() - start) * 1000))
        stderr = proc.stderr.decode("utf-8", errors="replace") if proc.stderr else "Unknown error"
        return ToolResult(output="", stderr=stderr, success=False,
                          duration_ms=int((time.time() - start) * 1000))
    except Exception as e:
        return ToolResult(output="", stderr=str(e), success=False,
                          duration_ms=int((time.time() - start) * 1000))


# Tool dispatch map — 54 tools
TOOL_MAP = {
    "run_powershell": run_powershell,
    "run_cmd": run_cmd,
    "run_python": run_python,
    "write_file": write_file,
    "read_file": read_file,
    "edit_file": edit_file,
    "create_directory": create_directory,
    "move_file": move_file,
    "delete_file": delete_file,
    "list_directory": list_directory,
    "search_files": search_files,
    "get_system_info": get_system_info,
    "get_current_datetime": get_current_datetime,
    "web_search": web_search,
    "search_news": search_news,
    "web_fetch": web_fetch,
    "web_fetch_json": web_fetch_json,
    "http_request": http_request,
    "download_file": download_file,
    "dns_lookup": dns_lookup,
    "port_check": port_check,
    "network_ping": network_ping,
    "rss_fetch": rss_fetch,
    "open_browser": open_browser,
    "clipboard_read": clipboard_read,
    "clipboard_write": clipboard_write,
    "network_info": network_info,
    "hash_file": hash_file,
    "event_log": event_log,
    "git_command": git_command,
    "process_manager": process_manager,
    "service_control": service_control,
    "compress_files": compress_files,
    "extract_archive": extract_archive,
    "json_transform": json_transform,
    "speak": speak,
    "notify": notify,
    "screenshot": screenshot,
    "scheduled_task": scheduled_task,
    "traceroute": traceroute,
    "whois_lookup": whois_lookup,
    "ssl_cert_info": ssl_cert_info,
    "ip_geolocation": ip_geolocation,
    "speed_test": speed_test,
    "wifi_info": wifi_info,
    "url_shorten": url_shorten,
    "base64_tool": base64_tool,
    "regex_test": regex_test,
    "env_var": env_var,
    "registry_query": registry_query,
    "disk_usage": disk_usage,
    "firewall_status": firewall_status,
    "web_screenshot": web_screenshot,
}


async def execute_tool(name: str, args: dict) -> ToolResult:
    """Dispatch a tool call by name."""
    func = TOOL_MAP.get(name)
    if not func:
        return ToolResult(output="", stderr=f"Unknown tool: {name}", success=False)

    try:
        return await func(**args)
    except TypeError as e:
        return ToolResult(
            output="", stderr=f"Invalid arguments for {name}: {e}", success=False
        )
