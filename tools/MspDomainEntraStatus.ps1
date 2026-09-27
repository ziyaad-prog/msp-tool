# ---------------- Settings ----------------
# Intune MDM enrollments are listed under this key; an Intune enrollment has ProviderID 'MS DM Server'
$enrollmentsKey = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
$intuneProviderId = 'MS DM Server'
# Warn when the device certificate expires within this many days
$certWarnDays = 30
# ------------------------------------------

function ConvertFrom-DsregOutput {
  # dsregcmd /status prints '| Section |' banners followed by 'Key : Value' lines.
  # Returns an ordered dictionary: section name -> ordered dictionary of key -> value (first occurrence wins).
  param([string[]]$Lines)
  $sections = [ordered]@{}
  $current = 'General'
  foreach ($raw in $Lines) {
    $line = "$raw"
    if ($line -match '^\s*\|\s*(.+?)\s*\|\s*$') {
      $current = $matches[1]
      if (-not $sections.Contains($current)) { $sections[$current] = [ordered]@{} }
      continue
    }
    if ($line -match '^\s*([A-Za-z][A-Za-z0-9 _\-\(\)/\.]*?)\s*:\s?(.*)$') {
      $k = $matches[1].Trim(); $v = $matches[2].Trim()
      if (-not $sections.Contains($current)) { $sections[$current] = [ordered]@{} }
      if (-not $sections[$current].Contains($k)) { $sections[$current][$k] = $v }
    }
  }
  return $sections
}

function Get-DsregValue {
  # First non-empty value for any of the given keys, searching the preferred section first, then all sections
  param($Sections, [string[]]$Keys, [string]$Section)
  $order = @()
  if ($Section -and $Sections.Contains($Section)) { $order += $Section }
  $order += @($Sections.Keys | Where-Object { $_ -ne $Section })
  foreach ($k in $Keys) {
    foreach ($s in $order) {
      if ($Sections[$s].Contains($k) -and "$($Sections[$s][$k])".Trim()) { return "$($Sections[$s][$k])".Trim() }
    }
  }
  return $null
}

