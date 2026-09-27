$reportDir = Join-Path $env:USERPROFILE 'Desktop\MSP-Reports'
$logDir = if ($ScriptRoot) { Join-Path $ScriptRoot 'logs' } else { $null }
# Opening files/folders needs a visible desktop (not session 0 / RMM / service context)
$hasDesktop = (Get-Process -Id $PID).SessionId -ne 0 -and [Environment]::UserInteractive

# Ticket bundle settings (same logic as the Ticket Bundle tool, duplicated so this tool stays self-contained)
$defaultBundleHours = 24
# Files are copied to a staging folder here first, so in-use log files do not break the zip
$stagingRoot = $env:TEMP
# Default age (days) offered when deleting old reports
$defaultDeleteDays = 30
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

# Lists files in ONE folder (not subfolders) older than N days, then deletes them only after a typed YES
function Remove-OldFiles {
  param([string]$Folder, [int]$Days, [string]$Label)
  $cutoff = (Get-Date).AddDays(-$Days)
  $old = @(Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff } | Sort-Object LastWriteTime)
  if (-not $old.Count) { Write-Host "No $Label older than $Days day(s) in $Folder." -ForegroundColor Green; return }
  Write-Host ''
  Write-Host "$($old.Count) $Label older than $Days day(s) (last modified before $($cutoff.ToString('yyyy-MM-dd'))) in ${Folder}:"
  foreach ($f in $old) { Write-Host ('  {0}  {1,10:N1} KB  {2}' -f $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), ($f.Length / 1KB), $f.Name) }
  Write-Host ('  Total: {0:N1} MB' -f (($old | Measure-Object Length -Sum).Sum / 1MB))
  $confirm = Read-Host "Type YES (uppercase) to permanently delete these $($old.Count) file(s) (anything else cancels)"
  if ($confirm -cne 'YES') { Write-Host 'Cancelled - nothing deleted.' -ForegroundColor Yellow; return }
  $deleted = 0; $failed = 0
  foreach ($f in $old) {
    try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $deleted++ }
    catch { $failed++; Write-Host "  Could not delete $($f.Name): $($_.Exception.Message)" -ForegroundColor Yellow }
  }
  Write-Host "[OK] Deleted $deleted $Label$(if ($failed) { "; $failed could not be deleted (in use?)" })." -ForegroundColor Green
}

function Read-WholeNumber {
  param([string]$Prompt, [int]$Default)
  while ($true) {
    $a = Read-Host $Prompt
    if (-not $a) { return $Default }
    if ($a -match '^\d{1,6}$' -and [int]$a -le 87600) { return [int]$a }
    Write-Host 'Invalid number - enter a whole number (or press Enter for the default).' -ForegroundColor Yellow
  }
}
function Show-TextPaged {
  param([string[]]$Lines, [int]$PageSize = 60)
  if (-not $Lines.Count) { Write-Host '(empty file)'; return }
  for ($i = 0; $i -lt $Lines.Count; $i += $PageSize) {
    $end = [math]::Min($i + $PageSize, $Lines.Count) - 1
    $Lines[$i..$end] | ForEach-Object { Write-Host $_ }
    if ($end -lt $Lines.Count - 1) {
      $more = Read-Host ('-- lines {0}-{1} of {2}: Enter for more, q to stop --' -f ($i + 1), ($end + 1), $Lines.Count)
      if ($more -match '^[Qq]') { return }
    }
  }
}

