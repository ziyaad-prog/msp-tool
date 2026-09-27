$reportDir = Join-Path $env:USERPROFILE 'Desktop\MSP-Reports'
# Windows 11 quick-indicator thresholds (NOT Microsoft's official PC Health Check - CPU model support is not checked)
$win11MinRamGB = 4
$win11MinDiskGB = 64
$win11MinCores = 2
$win11MinMHz = 1000
# Uninstall entries whose name matches this are treated as updates/patches and left out of the software list
$softwareExcludePattern = '^(Security )?Update for |^Hotfix for |\(KB\d{6,}\)|^KB\d{6,}'

$firmwareType = $env:firmware_type   # 'UEFI' or 'Legacy' (dynamic Windows variable)
if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $reportDir "system-info-$stamp.txt"
$htmlOut = Join-Path $reportDir "system-info-$stamp.html"
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Each section is rendered once into the text report and once into the HTML report.
# Kind: List (Format-List / 2-column table), Table (Format-Table / HTML table), Text (preformatted)
$sections = [System.Collections.Generic.List[object]]::new()
function Add-Section {
  param([string]$Title, [ValidateSet('List', 'Table', 'Text')][string]$Kind, $Data, [string]$Note)
  $sections.Add([pscustomobject]@{ Title = $Title; Kind = $Kind; Data = $Data; Note = $Note })
}
# Runs a native command without letting stderr/exit codes throw under $ErrorActionPreference = 'Stop'
function Invoke-NativeQuiet {
  param([scriptblock]$Command)
  $ErrorActionPreference = 'Continue'
  try { @(& $Command 2>$null | ForEach-Object { "$_" }) } catch { @() }
}

Write-Host 'Collecting system information...'

