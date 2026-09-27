# Security Baseline Scorecard - read-only. Each check is PASS / WARN / FAIL / N/A with a one-line fix hint.
# Nothing on the machine is changed. Checks that need elevation are shown as 'N/A (needs admin)' when not elevated.

# --- Tunables ---
$minPasswordLengthPass = 12     # min password length >= this = PASS
$minPasswordLengthWarn = 8      # >= this (but below the PASS value) = WARN, below = FAIL
$maxSignatureAgeDays   = 3      # Defender signatures older than this = FAIL
$maxAdminMembers       = 2      # more members than this in local Administrators = WARN
$supportWarnDays       = 60     # OS support ending within this many days = WARN
# Windows builds -> end of support (keep simple; update when Microsoft publishes new dates).
# Consumer = Home/Pro/Pro Workstation; Enterprise = Enterprise/Education/IoT Enterprise.
$osSupportTable = @(
  [pscustomobject]@{ Build = 19044; Type = 'Client'; Name = 'Windows 10 21H2 / LTSC 2021'; Consumer = '2023-06-13'; Enterprise = '2027-01-12' }
  [pscustomobject]@{ Build = 19045; Type = 'Client'; Name = 'Windows 10 22H2';            Consumer = '2025-10-14'; Enterprise = '2025-10-14' }
  [pscustomobject]@{ Build = 17763; Type = 'Client'; Name = 'Windows 10 LTSC 2019';       Consumer = '2029-01-09'; Enterprise = '2029-01-09' }
  [pscustomobject]@{ Build = 22000; Type = 'Client'; Name = 'Windows 11 21H2';            Consumer = '2023-10-10'; Enterprise = '2024-10-08' }
  [pscustomobject]@{ Build = 22621; Type = 'Client'; Name = 'Windows 11 22H2';            Consumer = '2024-10-08'; Enterprise = '2025-10-14' }
  [pscustomobject]@{ Build = 22631; Type = 'Client'; Name = 'Windows 11 23H2';            Consumer = '2025-11-11'; Enterprise = '2026-11-10' }
  [pscustomobject]@{ Build = 26100; Type = 'Client'; Name = 'Windows 11 24H2';            Consumer = '2026-10-13'; Enterprise = '2027-10-12' }
  [pscustomobject]@{ Build = 26200; Type = 'Client'; Name = 'Windows 11 25H2';            Consumer = '2027-10-12'; Enterprise = '2028-10-10' }
  [pscustomobject]@{ Build = 14393; Type = 'Server'; Name = 'Windows Server 2016';        Consumer = '2027-01-12'; Enterprise = '2027-01-12' }
  [pscustomobject]@{ Build = 17763; Type = 'Server'; Name = 'Windows Server 2019';        Consumer = '2029-01-09'; Enterprise = '2029-01-09' }
  [pscustomobject]@{ Build = 20348; Type = 'Server'; Name = 'Windows Server 2022';        Consumer = '2031-10-14'; Enterprise = '2031-10-14' }
  [pscustomobject]@{ Build = 26100; Type = 'Server'; Name = 'Windows Server 2025';        Consumer = '2034-11-14'; Enterprise = '2034-11-14' }
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$results = [System.Collections.Generic.List[object]]::new()
function Add-Check {
  param([string]$Check, [string]$Status, [string]$Detail, [string]$Fix = '')
  if ($Status -eq 'PASS') { $Fix = '' }
  $results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail; Fix = $Fix })
}
function Get-RegValue {
  param([string]$Path, [string]$Name)
  try { $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop; return $item.$Name } catch { return $null }
}
$na = 'N/A (needs admin)'

Write-Host '--- Security Baseline Scorecard ---' -ForegroundColor Cyan
if (-not $isAdmin) { Write-Host 'Not elevated: checks that need admin are marked N/A (needs admin).' -ForegroundColor Yellow }
Write-Host 'Running checks...'

# 1. SMBv1
$name = 'SMBv1 disabled'
try {
  $smb1 = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol
  $feature = $null
  if ($isAdmin) { try { $feature = (Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction Stop).State } catch { } }
  if ($smb1) { Add-Check $name 'FAIL' 'SMBv1 server protocol is enabled' 'Set-SmbServerConfiguration -EnableSMB1Protocol $false; Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol' }
  elseif ("$feature" -eq 'Enabled') { Add-Check $name 'WARN' 'SMBv1 server off, but the SMB1Protocol feature (client) is still installed' 'Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol (restart required)' }
  else { Add-Check $name 'PASS' $(if ($feature) { "SMBv1 server off; SMB1Protocol feature: $feature" } else { 'SMBv1 server protocol is off' }) }
} catch {
  Add-Check $name 'WARN' "Could not query SMB server configuration: $($_.Exception.Message)" 'Check manually: Get-SmbServerConfiguration | Select EnableSMB1Protocol'
}

