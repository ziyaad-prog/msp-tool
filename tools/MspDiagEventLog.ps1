$reportDir = Join-Path $env:USERPROFILE 'Desktop\MSP-Reports'
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$since = (Get-Date).AddHours(-24)
foreach ($log in @('System','Application')) {
  $events = Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 1,2; StartTime = $since } -ErrorAction SilentlyContinue
  $out = Join-Path $reportDir "events-$log-$stamp.csv"
  if ($events) {
    $events | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message | Export-Csv -Path $out -NoTypeInformation
    Write-Host "Exported $($events.Count) $log events to $out"
  } else {
    Write-Host "No critical $log events in last 24 hours"
  }
}

# --- Reliability Monitor (perfmon /rel) ---
# Its "Save reliability history" option is GUI-only, so the saved copy is built from the same
# data (Win32_ReliabilityRecords / Win32_ReliabilityStabilityMetrics) that Reliability Monitor reads.
Write-Host ''
Write-Host '--- Reliability Monitor (last 30 days) ---'
$relSince = (Get-Date).AddDays(-30)
$failureSources = @('Application Error', 'Application Hang', 'Windows Error Reporting', 'Microsoft-Windows-WER-SystemErrorReporting', 'EventLog', 'Microsoft-Windows-Kernel-Power')
try {
  $records = @(Get-CimInstance Win32_ReliabilityRecords -ErrorAction Stop | Where-Object { $_.TimeGenerated -ge $relSince } | Sort-Object TimeGenerated -Descending | ForEach-Object {
    $category = if ($failureSources -contains $_.SourceName) { 'Failure' }
      elseif (($_.SourceName -eq 'Microsoft-Windows-WindowsUpdateClient' -and $_.EventIdentifier -eq 20) -or ($_.SourceName -eq 'MsiInstaller' -and $_.EventIdentifier -eq 11708)) { 'Failed install' }
      else { 'Information' }
    [pscustomobject]@{ Time = $_.TimeGenerated; Category = $category; Source = $_.SourceName; EventId = $_.EventIdentifier; Product = $_.ProductName; Message = $_.Message }
  })
} catch {
  Write-Host "Could not read reliability records: $($_.Exception.Message)" -ForegroundColor Red
  $records = @()
}
try {
  $metrics = @(Get-CimInstance Win32_ReliabilityStabilityMetrics -ErrorAction Stop | Where-Object { $_.TimeGenerated -ge $relSince } | Sort-Object TimeGenerated -Descending)
} catch { $metrics = @() }

$failures = @($records | Where-Object Category -eq 'Failure')
$failedInstalls = @($records | Where-Object Category -eq 'Failed install')
if ($metrics.Count) {
  $current = [math]::Round($metrics[0].SystemStabilityIndex, 2)
  $lowest = $metrics | Sort-Object SystemStabilityIndex | Select-Object -First 1
  Write-Host ("Stability index : {0} / 10 now, lowest {1} on {2}" -f $current, [math]::Round($lowest.SystemStabilityIndex, 2), $lowest.TimeGenerated.ToString('yyyy-MM-dd'))
} else {
  Write-Host 'Stability index : not available (the Reliability Analysis task may be disabled on this machine)' -ForegroundColor Yellow
}
Write-Host ("Failures        : {0} ({1} app crashes, {2} app hangs, {3} Windows/shutdown)" -f $failures.Count, @($failures | Where-Object Source -eq 'Application Error').Count, @($failures | Where-Object Source -eq 'Application Hang').Count, @($failures | Where-Object { $_.Source -notin 'Application Error', 'Application Hang' }).Count)
Write-Host ("Failed installs : {0}" -f $failedInstalls.Count)
Write-Host ("Total records   : {0}" -f $records.Count)
if ($failures.Count) {
  Write-Host ''
  Write-Host 'Top failing applications:'
  $failures | Group-Object Product | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { Write-Host ("  {0,3}x  {1}" -f $_.Count, $(if ($_.Name) { $_.Name } else { '(unknown)' })) }
}

