$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
Write-Host "Hostname: $($cs.Name)"
Write-Host "Domain/Workgroup: $($cs.Domain)"
Write-Host "Manufacturer: $($cs.Manufacturer)"
Write-Host "Model: $($cs.Model)"
Write-Host "Serial: $($bios.SerialNumber)"
