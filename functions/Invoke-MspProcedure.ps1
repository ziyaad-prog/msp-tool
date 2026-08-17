function Resolve-MspProcedure {
    param([string]$Name)

    $fileName = if ($Name -match '-') { $Name } else { ($Name -creplace '([a-z])([A-Z])', '$1-$2').ToLower() }
    $path = Join-Path $ScriptRoot "config\procedures\$fileName.json"
    if (-not (Test-Path $path)) {
        throw "Procedure not found: $Name (looked for $path)"
    }

    $json = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($json.PSObject.Properties.Count -eq 1) {
        return $json.PSObject.Properties[0].Value
    }
    return $json
}

function Get-MspProcedureConfig {
    param([string]$ProcedureName)

    return Resolve-MspProcedure -Name $ProcedureName
}

function Get-MspProcedureNames {
    $dir = Join-Path $ScriptRoot 'config\procedures'
    if (-not (Test-Path $dir)) { return @() }

    Get-ChildItem -Path $dir -Filter '*.json' | ForEach-Object {
        $json = Get-Content -Path $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($json.PSObject.Properties.Count -eq 1) {
            $json.PSObject.Properties[0].Name
        } else {
            $_.BaseName
        }
    }
}

function Invoke-MspProcedure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Procedure,

        [Parameter(Mandatory)]
        [hashtable]$ToolConfig,

        [switch]$AutoOnly,

        [switch]$Interactive,

        [scriptblock]$OnLog
    )

    if (-not $OnLog) {
        $OnLog = { param($m) Write-Host $m }
    }

    & $OnLog "=========================================="
    & $OnLog "PROCEDURE: $($Procedure.Title)"
    & $OnLog $Procedure.Description
    & $OnLog "Keywords: $($Procedure.Keywords -join ', ')"
    if ($Procedure.Reference) {
        & $OnLog "Reference: $($Procedure.Reference)"
    }
    & $OnLog "=========================================="
    & $OnLog ""

    $stepNum = 0
    $automated = 0
    $manual = 0

    foreach ($section in @($Procedure.Sections)) {
        & $OnLog ""
        & $OnLog "--- $($section.Title) ---"
        if ($section.Description) {
            & $OnLog $section.Description
        }

        foreach ($step in @($section.Steps)) {
            $stepNum++
            $label = "[$stepNum] $($step.Title)"

            if ($step.Type -eq 'tool') {
                $automated++
                & $OnLog ""
                & $OnLog ">> AUTOMATED: $label"
                if ($step.Instructions) {
                    & $OnLog "   Note: $($step.Instructions)"
                }

                if ($Interactive) {
                    $prompt = Read-Host "Run this step? [Y/n/s=skip remaining automated]"
                    if ($prompt -eq 's') { $AutoOnly = $true; continue }
                    if ($prompt -eq 'n') {
                        & $OnLog "   Skipped by user."
                        continue
                    }
                }

                Invoke-MspTool -ToolId $step.ToolId -ToolConfig $ToolConfig -OnLog $OnLog | Out-Null
            }
            else {
                $manual++
                if ($AutoOnly) { continue }

                & $OnLog ""
                & $OnLog ">> MANUAL: $label"
                & $OnLog "   $($step.Instructions)"

                if ($Interactive) {
                    Read-Host "Press Enter when this manual step is complete (or type s to skip remaining manual steps)"
                }
            }
        }
    }

    & $OnLog ""
    & $OnLog "=========================================="
    & $OnLog "Procedure complete. Automated: $automated | Manual: $manual"
    & $OnLog "=========================================="
}
