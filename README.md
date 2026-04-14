# oll90 — Autonomous AI Agent for Windows 11

A fully local, autonomous AI agent running **qwen3.5** on your NVIDIA GPU.  
No API keys. No cloud. Full system access. Runs at ~105 tok/s on RTX 5080.

---

## One-Line Install

Open PowerShell and run:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; irm https://raw.githubusercontent.com/Michaelunkai/ollama-setup/main/install.ps1 | iex
```

Or clone and run manually:

```powershell
git clone https://github.com/Michaelunkai/ollama-setup.git C:\oll90
cd C:\oll90
powershell -ExecutionPolicy Bypass -File install.ps1
```

---

## What It Does

The installer automatically:

1. Checks your OS and GPU
2. Installs missing prerequisites (Git, Python 3.12, Node.js, Ollama, cloudflared) via winget
3. Clones the repo to `C:\oll90`
4. Sets Ollama environment variables for optimal GPU performance
5. Installs Python and Node.js dependencies
6. Pulls `qwen3.5:latest` (6.6 GB model)
7. Builds the custom `qwen3.5-oll90` model with 128K context
8. Creates a desktop shortcut and launch script

---

## Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| OS | Windows 10 | Windows 11 |
| GPU | NVIDIA 8 GB VRAM | RTX 4080/5080 16 GB |
| RAM | 16 GB | 32 GB |
| Disk | 15 GB free | 20 GB free |
| Python | 3.10+ | 3.12 |
| Node.js | 18+ | 20 LTS |

> CPU-only mode works but is very slow. A GPU with 8+ GB VRAM is strongly recommended.

---

## Launch

After install, start the web UI:

```powershell
powershell -ExecutionPolicy Bypass -File C:\oll90\launch.ps1
```

Or double-click the **oll90** shortcut on your Desktop.

This opens:
- **Local**: `http://localhost:3090`
- **Global URL**: printed in the terminal (e.g. `https://xxxx.trycloudflare.com`) — accessible from your phone or any device

---

## Features

### Web UI
- Terminal-style chat interface (React + Vite + TailwindCSS)
- **Sessions** — multiple named conversations with custom system prompts
- **Delete sessions** — click × next to any session
- **Clear context** — Clear button resets the current session's history
- **Cancel** — stop the agent mid-generation
- Real-time GPU stats (VRAM, temperature, utilization) in the top bar
- WebSocket streaming — tokens appear as the model generates

### Agent Capabilities (10 built-in tools)
| Tool | Description |
|------|-------------|
| `run_powershell` | Execute any PowerShell command |
| `run_cmd` | Execute CMD.exe commands |
| `write_file` | Create/overwrite files |
| `read_file` | Read file content |
| `edit_file` | Surgical text replacement |
| `list_directory` | Browse filesystem with sizes and dates |
| `search_files` | Regex search across directory trees |
| `get_system_info` | CPU, RAM, GPU, disk snapshot |
| `web_search` | Search the web via DuckDuckGo (no API key) |
| `web_fetch` | HTTP GET any URL, HTML stripped |

### Global Access
Every startup automatically creates a public cloudflare tunnel URL.  
Use it from your Android phone, tablet, or any browser anywhere.  
URL is saved to `C:\Temp\oll90-url.txt` each session.

### Model Config (verified optimal)
| Setting | Value |
|---------|-------|
| Model | qwen3.5:latest (9.7B Q4_K_M) |
| Context | 128K tokens |
| KV cache | q4_0 (halves VRAM vs q8_0) |
| Flash attention | enabled |
| Speed | ~105 tok/s on RTX 5080 |
| VRAM usage | ~12.7 GB at 128K context |

---

## Architecture

```
ollama-setup/
├── install.ps1                          # One-shot installer
├── launch.ps1                           # Generated at install time
├── Modelfile.oll90                      # Custom model definition
├── start.ps1                            # Terminal agent launcher
├── oll90-agent.ps1                      # CLI agent (PowerShell)
└── oll90-ui/interactive/app/
    ├── backend/                         # FastAPI (port 8090)
    │   ├── main.py
    │   ├── config.py
    │   ├── db.py                        # SQLite WAL sessions
    │   ├── routers/
    │   │   ├── sessions.py              # REST session management
    │   │   ├── ws.py                    # WebSocket agent loop
    │   │   └── status.py               # GPU/system status
    │   └── engine/
    │       ├── ollama_client.py         # Streaming + think-tag tracker
    │       ├── tool_executor.py         # 10 async tools
    │       ├── context_manager.py       # 128K context + compaction
    │       └── intelligence.py          # Error detection, loop guard
    ├── frontend/                        # React 19 + Vite 8 (port 3090)
    │   ├── src/
    │   │   ├── App.jsx
    │   │   ├── stores/                  # Zustand state
    │   │   ├── hooks/useWebSocket.js
    │   │   └── components/
    │   └── vite.config.js
    └── scripts/start.ps1                # Web UI launcher + cloudflared
```

---

## Manual Start (if needed)

If `launch.ps1` doesn't work, start manually:

```powershell
# Backend
cd C:\oll90\oll90-ui\interactive\app\backend
python main.py

# Frontend (new terminal)
cd C:\oll90\oll90-ui\interactive\app\frontend
npm run dev -- --port 3090 --host
```

---

## Update

To update to the latest version:

```powershell
cd C:\oll90
git pull origin main
powershell -ExecutionPolicy Bypass -File install.ps1
```

---

## Tested On

- Windows 11 Pro Build 26200
- RTX 5080 16 GB
- 32 GB RAM
- Python 3.12 / Node.js 22 / Ollama 0.20+

---

## License

MIT
