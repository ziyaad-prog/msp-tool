#Requires -Version 5.1
<#
.SYNOPSIS
    MSP Tool - Select and run Windows maintenance, diagnostic, and setup tools.

.DESCRIPTION
    WinUtil-style GUI for MSP technicians. Tools are defined in config/tools.json.
    Presets bundle common workflows in config/presets.json.

.PARAMETER Preset
    Run a named preset without opening the GUI.

.PARAMETER Tools
    Run specific tool IDs without opening the GUI.

.PARAMETER ListTools
    List all available tool IDs and exit.

.PARAMETER ListPresets
    List all available presets and exit.

.EXAMPLE
    .\msptool.ps1

.EXAMPLE
    .\msptool.ps1 -Preset QuickHealthCheck

.EXAMPLE
    .\msptool.ps1 -Tools MspDiagSystemInfo, MspDiagNetwork
#>
[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'Preset')]
    [string]$Preset,

    [Parameter(ParameterSetName = 'Tools')]
    [string[]]$Tools,

    [Parameter(ParameterSetName = 'Procedure')]
    [string]$Procedure,

    [Parameter(ParameterSetName = 'Procedure')]
    [switch]$AutoOnly,

    [Parameter(ParameterSetName = 'Procedure')]
    [switch]$Interactive,

    [Parameter(ParameterSetName = 'List')]
    [switch]$ListTools,

    [Parameter(ParameterSetName = 'List')]
    [switch]$ListPresets,

    [Parameter(ParameterSetName = 'List')]
    [switch]$ListProcedures,

    [string]$LogFile,

    [switch]$NoTranscript
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# Logging: capture all actions, inputs, and command output to a file
# ---------------------------------------------------------------------------
$logDir = Join-Path $ScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
if (-not $LogFile) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogFile = Join-Path $logDir "msp-$env:COMPUTERNAME-$stamp.log"
}

function Write-MspLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Write-MspHeader {
    Write-MspLog "================ MSP TOOL SESSION ================"
    Write-MspLog "Computer : $env:COMPUTERNAME"
    Write-MspLog "User     : $env:USERDOMAIN\$env:USERNAME"
    Write-MspLog "Started  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-MspLog "PS       : $($PSVersionTable.PSVersion)"
    Write-MspLog "--- Invocation inputs ---"
    foreach ($bound in $PSBoundParameters.GetEnumerator()) {
        if ($bound.Key -eq 'LogFile') { continue }
        Write-MspLog ("  -{0} = {1}" -f $bound.Key, ($bound.Value -join ', '))
    }
    if (-not $PSBoundParameters.Count -or $PSBoundParameters.Keys.Count -eq 0) {
        Write-MspLog "  (no parameters - interactive GUI session)"
    }
    Write-MspLog "---------------------------------------------------"
}

Write-MspHeader

if (-not $NoTranscript) {
    try { Start-Transcript -Path "$($LogFile).transcript.txt" -Append | Out-Null } catch { }
}


