# --- Settings (edit as needed) ---
$minHealthPercent = 60      # full-charge capacity below this % of design capacity is flagged (battery worn)
$reportDir = Join-Path $env:USERPROFILE 'Desktop\MSP-Reports'

$batteries = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
if (-not $batteries.Count) {
  Write-Host 'No battery detected on this machine (desktop, server or VM) - nothing to report.' -ForegroundColor Yellow
  return
}

$statusNames = @{ 1 = 'Discharging'; 2 = 'On AC power'; 3 = 'Fully charged'; 4 = 'Low'; 5 = 'Critical'; 6 = 'Charging'; 7 = 'Charging (high)'; 8 = 'Charging (low)'; 9 = 'Charging (critical)'; 10 = 'Undefined'; 11 = 'Partially charged' }
$hasDesktop = (Get-Process -Id $PID).SessionId -ne 0 -and [Environment]::UserInteractive

# ---------------- powercfg battery report (also used as a fallback data source) ----------------
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$reportPath = Join-Path $reportDir "battery-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
$reportOk = $false
$pcOut = @()
$started = (Get-Date).AddSeconds(-2)
try {
  $pcOut = @(& { $ErrorActionPreference = 'Continue'; powercfg /batteryreport /output $reportPath 2>&1 } | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
  $reportOk = (Test-Path -LiteralPath $reportPath) -and (Get-Item -LiteralPath $reportPath).LastWriteTime -ge $started
} catch { $pcOut += $_.Exception.Message }
$fromReport = @()
if ($reportOk) {
  $html = Get-Content -LiteralPath $reportPath -Raw -ErrorAction SilentlyContinue
  $num = { param($s) $d = "$s" -replace '[^\d]', ''; if ($d) { [int64]$d } else { $null } }
  $designs = [regex]::Matches("$html", 'DESIGN CAPACITY</span></td><td>([^<]*)')
  $fulls = [regex]::Matches("$html", 'FULL CHARGE CAPACITY</span></td><td>([^<]*)')
  $cycles = [regex]::Matches("$html", 'CYCLE COUNT</span></td><td>([^<]*)')
  for ($i = 0; $i -lt $designs.Count; $i++) {
    $fromReport += [pscustomobject]@{
      Design = & $num $designs[$i].Groups[1].Value
      Full   = $(if ($i -lt $fulls.Count) { & $num $fulls[$i].Groups[1].Value })
      Cycles = $(if ($i -lt $cycles.Count) { & $num $cycles[$i].Groups[1].Value })
    }
  }
}

# ---------------- WMI (root\wmi) battery data - some firmware returns 'Generic failure' ----------------
$wmiClass = { param($name) try { @(Get-CimInstance -Namespace 'root\wmi' -ClassName $name -ErrorAction Stop) } catch { @() } }
$static = @(& $wmiClass 'BatteryStaticData')
$fullCap = @(& $wmiClass 'BatteryFullChargedCapacity')
$cycleCnt = @(& $wmiClass 'BatteryCycleCount')

$flagged = $false
for ($i = 0; $i -lt $batteries.Count; $i++) {
  $b = $batteries[$i]
  $rep = if ($i -lt $fromReport.Count) { $fromReport[$i] } else { $null }
  $design = if ($i -lt $static.Count -and $static[$i].DesignedCapacity) { [int64]$static[$i].DesignedCapacity } elseif ($rep) { $rep.Design } else { $null }
  $full = if ($i -lt $fullCap.Count -and $fullCap[$i].FullChargedCapacity) { [int64]$fullCap[$i].FullChargedCapacity } elseif ($rep) { $rep.Full } else { $null }
  # A cycle count of 0 usually means "not reported by the firmware"
  $cycles = if ($i -lt $cycleCnt.Count -and $cycleCnt[$i].CycleCount -gt 0) { $cycleCnt[$i].CycleCount } elseif ($rep -and $rep.Cycles) { $rep.Cycles } else { $null }

  Write-Host ''
  Write-Host "--- Battery $($i + 1): $($b.Name) ---" -ForegroundColor Cyan
  $status = if ($statusNames.ContainsKey([int]$b.BatteryStatus)) { $statusNames[[int]$b.BatteryStatus] } else { "code $($b.BatteryStatus)" }
  Write-Host "Current charge     : $($b.EstimatedChargeRemaining)% ($status)"
  # 71582788 minutes (~136 years) is the 'unknown / on AC power' sentinel
  $rt = $b.EstimatedRunTime
  $rtText = if ($null -eq $rt -or $rt -ge 71582788 -or $rt -le 0) { 'n/a (on AC power or still calculating)' } else { '{0}h {1:00}m' -f [math]::Floor($rt / 60), ($rt % 60) }
  Write-Host "Estimated runtime  : $rtText"
  Write-Host ("Design capacity    : {0}" -f $(if ($design) { '{0:N0} mWh' -f $design } else { 'not reported' }))
  Write-Host ("Full-charge cap.   : {0}" -f $(if ($full) { '{0:N0} mWh' -f $full } else { 'not reported' }))
  Write-Host ("Cycle count        : {0}" -f $(if ($cycles) { $cycles } else { 'not reported by firmware' }))
  if ($design -and $full) {
    $health = [math]::Round(100 * $full / $design, 1)
    if ($health -lt $minHealthPercent) {
      Write-Host "Battery health     : $health% - WORN (below $minHealthPercent%). Battery holds much less charge than new - recommend replacement." -ForegroundColor Red
      $flagged = $true
    } else {
      Write-Host "Battery health     : $health% of design capacity" -ForegroundColor Green
    }
  } else {
    Write-Host 'Battery health     : could not calculate (capacity not reported) - see the HTML report.' -ForegroundColor Yellow
  }
}

Write-Host ''
if ($reportOk) {
  Write-Host "Battery report saved: $reportPath"
  if ($hasDesktop) {
    $ans = Read-Host 'Open the battery report now? (y/N)'
    if ($ans -match '^[Yy]') { Invoke-Item -Path $reportPath; Write-Host 'Battery report opened.' }
  } else {
    Write-Host 'No interactive desktop - open the saved report manually.' -ForegroundColor Yellow
  }
} else {
  Write-Host "powercfg could not create the battery report. powercfg said: $($pcOut -join ' ')" -ForegroundColor Red
}
if ($flagged) { Write-Host 'ACTION: battery health is low - quote a replacement battery (check warranty with the serial number).' -ForegroundColor Yellow }