# 2. RDP
$name = 'RDP disabled or NLA required'
$polTs = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$deny = Get-RegValue $polTs 'fDenyTSConnections'
if ($null -eq $deny) { $deny = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections' }
$nla = Get-RegValue $polTs 'UserAuthentication'
if ($null -eq $nla) { $nla = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication' }
if ("$deny" -eq '1') { Add-Check $name 'PASS' 'Remote Desktop is disabled' }
elseif ("$nla" -eq '1') { Add-Check $name 'PASS' 'Remote Desktop is enabled with Network Level Authentication required' }
elseif ($null -eq $deny) { Add-Check $name 'WARN' 'Could not read the Remote Desktop setting' 'Check System Properties > Remote' }
else { Add-Check $name 'FAIL' 'Remote Desktop is enabled WITHOUT Network Level Authentication' 'System Properties > Remote > tick "Allow connections only from computers running Remote Desktop with NLA"' }

# 3. UAC
$name = 'UAC enabled'
$sysPol = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
$lua = Get-RegValue $sysPol 'EnableLUA'
$cpba = Get-RegValue $sysPol 'ConsentPromptBehaviorAdmin'
if ("$lua" -eq '0') { Add-Check $name 'FAIL' 'UAC is turned off (EnableLUA=0)' 'Set EnableLUA=1 (GPO: User Account Control: Run all administrators in Admin Approval Mode = Enabled), restart' }
elseif ("$cpba" -eq '0') { Add-Check $name 'FAIL' 'UAC on, but admins are elevated without any prompt (ConsentPromptBehaviorAdmin=0)' 'Set ConsentPromptBehaviorAdmin to 5 (default) or 2 via GPO/Control Panel > User Account Control' }
else { Add-Check $name 'PASS' ("UAC on (EnableLUA={0}, ConsentPromptBehaviorAdmin={1})" -f $(if ($null -eq $lua) { 'default' } else { $lua }), $(if ($null -eq $cpba) { 'default' } else { $cpba })) }

# 4. Guest account (found by RID 501 so a renamed Guest is still caught)
$name = 'Guest account disabled'
try {
  $guest = Get-LocalUser -ErrorAction Stop | Where-Object { "$($_.SID)" -match '-501$' } | Select-Object -First 1
  if (-not $guest) { Add-Check $name 'PASS' 'No local Guest account found' }
  elseif ($guest.Enabled) { Add-Check $name 'FAIL' "Guest account '$($guest.Name)' is ENABLED" "Disable-LocalUser -Name '$($guest.Name)'" }
  else { Add-Check $name 'PASS' "Guest account '$($guest.Name)' is disabled" }
} catch {
  Add-Check $name 'WARN' "Could not read local users (domain controller?): $($_.Exception.Message)" 'Check: net user guest'
}

# 5. AutoRun / AutoPlay
$name = 'AutoRun/AutoPlay disabled'
$autoRun = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun'
$autoSrc = 'HKLM'
if ($null -eq $autoRun) { $autoRun = Get-RegValue 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun'; $autoSrc = 'HKCU' }
$autoFix = 'GPO: Computer Config > Admin Templates > Windows Components > AutoPlay Policies > Turn off AutoPlay = All drives (NoDriveTypeAutoRun=255)'
if ($null -eq $autoRun) { Add-Check $name 'WARN' 'NoDriveTypeAutoRun not configured (Windows default still allows AutoPlay on removable/optical media)' $autoFix }
elseif ([int]$autoRun -eq 255) { Add-Check $name 'PASS' "AutoRun off for all drive types ($autoSrc NoDriveTypeAutoRun=255)" }
elseif (([int]$autoRun -band 0x24) -eq 0x24) { Add-Check $name 'PASS' ("AutoRun off for removable and optical drives ({0} NoDriveTypeAutoRun=0x{1:X2})" -f $autoSrc, [int]$autoRun) }
else { Add-Check $name 'WARN' ("AutoRun still allowed on removable/optical drives ({0} NoDriveTypeAutoRun=0x{1:X2})" -f $autoSrc, [int]$autoRun) $autoFix }

# 6. Secure Boot
$name = 'Secure Boot on'
try {
  if (Confirm-SecureBootUEFI -ErrorAction Stop) { Add-Check $name 'PASS' 'Secure Boot is enabled' }
  else { Add-Check $name 'FAIL' 'UEFI firmware, but Secure Boot is OFF' 'Enable Secure Boot in the UEFI/BIOS setup (check BitLocker recovery key first)' }
} catch [System.PlatformNotSupportedException] {
  Add-Check $name 'FAIL' 'Secure Boot not supported - legacy BIOS/CSM boot' 'Convert the disk to GPT (mbr2gpt) and switch firmware to UEFI mode, then enable Secure Boot'
} catch {
  # Unelevated: Confirm-SecureBootUEFI needs admin, but the state registry value is readable
  $sb = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'
  if ("$sb" -eq '1') { Add-Check $name 'PASS' 'Secure Boot is enabled (from registry)' }
  elseif ("$sb" -eq '0') { Add-Check $name 'FAIL' 'Secure Boot is OFF (from registry)' 'Enable Secure Boot in the UEFI/BIOS setup (check BitLocker recovery key first)' }
  elseif ($env:firmware_type -eq 'Legacy') { Add-Check $name 'FAIL' 'Legacy BIOS boot - Secure Boot not available' 'Convert to UEFI (mbr2gpt) and enable Secure Boot' }
  else { Add-Check $name 'N/A' "$na - $($_.Exception.Message)" }
}

# 7. TPM
$name = 'TPM present and ready'
if ($isAdmin) {
  try {
    $tpm = Get-Tpm -ErrorAction Stop
    if (-not $tpm.TpmPresent) { Add-Check $name 'FAIL' 'No TPM detected' 'Enable TPM/PTT/fTPM in the UEFI/BIOS setup' }
    elseif (-not $tpm.TpmReady) { Add-Check $name 'WARN' 'TPM present but NOT ready' 'Run tpm.msc > Prepare the TPM, or clear/initialise it in firmware (suspend BitLocker first)' }
    else { Add-Check $name 'PASS' 'TPM present and ready' }
  } catch { Add-Check $name 'WARN' "Could not query TPM: $($_.Exception.Message)" 'Check tpm.msc' }
} else {
  $tpmDev = $null
  try { $tpmDev = Get-CimInstance Win32_PnPEntity -Filter "PNPClass='SecurityDevices'" -ErrorAction Stop | Where-Object { $_.Name -match 'Trusted Platform' } | Select-Object -First 1 } catch { }
  Add-Check $name 'N/A' $(if ($tpmDev) { "$na - device found: $($tpmDev.Name) ($($tpmDev.Status))" } else { "$na - no TPM device visible to a standard user" })
}

# 8. BitLocker on the OS drive (status only - no keys are read)
$name = 'BitLocker on OS drive'
$osDrive = $env:SystemDrive
if ($isAdmin) {
  try {
    $bl = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction Stop
    if ("$($bl.ProtectionStatus)" -eq 'On') { Add-Check $name 'PASS' "$osDrive protected ($($bl.VolumeStatus), $($bl.EncryptionMethod))" }
    elseif ("$($bl.VolumeStatus)" -eq 'FullyEncrypted') { Add-Check $name 'WARN' "$osDrive encrypted but protection is OFF (suspended or waiting for activation)" "Resume-BitLocker -MountPoint $osDrive (or add a TPM protector), after confirming the recovery key is escrowed" }
    else { Add-Check $name 'FAIL' "$osDrive not protected ($($bl.VolumeStatus), $($bl.EncryptionPercentage)%)" 'Enable BitLocker per client policy (Intune/GPO) and escrow the recovery key to Entra ID/AD' }
  } catch { Add-Check $name 'WARN' "Could not query BitLocker: $($_.Exception.Message)" 'Run the BitLocker Status tool elevated' }
} else {
  $code = $null
  try { $code = (New-Object -ComObject Shell.Application).NameSpace(17).ParseName($osDrive).ExtendedProperty('System.Volume.BitLockerProtection') } catch { }
  switch ("$code") {
    '1' { Add-Check $name 'PASS' "$osDrive BitLocker on (Explorer status)" }
    '2' { Add-Check $name 'FAIL' "$osDrive BitLocker off (Explorer status)" 'Enable BitLocker per client policy and escrow the recovery key' }
    '3' { Add-Check $name 'WARN' "$osDrive encryption in progress (Explorer status)" 'Let encryption finish, then re-check' }
    '4' { Add-Check $name 'FAIL' "$osDrive is being DECRYPTED (Explorer status)" 'Find out who/what started decryption' }
    '5' { Add-Check $name 'WARN' "$osDrive BitLocker suspended (Explorer status)" "Resume-BitLocker -MountPoint $osDrive" }
    default { Add-Check $name 'N/A' $(if ($null -ne $code -and "$code" -ne '') { "$na - Explorer status code $code is ambiguous" } else { $na }) }
  }
}

# 9. Firewall
$name = 'Firewall on (all profiles)'
try {
  $profiles = @(Get-NetFirewallProfile -ErrorAction Stop)
  $off = @($profiles | Where-Object { -not $_.Enabled -or "$($_.Enabled)" -eq 'False' })
  if ($off.Count) { Add-Check $name 'FAIL' ("OFF: {0}" -f (($off | ForEach-Object { $_.Name }) -join ', ')) 'Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True (or fix the GPO/third-party firewall)' }
  else { Add-Check $name 'PASS' ("On: {0}" -f (($profiles | ForEach-Object { $_.Name }) -join ', ')) }
} catch { Add-Check $name 'WARN' "Could not query firewall: $($_.Exception.Message)" 'Check wf.msc' }

# 10. Defender
$name = 'Defender real-time + signatures'
try {
  $mp = Get-MpComputerStatus -ErrorAction Stop
  $sigAge = if ($mp.AntivirusSignatureLastUpdated) { [math]::Floor(((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays) } else { $mp.AntivirusSignatureAge }
  if (-not $mp.RealTimeProtectionEnabled) { Add-Check $name 'FAIL' "Real-time protection is OFF (running mode: $($mp.AMRunningMode))" 'Turn real-time protection on (check for a third-party AV or a GPO/Intune policy disabling it)' }
  elseif ($sigAge -gt $maxSignatureAgeDays) { Add-Check $name 'FAIL' "Real-time on, but signatures are $sigAge days old" 'Update-MpSignature, then check Windows Update / WSUS / internet access' }
  else { Add-Check $name 'PASS' "Real-time on, signatures $sigAge day(s) old" }
} catch {
  $avNames = ''
  try { $avNames = (@(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop) | ForEach-Object { $_.displayName }) -join ', ' } catch { }
  Add-Check $name 'WARN' ("Defender status unavailable ({0}){1}" -f $_.Exception.Message, $(if ($avNames) { "; registered AV: $avNames" } else { '' })) 'Confirm the registered antivirus is active and up to date'
}

# 11. PowerShell v2
$name = 'PowerShell v2 removed'
$ps2 = $null
if ($isAdmin) { try { $ps2 = (Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -ErrorAction Stop).State } catch { } }
if ($ps2) {
  if ("$ps2" -eq 'Enabled') { Add-Check $name 'FAIL' 'PowerShell 2.0 engine is installed (can be used to bypass logging/AMSI)' 'Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root' }
  else { Add-Check $name 'PASS' "PowerShell 2.0 feature state: $ps2" }
} else {
  $engine = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\PowerShell\1\PowerShellEngine' 'PowerShellVersion'
  if ("$engine" -like '2*') { Add-Check $name 'FAIL' "PowerShell $engine engine registered (from registry)" 'Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root' }
  else { Add-Check $name 'PASS' 'No PowerShell 2.0 engine registered (from registry)' }
}

# 12. LLMNR
$name = 'LLMNR disabled'
$mc = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast'
if ("$mc" -eq '0') { Add-Check $name 'PASS' 'LLMNR disabled by policy (EnableMulticast=0)' }
else { Add-Check $name 'WARN' $(if ($null -eq $mc) { 'Not configured - LLMNR is on (name-poisoning risk)' } else { "EnableMulticast=$mc - LLMNR is on" }) 'GPO: Computer Config > Admin Templates > Network > DNS Client > Turn off multicast name resolution = Enabled' }

# 13/14. Password policy (net accounts - local account policy; lines parsed by position so non-English output works)
try {
  $netAcc = @(net accounts 2>$null | Where-Object { $_ -match ':' })
  $valueOf = { param($label, $index) $line = $netAcc | Where-Object { $_ -match $label } | Select-Object -First 1; if (-not $line -and $netAcc.Count -gt $index) { $line = $netAcc[$index] }; if ($line) { ($line -split ':')[-1].Trim() } }
  $minLen = & $valueOf 'Minimum password length' 3
  $lockout = & $valueOf 'Lockout threshold' 5
  if ($null -eq $minLen) { throw 'net accounts returned no data' }
  $minLenNum = if ("$minLen" -match '^\d+$') { [int]$minLen } else { 0 }
  if ($minLenNum -ge $minPasswordLengthPass) { Add-Check 'Password min length' 'PASS' "Minimum length $minLenNum" }
  elseif ($minLenNum -ge $minPasswordLengthWarn) { Add-Check 'Password min length' 'WARN' "Minimum length $minLenNum (recommend $minPasswordLengthPass+)" "net accounts /minpwlen:$minPasswordLengthPass or set via domain/Intune policy" }
  else { Add-Check 'Password min length' 'FAIL' "Minimum length $minLen" "net accounts /minpwlen:$minPasswordLengthPass or set via domain/Intune policy" }
  if ("$lockout" -match '^\d+$' -and [int]$lockout -gt 0) { Add-Check 'Account lockout threshold' 'PASS' "Locks out after $lockout bad attempts" }
  else { Add-Check 'Account lockout threshold' 'FAIL' "Lockout threshold: $lockout (no lockout)" 'net accounts /lockoutthreshold:10 or set via domain/Intune policy' }
} catch {
  Add-Check 'Password policy' 'WARN' "Could not read password policy: $($_.Exception.Message)" 'Check: net accounts'
}

# 15. Local Administrators membership (group found by SID so localized names work)
$name = 'Local admin count'
try {
  $grp = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
  try {
    $members = @(Get-LocalGroupMember -Group $grp -ErrorAction Stop | ForEach-Object { $_.Name })
  } catch {
    # Get-LocalGroupMember fails on orphaned SIDs - fall back to ADSI
    $members = @(([ADSI]"WinNT://$env:COMPUTERNAME/$($grp.Name),group").psbase.Invoke('Members') | ForEach-Object { $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null) })
  }
  $list = $members -join ', '
  if ($members.Count -gt $maxAdminMembers) { Add-Check $name 'WARN' "$($members.Count) members: $list" 'Review with the Audit Local Administrators tool; remove accounts that do not need admin' }
  else { Add-Check $name 'PASS' "$($members.Count) member(s): $list" }
} catch { Add-Check $name 'WARN' "Could not read the Administrators group: $($_.Exception.Message)" 'Check: net localgroup Administrators' }

# 16. OS support
$name = 'OS still supported'
try {
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
  $build = [int]$cv.CurrentBuild
  $type = if ("$($cv.InstallationType)" -match 'Server') { 'Server' } else { 'Client' }
  $isEnt = "$($cv.EditionID)" -match 'Enterprise|Education|IoT'
  $row = $osSupportTable | Where-Object { $_.Build -eq $build -and $_.Type -eq $type } | Select-Object -First 1
  $ver = "build $build.$($cv.UBR) $($cv.DisplayVersion) $($cv.EditionID)"
  if (-not $row) { Add-Check $name 'WARN' "Unknown $type $ver - not in this tool's support table" 'Check the Microsoft lifecycle page for this build and update $osSupportTable' }
  else {
    $end = [datetime]::ParseExact($(if ($isEnt) { $row.Enterprise } else { $row.Consumer }), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $days = [math]::Floor(($end - (Get-Date).Date).TotalDays)
    if ($days -lt 0) { Add-Check $name 'FAIL' "$($row.Name) ($ver) - support ENDED $($end.ToString('yyyy-MM-dd'))" 'Upgrade to a supported feature update (or confirm ESU/LTSC coverage)' }
    elseif ($days -le $supportWarnDays) { Add-Check $name 'WARN' "$($row.Name) ($ver) - support ends $($end.ToString('yyyy-MM-dd')) ($days days)" 'Schedule the next feature update' }
    else { Add-Check $name 'PASS' "$($row.Name) ($ver) - supported until $($end.ToString('yyyy-MM-dd'))" }
  }
} catch { Add-Check $name 'WARN' "Could not read OS version: $($_.Exception.Message)" 'Check winver' }

# 17. LSA protection (WARN-level only)
$name = 'LSA protection (RunAsPPL)'
$ppl = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL'
if ("$ppl" -eq '1' -or "$ppl" -eq '2') { Add-Check $name 'PASS' "RunAsPPL=$ppl" }
else { Add-Check $name 'WARN' $(if ($null -eq $ppl) { 'Not configured' } else { "RunAsPPL=$ppl" }) 'Windows Security > Device security > Core isolation > Local Security Authority protection = On (test drivers/plugins first), restart' }

# 18. Credential Guard (WARN-level only)
$name = 'Credential Guard'
try {
  $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
  if (@($dg.SecurityServicesRunning) -contains 1) { Add-Check $name 'PASS' 'Credential Guard is running' }
  elseif (@($dg.SecurityServicesConfigured) -contains 1) { Add-Check $name 'WARN' 'Configured but NOT running (restart pending or hardware/VBS not available)' 'Restart, then check msinfo32 > Virtualization-based security' }
  else { Add-Check $name 'WARN' ("Not running (VBS status {0}; needs Enterprise/Education)" -f $dg.VirtualizationBasedSecurityStatus) 'Enable via Intune/GPO: Device Guard > Turn On Virtualization Based Security > Credential Guard' }
} catch { Add-Check $name 'WARN' "Could not query Device Guard: $($_.Exception.Message)" 'Check msinfo32 > Virtualization-based security' }

# --- Output ---
$passed = @($results | Where-Object Status -eq 'PASS').Count
$warned = @($results | Where-Object Status -eq 'WARN').Count
$failed = @($results | Where-Object Status -eq 'FAIL').Count
$notChecked = @($results | Where-Object Status -eq 'N/A').Count
$total = $passed + $warned + $failed

Write-Host ''
foreach ($r in $results) {
  $color = switch ($r.Status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
  Write-Host ('[{0,-4}] {1,-32} {2}' -f $r.Status, $r.Check, $r.Detail) -ForegroundColor $color
  if ($r.Fix) { Write-Host ('       {0,-32} Fix: {1}' -f '', $r.Fix) }
}
Write-Host ''
$scoreColor = if ($failed) { 'Red' } elseif ($warned) { 'Yellow' } else { 'Green' }
Write-Host ("Score: {0} / {1} passed  ({2} warning, {3} failed, {4} not checked)" -f $passed, $total, $warned, $failed, $notChecked) -ForegroundColor $scoreColor
if ($notChecked) { Write-Host 'Re-run elevated to complete the N/A checks.' -ForegroundColor Yellow }

# --- HTML report ---
try {
  $reportDir = Join-Path $env:USERPROFILE 'Desktop\MSP-Reports'
  if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
  $style = '<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{font-size:22px}h2{font-size:17px;margin-top:28px}table{border-collapse:collapse;width:100%;font-size:12px}th,td{border:1px solid #ccc;padding:4px 6px;text-align:left;vertical-align:top;word-break:break-word}td:first-child{white-space:nowrap}th{background:#eee}td.PASS{background:#d9f2d9}td.WARN{background:#fff2cc}td.FAIL{background:#f8d0d0}td.NA{background:#eee}</style>'
  $summary = @(
    [pscustomobject]@{ Item = 'Computer'; Value = $env:COMPUTERNAME }
    [pscustomobject]@{ Item = 'Generated'; Value = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    [pscustomobject]@{ Item = 'Run as'; Value = "$env:USERDOMAIN\$env:USERNAME$(if ($isAdmin) { ' (elevated)' } else { ' (not elevated)' })" }
    [pscustomobject]@{ Item = 'Score'; Value = "$passed / $total passed" }
    [pscustomobject]@{ Item = 'Warnings / Failed / Not checked'; Value = "$warned / $failed / $notChecked" })
  $table = ($results | Select-Object Status, Check, Detail, Fix | ConvertTo-Html -Fragment) -join "`n"
  $table = $table -replace '<td>PASS</td>', '<td class="PASS">PASS</td>' -replace '<td>WARN</td>', '<td class="WARN">WARN</td>' -replace '<td>FAIL</td>', '<td class="FAIL">FAIL</td>' -replace '<td>N/A</td>', '<td class="NA">N/A</td>'
  $body = @("<h1>Security baseline - $env:COMPUTERNAME</h1>", ($summary | ConvertTo-Html -Fragment), '<h2>Checks</h2>', $table)
  $htmlOut = Join-Path $reportDir "security-baseline-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
  ConvertTo-Html -Title "Security baseline - $env:COMPUTERNAME" -Head $style -Body ($body -join "`n") | Out-File -FilePath $htmlOut -Encoding UTF8
  Write-Host "Scorecard saved: $htmlOut"
} catch {
  Write-Host "Could not save the HTML scorecard: $($_.Exception.Message)" -ForegroundColor Yellow
}
