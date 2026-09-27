# ---------------- Settings (edit these lists to match the MSP stack) ----------------
# ConnectWise Automate (CWA / LabTech) agent services and registry key
$cwaServices = @('LTService', 'LTSvcMon')
$cwaRegPath = 'HKLM:\SOFTWARE\LabTech\Service'
# CWA registry values that are safe to show. Allow-list on purpose: NEVER add password/key values here.
$cwaRegValues = @('Server Address', 'ID', 'ClientID', 'LocationID', 'Version', 'LastSuccessStatus', 'HeartbeatLastSent', 'HeartbeatLastReceived')
# Warn when the CWA last-contact/heartbeat value is older than this many hours
$cwaContactWarnHours = 24
# ScreenConnect client service(s): one per instance, named 'ScreenConnect Client (<thumbprint>)'
$screenConnectPatterns = @('ScreenConnect Client (*')
# ImmyBot agent service (matched against service Name and DisplayName)
$immyPatterns = @('*Immy*')
# Microsoft Defender Antivirus service
$defenderServices = @('WinDefend')
# Warn when Defender signatures are older than this many days
$defenderSigWarnDays = 3
# Third-party EDR/AV products: display name -> service name patterns. Only shown when found.
$edrProducts = [ordered]@{
  'Defender for Endpoint (Sense)' = @('Sense')
  'SentinelOne'                   = @('SentinelAgent')
  'CrowdStrike Falcon'            = @('CSFalconService')
  'Huntress'                      = @('HuntressAgent', 'HuntressRio')
  'Sophos'                        = @('Sophos*', 'SAVService')
  'Bitdefender GravityZone'       = @('EPSecurityService', 'EPProtectedService')
  'Webroot'                       = @('WRSVC')
  'Malwarebytes'                  = @('MBAMService')
  'Carbon Black'                  = @('CbDefense', 'CarbonBlack')
  'Cylance'                       = @('CylanceSvc')
  'ESET'                          = @('ekrn')
  'Trend Micro'                   = @('ntrtscan', 'TMBMServer')
  'Blackpoint SNAP'               = @('Snap*Agent*')
}
# Tamper-protected services that cannot be restarted from here (fix via the vendor console / reboot)
$noRestartServices = @('WinDefend', 'Sense', 'WdNisSvc', 'SentinelAgent', 'CSFalconService')
# ------------------------------------------------------------------------------------

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-AgentServices {
  param([string[]]$Patterns, [switch]$MatchDisplayName)
  $found = @()
  foreach ($p in $Patterns) {
    $found += @(Get-Service -Name $p -ErrorAction SilentlyContinue)
    if ($MatchDisplayName) { $found += @(Get-Service -DisplayName $p -ErrorAction SilentlyContinue) }
  }
  # De-duplicate by service name
  $seen = @{}
  foreach ($s in $found) { if ($s -and -not $seen.ContainsKey($s.Name)) { $seen[$s.Name] = $true; $s } }
}

function Get-ServiceFileVersion {
  param([string]$Name)
  try {
    $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f ($Name -replace "'", "\'")) -ErrorAction Stop
    $pn = "$($svc.PathName)"
    # Only the exe path is used - the rest of the command line can hold instance keys, never print it
    $exe = $null
    if ($pn -match '^\s*"([^"]+)"') { $exe = $matches[1] } elseif ($pn -match '^\s*(.+?\.exe)\b') { $exe = $matches[1] }
    if ($exe -and (Test-Path -LiteralPath $exe)) {
      $v = (Get-Item -LiteralPath $exe -ErrorAction Stop).VersionInfo.FileVersion
      if ($v) { return ("$v".Trim() -split '\s+')[0] }
    }
  } catch { }
  return ''
}

