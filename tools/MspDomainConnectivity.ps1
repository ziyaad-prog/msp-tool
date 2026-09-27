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

$domain = $null
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain) { $domain = $cs.Domain }
if (-not $domain) { $domain = $env:USERDNSDOMAIN }
if ($domain) {
  $answer = Read-Host "Enter target domain FQDN, or press Enter to use suggested '$domain'"
  if ($answer) { $domain = $answer }
} else {
  $domain = Read-Host 'Enter target domain FQDN (e.g. corp.contoso.com)'
}
if (-not $domain) { Write-Host 'No domain entered - aborted.' -ForegroundColor Yellow; return }
try {
  $ips = [System.Net.Dns]::GetHostAddresses($domain) | Where-Object AddressFamily -eq 'InterNetwork'
  if (-not $ips) { throw 'no A records' }
  Write-Host "[OK] DNS      : $domain -> $($ips[0].IPAddressToString)" -ForegroundColor Green
} catch {
  Write-Host "[FAIL] DNS    : cannot resolve '$domain'." -ForegroundColor Red
}
try {
  $ctx = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext([System.DirectoryServices.ActiveDirectory.DirectoryContextType]::Domain, $domain)
  $ad = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($ctx)
  $dc = $ad.DomainControllers | Select-Object -First 1
  Write-Host "[OK] DC found : $($dc.Name)" -ForegroundColor Green
  $tcp = New-Object System.Net.Sockets.TcpClient
  if (-not $tcp.ConnectAsync($dc.IPAddress, 389).Wait(5000)) { throw "LDAP timeout on $($dc.IPAddress)" }
  $tcp.Close()
  Write-Host "[OK] LDAP     : $($dc.IPAddress):389 reachable" -ForegroundColor Green
  Write-Host ''
  Write-Host "SUCCESS: Workstation can reach domain '$domain'." -ForegroundColor Green
} catch {
  Write-Host "[FAIL] AD/LDAP : $($_.Exception.Message)" -ForegroundColor Red
  $vpns = Get-VpnList
  if ($vpns.Count) {
    Write-Host ''
    Write-Host 'VPN connections found on this workstation:' -ForegroundColor Yellow
    for ($i = 0; $i -lt $vpns.Count; $i++) {
      $scope = if ($vpns[$i].AllUser) { 'all users' } else { 'current user' }
      Write-Host ('  [{0}] {1} ({2}, {3})' -f ($i + 1), $vpns[$i].Name, $vpns[$i].Status, $scope)
    }
    $choice = Read-Host 'Enter VPN number to start, or press Enter to skip'
    if ($choice -and $choice -ne '0') {
      if ($choice -notmatch '^\d+$' -or [int]$choice -lt 1 -or [int]$choice -gt $vpns.Count) { Write-Host 'Invalid selection.' -ForegroundColor Yellow }
      elseif ($vpns[[int]$choice - 1].Status -eq 'Connected') { Write-Host "VPN '$($vpns[[int]$choice - 1].Name)' is already connected - the domain is still unreachable over it." -ForegroundColor Yellow }
      elseif (Start-VpnEntry $vpns[[int]$choice - 1]) {
        $run = Read-Host 'Run Domain Connectivity Test again now? (Y/n)'
        if ($run -notmatch '^[Nn]') { & $MyInvocation.MyCommand.ScriptBlock }
      }
    }
  } else { Write-Host 'No VPN connections found on this workstation.' -ForegroundColor Yellow }
}
