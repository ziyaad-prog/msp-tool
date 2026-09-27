Write-Host 'Running DISM RestoreHealth - this may take a while...'
DISM /Online /Cleanup-Image /RestoreHealth
Write-Host "DISM exit code: $LASTEXITCODE"
