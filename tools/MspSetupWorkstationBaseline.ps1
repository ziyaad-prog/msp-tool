# New Workstation Baseline: rename, time zone, power plan, remove consumer apps, install baseline apps.
# Settings live in config\baseline.json (edit that file, not this one).
$configRelPath = 'config\baseline.json'
# External commands are called through these variables (bare names) so they can be swapped or stubbed
$wingetCmd = 'winget'
$powercfgCmd = 'powercfg'
# Where winget.exe lives when it is not on PATH (usual when running as SYSTEM / from an RMM)
$wingetSearchPath = Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe\winget.exe'
# AppX packages that are NEVER removed, even if a RemoveApps entry matches them
$protectedApps = @(
  'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.Windows.Photos',
  'Microsoft.WindowsCalculator', 'Microsoft.WindowsNotepad', 'Microsoft.WindowsTerminal', 'Microsoft.ScreenSketch',
  'Microsoft.Paint', 'Microsoft.MSPaint', 'MSTeams', 'MicrosoftTeams', 'Microsoft.OutlookForWindows', 'Microsoft.SecHealthUI',
  'Microsoft.VCLibs*', 'Microsoft.UI.Xaml*', 'Microsoft.NET.*', 'Microsoft.WindowsAppRuntime*', 'Microsoft.Services.Store.Engagement',
  'Microsoft.AAD.BrokerPlugin', 'Microsoft.AccountsControl', 'Microsoft.Windows.ShellExperienceHost', 'Microsoft.Windows.StartMenuExperienceHost',
  'Microsoft.Windows.CloudExperienceHost', 'Microsoft.Windows.ContentDeliveryManager', 'MicrosoftWindows.Client.*', 'windows.immersivecontrolpanel',
  'Microsoft.HEIFImageExtension', 'Microsoft.WebpImageExtension', 'Microsoft.VP9VideoExtensions', 'Microsoft.WebMediaExtensions',
  'Microsoft.HEVCVideoExtension', 'Microsoft.RawImageExtension', 'Microsoft.MicrosoftEdge*', 'Microsoft.CompanyPortal', 'Microsoft.MicrosoftStickyNotes'
)
# winget exit codes
$wgNotInstalled = -1978335212                              # 0x8A150014 no installed package found (winget list)
$wgAlreadyInstalled = @(-1978335189, -1978335135)          # 0x8A15002B no applicable upgrade, 0x8A150061 already installed
$wgRestartNeeded = @(-1978334967, 3010, 1641)              # 0x8A150109 restart required to finish, MSI 3010/1641
$wgRestartFirst = -1978334966                              # 0x8A15010A a restart is required before installing

# ---------------- Load config ----------------
if (-not $ScriptRoot) {
  Write-Host 'Cannot locate the MSP Tool folder ($ScriptRoot is not set), so config\baseline.json cannot be read.' -ForegroundColor Red
  Write-Host 'Run this tool from MSP Tool (console, GUI or CLI).' -ForegroundColor Red
  return
}
$configPath = Join-Path $ScriptRoot $configRelPath
if (-not (Test-Path -LiteralPath $configPath)) {
  Write-Host "Baseline config not found: $configPath" -ForegroundColor Red
  Write-Host 'Restore config\baseline.json from the MSP Tool repository (it holds the time zone, power plan and app lists).' -ForegroundColor Red
  return
}
try {
  $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  Write-Host "Baseline config is not valid JSON: $configPath" -ForegroundColor Red
  Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
  return
}
$cfgTimeZone = "$($config.DefaultTimeZone)".Trim()
$cfgPowerPlan = "$($config.PowerPlan)".Trim()
$cfgNameHint = "$($config.ComputerNamePattern)".Trim()
$removePatterns = @()
foreach ($p in @($config.RemoveApps)) {
  $p = "$p".Trim()
  if (-not $p) { continue }
  # Refuse over-broad patterns such as '*' or 'Mi*' that could match system apps
  if (($p -replace '[\*\?]', '').Length -lt 4) { Write-Host "Ignoring over-broad RemoveApps entry '$p'." -ForegroundColor Yellow; continue }
  $removePatterns += $p
}
$installIds = @(@($config.InstallApps) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })

