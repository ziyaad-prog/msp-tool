#Requires -Version 5.1
<#
.SYNOPSIS
    Checks domain-join status and joins a workstation to an Active Directory domain.

.DESCRIPTION
    Step 1: Reports whether the workstation is domain joined and shows the domain name.
    Step 2: Prompts for the domain FQDN and admin credentials, then joins the workstation
            to the domain (requires a reboot to complete).

.NOTES
    Run from an elevated PowerShell session:
        powershell -ExecutionPolicy Bypass -File .\Join-MspDomain.ps1 [-Domain corp.contoso.com] [-OU "OU=Workstations,DC=corp,DC=contoso,DC=com"] [-ComputerName NEWNAME]

.EXAMPLE
    .\Join-MspDomain.ps1                          # status check only, then interactive prompt
    .\Join-MspDomain.ps1 -Domain corp.contoso.com # skip domain prompt
    .\Join-MspDomain.ps1 -Domain corp.contoso.com -OU "OU=Workstations,DC=corp,DC=contoso,DC=com"
#>
[CmdletBinding()]
param(
    [string]$Domain,
    [string]$OU,
    [string]$ComputerName,
    [pscredential]$Credential,
    [switch]$StatusOnly,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'

if (-not $Domain) {
    $Domain = Get-MspDefaultDomainSuggestion
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan
}

function Test-MspElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-MspDomainStatus {
    $csi = Get-CimInstance -ClassName Win32_ComputerSystem

    if ($csi.PartOfDomain) {
        $status = [PSCustomObject]@{
            DomainJoined = $true
            Domain       = $csi.Domain
            Workgroup    = $null
            ComputerName = $env:COMPUTERNAME
            IsDC         = ($csi.DomainRole -in 4, 5)
        }
    }
    else {
        $status = [PSCustomObject]@{
            DomainJoined = $false
            Domain       = $null
            Workgroup    = $csi.Domain
            ComputerName = $env:COMPUTERNAME
            IsDC         = $false
        }
    }
    return $status
}

function Get-MspDefaultDomainSuggestion {
    $status = Get-MspDomainStatus
    if ($status.DomainJoined -and $status.Domain) {
        return $status.Domain
    }
    return $null
}

function Read-MspDomainPrompt {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$DefaultValue
    )

    if ($DefaultValue) {
        $value = Read-Host "$Message [$DefaultValue]"
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $DefaultValue
        }
        return $value
    }

    return Read-Host $Message
}

