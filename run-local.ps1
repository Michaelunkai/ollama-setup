# run-local.ps1 - Launch Claude Code with LOCAL Ollama (CONFIRMED WORKING)
#
# KEY TECHNICAL DECISIONS (DO NOT REVERT WITHOUT TESTING):
#
# --bare: Claude Code full system prompt tells local models they have no
#   filesystem access. --bare replaces it with our focused prompt below.
#
# --tools "Bash,Read,Write,Edit,Glob,Grep": All 36 Claude Code tools exceed
#   local model context (4096 tokens). 6 core tools fit perfectly.
#   TESTED: qwen3.5:9b made 6 tool calls, listed real files, confirmed working.
#
# --dangerously-skip-permissions: Required so tools execute without blocking.
#
# Default model qwen3.5:9b: qwen3-coder uses 14.6GB of 16GB VRAM leaving
#   only 4096-token KV cache. qwen3.5:9b uses 6.6GB leaving 9.4GB for
#   context. Ollama officially recommends qwen3.5 for Claude Code.
#
# Cleans up ANTHROPIC env vars on exit so normal 'claude' never breaks.

param(
    [string]$Model = "glm-4.7-flash"
)

# --- Performance env vars (session only) ---
$env:OLLAMA_FLASH_ATTENTION   = "1"
$env:OLLAMA_KV_CACHE_TYPE     = "q8_0"
$env:OLLAMA_NUM_PARALLEL      = "1"
$env:OLLAMA_MAX_LOADED_MODELS = "1"
$env:OLLAMA_KEEP_ALIVE        = "60m"
$env:OLLAMA_GPU_OVERHEAD      = "268435456"
$env:CUDA_VISIBLE_DEVICES     = "0"
$env:OLLAMA_NUM_GPU           = "999"
$env:OLLAMA_MODELS            = "F:\backup\LocalAI\ollama\models"
$env:OLLAMA_HOME              = "F:\backup\LocalAI\ollama"

# --- Check Ollama is alive, start if needed ---
$ollamaUp = $false
try {
    Invoke-WebRequest -Uri "http://localhost:11434" -Method Head -TimeoutSec 3 -UseBasicParsing | Out-Null
    $ollamaUp = $true
} catch {}

if (-not $ollamaUp) {
    Write-Host "Ollama not running. Starting it..." -ForegroundColor Yellow
    $ollamaExe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    if (-not (Test-Path $ollamaExe)) {
        $ollamaExe = "$env:ProgramFiles\Ollama\ollama.exe"
    }
    if (Test-Path $ollamaExe) {
        $p = Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden -PassThru
        try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch {}
        Start-Sleep -Seconds 5
    } else {
        Write-Error "Cannot find ollama.exe. Run a.ps1 first."
        exit 1
    }
}

# --- Set Ollama process to High priority ---
$ollamaProc = Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ollamaProc) {
    try { $ollamaProc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch {}
}

$thisScript = $MyInvocation.MyCommand.Definition
Write-Host "" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Claude Code - LOCAL MODEL" -ForegroundColor Cyan
Write-Host "  Model: $Model" -ForegroundColor Green
Write-Host "  Tools: Bash,Read,Write,Edit,Glob,Grep" -ForegroundColor Yellow
Write-Host "  Script: $thisScript" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# --- Set ANTHROPIC env vars ---
$env:ANTHROPIC_AUTH_TOKEN = "ollama"
$env:ANTHROPIC_API_KEY = ""
$env:ANTHROPIC_BASE_URL = "http://localhost:11434"

# --- System prompt for local models running in Git Bash on Windows ---
# CRITICAL: The shell is Git Bash. Windows drive paths use /DRIVELETTER/ syntax:
#   F: drive = /f/   C: drive = /c/   E: drive = /e/
# NEVER use dir "F:\" (backslash escapes the quote in bash)
# For PowerShell commands: powershell.exe -Command "Get-ChildItem 'F:\' -Directory"
# --- Launch Claude Code with LOCAL model ---
# NO system prompt customization. Claude Code's default prompt handles everything.
# This is the correct approach: let Claude Code work as designed.
claude --model $Model @args

# --- CLEANUP: remove ANTHROPIC vars so normal 'claude' works after ---
Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
Remove-Item Env:\ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Local session ended. ANTHROPIC vars cleaned up." -ForegroundColor Green
Write-Host "Normal 'claude' command will work normally now." -ForegroundColor Green
