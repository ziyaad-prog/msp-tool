# Clear Teams / Outlook caches for the CURRENT user. Caches are per user profile, so this must run
# in the affected user's own session (not as SYSTEM / ScreenConnect Backstage, not as another admin).
# Cache contents are deleted (not the folders); the apps rebuild them automatically on next start.
# Profile folders the cache paths are built from
$roamingDir = $env:APPDATA
$localDir = $env:LOCALAPPDATA
# Outlook data files that are never deleted - only listed for information
$protectedExtensions = @('.ost', '.pst', '.nst')
# Seconds to wait for apps to close after Stop-Process
$closeWaitSec = 10
$isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem

$outlookDir = Join-Path $localDir 'Microsoft\Outlook'
# Root = cache folder; SubFolders = only these subfolders are emptied (empty list = empty the whole Root)
$caches = @(
  [pscustomobject]@{ Name = 'Classic Teams cache'; Root = (Join-Path $roamingDir 'Microsoft\Teams'); Processes = @('Teams')
    SubFolders = @('Application Cache\Cache', 'blob_storage', 'Cache', 'Code Cache', 'databases', 'GPUCache', 'IndexedDB', 'Local Storage', 'Service Worker\CacheStorage', 'tmp')
    Note = 'Only the cache subfolders are emptied; Teams settings are kept.' }
  [pscustomobject]@{ Name = 'New Teams cache'; Root = (Join-Path $localDir 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams'); Processes = @('ms-teams')
    SubFolders = @(); Note = 'The user may have to sign in to Teams again.' }
  [pscustomobject]@{ Name = 'Outlook RoamCache'; Root = (Join-Path $outlookDir 'RoamCache'); Processes = @('OUTLOOK')
    SubFolders = @(); Note = 'Autocomplete for Exchange/M365 accounts is re-downloaded; POP/IMAP-only profiles may lose their local autocomplete list.' }
  [pscustomobject]@{ Name = 'Outlook Offline Address Book'; Root = (Join-Path $outlookDir 'Offline Address Books'); Processes = @('OUTLOOK')
    SubFolders = @(); Note = 'Re-downloaded automatically (or Send/Receive > Download Address Book).' }
)

function Get-CacheTargets {
  param($Cache)
  if (-not (Test-Path -LiteralPath $Cache.Root)) { return @() }
  if (-not $Cache.SubFolders.Count) { return @($Cache.Root) }
  @($Cache.SubFolders | ForEach-Object { Join-Path $Cache.Root $_ } | Where-Object { Test-Path -LiteralPath $_ })
}
function Get-SizeMB {
  param($Paths)
  $sum = 0
  foreach ($p in @($Paths)) {
    $s = (Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($s) { $sum += $s }
  }
  [math]::Round($sum / 1MB, 1)
}
function Get-AppProcess {
  param($Names)
  $mySession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
  @(Get-Process -Name $Names -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $mySession })
}
function Test-Protected {
  param($Item)
  if (-not $Item.PSIsContainer) { return ($protectedExtensions -contains "$($Item.Extension)".ToLower()) }
  [bool](@(Get-ChildItem -LiteralPath $Item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $protectedExtensions -contains "$($_.Extension)".ToLower() }).Count)
}
function Clear-CacheFolder {
  param($Dir)
  $removed = 0; $failed = 0; $skipped = 0
  foreach ($item in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
    if (Test-Protected $item) { $skipped++; continue }
    try { Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop; $removed++ } catch { $failed++ }
  }
  [pscustomobject]@{ Removed = $removed; Failed = $failed; Skipped = $skipped }
}

if ($isSystem) {
  Write-Host 'WARNING: running as SYSTEM. Teams and Outlook caches are per user, so clearing them here would only touch' -ForegroundColor Red
  Write-Host 'the SYSTEM profile and fix nothing. Run MSP Tool in the affected user''s own session (e.g. ScreenConnect as the user, not Backstage).' -ForegroundColor Red
  return
}
Write-Host "Clearing caches for user: $env:USERDOMAIN\$env:USERNAME (profile: $env:USERPROFILE)" -ForegroundColor Cyan
Write-Host 'Caches are per user - make sure this is the user who has the problem (not an elevated admin account).'

