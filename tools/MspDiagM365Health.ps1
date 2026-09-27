# --- Settings (edit as needed) ---
$maxOstGB = 25     # OST files above this size slow Outlook down
$maxPstGB = 20     # PST files above this size slow Outlook down and risk corruption
# Well-known Click-to-Run update channel GUIDs (last part of CDNBaseUrl / UpdateChannel URLs)
$channelMap = @{
  '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'
  '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (Preview)'
  '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'
  '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'
  'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-Annual Enterprise Channel (Preview)'
  '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta Channel'
  'f2e724c1-748f-4b47-8fb8-8e0d210e9208' = 'Office LTSC 2019 (volume licensed)'
  '5030841d-c919-4594-8d2d-84ae4f96e58e' = 'Office LTSC 2021 (volume licensed)'
  '7983bac0-e531-40cf-be00-fd24fe66619c' = 'Office LTSC 2024 (volume licensed)'
}
# Policy 'UpdateBranch' values (Group Policy / Intune) -> channel names
$branchMap = @{ 'Current' = 'Current Channel'; 'FirstReleaseCurrent' = 'Current Channel (Preview)'; 'MonthlyEnterprise' = 'Monthly Enterprise Channel'; 'Deferred' = 'Semi-Annual Enterprise Channel'; 'FirstReleaseDeferred' = 'Semi-Annual Enterprise Channel (Preview)'; 'InsiderFast' = 'Beta Channel' }

$officeKey = 'HKCU:\Software\Microsoft\Office\16.0'
$c2rKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun'
$issues = [System.Collections.Generic.List[string]]::new()
$regValues = { param($path) Get-ItemProperty -Path $path -ErrorAction SilentlyContinue }
$channelName = {
  param($url)
  if (-not $url) { return $null }
  $guid = ("$url".TrimEnd('/') -split '/')[-1].ToLower()
  if ($channelMap.ContainsKey($guid)) { $channelMap[$guid] } else { "Unknown channel ($guid)" }
}
# Click-to-Run stores times as milliseconds since 1601 (FILETIME / 10000)
$c2rTime = { param($v) try { if ([int64]$v -gt 1000000000000) { [datetime]::FromFileTimeUtc([int64]$v * 10000).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } } catch { $null } }

if ((Get-Process -Id $PID).SessionId -eq 0) { Write-Host 'Note: running as SYSTEM/service - per-user items (identities, Outlook profiles, Teams) show the SYSTEM profile, not the logged-on user.' -ForegroundColor Yellow }

