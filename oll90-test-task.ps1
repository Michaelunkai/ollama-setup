param(
    [Parameter(Mandatory=$true)]
    [string]$TaskPrompt,
    [int]$TaskNumber = 0,
    [string]$Model = "qwen3.5-oll90",
    [string]$OllamaUrl = "http://127.0.0.1:11434",
    [int]$TimeoutSec = 300
)

$ErrorActionPreference = "Continue"

# --- State tracking ---
$script:recentErrors = [System.Collections.ArrayList]::new()
$script:maxRepeatedErrors = 3
$script:errorPatternWindow = 5
$script:shallowScanRePrompted = $false
$script:thinkingRePrompted = $false

function ConvertTo-Hashtable {
    param([object]$Object)
    if ($Object -is [System.Collections.Hashtable]) { return $Object }
    if ($Object -is [string]) {
        try { $Object = $Object | ConvertFrom-Json } catch { return @{ value = $Object } }
    }
    $ht = @{}
    if ($Object -and $Object.PSObject) {
        $Object.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
    }
    return $ht
}

function Format-ToolCommand {
    param([string]$Text, [int]$MaxLen = 100)
    if ($Text.Length -gt $MaxLen) {
        return $Text.Substring(0, $MaxLen) + '...'
    }
    return $Text
}

# ============================================================================
# STDERR ANALYSIS
# ============================================================================
function Analyze-Stderr {
    param([string]$Stderr)
    if (-not $Stderr) { return $null }

    $parseMatch = [regex]::Match($Stderr, 'At\s+(?:(.+?):)?(\d+)\s+char:(\d+)')
    if ($parseMatch.Success) {
        $filePath = $parseMatch.Groups[1].Value
        $lineNum = [int]$parseMatch.Groups[2].Value
        $charPos = [int]$parseMatch.Groups[3].Value

        $lines = $Stderr -split "`n"
        $errDetail = ($lines | Where-Object { $_ -match 'missing|unexpected|variable|expression|token|string|recognized' } | Select-Object -First 1)
        if (-not $errDetail) { $errDetail = ($lines | Select-Object -Last 1) }

        $hint = "[AGENT HINT] PARSE ERROR at line $lineNum char $charPos"
        if ($filePath) { $hint += " in $filePath" }
        if ($errDetail -match '\$' -or $errDetail -match 'variable' -or $errDetail -match 'expression' -or $errDetail -match 'Variable reference') {
            $hint += ". CAUSE: Unescaped dollar-sign in double-quoted string. FIX: Use single quotes for literal strings, or use the subexpression syntax with dollar-sign-parentheses for variable expansion. Do NOT rewrite with the same approach."
        } else {
            $hint += '. Error: ' + $errDetail.Trim() + '. Read the file at that line to diagnose.'
        }
        return $hint
    }

    if ($Stderr -match 'property cannot be processed because the property "(.+)" already exists') {
        $dupProp = $Matches[1]
        return "[AGENT HINT] DUPLICATE PROPERTY '$dupProp' in Select-Object. You listed '$dupProp' as both a raw property AND as N= in a calculated property @{N='$dupProp'...}. Remove one - use either the plain property name OR the calculated @{N=...}, never both."
    }

    if ($Stderr -match 'Access.+denied|UnauthorizedAccess|PermissionDenied') {
        return "[AGENT HINT] ACCESS DENIED. Try -ErrorAction SilentlyContinue for bulk operations or skip protected items."
    }

    return $null
}

