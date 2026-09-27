Write-Host 'Running sfc /scannow - this may take a while...'
sfc /scannow
Write-Host "SFC exit code: $LASTEXITCODE"
