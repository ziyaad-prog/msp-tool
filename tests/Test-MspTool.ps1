#Requires -Version 5.1
<#
.SYNOPSIS
    Self-contained test suite for MSP Tool (no Pester dependency - Windows ships only Pester 3.4).

.DESCRIPTION
    Checks that every script parses, every config file is valid, every tool/preset/procedure
    reference resolves, the tool engine behaves, and the entry points' list commands run.
    Never runs a real tool. Exits with the number of failed checks (0 = all passed).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MspTool.ps1
#>
[CmdletBinding()]
param([switch]$SkipEntryPoints)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$script:failures = 0
$script:passes = 0

function Assert-True {
    param([bool]$Condition, [string]$Name, [string]$Detail)
    if ($Condition) { $script:passes++; Write-Host "  [PASS] $Name" -ForegroundColor Green }
    else { $script:failures++; Write-Host "  [FAIL] $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Red }
}

function Test-ParsesClean {
    param([string]$Code)
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$errors)
    return @($errors)
}

function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }

# ---------------------------------------------------------------------------
Write-Host 'PowerShell files parse' -ForegroundColor Cyan
$psFiles = @(Get-ChildItem -Path $repo -Recurse -Include *.ps1 -File | Where-Object { $_.FullName -notmatch '\\\.git\\' })
foreach ($f in $psFiles) {
    $errs = Test-ParsesClean (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8)
    Assert-True ($errs.Count -eq 0) ($f.FullName.Substring($repo.Length + 1)) (($errs | Select-Object -First 1 | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }))
}

# ---------------------------------------------------------------------------
Write-Host 'Config files are valid JSON' -ForegroundColor Cyan
$tools = $null; $presets = $null
try { $tools = Read-Json (Join-Path $repo 'config\tools.json'); Assert-True $true 'config\tools.json' } catch { Assert-True $false 'config\tools.json' $_.Exception.Message }
try { $presets = Read-Json (Join-Path $repo 'config\presets.json'); Assert-True $true 'config\presets.json' } catch { Assert-True $false 'config\presets.json' $_.Exception.Message }
$procedures = @{}
foreach ($f in @(Get-ChildItem -Path (Join-Path $repo 'config\procedures') -Filter *.json -ErrorAction SilentlyContinue)) {
    try { $procedures[$f.Name] = Read-Json $f.FullName; Assert-True $true "config\procedures\$($f.Name)" } catch { Assert-True $false "config\procedures\$($f.Name)" $_.Exception.Message }
}

# ---------------------------------------------------------------------------
Write-Host 'Tool definitions' -ForegroundColor Cyan
$toolIds = @()
if ($tools) {
    $toolIds = @($tools.PSObject.Properties.Name)
    $referenced = @{}
    foreach ($p in $tools.PSObject.Properties) {
        $t = $p.Value; $names = @($t.PSObject.Properties.Name); $problems = @()
        foreach ($field in 'Content', 'Description', 'category') { if (-not $t.$field) { $problems += "missing $field" } }
        if ($names -notcontains 'RequiresAdmin' -or $t.RequiresAdmin -isnot [bool]) { $problems += 'RequiresAdmin must be true/false' }
        if ($names -contains 'Script') {
            $path = Join-Path $repo $t.Script
            $referenced[[IO.Path]::GetFullPath($path).ToLowerInvariant()] = $true
            if (-not (Test-Path -LiteralPath $path)) { $problems += "script file not found: $($t.Script)" }
        }
        elseif ($names -contains 'InvokeScript') {
            foreach ($code in @($t.InvokeScript)) { if ((Test-ParsesClean $code).Count) { $problems += 'InvokeScript does not parse' } }
        }
        else { $problems += 'needs Script or InvokeScript' }
        Assert-True ($problems.Count -eq 0) $p.Name ($problems -join '; ')
    }
    $orphans = @(Get-ChildItem -Path (Join-Path $repo 'tools') -Filter *.ps1 -ErrorAction SilentlyContinue | Where-Object { -not $referenced.ContainsKey($_.FullName.ToLowerInvariant()) } | ForEach-Object Name)
    Assert-True ($orphans.Count -eq 0) 'every tools\*.ps1 file is registered in tools.json' ($orphans -join ', ')
}

# ---------------------------------------------------------------------------
Write-Host 'Preset and procedure references' -ForegroundColor Cyan
if ($presets) {
    foreach ($p in $presets.PSObject.Properties) {
        $missing = @($p.Value.Tools | Where-Object { $toolIds -notcontains $_ })
        Assert-True ($missing.Count -eq 0 -and @($p.Value.Tools).Count -gt 0) "preset $($p.Name)" ("unknown tools: " + ($missing -join ', '))
    }
}
foreach ($name in $procedures.Keys) {
    $json = $procedures[$name]
    $props = @($json.PSObject.Properties)
    $proc = if ($props.Count -eq 1) { $props[0].Value } else { $json }
    $steps = @($proc.Sections | ForEach-Object { $_.Steps })
    $missing = @($steps | Where-Object { $_.Type -eq 'tool' -and $toolIds -notcontains $_.ToolId } | ForEach-Object { $_.ToolId })
    $badType = @($steps | Where-Object { $_.Type -notin 'tool', 'manual' } | ForEach-Object { $_.Id })
    Assert-True ($missing.Count -eq 0 -and $badType.Count -eq 0) "procedure $name" (@("unknown tools: $($missing -join ', ')", "bad step types: $($badType -join ', ')") -join '; ')
}