$state = @{
  Changes  = [System.Collections.Generic.List[string]]::new()
  Failures = [System.Collections.Generic.List[string]]::new()
  Restart  = $false
  Winget   = $null
  AppListError = $false
}

# ---------------- Helpers ----------------
function Invoke-Native {
  # Runs an external command, returns exit code + output lines. Stderr is folded into the output.
  param([string]$Exe, [string[]]$ArgList)
  $ErrorActionPreference = 'Continue'
  $global:LASTEXITCODE = 0
  $out = @(& $Exe @ArgList 2>&1 | ForEach-Object { "$_" })
  [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
}

function Confirm-Yes {
  param([string]$Prompt)
  $a = "$(Read-Host $Prompt)".Trim()
  return ($a -match '^(?i)y(es)?$')
}

function Test-ProtectedApp {
  param([string]$Name)
  foreach ($p in $protectedApps) { if ($Name -like $p) { return $true } }
  return $false
}

function Test-ComputerNameRule {
  param([string]$Name)
  if ($Name.Length -gt 15) { return 'it is longer than 15 characters' }
  if ($Name -notmatch '^[A-Za-z0-9-]+$') { return 'only letters, digits and hyphens are allowed' }
  if ($Name -match '^\d+$') { return 'it cannot be all digits' }
  if ($Name -match '^-|-$') { return 'it cannot start or end with a hyphen' }
  return $null
}

function Resolve-Winget {
  if (Get-Command $wingetCmd -ErrorAction SilentlyContinue) { return $wingetCmd }
  try {
    $found = @(Resolve-Path -Path $wingetSearchPath -ErrorAction SilentlyContinue | ForEach-Object { $_.Path })
  } catch { $found = @() }
  if (-not $found.Count) { return $null }
  # Newest App Installer version wins (folder: Microsoft.DesktopAppInstaller_<version>_<arch>__8wekyb3d8bbwe)
  $best = $found | Sort-Object { try { [version]((Split-Path (Split-Path $_ -Parent) -Leaf) -split '_')[1] } catch { [version]'0.0' } } | Select-Object -Last 1
  return $best
}

function Get-WingetStatus {
  param([string]$Id)
  # Status only: never accept source terms here (that happens only on the confirmed install step), and
  # never let winget wait for input
  try { $r = Invoke-Native $state.Winget @('list', '--id', $Id, '-e', '--disable-interactivity') } catch { return 'unknown' }
  if ($r.Code -eq 0) { return 'installed' }
  if ($r.Code -eq $wgNotInstalled) { return 'not installed' }
  return "unknown (winget exit $($r.Code) - source terms may not be accepted yet; the install step accepts them)"
}

function Get-PowerPlans {
  try { $r = Invoke-Native $powercfgCmd @('/list') } catch { return @() }
  foreach ($line in $r.Output) {
    if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\((.+)\)\s*(\*?)\s*$') {
      [pscustomobject]@{ Guid = $Matches[1].ToLower(); Name = $Matches[2]; Active = ($Matches[3] -eq '*') }
    }
  }
}

function Get-AppMatches {
  # One entry per matching package name: which full names are installed (any user) and which are provisioned
  $installed = @(); $provisioned = @(); $state.AppListError = $false
  try { $installed = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } catch { $state.AppListError = $true; Write-Host "  Could not list installed apps: $("$($_.Exception.Message)".Trim())" -ForegroundColor Yellow }
  try { $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop) } catch { $state.AppListError = $true; Write-Host "  Could not list provisioned apps: $("$($_.Exception.Message)".Trim())" -ForegroundColor Yellow }
  $items = [ordered]@{}
  $skipped = @{}
  foreach ($pat in $removePatterns) {
    $hits = @()
    foreach ($pkg in $installed) { if ($pkg.Name -like $pat -and -not $pkg.IsFramework) { $hits += [pscustomobject]@{ Name = $pkg.Name; Full = $pkg.PackageFullName; Kind = 'I' } } }
    foreach ($pp in $provisioned) { if ($pp.DisplayName -like $pat) { $hits += [pscustomobject]@{ Name = $pp.DisplayName; Full = $pp.PackageName; Kind = 'P' } } }
    foreach ($h in $hits) {
      if (Test-ProtectedApp $h.Name) { $skipped[$h.Name] = $true; continue }
      if (-not $items.Contains($h.Name)) {
        $items[$h.Name] = [pscustomobject]@{ Name = $h.Name; Installed = [System.Collections.Generic.List[string]]::new(); Provisioned = [System.Collections.Generic.List[string]]::new() }
      }
      $prop = if ($h.Kind -eq 'I') { 'Installed' } else { 'Provisioned' }
      if (-not $items[$h.Name].$prop.Contains($h.Full)) { $items[$h.Name].$prop.Add($h.Full) }
    }
  }
  foreach ($n in $skipped.Keys) { Write-Host "  Not offered (protected core app): $n" -ForegroundColor Yellow }
  return , @($items.Values)
}

