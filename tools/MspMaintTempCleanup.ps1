# ---------------- Settings ----------------
# Only files older than this many days are removed (newer temp files are often still in use)
$minAgeDays = 7
# How many failed deletions to list per folder (the rest are only counted, to keep logs small)
$maxFailuresShown = 3
# Folders to clean. Wildcards are expanded (e.g. every user profile / browser profile).
# Only FILES inside these folders are deleted; the folders themselves are kept.
# Browser entries are cache folders only - never cookies, history, logins or settings.
# (C:\Windows\Prefetch is deliberately NOT cleaned: it speeds up boot and app launch.)
$cleanTargets = @(
  @{ Name = 'Windows Temp';                Path = "$env:SystemRoot\Temp" }
  @{ Name = 'User Temp';                   Path = "$env:SystemDrive\Users\*\AppData\Local\Temp" }
  @{ Name = 'Delivery Optimization cache'; Path = "$env:ProgramData\Microsoft\Windows\DeliveryOptimization\Cache" }
  @{ Name = 'Chrome cache';                Path = "$env:SystemDrive\Users\*\AppData\Local\Google\Chrome\User Data\*\Cache" }
  @{ Name = 'Chrome code cache';           Path = "$env:SystemDrive\Users\*\AppData\Local\Google\Chrome\User Data\*\Code Cache" }
  @{ Name = 'Chrome GPU cache';            Path = "$env:SystemDrive\Users\*\AppData\Local\Google\Chrome\User Data\*\GPUCache" }
  @{ Name = 'Edge cache';                  Path = "$env:SystemDrive\Users\*\AppData\Local\Microsoft\Edge\User Data\*\Cache" }
  @{ Name = 'Edge code cache';             Path = "$env:SystemDrive\Users\*\AppData\Local\Microsoft\Edge\User Data\*\Code Cache" }
  @{ Name = 'Edge GPU cache';              Path = "$env:SystemDrive\Users\*\AppData\Local\Microsoft\Edge\User Data\*\GPUCache" }
  @{ Name = 'Firefox cache';               Path = "$env:SystemDrive\Users\*\AppData\Local\Mozilla\Firefox\Profiles\*\cache2" }
)
# Reported only (never deleted by this tool)
$windowsOldPath = "$env:SystemDrive\Windows.old"
# ---- end of settings ----

$cutoff = (Get-Date).AddDays(-$minAgeDays)

# Lists files under a folder without following junctions/symlinks (so we never leave the target folder)
function Get-FilesNoReparse {
  param([string]$Root)
  $stack = New-Object System.Collections.Stack
  $stack.Push((New-Object System.IO.DirectoryInfo $Root))
  while ($stack.Count) {
    $dir = $stack.Pop()
    try { $items = $dir.GetFileSystemInfos() } catch { continue }
    foreach ($item in $items) {
      if ($item -is [System.IO.DirectoryInfo]) {
        if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $stack.Push($item) }
      } else { $item }
    }
  }
}

function Get-FreeGB {
  try {
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction Stop
    return [math]::Round($d.FreeSpace / 1GB, 2)
  } catch { return $null }
}

$freeBefore = Get-FreeGB
Write-Host "Removing temp and cache files older than $minAgeDays days (last modified before $($cutoff.ToString('yyyy-MM-dd HH:mm')))."
Write-Host 'Files in use are skipped. Newer files are kept.'
Write-Host ''

$totalRemoved = 0; $totalBytes = 0; $totalFailed = 0; $foldersCleaned = 0
foreach ($target in $cleanTargets) {
  $dirs = @(Get-Item -Path $target.Path -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer -and -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })
  if (-not $dirs.Count) { continue }
  foreach ($dir in $dirs) {
    $found = 0; $kept = 0; $removed = 0; $failed = 0; $bytes = 0
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($file in (Get-FilesNoReparse -Root $dir.FullName)) {
      $found++
      if ($file.LastWriteTime -ge $cutoff) { $kept++; continue }
      $size = $file.Length
      try {
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        $removed++
        $bytes += $size
      } catch {
        $failed++
        if ($failures.Count -lt $maxFailuresShown) { $failures.Add("$($file.Name): $($_.Exception.Message)") }
      }
    }
    $foldersCleaned++
    $totalRemoved += $removed; $totalBytes += $bytes; $totalFailed += $failed
    $color = if ($failed) { 'Yellow' } else { 'Green' }
    Write-Host "$($target.Name): $($dir.FullName)" -ForegroundColor Cyan
    Write-Host ('  found {0}, removed {1}, kept (newer) {2}, skipped (in use/denied) {3}, freed {4:N1} MB' -f $found, $removed, $kept, $failed, ($bytes / 1MB)) -ForegroundColor $color
    foreach ($msg in $failures) { Write-Host "    could not remove $msg" -ForegroundColor DarkYellow }
    if ($failed -gt $failures.Count) { Write-Host ('    ... and {0} more skipped' -f ($failed - $failures.Count)) -ForegroundColor DarkYellow }
  }
}

Write-Host ''
if (-not $foldersCleaned) { Write-Host 'No temp or cache folders found.' -ForegroundColor Yellow }
Write-Host ('TOTAL: removed {0} file(s), freed {1:N1} MB, skipped {2} file(s) in use or denied, across {3} folder(s).' -f $totalRemoved, ($totalBytes / 1MB), $totalFailed, $foldersCleaned) -ForegroundColor Green
$freeAfter = Get-FreeGB
if ($null -ne $freeBefore -and $null -ne $freeAfter) { Write-Host "Free space on $env:SystemDrive : $freeBefore GB before, $freeAfter GB after." }

# Windows.old - report only
if (Test-Path -LiteralPath $windowsOldPath) {
  Write-Host ''
  Write-Host "Measuring $windowsOldPath (not deleted)..."
  $oldBytes = 0; $oldCount = 0
  foreach ($f in (Get-FilesNoReparse -Root $windowsOldPath)) { $oldBytes += $f.Length; $oldCount++ }
  Write-Host ('{0} is present: about {1:N2} GB in {2} readable file(s).' -f $windowsOldPath, ($oldBytes / 1GB), $oldCount) -ForegroundColor Yellow
  Write-Host '  It holds the previous Windows install (needed only to roll back an upgrade). To remove it, use'
  Write-Host '  Settings > System > Storage > Temporary files > "Previous Windows installation(s)" (Storage Sense),'
  Write-Host '  or Disk Cleanup (cleanmgr) > Clean up system files > "Previous Windows installation(s)".'
}
