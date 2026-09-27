$cs = Get-CimInstance Win32_ComputerSystem
if (-not $cs.PartOfDomain) { Write-Host 'Workstation is not domain joined.' -ForegroundColor Yellow; return }
Write-Host "Current domain: $($cs.Domain)"
$confirm = Read-Host 'Type YES to remove this workstation from the domain'
if ($confirm -ne 'YES') { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
$workgroup = Read-Host 'Enter workgroup name to join (default: WORKGROUP)'
if (-not $workgroup) { $workgroup = 'WORKGROUP' }
$cred = Get-Credential -Message 'Enter domain account with rights to remove this computer from the domain'
if (-not $cred) { Write-Host 'Credentials required - aborted.' -ForegroundColor Yellow; return }
$stageOnly = Read-Host 'Stage the unjoin without restarting now? (Y/n)'
try {
  Remove-Computer -UnjoinDomainCredential $cred -WorkgroupName $workgroup -Force -ErrorAction Stop
  Write-Host "SUCCESS: Removed from domain and joined workgroup '$workgroup'. Restart is required." -ForegroundColor Green
  if ($stageOnly -match '^[Yy]') {
    Write-Host 'Unjoin staged. Reboot later to complete the change.' -ForegroundColor Yellow
    return
  }
  $r = Read-Host 'Restart now? (y/N)'
  if ($r -match '^(y|yes)$') { Restart-Computer -Force } else { Write-Host 'Reboot later to complete the unjoin.' -ForegroundColor Yellow }
} catch {
  Write-Host "FAILED to remove workstation from domain: $($_.Exception.Message)" -ForegroundColor Red
}
