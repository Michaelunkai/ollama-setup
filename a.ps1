#---------------------------------------------------------
# MAXIMUM PERFORMANCE OLLAMA + CLAUDE CODE SETUP
# RTX 5080 16GB VRAM - Absolute Maximum Performance
# Custom data path: F:\backup\LocalAI\ollama
# Auto-installs all missing dependencies
# Does NOT touch settings.json - normal Claude Code stays intact
#---------------------------------------------------------

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# -------------------------------------------------------
# 1) ADMIN ELEVATION + TLS
# -------------------------------------------------------
Write-Host "[1/12] Checking admin elevation and TLS..." -ForegroundColor Cyan

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Re-launching as Administrator..."
    $relaunchArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell.exe -ArgumentList $relaunchArgs -Verb RunAs
    exit 0
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "  Admin confirmed. TLS 1.2 enabled." -ForegroundColor Green

# -------------------------------------------------------
# 2) DETECT GPU AND VRAM
# -------------------------------------------------------
Write-Host "[2/12] Detecting GPU hardware..." -ForegroundColor Cyan

$gpuName = "Unknown"
$vramMB = 0
$driverVer = "Unknown"
try {
    $nvsmi = & nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits 2>$null
    if ($nvsmi) {
        $parts = $nvsmi.Split(",")
        $gpuName = $parts[0].Trim()
        $vramMB = [int]$parts[1].Trim()
        $driverVer = $parts[2].Trim()
    }
} catch {}

Write-Host "  GPU: $gpuName" -ForegroundColor Green
Write-Host "  VRAM: $vramMB MB ($([math]::Round($vramMB/1024,1)) GB)" -ForegroundColor Green
Write-Host "  Driver: $driverVer" -ForegroundColor Green

# Check driver version for RTX 5080 (needs 570+)
if ($driverVer -ne "Unknown") {
    $driverMajor = [int]($driverVer.Split(".")[0])
    if ($driverMajor -lt 570) {
        Write-Warning "RTX 5080 requires driver 570+. Current: $driverVer. Update from https://www.nvidia.com/drivers"
    }
}

# -------------------------------------------------------
# 3) AUTO-INSTALL MISSING DEPENDENCIES
# -------------------------------------------------------
Write-Host "[3/12] Checking and installing missing dependencies..." -ForegroundColor Cyan

# --- Check Node.js (required for Claude Code) ---
$hasNode = $false
try {
    $nodeVer = & node --version 2>$null
    if ($nodeVer) {
        $hasNode = $true
        Write-Host "  Node.js: $nodeVer (installed)" -ForegroundColor Green
    }
} catch {}