function ConvertFrom-DsregTime {
  # e.g. '2026-09-26 10:12:13.000 UTC' -> local [datetime], or $null
  param([string]$Text)
  if (-not $Text) { return $null }
  $t = ($Text -replace '\s*UTC\s*$', '').Trim()
  $fmts = [string[]]@('yyyy-MM-dd HH:mm:ss.fff', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm:ss.ffffff')
  $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
  $dt = [datetime]::MinValue
  if ([datetime]::TryParseExact($t, $fmts, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt)) { return $dt.ToLocalTime() }
  return $null
}

function Test-Yes { param($Value) return ("$Value".Trim() -eq 'YES') }

Write-Host '=== Entra ID / Intune Join Status ===' -ForegroundColor Cyan
Write-Host "Computer: $env:COMPUTERNAME"
Write-Host ''

try {
  $raw = @(dsregcmd /status)
} catch {
  Write-Host "Could not run dsregcmd: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host 'dsregcmd is available on Windows 10 / Server 2016 and later.'
  return
}
if (-not ($raw -join '').Trim()) { Write-Host 'dsregcmd /status returned no output.' -ForegroundColor Red; return }

$ds = ConvertFrom-DsregOutput -Lines $raw
$isSystem = $false
try { $isSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem } catch { }

$aadJoined = Test-Yes (Get-DsregValue $ds 'AzureAdJoined' 'Device State')
$domJoined = Test-Yes (Get-DsregValue $ds 'DomainJoined' 'Device State')
$entJoined = Test-Yes (Get-DsregValue $ds 'EnterpriseJoined' 'Device State')
$wpJoined = Test-Yes (Get-DsregValue $ds 'WorkplaceJoined' 'User State')
$domainName = Get-DsregValue $ds 'DomainName' 'Device State'
$tenantName = Get-DsregValue $ds @('TenantName', 'WorkplaceTenantName') 'Tenant Details'
$tenantId = Get-DsregValue $ds @('TenantId', 'WorkplaceTenantId') 'Tenant Details'
$deviceId = Get-DsregValue $ds @('DeviceId', 'WorkplaceDeviceId') 'Device Details'
$certText = Get-DsregValue $ds 'DeviceCertificateValidity' 'Device Details'
$authStatus = Get-DsregValue $ds 'DeviceAuthStatus' 'Device Details'
$tpm = Get-DsregValue $ds 'TpmProtected' 'Device Details'
$prt = Get-DsregValue $ds 'AzureAdPrt' 'SSO State'
$prtUpdate = Get-DsregValue $ds 'AzureAdPrtUpdateTime' 'SSO State'
$prtExpiry = Get-DsregValue $ds 'AzureAdPrtExpiryTime' 'SSO State'
$mdmUrl = Get-DsregValue $ds @('MdmUrl', 'WorkplaceMdmUrl') 'Tenant Details'
$ngcSet = Get-DsregValue $ds 'NgcSet' 'User State'
$ngcPreReq = Get-DsregValue $ds 'PreReqResult' 'Ngc Prerequisite Check'

# Join type
if ($aadJoined -and $domJoined) { $joinType = 'Hybrid Entra joined' }
elseif ($aadJoined) { $joinType = 'Entra joined' }
elseif ($entJoined) { $joinType = 'Enterprise joined (on-prem DRS)' }
elseif ($domJoined) { $joinType = 'Domain joined only (NOT Entra/hybrid joined)' }
elseif ($wpJoined) { $joinType = 'Entra registered only (WorkplaceJoined, not Entra joined)' }
else { $joinType = 'Not joined to Entra ID or a domain' }

# Device certificate validity: '[ start -- end ]'
$certStart = $null; $certEnd = $null
if ($certText -match '\[\s*(.+?)\s*--\s*(.+?)\s*\]') { $certStart = ConvertFrom-DsregTime $matches[1]; $certEnd = ConvertFrom-DsregTime $matches[2] }

# PRT
$prtUpdateDt = ConvertFrom-DsregTime $prtUpdate
$prtExpiryDt = ConvertFrom-DsregTime $prtExpiry
$prtValid = (Test-Yes $prt) -and (-not $prtExpiryDt -or $prtExpiryDt -gt (Get-Date))

# Intune enrollment (registry)
$intuneEnrollments = @()
try {
  if (Test-Path $enrollmentsKey) {
    foreach ($k in @(Get-ChildItem -Path $enrollmentsKey -ErrorAction Stop)) {
      $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
      if ($p -and "$($p.ProviderID)" -eq $intuneProviderId) {
        $intuneEnrollments += [pscustomobject]@{ Id = $k.PSChildName; UPN = "$($p.UPN)"; State = "$($p.EnrollmentState)"; Type = "$($p.EnrollmentType)" }
      }
    }
  }
} catch {
  Write-Host "Could not read $enrollmentsKey : $($_.Exception.Message)" -ForegroundColor Yellow
}
$mdmIsIntune = $mdmUrl -and $mdmUrl -match 'manage\.microsoft\.com'
$intuneEnrolled = $mdmIsIntune -or $intuneEnrollments.Count -gt 0

# ---------------- Summary ----------------
function Write-Field { param([string]$Label, $Value, [string]$Color) $v = if ($null -eq $Value -or "$Value" -eq '') { '-' } else { "$Value" }; if ($Color) { Write-Host ('  {0,-28} {1}' -f $Label, $v) -ForegroundColor $Color } else { Write-Host ('  {0,-28} {1}' -f $Label, $v) } }
function Get-YesNoColor { param([bool]$Good) if ($Good) { 'Green' } else { 'Yellow' } }

Write-Host '--- Join state ---' -ForegroundColor Cyan
Write-Field 'AzureAdJoined (Entra)' $(if ($aadJoined) { 'YES' } else { 'NO' }) (Get-YesNoColor $aadJoined)
Write-Field 'DomainJoined (AD)' $(if ($domJoined) { "YES$(if ($domainName) { " ($domainName)" })" } else { 'NO' })
Write-Field 'EnterpriseJoined' $(if ($entJoined) { 'YES' } else { 'NO' })
Write-Field 'WorkplaceJoined (registered)' $(if ($wpJoined) { 'YES' } else { 'NO' })
Write-Field 'Join type' $joinType
Write-Field 'Tenant name' $tenantName
Write-Field 'Tenant ID' $tenantId
Write-Field 'Device ID' $deviceId
if ($certText) {
  $certColor = if ($certEnd -and $certEnd -lt (Get-Date)) { 'Red' } elseif ($certEnd -and $certEnd -lt (Get-Date).AddDays($certWarnDays)) { 'Yellow' } else { 'Green' }
  $certShow = if ($certEnd) { '{0} to {1}' -f $(if ($certStart) { $certStart.ToString('yyyy-MM-dd') } else { '?' }), $certEnd.ToString('yyyy-MM-dd') } else { $certText }
  Write-Field 'Device certificate' $certShow $certColor
}
if ($tpm) { Write-Field 'Key TPM protected' $tpm }
if ($authStatus) { Write-Field 'DeviceAuthStatus' $authStatus $(if ($authStatus -eq 'SUCCESS') { 'Green' } else { 'Red' }) }

Write-Host ''
Write-Host '--- Sign-in (current user) ---' -ForegroundColor Cyan
Write-Field 'AzureAdPrt' $(if ($prt) { $prt } else { '-' }) (Get-YesNoColor $prtValid)
if ($prtUpdateDt) { Write-Field 'PRT last updated' $prtUpdateDt.ToString('yyyy-MM-dd HH:mm') } elseif ($prtUpdate) { Write-Field 'PRT last updated' $prtUpdate }
if ($prtExpiryDt) { Write-Field 'PRT expires' $prtExpiryDt.ToString('yyyy-MM-dd HH:mm') }
Write-Field 'Windows Hello (NgcSet)' $ngcSet
if ($ngcPreReq) { Write-Field 'Hello provisioning' $ngcPreReq }
if ($isSystem) { Write-Host '  Note: running as SYSTEM - user/PRT values describe SYSTEM, not the signed-in user. Run in the user''s context to check their PRT.' -ForegroundColor Yellow }

Write-Host ''
Write-Host '--- Intune / MDM ---' -ForegroundColor Cyan
Write-Field 'MDM URL' $mdmUrl
if ($intuneEnrollments.Count) {
  foreach ($en in $intuneEnrollments) { Write-Field 'Intune enrollment' ("{0}{1}" -f $(if ($en.UPN) { $en.UPN } else { '(device)' }), $(if ($en.State) { " (state $($en.State))" } else { '' })) 'Green' }
} else {
  Write-Field 'Intune enrollment' 'none found in registry' 'Yellow'
}

# Diagnostic errors reported by dsregcmd (only non-empty, non-success values)
$diag = @()
foreach ($s in $ds.Keys) {
  if ($s -notmatch 'Diagnostic') { continue }
  foreach ($k in $ds[$s].Keys) {
    $v = "$($ds[$s][$k])"
    if ($k -match 'Error|Recovery|Result|Attempt Status' -and $v -and $v -notmatch '^(0x0|0|NO|SUCCESS|none|NOT SET|-)$') { $diag += ('{0}: {1}' -f $k, $v) }
  }
}
if ($diag.Count) {
  Write-Host ''
  Write-Host '--- dsregcmd diagnostics ---' -ForegroundColor Cyan
  foreach ($d in $diag) { Write-Host "  $d" -ForegroundColor Yellow }
}

# ---------------- Verdict ----------------
$parts = @($joinType)
if ($aadJoined -or $entJoined -or $wpJoined) {
  $parts += $(if ($intuneEnrolled) { 'Intune enrolled' } else { 'NOT Intune enrolled' })
  if ($aadJoined) { $parts += $(if ($prtValid) { 'PRT valid' } elseif (Test-Yes $prt) { 'PRT EXPIRED' } else { 'no PRT' }) }
} elseif ($intuneEnrolled) { $parts += 'Intune enrolled' }
$healthy = ($aadJoined -and $intuneEnrolled -and $prtValid)
Write-Host ''
Write-Host "VERDICT: $($parts -join ', ')" -ForegroundColor $(if ($healthy) { 'Green' } else { 'Yellow' })

# ---------------- Hints ----------------
$hints = @()
if ($domJoined -and -not $aadJoined) {
  $hints += 'Domain joined but not hybrid joined: check Entra Connect device sync / SCP, and the scheduled task Microsoft\Windows\Workplace Join\Automatic-Device-Join. Run "dsregcmd /join" as SYSTEM if needed.'
}
if ($aadJoined -and -not $prtValid) {
  $hints += 'No valid PRT: the user''s Entra sign-in token is missing - have the user lock/unlock or sign out and back in with their work account; check Event Viewer > Applications and Services > Microsoft > Windows > AAD.'
}
if (($aadJoined -or $entJoined) -and -not $intuneEnrolled) {
  $hints += 'Not Intune enrolled: check Intune auto-enrollment (Entra > Mobility (MDM and MAM) > MDM user scope), the user''s Intune license, and for hybrid the GPO "Enable automatic MDM enrollment using default Azure AD credentials".'
}
if ($certEnd -and $certEnd -lt (Get-Date)) { $hints += 'Device certificate has EXPIRED: the device must be re-joined/re-registered.' }
if ($authStatus -and $authStatus -ne 'SUCCESS') { $hints += 'DeviceAuthStatus is not SUCCESS: the device may be deleted or disabled in Entra ID - check the device object in the Entra portal.' }
if (-not $aadJoined -and -not $domJoined -and $wpJoined) {
  $hints += 'Only Entra registered (WorkplaceJoined): typical for BYOD/personal PCs. Full SSO and Intune device policies need Entra join or hybrid join.'
}
if (-not $aadJoined -and -not $domJoined -and -not $wpJoined -and -not $entJoined) { $hints += 'Device is not joined or registered anywhere - it will not get Entra SSO or Intune policies.' }
if ($hints.Count) {
  Write-Host ''
  Write-Host '--- Hints ---' -ForegroundColor Cyan
  foreach ($h in $hints) { Write-Host "  - $h" -ForegroundColor Yellow }
}

# ---------------- Save raw output ----------------
Write-Host ''
$save = Read-Host 'Save the raw dsregcmd output to the reports folder? (y/N)'
if ($save -match '^(y|yes)$') {
  try {
    $reportDir = Join-Path $env:USERPROFILE 'Desktop\MSP-Reports'
    if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
    $file = Join-Path $reportDir "dsregcmd-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    $raw | Set-Content -Path $file -Encoding UTF8
    Write-Host "Saved: $file" -ForegroundColor Green
  } catch {
    Write-Host "[FAIL] Could not save the report: $($_.Exception.Message)" -ForegroundColor Red
  }
}
