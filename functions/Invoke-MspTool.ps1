function Get-MspToolScripts {
    # A tool's code lives in the file named by "Script" (path relative to the repo root);
    # inline "InvokeScript" strings are still accepted for custom tools.
    param([Parameter(Mandatory)]$Tool)

    if ($Tool.PSObject.Properties.Name -contains 'Script' -and $Tool.Script) {
        $root = Split-Path -Parent $PSScriptRoot
        $path = Join-Path $root $Tool.Script
        if (-not (Test-Path -LiteralPath $path)) { throw "Tool script not found: $path" }
        return , (Get-Content -LiteralPath $path -Raw -Encoding UTF8)
    }
    return , @($Tool.InvokeScript)
}

# Combined all-tools report: once it grows past this size it is renamed to .old (replacing any
# previous .old) and a new file is started
$MspCombinedReportMaxMB = 10

function Get-MspDefaultCombinedReportPath {
    Join-Path (Join-Path $env:USERPROFILE 'Desktop\MSP-Reports') "all-tools-report-$env:COMPUTERNAME.txt"
}

function Start-MspCombinedReportEntry {
    <#
      Writes the header for one tool run to the combined report and returns its path, or $null when
      no combined report is configured. The app turns it on by setting $MspCombinedReportPath (the
      entry scripts and the GUI do); tests and ad-hoc callers that just load the engine don't write one.
    #>
    param([string]$ToolName, [string]$ToolId)

    $path = Get-Variable -Name MspCombinedReportPath -ValueOnly -ErrorAction SilentlyContinue
    if (-not $path) { return $null }
    try {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt ($MspCombinedReportMaxMB * 1MB)) {
            Move-Item -LiteralPath $path -Destination "$path.old" -Force
        }
        $header = @(
            ''
            ('=' * 78)
            ('{0}  {1} ({2})' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $ToolName, $ToolId)
            ('Computer: {0}   User: {1}\{2}' -f $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME)
            ('=' * 78)
        )
        Add-Content -LiteralPath $path -Value $header -Encoding UTF8
        return $path
    }
    catch { return $null }
}

function Read-MspHostWithTimeout {
    <#
      A prompt that takes $Default if nothing is typed within $TimeoutSeconds. Once typing starts it
      waits for Enter. Returns $Default for Enter on an empty line, and immediately when there is no
      interactive console (RMM, redirected input). The GUI replaces this function with a countdown
      dialog, where Cancel returns $null - so callers should treat $null as "skip".
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [int]$TimeoutSeconds = 5,
        [string]$Default = ''
    )

    $interactive = $false
    try { $interactive = $Host.Name -eq 'ConsoleHost' -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected } catch { }
    if (-not $interactive) { return $Default }

    # Prompt and keystroke echo go straight to the console: Write-Host output from a tool is captured
    # and re-printed line by line by the engine, which would break an in-place countdown.
    try {
        [Console]::Write("$Prompt [$Default in $TimeoutSeconds s]: ")
        $buffer = ''
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ($buffer -or (Get-Date) -lt $deadline) {
            if (-not [Console]::KeyAvailable) { Start-Sleep -Milliseconds 50; continue }
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Enter') { [Console]::WriteLine(); return $(if ($buffer) { $buffer } else { $Default }) }
            if ($key.Key -eq 'Backspace') {
                if ($buffer.Length) { $buffer = $buffer.Substring(0, $buffer.Length - 1); [Console]::Write("`b `b") }
                continue
            }
            if (-not [char]::IsControl($key.KeyChar)) { $buffer += $key.KeyChar; [Console]::Write($key.KeyChar) }
        }
        [Console]::WriteLine("$Default (no answer - default used)")
        return $Default
    }
    catch { return $Default }
}

function Invoke-MspTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ToolId,

        [Parameter(Mandatory)]
        [hashtable]$ToolConfig,

        [scriptblock]$OnLog
    )

    $tool = $ToolConfig[$ToolId]
    $name = if ($tool) { $tool.Content } else { $ToolId }

    # Every line also goes to the combined all-tools report when the app has set one up
    # ($MspCombinedReportPath - see Start-MspCombinedReportEntry)
    $combined = Start-MspCombinedReportEntry -ToolName $name -ToolId $ToolId
    $emit = {
        param($m)
        & $OnLog $m
        if ($combined) { try { Add-Content -LiteralPath $combined -Value $m -Encoding UTF8 } catch { } }
    }

    if (-not $tool) {
        # Report rather than throw, so one mistyped ID doesn't abort the rest of a batch/procedure
        & $emit "[ERROR] Unknown tool: $ToolId (use -ListTools to see valid IDs)"
        return @{ Id = $ToolId; Name = $ToolId; Success = $false; Skipped = $false; Error = "Unknown tool: $ToolId" }
    }

    & $emit "[START] $name ($ToolId)"

    if ($tool.RequiresAdmin -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        & $emit "[SKIP] $name requires administrator privileges"
        return @{ Id = $ToolId; Name = $name; Success = $false; Skipped = $true }
    }

    try {
        foreach ($scriptBlock in @(Get-MspToolScripts -Tool $tool)) {
            $block = [scriptblock]::Create($scriptBlock)
            # *>&1 (not 2>&1) so Write-Host/verbose/warning output reaches OnLog - the GUI log
            # and the .log file - too. Piping streams each line as it's produced, so an
            # interactive tool's menu still appears before its Read-Host prompt.
            & $block *>&1 | ForEach-Object {
                if ($null -ne $_ -and "$_".Trim()) {
                    & $emit "  $_"
                }
            }
        }
        & $emit "[DONE] $name"
        return @{ Id = $ToolId; Name = $name; Success = $true; Skipped = $false }
    }
    catch {
        & $emit "[ERROR] $name - $($_.Exception.Message)"
        return @{ Id = $ToolId; Name = $name; Success = $false; Skipped = $false; Error = $_.Exception.Message }
    }
}

function Invoke-MspToolBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ToolIds,

        [Parameter(Mandatory)]
        [hashtable]$ToolConfig,

        [scriptblock]$OnLog,

        # Checked before each tool; returning $true ends the batch. Never interrupts a running tool,
        # so a tool's own cleanup (e.g. restarting services it stopped) always completes.
        [scriptblock]$ShouldStop
    )

    $results = @()
    foreach ($id in $ToolIds) {
        if ($ShouldStop -and (& $ShouldStop)) {
            & $OnLog "[STOP] Stopped before '$id' - remaining tools were not run"
            break
        }
        & $OnLog "[WAIT] Starting next tool only after the previous one completes"
        $results += Invoke-MspTool -ToolId $id -ToolConfig $ToolConfig -OnLog $OnLog
        & $OnLog ''
    }

    $completed = @($results | Where-Object Success).Count
    $failed = @($results | Where-Object { -not $_.Success -and -not $_.Skipped }).Count
    $skipped = @($results | Where-Object Skipped).Count
    & $OnLog "[COMPLETE] Selected tools completed: $completed success, $failed failed, $skipped skipped"
    return $results
}
