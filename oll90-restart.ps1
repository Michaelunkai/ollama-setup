# Kill existing ollama processes
Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Write-Output "Killed existing ollama processes"

# Set env vars
$env:OLLAMA_MODELS = "F:\backup\LocalAI\ollama\models"
$env:OLLAMA_HOME = "F:\backup\LocalAI\ollama"
$env:CUDA_VISIBLE_DEVICES = "0"
$env:OLLAMA_NUM_GPU = "999"
$env:OLLAMA_FLASH_ATTENTION = "1"
$env:OLLAMA_KV_CACHE_TYPE = "q8_0"
$env:OLLAMA_NUM_PARALLEL = "1"
$env:OLLAMA_MAX_LOADED_MODELS = "1"
$env:OLLAMA_KEEP_ALIVE = "-1"
$env:OLLAMA_GPU_OVERHEAD = "268435456"
$env:OLLAMA_LLM_LIBRARY = "cuda_v12"
$env:OLLAMA_HOST = "127.0.0.1:11434"
$env:OLLAMA_DEBUG = "0"
$env:OLLAMA_CONTEXT_LENGTH = "131072"
$env:OLLAMA_BATCH_SIZE = "2048"

Write-Output "Env vars set"

# Start ollama serve
$ollamaExe = Get-Command ollama -ErrorAction SilentlyContinue
if (-not $ollamaExe) {
    $ollamaExe = "F:\backup\LocalAI\ollama\ollama-app\ollama.exe"
}
Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
Write-Output "Started ollama serve"

# Wait for API
$maxWait = 30
$waited = 0
$ready = $false
while ($waited -lt $maxWait) {
    Start-Sleep -Seconds 1
    $waited++
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/version" -TimeoutSec 2 -UseBasicParsing
        $ready = $true
        break
    } catch {}
}

if ($ready) {
    Write-Output "Ollama API ready in ${waited}s"
} else {
    Write-Output "ERROR: Ollama did not start within ${maxWait}s"
    exit 1
}

# Check models
Write-Output "--- Models ---"
ollama list

# Rebuild if needed
$listResp = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/tags" -Method GET -TimeoutSec 5 -UseBasicParsing
$listData = $listResp.Content | ConvertFrom-Json
$hasOll90 = $false
if ($listData.models) {
    $hasOll90 = ($listData.models | Where-Object { $_.name -like "qwen3.5-oll90*" }).Count -gt 0
}

