$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain) { Write-Host "Already joined to '$($cs.Domain)'. Nothing to do." -ForegroundColor Yellow; return }
$domain = Read-Host 'Enter target domain FQDN (e.g. corp.contoso.com)'
if (-not $domain) { Write-Host 'No domain entered - aborted.' -ForegroundColor Yellow; return }
try {
  $ctx = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext([System.DirectoryServices.ActiveDirectory.DirectoryContextType]::Domain, $domain)
  [void][System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($ctx)
  Write-Host "[OK] Domain reachable: $domain" -ForegroundColor Green
} catch { Write-Host "Cannot reach domain '$domain': $($_.Exception.Message)" -ForegroundColor Red; return }
$cred = Get-Credential -Message "Account with rights to join $domain"
if (-not $cred) { Write-Host 'Credentials required - aborted.' -ForegroundColor Yellow; return }
$ou = Read-Host 'Target OU path (optional, press Enter to skip, e.g. OU=Workstations,DC=corp,DC=contoso,DC=com)'
$params = @{ DomainName = $domain; Credential = $cred; Force = $true; ErrorAction = 'Stop' }
if ($ou) { $params['OU'] = $ou }
try {
  Add-Computer @params
  Write-Host "SUCCESS: Joined domain '$domain'. A restart is required to finish." -ForegroundColor Green
  $r = Read-Host 'Restart now? (y/N)'
  if ($r -match '^(y|yes)$') { Restart-Computer -Force } else { Write-Host 'Reboot later to complete the join.' -ForegroundColor Yellow }
} catch { Write-Host "FAILED to join domain: $($_.Exception.Message)" -ForegroundColor Red }
