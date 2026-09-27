# Printer troubleshooter: list printers and queues, clear stuck jobs, restart the spooler,
# print a test page, set the default printer. Viewing works without admin; spooler actions need admin.
# Jobs older than this many minutes (or in an error state) are flagged as stuck
$stuckMinutes = 30
# Job status words that mean a job is stuck
$stuckStatusPattern = 'Error|Deleting|Blocked|UserIntervention|Offline|PaperOut|Paused'
# Spool folder emptied by option 2 (all queued jobs for all printers live here)
$spoolDir = "$env:SystemRoot\System32\spool\PRINTERS"
# Seconds to wait for the Print Spooler to stop or start
$spoolerTimeoutSec = 30
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem

function Wait-Spooler {
  param($Status)
  for ($i = 0; $i -le $spoolerTimeoutSec; $i++) {
    $s = Get-Service -Name Spooler -ErrorAction SilentlyContinue
    if ($s -and "$($s.Status)" -eq $Status) { return $true }
    if ($i -lt $spoolerTimeoutSec) { Start-Sleep -Seconds 1 }
  }
  return $false
}
function Get-PrinterData {
  $cim = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue)
  $list = @()
  foreach ($p in @(Get-Printer -ErrorAction Stop)) {
    try { $jobs = @(Get-PrintJob -PrinterName $p.Name -ErrorAction Stop) } catch { $jobs = @() }
    $cutoff = (Get-Date).AddMinutes(-$stuckMinutes)
    $stuck = @($jobs | Where-Object { "$($_.JobStatus)" -match $stuckStatusPattern -or ($_.SubmittedTime -and $_.SubmittedTime -lt $cutoff) })
    $c = $cim | Where-Object { $_.Name -eq $p.Name } | Select-Object -First 1
    $list += [pscustomobject]@{
      Name = $p.Name; Driver = $p.DriverName; Port = $p.PortName; Status = "$($p.PrinterStatus)"
      Default = [bool]($c -and $c.Default); Shared = [bool]$p.Shared; Jobs = $jobs; Stuck = $stuck
    }
  }
  return $list
}
function Select-Printer {
  param($Printers, $Prompt)
  if (-not $Printers.Count) { Write-Host 'No printers available.' -ForegroundColor Yellow; return $null }
  for ($i = 0; $i -lt $Printers.Count; $i++) { Write-Host ('  [{0}] {1}' -f ($i + 1), $Printers[$i].Name) }
  $sel = Read-Host "$Prompt, or 0 to cancel"
  if (-not $sel -or $sel -eq '0') { Write-Host 'Cancelled.' -ForegroundColor Yellow; return $null }
  if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $Printers.Count) { Write-Host 'Invalid selection.' -ForegroundColor Yellow; return $null }
  return $Printers[[int]$sel - 1]
}
function Get-CimPrinter {
  param($Name)
  Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

if ($isSystem) { Write-Host 'NOTE: running as SYSTEM - per-user printers and the user''s default printer are not visible here.' -ForegroundColor Yellow }
while ($true) {
  Write-Host ''
  $spooler = Get-Service -Name Spooler -ErrorAction SilentlyContinue
  if (-not $spooler) { Write-Host 'Print Spooler service not found on this computer.' -ForegroundColor Red; return }
  $running = "$($spooler.Status)" -eq 'Running'
  Write-Host "Print Spooler: $($spooler.Status) (startup: $($spooler.StartType))" -ForegroundColor $(if ($running) { 'Green' } else { 'Red' })
  $printers = @()
  if ($running) {
    try { $printers = @(Get-PrinterData) } catch { Write-Host "Could not list printers: $($_.Exception.Message)" -ForegroundColor Red }
    if ($printers.Count) {
      Write-Host '--- Printers ---' -ForegroundColor Cyan
      for ($i = 0; $i -lt $printers.Count; $i++) {
        $p = $printers[$i]
        $flags = @()
        if ($p.Default) { $flags += 'DEFAULT' }
        if ($p.Shared) { $flags += 'shared' }
        $flagText = if ($flags.Count) { '  (' + ($flags -join ', ') + ')' } else { '' }
        Write-Host ('  [{0}] {1}{2}' -f ($i + 1), $p.Name, $flagText)
        $line = '      Driver: {0} | Port: {1} | Status: {2} | Jobs: {3} ({4} stuck)' -f $p.Driver, $p.Port, $p.Status, $p.Jobs.Count, $p.Stuck.Count
        Write-Host $line -ForegroundColor $(if ($p.Stuck.Count) { 'Yellow' } else { 'Gray' })
      }
    } else {
      Write-Host 'No printers are installed for this user/computer.' -ForegroundColor Yellow
    }
  } else {
    Write-Host 'The Print Spooler is not running - printers and queues cannot be listed. Use [3] to start it.' -ForegroundColor Yellow
    if ("$($spooler.StartType)" -eq 'Disabled') { Write-Host 'Its startup type is Disabled (possibly on purpose by policy / PrintNightmare hardening) - check before re-enabling it in services.msc.' -ForegroundColor Yellow }
  }

  Write-Host ''
  Write-Host '  [1] Clear stuck jobs for one printer'
  Write-Host '  [2] Clear ALL print jobs (stops spooler, empties spool folder) - admin'
  Write-Host ('  [3] {0} Print Spooler - admin' -f $(if ($running) { 'Restart' } else { 'Start' }))
  Write-Host '  [4] Print a test page'
  Write-Host '  [5] Set default printer'
  Write-Host '  [0] Exit'
  $choice = Read-Host 'Enter a number (1-5), or 0 to exit'
  if (-not $choice -or $choice -eq '0') { Write-Host 'Exiting tool.' -ForegroundColor Yellow; return }

  if ($choice -eq '1') {
    # ---------------- Clear jobs for one printer ----------------
    $p = Select-Printer $printers 'Enter the printer number'
    if (-not $p) { continue }
    $jobs = @($p.Jobs)
    if (-not $jobs.Count) { Write-Host "No jobs in the queue for $($p.Name)." -ForegroundColor Green; continue }
    for ($i = 0; $i -lt $jobs.Count; $i++) {
      $j = $jobs[$i]
      $mark = if ($p.Stuck -contains $j) { '  *STUCK*' } else { '' }
      $when = if ($j.SubmittedTime) { ([datetime]$j.SubmittedTime).ToString('yyyy-MM-dd HH:mm') } else { '?' }
      Write-Host ('  [{0}] Job {1} | {2} | {3} | {4} | submitted {5}{6}' -f ($i + 1), $j.Id, $j.DocumentName, $j.UserName, $j.JobStatus, $when, $mark)
    }
    $sel = Read-Host 'Enter a job number to remove, S for all stuck jobs, A for all jobs on this printer, or 0 to cancel'
    if ($sel -match '^[Aa]$') { $targets = $jobs }
    elseif ($sel -match '^[Ss]$') { $targets = @($p.Stuck) }
    elseif ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $jobs.Count) { $targets = @($jobs[[int]$sel - 1]) }
    elseif (-not $sel -or $sel -eq '0') { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
    else { Write-Host 'Invalid selection.' -ForegroundColor Yellow; continue }
    if (-not $targets.Count) { Write-Host 'No stuck jobs to remove.' -ForegroundColor Green; continue }
    $confirm = Read-Host "Remove $($targets.Count) job(s) from $($p.Name)? (y/N)"
    if ($confirm -notmatch '^[Yy]') { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
    foreach ($j in $targets) {
      try {
        Remove-PrintJob -PrinterName $p.Name -ID $j.Id -ErrorAction Stop
        Write-Host "[OK] Removed job $($j.Id) ($($j.DocumentName))" -ForegroundColor Green
      } catch {
        Write-Host "[FAIL] Job $($j.Id): $($_.Exception.Message)" -ForegroundColor Red
        if (-not $isAdmin) { Write-Host '  Other users'' jobs need admin rights - relaunch MSP Tool elevated.' -ForegroundColor Yellow }
        Write-Host '  If the job stays in "Deleting", use [2] to clear all jobs.' -ForegroundColor Yellow
      }
    }
  }
  elseif ($choice -eq '2') {
    # ---------------- Clear ALL jobs ----------------
    if (-not $isAdmin) { Write-Host 'Clearing all print jobs requires administrator rights. Relaunch MSP Tool elevated.' -ForegroundColor Red; continue }
    Write-Host 'WARNING: this stops the Print Spooler, deletes ALL queued print jobs for ALL printers and users' -ForegroundColor Yellow
    Write-Host "(files in $spoolDir), then starts the spooler again." -ForegroundColor Yellow
    $answer = Read-Host 'Type YES (uppercase) to clear all print jobs (anything else cancels)'
    if ($answer -cne 'YES') { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
    try {
      $stopped = $true
      if ($running) {
        try {
          Stop-Service -Name Spooler -Force -NoWait -ErrorAction Stop
          $stopped = Wait-Spooler 'Stopped'
        } catch { $stopped = $false; Write-Host "[FAIL] Stop Print Spooler: $($_.Exception.Message)" -ForegroundColor Red }
      }
      if (-not $stopped) {
        Write-Host "[FAIL] Print Spooler did not stop within $spoolerTimeoutSec seconds - spool folder NOT cleared." -ForegroundColor Red
      } else {
        Write-Host '[OK] Print Spooler stopped' -ForegroundColor Green
        if (-not (Test-Path -LiteralPath $spoolDir)) {
          Write-Host "[FAIL] Spool folder not found: $spoolDir" -ForegroundColor Red
        } else {
          $removed = 0; $failed = 0
          foreach ($item in @(Get-ChildItem -LiteralPath $spoolDir -Force -ErrorAction SilentlyContinue)) {
            try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop; $removed++ } catch { $failed++ }
          }
          if ($failed) { Write-Host "[FAIL] Spool folder: removed $removed file(s), $failed could not be removed (in use)" -ForegroundColor Red }
          else { Write-Host "[OK] Spool folder emptied ($removed file(s) removed)" -ForegroundColor Green }
        }
      }
    } finally {
      # Only start it again if it was running: a deliberately stopped spooler (e.g. PrintNightmare hardening) stays stopped
      if ($running) {
        try {
          Start-Service -Name Spooler -ErrorAction Stop
          if (Wait-Spooler 'Running') { Write-Host '[OK] Print Spooler started' -ForegroundColor Green }
          else { Write-Host '[FAIL] Print Spooler did not start - check services.msc / System event log' -ForegroundColor Red }
        } catch { Write-Host "[FAIL] Start Print Spooler: $($_.Exception.Message)" -ForegroundColor Red }
      } else {
        Write-Host 'Print Spooler was not running before - left stopped (use [3] to start it if needed).' -ForegroundColor Yellow
      }
    }
  }
  elseif ($choice -eq '3') {
    # ---------------- Restart / start spooler ----------------
    if (-not $isAdmin) { Write-Host 'Restarting the Print Spooler requires administrator rights. Relaunch MSP Tool elevated.' -ForegroundColor Red; continue }
    $verb = if ($running) { 'Restart' } else { 'Start' }
    $confirm = Read-Host "$verb the Print Spooler now? Jobs that are printing may restart (y/N)"
    if ($confirm -notmatch '^[Yy]') { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
    try {
      if ($running) { Restart-Service -Name Spooler -Force -ErrorAction Stop } else { Start-Service -Name Spooler -ErrorAction Stop }
      if (Wait-Spooler 'Running') { Write-Host "[OK] Print Spooler ${verb}ed" -ForegroundColor Green }
      else { Write-Host '[FAIL] Print Spooler is not running afterwards - check the System event log' -ForegroundColor Red }
    } catch { Write-Host "[FAIL] $verb Print Spooler: $($_.Exception.Message)" -ForegroundColor Red }
  }
  elseif ($choice -eq '4') {
    # ---------------- Test page ----------------
    $p = Select-Printer $printers 'Enter the printer number for the test page'
    if (-not $p) { continue }
    $confirm = Read-Host "Print a Windows test page on $($p.Name)? (y/N)"
    if ($confirm -notmatch '^[Yy]') { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
    try {
      $c = Get-CimPrinter $p.Name
      if (-not $c) { throw 'printer not found in Win32_Printer' }
      $r = Invoke-CimMethod -InputObject $c -MethodName PrintTestPage -ErrorAction Stop
      if ($r.ReturnValue -eq 0) { Write-Host "[OK] Test page sent to $($p.Name)" -ForegroundColor Green }
      else { Write-Host "[FAIL] Test page on $($p.Name) returned code $($r.ReturnValue)" -ForegroundColor Red }
    } catch { Write-Host "[FAIL] Test page on $($p.Name): $($_.Exception.Message)" -ForegroundColor Red }
  }
  elseif ($choice -eq '5') {
    # ---------------- Default printer ----------------
    $p = Select-Printer $printers 'Enter the printer number to make default'
    if (-not $p) { continue }
    if ($p.Default) { Write-Host "$($p.Name) is already the default printer." -ForegroundColor Green; continue }
    try {
      $c = Get-CimPrinter $p.Name
      if (-not $c) { throw 'printer not found in Win32_Printer' }
      $r = Invoke-CimMethod -InputObject $c -MethodName SetDefaultPrinter -ErrorAction Stop
      if ($r.ReturnValue -eq 0) { Write-Host "[OK] $($p.Name) is now the default printer" -ForegroundColor Green }
      else { Write-Host "[FAIL] Set default returned code $($r.ReturnValue)" -ForegroundColor Red }
      $legacy = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows' -Name LegacyDefaultPrinterMode -ErrorAction SilentlyContinue).LegacyDefaultPrinterMode
      if ($legacy -ne 1) { Write-Host 'NOTE: "Let Windows manage my default printer" may be on - Windows can change the default again. Turn it off in Settings > Bluetooth & devices > Printers & scanners.' -ForegroundColor Yellow }
      if ($isSystem) { Write-Host 'NOTE: running as SYSTEM - this set the default for the SYSTEM account, not the logged-on user.' -ForegroundColor Yellow }
    } catch { Write-Host "[FAIL] Set default printer: $($_.Exception.Message)" -ForegroundColor Red }
  }
  else { Write-Host 'Invalid selection.' -ForegroundColor Yellow }
}
