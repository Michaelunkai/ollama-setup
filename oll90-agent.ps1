param(
    [string]$InitialPrompt = "",
    [string]$Model = "qwen3.5-oll90",
    [string]$OllamaUrl = "http://127.0.0.1:11434",
    [int]$TimeoutSec = 300
)

$ErrorActionPreference = "Continue"

# ============================================================================
# VT100: Enable ANSI escape codes on Windows console
# ============================================================================
try {
    $VT100_TYPE = @'
using System;
using System.Runtime.InteropServices;
public class VT100 {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleMode(IntPtr h, uint m);
    public static bool Enable() {
        IntPtr h = GetStdHandle(-11);
        uint m;
        if (!GetConsoleMode(h, out m)) return false;
        return SetConsoleMode(h, m | 0x0004);
    }
}
'@
    if (-not ([System.Management.Automation.PSTypeName]'VT100').Type) {
        Add-Type -TypeDefinition $VT100_TYPE -Language CSharp -ErrorAction SilentlyContinue
    }
    $script:vt100Enabled = [VT100]::Enable()
} catch {
    $script:vt100Enabled = $false
}

# ANSI color helpers (only used when VT100 enabled)
$script:ESC = [char]27
function Write-Ansi {
    param([string]$Text, [string]$Color = "37")
    if ($script:vt100Enabled) {
        Write-Host "$($script:ESC)[$($Color)m$Text$($script:ESC)[0m" -NoNewline
    } else {
        Write-Host $Text -NoNewline
    }
}

# ============================================================================
# HELPER: Convert PSCustomObject to Hashtable (PS v5.1 ConvertFrom-Json fix)
# ============================================================================
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

# ============================================================================
# DISPLAY HELPER: Truncate tool command for clean display
# ============================================================================
function Format-ToolCommand {
    param([string]$Text, [int]$MaxLen = 100)
    if ($Text.Length -gt $MaxLen) {
        return $Text.Substring(0, $MaxLen) + '...'
    }
    return $Text
}

