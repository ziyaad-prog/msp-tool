Write-Host '--- Top 10 by CPU ---'
Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Name, Id, @{N='CPU_s';E={[math]::Round($_.CPU,1)}}, @{N='MemMB';E={[math]::Round($_.WorkingSet64/1MB,0)}} | Format-Table -AutoSize | Out-String | Write-Host
Write-Host '--- Top 10 by Memory ---'
Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 10 Name, Id, @{N='MemMB';E={[math]::Round($_.WorkingSet64/1MB,0)}}, @{N='CPU_s';E={[math]::Round($_.CPU,1)}} | Format-Table -AutoSize | Out-String | Write-Host
Write-Host 'High svchost: try Windows Update or driver update. High Chrome: close unused tabs.'
