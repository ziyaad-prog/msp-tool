$tempPath = $env:TEMP
Write-Host "Clearing: $tempPath"
$removed = 0; $skipped = 0
Get-ChildItem $tempPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
  try { if ($_.PSIsContainer) { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop } else { $removed += $_.Length; Remove-Item $_.FullName -Force -ErrorAction Stop } } catch { $skipped++ }
}
Write-Host "Removed ~$([math]::Round($removed/1MB,1)) MB. Skipped $skipped locked items (OK to skip)."
