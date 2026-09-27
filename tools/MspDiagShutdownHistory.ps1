# ---------------- Settings ----------------
# How many days of the System log to look at
$daysBack = 30
# Flag when there are more than this many unexpected shutdown incidents
$unexpectedThreshold = 2
# Events within this many minutes of each other count as ONE incident (41 + 6008 + 1001 are logged together after a crash)
$incidentWindowMinutes = 10
# System log event IDs collected
$eventIds = @(6008, 41, 1001, 1074, 6005, 6006)
# Common bugcheck codes -> names (for BSOD events)
$bugcheckNames = @{
  0x0A = 'IRQL_NOT_LESS_OR_EQUAL'; 0x19 = 'BAD_POOL_HEADER'; 0x1A = 'MEMORY_MANAGEMENT'; 0x1E = 'KMODE_EXCEPTION_NOT_HANDLED'
  0x3B = 'SYSTEM_SERVICE_EXCEPTION'; 0x50 = 'PAGE_FAULT_IN_NONPAGED_AREA'; 0x7E = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'
  0x7F = 'UNEXPECTED_KERNEL_MODE_TRAP'; 0x9F = 'DRIVER_POWER_STATE_FAILURE'; 0xA0 = 'INTERNAL_POWER_ERROR'; 0xC2 = 'BAD_POOL_CALLER'
  0xD1 = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL'; 0xEF = 'CRITICAL_PROCESS_DIED'; 0x101 = 'CLOCK_WATCHDOG_TIMEOUT'; 0x116 = 'VIDEO_TDR_FAILURE'
  0x124 = 'WHEA_UNCORRECTABLE_ERROR'; 0x133 = 'DPC_WATCHDOG_VIOLATION'; 0x139 = 'KERNEL_SECURITY_CHECK_FAILURE'
  0x154 = 'UNEXPECTED_STORE_EXCEPTION'; 0x1D8 = 'ATTEMPTED_SWITCH_FROM_DPC'
}
# ------------------------------------------

function Get-EventDataMap {
  # Named EventData values from the event XML (empty map if unavailable)
  param($Event)
  $map = @{}
  try {
    $x = [xml]$Event.ToXml()
    foreach ($d in @($x.Event.EventData.Data)) { if ($d -and $d.Name) { $map[$d.Name] = "$($d.'#text')" } }
  } catch { }
  return $map
}

function Get-EventProp {
  param($Event, [int]$Index)
  $props = @($Event.Properties)
  if ($props.Count -gt $Index -and $null -ne $props[$Index]) { return "$($props[$Index].Value)".Trim() }
  return ''
}

function Get-BugcheckText {
  param([string]$Hex)
  if (-not $Hex) { return '' }
  try {
    $code = [Convert]::ToInt64(($Hex -replace '^0x', ''), 16)
    $name = if ($code -le [int]::MaxValue) { $bugcheckNames[[int]$code] } else { $null }
    $short = '0x{0:X}' -f $code
    if ($name) { return "$short $name" } else { return $short }
  } catch { return $Hex }
}

$since = (Get-Date).AddDays(-$daysBack)
Write-Host '=== Unexpected Shutdown History ===' -ForegroundColor Cyan
Write-Host "Computer: $env:COMPUTERNAME    System log since $($since.ToString('yyyy-MM-dd'))"
Write-Host ''

try {
  $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = $eventIds; StartTime = $since } -ErrorAction Stop)
} catch {
  if ("$($_.Exception.Message)" -match 'No events were found') { $events = @() }
  else { Write-Host "[FAIL] Could not read the System event log: $($_.Exception.Message)" -ForegroundColor Red; return }
}