# ---------------------------------------------------------------------------
Write-Host 'Tool engine' -ForegroundColor Cyan
. (Join-Path $repo 'functions\Invoke-MspTool.ps1')
$tmp = Join-Path $repo 'tools\__test_tool.ps1'
try {
    Set-Content -LiteralPath $tmp -Value "Write-Host 'from host'; Write-Output 'from output'; Write-Warning 'from warning'" -Encoding UTF8
    $cfg = @{
        FileTool   = [pscustomobject]@{ Content = 'File tool'; RequiresAdmin = $false; Script = 'tools/__test_tool.ps1' }
        InlineTool = [pscustomobject]@{ Content = 'Inline tool'; RequiresAdmin = $false; InvokeScript = @("Write-Host 'inline ok'") }
        BadTool    = [pscustomobject]@{ Content = 'Throwing tool'; RequiresAdmin = $false; InvokeScript = @("throw 'boom'") }
    }
    $log = [System.Collections.Generic.List[string]]::new()
    $results = @(Invoke-MspToolBatch -ToolIds FileTool, Typo, InlineTool, BadTool -ToolConfig $cfg -OnLog { param($m) $log.Add($m) })
    $text = $log -join "`n"
    Assert-True ($text -match 'from host' -and $text -match 'from output' -and $text -match 'from warning') 'captures Write-Host, output, and warnings from a Script file'
    Assert-True ($text -match 'inline ok') 'still runs inline InvokeScript tools'
    Assert-True ($results.Count -eq 4 -and $results[1].Success -eq $false -and $text -match 'Unknown tool: Typo') 'unknown tool ID is reported and the batch continues'
    Assert-True ($results[3].Success -eq $false -and $text -match '\[ERROR\] Throwing tool - boom') 'a throwing tool is reported as failed'
    Assert-True ($results[0].Success -and $results[2].Success) 'successful tools report success'

    # Combined all-tools report
    Assert-True ($null -eq (Start-MspCombinedReportEntry -ToolName 'x' -ToolId 'x')) 'no combined report is written unless $MspCombinedReportPath is set'
    $MspCombinedReportPath = Join-Path ([IO.Path]::GetTempPath()) "msptool-combined-test-$PID.txt"
    try {
        $null = Invoke-MspToolBatch -ToolIds FileTool, Typo, BadTool -ToolConfig $cfg -OnLog { param($m) }
        $null = Invoke-MspToolBatch -ToolIds InlineTool -ToolConfig $cfg -OnLog { param($m) }
        $combinedText = Get-Content -LiteralPath $MspCombinedReportPath -Raw -Encoding UTF8
        $headers = ([regex]::Matches($combinedText, '(?m)^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  .+ \((FileTool|Typo|BadTool|InlineTool)\)\r?$')).Count
        Assert-True ($headers -eq 4) "combined report gets a header per tool run, appended across batches (found $headers of 4)"
        Assert-True ($combinedText -match 'from host' -and $combinedText -match 'from warning' -and $combinedText -match 'inline ok') 'combined report contains each tool''s output'
        Assert-True ($combinedText -match 'Unknown tool: Typo' -and $combinedText -match '\[ERROR\] Throwing tool - boom' -and $combinedText -match '\[DONE\] File tool') 'combined report records results (DONE / unknown / ERROR)'
        $bytes = [IO.File]::ReadAllBytes($MspCombinedReportPath); $boms = 0
        for ($i = 0; $i -lt $bytes.Length - 2; $i++) { if ($bytes[$i] -eq 0xEF -and $bytes[$i + 1] -eq 0xBB -and $bytes[$i + 2] -eq 0xBF) { $boms++ } }
        Assert-True ($boms -le 1) "appending does not scatter byte-order marks through the file (found $boms)"
        $MspCombinedReportMaxMB = 0.0001   # ~100 bytes: the next run must rotate the full file to .old
        $null = Invoke-MspToolBatch -ToolIds InlineTool -ToolConfig $cfg -OnLog { param($m) }
        $rotatedOk = (Test-Path -LiteralPath "$MspCombinedReportPath.old") -and ((Get-Content -LiteralPath $MspCombinedReportPath -Raw) -notmatch 'FileTool')
        Assert-True $rotatedOk 'combined report rotates to .old once it passes the size limit'
    }
    finally {
        Remove-Item -LiteralPath $MspCombinedReportPath, "$MspCombinedReportPath.old" -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name MspCombinedReportPath, MspCombinedReportMaxMB -ErrorAction SilentlyContinue
    }
}
finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------------------
if (-not $SkipEntryPoints) {
    Write-Host 'Entry point list commands (read-only, no elevation)' -ForegroundColor Cyan
    $logFile = Join-Path ([IO.Path]::GetTempPath()) "msptool-test-$PID.log"
    foreach ($entry in 'msptool.ps1', 'msptool-console.ps1') {
        foreach ($flag in '-ListTools', '-ListPresets', '-ListProcedures') {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo $entry) $flag -NoTranscript -LogFile $logFile 2>&1 | Out-String
            Assert-True ($LASTEXITCODE -eq 0) "$entry $flag" ($output.Trim() -split "`n" | Select-Object -Last 1)
        }
    }
    Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Write-Host ''
$color = if ($script:failures) { 'Red' } else { 'Green' }
Write-Host ("{0} passed, {1} failed" -f $script:passes, $script:failures) -ForegroundColor $color
exit $script:failures
