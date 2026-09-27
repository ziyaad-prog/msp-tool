# Launched by Test-MspGui.ps1: opens the real MSP Tool GUI with harmless fake tools (print, sleep, prompt).
param([string]$LogFile, [string]$CombinedReport)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$ScriptRoot = $repo
. "$repo\functions\Invoke-MspTool.ps1"
. "$repo\functions\Invoke-MspProcedure.ps1"
. "$repo\functions\Show-MspGui.ps1"
$tools = @{
    TestSlow   = [pscustomobject]@{ Content = 'Test Slow Tool'; Description = 'Sleeps five seconds'; category = 'Test'; RequiresAdmin = $false; InvokeScript = @("Write-Host 'slow start'; Start-Sleep -Seconds 5; Write-Host 'slow end'") }
    TestSlow2  = [pscustomobject]@{ Content = 'Test Slow Tool 2'; Description = 'Second sleeper'; category = 'Test'; RequiresAdmin = $false; InvokeScript = @("Write-Host 'slow2 start'; Start-Sleep -Seconds 5; Write-Host 'slow2 end'") }
    TestTimed  = [pscustomobject]@{ Content = 'Test Timed Prompt Tool'; Description = 'Asks with a countdown'; category = 'Test'; RequiresAdmin = $false; InvokeScript = @(@'
$a = Read-MspHostWithTimeout -Prompt 'Timed question one' -TimeoutSeconds 3 -Default 'dflt'
Write-Host "timed1=$a"
$b = Read-MspHostWithTimeout -Prompt 'Timed question two' -TimeoutSeconds 3 -Default 'dflt'
Write-Host "timed2=$b"
$c = Read-MspHostWithTimeout -Prompt 'Timed question three' -TimeoutSeconds 3 -Default 'dflt'
Write-Host "timed3=[$c] isnull=$($null -eq $c)"
'@) }
    TestPrompt = [pscustomobject]@{ Content = 'Test Prompt Tool'; Description = 'Asks questions'; category = 'Test'; RequiresAdmin = $false; InvokeScript = @(@'
Write-Host '  [1] Alpha'
Write-Host '  [2] Beta'
$a = Read-Host 'Pick a number'
Write-Host "picked=$a"
$s = Read-Host 'Enter a secret' -AsSecureString
Write-Host "secretLen=$(if ($s) { $s.Length } else { 'null' })"
$c = Get-Credential -Message 'Credentials please'
Write-Host "user=$($c.UserName) pwLen=$($c.Password.Length)"
'@) }
}
Show-MspGui -ToolConfig $tools -PresetConfig @{ TestPreset = [pscustomobject]@{ Description = 'test'; Tools = @('TestSlow') } } -ProcedureNames @('PerformanceTroubleshooting') -LogFile $LogFile -CombinedReport $CombinedReport
