# Common rasdial error codes -> hint shown to the technician
$rasdialHints = @{
  623 = 'the VPN entry was not found in the phonebook'
  691 = 'user name or password was rejected'
  703 = 'the connection needs credentials - connect once from Settings > Network & internet > VPN and tick "Remember my sign-in info"'
  800 = 'could not reach the VPN server (check internet access, server address, firewall)'
  809 = 'the network blocked the VPN connection (IPsec/NAT-T ports)'
  868 = 'the VPN server name could not be resolved (DNS)'
}

# Lists VPN connections from the all-users and the current-user phonebooks, remembering which list each came from
function Get-VpnList {
  $list = @()
  try { foreach ($v in @(Get-VpnConnection -AllUserConnection -ErrorAction Stop)) { $list += [pscustomobject]@{ Name = $v.Name; Status = $v.ConnectionStatus; AllUser = $true } } } catch { }
  try { foreach ($v in @(Get-VpnConnection -ErrorAction Stop)) { $list += [pscustomobject]@{ Name = $v.Name; Status = $v.ConnectionStatus; AllUser = $false } } } catch { }
  return ,@($list | Sort-Object @{ Expression = 'Name' }, @{ Expression = 'AllUser'; Descending = $true })
}

# Dials a VPN with rasdial (native exe: exit code 0 = connected). Returns $true on success.
function Start-VpnEntry {
  param($Vpn)
  $scope = if ($Vpn.AllUser) { 'all users' } else { 'current user' }
  $pbk = if ($Vpn.AllUser) { Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk' } else { Join-Path $env:APPDATA 'Microsoft\Network\Connections\Pbk\rasphone.pbk' }
  $rasArgs = @($Vpn.Name)
  if (Test-Path -LiteralPath $pbk) { $rasArgs += "/PHONEBOOK:$pbk" }
  Write-Host "Connecting '$($Vpn.Name)' ($scope connection)..."
  try { $out = @(& { $ErrorActionPreference = 'Continue'; rasdial @rasArgs 2>&1 }); $code = $LASTEXITCODE }
  catch { Write-Host "[FAIL] VPN start failed: $($_.Exception.Message)" -ForegroundColor Red; return $false }
  foreach ($line in $out) { if ("$line".Trim()) { Write-Host "  $line" } }
  if ($code -eq 0) { Write-Host "[OK] VPN connected: $($Vpn.Name)" -ForegroundColor Green; return $true }
  $hint = if ($rasdialHints.ContainsKey([int]$code)) { " - $($rasdialHints[[int]$code])" } else { '' }
  Write-Host "[FAIL] VPN did not connect: rasdial error $code$hint" -ForegroundColor Red
  return $false
}

$vpns = Get-VpnList
if (-not $vpns.Count) { Write-Host 'No VPN connections found on this workstation.' -ForegroundColor Yellow; return }
Write-Host 'VPN connections found:'
for ($i = 0; $i -lt $vpns.Count; $i++) {
  $scope = if ($vpns[$i].AllUser) { 'all users' } else { 'current user' }
  Write-Host ('  [{0}] {1} ({2}, {3})' -f ($i + 1), $vpns[$i].Name, $vpns[$i].Status, $scope)
}
$choice = Read-Host 'Enter VPN number to start, or 0 to cancel'
if (-not $choice -or $choice -eq '0') { Write-Host 'Cancelled.' -ForegroundColor Yellow; return }
if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $vpns.Count) { Write-Host 'Invalid selection.' -ForegroundColor Yellow; return }
$vpn = $vpns[[int]$choice - 1]
if ($vpn.Status -eq 'Connected') { Write-Host "[OK] VPN already connected: $($vpn.Name)" -ForegroundColor Green; return }
if (Start-VpnEntry $vpn) {
  Write-Host 'Next: run the Domain Connectivity Test tool to confirm the domain is reachable over the VPN.' -ForegroundColor Yellow
}
