# BitLocker Status - read-only. NEVER prints recovery passwords (tool output goes to the MSP Tool log and transcript).
$osDrive = $env:SystemDrive   # e.g. C:
# BitLocker-API events (log Microsoft-Windows-BitLocker/BitLocker Management), IDs verified against the provider manifest:
$escrowSuccess = @{ 845 = 'Entra ID'; 784 = 'Active Directory'; 513 = 'Active Directory'; 828 = 'Microsoft account'; 897 = 'Microsoft account' }
$escrowFailure = @{ 846 = 'Entra ID'; 785 = 'Active Directory'; 514 = 'Active Directory'; 829 = 'Microsoft account'; 898 = 'Microsoft account' }
$escrowLog = 'Microsoft-Windows-BitLocker/BitLocker Management'

try {
  $volumes = @(Get-BitLockerVolume -ErrorAction Stop)
} catch {
  Write-Host "Could not read BitLocker status: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host 'BitLocker status needs administrator rights (and the BitLocker feature - not present on some Home editions).'
  return
}
$volumes | Select-Object MountPoint, VolumeStatus, EncryptionPercentage, ProtectionStatus | Format-Table -AutoSize | Out-String | Write-Host

# --- Encryption method + protector types (types only - no key material) for all fixed volumes ---
Write-Host '--- Fixed volumes: encryption method and protectors ---' -ForegroundColor Cyan
$fixed = @($volumes | Where-Object { "$($_.VolumeType)" -in @('OperatingSystem', 'FixedData') -or -not $_.VolumeType })
foreach ($v in $fixed) {
  $types = @($v.KeyProtector | ForEach-Object { "$($_.KeyProtectorType)" } | Group-Object | ForEach-Object { if ($_.Count -gt 1) { "$($_.Name) x$($_.Count)" } else { $_.Name } })
  $prot = if ($types.Count) { $types -join ', ' } else { '(none)' }
  $color = if ("$($v.ProtectionStatus)" -eq 'On') { 'Green' } elseif ("$($v.VolumeStatus)" -eq 'FullyDecrypted') { 'Red' } else { 'Yellow' }
  Write-Host ("  {0,-4} {1,-16} {2,-18} method: {3,-12} protectors: {4}" -f $v.MountPoint, $v.VolumeType, "$($v.VolumeStatus)", "$($v.EncryptionMethod)", $prot) -ForegroundColor $color
  if ("$($v.VolumeStatus)" -ne 'FullyDecrypted' -and "$($v.ProtectionStatus)" -ne 'On') {
    Write-Host '       Protection is OFF (suspended, or encrypted with a clear key waiting for activation) - data is readable without a key.' -ForegroundColor Yellow
  }
  if (@($v.KeyProtector | Where-Object { "$($_.KeyProtectorType)" -eq 'RecoveryPassword' }).Count -eq 0 -and "$($v.VolumeStatus)" -ne 'FullyDecrypted') {
    Write-Host '       No RecoveryPassword protector - there is no 48-digit recovery key to escrow for this volume.' -ForegroundColor Yellow
  }
}

# --- OS drive recovery protector IDs (IDs only) ---
$osVol = $volumes | Where-Object { $_.MountPoint -eq $osDrive } | Select-Object -First 1
$kp = @($osVol.KeyProtector | Where-Object { "$($_.KeyProtectorType)" -eq 'RecoveryPassword' })
if ($kp.Count) {
  Write-Host ''
  Write-Host "Recovery Password Protector(s) for ${osDrive}"
  $kp | Select-Object KeyProtectorId, KeyProtectorType | Format-List | Out-String | Write-Host
  Write-Host 'Recovery password not shown - tool output is saved to the MSP Tool log and transcript.'
  Write-Host 'To view it, check AD/Entra ID/your RMM, or run in a separate (unlogged) elevated session:'
  Write-Host "  manage-bde -protectors -get $osDrive -Type RecoveryPassword"
} else {
  Write-Host ''
  Write-Host "No RecoveryPassword protector found on ${osDrive}"
}

