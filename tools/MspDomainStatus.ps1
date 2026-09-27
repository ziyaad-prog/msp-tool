$cs = Get-CimInstance Win32_ComputerSystem
Write-Host "Computer Name : $env:COMPUTERNAME"
if ($cs.PartOfDomain) {
  Write-Host "Domain Joined : YES" -ForegroundColor Green
  Write-Host "Domain        : $($cs.Domain)" -ForegroundColor Green
  try {
    if (Test-ComputerSecureChannel) { Write-Host 'Secure Channel: HEALTHY' -ForegroundColor Green }
    else { Write-Host 'Secure Channel: BROKEN - run repair tool or rejoin' -ForegroundColor Red }
  } catch { Write-Host "Secure Channel: ERROR - $($_.Exception.Message)" -ForegroundColor Red }
} else {
  Write-Host "Domain Joined : NO" -ForegroundColor Yellow
  Write-Host "Workgroup     : $($cs.Domain)" -ForegroundColor Yellow
}
