# oll90 Web UI Launcher
# Starts backend (FastAPI on 8090) + frontend (Vite on 3090) + opens browser
param(
    [switch]$BackendOnly,
    [switch]$FrontendOnly,
    [string]$PythonExe = "C:\Users\micha\AppData\Local\Programs\Python\Python312\python.exe"
)

$ErrorActionPreference = 'Continue'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$backendDir = Join-Path $projectRoot 'app\backend'
$frontendDir = Join-Path $projectRoot 'app\frontend'

function Write-Status([string]$msg, [string]$color = 'Cyan') {
    Write-Host "[oll90-ui] $msg" -ForegroundColor $color
}

# Step 1: Check Ollama
Write-Status "Checking Ollama..."
try {
    $ollamaCheck = ollama ps 2>&1
    Write-Status "Ollama: $($ollamaCheck | Select-Object -First 2 | Out-String)" 'Green'
} catch {
    Write-Status "Ollama not running - start with oll90 first" 'Yellow'
}

# Step 2: Start backend
if (-not $FrontendOnly) {
    Write-Status "Starting backend on :8090..."
    $backendProc = Start-Process -FilePath $PythonExe -ArgumentList "main.py" `
        -WorkingDirectory $backendDir -PassThru -WindowStyle Hidden
    Write-Status "Backend PID: $($backendProc.Id)" 'Green'

    # Health check
    $attempts = 0
    while ($attempts -lt 15) {
        Start-Sleep -Milliseconds 500
        try {
            $resp = Invoke-WebRequest -Uri 'http://localhost:8090/' -UseBasicParsing -TimeoutSec 2
            if ($resp.StatusCode -eq 200) {
                Write-Status "Backend ready" 'Green'
                break
            }
        } catch {}
        $attempts++
    }
    if ($attempts -ge 15) {
        Write-Status "Backend failed to start" 'Red'
    }
}

# Step 3: Start frontend
if (-not $BackendOnly) {
    Write-Status "Starting frontend on :3090..."
    $frontendProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c npm run dev -- --port 3090 --host" `
        -WorkingDirectory $frontendDir -PassThru -WindowStyle Hidden
    Write-Status "Frontend PID: $($frontendProc.Id)" 'Green'

    Start-Sleep -Seconds 3
    Write-Status "Opening browser..."
    Start-Process "http://localhost:3090"
}

Write-Status "oll90 Web UI running!" 'Green'
Write-Status "  Backend:  http://localhost:8090" 'Cyan'
Write-Status "  Frontend: http://localhost:3090" 'Cyan'

# Step 4: Cloudflared tunnel for global Android access
$cloudflaredExe = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
if (Test-Path $cloudflaredExe) {
    Write-Status "Starting cloudflared tunnel on :3090..." 'Cyan'
    $tunnelLog = "C:\Temp\oll90-tunnel.log"
    $tunnelOut = "C:\Temp\oll90-tunnel-out.log"
    $tunnelProc = Start-Process -FilePath $cloudflaredExe `
        -ArgumentList "tunnel --url http://localhost:3090" `
        -RedirectStandardOutput $tunnelOut -RedirectStandardError $tunnelLog `
        -PassThru -WindowStyle Hidden
    # Wait up to 15s for URL to appear
    $tunnelUrl = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $tunnelLog) {
            $logContent = Get-Content $tunnelLog -Raw -ErrorAction SilentlyContinue
            if ($logContent -match 'https://[a-z0-9\-]+\.trycloudflare\.com') {
                $tunnelUrl = $Matches[0]
                break
            }
        }
    }
    if ($tunnelUrl) {
        Write-Status "  GLOBAL URL: $tunnelUrl" 'Green'
        [System.IO.File]::WriteAllText("C:\Temp\oll90-url.txt", $tunnelUrl, [System.Text.Encoding]::UTF8)
        Write-Status "  (saved to C:\Temp\oll90-url.txt)" 'Yellow'
    } else {
        Write-Status "  Tunnel started but URL not detected yet - check C:\Temp\oll90-tunnel.log" 'Yellow'
    }
} else {
    Write-Status "  cloudflared not found - no global URL (install from https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/)" 'Yellow'
}

Write-Status "  Press Ctrl+C to stop" 'Yellow'

# Keep alive
try {
    while ($true) { Start-Sleep -Seconds 5 }
} finally {
    Write-Status "Shutting down..." 'Yellow'
    if ($backendProc -and -not $backendProc.HasExited) {
        Stop-Process -Id $backendProc.Id -Force -ErrorAction SilentlyContinue
        Write-Status "Backend stopped" 'Yellow'
    }
    if ($frontendProc -and -not $frontendProc.HasExited) {
        Stop-Process -Id $frontendProc.Id -Force -ErrorAction SilentlyContinue
        Write-Status "Frontend stopped" 'Yellow'
    }
    if ($tunnelProc -and -not $tunnelProc.HasExited) {
        Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
        Write-Status "Tunnel stopped" 'Yellow'
    }
}
