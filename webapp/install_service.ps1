<#
.SYNOPSIS
Installs the RDS Dashboard web app as a Windows service.

.DESCRIPTION
Creates (or recreates) a service that starts server.ps1 on HTTPS 443.
This script uses NSSM (the Non-Sucking Service Manager) to host PowerShell as a proper Windows service.
If ServiceUser is provided, ServicePassword must be passed as SecureString.
For gMSA accounts, use -UseGmsa and do not pass ServicePassword.

.EXAMPLE
# Install as LocalSystem (default)
.\install_service.ps1 -NssmPath .\nssm.exe

.EXAMPLE
# Install as domain service account (interactive password prompt)
$svcPwd = Read-Host "Service account password" -AsSecureString
.\install_service.ps1 -NssmPath .\nssm.exe -ServiceUser "CONTOSO\\svc-rds-dashboard" -ServicePassword $svcPwd

.EXAMPLE
# Install as domain service account (non-interactive; use only in controlled automation)
$svcPwd = ConvertTo-SecureString "<password>" -AsPlainText -Force
.\install_service.ps1 -NssmPath .\nssm.exe -ServiceUser "CONTOSO\\svc-rds-dashboard" -ServicePassword $svcPwd

.EXAMPLE
# Install as gMSA account (no password)
.\install_service.ps1 -NssmPath .\nssm.exe -ServiceUser "CONTOSO\\gmsa-rds-dashboard$" -UseGmsa

.EXAMPLE
# Install as gMSA and force HTTPS rebinding by certificate FriendlyName at app startup
.\install_service.ps1 -NssmPath .\nssm.exe -ServiceUser "CONTOSO\\gmsa-rds-dashboard$" -UseGmsa -HttpsCertFriendlyName "tsfarm"

.EXAMPLE
# Install as LocalSystem and keep existing HTTPS binding configured externally
.\install_service.ps1 -NssmPath .\nssm.exe
#>

param(
    [string]$ServiceName = 'RDSDashboardWeb',
    [string]$DisplayName = 'RDS Dashboard Web App',
    [string]$Description = 'RDS dashboard HTTPS web app with AD authentication',
    [string]$StartupType = 'auto',
    [string]$HttpsCertFriendlyName = '',
    [string]$ServiceUser = '',
    [securestring]$ServicePassword,
    [switch]$UseGmsa,
    [string]$NssmPath = ''
)

$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'Run this script as Administrator.'
}

$scriptPath = Join-Path $PSScriptRoot 'server.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "server.ps1 not found at $scriptPath"
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$ErrorMessage = 'External command failed.'
    )

    & $FilePath @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "$ErrorMessage ExitCode=$LASTEXITCODE"
    }
}

function Resolve-NssmPath {
    param([string]$Candidate)

    if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
        if (Test-Path -LiteralPath $Candidate) {
            return (Resolve-Path -LiteralPath $Candidate).Path
        }
        throw "NSSM not found at provided path: $Candidate"
    }

    $local = Join-Path $PSScriptRoot 'nssm.exe'
    if (Test-Path -LiteralPath $local) {
        return (Resolve-Path -LiteralPath $local).Path
    }

    $cmd = Get-Command nssm.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Path
    }

    throw 'NSSM executable not found. Copy nssm.exe to this folder or pass -NssmPath <full path>.'
}

function Resolve-NssmStartType {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'SERVICE_AUTO_START'
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    switch ($normalized) {
        'auto' { return 'SERVICE_AUTO_START' }
        'automatic' { return 'SERVICE_AUTO_START' }
        'delayed-auto' { return 'SERVICE_DELAYED_AUTO_START' }
        'delayedautomatic' { return 'SERVICE_DELAYED_AUTO_START' }
        'manual' { return 'SERVICE_DEMAND_START' }
        'demand' { return 'SERVICE_DEMAND_START' }
        'disabled' { return 'SERVICE_DISABLED' }
        'service_auto_start' { return 'SERVICE_AUTO_START' }
        'service_delayed_auto_start' { return 'SERVICE_DELAYED_AUTO_START' }
        'service_demand_start' { return 'SERVICE_DEMAND_START' }
        'service_disabled' { return 'SERVICE_DISABLED' }
        default {
            throw "Unsupported StartupType '$Value'. Use: auto, delayed-auto, demand/manual, or disabled."
        }
    }
}

