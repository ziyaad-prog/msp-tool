$runKeys = @('HKLM:\Software\Microsoft\Windows\CurrentVersion\Run','HKCU:\Software\Microsoft\Windows\CurrentVersion\Run','HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce','HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce')
$startupDirs = @([Environment]::GetFolderPath('Startup'), "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup")
while ($true) {
  $entries = @()
  foreach ($p in $runKeys) {
    if (Test-Path $p) {
      Get-ItemProperty $p -ErrorAction SilentlyContinue | ForEach-Object { $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object {
        $entries += [PSCustomObject]@{ Type = 'Registry'; Location = $p; Name = $_.Name; Value = $_.Value; FullPath = $p }
      } }
    }
  }
  foreach ($dir in $startupDirs) {
    if (Test-Path $dir) {
      Get-ChildItem $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
        $entries += [PSCustomObject]@{ Type = 'Shortcut'; Location = $dir; Name = $_.Name; Value = $_.FullName; FullPath = $_.FullName }
      }
    }
  }
  if (-not $entries.Count) { Write-Host 'No startup entries found.' -ForegroundColor Green; return }
  Write-Host '--- Startup Entries ---'
  for ($i = 0; $i -lt $entries.Count; $i++) {
    Write-Host ("  [{0}] {1} ({2})" -f ($i + 1), $entries[$i].Name, $entries[$i].Type)
  }
  Write-Host ''
  $selection = Read-Host 'Enter the number to remove from startup, or 0 to exit'
  if (-not $selection -or $selection -eq '0') { Write-Host 'Exiting tool.' -ForegroundColor Yellow; return }
  $idx = [int]$selection - 1
  if ($idx -lt 0 -or $idx -ge $entries.Count) { Write-Host 'Invalid selection.' -ForegroundColor Yellow; continue }
  $entry = $entries[$idx]
  try {
    if ($entry.Type -eq 'Registry') {
      Remove-ItemProperty -Path $entry.FullPath -Name $entry.Name -Force -ErrorAction Stop
    } else {
      Remove-Item -LiteralPath $entry.FullPath -Force -ErrorAction Stop
    }
    Write-Host "REMOVED from startup: $($entry.Name)" -ForegroundColor Green
  } catch {
    Write-Host "FAILED to remove $($entry.Name): $($_.Exception.Message)" -ForegroundColor Red
  }
  Write-Host ''
}
