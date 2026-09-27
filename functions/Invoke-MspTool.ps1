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
    if (-not $tool) {
        # Report rather than throw, so one mistyped ID doesn't abort the rest of a batch/procedure
        & $OnLog "[ERROR] Unknown tool: $ToolId (use -ListTools to see valid IDs)"
        return @{ Id = $ToolId; Name = $ToolId; Success = $false; Skipped = $false; Error = "Unknown tool: $ToolId" }
    }

    $name = $tool.Content
    & $OnLog "[START] $name ($ToolId)"

    if ($tool.RequiresAdmin -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        & $OnLog "[SKIP] $name requires administrator privileges"
        return @{ Id = $ToolId; Name = $name; Success = $false; Skipped = $true }
    }

    try {
        foreach ($scriptBlock in @($tool.InvokeScript)) {
            $block = [scriptblock]::Create($scriptBlock)
            # *>&1 (not 2>&1) so Write-Host/verbose/warning output reaches OnLog - the GUI log
            # and the .log file - too. Piping streams each line as it's produced, so an
            # interactive tool's menu still appears before its Read-Host prompt.
            & $block *>&1 | ForEach-Object {
                if ($null -ne $_ -and "$_".Trim()) {
                    & $OnLog "  $_"
                }
            }
        }
        & $OnLog "[DONE] $name"
        return @{ Id = $ToolId; Name = $name; Success = $true; Skipped = $false }
    }
    catch {
        & $OnLog "[ERROR] $name - $($_.Exception.Message)"
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

        [scriptblock]$OnLog
    )

    $results = @()
    foreach ($id in $ToolIds) {
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
