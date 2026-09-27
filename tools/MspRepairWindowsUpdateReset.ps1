# Reset Windows Update components: stop the update services, rename the update cache folders
# (never delete), then start the services again - even if a step in the middle fails.
# Services stopped for the reset (stopped in this order, started again in reverse order)
$wuServices = @('wuauserv', 'bits', 'cryptsvc', 'msiserver')
# Seconds to wait for each service to stop or start
$serviceTimeoutSec = 60
# Update cache folders that get renamed to <name>.old-<stamp> so Windows rebuilds them
$wuFolders = @("$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2")
# Services that must be stopped before each folder can be renamed safely
$folderLocks = @{ 'SoftwareDistribution' = @('wuauserv', 'bits'); 'catroot2' = @('cryptsvc') }

function Get-FolderSizeMB {
  param($Path)
  $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
  if (-not $sum) { $sum = 0 }
  [math]::Round($sum / 1MB, 1)
}
function Wait-ServiceStatus {
  param($Name, $Status)
  for ($i = 0; $i -le $serviceTimeoutSec; $i++) {
    $s = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($s -and "$($s.Status)" -eq $Status) { return $true }
    if ($i -lt $serviceTimeoutSec) { Start-Sleep -Seconds 1 }
  }
  return $false
}
$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
  param($Step, $Result, $Detail)
  $results.Add([pscustomobject]@{ Step = $Step; Result = $Result; Detail = $Detail })
  $color = switch ($Result) { 'OK' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
  $text = if ($Detail) { "[$Result] $Step - $Detail" } else { "[$Result] $Step" }
  Write-Host $text -ForegroundColor $color
}

# ---------------- Current state ----------------
Write-Host '--- Windows Update services ---' -ForegroundColor Cyan
$original = @{}
foreach ($n in $wuServices) {
  $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
  if ($svc) {
    $original[$n] = [pscustomobject]@{ Status = "$($svc.Status)"; StartType = "$($svc.StartType)" }
    Write-Host ('  {0,-10} {1,-8} startup: {2,-9} {3}' -f $n, $svc.Status, $svc.StartType, $svc.DisplayName)
  } else {
    Write-Host ('  {0,-10} NOT FOUND' -f $n) -ForegroundColor Yellow
  }
}
Write-Host ''
Write-Host '--- Update cache folders ---' -ForegroundColor Cyan
foreach ($f in $wuFolders) {
  if (Test-Path -LiteralPath $f) { Write-Host ('  {0}  {1} MB' -f $f, (Get-FolderSizeMB $f)) }
  else { Write-Host "  $f  (not found - Windows creates it again)" -ForegroundColor Yellow }
  $leaf = Split-Path $f -Leaf
  foreach ($o in @(Get-ChildItem -LiteralPath (Split-Path $f -Parent) -Directory -Filter "$leaf.old*" -Force -ErrorAction SilentlyContinue)) {
    Write-Host "    previous reset folder: $($o.FullName) ($(Get-FolderSizeMB $o.FullName) MB) - can be deleted if updates work" -ForegroundColor Yellow
  }
}
foreach ($n in $original.Keys) {
  if ($original[$n].StartType -eq 'Disabled') { Write-Host "NOTE: $n is Disabled (possibly by policy or CWA patch settings) - it will be left stopped." -ForegroundColor Yellow }
}

# ---------------- Explain and confirm ----------------
Write-Host ''
Write-Host 'This will:'
Write-Host "  1. Stop services: $($wuServices -join ', ') (waits up to $serviceTimeoutSec s each)"
Write-Host '  2. Rename SoftwareDistribution and catroot2 to <name>.old-<date-time> (nothing is deleted)'
Write-Host '  3. Start the services again (this always runs, even if a step fails)'
Write-Host 'Windows rebuilds both folders. Installed updates are NOT removed, but the update history list in'
Write-Host 'Settings is cleared and pending downloads start again. Do not run while updates are installing.'
$answer = Read-Host 'Type YES (uppercase) to reset Windows Update components (anything else cancels)'
if ($answer -cne 'YES') { Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow; return }