# --- OS / uptime ---
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
Add-Section 'OS' List ($os | Select-Object Caption, Version, BuildNumber, LastBootUpTime, TotalVisibleMemorySize, FreePhysicalMemory)
$uptime = (Get-Date) - $os.LastBootUpTime
$uptimeText = '{0}d {1}h {2}m' -f $uptime.Days, $uptime.Hours, $uptime.Minutes
Add-Section 'Uptime' List ([pscustomobject]@{ 'Last boot' = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'); Uptime = $uptimeText }) -Note $(if ($uptime.TotalDays -gt 14) { 'Uptime over 14 days - a restart is recommended.' })

# --- Pending reboot (quick check) ---
$cbsPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$wuPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
$pfro = $null -ne (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue)
$yn = { param($b) if ($b) { 'YES' } else { 'NO' } }
$anyPending = $cbsPending -or $wuPending -or $pfro
Add-Section 'Pending Reboot' List ([pscustomobject]@{
    'Reboot pending'                  = (& $yn $anyPending)
    'CBS RebootPending'               = (& $yn $cbsPending)
    'Windows Update RebootRequired'   = (& $yn $wuPending)
    'PendingFileRenameOperations'     = (& $yn $pfro)
  }) -Note $(if ($anyPending) { 'RESTART REQUIRED to finish pending changes.' })

# --- CPU ---
$cpu = @(Get-CimInstance Win32_Processor)
Add-Section 'CPU' List ($cpu | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed)

# --- BIOS / serial ---
$bios = Get-CimInstance Win32_BIOS
$biosDate = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToString('yyyy-MM-dd') } else { 'unknown' }
Add-Section 'BIOS' List ([pscustomobject]@{
    'System manufacturer' = $cs.Manufacturer
    'System model'        = $cs.Model
    'Serial number'       = $bios.SerialNumber
    'BIOS manufacturer'   = $bios.Manufacturer
    'BIOS version'        = $bios.SMBIOSBIOSVersion
    'BIOS release date'   = $biosDate
    'Firmware type'       = $(if ($firmwareType) { $firmwareType } else { 'unknown' })
  })

# --- TPM: Get-Tpm (admin) -> Win32_Tpm (admin) -> tpmtool (no admin needed) -> PnP device name ---
$tpm = [ordered]@{ Present = 'unknown'; Version = 'unknown'; Ready = 'unknown'; Manufacturer = 'unknown'; Source = '' }
$tpmDone = $false
try {
  # Unelevated, Get-Tpm RETURNS the string 'Administrator privilege is required...' instead of throwing
  $gt = Get-Tpm -ErrorAction Stop
  if (-not ($gt -and $gt.PSObject.Properties['TpmPresent'])) { throw 'Get-Tpm needs admin' }
  $tpm.Present = "$($gt.TpmPresent)"; $tpm.Ready = "$($gt.TpmReady)"; $tpm.Manufacturer = "$($gt.ManufacturerIdTxt) $($gt.ManufacturerVersion)".Trim(); $tpm.Source = 'Get-Tpm'
  $tpmDone = $true
} catch { }
try {
  $wt = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop | Select-Object -First 1
  if ($wt) {
    $tpm.Present = 'True'
    if ($wt.SpecVersion) { $tpm.Version = ("$($wt.SpecVersion)" -split ',')[0].Trim() }
    if (-not $tpmDone) { $tpm.Ready = "$($wt.IsEnabled_InitialValue -and $wt.IsActivated_InitialValue)"; $tpm.Manufacturer = "$($wt.ManufacturerIdTxt) $($wt.ManufacturerVersion)".Trim() }
    $tpm.Source = (@($tpm.Source, 'Win32_Tpm') | Where-Object { $_ }) -join ' + '
    $tpmDone = $true
  } elseif (-not $tpmDone) { $tpm.Present = 'False'; $tpm.Source = 'Win32_Tpm'; $tpmDone = $true }
} catch { }
$tpmAbsent = $tpm.Present -eq 'False'
if (-not $tpmAbsent -and $tpm.Version -eq 'unknown' -and (Get-Command tpmtool -ErrorAction SilentlyContinue)) {
  $tt = Invoke-NativeQuiet { tpmtool getdeviceinformation }
  $ttVal = { param($label) $l = $tt | Where-Object { $_ -match "^\s*-$label\s*:" } | Select-Object -First 1; if ($l) { ($l -split ':', 2)[1].Trim() } }
  if (& $ttVal 'TPM Present') {
    $tpm.Present = & $ttVal 'TPM Present'
    if (& $ttVal 'TPM Version') { $tpm.Version = & $ttVal 'TPM Version' }
    if ($tpm.Ready -eq 'unknown' -and (& $ttVal 'Ready For Storage')) { $tpm.Ready = & $ttVal 'Ready For Storage' }
    if ($tpm.Manufacturer -eq 'unknown') { $tpm.Manufacturer = ("$(& $ttVal 'TPM Manufacturer Full Name') $(& $ttVal 'TPM Manufacturer Version')").Trim() }
    $tpm.Source = (@($tpm.Source, 'tpmtool') | Where-Object { $_ }) -join ' + '
    $tpmDone = $true
  }
}
if (-not $tpmAbsent -and $tpm.Version -eq 'unknown') {
  $pnpTpm = Get-PnpDevice -Class SecurityDevices -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -match 'Trusted Platform Module\s*([\d.]+)' } | Select-Object -First 1
  if ($pnpTpm -and $pnpTpm.FriendlyName -match 'Trusted Platform Module\s*([\d.]+)') {
    $tpm.Present = 'True'; $tpm.Version = $Matches[1]; $tpm.Source = (@($tpm.Source, 'Device Manager') | Where-Object { $_ }) -join ' + '; $tpmDone = $true
  }
}
if (-not $tpmDone) { $tpm.Source = 'needs admin (Get-Tpm/Win32_Tpm denied, no fallback available)' }
Add-Section 'TPM' List ([pscustomobject]$tpm)

# --- Secure Boot ---
$sbState = 'unknown'
try {
  $sbState = if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'Enabled' } else { 'Disabled (UEFI - capable)' }
} catch [System.PlatformNotSupportedException] {
  $sbState = 'Not supported (legacy BIOS / CSM)'
} catch {
  # Confirm-SecureBootUEFI needs admin; the SecureBoot\State key is readable without it (only exists on UEFI)
  $sbReg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name UEFISecureBootEnabled -ErrorAction SilentlyContinue
  if ($sbReg) { $sbState = if ($sbReg.UEFISecureBootEnabled -eq 1) { 'Enabled (from registry)' } else { 'Disabled (UEFI - capable, from registry)' } }
  elseif ($_.Exception -is [System.UnauthorizedAccessException]) { $sbState = 'unknown - needs admin' }
  else { $sbState = "unknown - $($_.Exception.Message)" }
}
Add-Section 'Secure Boot' List ([pscustomobject]@{ 'Secure Boot' = $sbState })

