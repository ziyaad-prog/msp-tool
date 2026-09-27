$issues = @()
$warnings = @()
Write-Host '=== LENET Spec Recommendation Check ==='
Write-Host 'Reference: LENET - TECHNO STACK - V3.0'
Write-Host ''

# Storage
Write-Host '--- Storage (SSD required since 2021) ---'
try {
  $disks = Get-PhysicalDisk -ErrorAction Stop
  foreach ($d in $disks) {
    $model = $d.FriendlyName
    $media = $d.MediaType
    $status = 'OK'
    if ($media -eq 'HDD') { $status = 'BAD - HDD is a performance bottleneck'; $issues += "HDD detected: $model" }
    elseif ($media -eq 'Unspecified' -or $media -eq 'Unknown') {
      if ($model -match 'SSD|NVMe|Solid') { $status = 'OK (model suggests SSD)' }
      elseif ($model -match 'ST[0-9]|WDC WD|Hitachi|TOSHIBA.*DT|HGST') { $status = 'BAD - Model suggests HDD'; $issues += "Possible HDD: $model" }
      else { $status = 'CHECK - Verify in CWA Storage tile'; $warnings += "Media type '$media' for $model - confirm in CWA" }
    }
    else { $status = 'OK' }
    Write-Host "  [$status] $model ($media)"
  }
} catch {
  Get-CimInstance Win32_DiskDrive | ForEach-Object {
    $m = $_.Model
    if ($m -match 'SSD|NVMe') { Write-Host "  [OK] $m" } else { Write-Host "  [CHECK] $m - verify SSD in CWA"; $warnings += $m }
  }
}

# RAM
Write-Host ''
Write-Host '--- RAM ---'
$ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
if ($ramGb -lt 8) { Write-Host "  [BAD] ${ramGb} GB (< 8 GB minimum)"; $issues += "RAM ${ramGb} GB below 8 GB minimum" }
elseif ($ramGb -le 16) { Write-Host "  [OK] ${ramGb} GB (>= 8 GB, good for standard users)" }
else { Write-Host "  [VERY GOOD] ${ramGb} GB (> 16 GB)" }

# CPU
Write-Host ''
Write-Host '--- CPU ---'
$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1)
Write-Host "  CPU: $($cpu.Name)"
Write-Host '  Action: Search at https://www.cpubenchmark.net/cpu_list.php'
Write-Host '  Score < 4000 = bad | > 4000 = okay | > 5000 = very good'

# Workstation age
Write-Host ''
Write-Host '--- Workstation Age ---'
$os = Get-CimInstance Win32_OperatingSystem
# Feature updates reset Win32_OperatingSystem.InstallDate; earlier install dates survive under
# HKLM\SYSTEM\Setup\Source OS (Updated on ...). A reimage resets all of them - hence the warranty hint.
$installDates = @($os.InstallDate)
Get-ChildItem 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Source OS*' } | ForEach-Object {
  $v = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).InstallDate
  if ($v) { $installDates += [DateTimeOffset]::FromUnixTimeSeconds([int64]$v).LocalDateTime }
}
$installDate = $installDates | Where-Object { $_ } | Sort-Object | Select-Object -First 1
$biosDate = (Get-CimInstance Win32_BIOS).ReleaseDate
if ($installDate) {
  $age = (New-TimeSpan -Start $installDate -End (Get-Date)).Days
  $years = [math]::Round($age / 365, 1)
  Write-Host "  Earliest Windows install found: $($installDate.ToString('yyyy-MM-dd')) ($years years ago)"
  if ($biosDate) { Write-Host "  BIOS release date: $($biosDate.ToString('yyyy-MM-dd')) (updates move this forward too)" }
  Write-Host '  Note: a reimage resets install dates - confirm the real age with a warranty lookup (serial below).'
  if ($years -lt 1) { Write-Host '  [INFO] < 1 year - warranty likely active, run troubleshooting first' }
  elseif ($years -ge 4) { Write-Host '  [WARN] > 4 years - recommend replacement (2021+ spec)'; $warnings += 'Workstation older than 4 years' }
  else { Write-Host '  [INFO] 1-3 years - consult support leader if we sold this machine' }
}
$bios = Get-CimInstance Win32_BIOS
Write-Host "  Serial (warranty lookup): $($bios.SerialNumber)"
Write-Host "  Manufacturer: $((Get-CimInstance Win32_ComputerSystem).Manufacturer)"

Write-Host ''
Write-Host '=== Summary ==='
if ($issues.Count -eq 0 -and $warnings.Count -eq 0) { Write-Host 'All automated checks passed. Proceed to troubleshooting if still slow.' }
else {
  if ($issues.Count) { Write-Host 'ISSUES:'; $issues | ForEach-Object { Write-Host "  - $_" } }
  if ($warnings.Count) { Write-Host 'WARNINGS:'; $warnings | ForEach-Object { Write-Host "  - $_" } }
  Write-Host 'If below spec, speed-up attempts may have limited success.'
}
