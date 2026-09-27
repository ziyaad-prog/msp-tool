$cs = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$mfr = $cs.Manufacturer
Write-Host "Manufacturer: $mfr"
Write-Host "Model: $($cs.Model)"
Write-Host "Serial: $($bios.SerialNumber) (also in ScreenConnect > General)"
Write-Host ''
$mfrLower = $mfr.ToLower()
if ($mfrLower -match 'dell') {
  Write-Host 'Dell Support: https://www.dell.com/support/home/en-us'
  Write-Host 'Tools: Dell Command | Update, Dell SupportAssist'
} elseif ($mfrLower -match 'hp|hewlett') {
  Write-Host 'HP Support: https://support.hp.com/us-en'
  Write-Host 'Tool: HP Support Assistant'
} elseif ($mfrLower -match 'lenovo') {
  Write-Host 'Lenovo Support: https://pcsupport.lenovo.com/us/en'
  Write-Host 'Tools: Lenovo System Update, Lenovo Vantage'
} else {
  Write-Host 'Look up manufacturer support page using serial number above.'
}
Write-Host ''
Write-Host 'Run Update Check + Install. Ask senior/SOC leader before network or BIOS updates.'