# --- Windows 11 readiness (quick indicator) ---
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$sysDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'" -ErrorAction SilentlyContinue
$sysDiskGB = if ($sysDrive) { [math]::Round($sysDrive.Size / 1GB, 0) } else { $null }
$cores = ($cpu | Measure-Object NumberOfCores -Sum).Sum
$mhz = ($cpu | Measure-Object MaxClockSpeed -Maximum).Maximum
$isUefi = if ($firmwareType) { $firmwareType -eq 'UEFI' } elseif ($sbState -match 'Enabled|Disabled \(UEFI') { $true } else { $null }
$check = { param($ok) if ($null -eq $ok) { 'UNKNOWN' } elseif ($ok) { 'PASS' } else { 'FAIL' } }
$tpmOk = if ($tpm.Version -match '^\d') { [double](($tpm.Version -split '[^\d.]')[0]) -ge 2 } elseif ($tpm.Present -eq 'False') { $false } else { $null }
$sbOk = if ($sbState -match '^(Enabled|Disabled \(UEFI)') { $true } elseif ($sbState -match 'Not supported') { $false } else { $null }
$win11 = @(
  [pscustomobject]@{ Requirement = 'TPM 2.0'; Result = (& $check $tpmOk); Detail = "Version: $($tpm.Version)" }
  [pscustomobject]@{ Requirement = 'Secure Boot capable'; Result = (& $check $sbOk); Detail = $sbState }
  [pscustomobject]@{ Requirement = 'UEFI firmware'; Result = (& $check $isUefi); Detail = $(if ($firmwareType) { $firmwareType } else { 'unknown' }) }
  [pscustomobject]@{ Requirement = "CPU >= $win11MinCores cores, >= $([math]::Round($win11MinMHz / 1000, 1)) GHz"; Result = (& $check ($cores -ge $win11MinCores -and $mhz -ge $win11MinMHz)); Detail = "$cores cores, $mhz MHz" }
  [pscustomobject]@{ Requirement = "RAM >= $win11MinRamGB GB"; Result = (& $check ($ramGB -ge $win11MinRamGB)); Detail = "$ramGB GB" }
  [pscustomobject]@{ Requirement = "System disk >= $win11MinDiskGB GB"; Result = (& $check $(if ($null -ne $sysDiskGB) { $sysDiskGB -ge $win11MinDiskGB })); Detail = "$($env:SystemDrive) $sysDiskGB GB" }
)
Add-Section 'Windows 11 Readiness (quick indicator)' Table $win11 -Note 'Quick indicator only - not Microsoft''s official check. CPU model/generation support is not checked; use PC Health Check to confirm.'

# --- Logged-on users ---
$sessions = @()
if (Get-Command quser -ErrorAction SilentlyContinue) {
  $sessions = @(Invoke-NativeQuiet { quser } | Where-Object { $_.Trim() })
}
$usersText = @("Console user (Win32_ComputerSystem): $(if ($cs.UserName) { $cs.UserName } else { '(none)' })", '')
if ($sessions.Count) { $usersText += 'quser:'; $usersText += $sessions }
elseif (Get-Command quser -ErrorAction SilentlyContinue) { $usersText += 'quser: no user sessions reported.' }
else { $usersText += 'quser: not available on this edition of Windows.' }
Add-Section 'Logged-on Users' Text ($usersText -join "`r`n")

# --- Disks ---
Add-Section 'Disks' Table @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object DeviceID, @{N = 'SizeGB'; E = { [math]::Round($_.Size / 1GB, 2) } }, @{N = 'FreeGB'; E = { [math]::Round($_.FreeSpace / 1GB, 2) } }, FileSystem)

# --- Network ---
Add-Section 'Network Adapters' Table @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object Name, InterfaceDescription, LinkSpeed, MacAddress)

# --- Installed software ---
$uninstallKeys = @(
  @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine' }
  @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Machine (32-bit)' }
  @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'; Scope = 'Current user' }
)
$software = foreach ($k in $uninstallKeys) {
  Get-ChildItem -Path $k.Path -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
    if (-not $p -or -not $p.DisplayName) { return }
    if ($p.SystemComponent -eq 1 -or $p.ParentKeyName -or $p.ReleaseType -match 'Update|Hotfix' -or $p.DisplayName -match $softwareExcludePattern) { return }
    $date = "$($p.InstallDate)"
    if ($date -match '^(\d{4})(\d{2})(\d{2})$') { $date = "$($Matches[1])-$($Matches[2])-$($Matches[3])" }
    [pscustomobject]@{ Name = "$($p.DisplayName)".Trim(); Version = "$($p.DisplayVersion)"; Publisher = "$($p.Publisher)".Trim(); 'Install date' = $date; Scope = $k.Scope }
  }
}
$software = @($software | Sort-Object Name, Version -Unique | Sort-Object Name)
Add-Section "Installed Software ($($software.Count))" Table $software