# ============================================================================
# TOOL DISPATCHER
# ============================================================================
function Invoke-Tool {
    param([string]$Name, [hashtable]$Arguments)
    $maxOutputChars = 30000
    $toolTimeoutMs = 60000

    switch ($Name) {
        "run_powershell" {
            $command = $Arguments["command"]
            if (-not $command) { return "[EXEC-PS] ERROR: No command provided" }
            $cmdDisplay = Format-ToolCommand -Text $command
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "run_powershell" -ForegroundColor Yellow -NoNewline
            Write-Host "(" -ForegroundColor DarkGray -NoNewline
            Write-Host "$cmdDisplay" -ForegroundColor White -NoNewline
            Write-Host ")" -ForegroundColor DarkGray
            try {
                $tempScript = [System.IO.Path]::GetTempPath() + "oll90_cmd_" + [guid]::NewGuid().ToString("N") + ".ps1"
                $tempOut = [System.IO.Path]::GetTempFileName()
                $tempErr = [System.IO.Path]::GetTempFileName()
                [System.IO.File]::WriteAllText($tempScript, $command, [System.Text.Encoding]::UTF8)
                $proc = Start-Process -FilePath "powershell.exe" `
                    -ArgumentList "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", $tempScript `
                    -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr `
                    -NoNewWindow -PassThru
                $exited = $proc.WaitForExit($toolTimeoutMs)
                if (-not $exited) { try { $proc.Kill() } catch {}; return "[EXEC-PS] ERROR: Timed out" }
                $stdout = ""; $stderr = ""
                if (Test-Path $tempOut) { $stdout = [System.IO.File]::ReadAllText($tempOut) }
                if (Test-Path $tempErr) { $stderr = [System.IO.File]::ReadAllText($tempErr) }
                Remove-Item $tempOut, $tempErr, $tempScript -ErrorAction SilentlyContinue
                $result = $stdout
                if ($stderr.Trim()) {
                    $result += "`nSTDERR: $stderr"
                    Write-Host "    " -NoNewline
                    Write-Host "! STDERR" -ForegroundColor Red
                    $stderrLines = ($stderr.Trim() -split "`n" | Select-Object -First 3)
                    foreach ($sl in $stderrLines) {
                        Write-Host "      $($sl.Trim())" -ForegroundColor Red
                    }
                    if (($stderr.Trim() -split "`n").Count -gt 3) {
                        Write-Host "      ..." -ForegroundColor DarkGray
                    }
                    $stderrHint = Analyze-Stderr $stderr
                    if ($stderrHint) {
                        $result += "`n$stderrHint"
                        $hintText = $stderrHint -replace '^\[AGENT HINT\]\s*', ''
                        Write-Host "    " -NoNewline
                        Write-Host "* HINT: " -ForegroundColor Yellow -NoNewline
                        Write-Host "$hintText" -ForegroundColor Yellow
                        $errorSig = [regex]::Match($stderr, 'At\s+.+?:(\d+)\s+char:(\d+)').Value
                        if (-not $errorSig) { $errorSig = $stderr.Substring(0, [Math]::Min(100, $stderr.Length)) }
                        [void]$script:recentErrors.Add($errorSig)
                        if ($script:recentErrors.Count -gt $script:errorPatternWindow) { $script:recentErrors.RemoveAt(0) }
                    }
                }
                if (-not $result.Trim()) { $result = "(no output)" }
                if ($result.Length -gt $maxOutputChars) { $result = $result.Substring(0, $maxOutputChars) + "`n...[TRUNCATED]" }
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($result.Length) chars" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                if ($result -match 'ERROR:' -or $result -match 'STDERR:') {
                    Write-Host "ERROR" -ForegroundColor Red
                } else {
                    Write-Host "OK" -ForegroundColor Green
                }
                return "[EXEC-PS] $result"
            } catch { return "[EXEC-PS] ERROR: $($_.Exception.Message)" }
        }
        "run_cmd" {
            $command = $Arguments["command"]
            if (-not $command) { return "[EXEC-CMD] ERROR: No command provided" }
            $cmdDisplay = Format-ToolCommand -Text $command
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "run_cmd" -ForegroundColor Yellow -NoNewline
            Write-Host "(" -ForegroundColor DarkGray -NoNewline
            Write-Host "$cmdDisplay" -ForegroundColor White -NoNewline
            Write-Host ")" -ForegroundColor DarkGray
            try {
                $tempOut = [System.IO.Path]::GetTempFileName()
                $tempErr = [System.IO.Path]::GetTempFileName()
                $proc = Start-Process -FilePath "cmd.exe" `
                    -ArgumentList "/c", $command `
                    -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr `
                    -NoNewWindow -PassThru
                $exited = $proc.WaitForExit($toolTimeoutMs)
                if (-not $exited) { try { $proc.Kill() } catch {}; return "[EXEC-CMD] ERROR: Timed out" }
                $stdout = ""; $stderr = ""
                if (Test-Path $tempOut) { $stdout = [System.IO.File]::ReadAllText($tempOut) }
                if (Test-Path $tempErr) { $stderr = [System.IO.File]::ReadAllText($tempErr) }
                Remove-Item $tempOut, $tempErr -ErrorAction SilentlyContinue
                $result = $stdout
                if ($stderr.Trim()) { $result += "`nSTDERR: $stderr" }
                if (-not $result.Trim()) { $result = "(no output)" }
                if ($result.Length -gt $maxOutputChars) { $result = $result.Substring(0, $maxOutputChars) + "`n...[TRUNCATED]" }
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($result.Length) chars" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                if ($result -match 'ERROR:' -or $result -match 'STDERR:') {
                    Write-Host "ERROR" -ForegroundColor Red
                } else {
                    Write-Host "OK" -ForegroundColor Green
                }
                return "[EXEC-CMD] $result"
            } catch { return "[EXEC-CMD] ERROR: $($_.Exception.Message)" }
        }
        "write_file" {
            $path = $Arguments["path"]; $content = $Arguments["content"]
            if (-not $path) { return "[WRITE] ERROR: No path provided" }
            if ($null -eq $content) { $content = "" }
            # Sanitize: strip leading .\ from absolute paths
            if ($path -match '^\.[/\\][A-Za-z]:\\') {
                $path = $path.Substring(2)
                Write-Host "  [WARN] Stripped leading '.\\' from absolute path -> $path" -ForegroundColor Yellow
            }
            # PLAN/REPORT INTERCEPTOR: Block write_file when user didn't ask for a file
            $userAskedForFile = ($TaskPrompt -match '(?i)(save|write to|create file|output to|log to|\.txt|\.ps1|\.json|\.csv|store to)')
            if (-not $userAskedForFile) {
                $looksLikePlan = ($path -match '(?i)(plan|report|analysis|optimization|summary|result)') -or `
                    ($content.Length -gt 300 -and $content -match '(?i)(plan|phase|step|optimization|summary)')
                if ($looksLikePlan) {
                    Write-Host "    " -NoNewline
                    Write-Host "! BLOCKED " -ForegroundColor Red -NoNewline
                    Write-Host "write_file($path) - user wants output HERE not in file" -ForegroundColor Yellow
                    return "[WRITE] BLOCKED: The user asked to see this in the conversation, not saved to a file. Present the content DIRECTLY in your text response now. Do NOT retry write_file."
                }
            }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "write_file" -ForegroundColor Yellow -NoNewline
            Write-Host "(" -ForegroundColor DarkGray -NoNewline
            Write-Host "$path" -ForegroundColor White -NoNewline
            Write-Host ")" -ForegroundColor DarkGray
            try {
                $dir = [System.IO.Path]::GetDirectoryName($path)
                if ($dir -and -not (Test-Path $dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
                $size = (Get-Item $path).Length
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$size bytes" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                Write-Host "OK" -ForegroundColor Green -NoNewline
                Write-Host " -> $path" -ForegroundColor DarkGray
                return "[WRITE] Successfully wrote $size bytes to $path"
            } catch { return "[WRITE] ERROR: $($_.Exception.Message)" }
        }
        "read_file" {
            $path = $Arguments["path"]
            if (-not $path) { return "[READ] ERROR: No path provided" }
            # Sanitize: strip leading .\ from absolute paths
            if ($path -match '^\.[/\\][A-Za-z]:\\') {
                $path = $path.Substring(2)
                Write-Host "  [WARN] Stripped leading '.\\' from absolute path -> $path" -ForegroundColor Yellow
            }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "read_file" -ForegroundColor Yellow -NoNewline
            Write-Host "(" -ForegroundColor DarkGray -NoNewline
            Write-Host "$path" -ForegroundColor White -NoNewline
            Write-Host ")" -ForegroundColor DarkGray
            try {
                if (-not (Test-Path $path)) { return "[READ] ERROR: File not found: $path" }
                $content = [System.IO.File]::ReadAllText($path)
                if ($content.Length -gt $maxOutputChars) { $content = $content.Substring(0, $maxOutputChars) + "`n...[TRUNCATED]" }
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($content.Length) chars" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                Write-Host "OK" -ForegroundColor Green
                return "[READ] $content"
            } catch { return "[READ] ERROR: $($_.Exception.Message)" }
        }
        default { return "ERROR: Unknown tool '$Name'" }
    }
}

