[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][pscredential]$Credential,
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'
$normalizedBaseUrl = $BaseUrl.TrimEnd('/')
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$common = @{ WebSession = $session; Credential = $Credential }
if ($SkipCertificateCheck) { $common.SkipCertificateCheck = $true }

$login = Invoke-WebRequest -Uri "$normalizedBaseUrl/login" @common
if ($login.StatusCode -ne 200) { throw "Login page returned HTTP $($login.StatusCode)." }

$dashboard = Invoke-WebRequest -Uri "$normalizedBaseUrl/dashboard" @common
if ($dashboard.StatusCode -ne 200 -or $dashboard.Content -notmatch 'live session') { throw 'Dashboard smoke check failed.' }

$data = Invoke-RestMethod -Uri "$normalizedBaseUrl/api/data" @common
if ($null -eq $data.Sessions) { throw 'Live data response has no Sessions property.' }

foreach ($path in @('/farm', '/server', '/health', '/logs', '/settings', '/ad-search', '/server-rdp-logins')) {
    try {
        $response = Invoke-WebRequest -Uri "$normalizedBaseUrl$path" @common
        throw "Removed route '$path' returned HTTP $($response.StatusCode)."
    }
    catch {
        if ($_.Exception.Message -like "Removed route '$path' returned*") { throw }
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -ne 404) { throw }
    }
}

[pscustomobject]@{
    Dashboard = 'OK'
    LiveData = 'OK'
    RemovedRoutes = '404'
}
