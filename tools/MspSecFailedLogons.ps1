# Failed Logons & Lockouts - read-only review of the Security event log (needs admin).
# 4625 failed logons, 4740 account lockouts, 4624 type 10 (RDP) successful logons for context.

# --- Tunables ---
$bruteForceThreshold = 10      # failures from ONE source above this = possible brute force
$sprayAccountThreshold = 5     # one source failing against this many different accounts = possible password spray
$maxFailedEvents = 20000       # cap on 4625 events read (busy servers)
$topN = 10

$logonTypes = @{ '2' = 'Interactive'; '3' = 'Network'; '4' = 'Batch'; '5' = 'Service'; '7' = 'Unlock'; '8' = 'NetworkCleartext'; '9' = 'NewCredentials'; '10' = 'RemoteInteractive (RDP)'; '11' = 'CachedInteractive'; '12' = 'CachedRemoteInteractive'; '13' = 'CachedUnlock' }
$statusCodes = @{
  '0XC000006A' = 'Bad password'
  '0XC0000064' = 'No such user'
  '0XC0000234' = 'Account locked out'
  '0XC0000072' = 'Account disabled'
  '0XC000006F' = 'Outside allowed logon hours'
  '0XC0000071' = 'Password expired'
  '0XC0000070' = 'Workstation not allowed'
  '0XC0000193' = 'Account expired'
  '0XC0000224' = 'Must change password at next logon'
  '0XC000015B' = 'Logon type not granted'
  '0XC000006D' = 'Bad user name or authentication info'
  '0XC000006E' = 'Account restriction'
  '0XC0000133' = 'Clock skew with DC'
  '0XC000005E' = 'No logon servers available'
  '0XC0000413' = 'Authentication firewall'
}

$reportDir = Join-Path $env:USERPROFILE 'Desktop\MSP-Reports'

function Get-EventData {
  # EventData <Data Name="...">value</Data> -> hashtable
  param($Event)
  $h = @{}
  try {
    $xml = [xml]$Event.ToXml()
    foreach ($d in @($xml.Event.EventData.Data)) { if ($d -and $d.Name) { $h[$d.Name] = "$($d.'#text')".Trim() } }
  } catch { }
  return $h
}
function Get-Reason {
  param([string]$Status, [string]$SubStatus)
  $code = if ($SubStatus -and $SubStatus -notmatch '^0x0+$') { $SubStatus } else { $Status }
  if (-not $code) { return 'Unknown' }
  $key = $code.ToUpper()
  if ($statusCodes.ContainsKey($key)) { return $statusCodes[$key] }
  return "Other ($code)"
}
function Get-Source {
  param($Data)
  $ip = $Data['IpAddress']; $ws = $Data['WorkstationName']
  if ($ip -and $ip -ne '-') { return $ip }
  if ($ws -and $ws -ne '-') { return $ws }
  return '(local)'
}
function Read-SecurityEvents {
  param([hashtable]$Filter, [string]$XPath, [int]$Max = 0)
  try {
    $args2 = @{ ErrorAction = 'Stop' }
    if ($XPath) { $args2.LogName = 'Security'; $args2.FilterXPath = $XPath } else { $args2.FilterHashtable = $Filter }
    if ($Max) { $args2.MaxEvents = $Max }
    return , @(Get-WinEvent @args2)
  } catch {
    if ($_.FullyQualifiedErrorId -match 'NoMatchingEventsFound' -or $_.Exception.Message -match 'No events were found') { return , @() }
    throw
  }
}

# --- Ask for the time window ---
$hours = $null
while ($null -eq $hours) {
  Write-Host 'Time window:'
  Write-Host '  [1] Last 1 hour'
  Write-Host '  [2] Last 24 hours (default)'
  Write-Host '  [3] Last 7 days (168 hours)'
  $pick = Read-Host 'Enter 1, 2 or 3 (blank = 24 hours), or 0 to exit'
  if ($null -eq $pick -or "$pick".Trim() -eq '') { $hours = 24; break }
  switch ("$pick".Trim()) {
    '0' { Write-Host 'Exiting tool.' -ForegroundColor Yellow; return }
    '1' { $hours = 1 } '2' { $hours = 24 } '3' { $hours = 168 }
    '24' { $hours = 24 } '168' { $hours = 168 }
    default { Write-Host 'Invalid selection.' -ForegroundColor Yellow }
  }
}
$since = (Get-Date).AddHours(-$hours)
$ms = [int64]($hours * 3600 * 1000)
Write-Host ''
Write-Host "--- Failed logons & lockouts since $($since.ToString('yyyy-MM-dd HH:mm')) ($hours h) ---" -ForegroundColor Cyan

