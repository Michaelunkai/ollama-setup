param(
    [string]$Model = "qwen3.5-oll90",
    [string]$OllamaUrl = "http://127.0.0.1:11434",
    [int]$TimeoutSec = 300,
    [int[]]$RunTasks = @()
)

$ErrorActionPreference = "Continue"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$testTaskScript = Join-Path $scriptDir "oll90-test-task.ps1"

if (-not (Test-Path $testTaskScript)) {
    Write-Host "[FATAL] oll90-test-task.ps1 not found at $testTaskScript" -ForegroundColor Red
    exit 1
}

# ============================================================================
# 10 COMPLICATED TASKS
# ============================================================================
$allTasks = @(
    @{
        Num = 1
        Name = "Write+Run Large PS Cleanup Script"
        Prompt = "Write a PowerShell script to C:\Temp\cleanup-temp.ps1 that scans C:\Windows\Temp, the current user AppData\Local\Temp folder, and C:\Temp for files older than 7 days. The script must be at least 100 lines. It must use try/catch for each file deletion, count files deleted vs skipped, calculate total MB freed using file lengths before deletion, and print a summary table at the end showing each folder scanned, files found, files deleted, files skipped, and MB freed. Use single-quoted strings for all literals. Then run the script and show me the results."
        Verify = { Test-Path "C:\Temp\cleanup-temp.ps1" }
    }
    @{
        Num = 2
        Name = "Multi-Subsystem Info Report"
        Prompt = "Gather and display a complete system report in one run: CPU name and core count using Get-WmiObject Win32_Processor, total and available RAM in GB using Get-WmiObject Win32_OperatingSystem, all disk drives with total and free space in GB using Get-WmiObject Win32_LogicalDisk, GPU name and driver version using nvidia-smi, Windows build version from registry, and system uptime. Present all data clearly with labels."
        Verify = { $true }
    }
    @{
        Num = 3
        Name = "Special Characters in File Paths"
        Prompt = "Create a directory C:\Temp\test-special\sub1 and write a file inside it called notes.txt with the content 'Hello from special path test'. Then read the file back using read_file and confirm the content matches what was written."
        Verify = { Test-Path "C:\Temp\test-special\sub1\notes.txt" }
    }
    @{
        Num = 4
        Name = "Registry Query and Analysis"
        Prompt = "Query the Windows registry at HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion and extract these values: ProductName, CurrentBuild, DisplayVersion, and InstallDate. Convert the InstallDate from Unix timestamp to a readable date format using PowerShell. Also query HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full for the Release value and map it to the .NET version number. Present all results."
        Verify = { $true }
    }
    @{
        Num = 5
        Name = "Network Diagnostics"
        Prompt = "Run a network diagnostic: first show all active network adapters with their IP addresses using Get-NetAdapter and Get-NetIPAddress. Then test DNS resolution for google.com using Resolve-DnsName. Then measure ping latency to 8.8.8.8 with 3 pings using Test-Connection. Present all results with actual values."
        Verify = { $true }
    }
    @{
        Num = 6
        Name = "Self-Verifying Script"
        Prompt = "Write a PowerShell script to C:\Temp\self-test.ps1 that: 1) generates a random number between 1000 and 9999, 2) writes that number to C:\Temp\self-test-output.txt, 3) reads the file back, 4) compares the written and read values, 5) prints PASS if they match or FAIL if they do not. Use single-quoted strings for all literals. Run the script, then use read_file to read C:\Temp\self-test-output.txt and confirm a number is there."
        Verify = { Test-Path "C:\Temp\self-test-output.txt" }
    }
    @{
        Num = 7
        Name = "Bulk File Create-Read-Delete"
        Prompt = "Create 20 test files in C:\Temp\bulk-test\ named file-001.txt through file-020.txt. Each file should contain the text 'File number X' where X is the file number. Then count all files in that directory to verify 20 exist. Then delete all 20 files and the directory. Report: files created, files verified, files deleted."
        Verify = { -not (Test-Path "C:\Temp\bulk-test\file-001.txt") }
    }
    @{
        Num = 8
        Name = "GPU Performance Analysis"
        Prompt = "Get detailed GPU information by running nvidia-smi with the query flag: nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,memory.free,temperature.gpu,power.draw,clocks.gr,clocks.mem --format=csv,noheader,nounits. Parse each value and present it in a labeled format showing GPU Name, Driver, Total VRAM, Used VRAM, Free VRAM, Temperature, Power Draw, GPU Clock, Memory Clock with proper units (MB, C, W, MHz)."
        Verify = { $true }
    }
    @{
        Num = 9
        Name = "Service Management Analysis"
        Prompt = "List the top 10 Windows services by memory usage. Use Get-Process to find service processes, then match them with Get-Service data. Show service name, display name, status, and memory in MB. Also check the Spooler service: show its status, start type, and list its dependent services using Get-Service -Name Spooler -DependentServices."
        Verify = { $true }
    }
    @{
        Num = 10
        Name = "Multi-Step Workflow with Log"
        Prompt = "Execute this multi-step workflow: 1) Get the current date and system hostname using Get-Date and hostname. 2) Create C:\Temp\workflow-log.txt and write a header line with the date and hostname. 3) Get disk C: free space in GB using Get-WmiObject and append it to the log. 4) Get the top 3 CPU-consuming processes using Get-Process and append their names and CPU values to the log. 5) Get GPU temperature using nvidia-smi and append it to the log. 6) Use read_file to read the final log file and display its full contents."
        Verify = { (Test-Path "C:\Temp\workflow-log.txt") -and ((Get-Item "C:\Temp\workflow-log.txt").Length -gt 50) }
    }
)