$nssmExe = Resolve-NssmPath -Candidate $NssmPath
$nssmStartType = Resolve-NssmStartType -Value $StartupType

$pwsh = Join-Path $PSHOME 'powershell.exe'
# Use \" so the quotes survive PowerShell 5.1's argument-to-command-line encoding when passed to NSSM.
$appArgs = '-NoProfile -ExecutionPolicy Bypass -File \"' + $scriptPath + '\" -Port 443 -BindHost +'
if (-not [string]::IsNullOrWhiteSpace($HttpsCertFriendlyName)) {
    $appArgs += ' -HttpsCertFriendlyName \"' + $HttpsCertFriendlyName + '\"'
}

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    try {
        & $nssmExe stop $ServiceName confirm | Out-Null
    }
    catch {
        # Ignore stop failures, service might already be stopped or not NSSM-managed.
    }

    & sc.exe stop $ServiceName | Out-Null
    Start-Sleep -Seconds 1

    # Attempt NSSM removal first, then force-delete with SC for non-NSSM legacy definitions.
    & $nssmExe remove $ServiceName confirm | Out-Null
    & sc.exe delete $ServiceName | Out-Null

    for ($i = 0; $i -lt 10; $i++) {
        if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        throw "Unable to remove existing service '$ServiceName'. Delete it manually and retry."
    }

    Start-Sleep -Seconds 1
}

Invoke-External -FilePath $nssmExe -Arguments @('install', $ServiceName, $pwsh) -ErrorMessage "Failed to install service '$ServiceName' via NSSM."
Invoke-External -FilePath $nssmExe -Arguments @('set', $ServiceName, 'AppParameters', $appArgs) -ErrorMessage 'Failed to set AppParameters.'
Invoke-External -FilePath $nssmExe -Arguments @('set', $ServiceName, 'DisplayName', $DisplayName) -ErrorMessage 'Failed to set service display name.'
Invoke-External -FilePath $nssmExe -Arguments @('set', $ServiceName, 'Description', $Description) -ErrorMessage 'Failed to set service description.'
Invoke-External -FilePath $nssmExe -Arguments @('set', $ServiceName, 'Start', $nssmStartType) -ErrorMessage 'Failed to set startup type.'
Invoke-External -FilePath $nssmExe -Arguments @('set', $ServiceName, 'AppDirectory', $PSScriptRoot) -ErrorMessage 'Failed to set app directory.'
Invoke-External -FilePath $nssmExe -Arguments @('set', $ServiceName, 'AppThrottle', '5000') -ErrorMessage 'Failed to set restart throttle.'
Invoke-External -FilePath $nssmExe -Arguments @('set', $ServiceName, 'AppRestartDelay', '5000') -ErrorMessage 'Failed to set restart delay.'

if ([string]::IsNullOrWhiteSpace($ServiceUser)) {
    if ($UseGmsa) {
        throw 'UseGmsa requires ServiceUser to be set to DOMAIN\gmsaName$.'
    }
}
else {
    if ($UseGmsa) {
        if (-not $ServiceUser.EndsWith('$')) {
            throw 'gMSA ServiceUser must end with $. Example: DOMAIN\gmsa-rds-dashboard$'
        }

        Invoke-External -FilePath $nssmExe -Arguments @('set', $ServiceName, 'ObjectName', $ServiceUser, '""') -ErrorMessage 'Failed to assign gMSA service identity.'
    }
    else {
        if ($null -eq $ServicePassword -or $ServicePassword.Length -eq 0) {
            throw 'When ServiceUser is provided, ServicePassword is required unless -UseGmsa is set.'
        }

        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ServicePassword)
        try {
            $plainServicePassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            Invoke-External -FilePath $nssmExe -Arguments @('set', $ServiceName, 'ObjectName', $ServiceUser, $plainServicePassword) -ErrorMessage 'Failed to assign service identity with password.'
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/15000 | Out-Null

Write-Host "Service '$ServiceName' created."
Write-Host "Start with: sc.exe start $ServiceName"
