# OneDrive restart / reset for the CURRENT user (OneDrive runs per user, so this must run in the
# affected user's own session - not as SYSTEM / ScreenConnect Backstage).
# Where OneDrive.exe can be installed (per-user first, then per-machine)
$oneDriveCandidates = @("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe", "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe", "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe")
# Signed-in accounts (read only)
$accountsKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts'
# Seconds to wait for OneDrive to close, and for it to restart by itself after /reset
$closeWaitSec = 15
$resetWaitSec = 60
$isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem

function Get-OneDriveProcess {
  $mySession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
  @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $mySession })
}
function Wait-OneDrive {
  # Waits until OneDrive is running ($true) or gone ($false); returns whether that state was reached
  param([bool]$Running, [int]$Seconds, $IgnoreIds = @())
  for ($i = 0; $i -le $Seconds; $i++) {
    $procs = @(Get-OneDriveProcess | Where-Object { $IgnoreIds -notcontains $_.Id })
    if ($Running -and $procs.Count) { return $true }
    if (-not $Running -and -not @(Get-OneDriveProcess).Count) { return $true }
    if ($i -lt $Seconds) { Start-Sleep -Seconds 1 }
  }
  return $false
}
function Stop-OneDrive {
  $procs = @(Get-OneDriveProcess)
  if (-not $procs.Count) { Write-Host '[OK] OneDrive was not running' -ForegroundColor Green; return $true }
  try { Start-Process -FilePath $oneDriveExe -ArgumentList '/shutdown' -ErrorAction Stop } catch { Write-Host "OneDrive /shutdown failed: $($_.Exception.Message)" -ForegroundColor Yellow }
  if (-not (Wait-OneDrive -Running $false -Seconds $closeWaitSec)) {
    Write-Host 'OneDrive did not close by itself - ending the process.' -ForegroundColor Yellow
    try { Stop-Process -Id @(Get-OneDriveProcess | ForEach-Object { $_.Id }) -Force -ErrorAction Stop } catch { }
    if (-not (Wait-OneDrive -Running $false -Seconds 5)) { Write-Host '[FAIL] OneDrive is still running' -ForegroundColor Red; return $false }
  }
  Write-Host '[OK] OneDrive stopped' -ForegroundColor Green
  return $true
}
function Start-OneDrive {
  try {
    Start-Process -FilePath $oneDriveExe -ArgumentList '/background' -ErrorAction Stop
  } catch { Write-Host "[FAIL] Could not start OneDrive: $($_.Exception.Message)" -ForegroundColor Red; return }
  if (Wait-OneDrive -Running $true -Seconds 15) { Write-Host '[OK] OneDrive started' -ForegroundColor Green }
  else { Write-Host '[FAIL] OneDrive was started but is not running - start it from the Start menu and check for an error.' -ForegroundColor Red }
}

if ($isSystem) {
  Write-Host 'WARNING: running as SYSTEM. OneDrive runs per user, so it cannot be restarted or reset from here.' -ForegroundColor Red
  Write-Host 'Run MSP Tool in the affected user''s own session (e.g. ScreenConnect as the user, not Backstage).' -ForegroundColor Red
  return
}
Write-Host "User: $env:USERDOMAIN\$env:USERNAME" -ForegroundColor Cyan
$oneDriveExe = $oneDriveCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $oneDriveExe) {
  Write-Host 'OneDrive.exe not found (checked per-user and Program Files locations) - OneDrive is not installed for this user.' -ForegroundColor Red
  return
}
$ver = (Get-Item -LiteralPath $oneDriveExe -ErrorAction SilentlyContinue).VersionInfo.FileVersion
Write-Host "OneDrive.exe: $oneDriveExe$(if ($ver) { " (version $ver)" })"

while ($true) {
  Write-Host ''
  $procs = @(Get-OneDriveProcess)
  if ($procs.Count) { Write-Host "OneDrive: running (PID $(($procs | ForEach-Object { $_.Id }) -join ', '))" -ForegroundColor Green }
  else { Write-Host 'OneDrive: NOT running' -ForegroundColor Yellow }
  Write-Host '--- Signed-in accounts ---' -ForegroundColor Cyan
  $accounts = @()
  if (Test-Path -LiteralPath $accountsKey) {
    foreach ($k in @(Get-ChildItem -LiteralPath $accountsKey -ErrorAction SilentlyContinue)) {
      $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
      if ($p -and $p.UserEmail) { $accounts += [pscustomobject]@{ Account = $k.PSChildName; Email = $p.UserEmail; Folder = $p.UserFolder } }
    }
  }
  if ($accounts.Count) { foreach ($a in $accounts) { Write-Host ('  {0}: {1}  ->  {2}' -f $a.Account, $a.Email, $a.Folder) } }
  else { Write-Host '  No signed-in OneDrive accounts found for this user.' -ForegroundColor Yellow }
  Write-Host ''
  Write-Host '  [1] Restart OneDrive (close and start again)'
  Write-Host '  [2] Full reset (OneDrive.exe /reset) - re-syncs everything'
  Write-Host '  [0] Exit'
  $choice = Read-Host 'Enter a number (1-2), or 0 to exit'
  if (-not $choice -or $choice -eq '0') { Write-Host 'Exiting tool.' -ForegroundColor Yellow; return }

  if ($choice -eq '1') {
    $confirm = Read-Host 'Restart OneDrive now? Sync pauses for a moment (y/N)'
    if ($confirm -notmatch '^[Yy]') { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
    if (Stop-OneDrive) { Start-OneDrive }
  }
  elseif ($choice -eq '2') {
    Write-Host 'WARNING: a reset disconnects all OneDrive sync connections (including synced SharePoint/Teams libraries)' -ForegroundColor Yellow
    Write-Host 'and then re-scans everything. Files are NOT deleted, but the re-sync can take a long time on large' -ForegroundColor Yellow
    Write-Host 'libraries. The user may need to sign in again, and synced libraries that do not come back must be re-synced.' -ForegroundColor Yellow
    $answer = Read-Host 'Type YES (uppercase) to reset OneDrive (anything else cancels)'
    if ($answer -cne 'YES') { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
    $oldIds = @(Get-OneDriveProcess | ForEach-Object { $_.Id })
    try {
      Start-Process -FilePath $oneDriveExe -ArgumentList '/reset' -ErrorAction Stop
      Write-Host '[OK] OneDrive reset started' -ForegroundColor Green
    } catch { Write-Host "[FAIL] OneDrive /reset: $($_.Exception.Message)" -ForegroundColor Red; continue }
    # The reset closes OneDrive; give the old process time to exit before looking for the new one
    [void](Wait-OneDrive -Running $false -Seconds $closeWaitSec)
    Write-Host "Waiting up to $resetWaitSec seconds for OneDrive to restart by itself..."
    if (Wait-OneDrive -Running $true -Seconds $resetWaitSec -IgnoreIds $oldIds) { Write-Host '[OK] OneDrive restarted by itself' -ForegroundColor Green }
    else {
      Write-Host 'OneDrive did not restart by itself - starting it.'
      Start-OneDrive
    }
    Write-Host 'Check the OneDrive icon: sign in if asked, and allow time for the re-sync to finish.'
  }
  else { Write-Host 'Invalid selection.' -ForegroundColor Yellow }
}