# --- Key escrow evidence from the BitLocker-API event log ---
Write-Host ''
Write-Host "--- Recovery key escrow ($osDrive) ---" -ForegroundColor Cyan
$ids = @($escrowSuccess.Keys) + @($escrowFailure.Keys)
$events = @()
try {
  $events = @(Get-WinEvent -FilterHashtable @{ LogName = $escrowLog; Id = $ids } -ErrorAction Stop)
} catch {
  if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound' -and $_.Exception.Message -notmatch 'No events were found') {
    Write-Host "Could not read the $escrowLog log: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}
# Keep events for the OS volume: messages that name the drive, plus AD events (784/785/513/514) that do not name a volume
$noVolumeIds = @(784, 785, 513, 514)
$osEvents = @($events | Where-Object { $noVolumeIds -contains $_.Id -or "$($_.Message)" -match [regex]::Escape($osDrive) } | Sort-Object TimeCreated -Descending)
$currentIds = @($kp | ForEach-Object { "$($_.KeyProtectorId)".Trim('{}') })
$successes = @($osEvents | Where-Object { $escrowSuccess.ContainsKey([int]$_.Id) })
if ($successes.Count) {
  foreach ($target in @($successes | ForEach-Object { $escrowSuccess[[int]$_.Id] } | Select-Object -Unique)) {
    $last = $successes | Where-Object { $escrowSuccess[[int]$_.Id] -eq $target } | Select-Object -First 1
    $matchesCurrent = @($currentIds | Where-Object { $_ -and "$($last.Message)" -match [regex]::Escape($_) }).Count -gt 0
    Write-Host ("Key escrow: backed up to {0} on {1:yyyy-MM-dd HH:mm} (event {2})" -f $target, $last.TimeCreated, $last.Id) -ForegroundColor Green
    if ($currentIds.Count -and $matchesCurrent) { Write-Host '            protector ID in the event matches the current recovery password protector.' -ForegroundColor Green }
    elseif ($currentIds.Count) { Write-Host '            protector ID in the event does NOT match the current recovery password protector - the key may have been rotated since; verify in the portal.' -ForegroundColor Yellow }
  }
} else {
  Write-Host 'Key escrow: no backup event found - verify in Entra/AD before relying on it.' -ForegroundColor Yellow
}
$lastFail = $osEvents | Where-Object { $escrowFailure.ContainsKey([int]$_.Id) } | Select-Object -First 1
if ($lastFail -and (-not $successes.Count -or $lastFail.TimeCreated -gt $successes[0].TimeCreated)) {
  $firstLine = ("$($lastFail.Message)" -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Skip 1 | Select-Object -First 1)
  Write-Host ("Latest backup FAILURE: {0} on {1:yyyy-MM-dd HH:mm} (event {2}){3}" -f $escrowFailure[[int]$lastFail.Id], $lastFail.TimeCreated, $lastFail.Id, $(if ($firstLine) { " - $($firstLine.Trim())" } else { '' })) -ForegroundColor Yellow
}
Write-Host '(The event log only shows what this PC attempted - older events may have rolled over. The portal/AD is the source of truth.)'

$partOfDomain = $false
try { $partOfDomain = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain } catch { }
$entraJoined = $false
try { $entraJoined = [bool](@(dsregcmd /status 2>$null) -match '^\s*AzureAdJoined\s*:\s*YES') } catch { }
if ($partOfDomain) { Write-Host 'Domain joined: an admin can verify AD escrow on the computer object (BitLocker Recovery tab / msFVE-RecoveryInformation child objects).' }
if ($entraJoined) { Write-Host 'Entra joined: verify in Entra admin center > Devices > this device > BitLocker keys (or Intune > Devices > Recovery keys).' }
if (-not $partOfDomain -and -not $entraJoined) { Write-Host 'Not domain or Entra joined: the key can only be escrowed to a Microsoft account, a file/print-out, or your RMM - confirm where it is stored.' -ForegroundColor Yellow }
