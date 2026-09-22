function Show-MspConsoleMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$ToolConfig,

        [Parameter(Mandatory)]
        [hashtable]$PresetConfig,

        [string[]]$ProcedureNames = @(),

        [scriptblock]$OnRun,

        [scriptblock]$OnProcedure
    )

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    $categories = @('All') + @($ToolConfig.Values | ForEach-Object { $_.category } | Sort-Object -Unique)

    # Mutable state lives in a hashtable so nested helper functions below can read
    # AND write it - plain scalar variables would be re-scoped (shadowed) the moment
    # a nested function assigned to them, silently losing the change.
    $state = @{
        CategoryIndex = 0
        SearchFilter  = ''
    }
    $selected = @{}
    foreach ($id in $ToolConfig.Keys) { $selected[$id] = $false }

    function Get-VisibleToolIds {
        $cat = $categories[$state.CategoryIndex]
        $filter = $state.SearchFilter.Trim().ToLowerInvariant()

        $ToolConfig.GetEnumerator() |
            Where-Object {
                $tool = $_.Value
                if ($cat -ne 'All' -and $tool.category -ne $cat) { return $false }
                if ($filter) {
                    $text = "$($tool.Content) $($tool.Description)".ToLowerInvariant()
                    if (-not $text.Contains($filter)) { return $false }
                }
                return $true
            } |
            Sort-Object `
                { $_.Value.category }, `
                { if ($_.Value.PSObject.Properties.Name -contains 'Order') { $_.Value.Order } else { 9999 } }, `
                { $_.Value.Content } |
            ForEach-Object { $_.Key }
    }

    function Write-MspMenuHeader {
        Write-Host ''
        Write-Host ('=' * 78) -ForegroundColor DarkCyan
        Write-Host ' MSP TOOL - Console Menu' -ForegroundColor Cyan
        Write-Host ('=' * 78) -ForegroundColor DarkCyan
        if ($isAdmin) {
            Write-Host ' Administrator' -ForegroundColor Green -NoNewline
        }
        else {
            Write-Host ' Standard User (some tools require Admin)' -ForegroundColor Yellow -NoNewline
        }
        Write-Host ("   Category: {0}   Filter: {1}" -f $categories[$state.CategoryIndex], $(if ($state.SearchFilter) { "'$($state.SearchFilter)'" } else { '(none)' }))
    }

    function Show-MspToolList {
        $ids = @(Get-VisibleToolIds)
        Write-Host ''
        if ($ids.Count -eq 0) {
            Write-Host '  (no tools match the current category/filter)' -ForegroundColor DarkGray
            return $ids
        }

        $lastCategory = $null
        for ($i = 0; $i -lt $ids.Count; $i++) {
            $id = $ids[$i]
            $tool = $ToolConfig[$id]
            if ($tool.category -ne $lastCategory) {
                Write-Host ''
                Write-Host " $($tool.category)" -ForegroundColor Blue
                $lastCategory = $tool.category
            }
            $mark = if ($selected[$id]) { '[x]' } else { '[ ]' }
            $adminTag = if ($tool.RequiresAdmin -and -not $isAdmin) { '  (admin)' } else { '' }
            Write-Host ('  {0,3}. {1} {2}{3}' -f ($i + 1), $mark, $tool.Content, $adminTag)
            Write-Host ("        $($tool.Description)") -ForegroundColor DarkGray
        }
        return $ids
    }

    function Show-MspCommandBar {
        Write-Host ''
        Write-Host ' [#] toggle tool(s), e.g. 1,3,5   [a] select all shown   [x] clear all' -ForegroundColor DarkGray
        Write-Host ' [c] change category   [f] set search filter   [p] apply preset' -ForegroundColor DarkGray
        Write-Host ' [m] run a procedure   [v] view selected   [r] run selected   [q] quit' -ForegroundColor DarkGray
    }

    function Select-MspPreset {
        $names = @($PresetConfig.Keys | Sort-Object)
        if ($names.Count -eq 0) {
            Write-Host 'No presets defined.' -ForegroundColor Yellow
            return
        }

        Write-Host ''
        for ($i = 0; $i -lt $names.Count; $i++) {
            Write-Host ("  [{0}] {1} - {2}" -f ($i + 1), $names[$i], $PresetConfig[$names[$i]].Description)
        }
        $choice = Read-Host 'Preset number (blank to cancel)'
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $names.Count) {
            $presetName = $names[[int]$choice - 1]
            $preset = $PresetConfig[$presetName]
            foreach ($id in @($selected.Keys)) { $selected[$id] = $false }
            foreach ($id in $preset.Tools) {
                if ($selected.ContainsKey($id)) { $selected[$id] = $true }
            }
            Write-Host "Applied preset: $presetName" -ForegroundColor Green
        }
    }

    function Select-MspProcedure {
        if ($ProcedureNames.Count -eq 0) {
            Write-Host 'No procedures defined.' -ForegroundColor Yellow
            return
        }

        Write-Host ''
        for ($i = 0; $i -lt $ProcedureNames.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $ProcedureNames[$i])
        }
        $choice = Read-Host 'Procedure number (blank to cancel)'
        if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $ProcedureNames.Count) { return }

        $name = $ProcedureNames[[int]$choice - 1]
        $autoOnly = (Read-Host 'Automated steps only? (y/N)') -match '^[Yy]'
        & $OnProcedure $name $autoOnly { param($m) Write-Host $m }
        Read-Host 'Procedure finished. Press Enter to continue' | Out-Null
    }

    function Show-MspSelectedTools {
        $ids = @($selected.GetEnumerator() | Where-Object Value | ForEach-Object { $_.Key })
        Write-Host ''
        if ($ids.Count -eq 0) {
            Write-Host 'No tools selected.' -ForegroundColor Yellow
        }
        else {
            Write-Host "Selected ($($ids.Count)):" -ForegroundColor Cyan
            foreach ($id in $ids) {
                Write-Host ("  - {0} ({1})" -f $ToolConfig[$id].Content, $id)
            }
        }
        Read-Host 'Press Enter to continue' | Out-Null
    }

    Write-Host ''
    Write-Host 'MSP Tool ready. Select tools by number, apply a preset, or run a procedure.' -ForegroundColor Green

    while ($true) {
        Write-MspMenuHeader
        $visibleIds = @(Show-MspToolList)
        Show-MspCommandBar

        $cmd = (Read-Host 'Command').Trim()
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }

        switch -Regex ($cmd) {
            '^[Qq](uit)?$' {
                return
            }
            '^[Aa]$' {
                foreach ($id in $visibleIds) { $selected[$id] = $true }
                break
            }
            '^[Xx]$' {
                foreach ($id in @($selected.Keys)) { $selected[$id] = $false }
                break
            }
            '^[Cc]$' {
                Write-Host ''
                for ($i = 0; $i -lt $categories.Count; $i++) {
                    Write-Host ("  [{0}] {1}" -f $i, $categories[$i])
                }
                $choice = Read-Host 'Category number (blank to cancel)'
                if ($choice -match '^\d+$' -and [int]$choice -ge 0 -and [int]$choice -lt $categories.Count) {
                    $state.CategoryIndex = [int]$choice
                }
                break
            }
            '^[Ff]$' {
                $state.SearchFilter = Read-Host 'Search text (blank to clear)'
                break
            }
            '^[Pp]$' {
                Select-MspPreset
                break
            }
            '^[Mm]$' {
                Select-MspProcedure
                break
            }
            '^[Vv]$' {
                Show-MspSelectedTools
                break
            }
            '^[Rr]$' {
                $chosen = @($selected.GetEnumerator() | Where-Object Value | ForEach-Object { $_.Key })
                if ($chosen.Count -eq 0) {
                    Write-Host 'No tools selected.' -ForegroundColor Yellow
                    break
                }
                Write-Host "Running $($chosen.Count) tool(s)..." -ForegroundColor Cyan
                & $OnRun $chosen { param($m) Write-Host $m }
                Read-Host 'Batch complete. Press Enter to continue' | Out-Null
                break
            }
            '^[\d, ]+$' {
                foreach ($token in ($cmd -split '[,\s]+' | Where-Object { $_ })) {
                    $idx = [int]$token - 1
                    if ($idx -ge 0 -and $idx -lt $visibleIds.Count) {
                        $id = $visibleIds[$idx]
                        $selected[$id] = -not $selected[$id]
                    }
                }
                break
            }
            default {
                Write-Host "Unrecognized command: $cmd" -ForegroundColor Yellow
                Start-Sleep -Milliseconds 800
                break
            }
        }
    }
}
