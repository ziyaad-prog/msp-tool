# Quick network fix: flush DNS, release/renew DHCP, re-register DNS, then re-test connectivity.
# Lighter than "Network Stack Reset" (MspRepairNetworkReset): no winsock/IP reset and no restart needed.
# Release/renew and DNS registration need admin; the DNS flush and the re-tests do not.
# Public name resolved to test DNS after the fix
$testDnsName = 'www.microsoft.com'
# Well-known host tested for HTTPS reachability
$testHttpsHost = 'www.microsoft.com'
$testHttpsPort = 443
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-AdapterInfo {
  $list = @()
  foreach ($c in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.NetAdapter -and "$($_.NetAdapter.Status)" -eq 'Up' })) {
    $ipIf = Get-NetIPInterface -InterfaceIndex $c.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    $list += [pscustomobject]@{
      Alias       = $c.InterfaceAlias
      Description = $c.InterfaceDescription
      IPv4        = (@($c.IPv4Address | ForEach-Object { $_.IPAddress }) -join ', ')
      Gateway     = (@($c.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ', ')
      Dns         = (@($c.DNSServer | Where-Object { "$($_.AddressFamily)" -match '^(2|IPv4|InterNetwork)$' } | ForEach-Object { $_.ServerAddresses }) -join ', ')
      Dhcp        = [bool]($ipIf -and "$($ipIf.Dhcp)" -eq 'Enabled')
    }
  }
  return $list
}
function Show-Adapters {
  param($Adapters)
  foreach ($a in $Adapters) {
    $mode = if ($a.Dhcp) { 'DHCP' } else { 'static' }
    Write-Host ('  {0} ({1}) - {2}' -f $a.Alias, $a.Description, $mode)
    Write-Host ('      IP: {0} | Gateway: {1} | DNS: {2}' -f $(if ($a.IPv4) { $a.IPv4 } else { 'none' }), $(if ($a.Gateway) { $a.Gateway } else { 'none' }), $(if ($a.Dns) { $a.Dns } else { 'none' }))
  }
}
$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
  param($Step, [bool]$Ok, $Detail)
  $r = if ($Ok) { 'OK' } else { 'FAIL' }
  $results.Add([pscustomobject]@{ Step = $Step; Result = $r; Detail = $Detail })
  $text = if ($Detail) { "[$r] $Step - $Detail" } else { "[$r] $Step" }
  Write-Host $text -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}
function Invoke-Ipconfig {
  param([string[]]$IpArgs)
  try {
    $global:LASTEXITCODE = 0
    $out = @(ipconfig @IpArgs)
    $code = $LASTEXITCODE
  } catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
  $detail = ''
  if ($code -ne 0) {
    $detail = @($out | Where-Object { "$_" -match 'error|unable|fail|not|denied' } | Select-Object -First 1) -join ''
    if (-not $detail) { $detail = "exit code $code" }
  }
  [pscustomobject]@{ Ok = ($code -eq 0); Detail = "$detail".Trim() }
}

# ---------------- Current state ----------------
$adapters = @(Get-AdapterInfo)
Write-Host '--- Connected adapters ---' -ForegroundColor Cyan
if (-not $adapters.Count) {
  Write-Host 'No connected network adapters found. Check the cable / Wi-Fi first (or use Network Diagnostics).' -ForegroundColor Red
  return
}
Show-Adapters $adapters
Write-Host ''

# ---------------- Choose adapters for release/renew ----------------
$renewTargets = @()
if ($isAdmin) {
  $dhcp = @($adapters | Where-Object { $_.Dhcp })
  if ($dhcp.Count) {
    for ($i = 0; $i -lt $dhcp.Count; $i++) { Write-Host ('  [{0}] {1} ({2})' -f ($i + 1), $dhcp[$i].Alias, $dhcp[$i].IPv4) }
    while ($true) {
      $sel = Read-Host 'Enter an adapter number to release/renew, A for all listed, S to skip release/renew, or 0 to exit'
      if (-not $sel -or $sel -eq '0') { Write-Host 'Exiting tool.' -ForegroundColor Yellow; return }
      if ($sel -match '^[Aa]$') { $renewTargets = $dhcp; break }
      if ($sel -match '^[Ss]$') { break }
      if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $dhcp.Count) { $renewTargets = @($dhcp[[int]$sel - 1]); break }
      Write-Host 'Invalid selection.' -ForegroundColor Yellow
    }
  } else {
    Write-Host 'No connected DHCP adapters (static IPs only) - release/renew will be skipped.' -ForegroundColor Yellow
  }
} else {
  Write-Host 'Not running as administrator: only the DNS flush and the re-tests will run (release/renew and DNS registration need admin).' -ForegroundColor Yellow
}