try {
  $failedEvents = Read-SecurityEvents -Filter @{ LogName = 'Security'; Id = 4625; StartTime = $since } -Max $maxFailedEvents
  $lockoutEvents = Read-SecurityEvents -Filter @{ LogName = 'Security'; Id = 4740; StartTime = $since }
  $rdpEvents = Read-SecurityEvents -XPath "*[System[(EventID=4624) and TimeCreated[timediff(@SystemTime) <= $ms]] and EventData[Data[@Name='LogonType']='10']]"
} catch {
  Write-Host "Could not read the Security log: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host 'The Security log needs administrator rights - run MSP Tool elevated.'
  return
}
if ($failedEvents.Count -ge $maxFailedEvents) { Write-Host "Note: capped at the newest $maxFailedEvents failed-logon events." -ForegroundColor Yellow }

$failed = @(foreach ($e in $failedEvents) {
  $d = Get-EventData $e
  $lt = $d['LogonType']
  [pscustomobject]@{
    Time = $e.TimeCreated; Event = 'Failed logon (4625)'
    Account = $d['TargetUserName']; Domain = $d['TargetDomainName']
    Source = (Get-Source $d); IpAddress = $d['IpAddress']; Workstation = $d['WorkstationName']
    LogonType = $(if ($logonTypes.ContainsKey("$lt")) { "$lt $($logonTypes["$lt"])" } else { "$lt" })
    Reason = (Get-Reason $d['Status'] $d['SubStatus']); Status = $d['Status']; SubStatus = $d['SubStatus']
    Process = $d['ProcessName']
  }
})
$lockouts = @(foreach ($e in $lockoutEvents) {
  $d = Get-EventData $e
  # 4740: TargetDomainName holds the CALLER computer (where the bad attempts came from)
  [pscustomobject]@{ Time = $e.TimeCreated; Event = 'Account lockout (4740)'; Account = $d['TargetUserName']; Domain = ''; Source = $d['TargetDomainName']; IpAddress = ''; Workstation = $d['TargetDomainName']; LogonType = ''; Reason = "Locked out (reported by $($d['SubjectUserName']))"; Status = ''; SubStatus = ''; Process = '' }
})
$rdp = @(foreach ($e in $rdpEvents) {
  $d = Get-EventData $e
  [pscustomobject]@{ Time = $e.TimeCreated; Event = 'RDP logon (4624 type 10)'; Account = $d['TargetUserName']; Domain = $d['TargetDomainName']; Source = (Get-Source $d); IpAddress = $d['IpAddress']; Workstation = $d['WorkstationName']; LogonType = '10 RemoteInteractive (RDP)'; Reason = 'Success'; Status = ''; SubStatus = ''; Process = '' }
})

