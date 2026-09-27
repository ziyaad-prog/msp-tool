# Defender Status Report - read-only.
# --- Tunables ---
$sigWarnDays = 3          # signatures older than this = WARN
$sigFailDays = 7          # older than this = FAIL
$threatDays = 30          # show detections from the last N days
# Exclusions that commonly hide malware - matched case-insensitively (regex for paths, exact names for processes/extensions)
$riskyPathPatterns = @(
  '^[A-Za-z]:\\?$'                          # whole drive
  '^\*'                                      # leading wildcard
  '\\(Temp|Tmp)(\\|$)', '%TEMP%', '%TMP%'    # temp folders
  '\\Downloads(\\|$)'                        # downloads
  '\\AppData(\\Local|\\Roaming)?\\?$'         # whole AppData
  '\\Users(\\Public)?\\?$', '%USERPROFILE%\\?$'
  '\\Windows(\\System32|\\SysWOW64)?\\?$'    # Windows / System32
  '\\ProgramData\\?$'
)
$riskyProcesses = @('powershell.exe', 'pwsh.exe', 'powershell_ise.exe', 'cmd.exe', 'wscript.exe', 'cscript.exe', 'mshta.exe', 'rundll32.exe', 'regsvr32.exe', 'msbuild.exe', 'installutil.exe', 'certutil.exe', 'bitsadmin.exe', 'wmic.exe', 'python.exe', 'explorer.exe', 'svchost.exe', 'msiexec.exe')
$riskyExtensions = @('exe', 'dll', 'ps1', 'psm1', 'bat', 'cmd', 'vbs', 'vbe', 'js', 'jse', 'hta', 'scr', 'msi', 'com', 'lnk', 'jar', 'wsf')

try {
  $mp = Get-MpComputerStatus -ErrorAction Stop
} catch {
  Write-Host "Could not read Defender status: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host 'Defender may be disabled/replaced by a third-party antivirus - check Windows Security > Virus & threat protection.'
  return
}
$mp | Select-Object AMServiceEnabled, AntivirusEnabled, RealTimeProtectionEnabled, AntivirusSignatureLastUpdated, QuickScanEndTime, FullScanEndTime | Format-List | Out-String | Write-Host

