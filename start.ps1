# oll90 Consolidated Launcher
# Self-contained: kills stale ollama, sets env vars, copies Modelfile, starts serve,
# health-checks, builds model if needed, warms up, then dispatches -Web or terminal agent.
# Profile oll90 function is a thin wrapper that calls this script.
param(
    [switch]$Web,
    [string]$Prompt = ""
)

$ErrorActionPreference = 'Continue'
$ROOT = 'F:\study\AI_ML\AI_and_Machine_Learning\Artificial_Intelligence\cli\claudecode\ollama-setup'
$MODELFILE_SRC = Join-Path $ROOT 'Modelfile.oll90'
$AGENT_SCRIPT  = Join-Path $ROOT 'oll90-agent.ps1'
$WEB_SCRIPT    = Join-Path $ROOT 'oll90-ui\interactive\app\scripts\start.ps1'
$MODEL_NAME    = 'qwen3-14b-oll90'

function Write-Step([string]$msg, [string]$color = 'Cyan') {
    Write-Host "[oll90] $msg" -ForegroundColor $color
}

# ===========================================================================
# STEP 1: KILL STALE OLLAMA PROCESSES
# Env vars ONLY apply when ollama starts fresh - must kill first
# ===========================================================================
Write-Step 'Stopping existing ollama processes...' 'Yellow'
$ollamaProcs = Get-Process -Name 'ollama' -ErrorAction SilentlyContinue
if ($ollamaProcs) {
    $ollamaProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 1000
    Write-Step "Killed $($ollamaProcs.Count) stale ollama process(es)" 'Yellow'
} else {
    Write-Step 'No stale ollama processes found' 'DarkGray'
}

# ===========================================================================
# STEP 2: SET ALL ENVIRONMENT VARIABLES (must be before starting ollama serve)
# GPU: RTX 5080, q4_0 KV cache (halves KV memory vs f16), 131072 ctx
# num_batch stays at 2048 (Ollama 0.20.2 GGML pool limit hit at 4096 for this model)
# ===========================================================================
Write-Step 'Configuring environment variables...' 'Yellow'

$env:CUDA_VISIBLE_DEVICES     = '0'
$env:OLLAMA_NUM_GPU           = '999'
$env:OLLAMA_GPU_OVERHEAD      = '0'
$env:OLLAMA_KV_CACHE_TYPE     = 'q4_0'     # halves KV memory vs q8_0
$env:OLLAMA_CONTEXT_LENGTH    = '32768'    # 32K tokens - saves ~3GB VRAM vs 64K, keeps 100% GPU layers
$env:OLLAMA_NUM_PARALLEL      = '1'
$env:OLLAMA_BATCH_SIZE        = '2048'     # 4096 hits GGML pool limit (needs 368 bytes more)
$env:OLLAMA_FLASH_ATTENTION   = '1'
$env:OLLAMA_MMAP              = '1'
$env:OLLAMA_MLOCK             = '0'
$env:OLLAMA_LLM_LIBRARY       = 'cuda_v12'
$env:OLLAMA_MAX_LOADED_MODELS = '1'
$env:OLLAMA_BASE_URL          = 'http://localhost:11434'

Write-Step 'Env set: GPU=0 LAYERS=999 CTX=32768 KV=q4_0 BATCH=2048 FA=1' 'Green'

# ===========================================================================
# STEP 3: COPY MODELFILE TO C:\TEMP (fixes "no Modelfile found" error)
# ollama create requires Modelfile accessible from working dir.
# Copying here ensures it is always fresh and avoids colon-path issues.
# ===========================================================================
Write-Step 'Copying Modelfile to C:\Temp...' 'Yellow'
if (-not (Test-Path 'C:\Temp')) { New-Item -ItemType Directory -Path 'C:\Temp' | Out-Null }
try {
    Copy-Item $MODELFILE_SRC 'C:\Temp\Modelfile.oll90' -Force
    Write-Step 'Modelfile copied to C:\Temp\Modelfile.oll90' 'Green'
} catch {
    Write-Step "ERROR copying Modelfile: $_" 'Red'
    return
}

# ===========================================================================
# STEP 4: START OLLAMA SERVE IN BACKGROUND
# ===========================================================================
Write-Step 'Starting ollama serve...' 'Yellow'
$ollamaExe = Get-Command 'ollama' -ErrorAction SilentlyContinue
if (-not $ollamaExe) {
    Write-Step 'ERROR: ollama not found in PATH. Install from https://ollama.com' 'Red'
    return
}
Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction Stop
Write-Step 'ollama serve launched (background)' 'DarkGray'

