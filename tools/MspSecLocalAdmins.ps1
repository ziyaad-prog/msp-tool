# Audit Local Administrators - lists members, flags unexpected ones, reports LAPS status, and can reset a local admin password.
# LAPS passwords are NEVER read or printed.

# --- Allow-list: members not matching any of these are flagged WARN ---
# Always expected: the built-in Administrator (RID 500), Domain Admins (RID 512), and the LAPS-managed account (read from policy).
# Add client/MSP-specific names here (match on the full name 'DOMAIN\name' or just 'name'; wildcards allowed), e.g. 'LENET-Admin', 'CONTOSO\IT Support'.
$extraAllowedAdmins = @()
# Entra ID joined devices add the Global Administrator / Azure AD Joined Device Local Administrator roles as unresolved SIDs (S-1-12-1-...)
$allowEntraRoleSids = $true

$windowsLapsKeys = [ordered]@{
  'Intune/CSP policy' = 'HKLM:\SOFTWARE\Microsoft\Policies\LAPS'
  'Group Policy'      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS'
  'Local config'      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\LAPS\Config'
}
$legacyLapsKey = 'HKLM:\SOFTWARE\Policies\Microsoft Services\AdmPwd'
$legacyLapsDll = Join-Path $env:ProgramFiles 'LAPS\CSE\AdmPwd.dll'
$lapsLog = 'Microsoft-Windows-LAPS/Operational'
# Windows LAPS events (IDs verified against the Microsoft-Windows-LAPS provider manifest)
$lapsSuccess = @{ 10018 = 'password backed up to Active Directory'; 10029 = 'password backed up to Entra ID'; 10020 = 'local account password updated' }
$lapsFailure = @{ 10017 = 'FAILED to back up password to Active Directory'; 10028 = 'FAILED to back up password to Entra ID'; 10019 = 'FAILED to update the local account password' }

function Get-RegValue {
  param([string]$Path, [string]$Name)
  try { $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop; return $item.$Name } catch { return $null }
}