if ($records.Count -or $metrics.Count) {
  $csvOut = Join-Path $reportDir "reliability-$stamp.csv"
  $records | Select-Object @{N = 'Time'; E = { $_.Time.ToString('yyyy-MM-dd HH:mm:ss') } }, Category, Source, EventId, Product, Message | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8

  $short = { param($t) if ("$t".Length -gt 400) { "$t".Substring(0, 400) + '...' } else { "$t" } }
  $style = '<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{font-size:22px}h2{font-size:17px;margin-top:28px}table{border-collapse:collapse;width:100%;font-size:12px}th,td{border:1px solid #ccc;padding:4px 6px;text-align:left;vertical-align:top;word-break:break-word}td:first-child{white-space:nowrap}th{background:#eee}</style>'
  $summary = @(
    [pscustomobject]@{ Item = 'Computer'; Value = $env:COMPUTERNAME }
    [pscustomobject]@{ Item = 'Generated'; Value = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    [pscustomobject]@{ Item = 'Period'; Value = "$($relSince.ToString('yyyy-MM-dd')) to $((Get-Date).ToString('yyyy-MM-dd'))" }
    [pscustomobject]@{ Item = 'Current stability index'; Value = $(if ($metrics.Count) { "$([math]::Round($metrics[0].SystemStabilityIndex, 2)) / 10" } else { 'not available' }) }
    [pscustomobject]@{ Item = 'Failures'; Value = $failures.Count }
    [pscustomobject]@{ Item = 'Failed installs'; Value = $failedInstalls.Count }
    [pscustomobject]@{ Item = 'Total records'; Value = $records.Count })
  $daily = $metrics | Group-Object { $_.TimeGenerated.ToString('yyyy-MM-dd') } | ForEach-Object {
    [pscustomobject]@{ Date = $_.Name; 'Lowest stability index' = [math]::Round(($_.Group | Measure-Object SystemStabilityIndex -Minimum).Minimum, 2) }
  }
  $asRows = { param($list) $list | Select-Object @{N = 'Time'; E = { $_.Time.ToString('yyyy-MM-dd HH:mm') } }, Category, Source, EventId, Product, @{N = 'Message'; E = { & $short $_.Message } } }
  $body = @(
    "<h1>Reliability report - $env:COMPUTERNAME</h1>"
    ($summary | ConvertTo-Html -Fragment)
    '<h2>Failures</h2>'
    $(if ($failures.Count) { & $asRows $failures | ConvertTo-Html -Fragment } else { '<p>No failures recorded.</p>' })
    '<h2>Failed installs</h2>'
    $(if ($failedInstalls.Count) { & $asRows $failedInstalls | ConvertTo-Html -Fragment } else { '<p>No failed installs recorded.</p>' })
    '<h2>Daily stability index</h2>'
    $(if ($daily) { $daily | ConvertTo-Html -Fragment } else { '<p>Not available.</p>' })
    '<h2>All reliability records</h2>'
    $(if ($records.Count) { & $asRows $records | ConvertTo-Html -Fragment } else { '<p>No records.</p>' })
  )
  $htmlOut = Join-Path $reportDir "reliability-$stamp.html"
  ConvertTo-Html -Title "Reliability report - $env:COMPUTERNAME" -Head $style -Body ($body -join "`n") | Out-File -FilePath $htmlOut -Encoding UTF8
  Write-Host ''
  Write-Host "Reliability report saved: $htmlOut"
  Write-Host "Reliability records (CSV) saved: $csvOut"
} else {
  Write-Host 'No reliability data found - nothing saved.' -ForegroundColor Yellow
}

# Only open the GUI when there's a visible desktop (not in session 0 / RMM / service context)
if ((Get-Process -Id $PID).SessionId -ne 0 -and [Environment]::UserInteractive) {
  Start-Process -FilePath "$env:SystemRoot\System32\perfmon.exe" -ArgumentList '/rel'
  Write-Host 'Reliability Monitor opened (perfmon /rel).'
} else {
  Write-Host 'No interactive desktop - skipped opening Reliability Monitor. Open the saved HTML report instead.' -ForegroundColor Yellow
}
