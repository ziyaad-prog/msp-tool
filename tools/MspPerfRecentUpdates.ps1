$since = (Get-Date).AddDays(-30)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# Removals are recorded per machine (not next to the tool) so they can be reinstalled after a restart
$recordDir = Join-Path $env:ProgramData 'MSP-Tool'
$recordFile = Join-Path $recordDir 'uninstalled-updates.json'
$lastBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime

function Get-RemovedRecords {
  if (-not (Test-Path $recordFile)) { return ,@() }
  try { $data = Get-Content -Path $recordFile -Raw -Encoding UTF8 | ConvertFrom-Json; return ,@($data) } catch { return ,@() }
}
function Save-RemovedRecords {
  param($Records)
  if (-not (Test-Path $recordDir)) { New-Item -ItemType Directory -Path $recordDir -Force | Out-Null }
  ConvertTo-Json -InputObject @($Records) -Depth 3 | Set-Content -Path $recordFile -Encoding UTF8
}
function Test-RemovalPending {
  param($Record)
  try { [datetime]::ParseExact($Record.RemovedAt, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) -gt $lastBoot } catch { $false }
}

Write-Host "Updates installed since $($since.ToString('yyyy-MM-dd'))"
Write-Host 'Cross-check CWA: Tiles > Patching > History (Failed/In Progress)'
while ($true) {
  try {
    $updates = @(Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn -and $_.InstalledOn -ge $since } | Sort-Object InstalledOn -Descending)
  } catch {
    Write-Host 'Could not read hotfix history. Check CWA patching history manually.' -ForegroundColor Red
    return
  }
  $records = Get-RemovedRecords
  Write-Host ''
  if (-not $updates.Count -and -not $records.Count) { Write-Host 'No updates installed in the last 30 days.' -ForegroundColor Green; return }
  Write-Host '--- Recent Updates ---'
  if (-not $updates.Count) { Write-Host '  (none installed in the last 30 days)' }
  for ($i = 0; $i -lt $updates.Count; $i++) {
    $u = $updates[$i]
    $rec = $records | Where-Object { $_.KB -eq $u.HotFixID } | Select-Object -First 1
    $note = if ($rec -and (Test-RemovalPending $rec)) { '  (uninstalled - pending restart)' } else { '' }
    Write-Host ('  [{0}] {1}  {2}  {3}{4}' -f ($i + 1), $u.InstalledOn.ToString('yyyy-MM-dd'), $u.HotFixID, $u.Description, $note)
  }
  if ($records.Count) {
    Write-Host ''
    Write-Host '--- Uninstalled by MSP Tool (can be reinstalled with R) ---'
    foreach ($r in $records) {
      $state = if (Test-RemovalPending $r) { 'pending restart' } else { 'removed' }
      Write-Host ('  {0}  removed {1} by {2}  ({3})' -f $r.KB, $r.RemovedAt, $r.RemovedBy, $state)
    }
  }
  Write-Host ''
  $selection = Read-Host 'Enter an update number to uninstall, R to reinstall a removed update, or 0 to exit'
  if (-not $selection -or $selection -eq '0') { Write-Host 'Exiting tool.' -ForegroundColor Yellow; return }

  if ($selection -match '^[Rr]$') {
    # ---------------- Reinstall ----------------
    if (-not $isAdmin) { Write-Host 'Reinstalling updates requires administrator rights. Relaunch MSP Tool elevated.' -ForegroundColor Red; continue }
    Write-Host ''
    for ($i = 0; $i -lt $records.Count; $i++) {
      Write-Host ('  [{0}] {1}  removed {2}' -f ($i + 1), $records[$i].KB, $records[$i].RemovedAt)
    }
    Write-Host '  [M] Enter a KB number manually (update removed some other way)'
    $pick = Read-Host 'Choose an update to reinstall, or 0 to cancel'
    $record = $null
    if ($pick -match '^[Mm]$') {
      $kbIn = (Read-Host 'KB number (e.g. KB5012345)').Trim()
      if ($kbIn -notmatch '^(KB)?\d{6,8}$') { Write-Host 'Invalid KB number.' -ForegroundColor Yellow; continue }
      $target = 'KB' + ($kbIn -replace '^KB', '')
    } elseif ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $records.Count) {
      $record = $records[[int]$pick - 1]
      $target = $record.KB
    } else { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }

    if ($record -and (Test-RemovalPending $record)) { Write-Host "The removal of $target is still pending a restart. Restart the computer first, then reinstall." -ForegroundColor Yellow; continue }
    if (Get-HotFix -Id $target -ErrorAction SilentlyContinue) {
      Write-Host "$target is already installed - nothing to do." -ForegroundColor Green
      try { Save-RemovedRecords @($records | Where-Object { $_.KB -ne $target }) } catch { }
      continue
    }
    $kbNum = $target -replace '^KB', ''
    Write-Host "Searching Windows Update for $target (this can take several minutes)..."
    try {
      $session = New-Object -ComObject Microsoft.Update.Session
      $session.ClientApplicationID = 'MSP Tool'
      $found = $session.CreateUpdateSearcher().Search('(IsInstalled=0 and IsHidden=0) or (IsInstalled=0 and IsHidden=1)')
      $match = @($found.Updates | Where-Object { @($_.KBArticleIDs) -contains $kbNum })
    } catch {
      Write-Host "[FAIL] Windows Update search failed: $($_.Exception.Message)" -ForegroundColor Red
      continue
    }
    if (-not $match.Count) {
      Write-Host "Windows Update is not offering $target." -ForegroundColor Yellow
      Write-Host '  - It may have been superseded by a newer update: install the latest updates via Windows Update/CWA instead.'
      Write-Host '  - Or this machine''s update policy (WSUS/CWA) is not offering it.'
      Write-Host "  - Manual option: download $target from https://www.catalog.update.microsoft.com and install the .msu."
      continue
    }
    $wu = $match[0]
    Write-Host "Found: $($wu.Title)"
    if ($wu.IsHidden) { Write-Host '(This update is currently hidden in Windows Update - it will be unhidden.)' -ForegroundColor Yellow }
    $answer = Read-Host "Type $target to download and reinstall it (anything else cancels)"
    if ($answer -ne $target) { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
    try {
      if ($wu.IsHidden) { $wu.IsHidden = $false }
      if (-not $wu.EulaAccepted) { $wu.AcceptEula() }
      $coll = New-Object -ComObject Microsoft.Update.UpdateColl
      [void]$coll.Add($wu)
      if (-not $wu.IsDownloaded) {
        Write-Host 'Downloading...'
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $coll
        $dl = $downloader.Download()
        if ($dl.ResultCode -ne 2 -and $dl.ResultCode -ne 3) { throw ('download failed (result code {0}, HRESULT 0x{1:X8})' -f $dl.ResultCode, $dl.HResult) }
      }
      Write-Host 'Installing (this can take several minutes)...'
      $installer = $session.CreateUpdateInstaller()
      $installer.Updates = $coll
      $res = $installer.Install()
      if ($res.ResultCode -ne 2 -and $res.ResultCode -ne 3) { throw ('install failed (result code {0}, HRESULT 0x{1:X8})' -f $res.ResultCode, $res.HResult) }
      Write-Host "[OK] $target reinstalled." -ForegroundColor Green
      if ($res.RebootRequired) { Write-Host 'RESTART REQUIRED to finish.' -ForegroundColor Yellow }
      try { Save-RemovedRecords @($records | Where-Object { $_.KB -ne $target }) } catch { Write-Host "Could not update $recordFile : $($_.Exception.Message)" -ForegroundColor Yellow }
    } catch {
      Write-Host "[FAIL] Reinstall of $target failed: $($_.Exception.Message)" -ForegroundColor Red
      Write-Host 'Note: Windows Update downloads are blocked in remote PowerShell (WinRM/SSH) sessions - run from the desktop or ScreenConnect Backstage instead.'
    }
    continue
  }

  # ---------------- Uninstall ----------------
  if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $updates.Count) { Write-Host 'Invalid selection.' -ForegroundColor Yellow; continue }
  $u = $updates[[int]$selection - 1]
  $kb = $u.HotFixID -replace '^KB', ''
  $installed = $u.InstalledOn.ToString('yyyy-MM-dd')
  Write-Host ''
  Write-Host "Selected: $($u.HotFixID) - $($u.Description) - installed $installed"
  $rec = $records | Where-Object { $_.KB -eq $u.HotFixID } | Select-Object -First 1
  if ($rec -and (Test-RemovalPending $rec)) { Write-Host 'Already uninstalled - restart the computer to finish removing it.' -ForegroundColor Yellow; continue }
  if (-not $isAdmin) { Write-Host 'Uninstalling updates requires administrator rights. Relaunch MSP Tool elevated.' -ForegroundColor Red; continue }

  # DISM rather than wusa: wusa ignores /quiet on Windows 10+ and shows a dialog, which hangs
  # unattended in Backstage/SYSTEM, SSH, and RMM sessions. DISM is also the only way to remove
  # a cumulative update that shipped bundled with a servicing stack update.
  Write-Host 'Looking up installed update packages (this can take a minute)...'
  try {
    $pkgs = @(Get-WindowsPackage -Online -ErrorAction Stop | Where-Object { $_.PackageState -eq 'Installed' })
  } catch {
    Write-Host "[FAIL] Could not list update packages: $($_.Exception.Message)" -ForegroundColor Red
    continue
  }
  $candidates = @($pkgs | Where-Object { $_.PackageName -match "KB$kb(\D|$)" })
  $confirmed = $candidates.Count -gt 0
  if ($confirmed) {
    Write-Host "Package(s) for $($u.HotFixID):"
  } else {
    $candidates = @($pkgs | Where-Object { $_.PackageName -match 'RollupFix' })
    if (-not $candidates.Count) {
      Write-Host "No removable package found for $($u.HotFixID). Try Settings > Windows Update > Update history > Uninstall updates." -ForegroundColor Yellow
      continue
    }
    Write-Host "No package is named after $($u.HotFixID)." -ForegroundColor Yellow
    Write-Host "If $($u.HotFixID) is the monthly cumulative update, it is the 'Package_for_RollupFix' package below."
    Write-Host "$($u.HotFixID) was installed $installed - only continue if the package install date matches." -ForegroundColor Yellow
  }
  for ($i = 0; $i -lt $candidates.Count; $i++) {
    $t = $candidates[$i].InstallTime
    $when = if ($t -is [datetime]) { $t.ToString('yyyy-MM-dd HH:mm') } elseif ($t) { "$t" } else { 'unknown' }
    Write-Host ('  [{0}] {1}  (installed {2})' -f ($i + 1), $candidates[$i].PackageName, $when)
  }
  $pick = Read-Host 'Enter the package number to remove, or 0 to cancel'
  if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $candidates.Count) { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
  $pkgName = $candidates[[int]$pick - 1].PackageName

  Write-Host ''
  Write-Host 'WARNING: Removing a security/cumulative update leaves the machine unpatched. Confirm with a senior/SOC leader, and pause/decline the patch in CWA so it is not reinstalled.' -ForegroundColor Yellow
  if ($confirmed) {
    $answer = Read-Host "Type $($u.HotFixID) to remove $pkgName (anything else cancels)"
    if ($answer -ne $u.HotFixID) { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
  } else {
    Write-Host "This package is NOT confirmed to be $($u.HotFixID)." -ForegroundColor Yellow
    $answer = Read-Host "Type YES (uppercase) to remove $pkgName (anything else cancels)"
    if ($answer -cne 'YES') { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
  }

  Write-Host "Removing $pkgName (this can take several minutes)..."
  try {
    $result = Remove-WindowsPackage -Online -PackageName $pkgName -NoRestart -ErrorAction Stop
    Write-Host "[OK] Removed $pkgName." -ForegroundColor Green
    if ($result.RestartNeeded) { Write-Host 'RESTART REQUIRED to finish. The update stays in the list until then.' -ForegroundColor Yellow }
    Write-Host 'To undo, run this tool again and choose R (reinstall).'
    try {
      $newRecord = [pscustomobject]@{ KB = $u.HotFixID; Description = $u.Description; Package = $pkgName; RemovedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); RemovedBy = "$env:USERDOMAIN\$env:USERNAME" }
      Save-RemovedRecords (@($records | Where-Object { $_.KB -ne $u.HotFixID }) + $newRecord)
    } catch {
      Write-Host "Could not record the removal in $recordFile : $($_.Exception.Message)" -ForegroundColor Yellow
    }
  } catch {
    Write-Host "[FAIL] Could not remove ${pkgName}: $($_.Exception.Message)" -ForegroundColor Red
  }
}
