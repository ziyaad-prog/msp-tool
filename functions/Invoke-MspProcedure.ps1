function Resolve-MspProcedure {
    param([string]$Name)

    $fileName = if ($Name -match '-') { $Name } else { ($Name -creplace '([a-z])([A-Z])', '$1-$2').ToLower() }
    $path = Join-Path $ScriptRoot "config\procedures\$fileName.json"
    if (-not (Test-Path $path)) {
        throw "Procedure not found: $Name (looked for $path)"
    }

    $json = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    # PSObject.Properties indexes by member name, not position - wrap in @() to index by position
    $props = @($json.PSObject.Properties)
    if ($props.Count -eq 1) {
        return $props[0].Value
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
        $props = @($json.PSObject.Properties)
        if ($props.Count -eq 1) {
            $props[0].Name
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

        [scriptblock]$OnLog,

        # Checked before each step; returning $true ends the procedure (a running tool is never interrupted)
        [scriptblock]$ShouldStop
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
    $skipAutomated = $false
    $skipManual = [bool]$AutoOnly

    foreach ($section in @($Procedure.Sections)) {
        & $OnLog ""
        & $OnLog "--- $($section.Title) ---"
        if ($section.Description) {
            & $OnLog $section.Description
        }

        foreach ($step in @($section.Steps)) {
            if ($ShouldStop -and (& $ShouldStop)) {
                & $OnLog ""
                & $OnLog "[STOP] Procedure stopped - remaining steps were not run"
                return
            }
            $stepNum++
            $label = "[$stepNum] $($step.Title)"

            if ($step.Type -eq 'tool') {
                $automated++
                if ($skipAutomated) { continue }

                & $OnLog ""
                & $OnLog ">> AUTOMATED: $label"
                if ($step.Instructions) {
                    & $OnLog "   Note: $($step.Instructions)"
                }

                if ($Interactive) {
                    $prompt = Read-Host "Run this step? [Y/n/s=skip remaining automated]"
                    if ($prompt -eq 's') {
                        $skipAutomated = $true
                        & $OnLog "   Skipped by user (and all remaining automated steps)."
                        continue
                    }
                    if ($prompt -eq 'n') {
                        & $OnLog "   Skipped by user."
                        continue
                    }
                }

                Invoke-MspTool -ToolId $step.ToolId -ToolConfig $ToolConfig -OnLog $OnLog | Out-Null
            }
            else {
                $manual++
                if ($skipManual) { continue }

                & $OnLog ""
                & $OnLog ">> MANUAL: $label"
                & $OnLog "   $($step.Instructions)"

                if ($Interactive) {
                    $prompt = Read-Host "Press Enter when this manual step is complete (or type s to skip remaining manual steps)"
                    if ($prompt -eq 's') {
                        $skipManual = $true
                        & $OnLog "   Remaining manual steps skipped by user."
                    }
                }
            }
        }
    }

    & $OnLog ""
    & $OnLog "=========================================="
    & $OnLog "Procedure complete. Automated: $automated | Manual: $manual"
    & $OnLog "=========================================="
}
