if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
  Write-Host 'PSWindowsUpdate module not installed. Installing from PowerShell Gallery...'
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null }
    Install-Module PSWindowsUpdate -Force -Scope CurrentUser -ErrorAction Stop
    Write-Host 'PSWindowsUpdate installed successfully.' -ForegroundColor Green
  } catch { Write-Host "Failed to install PSWindowsUpdate: $($_.Exception.Message)" -ForegroundColor Red; return }
}
Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue
Get-WindowsUpdate -IsInstalled:$false -ErrorAction SilentlyContinue | Select-Object Title, Size, IsDownloaded | Format-Table -AutoSize | Out-String | Write-Host