# ---------------- Office Click-to-Run ----------------
Write-Host '--- Microsoft 365 Apps (Click-to-Run) ---' -ForegroundColor Cyan
$cfg = & $regValues "$c2rKey\Configuration"
$officeInstalled = $false
if (-not $cfg -or -not $cfg.VersionToReport) {
  $msi = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') | ForEach-Object {
    Get-ChildItem -Path $_ -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue } } |
    Where-Object { $_.DisplayName -match '^Microsoft (Office|365)' -and $_.SystemComponent -ne 1 } | Select-Object -First 3
  if ($msi) {
    $officeInstalled = $true
    Write-Host 'Click-to-Run Office not found, but these Office products are installed (MSI/volume licensed):' -ForegroundColor Yellow
    $msi | ForEach-Object { Write-Host "  $($_.DisplayName) $($_.DisplayVersion)" }
  } else {
    Write-Host 'Microsoft 365 Apps / Office is not installed on this machine.' -ForegroundColor Yellow
  }
} else {
  $officeInstalled = $true
  $installedCh = & $channelName $cfg.CDNBaseUrl
  $targetCh = & $channelName $cfg.UpdateChannel
  $pol = & $regValues 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\common\officeupdate'
  $policyCh = if ($pol -and $pol.updatebranch) { if ($branchMap.ContainsKey("$($pol.updatebranch)")) { $branchMap["$($pol.updatebranch)"] } else { "$($pol.updatebranch)" } } elseif ($pol -and $pol.updatepath) { "custom path $($pol.updatepath)" } else { $null }
  Write-Host "Version        : $($cfg.VersionToReport) ($($cfg.Platform))"
  Write-Host "Update channel : $(if ($installedCh) { $installedCh } else { 'unknown' })"
  if ($targetCh -and $targetCh -ne $installedCh) { Write-Host "  Switching to : $targetCh (applies at next update)" -ForegroundColor Yellow }
  if ($policyCh) { Write-Host "  Set by policy: $policyCh" }
  if ($cfg.UpdateUrl) { Write-Host "  Update source: $($cfg.UpdateUrl) (custom - check it is reachable)" }
  if ("$($cfg.UpdatesEnabled)" -eq 'False' -or ($pol -and "$($pol.enableautomaticupdates)" -eq '0')) { Write-Host '  Automatic updates are DISABLED' -ForegroundColor Yellow; $issues.Add('Office automatic updates disabled') }
  Write-Host 'Products       :'
  foreach ($p in ("$($cfg.ProductReleaseIds)" -split ',' | Where-Object { $_ })) { Write-Host "  $p" }
  if ("$($cfg.SharedComputerLicensing)" -eq '1') { Write-Host 'Shared computer activation: ON (RDS/shared PC licensing)' }
  $st = & $regValues "$c2rKey\UpdateStatus"
  $upd = & $regValues "$c2rKey\Updates"
  $lastResult = if ($st -and $st.LastUpdateResult) { $st.LastUpdateResult } else { 'not recorded' }
  $lastApplied = if ($st) { & $c2rTime $st.UpdateFinalizeEndTime }
  if (-not $lastApplied -and $upd) { $lastApplied = & $c2rTime $upd.UpdatesAppliedTime }
  $lastCheck = if ($upd) { & $c2rTime $upd.UpdateDetectionLastRunTime }
  Write-Host "Last update    : $lastResult$(if ($lastApplied) { " (finished $lastApplied)" })"
  Write-Host "Last check     : $(if ($lastCheck) { $lastCheck } else { 'not recorded' })"
  if ($lastResult -notmatch 'Success|not recorded') { $issues.Add("Last Office update result: $lastResult") }
  if ($upd -and $upd.BlockedReason) { Write-Host "  Update blocked: $($upd.BlockedReason)" -ForegroundColor Yellow; $issues.Add("Office update blocked: $($upd.BlockedReason)") }
}

# ---------------- Licensing / activation ----------------
Write-Host ''
Write-Host '--- Licensing & signed-in accounts ---' -ForegroundColor Cyan
$licDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Office\Licenses'
$licCount = @(Get-ChildItem -Path $licDir -Recurse -File -ErrorAction SilentlyContinue).Count
$vnextKeys = @('HKCU:\Software\Microsoft\Office\16.0\Common\Licensing\LicensingNext', 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Common\Licensing\LicensingNext') | Where-Object { Test-Path $_ }
$licensingKey = @('HKCU:\Software\Microsoft\Office\16.0\Common\Licensing', 'HKLM:\SOFTWARE\Microsoft\Office\16.0\Common\Licensing') | Where-Object { Test-Path $_ }
Write-Host "vNext license files : $licCount (in $licDir)"
if ($licCount -gt 0 -or $vnextKeys) { Write-Host 'Licensing mode      : vNext (Microsoft 365 subscription / device-based)' }
elseif ($licensingKey) { Write-Host 'Licensing mode      : Licensing key present but no vNext licenses - may be volume/retail (legacy) activation, or the user has not signed in yet' -ForegroundColor Yellow }
elseif ($officeInstalled) { Write-Host 'Licensing mode      : no licensing data for this user - Office has probably never been activated/signed in under this profile' -ForegroundColor Yellow }
$idKey = "$officeKey\Common\Identity\Identities"
$ids = @(Get-ChildItem -Path $idKey -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue } | Where-Object { $_.EmailAddress } |
    Select-Object @{N = 'Email'; E = { $_.EmailAddress } }, @{N = 'Provider'; E = { switch -Regex ("$($_.ProviderId)") { '^AD$' { 'Work/school (Entra ID)' } '^OrgId$' { 'Work/school (OrgId)' } '^LiveId$' { 'Personal Microsoft account' } default { "$($_.ProviderId)" } } } } |
    Sort-Object Email, Provider -Unique)