function Get-ServiceHealth {
  param($Service)
  if ("$($Service.StartType)" -eq 'Disabled') { return 'DISABLED' }
  if ("$($Service.Status)" -eq 'Running') { return 'OK' }
  if ("$($Service.Status)" -eq 'Stopped') { return 'STOPPED' }
  return "$($Service.Status)".ToUpper()
}

$rows = New-Object System.Collections.Generic.List[object]
$problems = New-Object System.Collections.Generic.List[object]

function Add-ComponentRows {
  param([string]$Component, $Services, [string]$VersionOverride, [switch]$Optional)
  $svcList = @($Services)
  if (-not $svcList.Count) {
    if (-not $Optional) {
      $rows.Add([pscustomobject]@{ Component = $Component; Service = '(none found)'; Status = '-'; StartType = '-'; Version = ''; Health = 'NOT INSTALLED' })
    }
    return
  }
  foreach ($s in $svcList) {
    $ver = if ($VersionOverride) { $VersionOverride } else { Get-ServiceFileVersion -Name $s.Name }
    $health = Get-ServiceHealth $s
    $row = [pscustomobject]@{ Component = $Component; Service = $s.Name; Status = "$($s.Status)"; StartType = "$($s.StartType)"; Version = $ver; Health = $health }
    $rows.Add($row)
    if ($health -ne 'OK') { $problems.Add([pscustomobject]@{ Component = $Component; Name = $s.Name; DisplayName = $s.DisplayName; Status = "$($s.Status)"; StartType = "$($s.StartType)"; Health = $health }) }
  }
}

Write-Host '=== MSP Agent Health Check ===' -ForegroundColor Cyan
Write-Host "Computer: $env:COMPUTERNAME    Checked: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Host ''

# ---------------- ConnectWise Automate ----------------
$cwaSvc = @(Get-AgentServices -Patterns $cwaServices)
$cwaInfo = [ordered]@{}
$cwaRegNote = ''
if (Test-Path $cwaRegPath) {
  try {
    $reg = Get-ItemProperty -Path $cwaRegPath -ErrorAction Stop
    foreach ($v in $cwaRegValues) {
      $prop = $reg.PSObject.Properties[$v]
      if ($prop -and "$($prop.Value)".Trim()) { $cwaInfo[$v] = "$($prop.Value)".Trim() }
    }
  } catch {
    $cwaRegNote = 'CWA registry details need administrator rights (not available in this session).'
  }
} elseif ($cwaSvc.Count) {
  $cwaRegNote = "CWA registry key $cwaRegPath not found."
}
$cwaVersion = if ($cwaInfo.Contains('Version')) { $cwaInfo['Version'] } else { '' }
Add-ComponentRows -Component 'CWA Agent' -Services $cwaSvc -VersionOverride $cwaVersion

# ---------------- ScreenConnect ----------------
Add-ComponentRows -Component 'ScreenConnect' -Services @(Get-AgentServices -Patterns $screenConnectPatterns)

# ---------------- ImmyBot ----------------
Add-ComponentRows -Component 'ImmyBot Agent' -Services @(Get-AgentServices -Patterns $immyPatterns -MatchDisplayName)

# ---------------- Microsoft Defender ----------------
$defSvc = @(Get-AgentServices -Patterns $defenderServices)
$mp = $null
$mpError = ''
try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch { $mpError = $_.Exception.Message }
$defVersion = if ($mp -and $mp.AMProductVersion) { "$($mp.AMProductVersion)" } else { '' }
Add-ComponentRows -Component 'Microsoft Defender' -Services $defSvc -VersionOverride $defVersion

# ---------------- Third-party EDR / AV ----------------
$edrFound = @()
foreach ($product in $edrProducts.Keys) {
  $svcs = @(Get-AgentServices -Patterns $edrProducts[$product] -MatchDisplayName)
  if ($svcs.Count) { $edrFound += $product; Add-ComponentRows -Component $product -Services $svcs -Optional }
}

