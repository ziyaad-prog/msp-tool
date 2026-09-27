# ---------------- Settings ----------------
$reportDir = Join-Path $env:USERPROFILE 'Desktop\MSP-Reports'
$logDir = if ($ScriptRoot) { Join-Path $ScriptRoot 'logs' } else { $null }
# Default time window (hours) offered at the prompt; 0 = include all files
$defaultHours = 24
# Files are copied to a staging folder here first, so in-use log files do not break the zip
$stagingRoot = $env:TEMP
# ---- end of settings ----
# Opening folders needs a visible desktop (not session 0 / RMM / service context)
$hasDesktop = (Get-Process -Id $PID).SessionId -ne 0 -and [Environment]::UserInteractive

# Builds ticket-<COMPUTER>-<stamp>.zip in the reports folder. Returns the zip path, or $null if nothing to bundle.
function New-TicketBundle {
  param([int]$Hours)
  $since = if ($Hours -gt 0) { (Get-Date).AddHours(-$Hours) } else { [datetime]::MinValue }
  $sources = @()
  if (Test-Path -LiteralPath $reportDir) { $sources += [pscustomobject]@{ Root = $reportDir; Folder = 'reports' } }
  if ($logDir -and (Test-Path -LiteralPath $logDir)) { $sources += [pscustomobject]@{ Root = $logDir; Folder = 'logs' } }

  $picked = @()
  foreach ($s in $sources) {
    $rootFull = (Get-Item -LiteralPath $s.Root).FullName.TrimEnd('\')
    foreach ($f in @(Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force -ErrorAction SilentlyContinue)) {
      if ($f.Name -like 'ticket-*.zip') { continue }   # never bundle earlier bundles
      if ($f.LastWriteTime -lt $since) { continue }
      $picked += [pscustomobject]@{ File = $f; Folder = $s.Folder; Rel = $f.FullName.Substring($rootFull.Length + 1) }
    }
  }
  $window = if ($Hours -gt 0) { "last $Hours hour(s)" } else { 'all files' }
  if (-not $picked.Count) {
    Write-Host "No reports or logs found ($window) - nothing to bundle." -ForegroundColor Yellow
    Write-Host "Looked in: $reportDir$(if ($logDir) { " and $logDir" })"
    return $null
  }

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $stage = Join-Path $stagingRoot "msp-ticket-$stamp-$PID"
  $zip = Join-Path $reportDir "ticket-$env:COMPUTERNAME-$stamp.zip"
  $copied = @(); $skipped = @()
  try {
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($p in $picked) {
      $dest = Join-Path (Join-Path $stage $p.Folder) $p.Rel
      try {
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        # Share ReadWrite so files still open for writing (e.g. the current MSP Tool log) can be copied
        $in = [System.IO.File]::Open($p.File.FullName, 'Open', 'Read', 'ReadWrite, Delete')
        try {
          $out = [System.IO.File]::Create($dest)
          try { $in.CopyTo($out) } finally { $out.Dispose() }
        } finally { $in.Dispose() }
        $copied += $p
      } catch {
        $skipped += $p
        $err = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        Write-Host "  [WARN] Skipped unreadable file $($p.Folder)\$($p.Rel): $err" -ForegroundColor Yellow
      }
    }
    if (-not $copied.Count) { Write-Host 'None of the files could be read - no bundle created.' -ForegroundColor Red; return $null }

    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add('MSP Tool ticket bundle')
    $summary.Add("Computer : $env:COMPUTERNAME")
    $summary.Add("User     : $env:USERDOMAIN\$env:USERNAME")
    $summary.Add("Created  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
    $summary.Add("Window   : $window")
    $summary.Add('')
    $summary.Add("Files ($($copied.Count)):")
    foreach ($c in $copied) { $summary.Add(('  {0}  {1,10:N1} KB  {2}\{3}' -f $c.File.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), ($c.File.Length / 1KB), $c.Folder, $c.Rel)) }
    if ($skipped.Count) {
      $summary.Add('')
      $summary.Add("Skipped - could not be read ($($skipped.Count)):")
      foreach ($c in $skipped) { $summary.Add("  $($c.Folder)\$($c.Rel)") }
    }
    Set-Content -Path (Join-Path $stage 'summary.txt') -Value $summary -Encoding UTF8

    if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
    # -LiteralPath so file names containing [ ] are not treated as wildcards
    Compress-Archive -LiteralPath @(Get-ChildItem -LiteralPath $stage | ForEach-Object { $_.FullName }) -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop
  } catch {
    Write-Host "[FAIL] Could not create the ticket bundle: $($_.Exception.Message)" -ForegroundColor Red
    # Remove a partial zip created by this run
    if ($zip -and (Test-Path -LiteralPath $zip)) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    return $null
  } finally {
    # Staging folder was created above by this tool - remove it
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
  }

  $nReports = @($copied | Where-Object { $_.Folder -eq 'reports' }).Count
  $nLogs = @($copied | Where-Object { $_.Folder -eq 'logs' }).Count
  $size = (Get-Item -LiteralPath $zip).Length
  Write-Host ''
  Write-Host "[OK] Ticket bundle created: $zip" -ForegroundColor Green
  Write-Host ('  Size: {0:N1} KB. Contains {1} report file(s), {2} log file(s) and summary.txt ({3}){4}.' -f ($size / 1KB), $nReports, $nLogs, $window, $(if ($skipped.Count) { "; $($skipped.Count) unreadable file(s) skipped" } else { '' }))
  Write-Host '  Attach this zip to the ConnectWise ticket.'
  return $zip
}

Write-Host 'Ticket Bundle: zips MSP reports and MSP Tool logs into one file to attach to a ticket.'
while ($true) {
  $answer = Read-Host "Include files from the last how many hours? (Enter = $defaultHours, 0 = all files)"
  if (-not $answer) { $hours = $defaultHours; break }
  if ($answer -match '^\d{1,6}$' -and [int]$answer -le 87600) { $hours = [int]$answer; break }
  Write-Host 'Invalid number - enter hours as a whole number (e.g. 24), or 0 for all files.' -ForegroundColor Yellow
}
$zipPath = New-TicketBundle -Hours $hours
if ($zipPath -and $hasDesktop) {
  $open = Read-Host 'Open the MSP-Reports folder with the zip selected? (y/N)'
  if ($open -match '^[Yy]') { Start-Process -FilePath explorer.exe -ArgumentList "/select,`"$zipPath`""; Write-Host 'Opened.' -ForegroundColor Green }
}