if ($ids.Count) {
  Write-Host 'Signed-in Office accounts:'
  $ids | ForEach-Object { Write-Host "  $($_.Email)  [$($_.Provider)]" }
} else {
  Write-Host 'Signed-in Office accounts: none found for this user' -ForegroundColor $(if ($officeInstalled) { 'Yellow' } else { 'Gray' })
}

# ---------------- Outlook ----------------
Write-Host ''
Write-Host '--- Outlook ---' -ForegroundColor Cyan
$profiles = @(Get-ChildItem -Path "$officeKey\Outlook\Profiles" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty PSChildName)
$defaultProfile = (& $regValues "$officeKey\Outlook").DefaultProfile
if ($profiles.Count) {
  Write-Host 'Profiles:'
  $profiles | ForEach-Object { Write-Host "  $_$(if ($_ -eq $defaultProfile) { '  (default)' })" }
} else { Write-Host 'Profiles: none (classic Outlook not set up for this user)' }
$newOutlook = Get-AppxPackage -Name 'Microsoft.OutlookForWindows' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($newOutlook) { Write-Host "New Outlook      : installed ($($newOutlook.Version))" }
$dataDirs = @((Join-Path $env:LOCALAPPDATA 'Microsoft\Outlook'), (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Outlook Files')) | Select-Object -Unique
$dataFiles = @(foreach ($dir in $dataDirs) { Get-ChildItem -Path $dir -Recurse -File -Include '*.ost', '*.pst' -ErrorAction SilentlyContinue })
if ($dataFiles.Count) {
  Write-Host 'Data files:'
  foreach ($f in ($dataFiles | Sort-Object Length -Descending)) {
    $gb = [math]::Round($f.Length / 1GB, 2)
    $limit = if ($f.Extension -eq '.ost') { $maxOstGB } else { $maxPstGB }
    $line = '  {0,8} GB  {1}' -f $gb, $f.FullName
    if ($gb -gt $limit) {
      Write-Host "$line  <- LARGE (> $limit GB) - slows Outlook; archive/cleanup mailbox or reduce cached mode sync window" -ForegroundColor Yellow
      $issues.Add("Large $($f.Extension.TrimStart('.').ToUpper()) $gb GB: $($f.Name)")
    } else { Write-Host $line }
  }
} else { Write-Host 'Data files: no .ost/.pst files found in the default locations' }

# ---------------- Teams ----------------
Write-Host ''
Write-Host '--- Teams ---' -ForegroundColor Cyan
$classicExe = Join-Path $env:LOCALAPPDATA 'Microsoft\Teams\current\Teams.exe'
$classic = if (Test-Path -LiteralPath $classicExe) { (Get-Item -LiteralPath $classicExe).VersionInfo.FileVersion } else { $null }
$mwi = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall') | ForEach-Object {
  Get-ChildItem -Path $_ -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue } } | Where-Object { $_.DisplayName -eq 'Teams Machine-Wide Installer' } | Select-Object -First 1
$newTeams = Get-AppxPackage -Name 'MSTeams' -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host "New Teams            : $(if ($newTeams) { "installed ($($newTeams.Version))" } else { 'not installed for this user' })"
Write-Host "Classic Teams        : $(if ($classic) { "installed ($classic)" } else { 'not installed for this user' })"
if ($mwi) { Write-Host "Teams Machine-Wide Installer: present ($($mwi.DisplayVersion))" }
if ($classic -or $mwi) {
  Write-Host '  Classic Teams is retired - remove it (and the Machine-Wide Installer) and use new Teams.' -ForegroundColor Yellow
  $issues.Add('Classic Teams still installed')
}
if (-not $newTeams -and -not $classic) { Write-Host '  Teams is not installed for this user.' -ForegroundColor Yellow }

# ---------------- Summary ----------------
Write-Host ''
if ($issues.Count) {
  Write-Host "Items to review ($($issues.Count)):" -ForegroundColor Yellow
  $issues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
} else {
  Write-Host 'No Microsoft 365 problems found.' -ForegroundColor Green
}
