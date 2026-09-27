# --- Settings (edit as needed) ---
$pingTargets = @('8.8.8.8', '1.1.1.1', 'google.com')   # the default gateway is added in front automatically
$dnsTestName = 'google.com'
$publicIpUrl = 'https://api.ipify.org'
$publicIpTimeoutSec = 5
# TCP port checks. Host 'DNSSERVER' = the first DNS server configured on this PC. Empty Host = skipped.
$portChecks = @(
  @{ Name = 'HTTPS (web / Microsoft 365)'; Host = 'www.microsoft.com'; Port = 443 }
  @{ Name = 'DNS server (TCP 53)'; Host = 'DNSSERVER'; Port = 53 }
  @{ Name = 'RDP (optional - set a host)'; Host = ''; Port = 3389 }
)
$portTimeoutMs = 3000
$tracerouteTarget = '8.8.8.8'   # used when the traceroute prompt gets no answer
$promptTimeoutSec = 5           # traceroute target / Wi-Fi report prompts take their default after this
$tracerouteMaxHops = 15
$tracerouteWaitMs = 500
$wifiWeakSignalPercent = 50
$wlanReportSource = Join-Path $env:ProgramData 'Microsoft\Windows\WlanReport\wlan-report-latest.html'
$reportDir = Join-Path $env:USERPROFILE 'Desktop\MSP-Reports'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$issues = [System.Collections.Generic.List[string]]::new()

# Everything this tool prints is also collected for a text report (saved at the end): this local
# Write-Host records each line, then passes it to the real Write-Host unchanged.
$reportLines = [System.Collections.Generic.List[string]]::new()
$reportLines.Add('=== MSP Network Connectivity Test ===')
$reportLines.Add("Computer : $env:COMPUTERNAME")
$reportLines.Add("User     : $env:USERDOMAIN\$env:USERNAME")
$reportLines.Add("Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$reportLines.Add('')
function Write-Host {
  param(
    [Parameter(Position = 0, ValueFromPipeline = $true)][object]$Object,
    [switch]$NoNewline, [object]$Separator, [System.ConsoleColor]$ForegroundColor, [System.ConsoleColor]$BackgroundColor
  )
  process {
    $reportLines.Add(("$Object").TrimEnd())
    Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
  }
}
# Runs a native command without letting stderr/exit codes throw under $ErrorActionPreference = 'Stop'
function Invoke-NativeQuiet {
  param([scriptblock]$Command)
  $ErrorActionPreference = 'Continue'
  try { @(& $Command 2>$null | ForEach-Object { "$_" }) } catch { @() }
}
# Prompt that takes $Default after $promptTimeoutSec (engine helper; plain Read-Host if run outside MSP Tool).
# Returns $null if the technician cancels the GUI dialog.
function Read-TimedAnswer {
  param([string]$Prompt, [string]$Default)
  if (Get-Command Read-MspHostWithTimeout -ErrorAction SilentlyContinue) {
    return Read-MspHostWithTimeout -Prompt $Prompt -TimeoutSeconds $promptTimeoutSec -Default $Default
  }
  $a = Read-Host "$Prompt (Enter = $Default)"
  if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
  return $a
}
# TCP connect with a hard timeout (Test-NetConnection -Port has no timeout switch in PowerShell 5.1)
function Test-TcpPort {
  param([string]$HostName, [int]$Port, [int]$TimeoutMs)
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync($HostName, $Port)
    if (-not $task.Wait($TimeoutMs)) { return 'TIMEOUT' }
    if ($client.Connected) { return 'OPEN' } else { return 'CLOSED' }
  } catch {
    $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
    return "FAILED ($($inner.Message))"
  } finally { $client.Dispose() }
}

# ---------------- Ping / DNS (original tests) ----------------
Write-Host '--- Ping ---' -ForegroundColor Cyan
$targets = $pingTargets
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
if ($gw) { $targets = @($gw) + $targets }
foreach ($t in $targets) {
  $result = Test-Connection -ComputerName $t -Count 2 -Quiet -ErrorAction SilentlyContinue
  $status = if ($result) { 'OK' } else { 'FAIL' }
  Write-Host "[$status] $t" -ForegroundColor $(if ($result) { 'Green' } else { 'Red' })
  if (-not $result) { $issues.Add("Ping failed: $t") }
}
$dnsIp = Resolve-DnsName $dnsTestName -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | Select-Object -First 1 -ExpandProperty IPAddress
Write-Host "DNS test: $dnsIp"
if (-not $dnsIp) { Write-Host "  DNS could not resolve $dnsTestName" -ForegroundColor Red; $issues.Add("DNS failed to resolve $dnsTestName") }