# --- LAPS status ---
$lapsAccount = $null
$lapsLines = [System.Collections.Generic.List[object]]::new()
$winLapsSource = $null
foreach ($src in $windowsLapsKeys.Keys) {
  $bd = Get-RegValue $windowsLapsKeys[$src] 'BackupDirectory'
  if ($null -ne $bd) { $winLapsSource = $src; break }
}
$winLapsAvailable = [bool](Get-Command Get-LapsDiagnostics -ErrorAction SilentlyContinue) -or (Test-Path (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules\LAPS'))
if ($winLapsSource) {
  $key = $windowsLapsKeys[$winLapsSource]
  $bdName = switch ("$bd") { '0' { 'Disabled (no backup)' } '1' { 'Entra ID' } '2' { 'Active Directory' } default { "unknown ($bd)" } }
  $lapsAccount = Get-RegValue $key 'AdministratorAccountName'
  $age = Get-RegValue $key 'PasswordAgeDays'
  $lapsLines.Add(@(("Windows LAPS: configured by {0}, backup to {1}, managed account: {2}{3}" -f $winLapsSource, $bdName, $(if ($lapsAccount) { $lapsAccount } else { 'built-in Administrator' }), $(if ($age) { ", rotate every $age days" } else { '' })), $(if ("$bd" -in '1', '2') { 'Green' } else { 'Yellow' })))
} else {
  $lapsLines.Add(@(("Windows LAPS: no policy found{0}" -f $(if ($winLapsAvailable) { ' (feature present in this OS)' } else { ' (feature not detected - needs the April 2023+ cumulative update)' })), 'Yellow'))
}
try {
  $lapsEvents = @(Get-WinEvent -FilterHashtable @{ LogName = $lapsLog; Id = @($lapsSuccess.Keys) + @($lapsFailure.Keys) } -MaxEvents 50 -ErrorAction Stop | Sort-Object TimeCreated -Descending)
} catch { $lapsEvents = @() }
$lastOk = $lapsEvents | Where-Object { $lapsSuccess.ContainsKey([int]$_.Id) } | Select-Object -First 1
$lastBad = $lapsEvents | Where-Object { $lapsFailure.ContainsKey([int]$_.Id) } | Select-Object -First 1
if ($lastOk) { $lapsLines.Add(@(("  Last successful update: {0:yyyy-MM-dd HH:mm} - {1} (event {2})" -f $lastOk.TimeCreated, $lapsSuccess[[int]$lastOk.Id], $lastOk.Id), 'Green')) }
elseif ($winLapsSource) { $lapsLines.Add(@("  No successful LAPS password update event found in $lapsLog.", 'Yellow')) }
if ($lastBad -and (-not $lastOk -or $lastBad.TimeCreated -gt $lastOk.TimeCreated)) { $lapsLines.Add(@(("  Latest FAILURE: {0:yyyy-MM-dd HH:mm} - {1} (event {2})" -f $lastBad.TimeCreated, $lapsFailure[[int]$lastBad.Id], $lastBad.Id), 'Red')) }

$legacyEnabled = Get-RegValue $legacyLapsKey 'AdmPwdEnabled'
$legacyDll = Test-Path $legacyLapsDll
if ($legacyDll -or $null -ne $legacyEnabled) {
  $legacyAccount = Get-RegValue $legacyLapsKey 'AdminAccountName'
  if (-not $lapsAccount -and $legacyAccount) { $lapsAccount = $legacyAccount }
  $mode = if (-not $legacyDll -and "$legacyEnabled" -eq '1') { ' - CSE not installed, Windows LAPS may be running in legacy emulation mode' } else { '' }
  $lapsLines.Add(@(("Legacy Microsoft LAPS: CSE {0}, policy {1}, managed account: {2}{3}" -f $(if ($legacyDll) { 'installed' } else { 'not installed' }), $(if ("$legacyEnabled" -eq '1') { 'ENABLED' } elseif ($null -eq $legacyEnabled) { 'not configured' } else { 'disabled' }), $(if ($legacyAccount) { $legacyAccount } else { 'built-in Administrator' }), $mode), $(if ("$legacyEnabled" -eq '1') { 'Green' } else { 'Yellow' })))
} else {
  $lapsLines.Add(@('Legacy Microsoft LAPS: not installed', 'Gray'))
}
$lapsActive = ("$bd" -in '1', '2' -and $winLapsSource) -or "$legacyEnabled" -eq '1'

# --- Members ---
$admins = $null
try { $admins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue } catch { }
if (-not $admins) {
  # Native command: run with Continue so a line on stderr doesn't abort the tool before the LAPS section
  & { $ErrorActionPreference = 'Continue'; net localgroup Administrators 2>&1 } | ForEach-Object { Write-Host "$_" }
  Write-Host ''
  Write-Host '--- LAPS ---' -ForegroundColor Cyan
  foreach ($l in $lapsLines) { Write-Host $l[0] -ForegroundColor $l[1] }
  return
}
$admins = @($admins)
$localAdmins = @($admins | Where-Object { $_.ObjectClass -eq 'User' -and $_.PrincipalSource -eq 'Local' })
$admins | Select-Object Name, ObjectClass, PrincipalSource | Format-Table -AutoSize | Out-String | Write-Host

Write-Host '--- Membership review ---' -ForegroundColor Cyan
$unexpected = 0
foreach ($m in $admins) {
  $sid = "$($m.SID)"
  $short = ($m.Name -split '\\')[-1]
  $why = $null
  if ($sid -match '^S-1-5-21-.*-500$') { $why = 'built-in Administrator' }
  elseif ($sid -match '^S-1-5-21-.*-512$') { $why = 'Domain Admins' }
  elseif ($lapsAccount -and $short -eq $lapsAccount) { $why = 'LAPS-managed account' }
  elseif ($allowEntraRoleSids -and $sid -like 'S-1-12-1-*') { $why = 'Entra ID role (Global Admin / Device Local Admin)' }
  else { foreach ($a in $extraAllowedAdmins) { if ($m.Name -like $a -or $short -like $a) { $why = "allow-list ($a)" } } }
  if ($why) { Write-Host ("[OK]   {0} - {1}" -f $m.Name, $why) -ForegroundColor Green }
  else { $unexpected++; Write-Host ("[WARN] {0} ({1}, {2}) - not on the allow-list, confirm it needs admin rights" -f $m.Name, $m.ObjectClass, $m.PrincipalSource) -ForegroundColor Yellow }
}
if ($unexpected) { Write-Host "$unexpected unexpected member(s). Add legitimate ones to `$extraAllowedAdmins at the top of this tool." -ForegroundColor Yellow }

try {
  $builtin = Get-LocalUser -ErrorAction Stop | Where-Object { "$($_.SID)" -match '-500$' } | Select-Object -First 1
  if ($builtin) {
    if ($builtin.Enabled) {
      $lapsManaged = $lapsActive -and (-not $lapsAccount -or $lapsAccount -eq $builtin.Name)
      Write-Host ("Built-in Administrator '{0}' is ENABLED{1}" -f $builtin.Name, $(if ($lapsManaged) { ' (password managed by LAPS)' } else { ' - disable it unless LAPS manages it' })) -ForegroundColor $(if ($lapsManaged) { 'Green' } else { 'Yellow' })
    } else {
      Write-Host ("Built-in Administrator '{0}' is disabled" -f $builtin.Name) -ForegroundColor Green
    }
  }
} catch { Write-Host "Could not read the built-in Administrator state: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host ''
Write-Host '--- LAPS ---' -ForegroundColor Cyan
foreach ($l in $lapsLines) { Write-Host $l[0] -ForegroundColor $l[1] }
if (-not $lapsActive) { Write-Host 'No active LAPS policy: local admin passwords are not rotated automatically.' -ForegroundColor Yellow }

# --- Password reset ---
Write-Host ''
$answer = Read-Host 'Do you want to reset the password for one of these local administrator accounts? (y/N)'
if ($answer -notmatch '^[Yy]') { return }
if (-not $localAdmins) { Write-Host 'No local user accounts were found in the Administrators group.' -ForegroundColor Yellow; return }
if ($lapsActive) { Write-Host 'Note: LAPS manages a local admin password on this PC - a manual reset of that account is overwritten at the next rotation.' -ForegroundColor Yellow }
Write-Host ''
for ($i = 0; $i -lt $localAdmins.Count; $i++) {
  Write-Host ("  [{0}] {1}" -f ($i + 1), $localAdmins[$i].Name)
}
Write-Host ''
$choice = Read-Host 'Select the account number to reset'
if (-not $choice) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
if ($choice -notmatch '^\d+$') { Write-Host 'Invalid selection.' -ForegroundColor Yellow; return }
$index = [int]$choice - 1
if ($index -lt 0 -or $index -ge $localAdmins.Count) { Write-Host 'Invalid selection.' -ForegroundColor Yellow; return }
$userName = $localAdmins[$index].Name
$secure = Read-Host ("Enter new password for {0}" -f $userName) -AsSecureString
if (-not $secure -or $secure.Length -eq 0) { Write-Host 'No password entered. Cancelled.' -ForegroundColor Yellow; return }
try {
  # The SecureString is passed straight through (never converted to plain text); -SID avoids 'COMPUTER\name' lookup issues
  Set-LocalUser -SID $localAdmins[$index].SID -Password $secure -ErrorAction Stop
  Write-Host ("Password updated for {0}" -f $userName) -ForegroundColor Green
} catch {
  Write-Host ("Failed to update password for {0}: {1}" -f $userName, $_.Exception.Message) -ForegroundColor Red
}
