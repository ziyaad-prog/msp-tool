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
        throw "Unknown tool: $ToolId"
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
            $output = & $block 2>&1
            foreach ($line in @($output)) {
                if ($null -ne $line -and "$line".Trim()) {
                    & $OnLog "  $line"
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
    }
    return $results
}
