while ($true) {
  $services = Get-CimInstance Win32_Service | Where-Object { $_.State -eq 'Running' -and $_.PathName -notmatch 'Windows|Microsoft|windows|system32\\svchost' } | Sort-Object DisplayName
  if (-not $services) { Write-Host 'No running non-Microsoft services found.' -ForegroundColor Green; return }
  Write-Host '--- Running Non-Microsoft Services ---'
  for ($i = 0; $i -lt $services.Count; $i++) {
    $s = $services[$i]
    $path = if ($s.PathName.Length -gt 80) { $s.PathName.Substring(0,80) + '...' } else { $s.PathName }
    Write-Host ("  [{0}] {1} ({2}) | {3}" -f ($i + 1), $s.DisplayName, $s.Name, $path)
  }
  Write-Host ''
  $selection = Read-Host 'Enter the service number to manage, or 0 to exit'
  if (-not $selection -or $selection -eq '0') { Write-Host 'Exiting tool.' -ForegroundColor Yellow; return }
  $index = [int]$selection - 1
  if ($index -lt 0 -or $index -ge $services.Count) { Write-Host 'Invalid selection.' -ForegroundColor Yellow; continue }
  $s = $services[$index]
  Write-Host ''
  Write-Host ("Selected: [{0}] {1} ({2})" -f ($index + 1), $s.DisplayName, $s.Name)
  Write-Host '  [1] Open services.msc'
  Write-Host '  [2] Disable service'
  Write-Host '  [3] Set to Manual + stop'
  Write-Host '  [4] Return to service list'
  Write-Host '  [5] Exit tool'
  $action = Read-Host 'Select an option'
  switch ($action) {
    '1' { Start-Process services.msc; Write-Host 'Opened services.msc.' -ForegroundColor Green }
    '2' { try { Set-Service -Name $s.Name -StartupType Disabled -ErrorAction Stop; Stop-Service -Name $s.Name -Force -ErrorAction Stop; Write-Host "[DISABLED] $($s.DisplayName)" -ForegroundColor Green } catch { Write-Host "[FAILED] $($s.DisplayName): $($_.Exception.Message)" -ForegroundColor Red } }
    '3' { try { Set-Service -Name $s.Name -StartupType Manual -ErrorAction Stop; Stop-Service -Name $s.Name -Force -ErrorAction Stop; Write-Host "[MANUAL + STOPPED] $($s.DisplayName)" -ForegroundColor Green } catch { Write-Host "[FAILED] $($s.DisplayName): $($_.Exception.Message)" -ForegroundColor Red } }
    '4' { continue }
    '5' { Write-Host 'Exiting tool.' -ForegroundColor Yellow; return }
    default { Write-Host 'Invalid selection.' -ForegroundColor Yellow }
  }
  Write-Host ''
  Write-Host 'Do NOT disable Adobe, Broadcom, Realtek, Intel, AD, LENET services, driver-related.'
}