function Format-AppItem {
  param($Item)
  $parts = @()
  if ($Item.Installed.Count) { $parts += 'installed' }
  if ($Item.Provisioned.Count) { $parts += 'provisioned' }
  return ('{0}  ({1})' -f $Item.Name, ($parts -join ' + '))
}

function Read-NumberSelection {
  # Returns $null to cancel, or an array of 1-based indexes. Loops on invalid input.
  param([int]$Count, [string]$Prompt)
  while ($true) {
    $raw = "$(Read-Host $Prompt)".Trim()
    if (-not $raw -or $raw -eq '0') { return $null }
    if ($raw -match '^(?i)a(ll)?$') { return , @(1..$Count) }
    $picked = @(); $bad = $false
    foreach ($tok in @($raw -split '[,;\s]+' | Where-Object { $_ })) {
      if ($tok -match '^(\d+)-(\d+)$') { $a = [int]$Matches[1]; $b = [int]$Matches[2]; if ($a -lt 1 -or $b -gt $Count -or $a -gt $b) { $bad = $true } else { $picked += $a..$b } }
      elseif ($tok -match '^\d+$') { $n = [int]$tok; if ($n -lt 1 -or $n -gt $Count) { $bad = $true } else { $picked += $n } }
      else { $bad = $true }
    }
    if ($bad -or -not $picked.Count) { Write-Host 'Invalid selection.' -ForegroundColor Yellow; continue }
    return , @($picked | Sort-Object -Unique)
  }
}

# ---------------- Current state ----------------
function Show-CurrentState {
  Write-Host '=== Current state ===' -ForegroundColor Cyan
  try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { $cs = $null }
  try { $serial = "$((Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber)".Trim() } catch { $serial = 'unknown' }
  $join = if ($cs -and $cs.PartOfDomain) { "domain $($cs.Domain)" } elseif ($cs) { "workgroup $($cs.Workgroup)" } else { 'unknown' }
  Write-Host "Computer name : $env:COMPUTERNAME  ($join)"
  Write-Host "Serial number : $serial"
  try { $tz = Get-TimeZone; $tzNote = if ($cfgTimeZone -and $tz.Id -ne $cfgTimeZone) { "  [baseline: $cfgTimeZone]" } else { '' }; Write-Host "Time zone     : $($tz.Id)$tzNote" } catch { Write-Host 'Time zone     : unknown' }
  $active = @(Get-PowerPlans) | Where-Object { $_.Active } | Select-Object -First 1
  if ($active) { Write-Host "Power plan    : $($active.Name) ($($active.Guid))  [baseline: $cfgPowerPlan]" } else { Write-Host 'Power plan    : could not read (powercfg /list)' -ForegroundColor Yellow }

  Write-Host ''
  Write-Host 'Consumer apps from RemoveApps found on this computer:'
  $apps = Get-AppMatches
  if ($apps.Count) { foreach ($a in $apps) { Write-Host "  - $(Format-AppItem $a)" } }
  elseif ($state.AppListError) { Write-Host '  (could not check - app lists need administrator rights)' -ForegroundColor Yellow }
  else { Write-Host '  (none)' -ForegroundColor Green }

  Write-Host ''
  Write-Host 'Baseline apps from InstallApps:'
  if (-not $installIds.Count) { Write-Host '  (none listed in config)' }
  elseif (-not $state.Winget) { Write-Host '  winget not found - cannot check or install apps (see step 5).' -ForegroundColor Yellow }
  else {
    foreach ($id in $installIds) {
      $s = Get-WingetStatus $id
      $color = if ($s -eq 'installed') { 'Green' } elseif ($s -eq 'not installed') { 'Yellow' } else { 'Gray' }
      Write-Host "  - $id : $s" -ForegroundColor $color
    }
  }
  Write-Host ''
}

