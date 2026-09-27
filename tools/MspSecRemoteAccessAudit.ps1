# Remote Access Software Audit - read-only. Finds remote-access/RMM tools in installed programs, services,
# running processes and listening ports, and marks each APPROVED or UNAPPROVED. Nothing is removed or stopped.

# --- Approved software (wildcards, matched against the program/service/instance name) ---
$approvedNames = @('ScreenConnect Client (*)')
# Optional: LENET ScreenConnect instance IDs (the 16 hex chars in "ScreenConnect Client (xxxxxxxxxxxxxxxx)").
# When this list is NOT empty, any ScreenConnect instance whose ID is not listed is reported UNAPPROVED (foreign instance).
$approvedScreenConnectIds = @()

# --- Signatures: Product name + regex matched against display names, service names/paths, process names/paths ---
$signatures = @(
  [pscustomobject]@{ Product = 'ScreenConnect / ConnectWise Control'; Pattern = 'ScreenConnect|ConnectWise Control'; Note = '' }
  [pscustomobject]@{ Product = 'AnyDesk'; Pattern = 'AnyDesk'; Note = '' }
  [pscustomobject]@{ Product = 'TeamViewer'; Pattern = 'TeamViewer'; Note = '' }
  [pscustomobject]@{ Product = 'RustDesk'; Pattern = 'RustDesk'; Note = '' }
  [pscustomobject]@{ Product = 'Splashtop'; Pattern = 'Splashtop|^SRService(\.exe)?$|^SRManager(\.exe)?$|^SRAgent(\.exe)?$|^SRFeature(\.exe)?$'; Note = '"Splashtop for RMM" can be deployed by an RMM integration - confirm whether LENET/CWA installed it' }
  [pscustomobject]@{ Product = 'LogMeIn'; Pattern = 'LogMeIn|^LMIGuardian|^LMIIgnition|^LMIRTechConsole'; Note = '' }
  [pscustomobject]@{ Product = 'GoTo Resolve / GoToAssist'; Pattern = 'GoToAssist|GoTo Resolve|GoToResolve|^g2ax_'; Note = '' }
  [pscustomobject]@{ Product = 'Chrome Remote Desktop'; Pattern = 'Chrome Remote Desktop|^remoting_host(\.exe)?$|chromoting'; Note = '' }
  [pscustomobject]@{ Product = 'VNC (UltraVNC/TightVNC/RealVNC)'; Pattern = 'UltraVNC|TightVNC|RealVNC|VNC Server|^winvnc|^tvnserver|^vncserver'; Note = '' }
  [pscustomobject]@{ Product = 'Radmin'; Pattern = 'Radmin|^rserver3(\.exe)?$'; Note = '' }
  [pscustomobject]@{ Product = 'Ammyy Admin'; Pattern = 'Ammyy|^AA_v3'; Note = '' }
  [pscustomobject]@{ Product = 'Atera'; Pattern = 'Atera'; Note = '' }
  [pscustomobject]@{ Product = 'NinjaOne'; Pattern = 'NinjaRMM|NinjaOne'; Note = '' }
  [pscustomobject]@{ Product = 'Kaseya'; Pattern = 'Kaseya|^AgentMon(\.exe)?$'; Note = '' }
  [pscustomobject]@{ Product = 'N-able / SolarWinds Take Control'; Pattern = 'Take Control Agent|^BASupSrvc|^BASupport|N-able|SolarWinds MSP|BeAnywhere'; Note = '' }
  [pscustomobject]@{ Product = 'Supremo'; Pattern = 'Supremo'; Note = '' }
  [pscustomobject]@{ Product = 'DWService'; Pattern = 'DWService|DWAgent'; Note = '' }
  [pscustomobject]@{ Product = 'MeshCentral / MeshAgent'; Pattern = 'MeshAgent|Mesh Agent|MeshCentral'; Note = '' }
  [pscustomobject]@{ Product = 'Zoho Assist'; Pattern = 'Zoho Assist|ZohoAssist|^ZAService'; Note = '' }
  [pscustomobject]@{ Product = 'BeyondTrust / Bomgar'; Pattern = 'BeyondTrust Remote|Bomgar|^bomgar-scc'; Note = '' }
)