# ============================================================================
# TOOL DISPATCHER: Execute tool calls from the model
# ============================================================================
function Invoke-Tool {
    param(
        [string]$Name,
        [hashtable]$Arguments
    )

    $maxOutputChars = 30000
    $toolCallStart = [System.Diagnostics.Stopwatch]::StartNew()
    # Per-tool timeouts (ms)
    $toolTimeouts = @{
        "run_powershell" = 180000   # 3 min - scripts can take time
        "run_cmd"        = 180000   # 3 min
        "run_python"     = 120000   # 2 min
        "web_fetch"      = 15000    # 15s
        "web_search"     = 15000    # 15s
        "download_file"  = 300000   # 5 min for large files
        "git_command"    = 30000    # 30s
        "default"        = 60000    # 60s for everything else
    }
    $toolTimeoutMs = if ($toolTimeouts.ContainsKey($Name)) { $toolTimeouts[$Name] } else { $toolTimeouts["default"] }

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
                    -RedirectStandardOutput $tempOut `
                    -RedirectStandardError $tempErr `
                    -NoNewWindow -PassThru
                $exited = $proc.WaitForExit($toolTimeoutMs)
                if (-not $exited) {
                    try { $proc.Kill() } catch {}
                    return "[EXEC-PS] ERROR: Command timed out after $([int]($toolTimeoutMs/1000))s"
                }
                $stdout = ""
                $stderr = ""
                if (Test-Path $tempOut) { $stdout = [System.IO.File]::ReadAllText($tempOut) }
                if (Test-Path $tempErr) { $stderr = [System.IO.File]::ReadAllText($tempErr) }
                Remove-Item $tempOut, $tempErr, $tempScript -ErrorAction SilentlyContinue
                $result = $stdout
                if ($stderr.Trim()) {
                    $result += "`nSTDERR: $stderr"
                    # Visual STDERR block
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
                        # Track for loop detection
                        $errorSig = [regex]::Match($stderr, 'At\s+.+?:(\d+)\s+char:(\d+)').Value
                        if (-not $errorSig) { $errorSig = $stderr.Substring(0, [Math]::Min(100, $stderr.Length)) }
                        [void]$script:recentErrors.Add($errorSig)
                        if ($script:recentErrors.Count -gt $script:errorPatternWindow) { $script:recentErrors.RemoveAt(0) }
                    }
                }
                if (-not $result.Trim()) { $result = "(no output)" }
                if ($result.Length -gt $maxOutputChars) {
                    $result = $result.Substring(0, $maxOutputChars) + "`n... [TRUNCATED at $maxOutputChars chars]"
                }
                # Clean result display
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($result.Length) chars" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                if ($result -match 'ERROR:' -or $result -match 'STDERR:') {
                    Write-Host "ERROR" -ForegroundColor Red
                } else {
                    Write-Host "OK" -ForegroundColor Green
                }
                $previewLines = ($result -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 2)
                foreach ($pl in $previewLines) {
                    $plTrim = $pl.Trim()
                    if ($plTrim.Length -gt 120) { $plTrim = $plTrim.Substring(0, 120) + '...' }
                    Write-Host "      $plTrim" -ForegroundColor DarkGray
                }
                return "[EXEC-PS] $result"
            } catch {
                return "[EXEC-PS] ERROR: $($_.Exception.Message)"
            }
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
                    -RedirectStandardOutput $tempOut `
                    -RedirectStandardError $tempErr `
                    -NoNewWindow -PassThru
                $exited = $proc.WaitForExit($toolTimeoutMs)
                if (-not $exited) {
                    try { $proc.Kill() } catch {}
                    return "[EXEC-CMD] ERROR: Command timed out after $([int]($toolTimeoutMs/1000))s"
                }
                $stdout = ""
                $stderr = ""
                if (Test-Path $tempOut) { $stdout = [System.IO.File]::ReadAllText($tempOut) }
                if (Test-Path $tempErr) { $stderr = [System.IO.File]::ReadAllText($tempErr) }
                Remove-Item $tempOut, $tempErr -ErrorAction SilentlyContinue
                $result = $stdout
                if ($stderr.Trim()) { $result += "`nSTDERR: $stderr" }
                if (-not $result.Trim()) { $result = "(no output)" }
                if ($result.Length -gt $maxOutputChars) {
                    $result = $result.Substring(0, $maxOutputChars) + "`n... [TRUNCATED at $maxOutputChars chars]"
                }
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
            } catch {
                return "[EXEC-CMD] ERROR: $($_.Exception.Message)"
            }
        }

        "write_file" {
            $path = $Arguments["path"]
            $content = $Arguments["content"]
            if (-not $path) { return "[WRITE] ERROR: No path provided" }
            if ($null -eq $content) { $content = "" }
            # Sanitize: strip leading .\ from absolute paths (model bug guardrail)
            if ($path -match '^\.[/\\][A-Za-z]:\\') {
                $path = $path.Substring(2)
                Write-Host "  [WARN] Stripped leading '.\\' from absolute path -> $path" -ForegroundColor Yellow
            }

            # PLAN/REPORT INTERCEPTOR: Block write_file when user didn't ask for a file
            $userAskedForFile = $false
            foreach ($m in $script:messages) {
                if ($m.role -eq 'user' -and $m.content) {
                    if ($m.content -match '(?i)(save|write to|create file|output to|log to|\.txt|\.ps1|\.json|\.csv|store to)') {
                        $userAskedForFile = $true; break
                    }
                }
            }
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
                if ($dir -and -not (Test-Path $dir)) {
                    [System.IO.Directory]::CreateDirectory($dir) | Out-Null
                }
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
            } catch {
                return "[WRITE] ERROR: $($_.Exception.Message)"
            }
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
                if (-not (Test-Path $path)) {
                    return "[READ] ERROR: File not found: $path"
                }
                $content = [System.IO.File]::ReadAllText($path)
                if ($content.Length -gt $maxOutputChars) {
                    $content = $content.Substring(0, $maxOutputChars) + "`n... [TRUNCATED at $maxOutputChars chars]"
                }
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($content.Length) chars" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                Write-Host "OK" -ForegroundColor Green
                return "[READ] $content"
            } catch {
                return "[READ] ERROR: $($_.Exception.Message)"
            }
        }

        "edit_file" {
            $path = $Arguments["path"]
            $oldText = $Arguments["old_text"]
            $newText = $Arguments["new_text"]
            if (-not $path -or -not $oldText) { return "[EDIT] ERROR: path and old_text required" }
            if ($path -match '^\.[/\\][A-Za-z]:\\') { $path = $path.Substring(2) }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "edit_file" -ForegroundColor Yellow -NoNewline
            Write-Host "(" -ForegroundColor DarkGray -NoNewline
            Write-Host "$path" -ForegroundColor White -NoNewline
            Write-Host ")" -ForegroundColor DarkGray
            try {
                if (-not (Test-Path $path)) { return "[EDIT] ERROR: File not found: $path" }
                $content = [System.IO.File]::ReadAllText($path)
                $count = ([regex]::Matches($content, [regex]::Escape($oldText))).Count
                if ($count -eq 0) { return "[EDIT] ERROR: old_text not found in file" }
                if ($count -gt 1) { return "[EDIT] ERROR: old_text found $count times (must be unique)" }
                $newContent = $content.Replace($oldText, $newText)
                $utf8NoBom = New-Object System.Text.UTF8Encoding $false
                [System.IO.File]::WriteAllText($path, $newContent, $utf8NoBom)
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "replaced $($oldText.Length) -> $($newText.Length) chars" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                Write-Host "OK" -ForegroundColor Green
                return "[EDIT] Replaced $($oldText.Length) chars with $($newText.Length) chars in $path"
            } catch {
                return "[EDIT] ERROR: $($_.Exception.Message)"
            }
        }

        "list_directory" {
            $path = $Arguments["path"]
            if (-not $path) { return "[LIST] ERROR: No path provided" }
            $recursive = $Arguments["recursive"] -eq $true
            $pattern = if ($Arguments["pattern"]) { $Arguments["pattern"] } else { "*" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "list_directory" -ForegroundColor Yellow -NoNewline
            Write-Host "(" -ForegroundColor DarkGray -NoNewline
            Write-Host "$path" -ForegroundColor White -NoNewline
            Write-Host ")" -ForegroundColor DarkGray
            try {
                if (-not (Test-Path $path)) { return "[LIST] ERROR: Directory not found: $path" }
                $items = if ($recursive) {
                    Get-ChildItem -Path $path -Filter $pattern -Recurse -ErrorAction SilentlyContinue | Select-Object -First 500
                } else {
                    Get-ChildItem -Path $path -Filter $pattern -ErrorAction SilentlyContinue | Select-Object -First 500
                }
                $lines = @("Directory: $path", "$($items.Count) items", "")
                foreach ($item in $items) {
                    $kind = if ($item.PSIsContainer) { "D" } else { "F" }
                    $sz = if ($item.PSIsContainer) { 0 } else { $item.Length }
                    $szStr = if ($sz -gt 1GB) { "{0:F1} GB" -f ($sz / 1GB) } elseif ($sz -gt 1MB) { "{0:F1} MB" -f ($sz / 1MB) } elseif ($sz -gt 1KB) { "{0:F1} KB" -f ($sz / 1KB) } else { "$sz B" }
                    $mtime = $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                    $lines += "[$kind] {0,10}  {1}  {2}" -f $szStr, $mtime, $item.Name
                }
                $result = $lines -join "`n"
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($items.Count) items" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                Write-Host "OK" -ForegroundColor Green
                return "[LIST] $result"
            } catch {
                return "[LIST] ERROR: $($_.Exception.Message)"
            }
        }

        "search_files" {
            $path = $Arguments["path"]
            $pattern = $Arguments["pattern"]
            if (-not $path -or -not $pattern) { return "[SEARCH] ERROR: path and pattern required" }
            $fileGlob = if ($Arguments["file_glob"]) { $Arguments["file_glob"] } else { "*.*" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "search_files" -ForegroundColor Yellow -NoNewline
            Write-Host "(" -ForegroundColor DarkGray -NoNewline
            Write-Host "/$pattern/" -ForegroundColor White -NoNewline
            Write-Host ")" -ForegroundColor DarkGray
            try {
                if (-not (Test-Path $path)) { return "[SEARCH] ERROR: Directory not found: $path" }
                $regex = [regex]::new($pattern, 'IgnoreCase')
                $matches = @()
                $filesSearched = 0
                $maxResults = 50
                $files = Get-ChildItem -Path $path -Filter $fileGlob -Recurse -File -ErrorAction SilentlyContinue
                foreach ($f in $files) {
                    if ($f.Length -gt 1MB) { continue }
                    $filesSearched++
                    try {
                        $lineNum = 0
                        foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
                            $lineNum++
                            if ($regex.IsMatch($line)) {
                                $preview = if ($line.Length -gt 200) { $line.Substring(0, 200) } else { $line }
                                $matches += "{0}:{1}: {2}" -f $f.FullName, $lineNum, $preview.Trim()
                                if ($matches.Count -ge $maxResults) { break }
                            }
                        }
                    } catch {}
                    if ($matches.Count -ge $maxResults) { break }
                }
                $result = "Searched $filesSearched files in $path`n$($matches.Count) matches for /$pattern/`n`n" + ($matches -join "`n")
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($matches.Count) matches in $filesSearched files" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                Write-Host "OK" -ForegroundColor Green
                return "[SEARCH] $result"
            } catch {
                return "[SEARCH] ERROR: $($_.Exception.Message)"
            }
        }

        "get_system_info" {
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "get_system_info" -ForegroundColor Yellow
            try {
                $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
                $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
                $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
                $gpu = ""
                try { $gpu = (nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total --format=csv,noheader 2>$null) } catch {}
                $ramGB = if ($os) { [math]::Round($os.TotalVisibleMemorySize / 1MB, 1) } else { 0 }
                $freeGB = if ($os) { [math]::Round($os.FreePhysicalMemory / 1MB, 1) } else { 0 }
                $lines = @(
                    "CPU: $(if($cpu){$cpu.Name}else{'unknown'})"
                    "Cores: $(if($cpu){$cpu.NumberOfCores}else{'?'}) ($(if($cpu){$cpu.NumberOfLogicalProcessors}else{'?'}) logical)"
                    "RAM: $ramGB GB total, $freeGB GB free"
                    "OS: $(if($os){$os.Caption}else{'unknown'}) Build $(if($os){$os.BuildNumber}else{'?'})"
                )
                if ($gpu) { $lines += "GPU: $gpu" }
                foreach ($d in $disks) {
                    $totalGB = [math]::Round($d.Size / 1GB, 1)
                    $freeGB2 = [math]::Round($d.FreeSpace / 1GB, 1)
                    $lines += "Disk $($d.DeviceID) $totalGB GB total, $freeGB2 GB free"
                }
                $result = $lines -join "`n"
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($lines.Count) items" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                Write-Host "OK" -ForegroundColor Green
                return "[SYSINFO] $result"
            } catch {
                return "[SYSINFO] ERROR: $($_.Exception.Message)"
            }
        }

        "web_fetch" {
            $url = $Arguments["url"]
            if (-not $url) { return "[FETCH] ERROR: No URL provided" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "web_fetch" -ForegroundColor Yellow -NoNewline
            Write-Host "(" -ForegroundColor DarkGray -NoNewline
            Write-Host (Format-ToolCommand -Text $url -MaxLen 80) -ForegroundColor White -NoNewline
            Write-Host ")" -ForegroundColor DarkGray
            try {
                $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                $text = $resp.Content
                # Strip HTML tags
                $text = [regex]::Replace($text, '<script[^>]*>[\s\S]*?</script>', '', 'IgnoreCase')
                $text = [regex]::Replace($text, '<style[^>]*>[\s\S]*?</style>', '', 'IgnoreCase')
                $text = [regex]::Replace($text, '<[^>]+>', ' ')
                $text = [regex]::Replace($text, '\s+', ' ').Trim()
                if ($text.Length -gt 10000) {
                    $text = $text.Substring(0, 10000) + '... [TRUNCATED]'
                }
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($text.Length) chars" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                Write-Host "OK" -ForegroundColor Green
                return "[FETCH] $text"
            } catch {
                return "[FETCH] ERROR: $($_.Exception.Message)"
            }
        }

        "open_browser" {
            $url = $Arguments["url"]
            if (-not $url) { return "[BROWSER] ERROR: No URL provided" }
            $newTab = $true
            if ($Arguments.ContainsKey("new_tab")) { $newTab = $Arguments["new_tab"] }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "open_browser" -ForegroundColor Yellow -NoNewline
            Write-Host "(" -ForegroundColor DarkGray -NoNewline
            Write-Host (Format-ToolCommand -Text $url -MaxLen 60) -ForegroundColor White -NoNewline
            Write-Host ")" -ForegroundColor DarkGray
            try {
                $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
                if (-not (Test-Path $chromePath)) {
                    return "[BROWSER] ERROR: Chrome not found at $chromePath"
                }
                if (-not $url.StartsWith("http://") -and -not $url.StartsWith("https://")) {
                    $url = "https://" + $url
                }
                $args = @("--start-maximized")
                if ($newTab) { $args += "--new-tab" }
                $args += $url
                $proc = Start-Process -FilePath $chromePath -ArgumentList $args -PassThru
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "PID: $($proc.Id)" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                Write-Host "OK" -ForegroundColor Green
                return "[BROWSER] Opened Chrome: $url (PID: $($proc.Id))"
            } catch {
                return "[BROWSER] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- web_search (DuckDuckGo HTML) ----
        "web_search" {
            $query = $Arguments["query"]
            if (-not $query) { return "[SEARCH-WEB] ERROR: No query provided" }
            $maxResults = if ($Arguments["max_results"]) { [int]$Arguments["max_results"] } else { 5 }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "web_search" -ForegroundColor Yellow -NoNewline
            Write-Host "($query)" -ForegroundColor White
            try {
                $encoded = [Uri]::EscapeDataString($query)
                $url = "https://html.duckduckgo.com/html/?q=$encoded"
                $resp2 = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -UserAgent "Mozilla/5.0" -ErrorAction Stop
                $html = $resp2.Content
                $results = @()
                $pattern = '(?s)<a class="result__a"[^>]*href="([^"]+)"[^>]*>(.+?)</a>.*?<a class="result__snippet"[^>]*>(.+?)</a>'
                $allMatches = [regex]::Matches($html, $pattern)
                foreach ($m in $allMatches) {
                    if ($results.Count -ge $maxResults) { break }
                    $link = [regex]::Replace($m.Groups[1].Value, '<[^>]+>', ' ').Trim()
                    $title = [regex]::Replace($m.Groups[2].Value, '<[^>]+>', ' ').Trim()
                    $snippet = [regex]::Replace($m.Groups[3].Value, '<[^>]+>', ' ').Trim()
                    $results += "$($results.Count + 1). $title`n   URL: $link`n   $snippet"
                }
                if ($results.Count -eq 0) {
                    # Fallback: extract any links
                    $linkMatches = [regex]::Matches($html, 'href="(https?://[^"]+)"')
                    $seen = @{}
                    foreach ($lm in $linkMatches) {
                        $u = $lm.Groups[1].Value
                        if (-not $seen[$u] -and $u -notmatch 'duckduck') {
                            $seen[$u] = $true
                            $results += "$($results.Count + 1). $u"
                            if ($results.Count -ge $maxResults) { break }
                        }
                    }
                }
                $result = "Web search results for: $query`n" + ($results -join "`n`n")
                if ($result.Length -gt 8000) { $result = $result.Substring(0, 8000) + '...[TRUNCATED]' }
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($results.Count) results" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                Write-Host "OK" -ForegroundColor Green
                return "[SEARCH-WEB] $result"
            } catch {
                return "[SEARCH-WEB] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- download_file ----
        "download_file" {
            $url = $Arguments["url"]
            $dest = $Arguments["destination"]
            if (-not $url -or -not $dest) { return "[DOWNLOAD] ERROR: url and destination required" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "download_file" -ForegroundColor Yellow -NoNewline
            Write-Host "($url -> $dest)" -ForegroundColor White
            try {
                $dir2 = [System.IO.Path]::GetDirectoryName($dest)
                if ($dir2 -and -not (Test-Path $dir2)) { [System.IO.Directory]::CreateDirectory($dir2) | Out-Null }
                $wc = New-Object System.Net.WebClient
                $wc.DownloadFile($url, $dest)
                $size2 = (Get-Item $dest).Length
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$size2 bytes" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                Write-Host "OK" -ForegroundColor Green
                return "[DOWNLOAD] Downloaded $size2 bytes to $dest"
            } catch {
                return "[DOWNLOAD] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- run_python ----
        "run_python" {
            $code = $Arguments["code"]
            if (-not $code) { return "[PYTHON] ERROR: No code provided" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "run_python" -ForegroundColor Yellow -NoNewline
            Write-Host "($($code.Substring(0, [Math]::Min(60, $code.Length)))...)" -ForegroundColor White
            try {
                $pyScript = [System.IO.Path]::GetTempPath() + "oll90_py_" + [guid]::NewGuid().ToString("N") + ".py"
                $pyOut = [System.IO.Path]::GetTempFileName()
                $pyErr = [System.IO.Path]::GetTempFileName()
                [System.IO.File]::WriteAllText($pyScript, $code, [System.Text.Encoding]::UTF8)
                $pyExe = "python"
                if (Test-Path "C:\Python311\python.exe") { $pyExe = "C:\Python311\python.exe" }
                elseif (Test-Path "C:\Python310\python.exe") { $pyExe = "C:\Python310\python.exe" }
                $pyProc = Start-Process -FilePath $pyExe -ArgumentList $pyScript `
                    -RedirectStandardOutput $pyOut -RedirectStandardError $pyErr `
                    -NoNewWindow -PassThru
                $pyExited = $pyProc.WaitForExit(120000)
                if (-not $pyExited) { try { $pyProc.Kill() } catch {}; return "[PYTHON] ERROR: Timed out after 120s" }
                $pyStdout = if (Test-Path $pyOut) { [System.IO.File]::ReadAllText($pyOut) } else { "" }
                $pyStderr = if (Test-Path $pyErr) { [System.IO.File]::ReadAllText($pyErr) } else { "" }
                Remove-Item $pyScript, $pyOut, $pyErr -ErrorAction SilentlyContinue
                $pyResult = $pyStdout
                if ($pyStderr.Trim()) { $pyResult += "`nSTDERR: $pyStderr" }
                if (-not $pyResult.Trim()) { $pyResult = "(no output)" }
                if ($pyResult.Length -gt $maxOutputChars) { $pyResult = $pyResult.Substring(0, $maxOutputChars) + "`n...[TRUNCATED]" }
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($pyResult.Length) chars" -ForegroundColor DarkGray -NoNewline
                Write-Host " | " -ForegroundColor DarkGray -NoNewline
                if ($pyResult -match 'STDERR:') { Write-Host "ERROR" -ForegroundColor Red } else { Write-Host "OK" -ForegroundColor Green }
                return "[PYTHON] $pyResult"
            } catch {
                return "[PYTHON] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- clipboard_read ----
        "clipboard_read" {
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "clipboard_read" -ForegroundColor Yellow
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
                $text2 = [System.Windows.Forms.Clipboard]::GetText()
                if (-not $text2) { $text2 = "(clipboard is empty)" }
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($text2.Length) chars | OK" -ForegroundColor Green
                return "[CLIPBOARD] $text2"
            } catch {
                return "[CLIPBOARD] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- clipboard_write ----
        "clipboard_write" {
            $text3 = $Arguments["text"]
            if ($null -eq $text3) { return "[CLIPBOARD] ERROR: text required" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "clipboard_write" -ForegroundColor Yellow -NoNewline
            Write-Host "($($text3.Substring(0, [Math]::Min(40, $text3.Length)))...)" -ForegroundColor White
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
                [System.Windows.Forms.Clipboard]::SetText($text3)
                Write-Host "    " -NoNewline
                Write-Host "< " -ForegroundColor DarkGray -NoNewline
                Write-Host "$($text3.Length) chars | OK" -ForegroundColor Green
                return "[CLIPBOARD] Wrote $($text3.Length) chars to clipboard"
            } catch {
                return "[CLIPBOARD] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- network_info ----
        "network_info" {
            $action3 = if ($Arguments["action"]) { $Arguments["action"] } else { "interfaces" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "network_info" -ForegroundColor Yellow -NoNewline
            Write-Host "($action3)" -ForegroundColor White
            try {
                $netResult = ""
                switch ($action3) {
                    "interfaces" {
                        $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object Name, Status, MacAddress, LinkSpeed
                        $ips = Get-NetIPAddress -ErrorAction SilentlyContinue | Where-Object { $_.AddressFamily -eq 'IPv4' } | Select-Object InterfaceAlias, IPAddress, PrefixLength
                        $netResult = "--- Network Adapters ---`n" + ($adapters | Format-Table -AutoSize | Out-String).Trim()
                        $netResult += "`n--- IP Addresses ---`n" + ($ips | Format-Table -AutoSize | Out-String).Trim()
                    }
                    "connections" {
                        $conns = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State | Select-Object -First 30
                        $netResult = "--- Active TCP Connections ---`n" + ($conns | Format-Table -AutoSize | Out-String).Trim()
                    }
                    "dns" {
                        $hostname = $Arguments["hostname"]
                        if (-not $hostname) { $hostname = "google.com" }
                        $resolved = [System.Net.Dns]::GetHostAddresses($hostname) | ForEach-Object { $_.IPAddressToString }
                        $netResult = "DNS lookup for " + $hostname + ": " + ($resolved -join ", ")
                    }
                    default { $netResult = "Unknown action '$action3'. Use: interfaces, connections, dns" }
                }
                if ($netResult.Length -gt $maxOutputChars) { $netResult = $netResult.Substring(0, $maxOutputChars) + '...[TRUNCATED]' }
                Write-Host "    " -NoNewline
                Write-Host "< OK" -ForegroundColor Green
                return "[NETINFO] $netResult"
            } catch {
                return "[NETINFO] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- hash_file ----
        "hash_file" {
            $hPath = $Arguments["path"]
            $algo = if ($Arguments["algorithm"]) { $Arguments["algorithm"].ToUpper() } else { "SHA256" }
            if (-not $hPath) { return "[HASH] ERROR: path required" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "hash_file" -ForegroundColor Yellow -NoNewline
            Write-Host "($hPath [$algo])" -ForegroundColor White
            try {
                if (-not (Test-Path $hPath)) { return "[HASH] ERROR: File not found: $hPath" }
                $hash = Get-FileHash -Path $hPath -Algorithm $algo
                Write-Host "    " -NoNewline
                Write-Host "< OK" -ForegroundColor Green
                return "[HASH] $algo($hPath) = $($hash.Hash)"
            } catch {
                return "[HASH] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- http_request ----
        "http_request" {
            $hrUrl = $Arguments["url"]
            $hrMethod = if ($Arguments["method"]) { $Arguments["method"].ToUpper() } else { "GET" }
            $hrBody = $Arguments["body"]
            $hrHeaders = $Arguments["headers"]
            if (-not $hrUrl) { return "[HTTP] ERROR: url required" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "http_request" -ForegroundColor Yellow -NoNewline
            Write-Host "($hrMethod $hrUrl)" -ForegroundColor White
            try {
                $iwrParams = @{ Uri = $hrUrl; Method = $hrMethod; UseBasicParsing = $true; TimeoutSec = 30; ErrorAction = 'Stop' }
                if ($hrBody) { $iwrParams['Body'] = $hrBody; $iwrParams['ContentType'] = 'application/json' }
                if ($hrHeaders -and $hrHeaders -is [System.Management.Automation.PSCustomObject]) {
                    $hdrHt = @{}
                    $hrHeaders.PSObject.Properties | ForEach-Object { $hdrHt[$_.Name] = $_.Value }
                    $iwrParams['Headers'] = $hdrHt
                }
                $hrResp = Invoke-WebRequest @iwrParams
                $hrRespText = $hrResp.Content
                if ($hrRespText.Length -gt 10000) { $hrRespText = $hrRespText.Substring(0, 10000) + '...[TRUNCATED]' }
                Write-Host "    " -NoNewline
                Write-Host "< HTTP $($hrResp.StatusCode) | OK" -ForegroundColor Green
                return "[HTTP] Status: $($hrResp.StatusCode)`n$hrRespText"
            } catch {
                return "[HTTP] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- event_log ----
        "event_log" {
            $evLog = if ($Arguments["log_name"]) { $Arguments["log_name"] } else { "System" }
            $evLevel = if ($Arguments["level"]) { $Arguments["level"] } else { "Error" }
            $evCount = if ($Arguments["count"]) { [int]$Arguments["count"] } else { 20 }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "event_log" -ForegroundColor Yellow -NoNewline
            Write-Host "($evLog, $evLevel, last $evCount)" -ForegroundColor White
            try {
                $levelMap = @{ "Error" = 2; "Warning" = 3; "Information" = 4; "Info" = 4 }
                $levelId = if ($levelMap[$evLevel]) { $levelMap[$evLevel] } else { 2 }
                $evEvents = Get-WinEvent -LogName $evLog -MaxEvents 200 -ErrorAction SilentlyContinue | Where-Object { $_.Level -le $levelId } | Select-Object -First $evCount
                $evLines = $evEvents | ForEach-Object { "[$($_.TimeCreated.ToString('yyyy-MM-dd HH:mm'))] [$($_.LevelDisplayName)] $($_.Message.Substring(0, [Math]::Min(200, $_.Message.Length)))" }
                $evResult = "Event Log: $evLog ($evLevel, last $evCount)`n" + ($evLines -join "`n")
                Write-Host "    " -NoNewline
                Write-Host "< $($evEvents.Count) events | OK" -ForegroundColor Green
                return "[EVENTLOG] $evResult"
            } catch {
                return "[EVENTLOG] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- git_command ----
        "git_command" {
            $gitRepo = $Arguments["repo_path"]
            $gitCmd = $Arguments["command"]
            if (-not $gitRepo -or -not $gitCmd) { return "[GIT] ERROR: repo_path and command required" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "git_command" -ForegroundColor Yellow -NoNewline
            Write-Host "($gitCmd in $gitRepo)" -ForegroundColor White
            try {
                if (-not (Test-Path $gitRepo)) { return "[GIT] ERROR: repo path not found: $gitRepo" }
                $gitOut = [System.IO.Path]::GetTempFileName()
                $gitErr2 = [System.IO.Path]::GetTempFileName()
                $gitProc = Start-Process -FilePath "git" -ArgumentList ($gitCmd -split ' ') `
                    -WorkingDirectory $gitRepo `
                    -RedirectStandardOutput $gitOut -RedirectStandardError $gitErr2 `
                    -NoNewWindow -PassThru
                $gitExited = $gitProc.WaitForExit(30000)
                if (-not $gitExited) { try { $gitProc.Kill() } catch {}; return "[GIT] ERROR: git command timed out" }
                $gitStdout = if (Test-Path $gitOut) { [System.IO.File]::ReadAllText($gitOut) } else { "" }
                $gitStderr = if (Test-Path $gitErr2) { [System.IO.File]::ReadAllText($gitErr2) } else { "" }
                Remove-Item $gitOut, $gitErr2 -ErrorAction SilentlyContinue
                $gitResult = $gitStdout
                if ($gitStderr.Trim()) { $gitResult += "`nSTDERR: $gitStderr" }
                if (-not $gitResult.Trim()) { $gitResult = "(no output, exit code: $($gitProc.ExitCode))" }
                if ($gitResult.Length -gt $maxOutputChars) { $gitResult = $gitResult.Substring(0, $maxOutputChars) + '...[TRUNCATED]' }
                Write-Host "    " -NoNewline
                Write-Host "< $($gitResult.Length) chars | OK" -ForegroundColor Green
                return "[GIT] $gitResult"
            } catch {
                return "[GIT] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- process_manager ----
        "process_manager" {
            $pmAction = if ($Arguments["action"]) { $Arguments["action"] } else { "list" }
            $pmTarget = $Arguments["name"]
            $pmPid = $Arguments["pid"]
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "process_manager" -ForegroundColor Yellow -NoNewline
            Write-Host "($pmAction)" -ForegroundColor White
            try {
                $pmResult = ""
                switch ($pmAction) {
                    "list" {
                        $procs = Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 30
                        $pmResult = "Top 30 processes by RAM:`n" + ($procs | Format-Table -Property Id, ProcessName, @{N='RAM(MB)'; E={[math]::Round($_.WorkingSet64/1MB,1)}}, CPU -AutoSize | Out-String).Trim()
                    }
                    "kill" {
                        if ($pmPid) { Stop-Process -Id $pmPid -Force -ErrorAction Stop; $pmResult = "Killed PID $pmPid" }
                        elseif ($pmTarget) { Stop-Process -Name $pmTarget -Force -ErrorAction Stop; $pmResult = "Killed process(es) named '$pmTarget'" }
                        else { $pmResult = "ERROR: Provide name or pid" }
                    }
                    "start" {
                        if (-not $pmTarget) { $pmResult = "ERROR: name (exe path) required" } else {
                            $pmArgs = if ($Arguments["args"]) { $Arguments["args"] } else { "" }
                            $sp = Start-Process -FilePath $pmTarget -ArgumentList $pmArgs -PassThru
                            $pmResult = "Started '$pmTarget' with PID $($sp.Id)"
                        }
                    }
                    default { $pmResult = "Unknown action. Use: list, kill, start" }
                }
                Write-Host "    " -NoNewline
                Write-Host "< OK" -ForegroundColor Green
                return "[PROCESS] $pmResult"
            } catch {
                return "[PROCESS] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- service_control ----
        "service_control" {
            $svcAction = if ($Arguments["action"]) { $Arguments["action"] } else { "list" }
            $svcName = $Arguments["name"]
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "service_control" -ForegroundColor Yellow -NoNewline
            Write-Host "($svcAction)" -ForegroundColor White
            try {
                $svcResult = ""
                switch ($svcAction) {
                    "list" {
                        $svcs = Get-Service -ErrorAction SilentlyContinue | Select-Object -First 50
                        $svcResult = "Services (first 50):`n" + ($svcs | Format-Table -Property Name, Status, StartType -AutoSize | Out-String).Trim()
                    }
                    "status" {
                        if (-not $svcName) { $svcResult = "ERROR: name required" } else {
                            $svc = Get-Service -Name $svcName -ErrorAction Stop
                            $svcResult = "$($svc.Name): $($svc.Status) (StartType: $($svc.StartType))"
                        }
                    }
                    "start" {
                        if (-not $svcName) { $svcResult = "ERROR: name required" } else {
                            Start-Service -Name $svcName -ErrorAction Stop
                            $svcResult = "Started service: $svcName"
                        }
                    }
                    "stop" {
                        if (-not $svcName) { $svcResult = "ERROR: name required" } else {
                            Stop-Service -Name $svcName -Force -ErrorAction Stop
                            $svcResult = "Stopped service: $svcName"
                        }
                    }
                    "restart" {
                        if (-not $svcName) { $svcResult = "ERROR: name required" } else {
                            Restart-Service -Name $svcName -Force -ErrorAction Stop
                            $svcResult = "Restarted service: $svcName"
                        }
                    }
                    default { $svcResult = "Unknown action. Use: list, status, start, stop, restart" }
                }
                Write-Host "    " -NoNewline
                Write-Host "< OK" -ForegroundColor Green
                return "[SERVICE] $svcResult"
            } catch {
                return "[SERVICE] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- compress_files ----
        "compress_files" {
            $czSrc = $Arguments["source"]
            $czDest = $Arguments["destination"]
            if (-not $czSrc -or -not $czDest) { return "[COMPRESS] ERROR: source and destination required" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "compress_files" -ForegroundColor Yellow -NoNewline
            Write-Host "($czSrc -> $czDest)" -ForegroundColor White
            try {
                Compress-Archive -Path $czSrc -DestinationPath $czDest -Force -ErrorAction Stop
                $czSize = (Get-Item $czDest).Length
                Write-Host "    " -NoNewline
                Write-Host "< $czSize bytes | OK" -ForegroundColor Green
                return "[COMPRESS] Created $czDest ($czSize bytes)"
            } catch {
                return "[COMPRESS] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- extract_archive ----
        "extract_archive" {
            $exSrc = $Arguments["source"]
            $exDest = if ($Arguments["destination"]) { $Arguments["destination"] } else { [System.IO.Path]::GetDirectoryName($exSrc) }
            if (-not $exSrc) { return "[EXTRACT] ERROR: source required" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "extract_archive" -ForegroundColor Yellow -NoNewline
            Write-Host "($exSrc -> $exDest)" -ForegroundColor White
            try {
                Expand-Archive -Path $exSrc -DestinationPath $exDest -Force -ErrorAction Stop
                Write-Host "    " -NoNewline
                Write-Host "< OK" -ForegroundColor Green
                return "[EXTRACT] Extracted $exSrc to $exDest"
            } catch {
                return "[EXTRACT] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- json_transform ----
        "json_transform" {
            $jtJson = $Arguments["json"]
            $jtExpr = $Arguments["expression"]
            if (-not $jtJson -or -not $jtExpr) { return "[JSON] ERROR: json and expression required" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "json_transform" -ForegroundColor Yellow -NoNewline
            Write-Host "($jtExpr)" -ForegroundColor White
            try {
                $jtObj = $jtJson | ConvertFrom-Json
                $jtResult = $jtObj | Invoke-Expression -Command { param($obj, $expr) $obj | ForEach-Object { & ([scriptblock]::Create($jtExpr)) $_ } }
                # Safer: use scriptblock
                $jtSb = [scriptblock]::Create("`$_ = `$args[0]; $jtExpr")
                $jtResult = & $jtSb $jtObj
                $jtOut = if ($jtResult -is [string]) { $jtResult } else { $jtResult | ConvertTo-Json -Depth 10 }
                if ($jtOut.Length -gt $maxOutputChars) { $jtOut = $jtOut.Substring(0, $maxOutputChars) + '...' }
                Write-Host "    " -NoNewline
                Write-Host "< $($jtOut.Length) chars | OK" -ForegroundColor Green
                return "[JSON] $jtOut"
            } catch {
                return "[JSON] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- speak ----
        "speak" {
            $spText = $Arguments["text"]
            if (-not $spText) { return "[SPEAK] ERROR: text required" }
            $spRate = if ($Arguments["rate"]) { [int]$Arguments["rate"] } else { 0 }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "speak" -ForegroundColor Yellow -NoNewline
            Write-Host "($($spText.Substring(0, [Math]::Min(40, $spText.Length)))...)" -ForegroundColor White
            try {
                Add-Type -AssemblyName System.Speech -ErrorAction Stop
                $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
                $synth.Rate = [Math]::Max(-10, [Math]::Min(10, $spRate))
                $synth.SpeakAsync($spText) | Out-Null
                Write-Host "    " -NoNewline
                Write-Host "< speaking | OK" -ForegroundColor Green
                return "[SPEAK] Speaking: $($spText.Substring(0, [Math]::Min(80, $spText.Length)))"
            } catch {
                return "[SPEAK] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- notify ----
        "notify" {
            $ntTitle = if ($Arguments["title"]) { $Arguments["title"] } else { "oll90" }
            $ntMsg = if ($Arguments["message"]) { $Arguments["message"] } else { "Task complete" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "notify" -ForegroundColor Yellow -NoNewline
            Write-Host ("($ntTitle" + ": $ntMsg)") -ForegroundColor White
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
                $balloon = New-Object System.Windows.Forms.NotifyIcon
                $balloon.Icon = [System.Drawing.SystemIcons]::Information
                $balloon.BalloonTipTitle = $ntTitle
                $balloon.BalloonTipText = $ntMsg
                $balloon.Visible = $true
                $balloon.ShowBalloonTip(5000)
                Start-Sleep -Milliseconds 200
                $balloon.Dispose()
                Write-Host "    " -NoNewline
                Write-Host "< OK" -ForegroundColor Green
                return "[NOTIFY] Notification sent: $ntTitle - $ntMsg"
            } catch {
                # Fallback: beep
                [Console]::Beep(800, 300)
                return "[NOTIFY] Beep sent (balloon failed: $($_.Exception.Message))"
            }
        }

        # ---- screenshot ----
        "screenshot" {
            $ssPath = if ($Arguments["path"]) { $Arguments["path"] } else { "C:\Temp\oll90_screenshot_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".png" }
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "screenshot" -ForegroundColor Yellow -NoNewline
            Write-Host "($ssPath)" -ForegroundColor White
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                Add-Type -AssemblyName System.Drawing -ErrorAction Stop
                $ssDir = [System.IO.Path]::GetDirectoryName($ssPath)
                if ($ssDir -and -not (Test-Path $ssDir)) { [System.IO.Directory]::CreateDirectory($ssDir) | Out-Null }
                $screen = [System.Windows.Forms.Screen]::PrimaryScreen
                $bmp = New-Object System.Drawing.Bitmap($screen.Bounds.Width, $screen.Bounds.Height)
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $g.CopyFromScreen($screen.Bounds.Location, [System.Drawing.Point]::Empty, $screen.Bounds.Size)
                $g.Dispose()
                $bmp.Save($ssPath, [System.Drawing.Imaging.ImageFormat]::Png)
                $bmp.Dispose()
                $ssSize = (Get-Item $ssPath).Length
                Write-Host "    " -NoNewline
                Write-Host "< $ssSize bytes | OK" -ForegroundColor Green
                return "[SCREENSHOT] Saved $($screen.Bounds.Width)x$($screen.Bounds.Height) screenshot ($ssSize bytes) to $ssPath"
            } catch {
                return "[SCREENSHOT] ERROR: $($_.Exception.Message)"
            }
        }

        # ---- scheduled_task ----
        "scheduled_task" {
            $stAction = if ($Arguments["action"]) { $Arguments["action"] } else { "list" }
            $stName = $Arguments["name"]
            Write-Host "    " -NoNewline
            Write-Host "> " -ForegroundColor DarkGray -NoNewline
            Write-Host "scheduled_task" -ForegroundColor Yellow -NoNewline
            Write-Host "($stAction)" -ForegroundColor White
            try {
                $stResult = ""
                switch ($stAction) {
                    "list" {
                        $tasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Select-Object -First 30
                        $stResult = "Scheduled Tasks (first 30):`n" + ($tasks | Format-Table -Property TaskName, State, @{N='LastRunTime'; E={(Get-ScheduledTaskInfo $_.TaskName -ErrorAction SilentlyContinue).LastRunTime}} -AutoSize | Out-String).Trim()
                    }
                    "run" {
                        if (-not $stName) { $stResult = "ERROR: name required" } else {
                            Start-ScheduledTask -TaskName $stName -ErrorAction Stop
                            $stResult = "Started task: $stName"
                        }
                    }
                    "delete" {
                        if (-not $stName) { $stResult = "ERROR: name required" } else {
                            Unregister-ScheduledTask -TaskName $stName -Confirm:$false -ErrorAction Stop
                            $stResult = "Deleted task: $stName"
                        }
                    }
                    default { $stResult = "Unknown action. Use: list, run, delete" }
                }
                Write-Host "    " -NoNewline
                Write-Host "< OK" -ForegroundColor Green
                return "[TASK] $stResult"
            } catch {
                return "[TASK] ERROR: $($_.Exception.Message)"
            }
        }

        default {
            return "ERROR: Unknown tool '$Name'"
        }
    }
}

# ============================================================================
# API CALLER: POST to Ollama /api/chat with streaming
# ============================================================================
function Invoke-OllamaChat {
    param(
        [System.Collections.ArrayList]$Messages,
        [array]$Tools,
        [string]$ChatModel,
        [string]$Url,
        [int]$Timeout
    )

    $body = @{
        model    = $ChatModel
        messages = @($Messages)
        tools    = $Tools
        stream   = $true
    }
    # Apply generation options if set
    $genOptions = @{}
    if ($script:genTemperature -ne $null) { $genOptions['temperature'] = $script:genTemperature }
    if ($script:genContextLength -ne $null) { $genOptions['num_ctx'] = $script:genContextLength }
    if ($genOptions.Count -gt 0) { $body['options'] = $genOptions }

    $json = $body | ConvertTo-Json -Depth 20 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    $req = [System.Net.HttpWebRequest]::Create("$Url/api/chat")
    $req.Method = "POST"
    $req.ContentType = "application/json; charset=utf-8"
    $req.Timeout = $Timeout * 1000
    $req.ReadWriteTimeout = $Timeout * 1000
    $reqStream = $req.GetRequestStream()
    $reqStream.Write($bytes, 0, $bytes.Length)
    $reqStream.Close()

    try {
        $resp = $req.GetResponse()
    } catch [System.Net.WebException] {
        $webEx = $_.Exception
        $statusCode = 0
        $errorBody = ""
        if ($webEx.Response) {
            $statusCode = [int]($webEx.Response.StatusCode)
            try {
                $errStream = $webEx.Response.GetResponseStream()
                $errReader = New-Object System.IO.StreamReader($errStream)
                $errorBody = $errReader.ReadToEnd()
                $errReader.Close()
            } catch {}
        }
        if ($statusCode -eq 404) {
            $modelHint = ""
            if ($errorBody -match 'model.*not found|not found.*model') {
                $modelHint = " Model '$ChatModel' not found. Run: ollama list  (to see models) or: ollama create $ChatModel -f C:\Temp\Modelfile.oll90"
            }
            throw "HTTP 404 Not Found.$modelHint Raw: $errorBody"
        } elseif ($statusCode -eq 400) {
            throw "HTTP 400 Bad Request (context too long or invalid JSON). Body: $errorBody"
        } elseif ($statusCode -ne 0) {
            throw "HTTP $statusCode error. Body: $errorBody"
        } else {
            throw $webEx.Message
        }
    }
    $respStream = $resp.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($respStream, [System.Text.Encoding]::UTF8)

    # Streaming state
    $fullContent = ""
    $toolCalls = $null
    $evalCount = 0
    $evalDuration = 0
    $promptEvalCount = 0
    $inThinking = $false
    $tokenCount = 0
    $thinkTokens = 0
    $streamStart = [System.Diagnostics.Stopwatch]::StartNew()
    $lastChunkTime = [System.Diagnostics.Stopwatch]::StartNew()
    $streamTimeoutSec = $Timeout
    $gotDone = $false

    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if (-not $line -or -not $line.Trim()) {
                # Check for stream timeout (Ollama may have crashed)
                if ($lastChunkTime.Elapsed.TotalSeconds -gt $streamTimeoutSec) {
                    Write-Host "" ; Write-Host "  [WARN] Stream timeout after $streamTimeoutSec`s with no data. Ollama may have crashed." -ForegroundColor Yellow
                    break
                }
                continue
            }
            $lastChunkTime.Restart()

            try {
                # Normalize to ASCII-safe: replace non-printable non-ASCII chars that break JSON parse
                $safeLine = [System.Text.RegularExpressions.Regex]::Replace($line, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
                $chunk = $safeLine | ConvertFrom-Json
            } catch {
                continue
            }

            $msg = $chunk.message
            $content = ""
            if ($msg -and $msg.content) { $content = $msg.content }

            if ($content) {
                $fullContent += $content
                $tokenCount++

                # Think-tag tracking for real-time display
                $remaining = $content
                while ($remaining) {
                    if (-not $inThinking) {
                        $thinkIdx = $remaining.IndexOf('<think>')
                        if ($thinkIdx -ge 0) {
                            $before = $remaining.Substring(0, $thinkIdx)
                            if ($before) { Write-Host $before -NoNewline -ForegroundColor White }
                            $inThinking = $true
                            $remaining = $remaining.Substring($thinkIdx + 7)
                        } else {
                            # Check partial tag
                            if ('<think>'.StartsWith($remaining) -and $remaining.Length -lt 7) {
                                break  # partial, buffer it
                            }
                            Write-Host $remaining -NoNewline -ForegroundColor White
                            $remaining = ""
                        }
                    } else {
                        $endIdx = $remaining.IndexOf('</think>')
                        if ($endIdx -ge 0) {
                            $thinkContent = $remaining.Substring(0, $endIdx)
                            if ($thinkContent) { $thinkTokens++ }
                            $inThinking = $false
                            $remaining = $remaining.Substring($endIdx + 8)
                        } else {
                            $thinkTokens++
                            $remaining = ""
                        }
                    }
                }
            }

            # Tool calls arrive in final chunk
            if ($msg -and $msg.tool_calls -and $msg.tool_calls.Count -gt 0) {
                $toolCalls = $msg.tool_calls
            }

            # Done chunk
            if ($chunk.done -eq $true) {
                $gotDone = $true
                if ($chunk.eval_count) { $evalCount = [int]$chunk.eval_count }
                if ($chunk.eval_duration) { $evalDuration = [long]$chunk.eval_duration }
                if ($chunk.prompt_eval_count) { $promptEvalCount = [int]$chunk.prompt_eval_count }
                break
            }
        }
    } finally {
        $reader.Close()
        $respStream.Close()
        $resp.Close()
        $streamStart.Stop()
    }

    # Warn if stream ended without done=true (truncated response)
    if (-not $gotDone -and $fullContent) {
        Write-Host "  [WARN] Stream ended without done=true chunk - response may be truncated" -ForegroundColor Yellow
    }

    # Calculate tok/s
    $tokPerSec = 0.0
    if ($evalDuration -gt 0) {
        $tokPerSec = $evalCount / ($evalDuration / 1000000000.0)
    }

    # Stats line
    if ($tokenCount -gt 0) {
        Write-Host ""
        Write-Host "  --- " -ForegroundColor DarkGray -NoNewline
        Write-Host ("{0:F1} tok/s" -f $tokPerSec) -ForegroundColor Cyan -NoNewline
        Write-Host " | " -ForegroundColor DarkGray -NoNewline
        Write-Host "$evalCount tokens" -ForegroundColor White -NoNewline
        Write-Host " | " -ForegroundColor DarkGray -NoNewline
        Write-Host ("{0:F1}s" -f ($streamStart.Elapsed.TotalSeconds)) -ForegroundColor White -NoNewline
        if ($thinkTokens -gt 0) {
            Write-Host " | " -ForegroundColor DarkGray -NoNewline
            Write-Host "think: $thinkTokens" -ForegroundColor DarkGray -NoNewline
        }
        Write-Host " ---" -ForegroundColor DarkGray
    }

    # Track token usage
    $script:totalPromptTokens += $promptEvalCount
    $script:totalEvalTokens += $evalCount

    # Build response object matching original format
    $result = [PSCustomObject]@{
        message = [PSCustomObject]@{
            role       = "assistant"
            content    = $fullContent
            tool_calls = $toolCalls
        }
        eval_count       = $evalCount
        eval_duration    = $evalDuration
        prompt_eval_count = $promptEvalCount
        tokens_per_sec   = $tokPerSec
    }
    return $result
}

# ============================================================================
# TOOL SCHEMAS: 4 tools for Ollama native tool calling
# ============================================================================
$tools = @(
    @{
        type = "function"
        function = @{
            name = "run_powershell"
            description = "Execute a PowerShell command on Windows 11 Pro. Returns stdout and stderr. Use for ALL system operations: Get-Process, Get-ChildItem, Get-WmiObject, nvidia-smi, Get-NetAdapter, Get-EventLog, registry queries, etc. Chain multiple commands with semicolons (;). Use absolute Windows paths (C:\, F:\)."
            parameters = @{
                type = "object"
                properties = @{
                    command = @{
                        type = "string"
                        description = "The PowerShell command to execute"
                    }
                }
                required = @("command")
            }
        }
    }
    @{
        type = "function"
        function = @{
            name = "run_cmd"
            description = "Execute a CMD.exe command. Use for commands requiring CMD syntax: dir, type, tree, batch files, or programs that behave differently under cmd."
            parameters = @{
                type = "object"
                properties = @{
                    command = @{
                        type = "string"
                        description = "The CMD command to execute"
                    }
                }
                required = @("command")
            }
        }
    }
    @{
        type = "function"
        function = @{
            name = "write_file"
            description = "Write content to a file at the specified absolute Windows path. Creates parent directories automatically. Overwrites existing files."
            parameters = @{
                type = "object"
                properties = @{
                    path = @{
                        type = "string"
                        description = "Absolute file path (e.g. C:\Temp\output.txt)"
                    }
                    content = @{
                        type = "string"
                        description = "The content to write to the file"
                    }
                }
                required = @("path", "content")
            }
        }
    }
    @{
        type = "function"
        function = @{
            name = "read_file"
            description = "Read the entire content of a file at the specified absolute Windows path. Returns the file content as a string."
            parameters = @{
                type = "object"
                properties = @{
                    path = @{
                        type = "string"
                        description = "Absolute file path to read (e.g. C:\Temp\data.txt)"
                    }
                }
                required = @("path")
            }
        }
    }
    @{
        type = "function"
        function = @{
            name = "edit_file"
            description = "Edit a file by replacing exact text. old_text must match exactly once. Use read_file first to see the current content."
            parameters = @{
                type = "object"
                properties = @{
                    path = @{ type = "string"; description = "Absolute file path" }
                    old_text = @{ type = "string"; description = "Exact text to find (must be unique in file)" }
                    new_text = @{ type = "string"; description = "Replacement text" }
                }
                required = @("path", "old_text", "new_text")
            }
        }
    }
    @{
        type = "function"
        function = @{
            name = "list_directory"
            description = "List files and directories with sizes and dates. Returns structured listing. Set recursive=true for subdirectories."
            parameters = @{
                type = "object"
                properties = @{
                    path = @{ type = "string"; description = "Absolute directory path" }
                    recursive = @{ type = "boolean"; description = "If true, list recursively" }
                    pattern = @{ type = "string"; description = "File filter pattern (e.g. *.ps1)" }
                }
                required = @("path")
            }
        }
    }
    @{
        type = "function"
        function = @{
            name = "search_files"
            description = "Search file contents for a regex pattern. Returns matching lines with file paths and line numbers."
            parameters = @{
                type = "object"
                properties = @{
                    path = @{ type = "string"; description = "Directory to search in" }
                    pattern = @{ type = "string"; description = "Regex pattern to search for" }
                    file_glob = @{ type = "string"; description = "File filter (e.g. *.ps1, *.txt). Default: *.*" }
                }
                required = @("path", "pattern")
            }
        }
    }
    @{
        type = "function"
        function = @{
            name = "get_system_info"
            description = "Get a snapshot of system information: CPU, RAM, GPU, disk space, OS version. No parameters needed."
            parameters = @{
                type = "object"
                properties = @{}
            }
        }
    }
    @{
        type = "function"
        function = @{
            name = "web_fetch"
            description = "Fetch a web page via HTTP GET. Returns text content with HTML tags stripped. Max 10K chars."
            parameters = @{
                type = "object"
                properties = @{
                    url = @{ type = "string"; description = "URL to fetch" }
                }
                required = @("url")
            }
        }
    }
    @{
        type = "function"
        function = @{
            name = "open_browser"
            description = "Open a URL in Google Chrome. Opens new tab by default. Use to launch websites, YouTube, playlists, or any web page in the user's browser."
            parameters = @{
                type = "object"
                properties = @{
                    url = @{ type = "string"; description = "URL to open (e.g. youtube.com, https://youtube.com/playlist?list=...)" }
                    new_tab = @{ type = "boolean"; description = "If true, open new tab (default). If false, open new window." }
                }
                required = @("url")
            }
        }
    }
    @{ type = "function"; function = @{ name = "web_search"; description = "Search the web using DuckDuckGo. Returns top results with titles, URLs, and snippets. MUST use FIRST for any internet info. Use before web_fetch."; parameters = @{ type = "object"; properties = @{ query = @{ type = "string"; description = "Search query" }; max_results = @{ type = "integer"; description = "Max results to return (default: 5)" } }; required = @("query") } } }
    @{ type = "function"; function = @{ name = "download_file"; description = "Download a file from a URL to a local absolute Windows path. Creates directories as needed."; parameters = @{ type = "object"; properties = @{ url = @{ type = "string"; description = "URL to download from" }; destination = @{ type = "string"; description = "Absolute local path to save to (e.g. C:\Temp\file.zip)" } }; required = @("url", "destination") } } }
    @{ type = "function"; function = @{ name = "run_python"; description = "Execute a Python script. Writes code to temp file, runs python.exe, returns stdout/stderr. Use for data analysis, math, file processing, matplotlib (save to file not show())."; parameters = @{ type = "object"; properties = @{ code = @{ type = "string"; description = "Python code to execute" } }; required = @("code") } } }
    @{ type = "function"; function = @{ name = "clipboard_read"; description = "Read the current Windows clipboard text content."; parameters = @{ type = "object"; properties = @{} } } }
    @{ type = "function"; function = @{ name = "clipboard_write"; description = "Write text to the Windows clipboard."; parameters = @{ type = "object"; properties = @{ text = @{ type = "string"; description = "Text to write to clipboard" } }; required = @("text") } } }
    @{ type = "function"; function = @{ name = "network_info"; description = "Get network information. Actions: interfaces (adapters+IPs), connections (active TCP), dns (lookup hostname)."; parameters = @{ type = "object"; properties = @{ action = @{ type = "string"; description = "interfaces | connections | dns" }; hostname = @{ type = "string"; description = "Hostname for dns action" } }; required = @("action") } } }
    @{ type = "function"; function = @{ name = "hash_file"; description = "Compute MD5/SHA256/SHA512 hash of a file. Use to verify downloads or compare files."; parameters = @{ type = "object"; properties = @{ path = @{ type = "string"; description = "Absolute file path" }; algorithm = @{ type = "string"; description = "MD5 | SHA256 | SHA512 (default: SHA256)" } }; required = @("path") } } }
    @{ type = "function"; function = @{ name = "http_request"; description = "Make HTTP GET/POST/PUT/DELETE requests to REST APIs. Returns status code and response body."; parameters = @{ type = "object"; properties = @{ url = @{ type = "string"; description = "URL to request" }; method = @{ type = "string"; description = "GET | POST | PUT | DELETE (default: GET)" }; body = @{ type = "string"; description = "Request body (for POST/PUT)" }; headers = @{ type = "object"; description = "Request headers as key-value pairs" } }; required = @("url") } } }
    @{ type = "function"; function = @{ name = "event_log"; description = "Read Windows Event Log entries. Useful for diagnosing system errors, crashes, service failures."; parameters = @{ type = "object"; properties = @{ log_name = @{ type = "string"; description = "System | Application | Security (default: System)" }; level = @{ type = "string"; description = "Error | Warning | Information (default: Error)" }; count = @{ type = "integer"; description = "Number of entries to return (default: 20)" } } } } }
    @{ type = "function"; function = @{ name = "git_command"; description = "Run a git command in a repository directory. Supports: status, log, diff, add, commit, push, pull, branch, etc."; parameters = @{ type = "object"; properties = @{ repo_path = @{ type = "string"; description = "Absolute path to git repository" }; command = @{ type = "string"; description = "Git command without 'git' prefix (e.g. 'status', 'log --oneline -10')" } }; required = @("repo_path", "command") } } }
    @{ type = "function"; function = @{ name = "process_manager"; description = "Manage Windows processes: list top by RAM, kill by name/pid, start a new process."; parameters = @{ type = "object"; properties = @{ action = @{ type = "string"; description = "list | kill | start" }; name = @{ type = "string"; description = "Process name (for kill/start)" }; pid = @{ type = "integer"; description = "PID (for kill)" }; args = @{ type = "string"; description = "Arguments (for start)" } }; required = @("action") } } }
    @{ type = "function"; function = @{ name = "service_control"; description = "Manage Windows services: list, get status, start, stop, restart."; parameters = @{ type = "object"; properties = @{ action = @{ type = "string"; description = "list | status | start | stop | restart" }; name = @{ type = "string"; description = "Service name (required for status/start/stop/restart)" } }; required = @("action") } } }
    @{ type = "function"; function = @{ name = "compress_files"; description = "Create a ZIP archive from files/folders."; parameters = @{ type = "object"; properties = @{ source = @{ type = "string"; description = "Path to file or folder to compress (wildcards ok: C:\Temp\*.log)" }; destination = @{ type = "string"; description = "Absolute path for the output .zip file" } }; required = @("source", "destination") } } }
    @{ type = "function"; function = @{ name = "extract_archive"; description = "Extract a ZIP archive to a directory."; parameters = @{ type = "object"; properties = @{ source = @{ type = "string"; description = "Absolute path to the .zip file" }; destination = @{ type = "string"; description = "Directory to extract to (default: same folder as zip)" } }; required = @("source") } } }
    @{ type = "function"; function = @{ name = "json_transform"; description = "Transform/query JSON data using a PowerShell expression. Input JSON string + PS expression, returns result as JSON."; parameters = @{ type = "object"; properties = @{ json = @{ type = "string"; description = "JSON string to process" }; expression = @{ type = "string"; description = "PowerShell expression applied to parsed object (e.g. '$_.items | where {$_.active}')" } }; required = @("json", "expression") } } }
    @{ type = "function"; function = @{ name = "speak"; description = "Speak text aloud using Windows text-to-speech. Non-blocking. Good for alerting user when long tasks complete."; parameters = @{ type = "object"; properties = @{ text = @{ type = "string"; description = "Text to speak" }; rate = @{ type = "integer"; description = "Speech rate -10 (slow) to 10 (fast), default 0" } }; required = @("text") } } }
    @{ type = "function"; function = @{ name = "notify"; description = "Send a Windows toast notification balloon. Use to alert user when a long background task completes."; parameters = @{ type = "object"; properties = @{ title = @{ type = "string"; description = "Notification title (default: oll90)" }; message = @{ type = "string"; description = "Notification message" } }; required = @("message") } } }
    @{ type = "function"; function = @{ name = "screenshot"; description = "Capture a screenshot of the primary screen and save to PNG. Use to show current screen state or capture visual output."; parameters = @{ type = "object"; properties = @{ path = @{ type = "string"; description = "Output path for PNG file (default: C:\Temp\oll90_screenshot_TIMESTAMP.png)" } } } } }
    @{ type = "function"; function = @{ name = "scheduled_task"; description = "Manage Windows Task Scheduler tasks: list, run, or delete scheduled tasks."; parameters = @{ type = "object"; properties = @{ action = @{ type = "string"; description = "list | run | delete" }; name = @{ type = "string"; description = "Task name (required for run/delete)" } }; required = @("action") } } }
)

# ============================================================================
# DISPLAY HELPER: Handle <think> blocks from qwen3.5
# ============================================================================
function Show-AgentResponse {
    param([string]$Content)
    if (-not $Content) { return }

    # Extract and display thinking blocks collapsed to one line
    $thinkPattern = '(?s)<think>(.*?)</think>'
    $thinkMatches = [regex]::Matches($Content, $thinkPattern)
    foreach ($m in $thinkMatches) {
        $thinkText = $m.Groups[1].Value.Trim()
        if ($thinkText) {
            $firstLine = ($thinkText -split "`n")[0].Trim()
            if ($firstLine.Length -gt 80) { $firstLine = $firstLine.Substring(0, 80) + '...' }
            Write-Host "    [thinking] $firstLine" -ForegroundColor DarkGray
        }
    }

    # Display non-think content with visual framing
    $displayContent = [regex]::Replace($Content, $thinkPattern, '').Trim()
    if ($displayContent) {
        Write-Host ""
        Write-Host "  .----- AGENT RESPONSE -------." -ForegroundColor Magenta
        $lines = $displayContent -split "`n"
        foreach ($line in $lines) {
            Write-Host "  | " -ForegroundColor Magenta -NoNewline
            Write-Host "$line" -ForegroundColor White
        }
        Write-Host "  '------------------------------'" -ForegroundColor Magenta
        Write-Host ""
    }
}

# ============================================================================
# STDERR ANALYSIS: Parse PS errors and generate hints for the model
# ============================================================================
function Analyze-Stderr {
    param([string]$Stderr)
    if (-not $Stderr) { return $null }

    # Pattern: "At C:\path\file.ps1:155 char:44" or "At line:155 char:44"
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
# MAIN AGENT LOOP
# ============================================================================

# State
$messages = [System.Collections.ArrayList]::new()
$maxToolIterations = 25

# --- Loop detection state ---
$script:recentErrors = [System.Collections.ArrayList]::new()
$script:maxRepeatedErrors = 3
$script:errorPatternWindow = 5

# --- Token tracking ---
$script:totalPromptTokens = 0
$script:totalEvalTokens = 0
$script:contextLimit = 131072
$script:genTemperature = $null   # null = use model default
$script:genContextLength = $null # null = use model default

# Detect GPU for banner
$gpuName = "unknown"
try { $gpuLine = (nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>$null); if ($gpuLine) { $gpuName = $gpuLine.Trim() } } catch {}

# Banner
$vtStatus = if ($script:vt100Enabled) { "VT100 ON" } else { "VT100 OFF" }
Write-Host ""
Write-Host "  +================================================================+" -ForegroundColor DarkGray
Write-Host "  |   " -ForegroundColor DarkGray -NoNewline
Write-Host "OLL90 AUTONOMOUS AGENT  v2.0" -ForegroundColor Green -NoNewline
Write-Host "                             |" -ForegroundColor DarkGray
Write-Host "  |   " -ForegroundColor DarkGray -NoNewline
Write-Host "Model   : " -ForegroundColor DarkGray -NoNewline
Write-Host "$Model" -ForegroundColor Cyan -NoNewline
$pad = 51 - $Model.Length; if ($pad -lt 0) { $pad = 0 }
Write-Host (" " * $pad) -NoNewline
Write-Host "|" -ForegroundColor DarkGray
Write-Host "  |   " -ForegroundColor DarkGray -NoNewline
$gpuDisplay = $gpuName
if ($gpuDisplay.Length -gt 49) { $gpuDisplay = $gpuDisplay.Substring(0, 49) }
Write-Host "GPU     : " -ForegroundColor DarkGray -NoNewline
Write-Host "$gpuDisplay" -ForegroundColor Magenta -NoNewline
$pad2 = 51 - $gpuDisplay.Length; if ($pad2 -lt 0) { $pad2 = 0 }
Write-Host (" " * $pad2) -NoNewline
Write-Host "|" -ForegroundColor DarkGray
Write-Host "  |   " -ForegroundColor DarkGray -NoNewline
Write-Host "Context : 128K | Streaming ON | $vtStatus" -ForegroundColor White -NoNewline
$pad3 = 48 - ("128K | Streaming ON | $vtStatus").Length; if ($pad3 -lt 0) { $pad3 = 0 }
Write-Host (" " * $pad3) -NoNewline
Write-Host "|" -ForegroundColor DarkGray
Write-Host "  |   " -ForegroundColor DarkGray -NoNewline
$toolCount = $tools.Count
Write-Host "Tools[$toolCount]: " -ForegroundColor DarkGray -NoNewline
Write-Host "run_powershell run_cmd write_file read_file" -ForegroundColor Yellow -NoNewline
Write-Host "  |" -ForegroundColor DarkGray
Write-Host "  |             " -ForegroundColor DarkGray -NoNewline
Write-Host "edit_file list_directory search_files" -ForegroundColor Yellow -NoNewline
Write-Host "       |" -ForegroundColor DarkGray
Write-Host "  |             " -ForegroundColor DarkGray -NoNewline
Write-Host "get_system_info web_fetch web_search" -ForegroundColor Yellow -NoNewline
Write-Host "       |" -ForegroundColor DarkGray
Write-Host "  |             " -ForegroundColor DarkGray -NoNewline
Write-Host "download_file run_python open_browser" -ForegroundColor Yellow -NoNewline
Write-Host "      |" -ForegroundColor DarkGray
Write-Host "  |             " -ForegroundColor DarkGray -NoNewline
Write-Host "clipboard net_info hash_file http_request" -ForegroundColor Yellow -NoNewline
Write-Host "   |" -ForegroundColor DarkGray
Write-Host "  |             " -ForegroundColor DarkGray -NoNewline
Write-Host "event_log git_command process_mgr service" -ForegroundColor Yellow -NoNewline
Write-Host "    |" -ForegroundColor DarkGray
Write-Host "  |             " -ForegroundColor DarkGray -NoNewline
Write-Host "compress extract json_transform speak notify" -ForegroundColor Yellow -NoNewline
Write-Host "  |" -ForegroundColor DarkGray
Write-Host "  |             " -ForegroundColor DarkGray -NoNewline
Write-Host "screenshot scheduled_task" -ForegroundColor Yellow -NoNewline
Write-Host "                     |" -ForegroundColor DarkGray
Write-Host "  |   " -ForegroundColor DarkGray -NoNewline
Write-Host "Commands: /exit /clear /history /tools /stats /save /load /retry /model" -ForegroundColor White -NoNewline
Write-Host "  |" -ForegroundColor DarkGray
Write-Host "  +================================================================+" -ForegroundColor DarkGray
Write-Host ""

# ---- Ollama startup health check ----
Write-Host "  Checking Ollama at $OllamaUrl..." -ForegroundColor DarkGray -NoNewline
$ollamaReady = $false
for ($hc = 0; $hc -lt 3; $hc++) {
    try {
        $hcResp = Invoke-WebRequest -Uri "$OllamaUrl/api/version" -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
        Write-Host " OK ($(($hcResp.Content | ConvertFrom-Json).version))" -ForegroundColor Green
        $ollamaReady = $true
        break
    } catch {
        if ($hc -eq 0) {
            Write-Host " not running. Attempting to start..." -ForegroundColor Yellow
            try { Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden -ErrorAction SilentlyContinue } catch {}
        }
        Start-Sleep -Seconds 3
    }
}
if (-not $ollamaReady) {
    Write-Host "  [WARN] Could not reach Ollama after 3 attempts. API calls may fail." -ForegroundColor Red
    Write-Host "  Run: ollama serve" -ForegroundColor Yellow
}
Write-Host ""

# Handle initial prompt
$firstInput = $null
if ($InitialPrompt -ne "") {
    $firstInput = $InitialPrompt
    Write-Host "oll90> $firstInput" -ForegroundColor Cyan
}

# Outer REPL loop
while ($true) {
    # Get user input
    if ($firstInput) {
        $userInput = $firstInput
        $firstInput = $null
    } else {
        Write-Host -NoNewline "oll90> " -ForegroundColor Cyan
        $userInput = Read-Host
    }

    # Skip empty input
    if (-not $userInput -or $userInput.Trim() -eq "") { continue }

    # Handle slash commands
    $trimmed = $userInput.Trim().ToLower()
    if ($trimmed -eq "/exit" -or $trimmed -eq "/quit") {
        Write-Host "[SYSTEM] Agent session ended." -ForegroundColor Green
        break
    }
    if ($trimmed -eq "/clear") {
        $messages.Clear()
        Write-Host "[SYSTEM] Conversation history cleared." -ForegroundColor Green
        continue
    }
    if ($trimmed -eq "/history") {
        $msgCount = $messages.Count
        $totalChars = 0
        foreach ($m in $messages) {
            if ($m.content) { $totalChars += $m.content.ToString().Length }
        }
        Write-Host "[SYSTEM] Messages: $msgCount | Est. chars: $totalChars | Est. tokens: ~$([int]($totalChars / 4))" -ForegroundColor Green
        continue
    }
    if ($trimmed -eq "/tools") {
        Write-Host "[SYSTEM] Available tools:" -ForegroundColor Green
        foreach ($t in $tools) { Write-Host "  - $($t.function.name): $($t.function.description.Substring(0, [Math]::Min(80, $t.function.description.Length)))..." -ForegroundColor White }
        continue
    }
    if ($trimmed -eq "/stats") {
        $estTokens = $script:totalPromptTokens + $script:totalEvalTokens
        $pct = if ($script:contextLimit -gt 0) { [math]::Round(($estTokens / $script:contextLimit) * 100, 1) } else { 0 }
        Write-Host "[SYSTEM] Token usage: ~$([int]($estTokens/1000))K / $([int]($script:contextLimit/1000))K ($pct%)" -ForegroundColor Green
        Write-Host "[SYSTEM] Messages: $($messages.Count)" -ForegroundColor Green
        continue
    }
    if ($trimmed.StartsWith("/save")) {
        $saveName = $trimmed.Substring(5).Trim()
        if (-not $saveName) { $saveName = "oll90_session_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".json" }
        if (-not $saveName.EndsWith(".json")) { $saveName += ".json" }
        $savePath = if ([System.IO.Path]::IsPathRooted($saveName)) { $saveName } else { "C:\Temp\$saveName" }
        try {
            $saveDir = [System.IO.Path]::GetDirectoryName($savePath)
            if (-not (Test-Path $saveDir)) { [System.IO.Directory]::CreateDirectory($saveDir) | Out-Null }
            $saveData = @{ version = 1; model = $Model; saved = (Get-Date -Format 'o'); messages = @($messages) }
            $saveJson = $saveData | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($savePath, $saveJson, [System.Text.Encoding]::UTF8)
            Write-Host "[SYSTEM] Session saved to $savePath ($($messages.Count) messages)" -ForegroundColor Green
        } catch {
            Write-Host "[SYSTEM] Save failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        continue
    }
    if ($trimmed.StartsWith("/load")) {
        $loadName = $trimmed.Substring(5).Trim()
        if (-not $loadName) { Write-Host "[SYSTEM] Usage: /load <filename or path>" -ForegroundColor Yellow; continue }
        $loadPath = if ([System.IO.Path]::IsPathRooted($loadName)) { $loadName } else { "C:\Temp\$loadName" }
        try {
            $loadJson = [System.IO.File]::ReadAllText($loadPath)
            $loadData = $loadJson | ConvertFrom-Json
            $messages.Clear()
            foreach ($lm in $loadData.messages) {
                $lmHt = @{ role = $lm.role; content = $lm.content }
                if ($lm.tool_calls) { $lmHt['tool_calls'] = $lm.tool_calls }
                [void]$messages.Add($lmHt)
            }
            Write-Host "[SYSTEM] Loaded $($messages.Count) messages from $loadPath" -ForegroundColor Green
        } catch {
            Write-Host "[SYSTEM] Load failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        continue
    }
    if ($trimmed -eq "/retry") {
        # Remove last assistant + tool messages, keep last user message to re-run
        $lastUserIdx = -1
        for ($ri = $messages.Count - 1; $ri -ge 0; $ri--) {
            if ($messages[$ri].role -eq 'user') { $lastUserIdx = $ri; break }
        }
        if ($lastUserIdx -ge 0) {
            while ($messages.Count -gt $lastUserIdx) { $messages.RemoveAt($messages.Count - 1) }
            $retryMsg = $messages[$lastUserIdx]
            $messages.RemoveAt($lastUserIdx)
            Write-Host "[SYSTEM] Retrying: $($retryMsg.content)" -ForegroundColor Yellow
            # Re-inject as current input
            $firstInput = $retryMsg.content
        } else {
            Write-Host "[SYSTEM] Nothing to retry" -ForegroundColor Yellow
        }
        continue
    }
    if ($trimmed.StartsWith("/model")) {
        $newModel = $trimmed.Substring(6).Trim()
        if (-not $newModel) {
            # List available models
            $modelList = & ollama list 2>&1
            Write-Host "[SYSTEM] Available models:`n$modelList" -ForegroundColor Green
            Write-Host "[SYSTEM] Current model: $Model  Usage: /model <name>" -ForegroundColor Yellow
        } else {
            $Model = $newModel
            Write-Host "[SYSTEM] Model switched to: $Model" -ForegroundColor Green
        }
        continue
    }
    if ($trimmed.StartsWith("/temperature")) {
        $tempVal = $trimmed.Substring(12).Trim()
        if ($tempVal -match '^\d+(\.\d+)?$') {
            $script:genTemperature = [double]$tempVal
            Write-Host "[SYSTEM] Temperature set to $($script:genTemperature)" -ForegroundColor Green
        } else {
            Write-Host "[SYSTEM] Usage: /temperature <0.0-2.0>" -ForegroundColor Yellow
        }
        continue
    }
    if ($trimmed.StartsWith("/context")) {
        $ctxVal = $trimmed.Substring(8).Trim()
        if ($ctxVal -match '^\d+$') {
            $script:genContextLength = [int]$ctxVal
            Write-Host "[SYSTEM] Context length set to $($script:genContextLength)" -ForegroundColor Green
        } else {
            Write-Host "[SYSTEM] Usage: /context <tokens, e.g. 32768>" -ForegroundColor Yellow
        }
        continue
    }

    # Add user message
    [void]$messages.Add(@{ role = "user"; content = $userInput })

    # Inner tool-calling loop
    $iteration = 0
    $taskStartTime = Get-Date
    $script:recentErrors.Clear()
    $script:thinkingRePrompted = $false
    $script:shallowScanRePrompted = $false
    $turnToolCalls = 0
    while ($iteration -lt $maxToolIterations) {
        $iteration++
        $elapsed = ((Get-Date) - $taskStartTime).ToString("mm\:ss")
        $estTokens = $script:totalPromptTokens + $script:totalEvalTokens
        $tokUsage = "~$([int]($estTokens/1000))K/$([int]($script:contextLimit/1000))K"
        Write-Host ""
        Write-Host "  ------ " -ForegroundColor DarkGray -NoNewline
        Write-Host "Step $iteration" -ForegroundColor Cyan -NoNewline
        Write-Host "/$maxToolIterations" -ForegroundColor DarkGray -NoNewline
        Write-Host " ---- " -ForegroundColor DarkGray -NoNewline
        Write-Host "$elapsed" -ForegroundColor White -NoNewline
        Write-Host " ---- " -ForegroundColor DarkGray -NoNewline
        Write-Host "$tokUsage" -ForegroundColor DarkGray -NoNewline
        Write-Host " ------" -ForegroundColor DarkGray

        # --- CONTEXT AUTO-COMPACTION at 85% ---
        $estChars = 0
        foreach ($m in $messages) {
            if ($m.content) { $estChars += $m.content.ToString().Length }
        }
        $estTokensNow = [int]($estChars / 4)
        $compactThreshold = [int]($script:contextLimit * 0.85)
        if ($estTokensNow -gt $compactThreshold -and $messages.Count -gt 10) {
            Write-Host "  [CONTEXT] " -ForegroundColor Yellow -NoNewline
            Write-Host "~$([int]($estTokensNow/1000))K tokens exceeds 85% threshold. Compacting..." -ForegroundColor Yellow
            # Keep: system (index 0) + last 8 messages
            $keepCount = 8
            $systemMsg = $messages[0]
            $middleCount = $messages.Count - 1 - $keepCount
            if ($middleCount -gt 0) {
                $middleText = ""
                for ($mi = 1; $mi -le $middleCount; $mi++) {
                    $mmsg = $messages[$mi]
                    $role = $mmsg.role
                    $txt = if ($mmsg.content) { $mmsg.content.ToString() } else { "" }
                    if ($txt.Length -gt 200) { $txt = $txt.Substring(0, 200) + '...' }
                    $middleText += "[$role] $txt`n"
                }
                $summaryMsg = @{
                    role = "system"
                    content = "[CONTEXT COMPACTED] Previous conversation summary ($middleCount messages compacted):`n$middleText"
                }
                $tail = [System.Collections.ArrayList]::new()
                for ($ti = ($messages.Count - $keepCount); $ti -lt $messages.Count; $ti++) {
                    [void]$tail.Add($messages[$ti])
                }
                $messages.Clear()
                [void]$messages.Add($systemMsg)
                [void]$messages.Add($summaryMsg)
                foreach ($t in $tail) { [void]$messages.Add($t) }
                Write-Host "  [CONTEXT] Compacted to $($messages.Count) messages" -ForegroundColor Green
            }
        }

        # Call Ollama API with retry logic
        $response = $null
        $apiRetryDelays = @(2, 5, 10)
        $apiSuccess = $false
        foreach ($retryDelay in (@(0) + $apiRetryDelays)) {
            if ($retryDelay -gt 0) {
                Write-Host "  [RETRY] Waiting ${retryDelay}s before retry..." -ForegroundColor Yellow
                Start-Sleep -Seconds $retryDelay
            }
            try {
                $response = Invoke-OllamaChat -Messages $messages -Tools $tools -ChatModel $Model -Url $OllamaUrl -Timeout $TimeoutSec
                $apiSuccess = $true
                break
            } catch {
                $errMsg = $_.Exception.Message
                # Non-retryable errors: 404 (model missing), 400 (bad request)
                $isNonRetryable = ($errMsg -match "HTTP 404" -or $errMsg -match "HTTP 400")
                if ($isNonRetryable) {
                    if ($errMsg -match "HTTP 404") {
                        Write-Host "[ERROR] Model '$Model' not found (HTTP 404). Attempting auto-recovery..." -ForegroundColor Yellow
                        # Check if Modelfile exists and attempt to create the model
                        $modelfileAlt = "C:\Temp\Modelfile.oll90"
                        $modelfileLocal = (Join-Path (Split-Path $MyInvocation.ScriptName -Parent) "Modelfile.oll90")
                        $mfPath = if (Test-Path $modelfileAlt) { $modelfileAlt } elseif (Test-Path $modelfileLocal) { $modelfileLocal } else { $null }
                        if ($mfPath) {
                            Write-Host "  [AUTO] Found Modelfile at $mfPath. Running: ollama create $Model -f $mfPath" -ForegroundColor Cyan
                            try {
                                $createOut = & ollama create $Model -f $mfPath 2>&1
                                Write-Host "  [AUTO] ollama create output: $createOut" -ForegroundColor DarkGray
                                Write-Host "  [AUTO] Model created. Retrying API call..." -ForegroundColor Green
                                # Retry once after creation
                                try {
                                    $response = Invoke-OllamaChat -Messages $messages -Tools $tools -ChatModel $Model -Url $OllamaUrl -Timeout $TimeoutSec
                                    $apiSuccess = $true
                                } catch {
                                    Write-Host "[ERROR] Still failing after model creation: $($_.Exception.Message)" -ForegroundColor Red
                                    if ($messages.Count -gt 0) { $messages.RemoveAt($messages.Count - 1) }
                                }
                            } catch {
                                Write-Host "[ERROR] ollama create failed: $($_.Exception.Message)" -ForegroundColor Red
                                Write-Host "  FIX: Manually run: ollama create $Model -f $mfPath" -ForegroundColor Yellow
                                if ($messages.Count -gt 0) { $messages.RemoveAt($messages.Count - 1) }
                            }
                        } else {
                            Write-Host "[ERROR] No Modelfile found. Run 'ollama list' to see available models." -ForegroundColor Red
                            Write-Host "  FIX: ollama create $Model -f <path-to-Modelfile.oll90>" -ForegroundColor Yellow
                            if ($messages.Count -gt 0) { $messages.RemoveAt($messages.Count - 1) }
                        }
                    } else {
                        Write-Host "[ERROR] API error (non-retryable): $errMsg" -ForegroundColor Red
                        if ($messages.Count -gt 0) { $messages.RemoveAt($messages.Count - 1) }
                    }
                    $apiSuccess = $false
                    break
                }
                # Retryable errors
                if ($retryDelay -eq $apiRetryDelays[-1]) {
                    # Final attempt failed
                    if ($errMsg -match "Unable to connect" -or $errMsg -match "ConnectFailure") {
                        Write-Host "[ERROR] Cannot reach Ollama at $OllamaUrl after retries. Is it running?" -ForegroundColor Red
                    } else {
                        Write-Host "[ERROR] API call failed after retries: $errMsg" -ForegroundColor Red
                    }
                    if ($messages.Count -gt 0) { $messages.RemoveAt($messages.Count - 1) }
                } else {
                    Write-Host "  [WARN] API call failed (will retry): $errMsg" -ForegroundColor Yellow
                }
            }
        }
        if (-not $apiSuccess) { break }

        # Validate response
        if (-not $response -or -not $response.message) {
            Write-Host "[ERROR] Unexpected response format from Ollama" -ForegroundColor Red
            break
        }

        $msg = $response.message

        # Check for tool calls
        $hasToolCalls = $false
        if ($msg.tool_calls -and $msg.tool_calls.Count -gt 0) {
            $hasToolCalls = $true
        }

        if ($hasToolCalls) {
            # Append the assistant message (with tool_calls) to history
            $assistantMsg = @{
                role = "assistant"
                content = if ($msg.content) { $msg.content } else { "" }
                tool_calls = @($msg.tool_calls)
            }
            [void]$messages.Add($assistantMsg)

            # Show any content the assistant said before calling tools
            if ($msg.content -and $msg.content.Trim()) {
                Show-AgentResponse $msg.content
            }

            # Track tool calls for shallow-scan detection
            $turnToolCalls += $msg.tool_calls.Count

            # Execute each tool call
            foreach ($tc in $msg.tool_calls) {
                $toolName = $tc.function.name
                $toolArgs = $tc.function.arguments
                # Handle arguments as string or object
                if ($toolArgs -is [string]) {
                    try { $toolArgs = $toolArgs | ConvertFrom-Json } catch { $toolArgs = @{ command = $toolArgs } }
                }
                $toolArgsHt = ConvertTo-Hashtable $toolArgs

                # Execute the tool
                $tcTimer = [System.Diagnostics.Stopwatch]::StartNew()
                $toolResult = Invoke-Tool -Name $toolName -Arguments $toolArgsHt
                $tcTimer.Stop()
                # Log tool call to JSONL
                try {
                    $logPath = "C:\Temp\oll90_tool_log.jsonl"
                    $logEntry = @{
                        ts      = (Get-Date -Format 'o')
                        tool    = $toolName
                        args    = ($toolArgsHt | ConvertTo-Json -Compress -Depth 5 -ErrorAction SilentlyContinue)
                        result_len = $toolResult.Length
                        ms      = [int]$tcTimer.Elapsed.TotalMilliseconds
                    }
                    $logLine = $logEntry | ConvertTo-Json -Compress
                    $logDir2 = [System.IO.Path]::GetDirectoryName($logPath)
                    if (-not (Test-Path $logDir2)) { [System.IO.Directory]::CreateDirectory($logDir2) | Out-Null }
                    # Rotate if >10MB
                    if ((Test-Path $logPath) -and (Get-Item $logPath).Length -gt 10MB) {
                        Move-Item $logPath ($logPath -replace '\.jsonl$', '_old.jsonl') -Force
                    }
                    Add-Content -Path $logPath -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue
                } catch {}

                # Append tool result to messages
                [void]$messages.Add(@{
                    role = "tool"
                    content = $toolResult
                })
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

            # Continue the inner loop - let the model see the tool results
            continue
        } else {
            # No tool calls - just content response
            [void]$messages.Add(@{
                role = "assistant"
                content = if ($msg.content) { $msg.content } else { "" }
            })

            $content = $msg.content
            $cleanContent = ""
            if ($content) { $cleanContent = [regex]::Replace($content, '(?s)<think>.*?</think>', '').Trim() }
            $onlyThinking = (-not $cleanContent -and $content -and $content -match '(?s)<think>')

            # --- SHALLOW SCAN CHECK (one re-prompt per turn) ---
            $isDeepScanTask = $userInput -match '(?i)(scan deeply|deep scan|deeply scan)'
            if ($isDeepScanTask -and $turnToolCalls -lt 5 -and -not $script:shallowScanRePrompted) {
                $script:shallowScanRePrompted = $true
                Write-Host ""
                Write-Host "  [SHALLOW SCAN: $turnToolCalls tool calls - requiring deeper scan]" -ForegroundColor Yellow
                Write-Host ""
                $rePrompt = "[SYSTEM] Your scan was too shallow ($turnToolCalls tool calls). The task requires a DEEP scan. Call run_powershell multiple more times to gather: CPU specs, GPU details (nvidia-smi), RAM, storage, network adapters, top processes, temperatures. Make at least 5+ more tool calls before writing your plan."
                [void]$messages.Add(@{ role = "user"; content = $rePrompt })
                continue
            }

            # --- THINKING-ONLY CHECK (one re-prompt per turn) ---
            if ($onlyThinking -and -not $script:thinkingRePrompted) {
                $script:thinkingRePrompted = $true
                Write-Host ""
                Write-Host "  [thinking-only response - prompting for visible output]" -ForegroundColor Yellow
                Write-Host ""
                $rePrompt = "[SYSTEM] CRITICAL: Your last response was ENTIRELY inside <think> blocks. The user CANNOT see <think> content. Output your response as PLAIN VISIBLE TEXT right now - no <think> tags."
                [void]$messages.Add(@{ role = "user"; content = $rePrompt })
                continue
            }

            # Content already streamed inline, just add framing
            $content = $msg.content
            $cleanContent2 = ""
            if ($content) { $cleanContent2 = [regex]::Replace($content, '(?s)<think>.*?</think>', '').Trim() }
            if (-not $cleanContent2 -and $turnToolCalls -gt 0) {
                # No visible response but tools ran - add note
                Write-Host ""
                Write-Host "  [agent completed tools without text summary]" -ForegroundColor DarkGray
            }
            Write-Host ""
            break
        }
    }

    if ($iteration -ge $maxToolIterations) {
        Write-Host "[WARN] Reached max tool iterations ($maxToolIterations). Breaking out." -ForegroundColor DarkYellow
    }

    # Task summary
    $taskDuration = ((Get-Date) - $taskStartTime).ToString("mm\:ss")
    $hadErrors = ($script:recentErrors.Count -gt 0)
    $estTokFinal = $script:totalPromptTokens + $script:totalEvalTokens
    $tokPctFinal = if ($script:contextLimit -gt 0) { [math]::Round(($estTokFinal / $script:contextLimit) * 100, 1) } else { 0 }
    Write-Host ""
    Write-Host "  ================================================" -ForegroundColor DarkGray
    if ($hadErrors) {
        Write-Host "   COMPLETED WITH ERRORS" -ForegroundColor Yellow
    } else {
        Write-Host "   COMPLETED" -ForegroundColor Green
    }
    Write-Host "   Steps: " -ForegroundColor DarkGray -NoNewline
    Write-Host "$iteration" -ForegroundColor White -NoNewline
    Write-Host "   Tools: " -ForegroundColor DarkGray -NoNewline
    Write-Host "$turnToolCalls" -ForegroundColor White -NoNewline
    Write-Host "   Time: " -ForegroundColor DarkGray -NoNewline
    Write-Host "$taskDuration" -ForegroundColor White -NoNewline
    Write-Host "   Ctx: " -ForegroundColor DarkGray -NoNewline
    Write-Host "~$([int]($estTokFinal/1000))K ($tokPctFinal%)" -ForegroundColor Cyan
    if ($hadErrors) {
        Write-Host "   Errors: " -ForegroundColor DarkGray -NoNewline
        Write-Host "$($script:recentErrors.Count)" -ForegroundColor Red
    } else {
        Write-Host ""
    }
    Write-Host "  ================================================" -ForegroundColor DarkGray
    Write-Host ""
    $script:recentErrors.Clear()
}
