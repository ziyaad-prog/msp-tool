Write-Host 'Running Disk Cleanup...'
cleanmgr /sagerun:1 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host 'Launching interactive Disk Cleanup...'
  cleanmgr /d C:
}
Write-Host 'Disk Cleanup initiated'