# ---------------- Status table ----------------
Write-Host '--- Agent services ---' -ForegroundColor Cyan
$rows | Format-Table Component, Service, Status, StartType, Version, Health -AutoSize | Out-String -Width 220 | Write-Host
foreach ($r in $rows) {
  switch ($r.Health) {
    'OK' { }
    'NOT INSTALLED' { Write-Host "[WARN] $($r.Component): not installed (no matching service found)." -ForegroundColor Yellow }
    'DISABLED' { Write-Host "[FAIL] $($r.Component): service $($r.Service) is DISABLED." -ForegroundColor Red }
    'STOPPED' { Write-Host "[FAIL] $($r.Component): service $($r.Service) is STOPPED." -ForegroundColor Red }
    default { Write-Host "[WARN] $($r.Component): service $($r.Service) is $($r.Health)." -ForegroundColor Yellow }
  }
}

# ---------------- CWA details ----------------
Write-Host ''
Write-Host '--- CWA agent details ---' -ForegroundColor Cyan
if ($cwaInfo.Count) {
  foreach ($k in $cwaInfo.Keys) { Write-Host ('  {0,-22} {1}' -f $k, $cwaInfo[$k]) }
  foreach ($k in @('LastSuccessStatus', 'HeartbeatLastSent', 'HeartbeatLastReceived')) {
    if (-not $cwaInfo.Contains($k)) { continue }
    $when = [datetime]::MinValue
    if ([datetime]::TryParse($cwaInfo[$k], [ref]$when)) {
      $age = (Get-Date) - $when
      if ($age.TotalHours -gt $cwaContactWarnHours) {
        Write-Host ('[WARN] {0} is {1:N1} hours old - the agent may not be checking in. Compare with the CWA console (Last Contact).' -f $k, $age.TotalHours) -ForegroundColor Yellow
      }
    }
  }
} elseif ($cwaSvc.Count) {
  Write-Host '  (no registry details available)'
} else {
  Write-Host '  CWA agent is not installed.' -ForegroundColor Yellow
}
if ($cwaRegNote) { Write-Host "  $cwaRegNote" -ForegroundColor Yellow }

# ---------------- Defender details ----------------
Write-Host ''
Write-Host '--- Microsoft Defender ---' -ForegroundColor Cyan
if ($mp) {
  Write-Host ('  Running mode         : {0}' -f $(if ($mp.AMRunningMode) { $mp.AMRunningMode } else { 'unknown' }))
  Write-Host ('  Antivirus enabled    : {0}' -f $mp.AntivirusEnabled)
  Write-Host ('  Real-time protection : {0}' -f $mp.RealTimeProtectionEnabled)
  Write-Host ('  Tamper protection    : {0}' -f $mp.IsTamperProtected)
  Write-Host ('  Signatures updated   : {0} ({1} day(s) old)' -f $mp.AntivirusSignatureLastUpdated, $mp.AntivirusSignatureAge)
  $passive = "$($mp.AMRunningMode)" -match 'Passive|EDR'
  if (-not $mp.RealTimeProtectionEnabled -and -not $passive -and -not $edrFound.Count) {
    Write-Host '[FAIL] Defender real-time protection is OFF and no third-party AV/EDR was detected.' -ForegroundColor Red
  } elseif ($passive -and -not $edrFound.Count) {
    Write-Host '[WARN] Defender is in passive mode but no third-party AV/EDR from the list was detected - check what AV is registered.' -ForegroundColor Yellow
  }
  if ($mp.AntivirusSignatureAge -gt $defenderSigWarnDays -and -not $passive) {
    Write-Host "[WARN] Defender signatures are more than $defenderSigWarnDays days old." -ForegroundColor Yellow
  }
} else {
  Write-Host "  Could not read Defender status: $mpError" -ForegroundColor Yellow
}

