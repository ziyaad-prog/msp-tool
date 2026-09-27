Write-Host '--- Disk Free Space ---'
$issues = @()
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
  $freePct = if ($_.Size -gt 0) { [math]::Round(($_.FreeSpace / $_.Size) * 100, 1) } else { 0 }
  $status = if ($freePct -lt 20) { 'LOW - run disk cleanup'; $issues += $_.DeviceID } else { 'OK' }
  Write-Host "  [$status] $($_.DeviceID) ${freePct}% free ($([math]::Round($_.FreeSpace/1GB,1)) GB of $([math]::Round($_.Size/1GB,1)) GB)"
}
if ($issues.Count) { Write-Host 'Less than 20% free can cause slow startup. Run disk cleanup / WinDirStat.' }
