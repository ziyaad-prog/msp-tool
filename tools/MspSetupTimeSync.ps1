Stop-Service w32time -Force -ErrorAction SilentlyContinue
Start-Service w32time
w32tm /resync /force
Write-Host 'Time sync completed'
