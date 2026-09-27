Write-Host 'Running gpupdate /force...'
gpupdate /force
Write-Host ''
Write-Host 'Applied Group Policy results:'
try {
  gpresult /r
} catch {
  Write-Host "gpresult failed: $($_.Exception.Message)" -ForegroundColor Red
}