# ---------------- Public IP ----------------
Write-Host ''
Write-Host '--- Public IP ---' -ForegroundColor Cyan
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $publicIp = "$(Invoke-RestMethod -Uri $publicIpUrl -TimeoutSec $publicIpTimeoutSec -UseBasicParsing -ErrorAction Stop)".Trim()
  if ($publicIp -match '^[\d.]+$|^[0-9a-fA-F:]+$') { Write-Host "Public IP: $publicIp" -ForegroundColor Green }
  else { Write-Host "Unexpected reply from $publicIpUrl (captive portal or web filter?)" -ForegroundColor Yellow; $issues.Add('Public IP lookup returned unexpected content') }
} catch {
  Write-Host "Could not get public IP from $publicIpUrl - offline, blocked by firewall/web filter, or proxy required. ($($_.Exception.Message))" -ForegroundColor Yellow
  $issues.Add('Public IP lookup failed')
}

# ---------------- Proxy ----------------
Write-Host ''
Write-Host '--- Proxy settings ---' -ForegroundColor Cyan
$winhttp = @(Invoke-NativeQuiet { netsh winhttp show proxy } | Where-Object { $_.Trim() -and $_ -notmatch '^Current WinHTTP' })
Write-Host "WinHTTP (system/services): $(if ($winhttp.Count) { ($winhttp | ForEach-Object { $_.Trim() -replace '\s+', ' ' }) -join '; ' } else { 'could not read' })"
$ie = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
if ($ie) {
  $manual = if ($ie.ProxyEnable -eq 1) { "ON - $($ie.ProxyServer)" } else { 'off' }
  Write-Host "User proxy (WinINet)     : manual $manual"
  if ($ie.ProxyEnable -eq 1 -and $ie.ProxyOverride) { Write-Host "  Bypass list            : $($ie.ProxyOverride)" }
  Write-Host "  Auto-config script     : $(if ($ie.AutoConfigURL) { $ie.AutoConfigURL } else { 'none' })"
  if ($ie.ProxyEnable -eq 1 -or $ie.AutoConfigURL) { Write-Host '  A user proxy is set - confirm it is expected for this client.' -ForegroundColor Yellow }
} else { Write-Host 'User proxy (WinINet)     : could not read (running as SYSTEM shows the SYSTEM profile, not the user)' -ForegroundColor Yellow }

# ---------------- Port checks ----------------
Write-Host ''
Write-Host "--- Port checks (timeout $([math]::Round($portTimeoutMs / 1000, 1))s) ---" -ForegroundColor Cyan
$dnsServer = $null
$defaultIf = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).InterfaceIndex
$dnsAddrs = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses } | Sort-Object { $_.InterfaceIndex -ne $defaultIf })
if ($dnsAddrs.Count) { $dnsServer = @($dnsAddrs[0].ServerAddresses)[0] }
foreach ($pc in $portChecks) {
  $h = if ($pc.Host -eq 'DNSSERVER') { $dnsServer } else { $pc.Host }
  if (-not $h) { Write-Host ("[SKIP] {0} - port {1}: no host configured" -f $pc.Name, $pc.Port) -ForegroundColor DarkGray; continue }
  $res = Test-TcpPort -HostName $h -Port $pc.Port -TimeoutMs $portTimeoutMs
  $ok = $res -eq 'OPEN'
  Write-Host ("[{0}] {1} - {2}:{3}" -f $res, $pc.Name, $h, $pc.Port) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
  if (-not $ok) { $issues.Add("Port $($pc.Port) to $h $res") }
}

# ---------------- Wi-Fi ----------------
Write-Host ''
Write-Host '--- Wi-Fi ---' -ForegroundColor Cyan
$wifiUp = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ($_.PhysicalMediaType -match '802\.11' -or $_.NdisPhysicalMedium -eq 9) })
if (-not $wifiUp.Count) {
  Write-Host 'No wireless adapter is connected (wired or Wi-Fi off).'
} else {
  # Parse 'Label : value' blocks; a new block starts at each 'Name' line (English labels)
  $wlanIfs = @(); $cur = $null
  foreach ($line in (Invoke-NativeQuiet { netsh wlan show interfaces })) {
    if ($line -match '^\s{2,}([^:]+?)\s+:\s?(.*)$') {
      $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
      if ($k -eq 'Name') { $cur = [ordered]@{}; $wlanIfs += $cur }
      if ($cur -and -not $cur.Contains($k)) { $cur[$k] = $v }
    }
  }
  $connected = @($wlanIfs | Where-Object { $_['State'] -eq 'connected' })
  if (-not $connected.Count) { Write-Host 'Wireless adapter is up but netsh reported no connected interface (or non-English labels).' -ForegroundColor Yellow }
  foreach ($w in $connected) {
    $sig = if ("$($w['Signal'])" -match '(\d+)') { [int]$Matches[1] } else { $null }
    Write-Host "Adapter       : $($w['Name']) ($($w['Description']))"
    Write-Host "SSID          : $($w['SSID'])"
    Write-Host ("Signal        : {0}{1}" -f $w['Signal'], $(if ($w['Rssi']) { " (RSSI $($w['Rssi']) dBm)" }))
    Write-Host "Radio / band  : $($w['Radio type']) / $(if ($w['Band']) { $w['Band'] } else { 'n/a' })"
    Write-Host "Channel       : $($w['Channel'])"
    Write-Host "Rx / Tx rate  : $($w['Receive rate (Mbps)']) / $($w['Transmit rate (Mbps)']) Mbps"
    if ($null -ne $sig -and $sig -lt $wifiWeakSignalPercent) {
      Write-Host "  WEAK SIGNAL ($sig% < $wifiWeakSignalPercent%) - move closer to the access point, check for interference, or consider a wired connection/extra AP." -ForegroundColor Yellow
      $issues.Add("Weak Wi-Fi signal ($sig%) on $($w['SSID'])")
    }
  }
}

