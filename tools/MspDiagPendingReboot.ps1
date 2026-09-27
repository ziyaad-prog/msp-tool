# ---------------- Settings ----------------
# Warn when the machine has been up longer than this many days
$maxUptimeDays = 7
# Registry locations checked for pending reboot indicators
$cbsKeys = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress',
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
)
$wuKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
$sessionManagerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
$activeNameKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName'
$pendingNameKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'
$netlogonKeys = @('HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\JoinDomain', 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\AvoidSpnSet')
# ------------------------------------------

Write-Host '=== Pending Reboot Check ===' -ForegroundColor Cyan
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host ''

$results = New-Object System.Collections.Generic.List[object]
function Add-Indicator {
  param([string]$Name, [string]$State, [string]$Detail = '')
  $results.Add([pscustomobject]@{ Indicator = $Name; Pending = $State; Detail = $Detail })
}

# 1. Component Based Servicing (Windows servicing / feature installs)
try {
  $hit = @($cbsKeys | Where-Object { Test-Path -Path $_ })
  if ($hit.Count) { Add-Indicator 'Component Based Servicing' 'YES' (($hit | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') }
  else { Add-Indicator 'Component Based Servicing' 'NO' }
} catch { Add-Indicator 'Component Based Servicing' 'UNKNOWN' $_.Exception.Message }

# 2. Windows Update
try {
  if (Test-Path -Path $wuKey) { Add-Indicator 'Windows Update' 'YES' 'RebootRequired key present' } else { Add-Indicator 'Windows Update' 'NO' }
} catch { Add-Indicator 'Windows Update' 'UNKNOWN' $_.Exception.Message }

# 3. Pending file rename operations (files replaced at next boot - can be stale/benign)
try {
  $sm = Get-ItemProperty -Path $sessionManagerKey -ErrorAction Stop
  $ops = @()
  foreach ($n in 'PendingFileRenameOperations', 'PendingFileRenameOperations2') {
    $prop = $sm.PSObject.Properties[$n]
    if ($prop -and $prop.Value) { $ops += @($prop.Value | Where-Object { "$_".Trim() }) }
  }
  if ($ops.Count) {
    # Entries come in source/destination pairs
    Add-Indicator 'Pending file rename operations' 'YES' ('{0} pending file operation(s)' -f [math]::Ceiling($ops.Count / 2))
  } else { Add-Indicator 'Pending file rename operations' 'NO' }
} catch { Add-Indicator 'Pending file rename operations' 'UNKNOWN' $_.Exception.Message }

# 4. Pending computer rename
try {
  $active = (Get-ItemProperty -Path $activeNameKey -ErrorAction Stop).ComputerName
  $pending = (Get-ItemProperty -Path $pendingNameKey -ErrorAction Stop).ComputerName
  if ($active -and $pending -and $active -ne $pending) { Add-Indicator 'Pending computer rename' 'YES' "$active -> $pending" }
  else { Add-Indicator 'Pending computer rename' 'NO' }
} catch { Add-Indicator 'Pending computer rename' 'UNKNOWN' $_.Exception.Message }

# 5. Pending domain join
try {
  $hit = @($netlogonKeys | Where-Object { Test-Path -Path $_ })
  if ($hit.Count) { Add-Indicator 'Pending domain join' 'YES' (($hit | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') }
  else { Add-Indicator 'Pending domain join' 'NO' }
} catch { Add-Indicator 'Pending domain join' 'UNKNOWN' $_.Exception.Message }

# 6. ConfigMgr (SCCM) client - only if installed
try {
  $ccm = Invoke-CimMethod -Namespace 'root\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending' -ErrorAction Stop
  if ($ccm.RebootPending -or $ccm.IsHardRebootPending) {
    Add-Indicator 'ConfigMgr client' 'YES' $(if ($ccm.IsHardRebootPending) { 'hard reboot pending' } else { 'reboot pending' })
  } else { Add-Indicator 'ConfigMgr client' 'NO' }
} catch {
  if ("$($_.Exception.Message)" -match 'Invalid namespace|Invalid class|not found') { Add-Indicator 'ConfigMgr client' 'N/A' 'ConfigMgr client not installed' }
  else { Add-Indicator 'ConfigMgr client' 'UNKNOWN' $_.Exception.Message }
}

# ---------------- Results ----------------
Write-Host '--- Pending reboot indicators ---' -ForegroundColor Cyan
foreach ($r in $results) {
  $color = switch ($r.Pending) { 'YES' { 'Red' } 'NO' { 'Green' } 'UNKNOWN' { 'Yellow' } default { 'Gray' } }
  $detail = if ($r.Detail) { "  ($($r.Detail))" } else { '' }
  Write-Host ('  {0,-32} {1}{2}' -f $r.Indicator, $r.Pending, $detail) -ForegroundColor $color
}

$pendingList = @($results | Where-Object { $_.Pending -eq 'YES' })
Write-Host ''
if ($pendingList.Count) {
  Write-Host "VERDICT: RESTART REQUIRED - $($pendingList.Count) indicator(s): $(($pendingList | ForEach-Object { $_.Indicator }) -join ', ')" -ForegroundColor Red
  if ($pendingList.Count -eq 1 -and $pendingList[0].Indicator -eq 'Pending file rename operations') {
    Write-Host '  Note: pending file renames alone are often left by installers/AV and can persist - treat as low priority.' -ForegroundColor Yellow
  }
} elseif (@($results | Where-Object { $_.Pending -eq 'UNKNOWN' }).Count) {
  Write-Host 'VERDICT: No reboot pending from the indicators that could be read (some could not be checked - see UNKNOWN above).' -ForegroundColor Yellow
} else {
  Write-Host 'VERDICT: No reboot pending.' -ForegroundColor Green
}

# ---------------- Uptime ----------------
Write-Host ''
Write-Host '--- Uptime ---' -ForegroundColor Cyan
try {
  $lastBoot = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
  $up = (Get-Date) - $lastBoot
  Write-Host ('  Last boot : {0}' -f $lastBoot.ToString('yyyy-MM-dd HH:mm'))
  Write-Host ('  Uptime    : {0} day(s) {1} hour(s)' -f $up.Days, $up.Hours)
  if ($up.TotalDays -gt $maxUptimeDays) {
    Write-Host "[WARN] Uptime is more than $maxUptimeDays days - schedule a restart." -ForegroundColor Yellow
    Write-Host '  Note: with Fast Startup on, "Shut down" does not reset uptime - the user must choose Restart.' -ForegroundColor Yellow
  }
} catch {
  Write-Host "  Could not read last boot time: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ---------------- Restart offer (only when pending) ----------------
if (-not $pendingList.Count) { return }
Write-Host ''
Write-Host 'Restarting will close all open programs and disconnect any signed-in user. Make sure the user has saved their work.' -ForegroundColor Yellow
$answer = Read-Host 'Restart now? (y/N)'
if ($answer -match '^(y|yes)$') {
  Write-Host 'Restarting the computer...' -ForegroundColor Yellow
  try { Restart-Computer -Force -ErrorAction Stop } catch { Write-Host "[FAIL] Could not restart: $($_.Exception.Message)" -ForegroundColor Red }
} else {
  Write-Host 'Restart skipped. RESTART REQUIRED - restart the computer when convenient.' -ForegroundColor Yellow
}