function Show-MspDomainStatus {
    $status = Get-MspDomainStatus

    Write-Section "Workstation Domain Status"
    Write-Host ("  Computer Name : {0}" -f $status.ComputerName)
    if ($status.DomainJoined) {
        Write-Host "  Domain Joined : YES" -ForegroundColor Green
        Write-Host ("  Domain        : {0}" -f $status.Domain) -ForegroundColor Green
        Write-Host ("  Role          : {0}" -f $(if ($status.IsDC) { 'Domain Controller' } else { 'Domain Member' }))
    }
    else {
        Write-Host "  Domain Joined : NO" -ForegroundColor Yellow
        Write-Host ("  Workgroup     : {0}" -f $status.Workgroup) -ForegroundColor Yellow
    }

    try {
        $dns = [System.Net.Dns]::GetHostByName($env:COMPUTERNAME).HostName
        Write-Host ("  FQDN          : {0}" -f $dns)
    } catch { }

    if ($status.DomainJoined) {
        try {
            $secure = Test-ComputerSecureChannel
            if ($secure) {
                Write-Host "  Secure Channel: HEALTHY" -ForegroundColor Green
            }
            else {
                Write-Host "  Secure Channel: BROKEN (run: Test-ComputerSecureChannel -Repair, or rejoin the domain)" -ForegroundColor Red
            }

            $detail = Test-ComputerSecureChannel -Verbose
            Write-Host ("  DC Contacted  : {0}" -f $detail.Server)
        }
        catch {
            Write-Host ("  Secure Channel: ERROR - {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    }

    return $status
}

function Join-MspDomainToAD {
    param(
        [Parameter(Mandatory)][string]$TargetDomain,
        [string]$TargetOU,
        [pscredential]$AdminCredential
    )

    Write-Section "Joining Domain: $TargetDomain"

    if (-not $AdminCredential) {
        Write-Host "Enter credentials of a domain account with rights to join computers."
        $AdminCredential = Get-Credential -Message "Domain admin / delegated account for $TargetDomain"
        if (-not $AdminCredential) {
            throw "Credentials are required to join the domain."
        }
    }

    # Verify domain is reachable before attempting the join
    Write-Host "Verifying domain connectivity..."
    try {
        $context = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext(
            [System.DirectoryServices.ActiveDirectory.DirectoryContextType]::Domain, $TargetDomain)
        $adDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($context)
        Write-Host ("  Found domain: {0} (DC: {1})" -f $adDomain.Name, ($adDomain.DomainControllers | Select-Object -First 1).Name) -ForegroundColor Green
    }
    catch {
        throw "Cannot reach domain '$TargetDomain'. Check DNS/network. Error: $($_.Exception.Message)"
    }

    $joinParams = @{
        DomainName = $TargetDomain
        Credential = $AdminCredential
        Force      = $true
        ErrorAction = 'Stop'
    }
    if ($TargetOU)   { $joinParams['OU'] = $TargetOU; Write-Host ("  Target OU    : {0}" -f $TargetOU) }
    if ($ComputerName) {
        Write-Host ("  Renaming computer to: {0}" -f $ComputerName)
        Rename-Computer -NewName $ComputerName -Force -ErrorAction Stop | Out-Null
        $joinParams['NewName'] = $ComputerName
    }

    Write-Host "Joining domain (this may take a minute)..."
    try {
        Add-Computer @joinParams
        Write-Host ""
        Write-Host "SUCCESS: Computer joined domain '$TargetDomain'." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host ""
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Test-MspDomainConnectivity {
    param([Parameter(Mandatory)][string]$TargetDomain)

    Write-Host "Checking connectivity to domain '$TargetDomain'..."

    # 1. DNS resolution of the domain
    try {
        $ips = [System.Net.Dns]::GetHostAddresses($TargetDomain) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' }
        if (-not $ips) { throw "No A records found." }
        Write-Host ("  DNS OK       : {0} -> {1}" -f $TargetDomain, ($ips[0].IPAddressToString)) -ForegroundColor Green
    }
    catch {
        Write-Host "  DNS FAILED   : cannot resolve '$TargetDomain'. Check this machine's DNS points at the domain controllers." -ForegroundColor Red
        return $false
    }

    # 2. Locate a domain controller via AD (LDAP, port 389)
    try {
        $context = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext(
            [System.DirectoryServices.ActiveDirectory.DirectoryContextType]::Domain, $TargetDomain)
        $adDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($context)
        $dc = ($adDomain.DomainControllers | Select-Object -First 1)
        Write-Host ("  DC found     : {0}" -f $dc.Name) -ForegroundColor Green

        # 3. Test LDAP port on the DC
        $tcp = New-Object System.Net.Sockets.TcpClient
        $task = $tcp.ConnectAsync($dc.IPAddress, 389)
        if (-not $task.Wait(5000) -or -not $tcp.Connected) {
            $tcp.Close()
            throw "Cannot reach LDAP port 389 on $($dc.IPAddress)"
        }
        $tcp.Close()
        Write-Host ("  LDAP OK      : {0}:389 reachable" -f $dc.IPAddress) -ForegroundColor Green
    }
    catch {
        Write-Host ("  AD FAILED    : {0}" -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }

    return $true
}

function Invoke-MspElevation {
    # Relaunch the script elevated, forwarding all arguments
    if (-not (Test-MspElevated)) {
        Write-Host "Not elevated - relaunching with Run as Administrator..." -ForegroundColor Yellow

        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"")
        foreach ($bound in $MyInvocation.BoundParameters.GetEnumerator()) {
            if ($bound.Key -eq 'Credential') { continue }
            if ($bound.Value -is [switch] -and $bound.Value.IsPresent) {
                $argList += "-$($bound.Key)"
            }
            else {
                $argList += "-$($bound.Key)"; $argList += "`"$($bound.Value)`""
            }
        }

        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
        }
        catch {
            throw "Elevation was cancelled or failed: $($_.Exception.Message)"
        }
        exit 0
    }
}

function Show-MspMenu {
    param([bool]$IsDomainJoined)

    Write-Host ""
    Write-Section "Options"

    $options = [System.Collections.Generic.List[hashtable]]::new()

    if ($IsDomainJoined) {
        $options.Add(@{ Key = '1'; Label = 'Re-test secure channel' })
        $options.Add(@{ Key = '2'; Label = 'Repair secure channel (Test-ComputerSecureChannel -Repair)' })
        $options.Add(@{ Key = '3'; Label = 'Leave domain (unjoin)' })
        $options.Add(@{ Key = '4'; Label = 'Exit' })
    }
    else {
        $options.Add(@{ Key = '1'; Label = 'Join a domain' })
        $options.Add(@{ Key = '2'; Label = 'Test connectivity to a domain' })
        $options.Add(@{ Key = '3'; Label = 'Exit' })
    }

    foreach ($opt in $options) {
        Write-Host ("  [{0}] {1}" -f $opt.Key, $opt.Label)
    }
    Write-Host ""

    while ($true) {
        $choice = Read-Host "Select an option"
        if ($options.Key -contains $choice) {
            return $choice
        }
        Write-Host "Invalid selection. Enter one of: $($options.Key -join ', ')" -ForegroundColor Yellow
    }
}

function Invoke-MspJoinFlow {
    Write-Section "Domain Join"
    Write-Warning "The workstation will be joined to a domain. A restart is required afterwards."

    $defaultDomain = Get-MspDefaultDomainSuggestion
    $script:Domain = Read-MspDomainPrompt -Message 'Enter target domain FQDN (e.g. corp.contoso.com)' -DefaultValue $Domain
    if (-not $script:Domain) {
        throw "A domain name is required."
    }

    if (-not (Test-MspDomainConnectivity -TargetDomain $script:Domain)) {
        Write-Host ""
        Write-Host "ABORTED: Workstation cannot reach domain '$($script:Domain)'. Fix DNS/network and try again." -ForegroundColor Red
        return
    }
    Write-Host ""

    $joined = Join-MspDomainToAD -TargetDomain $script:Domain -TargetOU $OU -AdminCredential $Credential

    if ($joined) {
        if (-not $NoRestart) {
            Write-Host ""
            $answer = Read-Host "Restart now to complete the join? (Y/n)"
            if ($answer -notmatch '^n') {
                Restart-Computer -Force
            }
            else {
                Write-Host "Reboot manually later to finish joining '$($script:Domain)'." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "Reboot required to finish joining '$($script:Domain)' (-NoRestart was set)." -ForegroundColor Yellow
        }
    }
}

function Invoke-MspConnectivityFlow {
    $defaultDomain = Get-MspDefaultDomainSuggestion
    $target = Read-MspDomainPrompt -Message 'Enter domain FQDN to test (e.g. corp.contoso.com)' -DefaultValue $defaultDomain
    if (-not $target) { return }

    if (Test-MspDomainConnectivity -TargetDomain $target) {
        Write-Host ""
        Write-Host "SUCCESS: Workstation can reach domain '$target'." -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "FAILED: Workstation cannot reach domain '$target'. Fix DNS/network and try again." -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Invoke-MspElevation

if (-not (Test-MspElevated)) {
    throw "This script must be run from an elevated PowerShell session."
}

while ($true) {
    $status = Show-MspDomainStatus

    if ($StatusOnly) {
        exit 0
    }

    $choice = Show-MspMenu -IsDomainJoined $status.DomainJoined

    switch ($choice) {
        '1' {
            if ($status.DomainJoined) {
                Write-Host ""
                if (Test-ComputerSecureChannel) {
                    Write-Host "Secure channel is HEALTHY." -ForegroundColor Green
                }
                else {
                    Write-Host "Secure channel is BROKEN." -ForegroundColor Red
                }
            }
            else {
                Invoke-MspJoinFlow
                break
            }
        }
        '2' {
            if ($status.DomainJoined) {
                Write-Host ""
                Write-Host "Repairing secure channel..."
                if (Test-ComputerSecureChannel -Repair) {
                    Write-Host "Secure channel repaired. A restart is recommended." -ForegroundColor Green
                    $answer = Read-Host "Restart now? (Y/n)"
                    if ($answer -notmatch '^n') { Restart-Computer -Force }
                }
                else {
                    Write-Host "Repair failed. Consider leaving and rejoining the domain." -ForegroundColor Red
                }
            }
            else {
                Invoke-MspConnectivityFlow
            }
        }
        '3' {
            if (-not $status.DomainJoined) {
                Write-Host "Exiting." -ForegroundColor Yellow
                exit 0
            }
            else {
                Write-Section "Leave Domain"
                Write-Warning "This will unjoin the workstation from the domain and reboot."
                $confirm = Read-Host "Are you sure? (y/N)"
                if ($confirm -match '^[Yy]') {
                    $leaveCred = Get-Credential -Message "Domain account with rights to remove this computer"
                    if ($leaveCred) {
                        Remove-Computer -UnjoinDomainCredential $leaveCred -Force -Restart
                    }
                }
                exit 0
            }
        }
        '4' {
            Write-Host "Exiting." -ForegroundColor Yellow
            exit 0
        }
    }
}