# ---------------- Security products summary ----------------
Write-Host ''
Write-Host '--- Third-party EDR / AV ---' -ForegroundColor Cyan
if ($edrFound.Count) { Write-Host "  Detected: $($edrFound -join ', ')" } else { Write-Host '  None of the listed EDR/AV services were detected.' }
try {
  $avReg = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName } | Sort-Object -Unique)
  if ($avReg.Count) { Write-Host "  Registered with Windows Security Center: $($avReg -join ', ')" }
} catch { } # SecurityCenter2 does not exist on servers

# ---------------- Restart menu ----------------
Write-Host ''
if (-not $problems.Count) {
  Write-Host 'All installed agent services are running.' -ForegroundColor Green
  return
}
$fixable = @($problems | Where-Object { $noRestartServices -notcontains $_.Name })
foreach ($p in @($problems | Where-Object { $noRestartServices -contains $_.Name })) {
  Write-Host "$($p.Name) is tamper-protected and cannot be restarted here - reboot, or fix it from the vendor console." -ForegroundColor Yellow
}
if (-not $fixable.Count) { return }
if (-not $isAdmin) {
  Write-Host 'Restarting agent services requires administrator rights. Relaunch MSP Tool elevated to restart them.' -ForegroundColor Yellow
  return
}

while ($fixable.Count) {
  Write-Host ''
  Write-Host '--- Unhealthy agent services ---'
  for ($i = 0; $i -lt $fixable.Count; $i++) {
    $f = $fixable[$i]
    Write-Host ('  [{0}] {1} - {2} ({3}, start type {4})' -f ($i + 1), $f.Component, $f.Name, $f.Health, $f.StartType)
  }
  Write-Host ''
  $selection = Read-Host 'Enter a number to restart that service, or 0 to exit'
  if (-not $selection -or $selection -eq '0') { Write-Host 'Exiting tool.' -ForegroundColor Yellow; return }
  if ($selection -notmatch '^\d+$' -or [int]$selection -lt 1 -or [int]$selection -gt $fixable.Count) { Write-Host 'Invalid selection.' -ForegroundColor Yellow; continue }
  $target = $fixable[[int]$selection - 1]

  try {
    if ($target.StartType -eq 'Disabled') {
      $answer = Read-Host "$($target.Name) is Disabled. Type YES (uppercase) to set it to Automatic and start it (anything else cancels)"
      if ($answer -cne 'YES') { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
      Set-Service -Name $target.Name -StartupType Automatic -ErrorAction Stop
      Write-Host "[OK] $($target.Name) start type set to Automatic." -ForegroundColor Green
      if ($target.Status -ne 'Running') { Start-Service -Name $target.Name -ErrorAction Stop }
    } else {
      $answer = Read-Host "Restart $($target.Name) now? (y/N)"
      if ($answer -notmatch '^(y|yes)$') { Write-Host 'Cancelled.' -ForegroundColor Yellow; continue }
      if ($target.Status -eq 'Running') { Restart-Service -Name $target.Name -Force -ErrorAction Stop } else { Start-Service -Name $target.Name -ErrorAction Stop }
    }
    $now = Get-Service -Name $target.Name -ErrorAction Stop
    if ("$($now.Status)" -eq 'Running' -and "$($now.StartType)" -ne 'Disabled') {
      Write-Host "[OK] $($target.Name) is running (start type $($now.StartType))." -ForegroundColor Green
      $fixable = @($fixable | Where-Object { $_.Name -ne $target.Name })
    } else {
      Write-Host "[WARN] $($target.Name) is $($now.Status) (start type $($now.StartType)). Check the Application/System event log." -ForegroundColor Yellow
      $target.Status = "$($now.Status)"; $target.StartType = "$($now.StartType)"; $target.Health = Get-ServiceHealth $now
    }
  } catch {
    Write-Host "[FAIL] Could not restart $($target.Name): $($_.Exception.Message)" -ForegroundColor Red
  }
}
Write-Host 'All selected agent services are running.' -ForegroundColor Green