$findings = @{}   # key = product|instance
function Add-Finding {
  param([string]$Product, [string]$Instance, [string]$Where, [string]$Note, $ProcessId, [string]$Relay)
  $key = "$Product|$Instance"
  if (-not $findings.ContainsKey($key)) {
    $findings[$key] = [pscustomobject]@{ Product = $Product; Instance = $Instance; Where = [System.Collections.Generic.List[string]]::new(); Pids = [System.Collections.Generic.List[int]]::new(); Relay = ''; Note = $Note }
  }
  $f = $findings[$key]
  if (-not $f.Where.Contains($Where)) { $f.Where.Add($Where) }
  if ($ProcessId) { [void]$f.Pids.Add([int]$ProcessId) }
  if ($Relay -and -not $f.Relay) { $f.Relay = $Relay }
}
function Get-Signature {
  param([string[]]$Texts)
  foreach ($s in $signatures) { foreach ($t in $Texts) { if ($t -and $t -match $s.Pattern) { return $s } } }
  return $null
}
function Get-ScInstance {
  # "ScreenConnect Client (77fd8c77134c1026)" -> instance name; falls back to the matched text
  param([string[]]$Texts)
  foreach ($t in $Texts) { if ($t -match '(ScreenConnect Client \([0-9a-fA-F]+\))') { return $Matches[1] } }
  return 'ScreenConnect (instance unknown)'
}
function Get-ScRelay {
  # Only the relay host/port and company tag are shown - the key (k=), session and encrypted blobs are never printed
  param([string]$CommandLine)
  if ($CommandLine -notmatch '[?&]h=([^&"]+)') { return '' }
  $relay = $Matches[1]
  if ($CommandLine -match '[?&]p=(\d+)') { $relay += ":$($Matches[1])" }
  $tags = @([regex]::Matches($CommandLine, '[?&]c=([^&"]+)') | ForEach-Object { [uri]::UnescapeDataString($_.Groups[1].Value) } | Where-Object { $_ })
  if ($tags.Count) { $relay += " (company tags: $($tags -join ', '))" }
  return $relay
}
function Resolve-Instance {
  param($Sig, [string[]]$Texts)
  if ($Sig.Product -like 'ScreenConnect*') { return (Get-ScInstance $Texts) }
  return ''
}

Write-Host '--- Remote Access Software Audit (read-only) ---' -ForegroundColor Cyan
Write-Host ("Approved: {0}{1}" -f ($approvedNames -join ', '), $(if ($approvedScreenConnectIds.Count) { "; ScreenConnect IDs: $($approvedScreenConnectIds -join ', ')" } else { '' }))

# 1. Installed programs
$uninstallKeys = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
foreach ($key in $uninstallKeys) {
  $hive = ($key -split ':')[0] + $(if ($key -match 'WOW6432Node') { ' (32-bit)' } else { '' })
  foreach ($app in @(Get-ItemProperty -Path "$key\*" -ErrorAction SilentlyContinue)) {
    if (-not $app.DisplayName) { continue }
    $sig = Get-Signature @($app.DisplayName, $app.Publisher)
    if ($sig) { Add-Finding $sig.Product (Resolve-Instance $sig @($app.DisplayName, $app.InstallLocation)) ("Installed ($hive): {0} {1}" -f $app.DisplayName, $app.DisplayVersion).Trim() $sig.Note }
  }
}

# 2. Services
try {
  foreach ($svc in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
    $sig = Get-Signature @($svc.Name, $svc.DisplayName, $svc.PathName)
    if ($sig) {
      $relay = if ($sig.Product -like 'ScreenConnect*') { Get-ScRelay $svc.PathName } else { '' }
      Add-Finding $sig.Product (Resolve-Instance $sig @($svc.Name, $svc.DisplayName, $svc.PathName)) ("Service: {0} ({1}, {2})" -f $svc.Name, $svc.State, $svc.StartMode) $sig.Note $svc.ProcessId $relay
    }
  }
} catch { Write-Host "Could not list services: $($_.Exception.Message)" -ForegroundColor Yellow }

# 3. Running processes
foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
  $path = $null
  try { $path = $proc.Path } catch { }
  $sig = Get-Signature @($proc.Name, $path)
  if ($sig) { Add-Finding $sig.Product (Resolve-Instance $sig @($path)) ("Process: {0}.exe (PID {1})" -f $proc.Name, $proc.Id) $sig.Note $proc.Id }
}
# A ScreenConnect process whose path was not readable (e.g. SYSTEM service, not elevated) is attached to the only known instance
$scUnknown = $findings.Keys | Where-Object { $_ -eq 'ScreenConnect / ConnectWise Control|ScreenConnect (instance unknown)' }
$scKnown = @($findings.Keys | Where-Object { $_ -like 'ScreenConnect*' -and $_ -notlike '*instance unknown*' })
if ($scUnknown -and $scKnown.Count -eq 1) {
  $u = $findings[$scUnknown]; $k = $findings[$scKnown[0]]
  foreach ($w in $u.Where) { if (-not $k.Where.Contains($w)) { $k.Where.Add($w) } }
  foreach ($p in $u.Pids) { [void]$k.Pids.Add($p) }
  $findings.Remove($scUnknown)
}