# ---------------- Traceroute (defaults to $tracerouteTarget after $promptTimeoutSec s) ----------------
Write-Host ''
$target = Read-TimedAnswer -Prompt "Traceroute target IP or hostname (n = skip; up to $tracerouteMaxHops hops, can take a minute)" -Default $tracerouteTarget
if ($null -eq $target -or "$target".Trim() -match '^(?i)(n|no|skip|0)$') {
  Write-Host 'Traceroute skipped.'
} else {
  $target = "$target".Trim()
  if (-not $target) { $target = $tracerouteTarget }
  if ($target -notmatch '^[A-Za-z0-9.:\-]+$') {
    Write-Host "'$target' is not a valid IP address or hostname - using $tracerouteTarget." -ForegroundColor Yellow
    $target = $tracerouteTarget
  }
  Write-Host "--- Traceroute to $target ---" -ForegroundColor Cyan
  # Streamed line by line so hops appear as they are found
  & { $ErrorActionPreference = 'Continue'; tracert -d -h $tracerouteMaxHops -w $tracerouteWaitMs $target 2>$null } | Where-Object { "$_".Trim() } | ForEach-Object { Write-Host $_ }
}

# ---------------- Windows Wi-Fi report (optional, admin) ----------------
if ($wifiUp.Count -or (Get-Service -Name WlanSvc -ErrorAction SilentlyContinue)) {
  Write-Host ''
  if (-not $isAdmin) {
    Write-Host 'Windows Wi-Fi report (netsh wlan show wlanreport) needs administrator rights - relaunch MSP Tool elevated to generate it.' -ForegroundColor Yellow
  } else {
    # Defaults to yes after $promptTimeoutSec s; n (or Cancel in the GUI) skips it
    $ans = Read-TimedAnswer -Prompt 'Generate the Windows Wi-Fi report (last 3 days of Wi-Fi sessions, disconnects and errors)? (Y/n)' -Default 'y'
    if ($null -ne $ans -and "$ans".Trim() -notmatch '^(?i)(n|no)$') {
      Write-Host 'Generating Wi-Fi report...'
      $wlanStarted = (Get-Date).AddSeconds(-5)
      $wlanOut = Invoke-NativeQuiet { netsh wlan show wlanreport }
      # Ignore a wlan-report-latest.html left over from an earlier run
      if ((Test-Path -LiteralPath $wlanReportSource) -and (Get-Item -LiteralPath $wlanReportSource).LastWriteTime -ge $wlanStarted) {
        if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
        $dest = Join-Path $reportDir "wlan-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
        Copy-Item -LiteralPath $wlanReportSource -Destination $dest -Force
        Write-Host "Wi-Fi report saved: $dest" -ForegroundColor Green
      } else {
        Write-Host "Wi-Fi report was not created. netsh said: $(($wlanOut | Where-Object { $_.Trim() }) -join ' ')" -ForegroundColor Red
      }
    } else { Write-Host 'Wi-Fi report skipped.' }
  }
}

# ---------------- Summary ----------------
Write-Host ''
if ($issues.Count) {
  Write-Host "Issues found ($($issues.Count)):" -ForegroundColor Yellow
  $issues | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
} else {
  Write-Host 'All network checks passed.' -ForegroundColor Green
}

# ---------------- Text report ----------------
try {
  if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
  $reportPath = Join-Path $reportDir "network-test-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
  $reportLines | Out-File -FilePath $reportPath -Encoding UTF8
  Write-Host ''
  Write-Host "Report saved: $reportPath" -ForegroundColor Green
} catch {
  Write-Host "Could not save the text report: $($_.Exception.Message)" -ForegroundColor Red
}