while ($true) {
  Write-Host ''
  Write-Host '--- Caches ---' -ForegroundColor Cyan
  $info = @()
  for ($i = 0; $i -lt $caches.Count; $i++) {
    $c = $caches[$i]
    $targets = @(Get-CacheTargets $c)
    $size = if ($targets.Count) { Get-SizeMB $targets } else { 0 }
    $info += [pscustomobject]@{ Cache = $c; Targets = $targets; SizeMB = $size }
    $state = if ($targets.Count) { "$size MB" } else { 'not found' }
    Write-Host ('  [{0}] {1} - {2}' -f ($i + 1), $c.Name, $state)
    Write-Host "      $($c.Root)" -ForegroundColor Gray
  }
  $dataFiles = @(Get-ChildItem -LiteralPath $outlookDir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.ost', '.nst' })
  if ($dataFiles.Count) {
    Write-Host 'Outlook data files (for information only - never touched by this tool):'
    foreach ($f in $dataFiles) { Write-Host ('      {0}  {1} MB' -f $f.Name, [math]::Round($f.Length / 1MB, 1)) -ForegroundColor Gray }
  }
  Write-Host '  [A] Clear all caches found'
  $sel = Read-Host 'Enter a cache number to clear, A for all, or 0 to exit'
  if (-not $sel -or $sel -eq '0') { Write-Host 'Exiting tool.' -ForegroundColor Yellow; return }
  if ($sel -match '^[Aa]$') { $chosen = @($info) }
  elseif ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $info.Count) { $chosen = @($info[[int]$sel - 1]) }
  else { Write-Host 'Invalid selection.' -ForegroundColor Yellow; continue }
  $chosen = @($chosen | Where-Object { $_.Targets.Count })
  if (-not $chosen.Count) { Write-Host 'Nothing to clear - cache folder not found.' -ForegroundColor Yellow; continue }

  # ---------------- Apps must be closed ----------------
  $procNames = @($chosen | ForEach-Object { $_.Cache.Processes } | Select-Object -Unique)
  $running = @(Get-AppProcess $procNames)
  if ($running.Count) {
    Write-Host 'These apps are running and must be closed first:' -ForegroundColor Yellow
    foreach ($p in $running) { Write-Host "  $($p.ProcessName) (PID $($p.Id))" }
    $ans = Read-Host 'Close them now? Unsaved work in them will be lost (y/N)'
    if ($ans -notmatch '^[Yy]') { Write-Host 'Close the apps and run this again. Nothing was changed.' -ForegroundColor Yellow; continue }
    try { Stop-Process -Id @($running | ForEach-Object { $_.Id }) -Force -ErrorAction Stop } catch { Write-Host "Could not close all apps: $($_.Exception.Message)" -ForegroundColor Yellow }
    for ($w = 0; $w -lt $closeWaitSec; $w++) {
      if (-not @(Get-AppProcess $procNames).Count) { break }
      Start-Sleep -Seconds 1
    }
    $still = @(Get-AppProcess $procNames)
    if ($still.Count) { Write-Host "[FAIL] Still running: $(($still | ForEach-Object { $_.ProcessName } | Select-Object -Unique) -join ', ') - close them manually and try again." -ForegroundColor Red; continue }
    Write-Host '[OK] Apps closed' -ForegroundColor Green
  }

  # ---------------- Confirm and clear ----------------
  $total = 0
  foreach ($c in $chosen) { Write-Host "  $($c.Cache.Name) ($($c.SizeMB) MB) - $($c.Cache.Note)"; $total += $c.SizeMB }
  $confirm = Read-Host "Delete the contents of $($chosen.Count) cache(s) ($total MB)? They rebuild automatically when the app starts (y/N)"
  if ($confirm -notmatch '^[Yy]') { Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow; continue }
  foreach ($c in $chosen) {
    $removed = 0; $failed = 0; $skipped = 0
    foreach ($t in $c.Targets) {
      $r = Clear-CacheFolder $t
      $removed += $r.Removed; $failed += $r.Failed; $skipped += $r.Skipped
    }
    $after = Get-SizeMB $c.Targets
    $note = if ($skipped) { ", $skipped protected item(s) left alone" } else { '' }
    if ($failed) { Write-Host "[FAIL] $($c.Cache.Name): removed $removed item(s), $failed in use (close the app / sign out and retry)$note - $after MB left" -ForegroundColor Red }
    else { Write-Host "[OK] $($c.Cache.Name): cleared ($removed item(s) removed, $([math]::Round($c.SizeMB - $after, 1)) MB freed)$note" -ForegroundColor Green }
  }
  Write-Host 'Start Teams / Outlook again - the first start takes a little longer while the cache rebuilds.'
}
