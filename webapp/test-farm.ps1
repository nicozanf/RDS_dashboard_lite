param(
    [string]$BaseUrl = 'https://localhost',
    [System.Management.Automation.PSCredential]$Credential,
    [string]$HistoryServerName = 'rds-a01.example.local',
    [bool]$SkipCertificateCheck = $true,
    [int]$MinimumFarmRowsLast8Days = 10,
    [int]$MinimumServerRowsLast1Hour = 1,
    [int]$ZeroSessionsConsecutiveThreshold = 3,
    [int]$ZeroSessionsCheckCount = 5,
    [int]$ZeroSessionsCheckDelaySeconds = 10,
    [int]$TimedOutServersConsecutiveThreshold = 3,
    [int]$TimedOutServersMinimum = 2,
    [int]$TimedOutServersCheckCount = 5,
    [int]$TimedOutServersCheckDelaySeconds = 10,
    [switch]$InvokeRestartCheck
)

$ErrorActionPreference = 'Stop'

$baseUrlText = ([string]$BaseUrl).Trim()
if ([string]::IsNullOrWhiteSpace($baseUrlText)) {
    throw 'BaseUrl cannot be empty. Example: https://localhost or https://server.domain.local'
}

$placeholderPatterns = @(
    '(?i)your-isolated-host',
    '(?i)example\.com',
    '(?i)<.+>'
)
foreach ($pattern in $placeholderPatterns) {
    if ($baseUrlText -match $pattern) {
        throw "BaseUrl '$BaseUrl' looks like a placeholder. Pass a real dashboard URL, for example: -BaseUrl https://localhost"
    }
}

$scriptPath = Join-Path $PSScriptRoot 'Test-HealthEndpoints.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Required script not found: $scriptPath"
}

if ($null -eq $Credential) {
    $Credential = Get-Credential -Message ("Enter dashboard credentials for {0}" -f $BaseUrl)
}

$invokeArgs = @{
    BaseUrl                          = $baseUrlText
    Credential                       = $Credential
    SkipCertificateCheck             = [bool]$SkipCertificateCheck
    HistoryServerName                = $HistoryServerName
    MinimumFarmRowsLast8Days         = $MinimumFarmRowsLast8Days
    MinimumServerRowsLast1Hour       = $MinimumServerRowsLast1Hour
    ZeroSessionsConsecutiveThreshold = $ZeroSessionsConsecutiveThreshold
    ZeroSessionsCheckCount           = $ZeroSessionsCheckCount
    ZeroSessionsCheckDelaySeconds    = $ZeroSessionsCheckDelaySeconds
    TimedOutServersConsecutiveThreshold = $TimedOutServersConsecutiveThreshold
    TimedOutServersMinimum           = $TimedOutServersMinimum
    TimedOutServersCheckCount        = $TimedOutServersCheckCount
    TimedOutServersCheckDelaySeconds = $TimedOutServersCheckDelaySeconds
}

if ($InvokeRestartCheck) {
    $invokeArgs.InvokeRestartCheck = $true
}

& $scriptPath @invokeArgs
