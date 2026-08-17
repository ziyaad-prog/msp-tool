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
    [switch]$ListProcedures
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

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
    exit 0
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
    exit 0
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
    exit 0
}

function Write-MspConsoleLog {
    param([string]$Message)
    Write-Host $Message
}

if ($Procedure) {
    $procConfig = Resolve-MspProcedure -Name $Procedure
    Invoke-MspProcedure -Procedure $procConfig -ToolConfig $toolConfig -AutoOnly:$AutoOnly -Interactive:$Interactive -OnLog { param($m) Write-MspConsoleLog $m }
    exit 0
}

if ($Preset) {
    if (-not $presetConfig.ContainsKey($Preset)) {
        Write-Error "Unknown preset: $Preset. Use -ListPresets to see available presets."
    }

    $toolIds = $presetConfig[$Preset].Tools
    Write-Host "Running preset: $Preset ($($toolIds.Count) tools)"
    $results = Invoke-MspToolBatch -ToolIds $toolIds -ToolConfig $toolConfig -OnLog { param($m) Write-MspConsoleLog $m }
    $ok = @($results | Where-Object Success).Count
    Write-Host "Completed: $ok/$($results.Count) succeeded"
    exit 0
}

if ($Tools) {
    Write-Host "Running $($Tools.Count) selected tool(s)"
    $results = Invoke-MspToolBatch -ToolIds $Tools -ToolConfig $toolConfig -OnLog { param($m) Write-MspConsoleLog $m }
    $ok = @($results | Where-Object Success).Count
    Write-Host "Completed: $ok/$($results.Count) succeeded"
    exit 0
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
