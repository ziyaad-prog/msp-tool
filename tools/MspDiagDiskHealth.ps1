# --- Thresholds (edit as needed) ---
$maxWearPercent = 80        # SSD wear (percentage of rated life used) above this is flagged
$maxTemperatureC = 60       # current temperature above this is flagged

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$issues = [System.Collections.Generic.List[string]]::new()

try {
  $disks = @(Get-PhysicalDisk -ErrorAction Stop | Sort-Object { [int]$_.DeviceId })
} catch {
  Write-Host "Could not read physical disks: $($_.Exception.Message)" -ForegroundColor Red
  return
}
if (-not $disks.Count) { Write-Host 'No physical disks found.' -ForegroundColor Yellow; return }

$disks | Select-Object FriendlyName, MediaType, @{N='SizeGB';E={[math]::Round($_.Size/1GB,2)}}, HealthStatus, OperationalStatus | Format-Table -AutoSize | Out-String | Write-Host

if (-not $isAdmin) { Write-Host 'Not running as admin - SMART/reliability counters and failure prediction need administrator rights. Showing basic health only.' -ForegroundColor Yellow }

# ---------------- Reliability counters (SMART-style) per disk ----------------
Write-Host '--- Reliability counters ---' -ForegroundColor Cyan
foreach ($d in $disks) {
  $label = "Disk $($d.DeviceId): $($d.FriendlyName) ($($d.BusType), $($d.MediaType))"
  Write-Host ''
  Write-Host $label
  if ("$($d.HealthStatus)" -ne 'Healthy') {
    Write-Host "  HEALTH STATUS: $($d.HealthStatus) (operational: $(($d.OperationalStatus) -join ', ')) - back up data and plan replacement" -ForegroundColor Red
    $issues.Add("Disk $($d.DeviceId) $($d.FriendlyName): HealthStatus $($d.HealthStatus)")
  }
  $c = $null
  try { $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch {
    $why = if (-not $isAdmin) { 'needs admin' } else { "not supported by this disk/controller ($($_.Exception.Message))" }
    Write-Host "  Counters: not available - $why" -ForegroundColor Yellow
    continue
  }
  $fields = 'Temperature', 'TemperatureMax', 'Wear', 'PowerOnHours', 'ReadErrorsTotal', 'ReadErrorsUncorrected', 'WriteErrorsTotal', 'WriteErrorsUncorrected', 'StartStopCycleCount'
  if (-not $c -or -not @($fields | Where-Object { $null -ne $c.$_ }).Count) {
    Write-Host '  Counters: not reported by this disk (common on USB enclosures, RAID controllers and some NVMe drivers)' -ForegroundColor Yellow
    continue
  }
  $v = { param($x, $suffix) if ($null -eq $x) { 'n/a' } else { "$x$suffix" } }
  # Temperature 0 means "not reported" on many drives
  $temp = if ($c.Temperature) { $c.Temperature } else { $null }
  $tempMax = if ($c.TemperatureMax) { $c.TemperatureMax } else { $null }
  Write-Host ("  Temperature    : {0} (max {1})" -f (& $v $temp ' C'), (& $v $tempMax ' C'))
  Write-Host ("  Wear           : {0}" -f (& $v $c.Wear '%'))
  Write-Host ("  Power-on hours : {0}{1}" -f (& $v $c.PowerOnHours ''), $(if ($c.PowerOnHours) { " (~$([math]::Round($c.PowerOnHours / 8760, 1)) years)" }))
  Write-Host ("  Read errors    : {0} total, {1} uncorrected" -f (& $v $c.ReadErrorsTotal ''), (& $v $c.ReadErrorsUncorrected ''))
  Write-Host ("  Write errors   : {0} total, {1} uncorrected" -f (& $v $c.WriteErrorsTotal ''), (& $v $c.WriteErrorsUncorrected ''))
  Write-Host ("  Start/stop     : {0}" -f (& $v $c.StartStopCycleCount ''))
  if ($null -ne $c.Wear -and $c.Wear -gt $maxWearPercent) {
    Write-Host "  WEAR HIGH: $($c.Wear)% of rated life used (> $maxWearPercent%) - plan replacement" -ForegroundColor Red
    $issues.Add("Disk $($d.DeviceId) $($d.FriendlyName): wear $($c.Wear)%")
  }
  if ($temp -and $temp -gt $maxTemperatureC) {
    Write-Host "  TEMPERATURE HIGH: $temp C (> $maxTemperatureC C) - check airflow/fans" -ForegroundColor Red
    $issues.Add("Disk $($d.DeviceId) $($d.FriendlyName): temperature $temp C")
  }
  $unc = [int64]$c.ReadErrorsUncorrected + [int64]$c.WriteErrorsUncorrected
  if ($unc -gt 0) {
    Write-Host "  UNCORRECTED ERRORS: $unc - data at risk, back up and plan replacement" -ForegroundColor Red
    $issues.Add("Disk $($d.DeviceId) $($d.FriendlyName): $unc uncorrected read/write errors")
  }
}

# ---------------- Predictive failure (SMART status via storage driver) ----------------
Write-Host ''
Write-Host '--- SMART predictive failure ---' -ForegroundColor Cyan
try {
  $fps = @(Get-CimInstance -Namespace 'root\wmi' -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop)
  if (-not $fps.Count) {
    Write-Host 'No SMART prediction data exposed by the storage drivers (normal for many NVMe drives - rely on the counters above).'
  }
  foreach ($f in $fps) {
    $name = ($f.InstanceName -replace '_0$', '')
    if ($f.PredictFailure) {
      Write-Host "  [FAIL] $name - SMART predicts failure (reason code $($f.Reason)). Back up now and replace the disk." -ForegroundColor Red
      $issues.Add("SMART predicts failure: $name")
    } else {
      Write-Host "  [OK]   $name" -ForegroundColor Green
    }
  }
} catch {
  $msg = $_.Exception.Message
  if ($msg -match 'denied' -or -not $isAdmin) { Write-Host '  Not available - needs admin.' -ForegroundColor Yellow }
  elseif ($msg -match 'not supported|Invalid class|Not found') { Write-Host '  Not supported by the storage drivers on this machine.' -ForegroundColor Yellow }
  else { Write-Host "  Could not read SMART prediction: $msg" -ForegroundColor Yellow }
}

# ---------------- Summary ----------------
Write-Host ''
if ($issues.Count) {
  Write-Host "DISK PROBLEMS FOUND ($($issues.Count)):" -ForegroundColor Red
  $issues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  Write-Host 'Confirm a current backup exists before doing anything else on this machine.' -ForegroundColor Yellow
} elseif ($isAdmin) {
  Write-Host 'No disk problems found.' -ForegroundColor Green
} else {
  Write-Host 'No problems in basic health status. Run elevated for full SMART/reliability checks.' -ForegroundColor Green
}