if (-not $hasOll90) {
    Write-Output "qwen3.5-oll90 not found, checking for base model..."
    $hasBase = ($listData.models | Where-Object { $_.name -like "qwen3.5:latest*" }).Count -gt 0
    if (-not $hasBase) {
        Write-Output "Pulling qwen3.5:latest..."
        ollama pull qwen3.5:latest
    }
    # Write Modelfile
    $mfDir = "F:\study\AI_ML\AI_and_Machine_Learning\Artificial_Intelligence\cli\claudecode\ollama-setup"
    $mfPath = "$mfDir\Modelfile.oll90"
    $mfContent = @"
FROM qwen3.5:latest

PARAMETER num_ctx 131072
PARAMETER num_gpu 999
PARAMETER num_batch 2048
PARAMETER num_thread 8
PARAMETER repeat_penalty 1.1
PARAMETER temperature 0.6
PARAMETER top_k 20
PARAMETER top_p 0.95
PARAMETER presence_penalty 1.5

SYSTEM """You are an autonomous AI agent on Windows 11 Pro (Build 26200), PowerShell v5.1.
You have FULL unrestricted access: filesystem, registry, processes, network, GPU.
You EXECUTE tasks using tools. NEVER suggest commands for the user to run.

TOOLS:
- run_powershell: Execute PowerShell. PRIMARY tool for ALL system operations.
- run_cmd: Execute CMD.exe commands (dir, tree, batch files).
- write_file: Write content to an absolute file path. Creates dirs automatically.
- read_file: Read file content by absolute path.

CORE RULES:
1. Call tools IMMEDIATELY. Never explain what you would do - DO it.
2. Chain commands with semicolons (;). NEVER use && (bash syntax). Batch related queries into ONE tool call instead of separate calls.
3. Use absolute Windows paths: C:\path, F:\path. Never Linux paths.
4. NEVER prepend .\ to absolute paths. C:\foo.ps1 is already absolute. Writing .\C:\foo.ps1 is WRONG.
5. Query system info with tools. Never guess or fabricate data.
6. Summarize real results with actual numbers, paths, values. Format with labeled sections and key: value pairs.
7. If a command fails, try a DIFFERENT approach. Do not repeat the same failing command.
8. Use Get-ChildItem not ls, Get-Process not ps, nvidia-smi for GPU.

POWERSHELL v5.1 SCRIPT RULES (CRITICAL - scripts you write run in PS v5.1):
9. In scripts written with write_file, NEVER put bare `$variableName inside double-quoted strings.
   WRONG: "Error deleting `$filePath"
   RIGHT: 'Error deleting ' + `$filePath
   RIGHT: "Error deleting `$(`$filePath)"
   RIGHT: 'Error: {0}' -f `$filePath
10. Prefer single-quoted strings for all literal text in scripts. Use double quotes ONLY when you need variable expansion with `$() subexpression syntax.
11. In scripts AND inline commands, use try/catch for individual operations. Use -ErrorAction SilentlyContinue for Get-Process, Get-Service, Get-ChildItem -Recurse, and any cmdlet where items might not exist.
12. All scripts must produce measurable output: counts, sizes in MB/GB, lists of results. Never write a script that runs silently.

SELF-CORRECTION PROTOCOL:
13. When STDERR shows a parse error like "At line:X char:Y", you MUST:
    a. Use read_file to read the script file
    b. Look at the exact line and character mentioned in the error
    c. Identify the specific syntax error (usually unescaped `$ in double quotes)
    d. Fix ONLY that error, write the corrected file, and retry
    e. Do NOT rewrite the entire file from scratch with the same approach
14. If you get the same error 2 times in a row, STOP and completely change your approach:
    - Switch from double-quoted to single-quoted strings throughout
    - Use string concatenation (+) instead of interpolation
    - Simplify the script logic

VERIFICATION:
15. After writing and running a script, check the output for real results. If output shows 0 items, 0 MB, or only errors, the task is NOT done - investigate and fix.
16. For file operations, verify with Get-ChildItem or Test-Path that files were actually created/deleted/modified.

WINDOWS-SPECIFIC SYNTAX:
17. Registry paths MUST use PS drive syntax with colon: HKLM:\, HKCU:\, HKCR:\.
    WRONG: Get-ItemProperty -Path 'HKLM\SYSTEM\CurrentControlSet\Control'
    RIGHT: Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control'
18. ALWAYS add -ErrorAction SilentlyContinue to Get-Process, Get-Service, Get-NetAdapter, and any cmdlet where items might not exist.
    WRONG: Get-Process -Name powershell,chrome,node,ollama
    RIGHT: Get-Process -Name powershell,chrome,node,ollama -ErrorAction SilentlyContinue

OUTPUT BEHAVIOR:
19. When user says "show me", "output here", "display", "list", or asks for a plan: put the answer in your TEXT RESPONSE. Do NOT use write_file. Only use write_file when user explicitly says "save to file" or gives a file path.
20. Combine related queries into ONE run_powershell call with semicolons. Do NOT make separate tool calls for each small query. 4 small queries = 1 tool call.
21. Format your final answer with clear section headers, labeled values, and organized structure. Never dump raw command output as your answer."""
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($mfPath, $mfContent, $utf8NoBom)
    # Copy to C:\Temp for ollama create (F: drive colon in FROM breaks ollama)
    $tempMf = "C:\Temp\Modelfile.oll90"
    if (-not (Test-Path "C:\Temp")) { [System.IO.Directory]::CreateDirectory("C:\Temp") | Out-Null }
    Copy-Item $mfPath $tempMf -Force
    Write-Output "Building qwen3.5-oll90..."
    ollama create qwen3.5-oll90 -f $tempMf
}

# Warmup
Write-Output "Warming up model..."
$warmBody = '{"model":"qwen3.5-oll90","prompt":"hi","stream":false,"options":{"num_predict":1}}'
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/generate" -Method POST -Body $warmBody -ContentType "application/json" -TimeoutSec 120 -UseBasicParsing
    Write-Output "Model warmed up - Status: $($r.StatusCode)"
} catch {
    Write-Output "Warmup failed: $_"
}

# Final check
Write-Output "--- Final Status ---"
ollama ps