# ---------------- Confirm ----------------
Write-Host ''
Write-Host 'Steps:'
Write-Host '  - ipconfig /flushdns'
if ($renewTargets.Count) { Write-Host "  - ipconfig /release + /renew on: $(($renewTargets | ForEach-Object { $_.Alias }) -join ', ')" }
if ($isAdmin) { Write-Host '  - ipconfig /registerdns' }
Write-Host "  - re-test: gateway ping, DNS lookup of $testDnsName, HTTPS to ${testHttpsHost}:$testHttpsPort"
if ($renewTargets.Count) {
  Write-Host 'WARNING: release/renew drops the connection for a few seconds. A remote session (ScreenConnect, RDP, VPN)' -ForegroundColor Yellow
  Write-Host 'may disconnect briefly and should reconnect by itself. If no DHCP server answers, the adapter stays offline.' -ForegroundColor Yellow
}
$confirm = Read-Host 'Run these steps now? (y/N)'
if ($confirm -notmatch '^[Yy]') { Write-Host 'Cancelled. Nothing was changed.' -ForegroundColor Yellow; return }

# ---------------- Fix ----------------
Write-Host ''
Write-Host '--- Running ---' -ForegroundColor Cyan
$r = Invoke-Ipconfig @('/flushdns')
Add-Result 'Flush DNS cache' $r.Ok $r.Detail
foreach ($a in $renewTargets) {
  # Release and renew back to back per adapter to keep the outage short
  $r = Invoke-Ipconfig @('/release', $a.Alias)
  Add-Result "Release $($a.Alias)" $r.Ok $r.Detail
  Write-Host "Renewing $($a.Alias) (can take up to a minute)..."
  $r = Invoke-Ipconfig @('/renew', $a.Alias)
  Add-Result "Renew $($a.Alias)" $r.Ok $r.Detail
}
if ($isAdmin) {
  $r = Invoke-Ipconfig @('/registerdns')
  Add-Result 'Register DNS' $r.Ok $r.Detail
}
if ($renewTargets.Count) { Start-Sleep -Seconds 3 }

# ---------------- Re-test ----------------
Write-Host ''
Write-Host '--- Re-test ---' -ForegroundColor Cyan
$oldProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
try {
  $after = @(Get-AdapterInfo)
  Show-Adapters $after
  $gateways = @($after | ForEach-Object { $_.Gateway -split ',\s*' } | Where-Object { $_ } | Select-Object -Unique)
  if (-not $gateways.Count) { Add-Result 'Gateway ping' $false 'no default gateway on any connected adapter' }
  foreach ($gw in $gateways) {
    $ok = [bool](Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue)
    Add-Result "Gateway ping $gw" $ok $(if ($ok) { '' } else { 'no reply (some routers block ping)' })
  }
  try {
    $ans = @(Resolve-DnsName -Name $testDnsName -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress })
    if ($ans.Count) { Add-Result "DNS lookup $testDnsName" $true "-> $($ans[0].IPAddress)" }
    else { Add-Result "DNS lookup $testDnsName" $false 'no address returned' }
  } catch { Add-Result "DNS lookup $testDnsName" $false $_.Exception.Message }
  try {
    $ok = [bool](Test-NetConnection -ComputerName $testHttpsHost -Port $testHttpsPort -InformationLevel Quiet -WarningAction SilentlyContinue)
    Add-Result "HTTPS ${testHttpsHost}:$testHttpsPort" $ok ''
  } catch { Add-Result "HTTPS ${testHttpsHost}:$testHttpsPort" $false $_.Exception.Message }
} finally { $ProgressPreference = $oldProgress }

# ---------------- Summary ----------------
Write-Host ''
Write-Host '--- Summary ---' -ForegroundColor Cyan
$results | Format-Table -AutoSize -Wrap | Out-String | Write-Host
$fails = @($results | Where-Object { $_.Result -eq 'FAIL' })
if (-not $fails.Count) { Write-Host 'All steps and tests passed.' -ForegroundColor Green }
else {
  Write-Host "$($fails.Count) step(s)/test(s) failed." -ForegroundColor Red
  $dnsFail = @($fails | Where-Object { $_.Step -like 'DNS lookup*' }).Count
  $httpsFail = @($fails | Where-Object { $_.Step -like 'HTTPS*' }).Count
  $gwFail = @($fails | Where-Object { $_.Step -like 'Gateway*' }).Count
  if ($gwFail) { Write-Host '  Gateway unreachable: check cable / Wi-Fi / switch port, or the router. If the adapter has a 169.254.x.x address, DHCP is not answering.' }
  if ($dnsFail -and -not $gwFail) { Write-Host '  DNS failing: check the DNS servers above (domain PCs should use the DC), and the DNS server itself.' }
  if ($httpsFail -and -not $dnsFail -and -not $gwFail) { Write-Host '  HTTPS failing only: check proxy settings, firewall / web filter, or security software.' }
  Write-Host '  If problems persist, try Network Stack Reset (needs a restart) or Network Diagnostics.'
}
