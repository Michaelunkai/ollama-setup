# =============================================================================
# oll90 — Complete Windows 11 Installer
# =============================================================================
# Run from PowerShell (Admin recommended):
#   Set-ExecutionPolicy Bypass -Scope Process -Force
#   .\install.ps1
#
# Or one-liner from the web:
#   irm https://raw.githubusercontent.com/Michaelunkai/ollama-setup/main/install.ps1 | iex
# =============================================================================

$ErrorActionPreference = 'Continue'
$INSTALL_DIR = 'C:\oll90'
$REPO_URL    = 'https://github.com/Michaelunkai/ollama-setup.git'
$MODEL_NAME  = 'qwen3.5:latest'
$CUSTOM_MODEL = 'qwen3.5-oll90'
$PYTHON_MIN  = [Version]'3.10'

function Write-Step([string]$msg) { Write-Host "`n[INSTALL] $msg" -ForegroundColor Cyan }
function Write-OK([string]$msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  [!!] $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host "  [ERR] $msg" -ForegroundColor Red }
function Write-Banner {
    Write-Host ''
    Write-Host '  ██████╗ ██╗     ██╗      █████╗  ██████╗ ' -ForegroundColor Magenta
    Write-Host '  ██╔══██╗██║     ██║     ██╔══██╗██╔═══██╗' -ForegroundColor Magenta
    Write-Host '  ██║  ██║██║     ██║     ╚██████║██║   ██║' -ForegroundColor Magenta
    Write-Host '  ╚█████╔╝███████╗███████╗ ╚═══██║╚██████╔╝' -ForegroundColor Magenta
    Write-Host '   ╚════╝ ╚══════╝╚══════╝ █████╔╝ ╚═════╝ ' -ForegroundColor Magenta
    Write-Host '                           ╚════╝           ' -ForegroundColor Magenta
    Write-Host '  Autonomous AI Agent  |  qwen3.5 + RTX GPU' -ForegroundColor DarkMagenta
    Write-Host ''
}

Write-Banner

# =============================================================================
# STEP 0 — Check OS
# =============================================================================
Write-Step 'Checking OS...'
$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -notmatch 'Windows') {
    Write-Err 'This installer requires Windows. Exiting.'
    exit 1
}
Write-OK "$($os.Caption) Build $($os.BuildNumber)"

# =============================================================================
# STEP 1 — Check GPU (warn if not NVIDIA)
# =============================================================================
Write-Step 'Checking GPU...'
$gpuInfo = try { nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>$null } catch { $null }
if ($gpuInfo) {
    Write-OK "GPU: $gpuInfo"
} else {
    Write-Warn 'No NVIDIA GPU detected. oll90 will run on CPU (slow). 8GB+ VRAM recommended.'
}

# =============================================================================
# STEP 2 — Install prerequisites via winget
# =============================================================================
Write-Step 'Checking prerequisites...'

function Install-WingetPackage([string]$id, [string]$name, [string]$testCmd) {
    $exists = $false
    if ($testCmd) {
        try { $null = & $testCmd --version 2>$null; $exists = $true } catch {}
    }
    if ($exists) {
        Write-OK "$name already installed"
        return
    }
    Write-Warn "$name not found. Installing via winget..."
    $proc = Start-Process winget -ArgumentList "install --id $id --silent --accept-source-agreements --accept-package-agreements" -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335189) {
        Write-OK "$name installed"
    } else {
        Write-Err "Failed to install $name (exit $($proc.ExitCode)). Install manually: https://github.com/$id"
    }
}

# Git
Install-WingetPackage 'Git.Git' 'Git' 'git'

# Python 3.12
$pyExe = $null
foreach ($candidate in @('python', 'python3', 'py')) {
    try {
        $ver = & $candidate --version 2>&1
        if ($ver -match '(\d+\.\d+)') {
            $detected = [Version]$Matches[1]
            if ($detected -ge $PYTHON_MIN) { $pyExe = $candidate; break }
        }
    } catch {}
}
if (-not $pyExe) {
    Write-Warn 'Python 3.10+ not found. Installing Python 3.12...'
    Start-Process winget -ArgumentList 'install --id Python.Python.3.12 --silent --accept-source-agreements --accept-package-agreements' -Wait -NoNewWindow
    # Refresh PATH
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
    foreach ($candidate in @('python', 'python3')) {
        try { $ver = & $candidate --version 2>&1; if ($ver -match '3\.1[0-9]') { $pyExe = $candidate; break } } catch {}
    }
    # Fallback: find in AppData
    $found = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python" -Filter 'python.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $pyExe = $found.FullName }
    if ($pyExe) { Write-OK "Python installed: $pyExe" } else { Write-Warn 'Python install may require PATH refresh. Re-run install.ps1 if it fails later.' ; $pyExe = 'python' }
} else {
    Write-OK "Python found: $pyExe ($( & $pyExe --version 2>&1))"
}