# 4. Listening TCP ports owned by those processes
try {
  $listen = @(Get-NetTCPConnection -State Listen -ErrorAction Stop)
  foreach ($f in $findings.Values) {
    $ports = @($listen | Where-Object { $f.Pids -contains [int]$_.OwningProcess } | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" } | Sort-Object -Unique)
    if ($ports.Count) { $f.Where.Add("Listening TCP: $($ports -join ', ')") }
  }
} catch { Write-Host "Could not list listening ports: $($_.Exception.Message)" -ForegroundColor Yellow }

# --- Classify ---
$rows = foreach ($f in ($findings.Values | Sort-Object Product, Instance)) {
  $names = @($f.Instance) + @($f.Where)
  $approved = $false
  foreach ($a in $approvedNames) { if (@($names | Where-Object { $_ -and ($_ -like $a -or $_ -like "*$a*") }).Count) { $approved = $true } }
  $reason = ''
  if ($approved -and $f.Product -like 'ScreenConnect*' -and $approvedScreenConnectIds.Count) {
    $id = if ($f.Instance -match '\(([0-9a-fA-F]+)\)') { $Matches[1] } else { '' }
    if ($approvedScreenConnectIds -notcontains $id) { $approved = $false; $reason = 'ScreenConnect instance ID is not in the approved list (foreign instance?)' }
  }
  [pscustomobject]@{ Status = $(if ($approved) { 'APPROVED' } else { 'UNAPPROVED' }); Product = $f.Product; Instance = $f.Instance; Relay = $f.Relay; Where = @($f.Where); Note = (@($reason, $f.Note) | Where-Object { $_ }) -join '; ' }
}
$rows = @($rows)

Write-Host ''
if (-not $rows.Count) {
  Write-Host 'No remote-access software from the watch list was found (not even the approved agent).' -ForegroundColor Yellow
  Write-Host 'If this machine should be managed by LENET, the ScreenConnect client may be missing - check ScreenConnect/CWA.'
  return
}
foreach ($r in ($rows | Sort-Object @{ E = { $_.Status -eq 'APPROVED' } }, Product)) {
  $color = if ($r.Status -eq 'APPROVED') { 'Green' } else { 'Red' }
  Write-Host ("[{0}] {1}{2}" -f $r.Status, $r.Product, $(if ($r.Instance) { " - $($r.Instance)" } else { '' })) -ForegroundColor $color
  if ($r.Relay) { Write-Host "    Relay: $($r.Relay)" }
  foreach ($w in $r.Where) { Write-Host "    $w" }
  if ($r.Note) { Write-Host "    Note: $($r.Note)" -ForegroundColor Yellow }
}

$sc = @($rows | Where-Object { $_.Product -like 'ScreenConnect*' })
$bad = @($rows | Where-Object Status -eq 'UNAPPROVED')
Write-Host ''
Write-Host ("Summary: {0} approved, {1} UNAPPROVED" -f ($rows.Count - $bad.Count), $bad.Count) -ForegroundColor $(if ($bad.Count) { 'Red' } else { 'Green' })
if ($sc.Count -gt 1) {
  Write-Host ("WARNING: {0} ScreenConnect instances found - compare each instance ID/relay with LENET's; an unknown one may be a scammer or another MSP." -f $sc.Count) -ForegroundColor Yellow
} elseif ($sc.Count -eq 1 -and -not $approvedScreenConnectIds.Count) {
  Write-Host 'Check the ScreenConnect instance ID/relay above matches LENET (set $approvedScreenConnectIds in this tool to automate this).'
}
if ($bad.Count) {
  Write-Host ''
  Write-Host 'Advice (nothing was removed):' -ForegroundColor Yellow
  Write-Host '  - Ask the client/user whether the tool is expected (vendor support, another MSP). Unexpected + running = treat as a possible compromise; escalate to SOC.'
  Write-Host '  - If not needed: uninstall via Settings > Apps (or the vendor uninstaller / a CWA script), then re-run this audit.'
  Write-Host '  - Portable tools (no install entry) show up only as a process - find the exe path via Task Manager > Details > Open file location.'
}