$tools = @(
    @{ type = "function"; function = @{ name = "run_powershell"; description = "Execute a PowerShell command on Windows 11 Pro. Returns stdout and stderr. Use for ALL system operations. Chain commands with semicolons (;), NEVER use &&. Use absolute Windows paths."; parameters = @{ type = "object"; properties = @{ command = @{ type = "string"; description = "The PowerShell command to execute" } }; required = @("command") } } }
    @{ type = "function"; function = @{ name = "run_cmd"; description = "Execute a CMD.exe command."; parameters = @{ type = "object"; properties = @{ command = @{ type = "string"; description = "The CMD command to execute" } }; required = @("command") } } }
    @{ type = "function"; function = @{ name = "write_file"; description = "Write content to a file at the specified absolute Windows path. Creates parent directories. NEVER prepend .\ to absolute paths."; parameters = @{ type = "object"; properties = @{ path = @{ type = "string"; description = "Absolute file path (e.g. C:\Temp\output.txt)" }; content = @{ type = "string"; description = "Content to write" } }; required = @("path", "content") } } }
    @{ type = "function"; function = @{ name = "read_file"; description = "Read entire content of a file at the specified absolute Windows path."; parameters = @{ type = "object"; properties = @{ path = @{ type = "string"; description = "Absolute file path to read" } }; required = @("path") } } }
)

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "TASK $TaskNumber : $TaskPrompt" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$messages = [System.Collections.ArrayList]::new()
[void]$messages.Add(@{ role = "user"; content = $TaskPrompt })