# --- Failed logons summary ---
Write-Host ''
if (-not $failed.Count) {
  Write-Host 'No failed logons (4625) in this window.' -ForegroundColor Green
  # Zero failures can also mean failure auditing is off - check Logon subcategory by GUID (language independent)
  try {
    $ap = @(auditpol /get /subcategory:'{0CCE9215-69AE-11D9-BED3-505054503030}' /r 2>$null | Where-Object { $_ -match ',' })
    if ($ap.Count -ge 2) {
      $setting = ($ap[1] -split ',')[4]
      # The setting text is localized: only judge English values, otherwise just show it
      if ($setting -match 'Failure') { Write-Host "Logon failure auditing is enabled ($setting)." }
      elseif ($setting -match '^\s*(Success|No Auditing)\s*$') { Write-Host "WARNING: 'Audit Logon' failure auditing is not enabled (current: $setting) - failed logons are NOT being recorded." -ForegroundColor Yellow }
      else { Write-Host "Logon auditing setting: '$setting' - confirm it includes Failure (auditpol /get /subcategory:Logon)." -ForegroundColor Yellow }
    }
  } catch { }
} else {
  $accounts = @($failed | Group-Object { "$($_.Domain)\$($_.Account)".TrimStart('\') } | Sort-Object Count -Descending)
  $sources = @($failed | Group-Object Source | Sort-Object Count -Descending)
  Write-Host ("Failed logons: {0}   accounts: {1}   sources: {2}" -f $failed.Count, $accounts.Count, $sources.Count) -ForegroundColor Yellow

  Write-Host ''
  Write-Host "Top accounts:" -ForegroundColor Cyan
  $accounts | Select-Object -First $topN | ForEach-Object {
    $topReason = ($_.Group | Group-Object Reason | Sort-Object Count -Descending | Select-Object -First 1).Name
    $srcCount = @($_.Group | Select-Object -ExpandProperty Source -Unique).Count
    Write-Host ("  {0,5}x  {1,-35} from {2} source(s), mostly: {3}" -f $_.Count, $_.Name, $srcCount, $topReason)
  }
  Write-Host ''
  Write-Host "Top sources (IP / workstation):" -ForegroundColor Cyan
  $sources | Select-Object -First $topN | ForEach-Object {
    $acctCount = @($_.Group | Select-Object -ExpandProperty Account -Unique).Count
    $types = ($_.Group | Group-Object LogonType | Sort-Object Count -Descending | ForEach-Object { $_.Name }) -join ', '
    Write-Host ("  {0,5}x  {1,-35} against {2} account(s), type: {3}" -f $_.Count, $_.Name, $acctCount, $types)
  }
  Write-Host ''
  Write-Host 'By logon type:' -ForegroundColor Cyan
  $failed | Group-Object LogonType | Sort-Object Count -Descending | ForEach-Object { Write-Host ("  {0,5}x  {1}" -f $_.Count, $_.Name) }
  Write-Host 'By failure reason:' -ForegroundColor Cyan
  $failed | Group-Object Reason | Sort-Object Count -Descending | ForEach-Object { Write-Host ("  {0,5}x  {1}" -f $_.Count, $_.Name) }

  # --- Brute-force / spray flags ---
  Write-Host ''
  $alerts = 0
  foreach ($s in $sources) {
    $acctCount = @($s.Group | Select-Object -ExpandProperty Account -Unique).Count
    if ($s.Count -gt $bruteForceThreshold -or $acctCount -ge $sprayAccountThreshold) {
      $alerts++
      $kind = if ($acctCount -ge $sprayAccountThreshold) { 'password spray / user enumeration' } else { 'brute force' }
      $first = ($s.Group | Sort-Object Time | Select-Object -First 1).Time; $last = ($s.Group | Sort-Object Time | Select-Object -Last 1).Time
      Write-Host ("[ALERT] Possible {0}: {1} - {2} failures against {3} account(s) between {4:yyyy-MM-dd HH:mm} and {5:yyyy-MM-dd HH:mm}" -f $kind, $s.Name, $s.Count, $acctCount, $first, $last) -ForegroundColor Red
      $isPrivate = $s.Name -match '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|::1$|fe80:|f[cd][0-9a-f]{2}:)' -or $s.Name -notmatch '[\.:]'
      if (-not $isPrivate) { Write-Host '        Source looks like a PUBLIC address - check for RDP/SMB exposed to the internet (firewall/NAT rules).' -ForegroundColor Red }
    }
  }
  foreach ($a in $accounts) {
    $srcCount = @($a.Group | Select-Object -ExpandProperty Source -Unique).Count
    if ($a.Count -gt $bruteForceThreshold -and $srcCount -gt 1) {
      $alerts++
      Write-Host ("[ALERT] Account {0} failed {1} times from {2} different sources - targeted account or a stale saved credential (mapped drive/phone/service)." -f $a.Name, $a.Count, $srcCount) -ForegroundColor Red
    }
  }
  if (-not $alerts) { Write-Host "No brute-force pattern (no source above $bruteForceThreshold failures or $sprayAccountThreshold+ accounts)." -ForegroundColor Green }
}

# --- Lockouts ---
Write-Host ''
if ($lockouts.Count) {
  Write-Host "Account lockouts (4740): $($lockouts.Count)" -ForegroundColor Yellow
  $lockouts | Sort-Object Time -Descending | Select-Object -First 25 | ForEach-Object { Write-Host ("  {0:yyyy-MM-dd HH:mm}  {1,-25} caller computer: {2}" -f $_.Time, $_.Account, $_.Source) }
  Write-Host '  (4740 is logged on the domain controller for domain accounts - check the PDC emulator if none show here.)'
} else {
  Write-Host 'No account lockouts (4740) logged on this machine in this window.' -ForegroundColor Green
}

# --- RDP successes for context ---
Write-Host ''
if ($rdp.Count) {
  Write-Host "Successful RDP logons (4624 type 10): $($rdp.Count)" -ForegroundColor Cyan
  $failedSources = @($failed | Select-Object -ExpandProperty Source -Unique)
  $rdp | Sort-Object Time -Descending | Select-Object -First 25 | ForEach-Object {
    $warn = $failedSources -contains $_.Source -and $_.Source -ne '(local)'
    Write-Host ("  {0:yyyy-MM-dd HH:mm}  {1,-25} from {2}{3}" -f $_.Time, "$($_.Domain)\$($_.Account)".TrimStart('\'), $_.Source, $(if ($warn) { '   <-- same source also had FAILED logons' } else { '' })) -ForegroundColor $(if ($warn) { 'Red' } else { 'Gray' })
  }
} else {
  Write-Host 'No successful RDP logons in this window.'
}

# --- CSV export ---
$all = @($failed) + @($lockouts) + @($rdp)
if (-not $all.Count) { return }
Write-Host ''
$answer = Read-Host 'Export these events to CSV in the reports folder? (y/N)'
if ($answer -notmatch '^[Yy]') { return }
try {
  if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
  $csvOut = Join-Path $reportDir "failed-logons-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
  $all | Sort-Object Time | Select-Object @{ N = 'Time'; E = { $_.Time.ToString('yyyy-MM-dd HH:mm:ss') } }, Event, Account, Domain, Source, IpAddress, Workstation, LogonType, Reason, Status, SubStatus, Process |
    Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
  Write-Host "Saved: $csvOut" -ForegroundColor Green
} catch {
  Write-Host "Could not save CSV: $($_.Exception.Message)" -ForegroundColor Red
}