while ($true) {
  $files = @()
  if (Test-Path $reportDir) { $files += @(Get-ChildItem -Path $reportDir -File -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Source = 'Report'; File = $_ } }) }
  if ($logDir -and (Test-Path $logDir)) { $files += @(Get-ChildItem -Path $logDir -File -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Source = 'Log'; File = $_ } }) }
  $files = @($files | Sort-Object { $_.File.LastWriteTime } -Descending)
  Write-Host ''
  if (-not $files.Count) {
    Write-Host "No reports found in $reportDir." -ForegroundColor Yellow
    Write-Host 'Run Export System Information or Export Critical Event Logs & Reliability Report first.'
    return
  }
  Write-Host "--- Reports ($reportDir) ---"
  for ($i = 0; $i -lt $files.Count; $i++) {
    $f = $files[$i].File
    Write-Host ('  [{0,2}] {1}  {2,-6} {3,8}  {4}' -f ($i + 1), $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $files[$i].Source, ('{0:N1} KB' -f ($f.Length / 1KB)), $f.Name)
  }
  Write-Host ''
  Write-Host '  [B] Bundle reports + logs into a zip for the ticket'
  Write-Host '  [D] Delete old reports'
  Write-Host '  [O] Open the reports folder'
  $selection = Read-Host 'Enter a report number to view, B, D, O, or 0 to exit'
  if (-not $selection -or $selection -eq '0') { Write-Host 'Exiting tool.' -ForegroundColor Yellow; return }
  if ($selection -match '^[Bb]$') {
    $hours = Read-WholeNumber -Prompt "Include files from the last how many hours? (Enter = $defaultBundleHours, 0 = all files)" -Default $defaultBundleHours
    $zipPath = New-TicketBundle -Hours $hours
    if ($zipPath -and $hasDesktop) {
      $open = Read-Host 'Open the MSP-Reports folder with the zip selected? (y/N)'
      if ($open -match '^[Yy]') { Start-Process -FilePath explorer.exe -ArgumentList "/select,`"$zipPath`""; Write-Host 'Opened.' -ForegroundColor Green }
    }
    continue
  }
  if ($selection -match '^[Dd]$') {
    if (-not (Test-Path -LiteralPath $reportDir)) { Write-Host "Reports folder not found: $reportDir" -ForegroundColor Yellow; continue }
    $days = Read-WholeNumber -Prompt "Delete reports older than how many days? (Enter = $defaultDeleteDays)" -Default $defaultDeleteDays
    if ($days -lt 1) { Write-Host 'Days must be 1 or more - cancelled.' -ForegroundColor Yellow; continue }
    Remove-OldFiles -Folder $reportDir -Days $days -Label 'report file(s)'
    if ($logDir -and (Test-Path -LiteralPath $logDir)) {
      $alsoLogs = Read-Host "Also delete MSP Tool log files older than $days day(s)? (y/N)"
      if ($alsoLogs -match '^[Yy]') { Remove-OldFiles -Folder $logDir -Days $days -Label 'log file(s)' }
    }
    continue
  }
  if ($selection -match '^[Oo]$') {
    if ($hasDesktop -and (Test-Path $reportDir)) { Start-Process -FilePath explorer.exe -ArgumentList "`"$reportDir`""; Write-Host "Opened $reportDir" -ForegroundColor Green }
    else { Write-Host "Reports folder: $reportDir" }
    continue
  }
  if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $files.Count) { Write-Host 'Invalid selection.' -ForegroundColor Yellow; continue }

  $f = $files[[int]$selection - 1].File
  Write-Host ''
  Write-Host ('=== {0}  ({1:N1} KB, {2}) ===' -f $f.Name, ($f.Length / 1KB), $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) -ForegroundColor Cyan
  try {
    switch ($f.Extension.ToLowerInvariant()) {
      { $_ -in '.html', '.htm' } {
        if ($hasDesktop) { Invoke-Item -LiteralPath $f.FullName; Write-Host 'Opened in your default browser.' -ForegroundColor Green }
        else { Write-Host "HTML reports need a desktop to view. File: $($f.FullName)" -ForegroundColor Yellow }
        break
      }
      '.csv' {
        $rows = @(Import-Csv -LiteralPath $f.FullName)
        Write-Host "$($rows.Count) row(s). Long columns are cut off here - open in Excel for full text."
        if ($rows.Count) { Show-TextPaged -Lines (($rows | Format-Table -AutoSize | Out-String -Width 220) -split "\r?\n" | Where-Object { $_.Trim() }) }
        break
      }
      default { Show-TextPaged -Lines @(Get-Content -LiteralPath $f.FullName) }
    }
  } catch {
    Write-Host "Could not read $($f.Name): $($_.Exception.Message)" -ForegroundColor Red
    continue
  }
  if ($hasDesktop -and $f.Extension -notin '.html', '.htm') {
    $open = Read-Host 'Open this file in its default app? (y/N)'
    if ($open -match '^[Yy]') { Invoke-Item -LiteralPath $f.FullName; Write-Host 'Opened.' -ForegroundColor Green }
  }
}