# Node.js
$nodeOk = $false
try { $nv = node --version 2>$null; if ($nv) { $nodeOk = $true } } catch {}
if (-not $nodeOk) {
    Write-Warn 'Node.js not found. Installing...'
    Start-Process winget -ArgumentList 'install --id OpenJS.NodeJS.LTS --silent --accept-source-agreements --accept-package-agreements' -Wait -NoNewWindow
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
    Write-OK 'Node.js installed'
} else {
    Write-OK "Node.js: $(node --version 2>$null)"
}

# Ollama
$ollamaOk = $false
try { $null = ollama --version 2>$null; $ollamaOk = $true } catch {}
if (-not $ollamaOk) {
    Write-Warn 'Ollama not found. Installing...'
    Start-Process winget -ArgumentList 'install --id Ollama.Ollama --silent --accept-source-agreements --accept-package-agreements' -Wait -NoNewWindow
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
    Write-OK 'Ollama installed'
} else {
    Write-OK "Ollama: $(ollama --version 2>$null)"
}

# Cloudflared (optional — for global URL)
$cfOk = Test-Path 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
if (-not $cfOk) {
    Write-Warn 'cloudflared not found. Installing (enables global URL access)...'
    Start-Process winget -ArgumentList 'install --id Cloudflare.cloudflared --silent --accept-source-agreements --accept-package-agreements' -Wait -NoNewWindow
    Write-OK 'cloudflared installed'
} else {
    Write-OK 'cloudflared present'
}

# =============================================================================
# STEP 3 — Clone or update repo
# =============================================================================
Write-Step "Setting up repo at $INSTALL_DIR ..."
if (Test-Path "$INSTALL_DIR\.git") {
    Write-Warn 'Repo already exists. Pulling latest...'
    Push-Location $INSTALL_DIR
    git pull --rebase origin main 2>&1 | ForEach-Object { Write-Host "  $_" }
    Pop-Location
} else {
    if (Test-Path $INSTALL_DIR) { Remove-Item $INSTALL_DIR -Recurse -Force }
    git clone $REPO_URL $INSTALL_DIR 2>&1 | ForEach-Object { Write-Host "  $_" }
}
Write-OK "Repo ready at $INSTALL_DIR"

# Paths derived from install dir
$APP_DIR      = "$INSTALL_DIR\oll90-ui\interactive\app"
$BACKEND_DIR  = "$APP_DIR\backend"
$FRONTEND_DIR = "$APP_DIR\frontend"
$SCRIPTS_DIR  = "$APP_DIR\scripts"
$MODELFILE    = "$INSTALL_DIR\Modelfile.oll90"

# =============================================================================
# STEP 4 — Set Ollama environment variables (permanent, user-level)
# =============================================================================
Write-Step 'Configuring Ollama environment variables...'
$envVars = @{
    OLLAMA_KV_CACHE_TYPE    = 'q4_0'
    OLLAMA_CONTEXT_LENGTH   = '131072'
    OLLAMA_BATCH_SIZE       = '2048'
    OLLAMA_FLASH_ATTENTION  = '1'
    OLLAMA_NUM_GPU          = '999'
    OLLAMA_MAX_LOADED_MODELS= '1'
    OLLAMA_GPU_OVERHEAD     = '0'
    OLLAMA_NUM_PARALLEL     = '1'
    CUDA_VISIBLE_DEVICES    = '0'
}
foreach ($k in $envVars.Keys) {
    [Environment]::SetEnvironmentVariable($k, $envVars[$k], 'User')
    $env:($k) = $envVars[$k]
}
Write-OK 'Env vars set (KV=q4_0, CTX=131072, BATCH=2048, GPU=100%)'

# =============================================================================
# STEP 5 — Install Python dependencies
# =============================================================================
Write-Step 'Installing Python dependencies...'
if (Test-Path "$BACKEND_DIR\requirements.txt") {
    & $pyExe -m pip install -r "$BACKEND_DIR\requirements.txt" --quiet --upgrade
    Write-OK 'Python packages installed'
} else {
    Write-Warn 'requirements.txt not found — installing core packages directly'
    & $pyExe -m pip install fastapi uvicorn httpx websockets aiosqlite --quiet
    Write-OK 'Core Python packages installed'
}

