Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | ForEach-Object {
  Write-Host "Optimizing drive $($_.DriveLetter):..."
  Optimize-Volume -DriveLetter $_.DriveLetter -ReTrim -Verbose
}
Write-Host 'Drive optimization complete'