# Filter tasks if -RunTasks specified
if ($RunTasks.Count -gt 0) {
    $tasksToRun = @($allTasks | Where-Object { $RunTasks -contains $_.Num })
} else {
    $tasksToRun = $allTasks
}

if ($tasksToRun.Count -eq 0) {
    Write-Host "[ERROR] No tasks matched. Available: 1-10" -ForegroundColor Red
    exit 1
}

# ============================================================================
# BANNER
# ============================================================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "  OLL90 TEST HARNESS - $($tasksToRun.Count) Tasks" -ForegroundColor Magenta
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "  Model:    $Model" -ForegroundColor White
Write-Host "  Endpoint: $OllamaUrl" -ForegroundColor White
Write-Host "  Timeout:  ${TimeoutSec}s per API call" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host ""

# ============================================================================
# RUN EACH TASK
# ============================================================================
$results = [System.Collections.ArrayList]::new()
$overallStart = Get-Date

foreach ($task in $tasksToRun) {
    Write-Host ""
    Write-Host "$('=' * 60)" -ForegroundColor Magenta
    Write-Host "  TASK $($task.Num): $($task.Name)" -ForegroundColor Magenta
    Write-Host "$('=' * 60)" -ForegroundColor Magenta

    $taskResult = $null
    try {
        $taskResult = & $testTaskScript -TaskPrompt $task.Prompt -TaskNumber $task.Num -Model $Model -OllamaUrl $OllamaUrl -TimeoutSec $TimeoutSec
    } catch {
        Write-Host "[ERROR] Task $($task.Num) threw exception: $($_.Exception.Message)" -ForegroundColor Red
        $taskResult = @{ Success = $false; Iterations = 0; Duration = "00:00"; ToolCalls = 0; StderrHits = 0 }
    }

    # Run verification scriptblock
    $verifyPassed = $true
    if ($task.Verify) {
        try {
            $verifyPassed = (& $task.Verify) -eq $true
        } catch {
            $verifyPassed = $false
        }
    }

    $modelSuccess = $false
    if ($taskResult -is [hashtable]) {
        $modelSuccess = $taskResult.Success -eq $true
    }

    $finalPass = $modelSuccess -and $verifyPassed
    [void]$results.Add(@{
        Num = $task.Num
        Name = $task.Name
        Pass = $finalPass
        ModelPass = $modelSuccess
        VerifyPass = $verifyPassed
        Iterations = if ($taskResult.Iterations) { $taskResult.Iterations } else { 0 }
        Duration = if ($taskResult.Duration) { $taskResult.Duration } else { "00:00" }
        ToolCalls = if ($taskResult.ToolCalls) { $taskResult.ToolCalls } else { 0 }
        StderrHits = if ($taskResult.StderrHits) { $taskResult.StderrHits } else { 0 }
    })

    $statusText = if ($finalPass) { "PASS" } else { "FAIL" }
    $statusColor = if ($finalPass) { "Green" } else { "Red" }
    Write-Host ""
    Write-Host "  >> Task $($task.Num) Result: $statusText (Model: $modelSuccess, Verify: $verifyPassed)" -ForegroundColor $statusColor
}

# ============================================================================
# FINAL SCORECARD
# ============================================================================
$overallDuration = ((Get-Date) - $overallStart).ToString("hh\:mm\:ss")
$passed = @($results | Where-Object { $_.Pass }).Count
$failed = $results.Count - $passed

Write-Host ""
Write-Host ""
Write-Host "$('=' * 60)" -ForegroundColor Cyan
Write-Host "  FINAL SCORECARD" -ForegroundColor Cyan
Write-Host "$('=' * 60)" -ForegroundColor Cyan
$scoreColor = if ($failed -eq 0) { "Green" } else { "Red" }
Write-Host "  Total: $($results.Count)  Pass: $passed  Fail: $failed" -ForegroundColor $scoreColor
Write-Host "  Total time: $overallDuration" -ForegroundColor White
Write-Host ""

foreach ($r in $results) {
    $status = if ($r.Pass) { "PASS" } else { "FAIL" }
    $color = if ($r.Pass) { "Green" } else { "Red" }
    Write-Host "  [$status] Task $($r.Num): $($r.Name)" -ForegroundColor $color
    Write-Host "         Steps: $($r.Iterations)  Time: $($r.Duration)  Tools: $($r.ToolCalls)  Errors: $($r.StderrHits)" -ForegroundColor DarkGray
    if (-not $r.ModelPass) { Write-Host "         >> Model reported failure" -ForegroundColor Yellow }
    if (-not $r.VerifyPass) { Write-Host "         >> Verification check failed" -ForegroundColor Yellow }
}

Write-Host ""
Write-Host "$('=' * 60)" -ForegroundColor Cyan

# Return summary for programmatic use
@{
    Total = $results.Count
    Passed = $passed
    Failed = $failed
    Duration = $overallDuration
    Results = $results
}
