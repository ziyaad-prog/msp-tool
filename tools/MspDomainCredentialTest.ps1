$domain = Read-Host 'Enter target domain FQDN (e.g. corp.contoso.com)'
if (-not $domain) { Write-Host 'No domain entered - aborted.' -ForegroundColor Yellow; return }
$cred = Get-Credential -Message "Enter the account you want to test against $domain"
if (-not $cred) { Write-Host 'Credentials required - aborted.' -ForegroundColor Yellow; return }
try {
  $ctx = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext([System.DirectoryServices.ActiveDirectory.DirectoryContextType]::Domain, $domain, $cred.UserName, $cred.GetNetworkCredential().Password)
  $ad = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($ctx)
  Write-Host "SUCCESS: Credential validated for domain '$($ad.Name)'." -ForegroundColor Green
} catch {
  Write-Host "FAILED: Credential did not validate for domain '$domain'. $($_.Exception.Message)" -ForegroundColor Red
}