# =============================================================================
# STEP 6 — Install Node.js dependencies
# =============================================================================
Write-Step 'Installing Node.js dependencies...'
if (Test-Path $FRONTEND_DIR) {
    Push-Location $FRONTEND_DIR
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c npm install' -WorkingDirectory $FRONTEND_DIR -Wait -NoNewWindow
    Pop-Location
    Write-OK 'npm packages installed'
} else {
    Write-Err "Frontend directory not found: $FRONTEND_DIR"
}

# =============================================================================
# STEP 7 — Start Ollama service + pull model
# =============================================================================
Write-Step 'Starting Ollama service...'

# Kill existing ollama processes to ensure clean env
Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# Start ollama serve in background
Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden
Write-Warn 'Waiting for Ollama to start...'
$ready = $false
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $r = Invoke-WebRequest -Uri 'http://localhost:11434/api/version' -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
}
if ($ready) { Write-OK 'Ollama is running' } else { Write-Warn 'Ollama may not be ready yet — continuing anyway' }

Write-Step "Pulling model $MODEL_NAME (6.6 GB — this may take a while)..."
Write-Warn 'Please wait. Progress is shown below:'
ollama pull $MODEL_NAME
Write-OK "$MODEL_NAME pulled"

# =============================================================================
# STEP 8 — Build custom model (qwen3.5-oll90)
# =============================================================================
Write-Step "Building custom model $CUSTOM_MODEL from Modelfile..."
if (Test-Path $MODELFILE) {
    Copy-Item $MODELFILE 'C:\Temp\Modelfile.oll90' -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path 'C:\Temp')) { New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null; Copy-Item $MODELFILE 'C:\Temp\Modelfile.oll90' -Force }
    Push-Location 'C:\Temp'
    ollama create $CUSTOM_MODEL -f 'C:\Temp\Modelfile.oll90'
    Pop-Location
    Write-OK "$CUSTOM_MODEL model created"
} else {
    Write-Warn "Modelfile not found at $MODELFILE — using base model"
}

# =============================================================================
# STEP 9 — Create C:\Temp if needed
# =============================================================================
if (-not (Test-Path 'C:\Temp')) {
    New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null
    Write-OK 'Created C:\Temp'
}

# =============================================================================
# STEP 10 — Write launch script to C:\oll90\launch.ps1
# =============================================================================
Write-Step 'Writing launch script...'
$launchScript = @"
# oll90 Launcher — run this to start the web UI
# Usage: powershell -ExecutionPolicy Bypass -File C:\oll90\launch.ps1
Set-ExecutionPolicy Bypass -Scope Process -Force
& '$SCRIPTS_DIR\start.ps1'
"@
[System.IO.File]::WriteAllText("$INSTALL_DIR\launch.ps1", $launchScript, [System.Text.Encoding]::UTF8)
Write-OK "Launch script: $INSTALL_DIR\launch.ps1"

# =============================================================================
# STEP 11 — Create Desktop shortcut
# =============================================================================
Write-Step 'Creating desktop shortcut...'
try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut("$env:USERPROFILE\Desktop\oll90.lnk")
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = "-ExecutionPolicy Bypass -WindowStyle Normal -File `"$INSTALL_DIR\launch.ps1`""
    $shortcut.WorkingDirectory = $INSTALL_DIR
    $shortcut.Description = 'oll90 Autonomous AI Agent'
    $shortcut.Save()
    Write-OK 'Desktop shortcut created: oll90.lnk'
} catch {
    Write-Warn "Could not create shortcut: $_"
}

# =============================================================================
# DONE
# =============================================================================
Write-Host ''
Write-Host '  =============================================' -ForegroundColor Green
Write-Host '   oll90 installation complete!' -ForegroundColor Green
Write-Host '  =============================================' -ForegroundColor Green
Write-Host ''
Write-Host '  To start:' -ForegroundColor Cyan
Write-Host "    powershell -ExecutionPolicy Bypass -File $INSTALL_DIR\launch.ps1" -ForegroundColor White
Write-Host '  Or double-click oll90 on your Desktop' -ForegroundColor White
Write-Host ''
Write-Host '  Web UI will be available at:' -ForegroundColor Cyan
Write-Host '    Local:  http://localhost:3090' -ForegroundColor White
Write-Host '    Global: printed in terminal after startup (cloudflare URL)' -ForegroundColor White
Write-Host ''

$launch = Read-Host 'Launch oll90 now? (y/n)'
if ($launch -eq 'y') {
    Write-Host 'Starting oll90...' -ForegroundColor Cyan
    & "$INSTALL_DIR\launch.ps1"
}