$maxIter = 25
$iteration = 0
$success = $false
$taskStart = Get-Date
$allToolResults = [System.Collections.ArrayList]::new()
$allStderrHits = [System.Collections.ArrayList]::new()

while ($iteration -lt $maxIter) {
    $iteration++
    $elapsed = ((Get-Date) - $taskStart).ToString("mm\:ss")
    Write-Host ""
    Write-Host "  ------ " -ForegroundColor DarkGray -NoNewline
    Write-Host "Step $iteration" -ForegroundColor Cyan -NoNewline
    Write-Host "/$maxIter" -ForegroundColor DarkGray -NoNewline
    Write-Host " ------ " -ForegroundColor DarkGray -NoNewline
    Write-Host "$elapsed" -ForegroundColor DarkGray

    $body = @{ model = $Model; messages = @($messages); tools = $tools; stream = $false }
    $json = $body | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    try {
        $response = Invoke-WebRequest -Uri "$OllamaUrl/api/chat" -Method POST -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec $TimeoutSec -UseBasicParsing
        $parsed = $response.Content | ConvertFrom-Json
    } catch {
        Write-Host "[ERROR] API call failed: $($_.Exception.Message)" -ForegroundColor Red
        break
    }

    if (-not $parsed -or -not $parsed.message) {
        Write-Host "[ERROR] Unexpected response format" -ForegroundColor Red
        break
    }

    $msg = $parsed.message
    $hasToolCalls = ($msg.tool_calls -and $msg.tool_calls.Count -gt 0)

    if ($hasToolCalls) {
        $assistantMsg = @{ role = "assistant"; content = if ($msg.content) { $msg.content } else { "" }; tool_calls = @($msg.tool_calls) }
        [void]$messages.Add($assistantMsg)
        if ($msg.content -and $msg.content.Trim()) {
            $cleanContent = [regex]::Replace($msg.content, '(?s)<think>.*?</think>', '').Trim()
            if ($cleanContent) {
                Write-Host ""
                Write-Host "  .----- AGENT -------." -ForegroundColor Magenta
                $lines = $cleanContent -split "`n"
                foreach ($line in $lines) {
                    Write-Host "  | " -ForegroundColor Magenta -NoNewline
                    Write-Host "$line" -ForegroundColor White
                }
                Write-Host "  '--------------------'" -ForegroundColor Magenta
                Write-Host ""
            }
        }
        foreach ($tc in $msg.tool_calls) {
            $toolName = $tc.function.name
            $toolArgs = $tc.function.arguments
            if ($toolArgs -is [string]) { try { $toolArgs = $toolArgs | ConvertFrom-Json } catch { $toolArgs = @{ command = $toolArgs } } }
            $toolArgsHt = ConvertTo-Hashtable $toolArgs
            $toolResult = Invoke-Tool -Name $toolName -Arguments $toolArgsHt
            [void]$messages.Add(@{ role = "tool"; content = $toolResult })
            [void]$allToolResults.Add(@{ tool = $toolName; result = $toolResult; iteration = $iteration })

            # Track STDERR hits
            if ($toolResult -match 'STDERR:') {
                [void]$allStderrHits.Add(@{ iteration = $iteration; tool = $toolName })
            }
        }

        # --- STUCK DETECTION ---
        if ($script:recentErrors.Count -ge $script:maxRepeatedErrors) {
            $lastN = @($script:recentErrors | Select-Object -Last $script:maxRepeatedErrors)
            $uniqueErrors = @($lastN | Sort-Object -Unique)
            if ($uniqueErrors.Count -eq 1) {
                Write-Host ""
                Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
                Write-Host "   STUCK DETECTED - Same error $($script:maxRepeatedErrors)x in a row" -ForegroundColor Red
                Write-Host "   Forcing new approach..." -ForegroundColor Yellow
                Write-Host "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
                Write-Host ""
                $stuckMsg = "[SYSTEM] WARNING: You have made the same error $($script:maxRepeatedErrors) times in a row. You MUST try a completely different approach. Switch to single-quoted strings with concatenation (+), avoid all variable interpolation in double quotes, and simplify the script."
                [void]$messages.Add(@{ role = "user"; content = $stuckMsg })
                $script:recentErrors.Clear()
            }
        }

        continue
    } else {
        # Model stopped calling tools - verify actual success
        [void]$messages.Add(@{ role = "assistant"; content = if ($msg.content) { $msg.content } else { "" } })
        $content = $msg.content

        $cleanContent = ""
        if ($content) {
            $cleanContent = [regex]::Replace($content, '(?s)<think>.*?</think>', '').Trim()
        }
        $onlyThinking = (-not $cleanContent -and $content -and $content -match '(?s)<think>')

        # --- SHALLOW SCAN CHECK ---
        $isDeepScanTask = $TaskPrompt -match '(?i)(scan deeply|deep scan|deeply scan)'
        if ($isDeepScanTask -and $allToolResults.Count -lt 5 -and -not $script:shallowScanRePrompted) {
            $script:shallowScanRePrompted = $true
            Write-Host ""
            Write-Host "  [SHALLOW SCAN: $($allToolResults.Count) tool calls - requiring deeper scan]" -ForegroundColor Yellow
            Write-Host ""
            $rePrompt = "[SYSTEM] Your scan was too shallow ($($allToolResults.Count) tool calls). The task requires a DEEP scan. You MUST call run_powershell multiple more times to gather: CPU specs, GPU details (nvidia-smi), RAM, storage drives, network adapters, top processes by memory, temperatures, and system performance. Make at least 5+ more tool calls before writing your plan."
            [void]$messages.Add(@{ role = "user"; content = $rePrompt })
            continue
        }

        # --- THINKING-ONLY CHECK ---
        if ($onlyThinking -and -not $script:thinkingRePrompted) {
            $script:thinkingRePrompted = $true
            Write-Host ""
            Write-Host "  [thinking-only response - prompting for visible output]" -ForegroundColor Yellow
            Write-Host ""
            $rePrompt = "[SYSTEM] CRITICAL: Your last response was ENTIRELY inside <think> blocks. The user CANNOT see <think> content. You MUST output your plan as PLAIN VISIBLE TEXT - no <think> tags. Write the plan directly as your text response RIGHT NOW."
            [void]$messages.Add(@{ role = "user"; content = $rePrompt })
            continue
        }

        # Display final response
        if ($cleanContent) {
            Write-Host ""
            Write-Host "  .----- AGENT -------." -ForegroundColor Magenta
            $lines = $cleanContent -split "`n"
            foreach ($line in $lines) {
                Write-Host "  | " -ForegroundColor Magenta -NoNewline
                Write-Host "$line" -ForegroundColor White
            }
            Write-Host "  '--------------------'" -ForegroundColor Magenta
            Write-Host ""
        } elseif ($onlyThinking) {
            # Fallback: model still putting everything in thinking after re-prompt - extract and show
            $thinkContent = [regex]::Match($content, '(?s)<think>(.*?)</think>').Groups[1].Value.Trim()
            if ($thinkContent) {
                Write-Host ""
                Write-Host "  .----- AGENT [extracted from thinking] -------." -ForegroundColor DarkYellow
                $lines = $thinkContent -split "`n"
                $displayLines = @($lines | Select-Object -First 60)
                foreach ($line in $displayLines) {
                    Write-Host "  | " -ForegroundColor DarkYellow -NoNewline
                    Write-Host $line -ForegroundColor White
                }
                if ($lines.Count -gt 60) {
                    Write-Host "  | ... ($($lines.Count - 60) more lines truncated)" -ForegroundColor DarkGray
                }
                Write-Host "  '----------------------------------------------'" -ForegroundColor DarkYellow
                Write-Host ""
            }
        }

        # --- REAL SUCCESS VERIFICATION ---
        $hasUncorrectedErrors = $false
        $lastToolResults = @($allToolResults | Select-Object -Last 3)
        foreach ($tr in $lastToolResults) {
            if ($tr.result -match 'STDERR:' -and $tr.result -notmatch 'AGENT HINT') {
                $hasUncorrectedErrors = $true
            }
        }

        # Check if any tool produced meaningful output
        $hasMeaningfulOutput = $false
        foreach ($tr in $allToolResults) {
            if ($tr.result -match '\d+(\.\d+)?\s*(MB|GB|files|items|bytes|KB|entries|services|processes|adapters|drives)' -and $tr.result -notmatch 'ERROR:') {
                $hasMeaningfulOutput = $true
                break
            }
            if ($tr.tool -eq 'write_file' -and $tr.result -match 'Successfully wrote \d+ bytes') {
                $hasMeaningfulOutput = $true
                break
            }
            if ($tr.tool -eq 'run_powershell' -and $tr.result.Length -gt 100 -and $tr.result -notmatch 'ERROR:') {
                $hasMeaningfulOutput = $true
                break
            }
        }

        if ($hasUncorrectedErrors) {
            $success = $false
            Write-Host "[VERIFY] FAIL: Last tool results still contain STDERR errors" -ForegroundColor Red
        } elseif ($allToolResults.Count -eq 0) {
            $success = $false
            Write-Host "[VERIFY] FAIL: No tools were called" -ForegroundColor Red
        } elseif (-not $hasMeaningfulOutput) {
            # Warn but don't fail - some tasks may have short output
            $success = $true
            Write-Host "[VERIFY] WARN: No measurable results detected in tool output" -ForegroundColor Yellow
        } else {
            $success = $true
        }
        break
    }
}

# --- SUMMARY BANNER ---
$taskDuration = ((Get-Date) - $taskStart).ToString("mm\:ss")
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
if ($success) {
    Write-Host "  TASK $TaskNumber : PASS" -ForegroundColor Green
} else {
    Write-Host "  TASK $TaskNumber : FAIL" -ForegroundColor Red
}
Write-Host "  Iterations:  $iteration / $maxIter" -ForegroundColor White
Write-Host "  Duration:    $taskDuration" -ForegroundColor White
Write-Host "  Tool calls:  $($allToolResults.Count)" -ForegroundColor White
$stderrColor = if ($allStderrHits.Count -gt 0) { "Yellow" } else { "White" }
Write-Host "  STDERR hits: $($allStderrHits.Count)" -ForegroundColor $stderrColor
Write-Host "==========================================" -ForegroundColor Cyan

# Return structured result for harness consumption
@{
    TaskNumber = $TaskNumber
    Success = $success
    Iterations = $iteration
    Duration = $taskDuration
    ToolCalls = $allToolResults.Count
    StderrHits = $allStderrHits.Count
}