# Auto-elevate: relaunch as Administrator if not already elevated
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
    foreach ($bound in $PSBoundParameters.GetEnumerator()) {
        if ($bound.Value -is [switch] -and $bound.Value.IsPresent) {
            $argList += "-$($bound.Key)"
        }
        else {
            $argList += "-$($bound.Key)"; $argList += "`"$($bound.Value)`""
        }
    }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
        exit 0
    }
    catch {
        Write-Warning "Elevation cancelled - continuing without admin rights (some tools will be skipped)."
    }
}

function Get-MspConfig {
    param([string]$Name)

    $path = Join-Path $ScriptRoot "config\$Name.json"
    if (-not (Test-Path $path)) {
        throw "Config not found: $path"
    }

    $json = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $hash = @{}
    foreach ($prop in $json.PSObject.Properties) {
        $hash[$prop.Name] = $prop.Value
    }
    return $hash
}

. (Join-Path $ScriptRoot 'functions\Invoke-MspTool.ps1')
. (Join-Path $ScriptRoot 'functions\Invoke-MspProcedure.ps1')

$toolConfig = Get-MspConfig -Name 'tools'
$presetConfig = Get-MspConfig -Name 'presets'

if ($ListTools) {
    $toolConfig.GetEnumerator() |
        Sort-Object { $_.Value.category }, { $_.Value.Content } |
        ForEach-Object {
            [PSCustomObject]@{
                Id       = $_.Key
                Name     = $_.Value.Content
                Category = $_.Value.category
                Admin    = [bool]$_.Value.RequiresAdmin
            }
        } | Format-Table -AutoSize
    Exit-MspSession
}

if ($ListPresets) {
    $presetConfig.GetEnumerator() |
        Sort-Object Name |
        ForEach-Object {
            [PSCustomObject]@{
                Preset      = $_.Key
                Description = $_.Value.Description
                ToolCount   = $_.Value.Tools.Count
            }
        } | Format-Table -AutoSize
    Exit-MspSession
}

if ($ListProcedures) {
    Get-MspProcedureNames | ForEach-Object {
        $proc = Resolve-MspProcedure -Name $_
        [PSCustomObject]@{
            Procedure   = $_
            Title       = $proc.Title
            Description = $proc.Description
        }
    } | Format-Table -AutoSize -Wrap
    Exit-MspSession
}

function Exit-MspSession {
    param([int]$Code = 0)
    if (-not $NoTranscript) { try { Stop-Transcript | Out-Null } catch { } }
    Write-MspLog "Session ended: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-MspLog "Log saved: $LogFile"
    exit $Code
}

function Write-MspConsoleLog {
    param([string]$Message)
    Write-Host $Message
    Write-MspLog $Message
}

if ($Procedure) {
    $procConfig = Resolve-MspProcedure -Name $Procedure
    Write-MspLog "ACTION: Running procedure '$Procedure'"
    Invoke-MspProcedure -Procedure $procConfig -ToolConfig $toolConfig -AutoOnly:$AutoOnly -Interactive:$Interactive -OnLog { param($m) Write-MspConsoleLog $m }
    Exit-MspSession
}

if ($Preset) {
    if (-not $presetConfig.ContainsKey($Preset)) {
        Write-Error "Unknown preset: $Preset. Use -ListPresets to see available presets."
    }

    $toolIds = $presetConfig[$Preset].Tools
    Write-MspLog "ACTION: Running preset '$Preset' (tools: $($toolIds -join ', '))"
    Write-Host "Running preset: $Preset ($($toolIds.Count) tools)"
    $results = Invoke-MspToolBatch -ToolIds $toolIds -ToolConfig $toolConfig -OnLog { param($m) Write-MspConsoleLog $m }
    $ok = @($results | Where-Object Success).Count
    Write-Host "Completed: $ok/$($results.Count) succeeded"
    Write-MspLog "RESULT: Preset '$Preset' completed $ok/$($results.Count) succeeded"
    Exit-MspSession
}

if ($Tools) {
    Write-MspLog "ACTION: Running tools ($($Tools -join ', '))"
    Write-Host "Running $($Tools.Count) selected tool(s)"
    $results = Invoke-MspToolBatch -ToolIds $Tools -ToolConfig $toolConfig -OnLog { param($m) Write-MspConsoleLog $m }
    $ok = @($results | Where-Object Success).Count
    Write-Host "Completed: $ok/$($results.Count) succeeded"
    Write-MspLog "RESULT: Tools completed $ok/$($results.Count) succeeded"
    Exit-MspSession
}

. (Join-Path $ScriptRoot 'functions\Show-MspGui.ps1')

Show-MspGui -ToolConfig $toolConfig -PresetConfig $presetConfig -ProcedureNames @(Get-MspProcedureNames) -OnRun {
    param([string[]]$SelectedIds, [scriptblock]$OnLog)
    Invoke-MspToolBatch -ToolIds $SelectedIds -ToolConfig $toolConfig -OnLog $OnLog | Out-Null
} -OnProcedure {
    param([string]$Name, [bool]$AutoOnly, [scriptblock]$OnLog)
    $procConfig = Resolve-MspProcedure -Name $Name
    Invoke-MspProcedure -Procedure $procConfig -ToolConfig $toolConfig -AutoOnly:$AutoOnly -OnLog $OnLog
}