# ---------------- Steps ----------------
function Step-RenameComputer {
  Write-Host '--- [1] Rename computer ---' -ForegroundColor Cyan
  try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { Write-Host "[FAIL] Could not read computer info: $($_.Exception.Message)" -ForegroundColor Red; return }
  try { $serial = "$((Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber)".Trim() } catch { $serial = 'unknown' }
  $current = $env:COMPUTERNAME
  Write-Host "Current name: $current   Serial: $serial"
  if ($cfgNameHint) { Write-Host "Naming hint : $cfgNameHint" }
  Write-Host 'Rules: max 15 characters, letters/digits/hyphens only, not all digits, no leading/trailing hyphen.'
  while ($true) {
    $new = "$(Read-Host 'New computer name (blank to skip)')".Trim()
    if (-not $new) { Write-Host 'Skipped rename.' -ForegroundColor Yellow; return }
    $problem = Test-ComputerNameRule $new
    if ($problem) { Write-Host "Invalid name '$new': $problem." -ForegroundColor Yellow; continue }
    break
  }
  if ($new -eq $current) { Write-Host "The computer is already named $current - nothing to do." -ForegroundColor Green; return }
  if ($cs.PartOfDomain) {
    Write-Host "This computer is joined to the domain $($cs.Domain). Renaming also renames its Active Directory computer account," -ForegroundColor Yellow
    Write-Host 'so you will be asked for domain credentials that are allowed to rename computer objects (e.g. DOMAIN\admin).' -ForegroundColor Yellow
  }
  Write-Host "Rename '$current' to '$new'. A RESTART IS REQUIRED for the new name to take effect."
  if (-not (Confirm-Yes "Rename this computer to $new? (y/N)")) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
  $params = @{ NewName = $new; Force = $true; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
  if ($cs.PartOfDomain) {
    $cred = $null
    try { $cred = Get-Credential -Message "Domain credentials to rename $current to $new in $($cs.Domain)" } catch { $cred = $null }
    if (-not $cred) { Write-Host 'No credentials entered - rename cancelled.' -ForegroundColor Yellow; return }
    $params.DomainCredential = $cred
  }
  try {
    Rename-Computer @params
    Write-Host "[OK] Computer renamed to $new. RESTART REQUIRED." -ForegroundColor Green
    $state.Changes.Add("Computer name: $current -> $new (takes effect after restart)")
    $state.Restart = $true
  } catch {
    Write-Host "[FAIL] Rename failed: $($_.Exception.Message)" -ForegroundColor Red
    $state.Failures.Add("Rename to $new failed: $($_.Exception.Message)")
  }
}

function Step-SetTimeZone {
  Write-Host '--- [2] Set time zone ---' -ForegroundColor Cyan
  try { $cur = Get-TimeZone; $all = @(Get-TimeZone -ListAvailable) } catch { Write-Host "[FAIL] Could not read time zones: $($_.Exception.Message)" -ForegroundColor Red; return }
  Write-Host "Current: $($cur.Id)  $($cur.DisplayName)"
  while ($true) {
    $prompt = if ($cfgTimeZone) { "Time zone ID (Enter = $cfgTimeZone, 0 = skip)" } else { 'Time zone ID (blank or 0 = skip)' }
    $in = "$(Read-Host $prompt)".Trim()
    if ($in -eq '0' -or (-not $in -and -not $cfgTimeZone)) { Write-Host 'Skipped time zone.' -ForegroundColor Yellow; return }
    if (-not $in) { $in = $cfgTimeZone }
    $tz = $all | Where-Object { $_.Id -eq $in } | Select-Object -First 1
    if ($tz) { break }
    Write-Host "'$in' is not a valid time zone ID on this computer." -ForegroundColor Yellow
    $sugg = @($all | Where-Object { $_.Id.IndexOf($in, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.DisplayName.IndexOf($in, [StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 10)
    if ($sugg.Count) { Write-Host 'Did you mean one of these IDs?'; foreach ($s in $sugg) { Write-Host "  $($s.Id)   $($s.DisplayName)" } }
    else { Write-Host 'List valid IDs with: Get-TimeZone -ListAvailable' }
  }
  if ($tz.Id -eq $cur.Id) { Write-Host "Time zone is already $($tz.Id) - nothing to do." -ForegroundColor Green; return }
  if (-not (Confirm-Yes "Change time zone from $($cur.Id) to $($tz.Id)? (y/N)")) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
  try {
    Set-TimeZone -Id $tz.Id -ErrorAction Stop
    Write-Host "[OK] Time zone set to $($tz.Id)." -ForegroundColor Green
    $state.Changes.Add("Time zone: $($cur.Id) -> $($tz.Id)")
  } catch {
    Write-Host "[FAIL] Could not set time zone: $($_.Exception.Message)" -ForegroundColor Red
    $state.Failures.Add("Time zone $($tz.Id) failed: $($_.Exception.Message)")
  }
}

function Step-SetPowerPlan {
  Write-Host '--- [3] Set power plan ---' -ForegroundColor Cyan
  $plans = @(Get-PowerPlans)
  if (-not $plans.Count) {
    Write-Host '[FAIL] Could not read power plans (powercfg /list returned nothing usable).' -ForegroundColor Red
    $state.Failures.Add('Power plan: could not read power plans')
    return
  }
  for ($i = 0; $i -lt $plans.Count; $i++) {
    $mark = if ($plans[$i].Active) { '  (active)' } else { '' }
    Write-Host ('  [{0}] {1}  {2}{3}' -f ($i + 1), $plans[$i].Name, $plans[$i].Guid, $mark)
  }
  $baseline = $null
  if ($cfgPowerPlan) {
    $baseline = if ($cfgPowerPlan -match '^\{?[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\}?$') { $plans | Where-Object { $_.Guid -eq $cfgPowerPlan.Trim('{}').ToLower() } | Select-Object -First 1 } else { $plans | Where-Object { $_.Name -eq $cfgPowerPlan } | Select-Object -First 1 }
    if (-not $baseline) { Write-Host "Baseline power plan '$cfgPowerPlan' does not exist on this computer - pick one by number instead." -ForegroundColor Yellow }
  }
  $target = $null
  while ($true) {
    $prompt = if ($baseline) { "Enter a plan number, Enter for baseline '$($baseline.Name)', or 0 to skip" } else { 'Enter a plan number, or 0 / blank to skip' }
    $sel = "$(Read-Host $prompt)".Trim()
    if ($sel -eq '0' -or (-not $sel -and -not $baseline)) { Write-Host 'Skipped power plan.' -ForegroundColor Yellow; return }
    if (-not $sel) { $target = $baseline; break }
    if ($sel -notmatch '^\d+$' -or [int]$sel -lt 1 -or [int]$sel -gt $plans.Count) { Write-Host 'Invalid selection.' -ForegroundColor Yellow; continue }
    $target = $plans[[int]$sel - 1]; break
  }
  if ($target.Active) { Write-Host "$($target.Name) is already the active plan - nothing to do." -ForegroundColor Green; return }
  $was = $plans | Where-Object { $_.Active } | Select-Object -First 1
  if (-not (Confirm-Yes "Activate power plan '$($target.Name)'? (y/N)")) { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
  try { $r = Invoke-Native $powercfgCmd @('/setactive', $target.Guid) } catch { $r = [pscustomobject]@{ Code = -1; Output = @($_.Exception.Message) } }
  if ($r.Code -eq 0) {
    Write-Host "[OK] Power plan set to $($target.Name)." -ForegroundColor Green
    $state.Changes.Add("Power plan: $(if ($was) { $was.Name } else { 'unknown' }) -> $($target.Name)")
  } else {
    Write-Host "[FAIL] powercfg /setactive failed (exit $($r.Code)): $($r.Output -join ' ')" -ForegroundColor Red
    $state.Failures.Add("Power plan $($target.Name) failed (exit $($r.Code))")
  }
}

function Step-RemoveApps {
  Write-Host '--- [4] Remove consumer apps ---' -ForegroundColor Cyan
  if (-not $removePatterns.Count) { Write-Host 'No RemoveApps entries in config\baseline.json - nothing to do.' -ForegroundColor Yellow; return }
  Write-Host 'Checking installed and provisioned apps...'
  $items = Get-AppMatches
  if (-not $items.Count -and $state.AppListError) { Write-Host '[FAIL] Could not check which apps are installed (see message above).' -ForegroundColor Red; $state.Failures.Add('Remove apps: could not list apps'); return }
  if (-not $items.Count) { Write-Host 'None of the RemoveApps are installed or provisioned.' -ForegroundColor Green; return }
  for ($i = 0; $i -lt $items.Count; $i++) { Write-Host ('  [{0}] {1}' -f ($i + 1), (Format-AppItem $items[$i])) }
  $picks = Read-NumberSelection -Count $items.Count -Prompt 'Enter app numbers to remove (e.g. 1,3,5 or 2-4), A for all, or 0 to skip'
  if (-not $picks) { Write-Host 'Skipped app removal.' -ForegroundColor Yellow; return }
  $chosen = @($picks | ForEach-Object { $items[$_ - 1] })
  Write-Host ''
  Write-Host 'Selected for removal:'
  foreach ($c in $chosen) { Write-Host "  - $($c.Name)" }
  Write-Host 'They are removed for ALL users and from the Windows image (new user profiles will not get them).' -ForegroundColor Yellow
  Write-Host 'They can be reinstalled from the Microsoft Store if a user needs one back.' -ForegroundColor Yellow
  $answer = Read-Host "Type YES (uppercase) to remove $($chosen.Count) app(s) (anything else cancels)"
  if ($answer -cne 'YES') { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
  foreach ($c in $chosen) {
    $errs = @()
    foreach ($full in $c.Installed) {
      try { Remove-AppxPackage -Package $full -AllUsers -ErrorAction Stop } catch { $errs += "installed package: $($_.Exception.Message)" }
    }
    foreach ($pn in $c.Provisioned) {
      try { $null = Remove-AppxProvisionedPackage -Online -PackageName $pn -ErrorAction Stop } catch { $errs += "provisioned package: $($_.Exception.Message)" }
    }
    if ($errs.Count) {
      Write-Host "[FAIL] $($c.Name): $($errs -join ' | ')" -ForegroundColor Red
      $state.Failures.Add("Remove app $($c.Name) failed")
    } else {
      Write-Host "[OK] Removed $($c.Name)" -ForegroundColor Green
      $state.Changes.Add("Removed app: $($c.Name)")
    }
  }
}

function Step-InstallApps {
  Write-Host '--- [5] Install baseline apps (winget) ---' -ForegroundColor Cyan
  if (-not $installIds.Count) { Write-Host 'No InstallApps entries in config\baseline.json - nothing to do.' -ForegroundColor Yellow; return }
  if (-not $state.Winget) {
    Write-Host '[FAIL] winget (App Installer) was not found on this computer.' -ForegroundColor Red
    Write-Host '  It is often unavailable when MSP Tool runs as SYSTEM (RMM/Backstage) or on fresh/LTSC builds.' -ForegroundColor Yellow
    Write-Host '  Fix: update "App Installer" from the Microsoft Store, or run MSP Tool as the logged-on admin user, then retry.' -ForegroundColor Yellow
    $state.Failures.Add('Install apps: winget not found')
    return
  }
  Write-Host 'Checking which baseline apps are already installed...'
  $todo = @()
  for ($i = 0; $i -lt $installIds.Count; $i++) {
    $s = Get-WingetStatus $installIds[$i]
    Write-Host ('  [{0}] {1} : {2}' -f ($i + 1), $installIds[$i], $s)
    if ($s -ne 'installed') { $todo += $installIds[$i] }
  }
  if (-not $todo.Count) { Write-Host 'All baseline apps are already installed.' -ForegroundColor Green; return }
  Write-Host ''
  Write-Host "To install: $($todo -join ', ')"
  Write-Host 'WARNING: this downloads installers from the internet and ACCEPTS each package''s licence terms on the client''s behalf.' -ForegroundColor Yellow
  Write-Host 'Only continue if the client is licensed for / has agreed to this software.' -ForegroundColor Yellow
  $answer = Read-Host "Type YES (uppercase) to install $($todo.Count) app(s) (anything else cancels)"
  if ($answer -cne 'YES') { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
  foreach ($id in $todo) {
    Write-Host "Installing $id (this can take several minutes)..."
    try {
      $r = Invoke-Native $state.Winget @('install', '--id', $id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    } catch {
      $r = [pscustomobject]@{ Code = $null; Output = @($_.Exception.Message) }
    }
    $code = $r.Code
    if ($code -eq 0) {
      Write-Host "[OK] $id installed." -ForegroundColor Green
      $state.Changes.Add("Installed app: $id")
    } elseif ($wgAlreadyInstalled -contains $code) {
      Write-Host "[OK] $id is already installed." -ForegroundColor Green
    } elseif ($wgRestartNeeded -contains $code) {
      Write-Host "[OK] $id installed - RESTART REQUIRED to finish." -ForegroundColor Green
      $state.Changes.Add("Installed app: $id (restart required)")
      $state.Restart = $true
    } else {
      $why = if ($code -eq $wgRestartFirst) { 'a restart is required before it can install' } elseif ($null -eq $code) { 'winget could not be run' } else { 'exit code {0} (0x{1:X8})' -f $code, $code }
      Write-Host "[FAIL] $id : $why" -ForegroundColor Red
      $tail = @($r.Output | Where-Object { $_ -match '[A-Za-z]{3}' } | Select-Object -Last 4)
      foreach ($t in $tail) { Write-Host "    $($t.Trim())" }
      $state.Failures.Add("Install $id failed ($why)")
    }
  }
}

# ---------------- Main ----------------
Write-Host "Baseline config: $configPath"
$state.Winget = Resolve-Winget
if ($state.Winget -and $state.Winget -ne $wingetCmd) { Write-Host "winget found at $($state.Winget)" }
Write-Host ''
Show-CurrentState

while ($true) {
  Write-Host '--- New Workstation Baseline ---'
  Write-Host '  [1] Rename computer'
  Write-Host "  [2] Set time zone (baseline: $(if ($cfgTimeZone) { $cfgTimeZone } else { 'none' }))"
  Write-Host "  [3] Set power plan (baseline: $(if ($cfgPowerPlan) { $cfgPowerPlan } else { 'none' }))"
  Write-Host "  [4] Remove consumer apps ($($removePatterns.Count) entries in config)"
  Write-Host "  [5] Install baseline apps via winget ($($installIds.Count) in config)"
  Write-Host '  [6] Run all of the above in order (each step still asks first)'
  Write-Host '  [0] Exit'
  $sel = "$(Read-Host 'Enter a step number, 6 to run all steps, or 0 to exit')".Trim()
  if (-not $sel -or $sel -eq '0') { break }
  switch ($sel) {
    '1' { Step-RenameComputer }
    '2' { Step-SetTimeZone }
    '3' { Step-SetPowerPlan }
    '4' { Step-RemoveApps }
    '5' { Step-InstallApps }
    '6' { Step-RenameComputer; Write-Host ''; Step-SetTimeZone; Write-Host ''; Step-SetPowerPlan; Write-Host ''; Step-RemoveApps; Write-Host ''; Step-InstallApps }
    default { Write-Host 'Invalid selection.' -ForegroundColor Yellow }
  }
  Write-Host ''
}

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
if ($state.Changes.Count) { foreach ($c in $state.Changes) { Write-Host "  [CHANGED] $c" -ForegroundColor Green } } else { Write-Host '  No changes were made.' }
foreach ($f in $state.Failures) { Write-Host "  [FAILED] $f" -ForegroundColor Red }
if ($state.Restart) {
  Write-Host 'RESTART REQUIRED to finish the changes above.' -ForegroundColor Yellow
  if (Confirm-Yes 'Restart now? (y/N)') {
    Write-Host 'Restarting...' -ForegroundColor Yellow
    Restart-Computer -Force
  } else {
    Write-Host 'Restart skipped - restart the computer before handing it over.' -ForegroundColor Yellow
  }
} else {
  Write-Host 'No restart required.'
}