# ===========================================================================
# STEP 5: HEALTH CHECK LOOP (HTTP POLL /api/version)
# ===========================================================================
Write-Step 'Waiting for ollama API...' 'Yellow'
$maxWaitMs  = 30000
$pollMs     = 250
$elapsed    = 0
$ready      = $false

while ($elapsed -lt $maxWaitMs) {
    try {
        $r = Invoke-WebRequest -Uri 'http://127.0.0.1:11434/api/version' -Method GET -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
    Start-Sleep -Milliseconds $pollMs
    $elapsed += $pollMs
    if ($elapsed % 5000 -eq 0) { Write-Step "Still waiting... ($([int]($elapsed/1000))s)" 'DarkGray' }
}

if (-not $ready) {
    Write-Step 'ERROR: ollama API did not become ready within 30s' 'Red'
    return
}
Write-Step "ollama API ready in $([math]::Round($elapsed/1000,1))s" 'Green'

# ===========================================================================
# STEP 6: PULL BASE MODEL + BUILD qwen3.5-oll90 IF NOT PRESENT
# ===========================================================================
Write-Step "Checking for $MODEL_NAME..." 'Yellow'
try {
    $tags = (Invoke-WebRequest -Uri 'http://127.0.0.1:11434/api/tags' -Method GET -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop).Content | ConvertFrom-Json
    $present = $tags.models | Where-Object { $_.name -like "$MODEL_NAME*" }
} catch { $present = $null }

if ($present) {
    Write-Step "$MODEL_NAME already present - skipping build" 'Green'
} else {
    Write-Step 'Pulling qwen3:14b base model...' 'Yellow'
    & ollama pull qwen3:14b
    Write-Step "Building $MODEL_NAME from Modelfile..." 'Yellow'
    Set-Location 'C:\Temp'
    & ollama create $MODEL_NAME -f 'C:\Temp\Modelfile.oll90'
    if ($LASTEXITCODE -ne 0) {
        Write-Step "ERROR: Failed to create $MODEL_NAME (exit $LASTEXITCODE)" 'Red'
        return
    }
    Write-Step "$MODEL_NAME built successfully" 'Green'
}

# ===========================================================================
# STEP 7: WARM UP MODEL (LOADS WEIGHTS TO VRAM)
# ===========================================================================
Write-Step 'Warming up model (loading to VRAM)...' 'Yellow'
try {
    $warmBody = '{"model":"' + $MODEL_NAME + '","prompt":"hi","stream":false,"options":{"num_predict":1}}'
    $wr = Invoke-WebRequest -Uri 'http://127.0.0.1:11434/api/generate' -Method POST -Body $warmBody -ContentType 'application/json' -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop
    if ($wr.StatusCode -eq 200) { Write-Step 'Model warm - weights in VRAM' 'Green' }
} catch {
    Write-Step "Warmup failed (non-fatal): $_" 'DarkYellow'
}

# ===========================================================================
# STEP 8: DISPLAY CONFIG SUMMARY
# ===========================================================================
$vram = (nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>$null).Trim()
Write-Host ''
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host '  OLL90 v3 READY - 14B Upgrade, RTX 5080 Optimized'   -ForegroundColor Cyan
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host "  Model:      $MODEL_NAME (14B qwen3 Q4_K_M)"
Write-Host '  GPU Layers: 100% GPU, RTX 5080'
Write-Host "  VRAM Used:  ~$vram MiB / 16303 MiB"
Write-Host '  Context:    32768 tokens (32K) - saves ~3GB VRAM, 100% GPU speed'
Write-Host '  KV Cache:   q4_0 (halved memory vs q8_0)'
Write-Host '  Batch:      2048'
Write-Host '  Flash Attn: enabled'
Write-Host '  Tools:      16 (5 new: run_python, create_dir, move, delete, http_request)'
Write-Host '  Parallel:   1 (max throughput)'
Write-Host '======================================================' -ForegroundColor Cyan
Write-Host ''

# ===========================================================================
# STEP 9: DISPATCH â€” -Web or terminal agent
# ===========================================================================
if ($Web) {
    Write-Step 'Launching web UI (backend:8090 + frontend:3090)...' 'Green'
    if (Test-Path $WEB_SCRIPT) {
        & $WEB_SCRIPT
    } else {
        Write-Step "ERROR: Web script not found at $WEB_SCRIPT" 'Red'
    }
} else {
    Write-Step 'Launching autonomous terminal agent...' 'Green'
    if (Test-Path $AGENT_SCRIPT) {
        if ($Prompt -ne '') {
            & $AGENT_SCRIPT -InitialPrompt $Prompt
        } else {
            & $AGENT_SCRIPT
        }
    } else {
        Write-Step "Agent script not found at $AGENT_SCRIPT - falling back to interactive" 'Yellow'
        & ollama run $MODEL_NAME
    }
}