# ---------------- Reset ----------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stoppedOk = @{}
$renamed = @()
# Stop-Service -Force also stops running dependents (e.g. cryptsvc -> AppIDSvc/applockerfltr for AppLocker);
# remember them so they are started again afterwards
$dependentsToRestart = [System.Collections.Generic.List[string]]::new()
foreach ($n in $wuServices) {
  if (-not $original.ContainsKey($n)) { continue }
  foreach ($d in @((Get-Service -Name $n -ErrorAction SilentlyContinue).DependentServices | Where-Object { $_ -and "$($_.Status)" -eq 'Running' })) {
    if ($wuServices -notcontains $d.Name -and -not $dependentsToRestart.Contains($d.Name)) { $dependentsToRestart.Add($d.Name) }
  }
}
if ($dependentsToRestart.Count) { Write-Host "Dependent services that will stop too and be restarted afterwards: $($dependentsToRestart -join ', ')" -ForegroundColor Yellow }
try {
  Write-Host ''
  Write-Host '--- Stopping services ---' -ForegroundColor Cyan
  foreach ($n in $wuServices) {
    if (-not $original.ContainsKey($n)) { Add-Result "Stop $n" 'SKIP' 'service not found'; continue }
    try {
      $s = Get-Service -Name $n -ErrorAction Stop
      if ("$($s.Status)" -ne 'Stopped') { Stop-Service -Name $n -Force -NoWait -ErrorAction Stop }
      if (Wait-ServiceStatus $n 'Stopped') { $stoppedOk[$n] = $true; Add-Result "Stop $n" 'OK' '' }
      else {
        $stoppedOk[$n] = $false
        $now = Get-Service -Name $n -ErrorAction SilentlyContinue
        Add-Result "Stop $n" 'FAIL' "did not stop within $serviceTimeoutSec seconds (status: $($now.Status))"
      }
    } catch {
      $stoppedOk[$n] = $false
      Add-Result "Stop $n" 'FAIL' $_.Exception.Message
    }
  }

  Write-Host ''
  Write-Host '--- Renaming update cache folders ---' -ForegroundColor Cyan
  foreach ($f in $wuFolders) {
    $leaf = Split-Path $f -Leaf
    $newName = "$leaf.old-$stamp"
    if (-not (Test-Path -LiteralPath $f)) { Add-Result "Rename $leaf" 'SKIP' 'folder not found'; continue }
    $blockers = @($folderLocks[$leaf] | Where-Object { $_ -and $stoppedOk.ContainsKey($_) -and -not $stoppedOk[$_] })
    if ($blockers.Count) { Add-Result "Rename $leaf" 'FAIL' "skipped - $($blockers -join ', ') did not stop"; continue }
    try {
      Rename-Item -LiteralPath $f -NewName $newName -ErrorAction Stop
      $renamed += (Join-Path (Split-Path $f -Parent) $newName)
      Add-Result "Rename $leaf" 'OK' "renamed to $newName"
    } catch {
      Add-Result "Rename $leaf" 'FAIL' "$($_.Exception.Message) (files in use - restart the computer and run this again)"
    }
  }
} finally {
  Write-Host ''
  Write-Host '--- Starting services ---' -ForegroundColor Cyan
  $reverse = @($wuServices)
  [array]::Reverse($reverse)
  foreach ($n in $reverse) {
    if (-not $original.ContainsKey($n)) { continue }
    if ($original[$n].StartType -eq 'Disabled') { Add-Result "Start $n" 'WARN' 'startup type is Disabled - left stopped (check policy / CWA patch settings)'; continue }
    try {
      Start-Service -Name $n -ErrorAction Stop
      if (Wait-ServiceStatus $n 'Running') { Add-Result "Start $n" 'OK' '' }
      else { Add-Result "Start $n" 'FAIL' "not running after $serviceTimeoutSec seconds" }
    } catch {
      Add-Result "Start $n" 'FAIL' $_.Exception.Message
    }
  }
  foreach ($d in $dependentsToRestart) {
    try {
      Start-Service -Name $d -ErrorAction Stop
      if (Wait-ServiceStatus $d 'Running') { Add-Result "Start $d (dependent)" 'OK' '' }
      else { Add-Result "Start $d (dependent)" 'FAIL' "not running after $serviceTimeoutSec seconds" }
    } catch {
      Add-Result "Start $d (dependent)" 'FAIL' $_.Exception.Message
    }
  }
}

# ---------------- Optional follow-up ----------------
Write-Host ''
Write-Host 'Optional: ask Windows Update to scan now (UsoClient StartScan). The old wuauclt /detectnow is deprecated.'
$scan = Read-Host 'Start a Windows Update scan now? (y/N)'
if ($scan -match '^[Yy]') {
  if (Get-Command UsoClient -ErrorAction SilentlyContinue) {
    try { UsoClient StartScan; Add-Result 'UsoClient StartScan' 'OK' 'scan requested (runs in the background)' }
    catch { Add-Result 'UsoClient StartScan' 'FAIL' $_.Exception.Message }
  } else {
    Add-Result 'UsoClient StartScan' 'SKIP' 'UsoClient not available on this Windows version - use Settings > Windows Update'
  }
}

# ---------------- Summary ----------------
Write-Host ''
Write-Host '--- Summary ---' -ForegroundColor Cyan
$results | Format-Table -AutoSize -Wrap | Out-String | Write-Host
$failCount = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
if ($failCount) { Write-Host "$failCount step(s) FAILED - see above." -ForegroundColor Red }
else { Write-Host 'Windows Update components reset.' -ForegroundColor Green }
Write-Host 'RESTART RECOMMENDED: restart the computer, then check for updates (Settings > Windows Update) or push patching from CWA (Tiles > Patching).' -ForegroundColor Yellow
if ($renamed.Count) {
  Write-Host 'Once updates install successfully, these old folders can be deleted to free space:'
  foreach ($r in $renamed) { Write-Host "  $r" }
}