$timeline = New-Object System.Collections.Generic.List[object]
foreach ($e in $events) {
  $type = $null; $detail = ''; $severity = 'Info'
  $provider = "$($e.ProviderName)"
  switch ($e.Id) {
    6008 {
      if ($provider -notmatch 'EventLog') { break }
      $type = 'Unexpected shutdown'; $severity = 'Bad'
      $msg = "$($e.Message)" -replace '[\u200e\u200f]', ''
      $detail = if ($msg) { ($msg -split "`r?`n")[0].Trim() } else { 'The previous system shutdown was unexpected.' }
    }
    41 {
      if ($provider -notmatch 'Kernel-Power') { break }
      $type = 'Dirty reboot (Kernel-Power 41)'; $severity = 'Bad'
      $d = Get-EventDataMap $e
      $bits = @()
      $bc = $d['BugcheckCode']
      if ($bc -and $bc -ne '0') { $bits += 'bugcheck ' + (Get-BugcheckText ('0x{0:X}' -f [int64]$bc)) }
      if ($d['PowerButtonTimestamp'] -and $d['PowerButtonTimestamp'] -ne '0') { $bits += 'power button was held' }
      if ($d['SleepInProgress'] -and $d['SleepInProgress'] -notin @('0', 'false')) { $bits += 'during sleep/hibernate' }
      $detail = if ($bits.Count) { $bits -join '; ' } else { 'rebooted without a clean shutdown (power loss, hang, or forced power-off)' }
    }
    1001 {
      if ($provider -notmatch 'WER-SystemErrorReporting|BugCheck') { break }
      $type = 'BSOD (BugCheck 1001)'; $severity = 'Bad'
      $msg = "$($e.Message)"
      $hex = ''
      if ($msg -match 'bugcheck was:\s*(0x[0-9a-fA-F]+)') { $hex = $matches[1] }
      elseif ((Get-EventProp $e 0) -match '^(0x[0-9a-fA-F]+)') { $hex = $matches[1] }
      $detail = if ($hex) { 'bugcheck ' + (Get-BugcheckText $hex) } else { 'bugcheck code not available' }
      if ($msg -match 'saved in:\s*(\S+?)\.?\s*(Report Id|$)') { $detail += "; dump: $($matches[1])" }
    }
    1074 {
      if ($provider -notmatch 'User32') { break }
      $proc = Get-EventProp $e 0; $reason = Get-EventProp $e 2; $kind = Get-EventProp $e 4; $comment = Get-EventProp $e 5; $user = Get-EventProp $e 6
      $proc = $proc -replace '\s*\([^)]*\)\s*$', ''
      $type = if ($kind -match 'restart') { 'Restart (user/process)' } elseif ($kind) { "Shutdown ($kind)" } else { 'Shutdown (user/process)' }
      $severity = 'Planned'
      $detail = "by $(if ($user) { $user } else { '?' }) via $(Split-Path -Leaf $proc) - reason: $reason"
      if ($comment) { $detail += " - comment: $comment" }
    }
    6005 { if ($provider -match 'EventLog') { $type = 'Boot (Event Log started)' } }
    6006 { if ($provider -match 'EventLog') { $type = 'Clean shutdown (Event Log stopped)' } }
  }
  if ($type) { $timeline.Add([pscustomobject]@{ Time = $e.TimeCreated; EventId = $e.Id; Type = $type; Severity = $severity; Detail = $detail }) }
}

if (-not $timeline.Count) {
  Write-Host "No shutdown, restart or boot events found in the last $daysBack days." -ForegroundColor Green
  return
}

# ---------------- Timeline (newest first) ----------------
$sorted = @($timeline | Sort-Object Time -Descending)
Write-Host '--- Timeline (newest first) ---' -ForegroundColor Cyan
foreach ($t in $sorted) {
  $color = switch ($t.Severity) { 'Bad' { 'Red' } 'Planned' { 'Yellow' } default { 'Gray' } }
  $line = '  {0}  {1,-36} {2}' -f $t.Time.ToString('yyyy-MM-dd HH:mm:ss'), $t.Type, $t.Detail
  Write-Host $line.TrimEnd() -ForegroundColor $color
}

# ---------------- Summary ----------------
Write-Host ''
Write-Host '--- Summary ---' -ForegroundColor Cyan
foreach ($g in @($timeline | Group-Object Type | Sort-Object Count -Descending)) {
  Write-Host ('  {0,-36} {1}' -f $g.Name, $g.Count)
}

# Group crash-related events (41/6008/1001) that happened close together into incidents
$bad = @($timeline | Where-Object { $_.Severity -eq 'Bad' } | Sort-Object Time)
$incidents = 0; $last = $null
foreach ($b in $bad) {
  if (-not $last -or ($b.Time - $last).TotalMinutes -gt $incidentWindowMinutes) { $incidents++ }
  $last = $b.Time
}
$bsods = @($timeline | Where-Object { $_.EventId -eq 1001 }).Count
Write-Host ''
if ($incidents -gt $unexpectedThreshold) {
  Write-Host "[WARN] $incidents unexpected shutdown incident(s) in $daysBack days (threshold $unexpectedThreshold) - investigate power, hardware, drivers and overheating." -ForegroundColor Red
} elseif ($incidents) {
  Write-Host "$incidents unexpected shutdown incident(s) in $daysBack days." -ForegroundColor Yellow
} else {
  Write-Host "No unexpected shutdowns in $daysBack days." -ForegroundColor Green
}
if ($bsods) { Write-Host "  $bsods BSOD(s): check C:\Windows\Minidump and driver/BIOS updates for the listed bugcheck code(s)." -ForegroundColor Yellow }
if ($incidents) { Write-Host '  Note: Kernel-Power 41 and 6008 are usually logged together for the same crash; they are counted as one incident.' }

# ---------------- CSV export ----------------
Write-Host ''
$save = Read-Host 'Save the timeline as CSV to the reports folder? (y/N)'
if ($save -match '^(y|yes)$') {
  try {
    $reportDir = Join-Path $env:USERPROFILE 'Desktop\MSP-Reports'
    if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
    $file = Join-Path $reportDir "shutdown-history-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    $sorted | Select-Object @{ n = 'Time'; e = { $_.Time.ToString('yyyy-MM-dd HH:mm:ss') } }, EventId, Type, Detail |
      Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
    Write-Host "Saved: $file" -ForegroundColor Green
  } catch {
    Write-Host "[FAIL] Could not save the CSV: $($_.Exception.Message)" -ForegroundColor Red
  }
}
