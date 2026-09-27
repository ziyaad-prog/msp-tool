Stop-Service WSearch -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Service WSearch
Write-Host 'Search service restarted. Index will rebuild in background.'