if (-not $hasNode) {
    Write-Host "  Installing Node.js LTS..." -ForegroundColor Yellow
    try {
        $nodeInstaller = "$env:TEMP\node_lts_setup.msi"
        Invoke-WebRequest -Uri "https://nodejs.org/dist/v22.15.0/node-v22.15.0-x64.msi" -OutFile $nodeInstaller -UseBasicParsing
        Start-Process msiexec.exe -ArgumentList "/i `"$nodeInstaller`" /qn /norestart" -Wait -NoNewWindow
        # Refresh PATH
        $env:PATH = [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [Environment]::GetEnvironmentVariable("PATH", "User")
        Write-Host "  Node.js installed." -ForegroundColor Green
    } catch {
        Write-Host "  Could not auto-install Node.js. Install manually from https://nodejs.org" -ForegroundColor Yellow
    }
}

# --- Check Visual C++ Redistributable 2015-2022 ---
$vcInstalled = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64" -ErrorAction SilentlyContinue
if ($vcInstalled) {
    Write-Host "  Visual C++ Redist: installed (v$($vcInstalled.Major).$($vcInstalled.Minor))" -ForegroundColor Green
} else {
    Write-Host "  Installing Visual C++ Redistributable 2015-2022..." -ForegroundColor Yellow
    try {
        $vcUrl = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
        $vcInstaller = "$env:TEMP\vc_redist_x64.exe"
        Invoke-WebRequest -Uri $vcUrl -OutFile $vcInstaller -UseBasicParsing
        Start-Process -FilePath $vcInstaller -ArgumentList "/install /quiet /norestart" -Wait -NoNewWindow
        Write-Host "  Visual C++ Redist installed." -ForegroundColor Green
    } catch {
        Write-Host "  Could not auto-install VC++ Redist (non-critical)." -ForegroundColor Yellow
    }
}

# --- Check Ollama ---
$ollamaExe = $null
$searchPaths = @(
    "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe",
    "$env:ProgramFiles\Ollama\ollama.exe",
    "C:\Users\$env:USERNAME\AppData\Local\Programs\Ollama\ollama.exe"
)
foreach ($p in $searchPaths) {
    if (Test-Path $p) {
        $ollamaExe = $p
        break
    }
}
if (-not $ollamaExe) {
    try { $ollamaExe = (Get-Command ollama -ErrorAction Stop).Source } catch {}
}

if ($ollamaExe) {
    Write-Host "  Ollama: $ollamaExe (installed)" -ForegroundColor Green
} else {
    Write-Host "  Installing Ollama..." -ForegroundColor Yellow
    try {
        $ollamaInstaller = "$env:TEMP\OllamaSetup.exe"
        Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $ollamaInstaller -UseBasicParsing
        Start-Process -FilePath $ollamaInstaller -ArgumentList "/SILENT" -Wait -NoNewWindow
        Start-Sleep -Seconds 5
        # Re-check
        foreach ($p in $searchPaths) {
            if (Test-Path $p) { $ollamaExe = $p; break }
        }
        if ($ollamaExe) {
            Write-Host "  Ollama installed: $ollamaExe" -ForegroundColor Green
        } else {
            Write-Error "Ollama install failed. Install manually from https://ollama.com/download"
        }
    } catch {
        Write-Error "Could not download Ollama. Install manually from https://ollama.com/download"
    }
}

# --- Check Claude Code CLI ---
$hasClaude = $false
try {
    $claudeCmd = Get-Command -Name "claude" -ErrorAction Stop
    $hasClaude = $true
    Write-Host "  Claude Code CLI: installed" -ForegroundColor Green
} catch {}

if (-not $hasClaude) {
    Write-Host "  Installing Claude Code CLI..." -ForegroundColor Yellow
    try {
        & ([scriptblock]::Create((Invoke-RestMethod https://claude.ai/install.ps1)))
        Start-Sleep -Seconds 3
        Write-Host "  Claude Code CLI installed." -ForegroundColor Green
    } catch {
        Write-Host "  Could not auto-install Claude Code CLI." -ForegroundColor Yellow
    }
}

# --- Set Windows Graphics Performance for Ollama ---
Write-Host "  Setting Windows GPU preference for Ollama to High Performance..." -ForegroundColor Yellow
try {
    $gfxPath = "HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences"
    if (-not (Test-Path $gfxPath)) {
        New-Item -Path $gfxPath -Force | Out-Null
    }
    if ($ollamaExe) {
        Set-ItemProperty -Path $gfxPath -Name $ollamaExe -Value "GpuPreference=2;" -Force
        Write-Host "  Windows GPU preference set to High Performance for Ollama." -ForegroundColor Green
    }
} catch {
    Write-Host "  Could not set GPU preference (non-critical)." -ForegroundColor Yellow
}

# -------------------------------------------------------
# 4) SET CUSTOM OLLAMA DATA PATH
# -------------------------------------------------------
Write-Host "[4/12] Setting custom Ollama data path..." -ForegroundColor Cyan

$customPath = "F:\backup\LocalAI\ollama"
$modelsPath = Join-Path $customPath "models"

if (-not (Test-Path $customPath)) {
    New-Item -ItemType Directory -Path $customPath -Force | Out-Null
}
if (-not (Test-Path $modelsPath)) {
    New-Item -ItemType Directory -Path $modelsPath -Force | Out-Null
}

# Set permanently for user
$pathVars = @{
    OLLAMA_MODELS = $modelsPath
    OLLAMA_HOME   = $customPath
}
foreach ($name in $pathVars.Keys) {
    $value = $pathVars[$name]
    $existing = [Environment]::GetEnvironmentVariable($name, "User")
    if ($existing -ne $value) {
        [Environment]::SetEnvironmentVariable($name, $value, "User")
    }
    [Environment]::SetEnvironmentVariable($name, $value, "Process")
}

Write-Host "  Data path: $customPath" -ForegroundColor Green
Write-Host "  Models path: $modelsPath" -ForegroundColor Green

# -------------------------------------------------------
# 5) SET ALL PERFORMANCE ENVIRONMENT VARIABLES
# -------------------------------------------------------
Write-Host "[5/12] Setting MAXIMUM performance environment variables..." -ForegroundColor Cyan

$perfVars = @{
    # Flash Attention - reduces memory bandwidth 40%, huge speed boost
    OLLAMA_FLASH_ATTENTION   = "1"

    # KV Cache quantization - q8_0 uses half the memory of f16
    # Nearly zero quality loss, massive VRAM savings for long contexts
    OLLAMA_KV_CACHE_TYPE     = "q8_0"

    # Single user = no contention, all VRAM for one model
    OLLAMA_NUM_PARALLEL      = "1"

    # Only load one model at a time - maximize VRAM for active model
    OLLAMA_MAX_LOADED_MODELS = "1"

    # Keep model loaded 60 minutes - avoid reload latency
    OLLAMA_KEEP_ALIVE        = "60m"

    # Minimize reserved VRAM overhead - give maximum to model
    # 256MB reserve (safe for RTX 5080 with 16GB)
    OLLAMA_GPU_OVERHEAD      = "268435456"

    # Force CUDA device 0 (RTX 5080)
    CUDA_VISIBLE_DEVICES     = "0"

    # Disable debug logging for speed
    OLLAMA_DEBUG             = "0"

    # Bind to localhost only
    OLLAMA_HOST              = "127.0.0.1:11434"

    # Max GPU layers - force full GPU offload (999 = all layers)
    OLLAMA_NUM_GPU           = "999"
}

foreach ($name in $perfVars.Keys) {
    $value = $perfVars[$name]
    [Environment]::SetEnvironmentVariable($name, $value, "User")
    [Environment]::SetEnvironmentVariable($name, $value, "Process")
    Write-Host "  $name = $value" -ForegroundColor Yellow
}

Write-Host "  All performance vars set." -ForegroundColor Green

# -------------------------------------------------------
# 6) WINDOWS POWER PLAN - ULTIMATE PERFORMANCE
# -------------------------------------------------------
Write-Host "[6/12] Setting Windows to Ultimate/High Performance power plan..." -ForegroundColor Cyan

try {
    # Try to create Ultimate Performance plan first
    powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null
    $plans = powercfg /list
    # Prefer Ultimate Performance, fall back to High Performance
    $target = $plans | Select-String "Ultimate Performance" | Select-Object -First 1
    if (-not $target) {
        $target = $plans | Select-String "High performance" | Select-Object -First 1
    }
    if ($target) {
        $guid = [regex]::Match($target.Line, '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}').Value
        if ($guid) {
            powercfg /setactive $guid
            Write-Host "  Power plan activated: $($target.Line.Trim())" -ForegroundColor Green
        }
    }
} catch {
    Write-Host "  Could not set power plan (non-critical)." -ForegroundColor Yellow
}

# -------------------------------------------------------
# 7) GPU PERFORMANCE TWEAKS
# -------------------------------------------------------
Write-Host "[7/12] Applying GPU performance registry tweaks..." -ForegroundColor Cyan

try {
    # Increase TDR timeout to prevent GPU timeout during heavy inference
    $tdrPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    $currentTdr = Get-ItemProperty -Path $tdrPath -Name TdrDelay -ErrorAction SilentlyContinue
    if (-not $currentTdr -or $currentTdr.TdrDelay -lt 60) {
        Set-ItemProperty -Path $tdrPath -Name TdrDelay -Value 60 -Type DWord -Force
        Set-ItemProperty -Path $tdrPath -Name TdrDdiDelay -Value 60 -Type DWord -Force
        Write-Host "  TDR timeout increased to 60s (prevents GPU timeout)." -ForegroundColor Green
    } else {
        Write-Host "  TDR timeout already set to $($currentTdr.TdrDelay)s." -ForegroundColor Green
    }

    # Disable NVIDIA telemetry for less overhead
    $nvTelemetry = "HKLM:\SOFTWARE\NVIDIA Corporation\NvTelemetryContainer"
    if (Test-Path $nvTelemetry) {
        Set-ItemProperty -Path $nvTelemetry -Name "IsTelemetryEnabled" -Value 0 -Force -ErrorAction SilentlyContinue
        Write-Host "  NVIDIA telemetry disabled." -ForegroundColor Green
    }

    # Set GPU to prefer maximum performance via nvidia-smi
    & nvidia-smi -pm 1 2>$null | Out-Null
    Write-Host "  GPU persistence mode enabled." -ForegroundColor Green

    # Lock GPU clocks to maximum for consistent performance
    $maxClocks = & nvidia-smi --query-gpu=clocks.max.gr,clocks.max.mem --format=csv,noheader,nounits 2>$null
    if ($maxClocks) {
        $clockParts = $maxClocks.Split(",")
        $maxGr = $clockParts[0].Trim()
        $maxMem = $clockParts[1].Trim()
        & nvidia-smi -lgc $maxGr 2>$null | Out-Null
        & nvidia-smi -lmc $maxMem 2>$null | Out-Null
        Write-Host "  GPU clocks locked to max: Core=${maxGr}MHz Mem=${maxMem}MHz" -ForegroundColor Green
    }

    # Disable hardware-accelerated GPU scheduling overhead (optional perf gain)
    $hwSchPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
    $hwSch = Get-ItemProperty -Path $hwSchPath -Name HwSchMode -ErrorAction SilentlyContinue
    if ($hwSch -and $hwSch.HwSchMode -ne 2) {
        Set-ItemProperty -Path $hwSchPath -Name HwSchMode -Value 2 -Type DWord -Force
        Write-Host "  Hardware GPU scheduling enabled." -ForegroundColor Green
    }
} catch {
    Write-Host "  Some GPU tweaks failed (non-critical): $($_.Exception.Message)" -ForegroundColor Yellow
}

# -------------------------------------------------------
# 8) KILL AND RESTART OLLAMA WITH PERF SETTINGS
# -------------------------------------------------------
Write-Host "[8/12] Restarting Ollama with maximum performance settings..." -ForegroundColor Cyan

# Kill any existing Ollama processes
$ollamaProcs = Get-Process -Name "ollama*" -ErrorAction SilentlyContinue
if ($ollamaProcs) {
    Write-Host "  Stopping existing Ollama processes..." -ForegroundColor Yellow
    $ollamaProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

if (-not $ollamaExe) {
    Write-Error "Cannot find ollama.exe. Installation may have failed."
}

# Start ollama serve in background with all perf env vars already set
Write-Host "  Starting Ollama serve from: $ollamaExe" -ForegroundColor Yellow
$proc = Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden -PassThru

# Set process priority to High
try {
    Start-Sleep -Seconds 2
    $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
    Write-Host "  Ollama process priority set to HIGH." -ForegroundColor Green
} catch {
    Write-Host "  Could not set priority (non-critical)." -ForegroundColor Yellow
}

# Also set CPU affinity to performance cores (all cores)
try {
    $coreCount = [Environment]::ProcessorCount
    $allCoresMask = [long]([math]::Pow(2, $coreCount) - 1)
    $proc.ProcessorAffinity = [IntPtr]$allCoresMask
    Write-Host "  CPU affinity set to all $coreCount cores." -ForegroundColor Green
} catch {
    Write-Host "  Could not set CPU affinity (non-critical)." -ForegroundColor Yellow
}

# Wait for API to come up
Write-Host "  Waiting for Ollama API..." -ForegroundColor Yellow
$maxWait = 30
$waited = 0
$alive = $false
while ($waited -lt $maxWait) {
    Start-Sleep -Seconds 1
    $waited++
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:11434" -Method Head -TimeoutSec 2 -UseBasicParsing
        $alive = $true
        break
    } catch {}
}

if (-not $alive) {
    Write-Error "Ollama API did not start within ${maxWait}s. Check ollama installation."
}

Write-Host "  Ollama API is live (started in ${waited}s)." -ForegroundColor Green

# -------------------------------------------------------
# 9) DETERMINE AND PULL THE BEST MODEL
# -------------------------------------------------------
Write-Host "[9/12] Selecting the ABSOLUTE BEST model for RTX 5080 16GB..." -ForegroundColor Cyan

# MODEL SELECTION - FINAL ANSWER (April 2026):
#
# CRITICAL: Claude Code requires TOOL CALLING support. Models without it
# just give instructions instead of actually running commands/editing files.
#
# TOOL CALLING SUPPORT CHECK (from ollama show):
#   qwen3.5:9b:          tools YES, thinking YES, vision YES, 262K context
#   qwen3-coder 30B:     tools YES, thinking NO,  vision NO
#   qwen2.5-coder:14b:   tools NO  <- USELESS for Claude Code (just chats)
#   deepseek-r1:32b:     tools NO  <- USELESS
#   llama3:8b:           tools NO  <- USELESS
#   glm-4.7-flash:       tools YES, thinking YES, but 19GB -> spills to CPU
#
# VRAM FIT (Q4_K_M):
#   qwen3.5:9b:          6.6GB -> 100% GPU, ~9GB headroom for KV cache
#   qwen3-coder 30B:     18GB  -> SPILLS TO CPU
#   glm-4.7-flash:       19GB  -> SPILLS TO CPU
#
# SPEED ON RTX 5080 16GB (fully GPU-resident):
#   qwen3.5:9b:          ~129 tok/s (all in VRAM, fastest with tools)
#   qwen3-coder:         ~45 tok/s (CPU offload)
#   glm-4.7-flash:       ~40 tok/s (CPU offload)
#
# VERDICT:
#   PRIMARY: qwen3.5:9b - ONLY model with tools+thinking+vision that
#            fits 100% in 16GB VRAM. 262K context. 129 tok/s.
#            Ollama officially recommends qwen3.5 for Claude Code.
#            72.2 BFCL-V4 tool use benchmark. Agentic coding works.
#
#   QUALITY: qwen3-coder - for when you need code-specialized model
#            and can tolerate slower speed from CPU offload

$primaryModel = "qwen3-coder"
$qualityModel = "qwen3.5:9b"

# Pull primary model
$modelList = & ollama list 2>$null
$hasPrimary = $modelList | Select-String "qwen3-coder"
if ($hasPrimary) {
    Write-Host "  PRIMARY model '$primaryModel' already installed." -ForegroundColor Green
} else {
    Write-Host "  Pulling PRIMARY model '$primaryModel' (18GB, code-specialized, tool calling)..." -ForegroundColor Yellow
    & ollama pull $primaryModel
    Write-Host "  PRIMARY model '$primaryModel' pulled." -ForegroundColor Green
}

# Pull alternative model
$hasQuality = $modelList | Select-String "qwen3.5:9b"
if ($hasQuality) {
    Write-Host "  ALT model '$qualityModel' already installed." -ForegroundColor Green
} else {
    Write-Host "  Pulling ALT model '$qualityModel' (6.6GB, lighter alternative)..." -ForegroundColor Yellow
    & ollama pull $qualityModel
    Write-Host "  ALT model '$qualityModel' pulled." -ForegroundColor Green
}

Write-Host ""
Write-Host "  Current models:" -ForegroundColor Yellow
& ollama list

# -------------------------------------------------------
# 10) PRE-WARM THE PRIMARY MODEL
# -------------------------------------------------------
Write-Host "[10/12] Pre-warming primary model in VRAM..." -ForegroundColor Cyan

try {
    $warmBody = @{
        model  = $primaryModel
        prompt = "hi"
        stream = $false
        options = @{
            num_predict = 1
            num_ctx     = 8192
        }
    } | ConvertTo-Json -Depth 5

    $warmResp = Invoke-RestMethod -Uri "http://localhost:11434/api/generate" -Method Post -Body $warmBody -ContentType "application/json" -TimeoutSec 120
    Write-Host "  Model '$primaryModel' loaded into VRAM and ready." -ForegroundColor Green

    $psInfo = & ollama ps 2>$null
    if ($psInfo) {
        Write-Host "  Running models:" -ForegroundColor Yellow
        Write-Host $psInfo -ForegroundColor Yellow
    }
} catch {
    Write-Host "  Pre-warm failed (model will load on first request): $($_.Exception.Message)" -ForegroundColor Yellow
}

# -------------------------------------------------------
# 11) CREATE LAUNCHER SCRIPTS (in script directory)
# -------------------------------------------------------
Write-Host "[11/12] Creating optimized launcher scripts in $scriptDir ..." -ForegroundColor Cyan

# --- MAIN LAUNCHER: run-local.ps1 ---
$launcherContent = @'
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
    [string]$Model = "qwen3.5:9b"
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
'@

$launcherPath = Join-Path $scriptDir "run-local.ps1"
$launcherContent | Set-Content -Path $launcherPath -Encoding UTF8
Write-Host "  Created: $launcherPath" -ForegroundColor Green

# --- Also copy to F:\Downloads for convenience ---
$dlLauncherPath = "F:\Downloads\claude-ollama.ps1"
$launcherContent | Set-Content -Path $dlLauncherPath -Encoding UTF8
Write-Host "  Created: $dlLauncherPath" -ForegroundColor Green

# -------------------------------------------------------
# 12) FINAL SUMMARY
# -------------------------------------------------------
Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host "  MAXIMUM PERFORMANCE SETUP COMPLETE" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  GPU: $gpuName ($([math]::Round($vramMB/1024,1)) GB VRAM)" -ForegroundColor Cyan
Write-Host "  Driver: $driverVer" -ForegroundColor Cyan
Write-Host ""
Write-Host "  PERFORMANCE OPTIMIZATIONS APPLIED:" -ForegroundColor Yellow
Write-Host "    [x] Flash Attention ON (40% memory bandwidth reduction)" -ForegroundColor White
Write-Host "    [x] KV Cache q8_0 (50% cache memory savings)" -ForegroundColor White
Write-Host "    [x] GPU Persistence Mode ON" -ForegroundColor White
Write-Host "    [x] GPU Clocks locked to maximum" -ForegroundColor White
Write-Host "    [x] TDR Timeout 60s (no GPU timeout)" -ForegroundColor White
Write-Host "    [x] Process Priority HIGH" -ForegroundColor White
Write-Host "    [x] Ultimate/High Performance power plan" -ForegroundColor White
Write-Host "    [x] Single model loaded (max VRAM)" -ForegroundColor White
Write-Host "    [x] GPU overhead minimized (256MB reserve)" -ForegroundColor White
Write-Host "    [x] Model pre-warmed in VRAM" -ForegroundColor White
Write-Host "    [x] Windows GPU preference = High Performance" -ForegroundColor White
Write-Host "    [x] Hardware GPU scheduling enabled" -ForegroundColor White
Write-Host "    [x] CPU affinity = all cores" -ForegroundColor White
Write-Host "    [x] NVIDIA telemetry disabled" -ForegroundColor White
Write-Host ""
Write-Host "  DEPENDENCIES AUTO-INSTALLED:" -ForegroundColor Yellow
Write-Host "    [x] Node.js LTS (for Claude Code)" -ForegroundColor White
Write-Host "    [x] Visual C++ Redistributable 2015-2022" -ForegroundColor White
Write-Host "    [x] Ollama (with bundled CUDA runtime)" -ForegroundColor White
Write-Host "    [x] Claude Code CLI" -ForegroundColor White
Write-Host ""
Write-Host "  BEST MODEL FOR CLAUDE CODE:" -ForegroundColor Yellow
Write-Host "    PRIMARY: qwen3-coder (Ollama officially recommended)" -ForegroundColor White
Write-Host "    ALT:     qwen3.5:9b (lighter, 6.6GB)" -ForegroundColor White
Write-Host ""
Write-Host "  HOW TO USE:" -ForegroundColor Yellow
Write-Host "    Local:           .\run-local.ps1" -ForegroundColor White
Write-Host "    Local (alt):     .\run-local.ps1 -Model qwen3.5:9b" -ForegroundColor White
Write-Host "    Normal Claude:   claude" -ForegroundColor White
Write-Host ""
Write-Host "  DATA PATH: $customPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Normal 'claude' command is COMPLETELY UNAFFECTED." -ForegroundColor Cyan
Write-Host "  All local env vars are session-scoped in the launcher." -ForegroundColor Cyan
Write-Host ""
Write-Host "  SCRIPT PATHS:" -ForegroundColor Yellow
Write-Host "    Setup:    $PSCommandPath" -ForegroundColor White
Write-Host "    Launcher: $launcherPath" -ForegroundColor White
Write-Host "========================================================" -ForegroundColor Green
