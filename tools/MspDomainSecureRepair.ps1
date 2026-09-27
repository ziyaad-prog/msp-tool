$cs = Get-CimInstance Win32_ComputerSystem
if (-not $cs.PartOfDomain) { Write-Host 'Workstation is not domain joined.' -ForegroundColor Yellow; return }
Write-Host "Testing secure channel for domain '$($cs.Domain)'..."
if (Test-ComputerSecureChannel) {
  Write-Host 'Secure channel is HEALTHY - no repair needed.' -ForegroundColor Green
} else {
  Write-Host 'Secure channel is BROKEN - repairing...' -ForegroundColor Yellow
  if (Test-ComputerSecureChannel -Repair) {
    Write-Host 'Secure channel repaired successfully.' -ForegroundColor Green
    $r = Read-Host 'Restart now? (y/N)'
    if ($r -match '^(y|yes)$') { Restart-Computer -Force }
  } else {
    Write-Host 'Repair failed - leave and rejoin the domain instead.' -ForegroundColor Red
  }
}