# --- Protection state ---
Write-Host '--- Protection ---' -ForegroundColor Cyan
function Write-State { param([string]$Label, [string]$Status, [string]$Text)
  $color = switch ($Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
  Write-Host ('[{0,-4}] {1,-22} {2}' -f $Status, $Label, $Text) -ForegroundColor $color }
Write-State 'Real-time protection' $(if ($mp.RealTimeProtectionEnabled) { 'OK' } else { 'FAIL' }) $(if ($mp.RealTimeProtectionEnabled) { 'On' } else { 'OFF' })
Write-State 'Running mode' $(if ("$($mp.AMRunningMode)" -in @('Normal', '')) { 'OK' } else { 'WARN' }) $(if ($mp.AMRunningMode) { "$($mp.AMRunningMode)" } else { 'unknown' })
if ($null -eq $mp.IsTamperProtected) { Write-State 'Tamper protection' 'WARN' 'Not reported by this Defender version' }
else { Write-State 'Tamper protection' $(if ($mp.IsTamperProtected) { 'OK' } else { 'WARN' }) $(if ($mp.IsTamperProtected) { 'On' } else { 'OFF - turn on in Windows Security or via Intune/Defender portal' }) }
$sigAge = if ($mp.AntivirusSignatureLastUpdated) { [math]::Floor(((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays) } else { $mp.AntivirusSignatureAge }
$sigStatus = if ($sigAge -gt $sigFailDays) { 'FAIL' } elseif ($sigAge -gt $sigWarnDays) { 'WARN' } else { 'OK' }
Write-State 'Signature age' $sigStatus ("{0} day(s) (version {1}){2}" -f $sigAge, $mp.AntivirusSignatureVersion, $(if ($sigStatus -ne 'OK') { ' - run Update-MpSignature / check Windows Update' } else { '' }))
Write-Host ("       Platform version       {0}" -f $mp.AMProductVersion)
Write-Host ("       Engine version         {0}" -f $mp.AMEngineVersion)

# --- Recent threat detections ---
Write-Host ''
Write-Host "--- Threat detections (last $threatDays days) ---" -ForegroundColor Cyan
$severityNames = @{ 0 = 'Unknown'; 1 = 'Low'; 2 = 'Moderate'; 4 = 'High'; 5 = 'Severe' }
$statusNames = @{ 0 = 'Unknown'; 1 = 'Detected'; 2 = 'Cleaned'; 3 = 'Quarantined'; 4 = 'Removed'; 5 = 'Allowed'; 6 = 'Blocked'; 102 = 'Quarantine failed'; 103 = 'Remove failed'; 104 = 'Allow failed'; 105 = 'Abandoned'; 107 = 'Block failed' }
try {
  $since = (Get-Date).AddDays(-$threatDays)
  $detections = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { $_.InitialDetectionTime -ge $since } | Sort-Object InitialDetectionTime -Descending)
  if (-not $detections.Count) {
    Write-Host "No detections in the last $threatDays days." -ForegroundColor Green
  } else {
    $threats = @{}
    try { foreach ($t in @(Get-MpThreat -ErrorAction Stop)) { $threats["$($t.ThreatID)"] = $t } } catch { }
    foreach ($d in $detections) {
      $t = $threats["$($d.ThreatID)"]
      $name = if ($t) { $t.ThreatName } else { "ThreatID $($d.ThreatID)" }
      $sev = if ($t -and $severityNames.ContainsKey([int]$t.SeverityID)) { $severityNames[[int]$t.SeverityID] } else { 'Unknown' }
      $state = if ($statusNames.ContainsKey([int]$d.ThreatStatusID)) { $statusNames[[int]$d.ThreatStatusID] } else { "status $($d.ThreatStatusID)" }
      $bad = (-not $d.ActionSuccess) -or ([int]$d.ThreatStatusID -in @(1, 5, 102, 103, 104, 105, 107)) -or ($t -and $t.IsActive)
      Write-Host ("  {0:yyyy-MM-dd HH:mm}  [{1}] {2} - {3}{4}" -f $d.InitialDetectionTime, $sev, $name, $state, $(if ($bad) { '  <-- NOT fully remediated, investigate' } else { '' })) -ForegroundColor $(if ($bad -or $sev -in 'High', 'Severe') { 'Red' } else { 'Yellow' })
      if ($d.DomainUser) { Write-Host "      User: $($d.DomainUser)   Process: $($d.ProcessName)" }
      foreach ($r in @($d.Resources | Select-Object -First 3)) { Write-Host "      Resource: $($r -replace '^[a-z]+:_', '')" }
    }
    Write-Host 'Full history: Windows Security > Virus & threat protection > Protection history (or the Defender portal).'
  }
} catch {
  Write-Host "Could not read threat history: $($_.Exception.Message)" -ForegroundColor Yellow
}

# --- Exclusions ---
Write-Host ''
Write-Host '--- Exclusions ---' -ForegroundColor Cyan
try {
  $pref = Get-MpPreference -ErrorAction Stop
  $lists = [ordered]@{ Path = @($pref.ExclusionPath); Process = @($pref.ExclusionProcess); Extension = @($pref.ExclusionExtension) }
  $riskyCount = 0
  foreach ($kind in $lists.Keys) {
    $items = @($lists[$kind] | Where-Object { $_ })
    if ($items.Count -and "$($items[0])" -match '^N/A') { Write-Host ("  {0,-10} requires admin to view" -f $kind) -ForegroundColor Yellow; continue }
    if (-not $items.Count) { Write-Host ("  {0,-10} (none)" -f $kind); continue }
    foreach ($x in $items) {
      $risky = $false
      switch ($kind) {
        'Path' { foreach ($p in $riskyPathPatterns) { if ($x -match $p) { $risky = $true } } }
        'Process' { $risky = $riskyProcesses -contains (Split-Path $x -Leaf).ToLower() }
        'Extension' { $risky = $riskyExtensions -contains ($x.TrimStart('*').TrimStart('.').ToLower()) }
      }
      if ($risky) { $riskyCount++ }
      Write-Host ("  {0,-10} {1}{2}" -f $kind, $x, $(if ($risky) { '   [WARN] risky exclusion' } else { '' })) -ForegroundColor $(if ($risky) { 'Yellow' } else { 'Gray' })
    }
  }
  if ($riskyCount) { Write-Host "$riskyCount risky exclusion(s) - confirm who added them and why (GPO/Intune/app vendor); attackers add exclusions to hide malware." -ForegroundColor Yellow }
} catch {
  Write-Host "Could not read Defender preferences: $($_.Exception.Message)" -ForegroundColor Yellow
}