# --- Raw network output (existing report sections) ---
Add-Section 'ipconfig /all' Text (& "$env:SystemRoot\System32\ipconfig.exe" /all | Out-String)
Add-Section 'route print' Text (& "$env:SystemRoot\System32\route.exe" print | Out-String)

# ---------------- Text report ----------------
$info = @()
$info += "=== MSP System Report ==="
$info += "Generated: $(Get-Date)"
$info += "Computer: $env:COMPUTERNAME"
$info += "User: $env:USERNAME"
$info += ""
foreach ($s in $sections) {
  $info += "--- $($s.Title) ---"
  if ($s.Note) { $info += "NOTE: $($s.Note)" }
  switch ($s.Kind) {
    'List' { $info += ($s.Data | Format-List | Out-String) }
    'Table' { if (@($s.Data).Count) { $info += ($s.Data | Format-Table -AutoSize | Out-String -Width 400) } else { $info += "(none)`r`n" } }
    'Text' { $info += "$($s.Data)"; $info += '' }
  }
}
$info | Out-File -FilePath $out -Encoding UTF8

# ---------------- HTML report ----------------
$enc = { param($t) [System.Net.WebUtility]::HtmlEncode("$t") }
$style = '<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}h1{font-size:22px}h2{font-size:17px;margin-top:28px}table{border-collapse:collapse;width:100%;font-size:12px}th,td{border:1px solid #ccc;padding:4px 6px;text-align:left;vertical-align:top;word-break:break-word}th{background:#eee}pre{background:#f6f6f6;border:1px solid #ddd;padding:8px;font-size:12px;white-space:pre-wrap}.note{color:#9a5b00;font-weight:600}</style>'
$body = [System.Collections.Generic.List[string]]::new()
$body.Add("<h1>MSP System Report - $(& $enc $env:COMPUTERNAME)</h1>")
$body.Add("<p>Generated: $(& $enc (Get-Date).ToString('yyyy-MM-dd HH:mm')) &nbsp; User: $(& $enc $env:USERNAME)</p>")
foreach ($s in $sections) {
  $body.Add("<h2>$(& $enc $s.Title)</h2>")
  if ($s.Note) { $body.Add("<p class=""note"">$(& $enc $s.Note)</p>") }
  switch ($s.Kind) {
    'List' { $body.Add((($s.Data | ConvertTo-Html -As List -Fragment) -join "`n")) }
    'Table' { if (@($s.Data).Count) { $body.Add((($s.Data | ConvertTo-Html -Fragment) -join "`n")) } else { $body.Add('<p>(none)</p>') } }
    'Text' { $body.Add("<pre>$(& $enc $s.Data)</pre>") }
  }
}
ConvertTo-Html -Title "System report - $env:COMPUTERNAME" -Head $style -Body ($body -join "`n") | Out-File -FilePath $htmlOut -Encoding UTF8

# ---------------- Console summary ----------------
Write-Host ''
Write-Host "Uptime         : $uptimeText (last boot $($os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')))"
if ($anyPending) { Write-Host 'Pending reboot : YES - RESTART REQUIRED' -ForegroundColor Yellow } else { Write-Host 'Pending reboot : NO' -ForegroundColor Green }
Write-Host "Serial / BIOS  : $($bios.SerialNumber) / $($bios.SMBIOSBIOSVersion) ($biosDate)"
Write-Host "TPM            : present $($tpm.Present), version $($tpm.Version) [$($tpm.Source)]"
Write-Host "Secure Boot    : $sbState"
$w11Fail = @($win11 | Where-Object Result -eq 'FAIL')
$w11Unknown = @($win11 | Where-Object Result -eq 'UNKNOWN')
if ($w11Fail.Count) { Write-Host "Windows 11     : NOT READY - failed: $(($w11Fail.Requirement) -join ', ') (quick indicator)" -ForegroundColor Yellow }
elseif ($w11Unknown.Count) { Write-Host "Windows 11     : no failures found, but could not check: $(($w11Unknown.Requirement) -join ', ') (quick indicator)" -ForegroundColor Yellow }
else { Write-Host 'Windows 11     : hardware basics met (quick indicator - CPU model not checked)' -ForegroundColor Green }
Write-Host "Software       : $($software.Count) programs listed"
if (-not $isAdmin) { Write-Host 'Note: not running as admin - TPM/Secure Boot used non-admin fallbacks where needed.' -ForegroundColor Yellow }
Write-Host ''
Write-Host "Report saved: $out"
Write-Host "HTML report saved: $htmlOut"
