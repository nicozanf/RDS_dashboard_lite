param(
    [int]$Port = 443,
    [string]$BindHost = '+',
    [string]$HttpsCertFriendlyName = '',
    [string]$RuntimeDir = "$PSScriptRoot\runtime",
    [Alias('DataFile')][string]$LegacyDataFile,
    [int]$CollectorTimeoutSeconds = 15,
    [int]$CycleDelaySeconds = 15,
    [int]$SessionTimeoutMinutes = 720,
    [string]$DefaultDomain = '',
    [string]$ConfigFile = "$PSScriptRoot\config.toml"
)

$script:ApplicationVersion = '2026.09.11 Lite'

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.DirectoryServices.AccountManagement

# Import shared utilities module
Import-Module -Name (Join-Path $PSScriptRoot 'common.psm1') -ErrorAction Stop

function Resolve-DefaultAdDomain {
    # Prefer the AD domain the server is joined to, then fall back to environment hints.
    try {
        $computerDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
        if ($null -ne $computerDomain) {
            $name = ([string]$computerDomain.Name).Trim()
            if (-not [string]::IsNullOrWhiteSpace($name)) {
                return $name
            }
        }
    }
    catch {}

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($null -ne $cs -and $cs.PartOfDomain -and -not [string]::IsNullOrWhiteSpace([string]$cs.Domain)) {
            return ([string]$cs.Domain).Trim()
        }
    }
    catch {}

    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
        return ([string]$env:USERDNSDOMAIN).Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
        return ([string]$env:USERDOMAIN).Trim()
    }

    return ''
}

if ([string]::IsNullOrWhiteSpace($DefaultDomain)) {
    $DefaultDomain = Resolve-DefaultAdDomain
}

$scriptRoot = Split-Path -Path $PSCommandPath -Parent
if ([string]::IsNullOrWhiteSpace([string]$RuntimeDir) -and -not [string]::IsNullOrWhiteSpace([string]$LegacyDataFile)) {
    try {
        if ([System.IO.Path]::HasExtension([string]$LegacyDataFile)) {
            $RuntimeDir = Split-Path -Path $LegacyDataFile -Parent
        }
        else {
            $RuntimeDir = [string]$LegacyDataFile
        }
    }
    catch {
        $RuntimeDir = [string]$LegacyDataFile
    }
}
if ([string]::IsNullOrWhiteSpace([string]$RuntimeDir)) {
    $RuntimeDir = Join-Path $scriptRoot 'runtime'
}
$runtimeDir = $RuntimeDir
$logsDir = Join-Path $scriptRoot 'logs'
$templateDir = Join-Path $scriptRoot 'templates'
if (-not (Test-Path -LiteralPath $runtimeDir)) {
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
}

function Get-RotatedLogPath {
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    $parent = Split-Path -Path $LogPath -Parent
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($LogPath)
    $candidate = Join-Path $parent ("{0}-{1}.log" -f $baseName, $Timestamp)
    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }

    $idx = 1
    do {
        $candidate = Join-Path $parent ("{0}-{1}-{2}.log" -f $baseName, $Timestamp, $idx)
        $idx++
    } while (Test-Path -LiteralPath $candidate)

    return $candidate
}

function Invoke-LogFileRotation {
    param(
        [Parameter(Mandatory = $true)][string]$LogPath,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    if (-not (Test-Path -LiteralPath $LogPath)) {
        return $null
    }

    try {
        $item = Get-Item -LiteralPath $LogPath -ErrorAction Stop
        if ($null -eq $item -or $item.PSIsContainer -or [int64]$item.Length -le 0) {
            return $null
        }

        $rotatedPath = Get-RotatedLogPath -LogPath $LogPath -Timestamp $Timestamp
        Move-Item -LiteralPath $LogPath -Destination $rotatedPath -Force
        return $rotatedPath
    }
    catch {
        return $null
    }
}

function Remove-OldRotatedLogs {
    param(
        [Parameter(Mandatory = $true)][string]$LogsFolder,
        [int]$MonthsToKeep = 6
    )

    if (-not (Test-Path -LiteralPath $LogsFolder)) {
        return 0
    }

    $deleted = 0
    $cutoff = (Get-Date).AddMonths(-[math]::Max(1, $MonthsToKeep))
    $pattern = '.*-\d{8}-\d{4,6}(?:-\d+)?\.log$'

    foreach ($file in @(Get-ChildItem -LiteralPath $LogsFolder -File -Filter '*.log' -ErrorAction SilentlyContinue)) {
        try {
            if ($file.Name -match $pattern -and $file.LastWriteTime -lt $cutoff) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $deleted++
            }
        }
        catch {}
    }

    return $deleted
}

function Invoke-StartupLogMaintenance {
    param(
        [Parameter(Mandatory = $true)][string[]]$LogPaths,
        [Parameter(Mandatory = $true)][string]$LogsFolder,
        [int]$MonthsToKeep = 6
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $rotated = @()
    $seen = @{}

    foreach ($path in @($LogPaths)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        $k = ([string]$path).ToLowerInvariant()
        if ($seen.ContainsKey($k)) {
            continue
        }
        $seen[$k] = $true

        $rotatedPath = Invoke-LogFileRotation -LogPath $path -Timestamp $timestamp
        if (-not [string]::IsNullOrWhiteSpace([string]$rotatedPath)) {
            $rotated += $rotatedPath
        }
    }

    $deletedCount = Remove-OldRotatedLogs -LogsFolder $LogsFolder -MonthsToKeep $MonthsToKeep
    return [PSCustomObject]@{
        RotatedLogs = @($rotated)
        DeletedCount = $deletedCount
    }
}

$logFile = Join-Path $logsDir 'server.log'
$auditLogFile = Join-Path $logsDir 'connection_actions.log'
$collectorStdOutLog = Join-Path $logsDir 'collector.stdout.log'
$collectorStdErrLog = Join-Path $logsDir 'collector.stderr.log'
$collectorCycleLog = Join-Path $logsDir 'collector.log'

if (-not [System.IO.Path]::IsPathRooted([string]$ConfigFile)) {
    $ConfigFile = Join-Path $scriptRoot $ConfigFile
}
try {
    if (Test-Path -LiteralPath $ConfigFile) {
        $ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path
    }
}
catch {
    # Keep the normalized absolute path and let Read-ConfigFile surface any load errors.
}

# Set up log file path for shared Write-Log function
Initialize-Logging -LogPath $logFile

$configData = Read-ConfigFile -Path $ConfigFile
$dashboardTitle = $configData.Title
$servers = @($configData.Servers)
$script:allServersFarmName = 'All servers'
$script:farmServerMap = [ordered]@{}
$script:serverFarmMap = @{}
foreach ($farmName in @($configData.FarmNames)) {
    $script:farmServerMap[$farmName] = @($configData.Farms[$farmName])
}
foreach ($key in @($configData.ServerFarmMap.Keys)) {
    $script:serverFarmMap[$key] = [string]$configData.ServerFarmMap[$key]
}
if ($configData.ContainsKey('CollectorTimeoutSeconds') -and [int]$configData.CollectorTimeoutSeconds -gt 0) {
    $CollectorTimeoutSeconds = [int]$configData.CollectorTimeoutSeconds
}
if ($configData.ContainsKey('CycleDelaySeconds') -and [int]$configData.CycleDelaySeconds -gt 0) {
    $CycleDelaySeconds = [int]$configData.CycleDelaySeconds
}
$MaxConcurrentJobs = 6
if ($configData.ContainsKey('MaxConcurrentJobs') -and [int]$configData.MaxConcurrentJobs -gt 0) {
    $MaxConcurrentJobs = [int]$configData.MaxConcurrentJobs
}
$customLoginDomain = ''
if ($configData.ContainsKey('CustomLoginDomain') -and -not [string]::IsNullOrWhiteSpace([string]$configData.CustomLoginDomain)) {
    $customLoginDomain = ([string]$configData.CustomLoginDomain).Trim()
    Write-Log "CustomLoginDomain configured: '$customLoginDomain' (used for user auth and AD search)"
}

if ($servers.Count -eq 0) {
    throw "No servers configured in $ConfigFile"
}

$script:sessions = @{}
$script:sessionsLock = New-Object object
$cookieName = 'RDSAUTH'
$listener = $null
$collectorJob = $null
$script:collectorSnapshotState = [hashtable]::Synchronized(@{
    Snapshot = $null
    UpdatedAtUtc = ''
    Error = ''
})
$script:serverMetricHistoryByShort = @{}
$sslBindingAppId = '{d1f2fd5b-bcd9-4df8-979f-7f3b4e36f029}'
$farmMetricsDbPath = Join-Path $runtimeDir 'farm_metrics.sqlite'
$script:sqliteExe = $null
$script:sqliteEnabled = $false
$script:farmMetricHistory = @()
$script:historyLock = New-Object object
$script:snapshotCache = $null
$script:snapshotCacheLock = New-Object object
$script:snapshotCacheHits = 0
$script:snapshotCacheMisses = 0
$script:snapshotCacheLastLogUtc = [DateTime]::MinValue
$script:collectorLastObservedPid = 0
$script:collectorLastObservedState = ''
$script:collectorLastObservedExitCode = $null
$script:collectorRestartCooldownSeconds = [math]::Max(30, ($CycleDelaySeconds * 2))
$script:collectorRestartNotBeforeUtc = [DateTime]::MinValue
$script:collectorRestartRequestTimesUtc = @()
$script:collectorRestartStats = [ordered]@{
    TotalRequests       = 0
    TotalSuccesses      = 0
    TotalFailures       = 0
    CooldownBlocked     = 0
    LastAttemptUtc      = ''
    LastSuccessUtc      = ''
    LastFailureUtc      = ''
    LastFailureMessage  = ''
    LastActor           = ''
    LastOutcome         = ''
}

function Get-HttpsCertificateByFriendlyName {
    param([Parameter(Mandatory = $true)][string]$FriendlyName)

    $certMatches = @(
        Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction Stop |
        Where-Object { $_.FriendlyName -eq $FriendlyName -and $_.HasPrivateKey }
    )

    if ($certMatches.Count -eq 0) {
        throw "No certificate with FriendlyName '$FriendlyName' and private key was found in LocalMachine\\My."
    }

    if ($certMatches.Count -gt 1) {
        Write-Log "Multiple certificates found for FriendlyName '$FriendlyName'. Using the newest expiration."
    }

    return ($certMatches | Sort-Object -Property NotAfter -Descending | Select-Object -First 1)
}

function Set-HttpsCertificateBinding {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$FriendlyName
    )

    $cert = Get-HttpsCertificateByFriendlyName -FriendlyName $FriendlyName
    $thumbprint = ([string]$cert.Thumbprint -replace '\s', '').ToUpperInvariant()
    $bindings = @("0.0.0.0:$Port", "[::]:$Port")

    foreach ($binding in $bindings) {
        $showOutput = (& netsh http show sslcert ipport=$binding 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) {
            $showOutput = ''
        }

        $existingThumb = ''
        $m = [regex]::Match($showOutput, '(?im)Certificate Hash\s*:\s*([0-9A-F]+)')
        if ($m.Success) {
            $existingThumb = $m.Groups[1].Value.ToUpperInvariant()
        }

        if ($existingThumb -eq $thumbprint) {
            Write-Log "HTTPS cert already bound on $binding to '$FriendlyName' ($thumbprint)."
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($existingThumb)) {
            Write-Log "Replacing existing HTTPS cert binding on $binding (old=$existingThumb, new=$thumbprint)."
            $deleteOutput = (& netsh http delete sslcert ipport=$binding 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                throw "Failed deleting existing SSL binding on ${binding}: $deleteOutput"
            }
        }
        else {
            Write-Log "Creating HTTPS cert binding on $binding with '$FriendlyName' ($thumbprint)."
        }

        $addOutput = (& netsh http add sslcert ipport=$binding certhash=$thumbprint certstorename=MY appid=$sslBindingAppId 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Failed adding SSL binding on ${binding}: $addOutput"
        }
    }
}

function Initialize-FarmMetricsStore {
    return
}

function Invoke-SqliteReadQuery {
    param(
        [Parameter(Mandatory = $true)][string]$QuerySql,
        [switch]$NoHeader,
        [string]$Separator = '',
        [int]$BusyTimeoutMs = 5000,
        [int]$MaxAttempts = 3
    )

    if (-not $script:sqliteEnabled -or [string]::IsNullOrWhiteSpace([string]$script:sqliteExe) -or -not (Test-Path -LiteralPath $farmMetricsDbPath)) {
        return [PSCustomObject]@{
            Success = $false
            Rows = @()
            Error = 'SQLite store is unavailable.'
        }
    }

    $attemptLimit = [math]::Max(1, $MaxAttempts)
    for ($attempt = 1; $attempt -le $attemptLimit; $attempt++) {
        $sqliteCmdArgs = @('-cmd', (".timeout {0}" -f ([math]::Max(0, $BusyTimeoutMs))))
        if ($NoHeader) {
            $sqliteCmdArgs += '-noheader'
        }
        if (-not [string]::IsNullOrWhiteSpace($Separator)) {
            $sqliteCmdArgs += @('-separator', $Separator)
        }
        $sqliteCmdArgs += @($farmMetricsDbPath, $QuerySql)

        $rows = @(& $script:sqliteExe @sqliteCmdArgs 2>&1)
        if ($LASTEXITCODE -eq 0) {
            return [PSCustomObject]@{
                Success = $true
                Rows = $rows
                Error = ''
            }
        }

        $err = ($rows | Out-String).Trim()
        $isLock = (-not [string]::IsNullOrWhiteSpace($err)) -and ($err -match '(?i)database is locked')
        if ($isLock -and $attempt -lt $attemptLimit) {
            Start-Sleep -Milliseconds (120 * $attempt)
            continue
        }

        return [PSCustomObject]@{
            Success = $false
            Rows = $rows
            Error = $err
        }
    }

    return [PSCustomObject]@{
        Success = $false
        Rows = @()
        Error = 'SQLite query failed after retries.'
    }
}

function Get-OldestFarmDataTimestamp {
    if (-not $script:sqliteEnabled) {
        if ($script:farmMetricHistory.Count -gt 0) {
            $oldestTs = ''
            foreach ($entry in @($script:farmMetricHistory)) {
                if ($null -eq $entry -or [string]::IsNullOrWhiteSpace([string]$entry.Ts)) {
                    continue
                }
                try {
                    if ([string]::IsNullOrWhiteSpace($oldestTs) -or ([DateTimeOffset]::Parse([string]$entry.Ts).UtcDateTime -lt [DateTimeOffset]::Parse($oldestTs).UtcDateTime)) {
                        $oldestTs = [string]$entry.Ts
                    }
                }
                catch {}
            }
            if (-not [string]::IsNullOrWhiteSpace($oldestTs)) {
                return $oldestTs
            }
        }

        return ''
    }

    $querySql = @"
SELECT MIN(ts_utc)
FROM farm_metrics_by_farm;
"@

    $queryResult = Invoke-SqliteReadQuery -QuerySql $querySql -NoHeader
    if ($queryResult.Success -and $queryResult.Rows.Count -gt 0) {
        $oldest = ([string]$queryResult.Rows[0]).Trim()
        if (-not [string]::IsNullOrWhiteSpace($oldest)) {
            return $oldest
        }
    }

    return ''
}

function Select-FarmHistoryPayload {
    param(
        [Parameter(Mandatory = $true)]$History,
        [string]$FarmName = '',
        [int]$Days = 70
    )

    $safeDays = [math]::Max(1, [math]::Min(70, [int]$Days))
    $cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-$safeDays)
    $farmFilter = ([string]$FarmName).Trim().ToLowerInvariant()

    $filtered = @()
    foreach ($point in @($History)) {
        if ($null -eq $point) {
            continue
        }

        $farm = [string]$point.Farm
        if ([string]::IsNullOrWhiteSpace($farm)) {
            $farm = $script:allServersFarmName
        }

        if (-not [string]::IsNullOrWhiteSpace($farmFilter) -and $farm.Trim().ToLowerInvariant() -ne $farmFilter) {
            continue
        }

        $tsText = [string]$point.Ts
        if ([string]::IsNullOrWhiteSpace($tsText)) {
            continue
        }

        try {
            $tsUtc = [DateTimeOffset]::Parse($tsText).UtcDateTime
            if ($tsUtc -lt $cutoffUtc) {
                continue
            }
        }
        catch {
            continue
        }

        $filtered += [PSCustomObject]@{
            Farm          = $farm
            Ts            = $tsText
            AvgCPU        = if ($null -eq $point.AvgCPU) { 0.0 } else { [double]$point.AvgCPU }
            AvgRAM        = if ($null -eq $point.AvgRAM) { 0.0 } else { [double]$point.AvgRAM }
            TotalSessions = if ($null -eq $point.TotalSessions) { 0 } else { [int]$point.TotalSessions }
        }
    }

    return $filtered
}

function Get-Farm24hHistoryPayload {
    param(
        [string]$FarmName = '',
        [int]$Days = 70
    )

    $safeDays = [math]::Max(1, [math]::Min(70, [int]$Days))
    $farmFilter = ([string]$FarmName).Trim()

    if (-not $script:sqliteEnabled) {
        $normalized = @()
        foreach ($point in @($script:farmMetricHistory)) {
            if ($null -eq $point) {
                continue
            }
            $farmName = [string]$point.Farm
            if ([string]::IsNullOrWhiteSpace($farmName)) {
                $farmName = $script:allServersFarmName
            }
            $normalized += [PSCustomObject]@{
                Farm = $farmName
                Ts = [string]$point.Ts
                AvgCPU = if ($null -eq $point.AvgCPU) { 0.0 } else { [double]$point.AvgCPU }
                AvgRAM = if ($null -eq $point.AvgRAM) { 0.0 } else { [double]$point.AvgRAM }
                TotalSessions = if ($null -eq $point.TotalSessions) { 0 } else { [int]$point.TotalSessions }
            }
        }
        return (Select-FarmHistoryPayload -History $normalized -FarmName $farmFilter -Days $safeDays)
    }

    $farmPredicate = ''
    if (-not [string]::IsNullOrWhiteSpace($farmFilter)) {
        $farmLiteral = ConvertTo-SqliteLiteral -Value $farmFilter
        $farmPredicate = "`n  AND lower(trim(farm_name)) = lower(trim($farmLiteral))"
    }

    $querySql = @"
SELECT farm_name,
       MAX(ts_utc) AS ts_utc,
       AVG(avg_cpu) AS avg_cpu,
       AVG(avg_ram) AS avg_ram,
       ROUND(AVG(total_sessions)) AS total_sessions
FROM farm_metrics_by_farm
WHERE ts_epoch >= CAST(strftime('%s','now','-$safeDays days') AS INTEGER)$farmPredicate
GROUP BY farm_name, (ts_epoch / 900)
ORDER BY MAX(ts_epoch) ASC, farm_name ASC;
"@

    try {
        $queryResult = Invoke-SqliteReadQuery -QuerySql $querySql -NoHeader -Separator '|'
        if (-not $queryResult.Success) {
            throw $queryResult.Error
        }

        $result = @()
        foreach ($row in @($queryResult.Rows)) {
            $line = ([string]$row).Trim()
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $parts = $line -split '\|', 5
            if ($parts.Count -lt 5) {
                continue
            }

            $result += [PSCustomObject]@{
                Farm        = if ([string]::IsNullOrWhiteSpace([string]$parts[0])) { $script:allServersFarmName } else { [string]$parts[0] }
                Ts          = [string]$parts[1]
                AvgCPU      = if ([string]::IsNullOrWhiteSpace([string]$parts[2])) { 0.0 } else { [double]$parts[2] }
                AvgRAM      = if ([string]::IsNullOrWhiteSpace([string]$parts[3])) { 0.0 } else { [double]$parts[3] }
                TotalSessions = if ([string]::IsNullOrWhiteSpace([string]$parts[4])) { 0 } else { [int]$parts[4] }
            }
        }

        # If database query succeeded and returned data, use it; otherwise fallback to in-memory cache
        if ($result.Count -gt 0) {
            return $result
        }

        # Compatibility fallback for legacy schema without farm_name.
        $legacySql = @"
SELECT MAX(ts_utc) AS ts_utc,
       AVG(avg_cpu) AS avg_cpu,
       AVG(avg_ram) AS avg_ram,
       ROUND(AVG(total_sessions)) AS total_sessions
FROM farm_metrics
WHERE ts_epoch >= CAST(strftime('%s','now','-$safeDays days') AS INTEGER)
GROUP BY (ts_epoch / 900)
ORDER BY MAX(ts_epoch) ASC;
"@
        $legacyResultQuery = Invoke-SqliteReadQuery -QuerySql $legacySql -NoHeader -Separator '|'
        if ($legacyResultQuery.Success) {
            $legacyResult = @()
            foreach ($row in @($legacyResultQuery.Rows)) {
                $line = ([string]$row).Trim()
                if ([string]::IsNullOrWhiteSpace($line)) {
                    continue
                }

                $parts = $line -split '\|', 4
                if ($parts.Count -lt 4) {
                    continue
                }

                $legacyResult += [PSCustomObject]@{
                    Farm = $script:allServersFarmName
                    Ts = [string]$parts[0]
                    AvgCPU = if ([string]::IsNullOrWhiteSpace([string]$parts[1])) { 0.0 } else { [double]$parts[1] }
                    AvgRAM = if ([string]::IsNullOrWhiteSpace([string]$parts[2])) { 0.0 } else { [double]$parts[2] }
                    TotalSessions = if ([string]::IsNullOrWhiteSpace([string]$parts[3])) { 0 } else { [int]$parts[3] }
                }
            }
            if ($legacyResult.Count -gt 0) {
                return (Select-FarmHistoryPayload -History $legacyResult -FarmName $farmFilter -Days $safeDays)
            }
        }
    }
    catch {
        Write-Log "Failed to query 24h farm metrics: $($_.Exception.Message)"
    }

    # Fallback to in-memory cache if database is empty or unavailable
    $normalized = @()
    foreach ($point in @($script:farmMetricHistory)) {
        if ($null -eq $point) {
            continue
        }
        $farmName = [string]$point.Farm
        if ([string]::IsNullOrWhiteSpace($farmName)) {
            $farmName = $script:allServersFarmName
        }
        $normalized += [PSCustomObject]@{
            Farm = $farmName
            Ts = [string]$point.Ts
            AvgCPU = if ($null -eq $point.AvgCPU) { 0.0 } else { [double]$point.AvgCPU }
            AvgRAM = if ($null -eq $point.AvgRAM) { 0.0 } else { [double]$point.AvgRAM }
            TotalSessions = if ($null -eq $point.TotalSessions) { 0 } else { [int]$point.TotalSessions }
        }
    }
    return (Select-FarmHistoryPayload -History $normalized -FarmName $farmFilter -Days $safeDays)
}

function Get-Server24hHistoryPayload {
    param([Parameter(Mandatory = $true)][string]$ServerName)

    if (-not $script:sqliteEnabled) {
        $resolvedServerNoSql = Resolve-ServerName -ServerName $ServerName
        if ($null -eq $resolvedServerNoSql) {
            return @()
        }

        $shortNoSql = Get-ServerHistoryKey -ServerName $resolvedServerNoSql
        if ($script:serverMetricHistoryByShort.ContainsKey($shortNoSql)) {
            return @($script:serverMetricHistoryByShort[$shortNoSql])
        }
        return @()
    }

    $resolvedServer = Resolve-ServerName -ServerName $ServerName
    if ($null -eq $resolvedServer) {
        return @()
    }

    $serverShort = Get-ServerHistoryKey -ServerName $resolvedServer
    $querySql = @"
SELECT ts_utc, cpu, ram, sessions
FROM server_metrics
WHERE server_short = $(ConvertTo-SqliteLiteral -Value $serverShort)
    AND ts_epoch >= CAST(strftime('%s','now','-2 hours') AS INTEGER)
ORDER BY ts_epoch ASC;
"@

    try {
        $queryResult = Invoke-SqliteReadQuery -QuerySql $querySql -NoHeader -Separator '|'
        if (-not $queryResult.Success) {
            throw $queryResult.Error
        }

        $result = @()
        foreach ($row in @($queryResult.Rows)) {
            $line = ([string]$row).Trim()
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $parts = $line -split '\|', 4
            if ($parts.Count -lt 3) {
                continue
            }

            $result += [PSCustomObject]@{
                Ts       = [string]$parts[0]
                CPU      = if ([string]::IsNullOrWhiteSpace([string]$parts[1])) { $null } else { [double]$parts[1] }
                RAM      = if ([string]::IsNullOrWhiteSpace([string]$parts[2])) { $null } else { [double]$parts[2] }
                Sessions = if ($parts.Count -lt 4 -or [string]::IsNullOrWhiteSpace([string]$parts[3])) { $null } else { [int]$parts[3] }
            }
        }

        # Return from database only if we got results
        if ($result.Count -gt 0) {
            return $result
        }
    }
    catch {
        Write-Log "Failed to query 24h server metrics for ${serverShort}: $($_.Exception.Message)"
    }

    # Fallback to in-memory cache if database is empty or unavailable
    if ($script:serverMetricHistoryByShort.ContainsKey($serverShort)) {
        return @($script:serverMetricHistoryByShort[$serverShort])
    }

    return @()
}

function Get-HistoryDebugPayload {
    param([string]$ServerName = '')

    $farmCount = 0
    $farmLastTs = ''
    $serverCount = 0
    $serverLastTs = ''
    $resolvedServer = ''
    $serverShort = ''
    $dbError = ''
    $fallbackFarmCount = @($script:farmMetricHistory).Count
    $fallbackServerCount = 0

    if ($script:sqliteEnabled -and -not [string]::IsNullOrWhiteSpace([string]$script:sqliteExe) -and (Test-Path -LiteralPath $farmMetricsDbPath)) {
        try {
            $farmCountSql = "SELECT COUNT(*) FROM farm_metrics_by_farm WHERE ts_epoch >= CAST(strftime('%s','now','-70 days') AS INTEGER);"
            $farmCountResult = Invoke-SqliteReadQuery -QuerySql $farmCountSql -NoHeader
            if (-not $farmCountResult.Success) {
                throw $farmCountResult.Error
            }
            if ($farmCountResult.Rows.Count -gt 0) {
                $farmCount = [int]([string]$farmCountResult.Rows[0]).Trim()
            }

            $farmLastSql = "SELECT COALESCE(MAX(ts_utc), '') FROM farm_metrics_by_farm;"
            $farmLastResult = Invoke-SqliteReadQuery -QuerySql $farmLastSql -NoHeader
            if (-not $farmLastResult.Success) {
                throw $farmLastResult.Error
            }
            if ($farmLastResult.Rows.Count -gt 0) {
                $farmLastTs = ([string]$farmLastResult.Rows[0]).Trim()
            }

            if (-not [string]::IsNullOrWhiteSpace($ServerName)) {
                $resolvedServer = Resolve-ServerName -ServerName $ServerName
                if ($null -ne $resolvedServer) {
                    $serverShort = Get-ServerHistoryKey -ServerName $resolvedServer
                    $serverCountSql = @"
SELECT COUNT(*)
FROM server_metrics
WHERE server_short = $(ConvertTo-SqliteLiteral -Value $serverShort)
  AND ts_epoch >= CAST(strftime('%s','now','-1 hours') AS INTEGER);
"@
                    $serverCountResult = Invoke-SqliteReadQuery -QuerySql $serverCountSql -NoHeader
                    if (-not $serverCountResult.Success) {
                        throw $serverCountResult.Error
                    }
                    if ($serverCountResult.Rows.Count -gt 0) {
                        $serverCount = [int]([string]$serverCountResult.Rows[0]).Trim()
                    }

                    $serverLastSql = @"
SELECT COALESCE(MAX(ts_utc), '')
FROM server_metrics
WHERE server_short = $(ConvertTo-SqliteLiteral -Value $serverShort);
"@
                    $serverLastResult = Invoke-SqliteReadQuery -QuerySql $serverLastSql -NoHeader
                    if (-not $serverLastResult.Success) {
                        throw $serverLastResult.Error
                    }
                    if ($serverLastResult.Rows.Count -gt 0) {
                        $serverLastTs = ([string]$serverLastResult.Rows[0]).Trim()
                    }
                }
            }
        }
        catch {
            $dbError = $_.Exception.Message
        }
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($ServerName)) {
            $resolvedServer = Resolve-ServerName -ServerName $ServerName
            if ($null -ne $resolvedServer) {
                $serverShort = Get-ServerHistoryKey -ServerName $resolvedServer
                if ($script:serverMetricHistoryByShort.ContainsKey($serverShort)) {
                    $fallbackServerCount = @($script:serverMetricHistoryByShort[$serverShort]).Count
                    $series = @($script:serverMetricHistoryByShort[$serverShort])
                    if ($series.Count -gt 0) {
                        $serverLastTs = [string]$series[$series.Count - 1].Ts
                    }
                }
            }
        }

        if (@($script:farmMetricHistory).Count -gt 0) {
            $farmLastTs = [string]$script:farmMetricHistory[@($script:farmMetricHistory).Count - 1].Ts
        }
    }

    $snapshotMeta = Get-SnapshotMetadata

    return [PSCustomObject]@{
        GeneratedAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
        SqliteEnabled         = [bool]$script:sqliteEnabled
        SqliteExe             = [string]$script:sqliteExe
        DbPath                = $farmMetricsDbPath
        DbExists              = (Test-Path -LiteralPath $farmMetricsDbPath)
        FarmRowsLast8Days     = $farmCount
        FarmLatestTsUtc       = $farmLastTs
        RequestedServer       = $ServerName
        ResolvedServer        = $resolvedServer
        ServerShort           = $serverShort
        ServerRowsLast1Hour   = $serverCount
        ServerLatestTsUtc     = $serverLastTs
        FallbackFarmRows      = $fallbackFarmCount
        FallbackServerRows    = $fallbackServerCount
        DbQueryError          = $dbError
        Snapshot              = $snapshotMeta
    }
}

function Read-CurrentSnapshotFile {
    $snapshot = $script:collectorSnapshotState['Snapshot']
    if ($null -ne $snapshot) {
        return [PSCustomObject]@{
            RawText = $null
            Snapshot = $snapshot
            Source = 'memory'
        }
    }
    return $null

    if ($script:sqliteEnabled -and -not [string]::IsNullOrWhiteSpace([string]$script:sqliteExe) -and (Test-Path -LiteralPath $farmMetricsDbPath)) {
        try {
            $tsQuerySql = @"
SELECT ts_utc
FROM snapshot_state
WHERE id = 1
LIMIT 1;
"@
            $tsQueryResult = Invoke-SqliteReadQuery -QuerySql $tsQuerySql -NoHeader -Separator '|'
            $snapshotTsUtc = ''
            if ($tsQueryResult.Success -and $tsQueryResult.Rows.Count -gt 0) {
                $snapshotTsUtc = ([string]$tsQueryResult.Rows[0]).Trim()
            }

            if (-not [string]::IsNullOrWhiteSpace($snapshotTsUtc)) {
                [System.Threading.Monitor]::Enter($script:snapshotCacheLock)
                try {
                    if ($null -ne $script:snapshotCache -and ([string]$script:snapshotCache.TsUtc -eq $snapshotTsUtc)) {
                        $script:snapshotCacheHits++
                        $nowUtc = (Get-Date).ToUniversalTime()
                        if ($script:snapshotCacheLastLogUtc -eq [DateTime]::MinValue -or ($nowUtc - $script:snapshotCacheLastLogUtc).TotalMinutes -ge 5) {
                            $total = [math]::Max(1, ($script:snapshotCacheHits + $script:snapshotCacheMisses))
                            $hitRate = [math]::Round((100.0 * $script:snapshotCacheHits / $total), 1)
                            Write-Log ("Snapshot cache stats: hits={0} misses={1} hitRate={2}%" -f $script:snapshotCacheHits, $script:snapshotCacheMisses, $hitRate)
                            $script:snapshotCacheLastLogUtc = $nowUtc
                        }
                        return [PSCustomObject]@{
                            RawText = [string]$script:snapshotCache.RawText
                            Snapshot = $script:snapshotCache.Snapshot
                            Source = 'sqlite-cache'
                        }
                    }
                }
                finally {
                    [System.Threading.Monitor]::Exit($script:snapshotCacheLock)
                }
            }

            $querySql = @"
SELECT ts_utc, payload_json
FROM snapshot_state
WHERE id = 1
LIMIT 1;
"@
            $queryResult = Invoke-SqliteReadQuery -QuerySql $querySql -NoHeader -Separator '|'
            if ($queryResult.Success -and $queryResult.Rows.Count -gt 0) {
                $line = ([string]$queryResult.Rows[0]).Trim()
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    $parts = $line -split '\|', 2
                    if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace([string]$parts[1])) {
                        $rawPayload = [string]$parts[1]
                        $parsedSnapshot = ($rawPayload | ConvertFrom-Json)
                        [System.Threading.Monitor]::Enter($script:snapshotCacheLock)
                        try {
                            $script:snapshotCacheMisses++
                            $script:snapshotCache = [PSCustomObject]@{
                                TsUtc = [string]$parts[0]
                                RawText = $rawPayload
                                Snapshot = $parsedSnapshot
                            }
                        }
                        finally {
                            [System.Threading.Monitor]::Exit($script:snapshotCacheLock)
                        }
                        return [PSCustomObject]@{
                            RawText = $rawPayload
                            Snapshot = $parsedSnapshot
                            Source = 'sqlite'
                        }
                    }
                }
            }
        }
        catch {
            Write-Log "Failed to read current snapshot from SQLite: $($_.Exception.Message)"
        }
    }

    return $null
}

function Get-SnapshotMetadata {
    $snapshotMeta = [PSCustomObject]@{
        SnapshotAvailable      = $false
        SnapshotSource         = 'none'
        GeneratedAtUtc         = ''
        ServersCount           = 0
        SessionsCount          = 0
        ServersWithCpuData     = 0
        ServersWithRamData     = 0
        ServersWithAnyMetricData = 0
        ServersWithSessionRows = 0
        ServersWithoutAnyData  = 0
        AnyDataCoveragePercent = 0.0
        ProbeGapRanking        = @()
        CycleDurationSeconds   = $null
        InputServersCount      = 0
        StartedWorkersCount    = 0
        StartFailedServersCount = 0
        TimedOutServersCount   = 0
        FailedServersCount     = 0
        MaxConcurrentJobs      = $null
        AgeSeconds             = $null
        StaleThresholdSeconds  = [math]::Max(($CycleDelaySeconds * 3), ($CollectorTimeoutSeconds + ($CycleDelaySeconds * 2)))
        IsStale                = $true
        HasDegradedData        = $false
        SnapshotReadError      = ''
    }

    try {
        $snapshotFile = Read-CurrentSnapshotFile
        if ($null -eq $snapshotFile -or $null -eq $snapshotFile.Snapshot) {
            return $snapshotMeta
        }

        $snapshotMeta.SnapshotSource = [string]$snapshotFile.Source
        $snapshotMeta.SnapshotAvailable = $true

        $snapshot = $snapshotFile.Snapshot
        $serversList = @($snapshot.Servers | Where-Object { $null -ne $_ })
        $serversWithSessionRows = 0
        $serversWithAnyMetricData = 0

        foreach ($srv in $serversList) {
            $hasCpu = ($null -ne $srv.CPU)
            $hasRam = ($null -ne $srv.RAM)
            $hasSessionRows = $false
            $sessionCount = 0

            if ($null -ne $srv.Count -and [int]::TryParse([string]$srv.Count, [ref]$sessionCount)) {
                $hasSessionRows = ($sessionCount -gt 0)
            }

            if ($hasSessionRows) {
                $serversWithSessionRows++
            }

            if ($hasCpu -or $hasRam -or $hasSessionRows) {
                $serversWithAnyMetricData++
            }
        }

        $snapshotMeta.GeneratedAtUtc = [string]$snapshot.GeneratedAtUtc
        $snapshotMeta.ServersCount = @($serversList).Count
        $snapshotMeta.SessionsCount = @($snapshot.Sessions).Count
        $snapshotMeta.ServersWithCpuData = @($serversList | Where-Object { $null -ne $_.CPU }).Count
        $snapshotMeta.ServersWithRamData = @($serversList | Where-Object { $null -ne $_.RAM }).Count
        $snapshotMeta.ServersWithSessionRows = $serversWithSessionRows
        $snapshotMeta.ServersWithAnyMetricData = $serversWithAnyMetricData
        $snapshotMeta.ServersWithoutAnyData = [int][math]::Max(0, ($snapshotMeta.ServersCount - $snapshotMeta.ServersWithAnyMetricData))
        $cpuMissingCount = [int][math]::Max(0, ($snapshotMeta.ServersCount - $snapshotMeta.ServersWithCpuData))
        $ramMissingCount = [int][math]::Max(0, ($snapshotMeta.ServersCount - $snapshotMeta.ServersWithRamData))
        $sessionsMissingCount = [int][math]::Max(0, ($snapshotMeta.ServersCount - $snapshotMeta.ServersWithSessionRows))
        $snapshotMeta.ProbeGapRanking = @(
            [PSCustomObject]@{ Probe = 'CPU'; MissingServers = $cpuMissingCount },
            [PSCustomObject]@{ Probe = 'RAM'; MissingServers = $ramMissingCount },
            [PSCustomObject]@{ Probe = 'Sessions'; MissingServers = $sessionsMissingCount }
        ) | Sort-Object -Property MissingServers -Descending
        if ($snapshotMeta.ServersCount -gt 0) {
            $snapshotMeta.AnyDataCoveragePercent = [math]::Round((100.0 * $snapshotMeta.ServersWithAnyMetricData / $snapshotMeta.ServersCount), 1)
        }
        $snapshotMeta.CycleDurationSeconds = if ($null -ne $snapshot.CycleDurationSeconds) { [int]$snapshot.CycleDurationSeconds } else { $null }
        $snapshotMeta.InputServersCount = if ($null -ne $snapshot.InputServersCount) { [int]$snapshot.InputServersCount } else { $snapshotMeta.ServersCount }
        $snapshotMeta.StartedWorkersCount = if ($null -ne $snapshot.StartedWorkersCount) { [int]$snapshot.StartedWorkersCount } else { $snapshotMeta.InputServersCount }
        $snapshotMeta.StartFailedServersCount = if ($null -ne $snapshot.StartFailedServersCount) { [int]$snapshot.StartFailedServersCount } else { [int][math]::Max(0, ($snapshotMeta.InputServersCount - $snapshotMeta.StartedWorkersCount)) }
        $snapshotMeta.TimedOutServersCount = if ($null -ne $snapshot.TimedOutServersCount) { [int]$snapshot.TimedOutServersCount } else { 0 }
        $snapshotMeta.FailedServersCount = if ($null -ne $snapshot.FailedServersCount) { [int]$snapshot.FailedServersCount } else { 0 }
        $snapshotMeta.MaxConcurrentJobs = if ($null -ne $snapshot.MaxConcurrentJobs) { [int]$snapshot.MaxConcurrentJobs } else { $null }
        $snapshotMeta.HasDegradedData = (
            ($snapshotMeta.StartFailedServersCount -gt 0) -or
            ($snapshotMeta.TimedOutServersCount -gt 0) -or
            ($snapshotMeta.FailedServersCount -gt 0) -or
            ($snapshotMeta.ServersWithoutAnyData -gt 0)
        )
        if (-not [string]::IsNullOrWhiteSpace($snapshotMeta.GeneratedAtUtc)) {
            $snapshotTs = [DateTimeOffset]::Parse($snapshotMeta.GeneratedAtUtc)
            $ageSeconds = [math]::Round(((Get-Date).ToUniversalTime() - $snapshotTs.UtcDateTime).TotalSeconds, 0)
            $snapshotMeta.AgeSeconds = [int][math]::Max(0, $ageSeconds)
            $snapshotMeta.IsStale = ($snapshotMeta.AgeSeconds -gt $snapshotMeta.StaleThresholdSeconds)
        }
    }
    catch {
        $snapshotMeta.SnapshotReadError = $_.Exception.Message
    }

    return $snapshotMeta
}

function Get-ServiceHealthPayload {
    $missingTemplates = @(Test-TemplateAvailability)
    $snapshotMeta = Get-SnapshotMetadata
    $restartMetrics = Get-CollectorRestartMetrics

    $collectorState = Get-CollectorJobState
    $collectorId = Get-CollectorJobId
    $awaitingFirstSnapshot = (-not $snapshotMeta.SnapshotAvailable) -or [string]::IsNullOrWhiteSpace([string]$snapshotMeta.GeneratedAtUtc)

    $collectorHealthState = 'Stopped'
    $collectorStatusText = if ([string]::IsNullOrWhiteSpace($collectorState)) { 'Unknown' } else { $collectorState }
    $hasSnapshotDegradation = [bool]$snapshotMeta.HasDegradedData
    $freshSnapshotAvailable = (
        $snapshotMeta.SnapshotAvailable -and
        -not $snapshotMeta.IsStale -and
        [string]::IsNullOrWhiteSpace([string]$snapshotMeta.SnapshotReadError) -and
        -not $hasSnapshotDegradation
    )

    if ($collectorState -eq 'Running') {
        if ($awaitingFirstSnapshot) {
            $collectorHealthState = 'Healthy'
            $collectorStatusText = 'Running (waiting for first snapshot)'
        }
        elseif ($snapshotMeta.IsStale -or -not [string]::IsNullOrWhiteSpace($snapshotMeta.SnapshotReadError)) {
            $collectorHealthState = 'Warning'
            $collectorStatusText = if (-not [string]::IsNullOrWhiteSpace($snapshotMeta.SnapshotReadError)) { 'Running with snapshot read error' } else { 'Running with stale snapshot' }
        }
        elseif ($restartMetrics.WarningActive) {
            $collectorHealthState = 'Warning'
            $collectorStatusText = [string]$restartMetrics.WarningReason
        }
        elseif ($hasSnapshotDegradation) {
            $collectorHealthState = 'Warning'
            $collectorStatusText = 'Running with degraded snapshot data'
        }
        else {
            $collectorHealthState = 'Healthy'
            $collectorStatusText = 'Healthy'
        }
    }
    elseif ($freshSnapshotAvailable) {
        # If snapshot data is fresh but the current process does not own the collector handle,
        # treat collector health as externally healthy to avoid false "NotStarted" alarms.
        $collectorHealthState = 'Healthy'
        if ($collectorState -eq 'NotStarted' -or $collectorState -eq 'Stopped') {
            $collectorStatusText = 'Healthy (external collector)'
        }
    }

    return [PSCustomObject]@{
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        DashboardTitle = $dashboardTitle
        ConfiguredServers = @($servers).Count
        Collector = [PSCustomObject]@{
            State = $collectorState
            Id = $collectorId
            TimeoutSeconds = $CollectorTimeoutSeconds
            CycleDelaySeconds = $CycleDelaySeconds
            Restart = $restartMetrics
            HealthState = $collectorHealthState
            StatusText = $collectorStatusText
        }
        Templates = [PSCustomObject]@{
            TemplateDir = $templateDir
            Missing = $missingTemplates
            AllPresent = ($missingTemplates.Count -eq 0)
        }
        Sqlite = [PSCustomObject]@{
            Enabled = [bool]$script:sqliteEnabled
            Executable = [string]$script:sqliteExe
            DatabasePath = $farmMetricsDbPath
            DatabaseExists = (Test-Path -LiteralPath $farmMetricsDbPath)
        }
        RuntimeFiles = [PSCustomObject]@{
            AuditLogPath = $auditLogFile
            AuditLogExists = (Test-Path -LiteralPath $auditLogFile)
            ServerLogPath = $logFile
            ServerLogExists = (Test-Path -LiteralPath $logFile)
        }
        Snapshot = $snapshotMeta
    }
}

function Convert-AuditValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    return ([string]$Value -replace '\|', '/' -replace "`r|`n", ' ').Trim()
}

<#
.SYNOPSIS
    Writes one normalized entry to the audit log.

.DESCRIPTION
    Appends an audit row to logs/connection_actions.log in a fixed pipe-delimited format.
    The header row is created automatically on first write.

.PARAMETER Event
    Audit event name (for example: login, disconnect, logoff, sendmsg, service_start).

.PARAMETER Actor
    Principal that performed the action (user, collector, or system).

.PARAMETER Server
    Target server FQDN for server/session scoped events.

.PARAMETER SessionId
    Session identifier for session-scoped events.

.PARAMETER Username
    Username associated with the action.

.PARAMETER SessionName
    Session name associated with the action (for example rdp-tcp#3).

.PARAMETER State
    Optional state/details bucket used by multi-state events (for example login Success/Denied/Failed).

.PARAMETER Details
    Human-readable context for the event.

.NOTES
    - Field values are sanitized through Convert-AuditValue.
    - Logging failures are swallowed to avoid impacting request handling.
    - File format: Timestamp|Event|Actor|Server|SessionId|Username|SessionName|State|Details
#>
function Write-AuditLog {
    param(
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Actor = 'collector',
        [string]$Server = '',
        [string]$SessionId = '',
        [string]$Username = '',
        [string]$SessionName = '',
        [string]$State = '',
        [string]$Details = ''
    )

    return

    try {
        if (-not (Test-Path -LiteralPath $auditLogFile)) {
            Add-Content -LiteralPath $auditLogFile -Value 'Timestamp|Event|Actor|Server|SessionId|Username|SessionName|State|Details' -Encoding UTF8
        }

        $line = @(
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            (Convert-AuditValue -Value $Event),
            (Convert-AuditValue -Value $Actor),
            (Convert-AuditValue -Value $Server),
            (Convert-AuditValue -Value $SessionId),
            (Convert-AuditValue -Value $Username),
            (Convert-AuditValue -Value $SessionName),
            (Convert-AuditValue -Value $State),
            (Convert-AuditValue -Value $Details)
        ) -join '|'

        Add-Content -LiteralPath $auditLogFile -Value $line -Encoding UTF8
    }
    catch {
        # Audit logging must never break request handling.
    }
}

function Test-ClientDisconnectedException {
    param([System.Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.Net.HttpListenerException]) {
            $code = 0
            try { $code = [int]$current.ErrorCode } catch {}
            if ($code -in @(64, 1229, 1236, 995)) {
                return $true
            }

            $msg = [string]$current.Message
            if ($msg -match '(?i)nonexistent network connection|forcibly closed|closed by the remote host|connection aborted') {
                return $true
            }
        }

        if ($current -is [System.IO.IOException]) {
            $msg = [string]$current.Message
            if ($msg -match '(?i)unable to write data to the transport connection|forcibly closed|closed by the remote host|connection aborted|i/o operation has been aborted') {
                return $true
            }
        }

        $current = $current.InnerException
    }

    return $false
}

function Send-TextResponse {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [int]$StatusCode = 200,
        [string]$Body = '',
        [string]$ContentType = 'text/plain; charset=utf-8'
    )

    try {
        $Response.StatusCode = $StatusCode
        $Response.ContentType = $ContentType
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $Response.ContentLength64 = $bytes.Length
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    catch {
        if (-not (Test-ClientDisconnectedException -Exception $_.Exception)) {
            throw
        }
    }
    finally {
        try { $Response.Close() } catch {}
    }
}

function Send-BinaryResponse {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [int]$StatusCode = 200,
        [string]$ContentType = 'application/octet-stream',
        [byte[]]$Body = @()
    )

    try {
        $Response.StatusCode = $StatusCode
        $Response.ContentType = $ContentType
        $Response.ContentLength64 = $Body.Length
        $Response.OutputStream.Write($Body, 0, $Body.Length)
    }
    catch {
        if (-not (Test-ClientDisconnectedException -Exception $_.Exception)) {
            throw
        }
    }
    finally {
        try { $Response.Close() } catch {}
    }
}

function Send-Redirect {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][string]$Location
    )

    try {
        $Response.StatusCode = 302
        $Response.RedirectLocation = $Location
    }
    catch {
        if (-not (Test-ClientDisconnectedException -Exception $_.Exception)) {
            throw
        }
    }
    finally {
        try { $Response.Close() } catch {}
    }
}

function Read-RequestBodyBytes {
    param([Parameter(Mandatory = $true)]$Request)

    if (-not $Request.HasEntityBody) {
        return [byte[]]@()
    }

    $stream = $Request.InputStream
    if ($stream.CanSeek) {
        $stream.Position = 0
    }

    $ms = New-Object System.IO.MemoryStream
    try {
        $buffer = New-Object byte[] 4096
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $ms.Write($buffer, 0, $read)
        }
        return $ms.ToArray()
    }
    finally {
        $ms.Dispose()
    }
}

function Read-RequestBodyText {
    param([Parameter(Mandatory = $true)]$Request)

    $bodyBytes = Read-RequestBodyBytes -Request $Request
    if ($null -eq $bodyBytes -or $bodyBytes.Length -eq 0) {
        return ''
    }

    $declaredEncoding = if ($null -ne $Request.ContentEncoding) { $Request.ContentEncoding } else { [System.Text.Encoding]::UTF8 }
    $raw = $declaredEncoding.GetString($bodyBytes)

    # If the body likely arrived in UTF-16, retry decode with UTF-16 LE/BE.
    if ($raw.Contains("`0")) {
        if ($bodyBytes.Length -ge 2 -and $bodyBytes[0] -eq 0xFE -and $bodyBytes[1] -eq 0xFF) {
            $raw = [System.Text.Encoding]::BigEndianUnicode.GetString($bodyBytes)
        }
        else {
            $raw = [System.Text.Encoding]::Unicode.GetString($bodyBytes)
        }
    }

    return ($raw -replace "`0", '').Trim()
}

function ConvertFrom-UrlEncodedForm {
    param([Parameter(Mandatory = $true)][string]$Raw)

    $manualForm = @{}
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $manualForm
    }

    $rawWork = ($Raw -replace "`0", '').Trim()
    if ($rawWork.StartsWith('?')) {
        $rawWork = $rawWork.Substring(1)
    }

    foreach ($pair in ($rawWork -split '&')) {
        if ([string]::IsNullOrWhiteSpace($pair)) {
            continue
        }

        $kv = $pair -split '=', 2
        $rawKey = $kv[0]
        $rawValue = if ($kv.Count -gt 1) { $kv[1] } else { '' }

        # Handle HTML form semantics: '+' is space, then percent-decode.
        $k = [uri]::UnescapeDataString(($rawKey -replace '\+', ' ')).Trim()
        $v = [uri]::UnescapeDataString(($rawValue -replace '\+', ' '))

        if (-not [string]::IsNullOrWhiteSpace($k)) {
            $manualForm[$k] = $v
        }
    }

    return $manualForm
}

function Get-RequestForm {
    param([Parameter(Mandatory = $true)]$Request)

    $rawBody = Read-RequestBodyText -Request $Request
    return ConvertFrom-UrlEncodedForm -Raw $rawBody
}

function Get-FormValue {
    param(
        [Parameter(Mandatory = $true)]$Form,
        [Parameter(Mandatory = $true)][string[]]$CandidateKeys
    )

    foreach ($key in $CandidateKeys) {
        $value = ''
        if ($Form -is [System.Collections.IDictionary]) {
            if ($Form.Contains($key)) {
                $value = [string]$Form[$key]
            }
        }
        else {
            $value = [string]$Form[$key]
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return ''
}

function Remove-ExpiredSessions {
    [System.Threading.Monitor]::Enter($script:sessionsLock)
    try {
        $now = Get-Date
        $expiredKeys = @()
        foreach ($key in $script:sessions.Keys) {
            $entry = $script:sessions[$key]
            if ($null -eq $entry) {
                $expiredKeys += $key
                continue
            }
            if ($entry.ExpiresAt -lt $now) {
                $expiredKeys += $key
            }
        }

        foreach ($key in $expiredKeys) {
            $null = $script:sessions.Remove($key)
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:sessionsLock)
    }
}

function New-AuthSession {
    param([Parameter(Mandatory = $true)][string]$Username)

    $token = [guid]::NewGuid().ToString('N')
    [System.Threading.Monitor]::Enter($script:sessionsLock)
    try {
        $script:sessions[$token] = [PSCustomObject]@{
            Username  = $Username
            ExpiresAt = (Get-Date).AddMinutes($SessionTimeoutMinutes)
            CsrfToken = [guid]::NewGuid().ToString('N')
        }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:sessionsLock)
    }

    return $token
}

function Remove-AuthSession {
    param([string]$Token)

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return
    }

    [System.Threading.Monitor]::Enter($script:sessionsLock)
    try {
        $null = $script:sessions.Remove($Token)
    }
    finally {
        [System.Threading.Monitor]::Exit($script:sessionsLock)
    }
}

function Get-CsrfTokenForRequest {
    param([Parameter(Mandatory = $true)]$Request)

    $cookie = $Request.Cookies[$cookieName]
    if ($null -eq $cookie -or [string]::IsNullOrWhiteSpace($cookie.Value)) {
        return ''
    }

    [System.Threading.Monitor]::Enter($script:sessionsLock)
    try {
        $entry = $script:sessions[$cookie.Value]
        if ($null -eq $entry) {
            return ''
        }

        if (-not $entry.PSObject.Properties['CsrfToken']) {
            $entry | Add-Member -NotePropertyName CsrfToken -NotePropertyValue ([guid]::NewGuid().ToString('N'))
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$entry.CsrfToken)) {
            $entry.CsrfToken = [guid]::NewGuid().ToString('N')
        }

        return [string]$entry.CsrfToken
    }
    finally {
        [System.Threading.Monitor]::Exit($script:sessionsLock)
    }
}

function Get-AuthenticatedUser {
    param([Parameter(Mandatory = $true)]$Request)

    Remove-ExpiredSessions

    $cookie = $Request.Cookies[$cookieName]
    if ($null -eq $cookie -or [string]::IsNullOrWhiteSpace($cookie.Value)) {
        return $null
    }

    [System.Threading.Monitor]::Enter($script:sessionsLock)
    try {
        $entry = $script:sessions[$cookie.Value]
        if ($null -eq $entry) {
            return $null
        }

        if (-not $entry.PSObject.Properties['CsrfToken']) {
            $entry | Add-Member -NotePropertyName CsrfToken -NotePropertyValue ([guid]::NewGuid().ToString('N'))
        }
        elseif ([string]::IsNullOrWhiteSpace([string]$entry.CsrfToken)) {
            $entry.CsrfToken = [guid]::NewGuid().ToString('N')
        }

        $entry.ExpiresAt = (Get-Date).AddMinutes($SessionTimeoutMinutes)
        return $entry.Username
    }
    finally {
        [System.Threading.Monitor]::Exit($script:sessionsLock)
    }
}

function Set-AuthCookie {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][string]$Token
    )

    $cookie = New-Object System.Net.Cookie($cookieName, $Token, '/')
    $cookie.HttpOnly = $true
    $cookie.Secure = $true
    try {
        $cookie.SameSite = [System.Net.SameSiteMode]::Strict
    }
    catch {
        # SameSite enum/property might not be available on older runtimes.
    }
    $Response.SetCookie($cookie)
}

function Clear-AuthCookie {
    param([Parameter(Mandatory = $true)]$Response)

    $cookie = New-Object System.Net.Cookie($cookieName, '', '/')
    $cookie.HttpOnly = $true
    $cookie.Secure = $true
    try {
        $cookie.SameSite = [System.Net.SameSiteMode]::Strict
    }
    catch {
        # SameSite enum/property might not be available on older runtimes.
    }
    $cookie.Expires = (Get-Date).AddDays(-1)
    $Response.SetCookie($cookie)
}

function Test-SameOriginUrl {
    param(
        [Parameter(Mandatory = $true)][string]$UrlValue,
        [Parameter(Mandatory = $true)]$RequestUrl
    )

    if ([string]::IsNullOrWhiteSpace($UrlValue)) {
        return $false
    }

    try {
        $u = [Uri]$UrlValue
        return (
            $u.Scheme.Equals($RequestUrl.Scheme, [System.StringComparison]::OrdinalIgnoreCase) -and
            $u.Host.Equals($RequestUrl.Host, [System.StringComparison]::OrdinalIgnoreCase) -and
            $u.Port -eq $RequestUrl.Port
        )
    }
    catch {
        return $false
    }
}

function Test-CsrfRequest {
    param([Parameter(Mandatory = $true)]$Context)

    $req = $Context.Request
    $cookie = $req.Cookies[$cookieName]
    if ($null -eq $cookie -or [string]::IsNullOrWhiteSpace($cookie.Value)) {
        return $false
    }

    $entry = $script:sessions[$cookie.Value]
    if ($null -eq $entry) {
        return $false
    }

    $expectedToken = [string]$entry.CsrfToken
    $providedToken = [string]$req.Headers['X-CSRF-Token']
    if ([string]::IsNullOrWhiteSpace($expectedToken) -or [string]::IsNullOrWhiteSpace($providedToken) -or $expectedToken -ne $providedToken) {
        return $false
    }

    $origin = [string]$req.Headers['Origin']
    if (-not [string]::IsNullOrWhiteSpace($origin)) {
        return (Test-SameOriginUrl -UrlValue $origin -RequestUrl $req.Url)
    }

    $referer = [string]$req.Headers['Referer']
    if (-not [string]::IsNullOrWhiteSpace($referer)) {
        return (Test-SameOriginUrl -UrlValue $referer -RequestUrl $req.Url)
    }

    return $false
}

function Test-AdCredentials {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][securestring]$Password
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    if ([string]::IsNullOrWhiteSpace($Username) -or [string]::IsNullOrWhiteSpace($plainPassword)) {
        return $false
    }

    $validateUser = $Username
    $validateDomain = if (-not [string]::IsNullOrWhiteSpace($customLoginDomain)) { $customLoginDomain } else { $DefaultDomain }

    if ($Username -match '^(?<dom>[^\\]+)\\(?<usr>.+)$') {
        $validateDomain = $matches.dom
        $validateUser = $matches.usr
    }
    elseif ($Username -match '^(?<usr>[^@]+)@(?<dom>.+)$') {
        $validateDomain = $matches.dom
        $validateUser = $matches.usr
    }

    try {
        $context = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
            [System.DirectoryServices.AccountManagement.ContextType]::Domain,
            $validateDomain
        )

        $ok = $context.ValidateCredentials(
            $validateUser,
            $plainPassword,
            [System.DirectoryServices.AccountManagement.ContextOptions]::Negotiate
        )
        $context.Dispose()
        return $ok
    }
    catch {
        Write-Log "AD validation failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-UserIsAdmin {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [string]$Domain = '',
        [string]$LocalGroupName = 'RDS-Dashboard-Admins'
    )

    $machineCtx = $null
    $localGroup = $null
    $domainCtx = $null
    $targetSid = $null
    $targetUpn = ''
    $targetSam = [string]$Username

    if (-not [string]::IsNullOrWhiteSpace($Domain) -and -not [string]::IsNullOrWhiteSpace($targetSam)) {
        $targetUpn = ('{0}@{1}' -f $targetSam, $Domain)
        try {
            $domainCtx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                [System.DirectoryServices.AccountManagement.ContextType]::Domain,
                $Domain
            )

            $domainUser = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($domainCtx, $targetSam)
            if ($null -eq $domainUser) {
                $domainUser = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity($domainCtx, $targetUpn)
            }
            if ($domainUser -and $domainUser.Sid) {
                $targetSid = $domainUser.Sid.Value
            }
            if ($domainUser) {
                $domainUser.Dispose()
            }
        }
        catch {
            Write-Log "Could not resolve user SID for admin check ($Domain\\$targetSam): $($_.Exception.Message)"
        }
    }

    try {
        $machineCtx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
            [System.DirectoryServices.AccountManagement.ContextType]::Machine
        )
        $localGroup = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($machineCtx, $LocalGroupName)

        if ($null -eq $localGroup) {
            Write-Log "Local group '$LocalGroupName' does not exist."
            return $false
        }

        # GetMembers($true) recursively expands nested groups, catching indirect members.
        foreach ($member in $localGroup.GetMembers($true)) {
            try {
                if ($targetSid -and $member.Sid -and $member.Sid.Value -eq $targetSid) {
                    return $true
                }

                $memberSam = [string]$member.SamAccountName
                $memberUpn = [string]$member.UserPrincipalName
                if (-not [string]::IsNullOrWhiteSpace($Domain)) {
                    if (
                        $memberSam.Equals($targetSam, [System.StringComparison]::OrdinalIgnoreCase) -and
                        (
                            [string]::IsNullOrWhiteSpace($memberUpn) -or
                            $memberUpn.EndsWith("@$Domain", [System.StringComparison]::OrdinalIgnoreCase)
                        )
                    ) {
                        return $true
                    }
                }
                elseif ($memberSam.Equals($targetSam, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }
            catch {
                # Skip members that cannot be resolved (e.g. stale SIDs).
            }
            finally {
                $member.Dispose()
            }
        }

        return $false
    }
    catch {
        Write-Log "Error checking admin group membership for $Username : $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($localGroup) { $localGroup.Dispose() }
        if ($machineCtx)  { $machineCtx.Dispose()  }
        if ($domainCtx)   { $domainCtx.Dispose()   }
    }
}

function Confirm-DashboardAccessGroup {
    $groupName = 'RDS-Dashboard-Admins'
    $groupDescription = 'Users authorized to login on RDS-Dashboard web app'
    $machineCtx = $null
    $localGroup = $null

    try {
        $machineCtx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
            [System.DirectoryServices.AccountManagement.ContextType]::Machine
        )
        $localGroup = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($machineCtx, $groupName)

        if ($null -ne $localGroup) {
            Write-Log "Local group '$groupName' is available."
            Write-AuditLog -Event 'group_status' -Actor 'system' -State 'Verified' -Details "Local group '$groupName' is available"
            return
        }

        $localGroup = New-Object System.DirectoryServices.AccountManagement.GroupPrincipal($machineCtx)
        $localGroup.Name = $groupName
        $localGroup.Description = $groupDescription
        $localGroup.Save()
        Write-Log "Created local group '$groupName'."
        Write-AuditLog -Event 'group_status' -Actor 'system' -State 'Created' -Details "Created local group '$groupName'"
    }
    catch {
        throw "Unable to ensure local group '$groupName': $($_.Exception.Message)"
    }
    finally {
        if ($localGroup) { $localGroup.Dispose() }
        if ($machineCtx) { $machineCtx.Dispose() }
    }
}

function Update-ServerMetricHistoryFromSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)

    [System.Threading.Monitor]::Enter($script:historyLock)
    try {

    $generatedAt = [string]$Snapshot.GeneratedAtUtc
    $cutoffUtc = (Get-Date).ToUniversalTime().AddHours(-2)
    $farmCutoffUtc = (Get-Date).ToUniversalTime().AddDays(-70)

    $serversList = @($Snapshot.Servers | Where-Object { $null -ne $_ })
    $totalSessions = 0
    try {
        if ($null -ne $Snapshot.Summary -and $null -ne $Snapshot.Summary.Total) {
            $totalSessions = [int]$Snapshot.Summary.Total
        }
    }
    catch {}

    $cpuValues = @($serversList | ForEach-Object { if ($null -ne $_.CPU) { [double]$_.CPU } })
    $ramValues = @($serversList | ForEach-Object { if ($null -ne $_.RAM) { [double]$_.RAM } })
    $avgCpu = if ($cpuValues.Count -gt 0) { [math]::Round((($cpuValues | Measure-Object -Average).Average), 1) } else { 0.0 }
    $avgRam = if ($ramValues.Count -gt 0) { [math]::Round((($ramValues | Measure-Object -Average).Average), 1) } else { 0.0 }

    $farmPoints = @($script:farmMetricHistory)
    if (-not [string]::IsNullOrWhiteSpace($generatedAt)) {
        $farmCyclePoints = @([PSCustomObject]@{
                Farm = $script:allServersFarmName
                Ts = $generatedAt
                AvgCPU = $avgCpu
                AvgRAM = $avgRam
                TotalSessions = $totalSessions
            })

        $sessionsList = @($Snapshot.Sessions | Where-Object { $null -ne $_ })
        foreach ($farmName in (Get-ConfiguredFarmNames)) {
            $farmServers = @($serversList | Where-Object { ([string]$_.Farm).Equals($farmName, [System.StringComparison]::OrdinalIgnoreCase) })
            $farmSessions = @($sessionsList | Where-Object { ([string]$_.Farm).Equals($farmName, [System.StringComparison]::OrdinalIgnoreCase) })
            $farmCpuValues = @($farmServers | ForEach-Object { if ($null -ne $_.CPU) { [double]$_.CPU } })
            $farmRamValues = @($farmServers | ForEach-Object { if ($null -ne $_.RAM) { [double]$_.RAM } })
            $farmAvgCpu = if ($farmCpuValues.Count -gt 0) { [math]::Round((($farmCpuValues | Measure-Object -Average).Average), 1) } else { 0.0 }
            $farmAvgRam = if ($farmRamValues.Count -gt 0) { [math]::Round((($farmRamValues | Measure-Object -Average).Average), 1) } else { 0.0 }

            $farmCyclePoints += [PSCustomObject]@{
                Farm = $farmName
                Ts = $generatedAt
                AvgCPU = $farmAvgCpu
                AvgRAM = $farmAvgRam
                TotalSessions = @($farmSessions).Count
            }
        }

        foreach ($newPoint in $farmCyclePoints) {
            $newFarm = [string]$newPoint.Farm
            $farmLastTs = ''
            for ($i = $farmPoints.Count - 1; $i -ge 0; $i--) {
                $existingFarm = [string]$farmPoints[$i].Farm
                if ([string]::IsNullOrWhiteSpace($existingFarm)) {
                    $existingFarm = $script:allServersFarmName
                }
                if ($existingFarm.Equals($newFarm, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $farmLastTs = [string]$farmPoints[$i].Ts
                    break
                }
            }

            if ($generatedAt -ne $farmLastTs) {
                $farmPoints += $newPoint
            }
        }
    }

    $farmPruned = @()
    foreach ($p in $farmPoints) {
        try {
            $dt = [DateTimeOffset]::Parse([string]$p.Ts).UtcDateTime
            if ($dt -ge $farmCutoffUtc) {
                $farmPruned += $p
            }
        }
        catch {
            $farmPruned += $p
        }
    }
    $script:farmMetricHistory = $farmPruned

    foreach ($srv in @($Snapshot.Servers)) {
        if ($null -eq $srv) {
            continue
        }

        $shortName = [string]$srv.Short
        if ([string]::IsNullOrWhiteSpace($shortName)) {
            continue
        }

        $key = $shortName.ToLowerInvariant()
        if (-not $script:serverMetricHistoryByShort.ContainsKey($key)) {
            $script:serverMetricHistoryByShort[$key] = @()
        }

        $points = @($script:serverMetricHistoryByShort[$key])
        $lastTs = if ($points.Count -gt 0) { [string]$points[$points.Count - 1].Ts } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($generatedAt) -and $generatedAt -ne $lastTs) {
            $points += [PSCustomObject]@{
                Ts       = $generatedAt
                CPU      = $srv.CPU
                RAM      = $srv.RAM
                Sessions = $srv.Count
            }
        }

        $pruned = @()
        foreach ($p in $points) {
            $ts = [string]$p.Ts
            try {
                $dt = [DateTimeOffset]::Parse($ts).UtcDateTime
                if ($dt -ge $cutoffUtc) {
                    $pruned += $p
                }
            }
            catch {
                # Keep malformed timestamps to avoid discarding possibly useful data.
                $pruned += $p
            }
        }

        $script:serverMetricHistoryByShort[$key] = $pruned
    }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:historyLock)
    }

}

function Get-ServerMetricHistoryPayload {
    [System.Threading.Monitor]::Enter($script:historyLock)
    try {
        $result = @{}
        foreach ($k in $script:serverMetricHistoryByShort.Keys) {
            $result[$k] = @($script:serverMetricHistoryByShort[$k])
        }
        return $result
    }
    finally {
        [System.Threading.Monitor]::Exit($script:historyLock)
    }
}

function Get-ServerShortName {
    param([string]$ServerName)

    $name = ([string]$ServerName).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return ''
    }

    return ($name.Split('.', 2)[0]).Trim()
}

function Get-ServerHistoryKey {
    param([string]$ServerName)

    $short = (Get-ServerShortName -ServerName $ServerName)
    if ([string]::IsNullOrWhiteSpace($short)) {
        return ''
    }

    return $short.ToLowerInvariant()
}

function Get-ConfiguredFarmNames {
    return @($script:farmServerMap.Keys)
}

function Resolve-FarmName {
    param([string]$FarmName)

    if ([string]::IsNullOrWhiteSpace($FarmName)) {
        return $script:allServersFarmName
    }

    foreach ($name in (Get-ConfiguredFarmNames)) {
        if ($name.Equals($FarmName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $name
        }
    }

    if ($script:allServersFarmName.Equals($FarmName, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $script:allServersFarmName
    }

    return $null
}

function Get-ServerFarmName {
    param([string]$ServerName)

    $normalized = ([string]$ServerName).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ''
    }

    if ($script:serverFarmMap.ContainsKey($normalized)) {
        return [string]$script:serverFarmMap[$normalized]
    }

    $short = (Get-ServerShortName -ServerName $ServerName).ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($short) -and $script:serverFarmMap.ContainsKey($short)) {
        return [string]$script:serverFarmMap[$short]
    }

    return ''
}

function Get-FarmCatalogPayload {
    $catalog = @([PSCustomObject]@{
            Name = $script:allServersFarmName
            ServerCount = @($servers).Count
            IsAllServers = $true
        })

    foreach ($farmName in (Get-ConfiguredFarmNames)) {
        $catalog += [PSCustomObject]@{
            Name = $farmName
            ServerCount = @($script:farmServerMap[$farmName]).Count
            IsAllServers = $false
        }
    }

    return $catalog
}

function Add-FarmMetadataToSnapshot {
    param([Parameter(Mandatory = $true)]$Snapshot)

    foreach ($srv in @($Snapshot.Servers)) {
        if ($null -eq $srv) {
            continue
        }

        $farmName = Get-ServerFarmName -ServerName ([string]$srv.Server)
        $srv | Add-Member -NotePropertyName Farm -NotePropertyValue $farmName -Force
        $srv | Add-Member -NotePropertyName Short -NotePropertyValue (Get-ServerShortName -ServerName ([string]$srv.Server)) -Force
    }

    foreach ($session in @($Snapshot.Sessions)) {
        if ($null -eq $session) {
            continue
        }

        $farmName = Get-ServerFarmName -ServerName ([string]$session.Server)
        $session | Add-Member -NotePropertyName Farm -NotePropertyValue $farmName -Force
        $session | Add-Member -NotePropertyName ServerShort -NotePropertyValue (Get-ServerShortName -ServerName ([string]$session.Server)) -Force
    }

    $farmServerMapPayload = [ordered]@{}
    foreach ($farmName in (Get-ConfiguredFarmNames)) {
        $farmServerMapPayload[$farmName] = @($script:farmServerMap[$farmName])
    }


    $Snapshot | Add-Member -NotePropertyName FarmCatalog -NotePropertyValue (Get-FarmCatalogPayload) -Force
    $Snapshot | Add-Member -NotePropertyName FarmServerMap -NotePropertyValue $farmServerMapPayload -Force
    $Snapshot | Add-Member -NotePropertyName AllServersFarmName -NotePropertyValue $script:allServersFarmName -Force
}

function Get-DataPayload {
    $snapshotFile = Read-CurrentSnapshotFile
    if ($null -eq $snapshotFile -or $null -eq $snapshotFile.Snapshot) {
        return (@{
            GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            Summary = @{ Total = 0; Active = 0; Disconnected = 0 }
            Servers = @()
            Sessions = @()
            ServerHistoryByShort = @{}
            FarmCatalog = (Get-FarmCatalogPayload)
            FarmServerMap = $script:farmServerMap
            AllServersFarmName = $script:allServersFarmName
            NextCycleDelaySeconds = $CycleDelaySeconds
            Message = 'Collector is initializing.'
        } | ConvertTo-Json -Depth 8)
    }

    try {
        $snapshot = $snapshotFile.Snapshot
        Add-FarmMetadataToSnapshot -Snapshot $snapshot

        $oldestTs = ''
        try {
            $oldestTs = Get-OldestFarmDataTimestamp
        }
        catch {
            Write-Log "Failed to get oldest farm data timestamp: $($_.Exception.Message)"
            $oldestTs = ''
        }
        $snapshot | Add-Member -NotePropertyName OldestDataTs -NotePropertyValue $oldestTs -Force
        return ($snapshot | ConvertTo-Json -Depth 10)
    }
    catch {
        Write-Log "Failed to enrich live payload: $($_.Exception.Message)"
        return ($snapshotFile.Snapshot | ConvertTo-Json -Depth 10)
    }
}

function Get-HtmlTemplate {
    param([Parameter(Mandatory = $true)][string]$TemplateName)

    $candidates = @(
        (Join-Path $templateDir $TemplateName),
        (Join-Path (Join-Path $PSScriptRoot 'templates') $TemplateName)
    )

    foreach ($templatePath in $candidates) {
        if (Test-Path -LiteralPath $templatePath) {
            return (Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8)
        }
    }

    Write-Log "Template not found: $TemplateName. Checked: $($candidates -join '; ')"
    $safeTemplateName = [System.Web.HttpUtility]::HtmlEncode($TemplateName)
    return @"
<!doctype html>
<html>
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>$dashboardTitle</title>
</head>
<body style="font-family:Segoe UI, Tahoma, sans-serif;padding:20px;">
    <h2>Template missing</h2>
    <p>Unable to load template: $safeTemplateName</p>
    <p>Checked folders:</p>
    <ul>
        <li>$([System.Web.HttpUtility]::HtmlEncode($candidates[0]))</li>
        <li>$([System.Web.HttpUtility]::HtmlEncode($candidates[1]))</li>
    </ul>
    <p><a href="/login">Back to login</a></p>
</body>
</html>
"@
}

function Test-TemplateAvailability {
    # Lite ships only these templates; other Get-HtmlTemplate callers are inherited dead code from the full dashboard.
    $requiredTemplates = @(
        'login.html',
        'dashboard.html',
        'help.html'
    )

    $missing = @()
    foreach ($templateName in $requiredTemplates) {
        $primaryPath = Join-Path $templateDir $templateName
        $fallbackPath = Join-Path (Join-Path $PSScriptRoot 'templates') $templateName
        if ((-not (Test-Path -LiteralPath $primaryPath)) -and (-not (Test-Path -LiteralPath $fallbackPath))) {
            $missing += $templateName
        }
    }

    return $missing
}

function Get-ADUserSearchPage {
    param([string]$Username)

    $safeUser = [System.Web.HttpUtility]::HtmlEncode($Username)
    $effectiveLoginDomain = if (-not [string]::IsNullOrWhiteSpace($customLoginDomain)) { $customLoginDomain } else { $DefaultDomain }
    $template = Get-HtmlTemplate -TemplateName 'ad_search.html'
    return $template.Replace('__DASHBOARD_TITLE__', $dashboardTitle).Replace('__SAFE_USER__', $safeUser).Replace('__AD_DOMAIN__', $effectiveLoginDomain)
}

function Get-HealthHtml {
    param(
        [string]$Username,
        [string]$CsrfToken = ''
    )

    $safeUser = [System.Web.HttpUtility]::HtmlEncode($Username)
    $safeCsrfToken = [System.Web.HttpUtility]::JavaScriptStringEncode($CsrfToken)
    $template = Get-HtmlTemplate -TemplateName 'health.html'
    return $template.Replace('__DASHBOARD_TITLE__', $dashboardTitle).Replace('__SAFE_USER__', $safeUser).Replace('__CSRF_TOKEN__', $safeCsrfToken)
}

function Get-HelpHtml {
    param([string]$Username)

    $safeUser = [System.Web.HttpUtility]::HtmlEncode($Username)
    $safeVersion = [System.Web.HttpUtility]::HtmlEncode($script:ApplicationVersion)
    $template = Get-HtmlTemplate -TemplateName 'help.html'
    return $template.Replace('__DASHBOARD_TITLE__', $dashboardTitle).Replace('__SAFE_USER__', $safeUser).Replace('__APP_VERSION__', $safeVersion)
}

function ConvertTo-LdapFilterString {
    param([string]$String)
    
    if ([string]::IsNullOrEmpty($String)) {
        return $String
    }
    
    # Escape LDAP special characters: * ( ) \ / NUL
    return $String `
        -replace '\\', '\5c' `
        -replace '\*', '\2a' `
        -replace '\(', '\28' `
        -replace '\)', '\29' `
        -replace '/', '\2f' `
        -replace "`0", '\00'
}

function ConvertTo-ADFileTimeInt64 {
    param([object]$FileTimeValue)

    if ($null -eq $FileTimeValue) {
        return $null
    }

    try {
        if ($FileTimeValue -is [long] -or $FileTimeValue -is [int64]) {
            return [int64]$FileTimeValue
        }
        elseif ($FileTimeValue.PSObject -and $FileTimeValue.PSObject.Properties['HighPart'] -and $FileTimeValue.PSObject.Properties['LowPart']) {
            $high = [int64]$FileTimeValue.HighPart
            $low = [uint32]$FileTimeValue.LowPart
            return (($high -shl 32) -bor $low)
        }
        else {
            return [int64]([string]$FileTimeValue)
        }
    }
    catch {
        return $null
    }
}

function Convert-ADFileTimeToRomeText {
    param([object]$FileTimeValue)

    $fileTime = ConvertTo-ADFileTimeInt64 -FileTimeValue $FileTimeValue
    if ($null -eq $fileTime) {
        return ''
    }

    if ($fileTime -le 0) {
        return 'Never'
    }

    try {
        $utcTime = [DateTime]::FromFileTimeUtc($fileTime)
        $romeTz = [System.TimeZoneInfo]::FindSystemTimeZoneById('W. Europe Standard Time')
        $romeTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($utcTime, $romeTz)
        return $romeTime.ToString('yyyy-MM-dd HH:mm:ss')
    }
    catch {
        return ''
    }
}

function Convert-ADAccountExpiresToRomeText {
    param([object]$AccountExpiresValue)

    $fileTime = ConvertTo-ADFileTimeInt64 -FileTimeValue $AccountExpiresValue
    if ($null -eq $fileTime) {
        return ''
    }

    if ($fileTime -le 0 -or $fileTime -eq [Int64]::MaxValue) {
        return 'Never'
    }

    return (Convert-ADFileTimeToRomeText -FileTimeValue $fileTime)
}

function Search-ActiveDirectoryUsers {
    param([string]$Query)
    
    if ([string]::IsNullOrWhiteSpace($Query)) {
        return @{
            success = $false
            error = 'Query is empty'
        }
    }
    
    $ctx = $null
    $searcher = $null
    $searchResults = $null

    try {
        if (-not [string]::IsNullOrWhiteSpace($customLoginDomain)) {
            $ctx = New-Object System.DirectoryServices.DirectoryEntry "LDAP://$customLoginDomain"
        }
        else {
            $ctx = New-Object System.DirectoryServices.DirectoryEntry
        }
        $searcher = New-Object System.DirectoryServices.DirectorySearcher -ArgumentList $ctx
        
        $escapedQuery = ConvertTo-LdapFilterString -String $Query
        $filter = "(&(sAMAccountType=805306368)(|(displayName=*$escapedQuery*)(cn=*$escapedQuery*)(sAMAccountName=*$escapedQuery*)))"
        $searcher.Filter = $filter
        
        $searcher.PropertiesToLoad.AddRange(@('displayName', 'cn', 'sAMAccountName', 'mail', 'userAccountControl', 'pwdLastSet', 'accountExpires')) | Out-Null
        $searchResults = $searcher.FindAll()
        
        $results = @()
        foreach ($result in $searchResults) {
            $props = $result.Properties
            $uacRaw = @($props['userAccountControl'])[0]
            $pwdLastSetRaw = @($props['pwdLastSet'])[0]
            $accountExpiresRaw = @($props['accountExpires'])[0]
            $accountState = 'Unknown'
            $mustChangeAtNextLogon = 'Unknown'

            $pwdLastSetFileTime = ConvertTo-ADFileTimeInt64 -FileTimeValue $pwdLastSetRaw
            if ($null -ne $pwdLastSetFileTime) {
                $mustChangeAtNextLogon = if ($pwdLastSetFileTime -le 0) { 'Yes' } else { 'No' }
            }

            if ($null -ne $uacRaw -and -not [string]::IsNullOrWhiteSpace([string]$uacRaw)) {
                try {
                    $uac = [int64]$uacRaw
                    $accountState = if (($uac -band 2) -eq 2) { 'Disabled' } else { 'Enabled' }
                }
                catch {
                    $accountState = 'Unknown'
                }
            }

            $results += [PSCustomObject]@{
                FullName = @($props['cn'])[0] -as [string]
                DisplayName = @($props['displayName'])[0] -as [string]
                SamAccountName = @($props['sAMAccountName'])[0] -as [string]
                Email = @($props['mail'])[0] -as [string]
                AccountState = $accountState
                MustChangePasswordAtNextLogon = $mustChangeAtNextLogon
                PasswordLastChangedRome = (Convert-ADFileTimeToRomeText -FileTimeValue $pwdLastSetRaw)
                AccountExpiresRome = (Convert-ADAccountExpiresToRomeText -AccountExpiresValue $accountExpiresRaw)
            }
        }

        return @{
            success = $true
            results = @($results | Sort-Object -Property DisplayName -ErrorAction SilentlyContinue)
        }
    }
    catch {
        Write-Log "AD search error: $($_.Exception.Message)"
        return @{
            success = $false
            error = $_.Exception.Message
        }
    }
    finally {
        if ($searchResults) { $searchResults.Dispose() }
        if ($searcher) { $searcher.Dispose() }
        if ($ctx) { $ctx.Dispose() }
    }
}

function Get-ADUserGroupsPayload {
    param([string]$SamAccountName)

    if ([string]::IsNullOrWhiteSpace($SamAccountName)) {
        return @{
            success = $false
            error = 'SamAccountName is required'
        }
    }

    $domainCtx = $null
    $userPrincipal = $null

    try {
        $effectiveDomain = if (-not [string]::IsNullOrWhiteSpace($customLoginDomain)) { $customLoginDomain } else { $DefaultDomain }
        if ([string]::IsNullOrWhiteSpace($effectiveDomain)) {
            $domainCtx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                [System.DirectoryServices.AccountManagement.ContextType]::Domain
            )
        }
        else {
            $domainCtx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext(
                [System.DirectoryServices.AccountManagement.ContextType]::Domain,
                $effectiveDomain
            )
        }

        $userPrincipal = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity(
            $domainCtx,
            [System.DirectoryServices.AccountManagement.IdentityType]::SamAccountName,
            $SamAccountName
        )

        if ($null -eq $userPrincipal -and -not [string]::IsNullOrWhiteSpace($effectiveDomain)) {
            $upn = ('{0}@{1}' -f $SamAccountName, $effectiveDomain)
            $userPrincipal = [System.DirectoryServices.AccountManagement.UserPrincipal]::FindByIdentity(
                $domainCtx,
                [System.DirectoryServices.AccountManagement.IdentityType]::UserPrincipalName,
                $upn
            )
        }

        if ($null -eq $userPrincipal) {
            return @{
                success = $false
                error = ('User not found: {0}' -f $SamAccountName)
            }
        }

        $directGroups = @()
        foreach ($group in @($userPrincipal.GetGroups())) {
            try {
                $groupName = [string]$group.Name
                if (-not [string]::IsNullOrWhiteSpace($groupName)) {
                    $directGroups += $groupName
                }
            }
            finally {
                if ($group) { $group.Dispose() }
            }
        }

        $allGroups = @()
        $allGroupsWarning = ''
        try {
            foreach ($group in @($userPrincipal.GetAuthorizationGroups())) {
                try {
                    $groupName = [string]$group.Name
                    if (-not [string]::IsNullOrWhiteSpace($groupName)) {
                        $allGroups += $groupName
                    }
                }
                finally {
                    if ($group) { $group.Dispose() }
                }
            }
        }
        catch {
            $allGroupsWarning = $_.Exception.Message
        }

        $directGroups = @($directGroups | Sort-Object -Unique)
        $allGroups = @($allGroups | Sort-Object -Unique)
        if ($allGroups.Count -eq 0 -and $directGroups.Count -gt 0) {
            $allGroups = @($directGroups)
        }

        return @{
            success = $true
            samAccountName = [string]$userPrincipal.SamAccountName
            directGroups = $directGroups
            allGroups = $allGroups
            directCount = $directGroups.Count
            allCount = $allGroups.Count
            warning = $allGroupsWarning
        }
    }
    catch {
        Write-Log "AD groups lookup error for ${SamAccountName}: $($_.Exception.Message)"
        return @{
            success = $false
            error = $_.Exception.Message
        }
    }
    finally {
        if ($userPrincipal) { $userPrincipal.Dispose() }
        if ($domainCtx) { $domainCtx.Dispose() }
    }
}

function Get-LogsHtml {
        param([string]$Username)

        $safeUser = [System.Web.HttpUtility]::HtmlEncode($Username)
        $rows = @()

        if (Test-Path -LiteralPath $auditLogFile) {
                $rows = @(Get-Content -LiteralPath $auditLogFile -Encoding UTF8 | Select-Object -Skip 1)
                # Reverse to show newest first
                $rows = @($rows | Sort-Object { $_ } -Descending)
        }

        $sb = New-Object System.Text.StringBuilder
        foreach ($line in $rows) {
                if ([string]::IsNullOrWhiteSpace($line)) {
                        continue
                }

                $parts = $line -split '\|', 9
                while ($parts.Count -lt 9) {
                        $parts += ''
                }

                $safeCells = @($parts | ForEach-Object { [System.Web.HttpUtility]::HtmlEncode($_) })
                $null = $sb.Append("<tr><td>$($safeCells[0])</td><td>$($safeCells[1])</td><td>$($safeCells[2])</td><td>$($safeCells[3])</td><td>$($safeCells[4])</td><td>$($safeCells[5])</td><td>$($safeCells[6])</td><td>$($safeCells[7])</td><td>$($safeCells[8])</td></tr>")
        }

        $safeAuditLogFile = [System.Web.HttpUtility]::HtmlEncode($auditLogFile)
        $template = Get-HtmlTemplate -TemplateName 'logs.html'
        return $template.Replace('__DASHBOARD_TITLE__', $dashboardTitle).Replace('__SAFE_USER__', $safeUser).Replace('__AUDIT_LOG_FILE__', $safeAuditLogFile).Replace('__LOG_ROWS__', $sb.ToString())
}

function Resolve-ServerName {
    param([Parameter(Mandatory = $true)][string]$ServerName)

    if ([string]::IsNullOrWhiteSpace($ServerName)) {
        return $null
    }

    $inputName = ([string]$ServerName).Trim()

    # First prefer exact configured server name (FQDN or exact configured token).
    foreach ($srv in $servers) {
        if (([string]$srv).Equals($inputName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $srv
        }
    }

    # Then match by short name only when unique; if ambiguous, fail closed.
    $shortMatches = @()
    foreach ($srv in $servers) {
        $short = Get-ServerShortName -ServerName $srv
        if ($short.Equals($inputName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $shortMatches += $srv
        }
    }

    if ($shortMatches.Count -eq 1) {
        return $shortMatches[0]
    }

    if ($shortMatches.Count -gt 1) {
        Write-Log "Resolve-ServerName ambiguous short name '$inputName' ($($shortMatches.Count) matches)."
        return $null
    }

    return $null
}

function Get-ServerHostInfoPayload {
    param([Parameter(Mandatory = $true)][string]$ServerName)

    $resolvedServer = Resolve-ServerName -ServerName $ServerName
    if ($null -eq $resolvedServer) {
        return $null
    }

    $osDisplay = 'N/A'
    $hostType = 'Unknown'
    $ramGb = $null
    $coreCount = $null
    $logicalCount = $null
    $ipAddresses = @()
    $manufacturer = ''
    $model = ''
    $hypervisorPresent = $false

    try {
        $osInfo = Get-CimInstance -ComputerName $resolvedServer -ClassName Win32_OperatingSystem -ErrorAction Stop -OperationTimeoutSec 5
        $caption = [string]$osInfo.Caption
        $version = [string]$osInfo.Version
        $build = [string]$osInfo.BuildNumber
        $osParts = @()
        if (-not [string]::IsNullOrWhiteSpace($caption)) { $osParts += $caption.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($version)) { $osParts += ('v' + $version.Trim()) }
        if (-not [string]::IsNullOrWhiteSpace($build)) { $osParts += ('build ' + $build.Trim()) }
        if ($osParts.Count -gt 0) {
            $osDisplay = ($osParts -join ' | ')
        }
    }
    catch {
        Write-Log "Failed to read OS info from ${resolvedServer}: $($_.Exception.Message)"
    }

    try {
        $computerSystem = Get-CimInstance -ComputerName $resolvedServer -ClassName Win32_ComputerSystem -ErrorAction Stop -OperationTimeoutSec 5
        $manufacturer = [string]$computerSystem.Manufacturer
        $model = [string]$computerSystem.Model
        $hypervisorPresent = [bool]$computerSystem.HypervisorPresent
        if ($null -ne $computerSystem.TotalPhysicalMemory) {
            $ramGb = [math]::Round(([double]$computerSystem.TotalPhysicalMemory / 1GB), 1)
        }
    }
    catch {
        Write-Log "Failed to read computer system info from ${resolvedServer}: $($_.Exception.Message)"
    }

    try {
        $cpuRows = @(Get-CimInstance -ComputerName $resolvedServer -ClassName Win32_Processor -ErrorAction Stop -OperationTimeoutSec 5)
        if ($cpuRows.Count -gt 0) {
            $coreCount = (($cpuRows | Measure-Object -Property NumberOfCores -Sum).Sum)
            $logicalCount = (($cpuRows | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
        }
    }
    catch {
        Write-Log "Failed to read CPU info from ${resolvedServer}: $($_.Exception.Message)"
    }

    try {
        $nicRows = @(Get-CimInstance -ComputerName $resolvedServer -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' -ErrorAction Stop -OperationTimeoutSec 5)
        $ipCandidates = @()
        foreach ($nic in $nicRows) {
            foreach ($ip in @($nic.IPAddress)) {
                $ipText = ([string]$ip).Trim()
                if ([string]::IsNullOrWhiteSpace($ipText)) {
                    continue
                }

                # Ignore transient/local-only addresses to keep the UI focused on routable IPs.
                if ($ipText -match '^169\.254\.' -or $ipText -match '^(?i)fe80:') {
                    continue
                }

                $ipCandidates += $ipText
            }
        }

        $ipAddresses = @($ipCandidates | Sort-Object -Unique)
    }
    catch {
        Write-Log "Failed to read IP info from ${resolvedServer}: $($_.Exception.Message)"
    }

    $vmHints = @('virtual', 'vmware', 'hyper-v', 'kvm', 'xen', 'virtualbox', 'qemu', 'bochs', 'parallels', 'hvm domu')
    $identity = (('{0} {1}' -f $manufacturer, $model).Trim()).ToLowerInvariant()
    $isVirtual = $false
    if ($hypervisorPresent) {
        $isVirtual = $true
    }
    else {
        foreach ($hint in $vmHints) {
            if ($identity.Contains($hint)) {
                $isVirtual = $true
                break
            }
        }
    }

    if ($isVirtual) {
        $hostType = 'Virtual'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($identity)) {
        $hostType = 'Physical'
    }

    $payload = [PSCustomObject]@{
        Server            = $resolvedServer
        Short             = (Get-ServerShortName -ServerName $resolvedServer)
        GeneratedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
        OS                = $osDisplay
        HostType          = $hostType
        RAMGB             = $ramGb
        Cores             = $coreCount
        LogicalProcessors = $logicalCount
        IPs               = $ipAddresses
    }

    return ($payload | ConvertTo-Json -Depth 6)
}

function Get-ServerRdpLoginsPayload {
    param(
        [Parameter(Mandatory = $true)][string]$ServerName,
        [switch]$SummaryOnly
    )

    $resolvedServer = Resolve-ServerName -ServerName $ServerName
    if ($null -eq $resolvedServer) {
        return $null
    }

    $oldestEventUtc = $null
    $oldestEventDate = $null
    $readError = ''
    $rows = New-Object System.Collections.Generic.List[object]

    try {
        $oldestEvent = Get-WinEvent -ComputerName $resolvedServer -LogName Security -MaxEvents 1 -Oldest -ErrorAction Stop
        if ($oldestEvent -and $oldestEvent.TimeCreated) {
            $oldestEventUtc = $oldestEvent.TimeCreated.ToUniversalTime().ToString('o')
            $oldestEventDate = $oldestEvent.TimeCreated.ToString('yyyy.MM.dd')
        }
    }
    catch {
        $readError = $_.Exception.Message
        Write-Log "Failed to query oldest Security event from ${resolvedServer}: $readError"
    }

    if ($SummaryOnly) {
        $summaryPayload = [PSCustomObject]@{
            Server          = $resolvedServer
            Short           = (Get-ServerShortName -ServerName $resolvedServer)
            GeneratedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
            OldestEventUtc  = $oldestEventUtc
            OldestEventDate = $oldestEventDate
            Count           = 0
            Rows            = @()
            ReadError       = $readError
        }

        return ($summaryPayload | ConvertTo-Json -Depth 8)
    }

    try {
        # Filter directly in Event Log query to avoid scanning all 4624 rows.
        $rdpXPath = "*[System[(EventID=4624)] and EventData[Data[@Name='LogonType']='10']]"
        $allEvents = @(Get-WinEvent -ComputerName $resolvedServer -LogName Security -FilterXPath $rdpXPath -ErrorAction Stop)

        foreach ($evt in $allEvents) {
            $eventXml = $null
            try {
                $eventXml = [xml]$evt.ToXml()
            }
            catch {
                continue
            }

            $eventData = @($eventXml.Event.EventData.Data)

            $usernameNode = @($eventData | Where-Object { $_.Name -eq 'TargetUserName' } | Select-Object -First 1)
            $sourceIpNode = @($eventData | Where-Object { $_.Name -eq 'IpAddress' } | Select-Object -First 1)

            $username = if ($usernameNode.Count -gt 0) { ([string]$usernameNode[0].'#text').Trim() } else { '' }
            $sourceIp = if ($sourceIpNode.Count -gt 0) { ([string]$sourceIpNode[0].'#text').Trim() } else { '' }

            if ([string]::IsNullOrWhiteSpace($username)) {
                $username = '-'
            }

            if ([string]::IsNullOrWhiteSpace($sourceIp) -or $sourceIp -eq '-') {
                $sourceIp = '-'
            }
            elseif ($sourceIp -eq '::1') {
                $sourceIp = 'Localhost'
            }

            $rows.Add([PSCustomObject]@{
                LoginTimeUtc = if ($evt.TimeCreated) { $evt.TimeCreated.ToUniversalTime().ToString('o') } else { $null }
                Username     = $username
                SourceIP     = $sourceIp
                LogonType    = 'RDP (Type 10)'
                Status       = 'Success'
            }) | Out-Null
        }
    }
    catch {
        $evtError = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($readError)) {
            $readError = $evtError
        }
        else {
            $readError = "$readError | $evtError"
        }
        Write-Log "Failed to query RDP login events from ${resolvedServer}: $evtError"
    }

    $sortedRows = @($rows | Sort-Object -Property LoginTimeUtc -Descending)
    $payload = [PSCustomObject]@{
        Server          = $resolvedServer
        Short           = (Get-ServerShortName -ServerName $resolvedServer)
        GeneratedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
        OldestEventUtc  = $oldestEventUtc
        OldestEventDate = $oldestEventDate
        Count           = $sortedRows.Count
        Rows            = $sortedRows
        ReadError       = $readError
    }

    return ($payload | ConvertTo-Json -Depth 8)
}

function ConvertTo-SessionMetricKey {
    param([string]$SessionName)

    if ([string]::IsNullOrWhiteSpace($SessionName)) {
        return 'console'
    }

    $k = $SessionName.Trim().ToLowerInvariant()
    $k = ($k -replace '\s+', ' ').Trim()

    # Normalize terminal session suffixes to a canonical form (e.g. rdp-tcp 0 -> rdp-tcp#0).
    if ($k -match '^(?<name>.+?)(?:\s+|#)(?<id>\d+)$') {
        return ("{0}#{1}" -f $matches.name.Trim(), $matches.id)
    }

    return $k
}

function Get-ServerSessionMetricsPayload {
    param(
        [Parameter(Mandatory = $true)][string]$ServerName,
        [switch]$IncludeDebug
    )

    $resolvedServer = Resolve-ServerName -ServerName $ServerName
    if ($null -eq $resolvedServer) {
        return $null
    }

    $cpuBySession = @{}
    $ramBySession = @{}
    $fromCim = $false
    $source = 'none'
    $cimError = $null
    $cpuCounterError = $null
    $ramCounterError = $null

    try {
        # Preferred path: class names are not localized, unlike PerfMon counter paths.
        $sessionPerf = @(Get-CimInstance -ComputerName $resolvedServer -ClassName Win32_PerfFormattedData_TermService_TerminalServicesSession -ErrorAction Stop -OperationTimeoutSec 5)
        foreach ($row in $sessionPerf) {
            $instance = [string]$row.Name
            if ([string]::IsNullOrWhiteSpace($instance) -or $instance -eq '_Total' -or $instance -eq 'Total') {
                continue
            }

            $cpuVal = $null
            $ramValMb = $null

            if ($row.PSObject.Properties['PercentProcessorTime']) {
                $cpuVal = [math]::Round([double]$row.PercentProcessorTime, 1)
            }

            if ($row.PSObject.Properties['WorkingSet']) {
                $ramValMb = [math]::Round(([double]$row.WorkingSet / 1MB), 1)
            }
            elseif ($row.PSObject.Properties['WorkingSetPrivate']) {
                $ramValMb = [math]::Round(([double]$row.WorkingSetPrivate / 1MB), 1)
            }

            $k = ConvertTo-SessionMetricKey -SessionName $instance
            $kBase = ($k -replace '#\d+$', '')
            $cpuBySession[$k] = $cpuVal
            $ramBySession[$k] = $ramValMb
            if ($kBase -ne $k) {
                if (-not $cpuBySession.ContainsKey($kBase)) { $cpuBySession[$kBase] = $cpuVal }
                if (-not $ramBySession.ContainsKey($kBase)) { $ramBySession[$kBase] = $ramValMb }
            }
        }

        if ($cpuBySession.Count -gt 0 -or $ramBySession.Count -gt 0) {
            $fromCim = $true
            $source = 'cim'
        }
    }
    catch {
        $fromCim = $false
        $cimError = $_.Exception.Message
    }

    if (-not $fromCim) {
        # Skip Get-Counter fallback: on some environments it can block indefinitely and stall request handling.
        $cpuCounterError = 'Skipped fallback to avoid blocking request handling.'
        $ramCounterError = 'Skipped fallback to avoid blocking request handling.'
    }

    $allKeys = @($cpuBySession.Keys + $ramBySession.Keys | Sort-Object -Unique)
    $metricsBySessionName = @{}
    foreach ($key in $allKeys) {
        $cpu = $null
        $ram = $null
        if ($cpuBySession.ContainsKey($key)) { $cpu = $cpuBySession[$key] }
        if ($ramBySession.ContainsKey($key)) { $ram = $ramBySession[$key] }

        $metricsBySessionName[$key] = [PSCustomObject]@{
            SessionCPU   = $cpu
            SessionRAMMB = $ram
        }
    }

    $payload = [PSCustomObject]@{
        Server               = $resolvedServer
        Short                = (Get-ServerShortName -ServerName $resolvedServer)
        GeneratedAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
        MetricsBySessionName = $metricsBySessionName
    }

    if ($IncludeDebug) {
        $dataSessionNames = @()
        $dataError = $null
        try {
            $currentSnapshotFile = Read-CurrentSnapshotFile
            if ($null -ne $currentSnapshotFile -and $null -ne $currentSnapshotFile.Snapshot) {
                $dataPayload = $currentSnapshotFile.Snapshot
                $short = (Get-ServerShortName -ServerName $resolvedServer)
                foreach ($s in @($dataPayload.Sessions)) {
                    $sShort = ([string]$s.Server).Split('.')[0]
                    if ($sShort -eq $short -or [string]$s.Server -eq $resolvedServer) {
                        $dataSessionNames += [string]$s.SessionName
                    }
                }
                $dataSessionNames = @($dataSessionNames | Sort-Object -Unique)
            }
        }
        catch {
            $dataError = $_.Exception.Message
        }

        $payload | Add-Member -NotePropertyName Debug -NotePropertyValue ([PSCustomObject]@{
                Source = $source
                MetricKeys = @($metricsBySessionName.Keys | Sort-Object)
                DataSessionNames = $dataSessionNames
                CimError = $cimError
                CounterCpuError = $cpuCounterError
                CounterRamError = $ramCounterError
                DataError = $dataError
            })
    }

    return ($payload | ConvertTo-Json -Depth 8)
}

function Test-AuthorizedSession {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [switch]$Api
    )

    $username = Get-AuthenticatedUser -Request $Context.Request
    if ($null -eq $username) {
        if ($Api) {
            Send-TextResponse -Response $Context.Response -StatusCode 401 -Body 'Unauthorized'
        }
        else {
            Send-Redirect -Response $Context.Response -Location '/login'
        }
        return $null
    }

    return $username
}

function Invoke-SessionCommand {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('logoff', 'disconnect', 'sendmsg')]$Action,
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Message,
        [string]$MessageSender,
        [string]$Username = '',
        [string]$SessionName = ''
    )

    if ($Server -notin $servers) {
        return @{ Status = 400; Body = 'Unknown server.' }
    }

    if ($Id -notmatch '^\d+$') {
        return @{ Status = 400; Body = 'Invalid session id.' }
    }

    try {
        if ($Action -eq 'logoff') {
            $output = (& logoff $Id /server:$Server 2>&1 | Out-String).Trim()
            $code = $LASTEXITCODE
        }
        elseif ($Action -eq 'disconnect') {
            $output = (& tsdiscon $Id /server:$Server 2>&1 | Out-String).Trim()
            $code = $LASTEXITCODE
        }
        else {
            if ([string]::IsNullOrWhiteSpace($Message)) {
                return @{ Status = 400; Body = 'Message is required.' }
            }
            $fullMessage = if ([string]::IsNullOrWhiteSpace($MessageSender)) { $Message } else { "[From: $MessageSender] $Message" }
            $output = (& msg $Id /server:$Server $fullMessage 2>&1 | Out-String).Trim()
            $code = $LASTEXITCODE
        }

        if ($code -ne 0) {
            if ([string]::IsNullOrWhiteSpace($output)) {
                return @{ Status = 500; Body = "Command failed with exit code $code." }
            }
            return @{ Status = 500; Body = $output }
        }

        return @{ Status = 200; Body = 'OK' }
    }
    catch {
        return @{ Status = 500; Body = $_.Exception.Message }
    }
}

function Get-LoginHtml {
    param([string]$ErrorMessage = '')

    $safeError = [System.Web.HttpUtility]::HtmlEncode($ErrorMessage)

        $template = Get-HtmlTemplate -TemplateName 'login.html'
        $effectiveLoginDomain = if (-not [string]::IsNullOrWhiteSpace($customLoginDomain)) { $customLoginDomain } else { $DefaultDomain }
        return $template.Replace('__DASHBOARD_TITLE__', $dashboardTitle).Replace('__SAFE_ERROR__', $safeError).Replace('__AD_DOMAIN__', $effectiveLoginDomain)
}

function Invoke-LoginPost {
    param([Parameter(Mandatory = $true)]$Context)

    $req = $Context.Request
    $res = $Context.Response

    $form = Get-RequestForm -Request $req
    $username = Get-FormValue -Form $form -CandidateKeys @('username', 'Username', 'user', 'User')
    $password = Get-FormValue -Form $form -CandidateKeys @('password', 'Password', 'pass', 'Pass')

    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
        $keys = @($form.Keys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ','
        Write-Log "Login POST missing credentials. ContentType='$($req.ContentType)' HasEntityBody=$($req.HasEntityBody) ContentLength64=$($req.ContentLength64) FormKeys='$keys'"
        Send-TextResponse -Response $res -StatusCode 400 -ContentType 'text/html; charset=utf-8' -Body (Get-LoginHtml -ErrorMessage 'Username and password are required.')
        return
    }

    $username = $username.Trim()
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
    if (Test-AdCredentials -Username $username -Password $securePassword) {
        # Extract username and domain for admin group check
        $checkUser = $username
        $checkDomain = if (-not [string]::IsNullOrWhiteSpace($customLoginDomain)) { $customLoginDomain } else { $DefaultDomain }
        if ($username -match '^(?<dom>[^\\]+)\\(?<usr>.+)$') {
            $checkDomain = $matches.dom
            $checkUser = $matches.usr
        }
        elseif ($username -match '^(?<usr>[^@]+)@(?<dom>.+)$') {
            $checkDomain = $matches.dom
            $checkUser = $matches.usr
        }

        # Check if user is in RDS-Dashboard-Admins local group
        if (-not (Test-UserIsAdmin -Username $checkUser -Domain $checkDomain)) {
            Write-Log "Login denied for $username : user is not a member of RDS-Dashboard-Admins local group"
            Write-AuditLog -Event 'login' -Actor $username -Username $username -State 'Denied' -Details 'User not member of RDS-Dashboard-Admins'
            Send-TextResponse -Response $res -StatusCode 403 -ContentType 'text/html; charset=utf-8' -Body (Get-LoginHtml -ErrorMessage 'Access denied. Only members of the RDS-Dashboard-Admins group can access this dashboard.')
            return
        }

        Write-AuditLog -Event 'login' -Actor $username -Username $username -State 'Success' -Details 'User authenticated and authorized'
        $token = New-AuthSession -Username $username
        Set-AuthCookie -Response $res -Token $token
        Send-Redirect -Response $res -Location '/dashboard'
        return
    }

    Write-AuditLog -Event 'login' -Actor $username -Username $username -State 'Failed' -Details 'Invalid credentials'
    Send-TextResponse -Response $res -StatusCode 401 -ContentType 'text/html; charset=utf-8' -Body (Get-LoginHtml -ErrorMessage 'Invalid AD credentials.')
}

function Get-DashboardHtml {
    param(
        [string]$Username,
        [string]$CsrfToken = '',
        [string]$FlashMessage = ''
    )

    $safeUser = [System.Web.HttpUtility]::HtmlEncode($Username)
    $safeCsrfToken = [System.Web.HttpUtility]::JavaScriptStringEncode($CsrfToken)
    $safeFlashMessage = [System.Web.HttpUtility]::HtmlEncode($FlashMessage)
    $autoRefreshSeconds = [int][math]::Max(($CycleDelaySeconds * 3), ($CollectorTimeoutSeconds + ($CycleDelaySeconds * 2)))
    $autoRefreshText = "Refresh every $autoRefreshSeconds seconds."

    $template = Get-HtmlTemplate -TemplateName 'dashboard.html'
    return $template.Replace('__DASHBOARD_TITLE__', $dashboardTitle).Replace('__SAFE_USER__', $safeUser).Replace('__CSRF_TOKEN__', $safeCsrfToken).Replace('__FLASH_MESSAGE__', $safeFlashMessage).Replace('__AUTO_REFRESH_TEXT__', $autoRefreshText).Replace('__AUTO_REFRESH_SECONDS__', [string]$autoRefreshSeconds)
}

function Get-FarmHtml {
    param(
        [string]$Username,
        [string]$CsrfToken = ''
    )

    $safeUser = [System.Web.HttpUtility]::HtmlEncode($Username)
    $safeCsrfToken = [System.Web.HttpUtility]::JavaScriptStringEncode($CsrfToken)

    $template = Get-HtmlTemplate -TemplateName 'farm.html'
    return $template.Replace('__DASHBOARD_TITLE__', $dashboardTitle).Replace('__SAFE_USER__', $safeUser).Replace('__CSRF_TOKEN__', $safeCsrfToken)
}

function Get-ServerHtml {
    param(
        [string]$Username,
        [string]$CsrfToken = ''
    )

    $safeUser = [System.Web.HttpUtility]::HtmlEncode($Username)
    $safeCsrfToken = [System.Web.HttpUtility]::JavaScriptStringEncode($CsrfToken)

    $template = Get-HtmlTemplate -TemplateName 'server.html'
    return $template.Replace('__DASHBOARD_TITLE__', $dashboardTitle).Replace('__SAFE_USER__', $safeUser).Replace('__CSRF_TOKEN__', $safeCsrfToken)
}

function Get-ServerRdpLoginsHtml {
    param(
        [string]$Username,
        [string]$CsrfToken = ''
    )

    $safeUser = [System.Web.HttpUtility]::HtmlEncode($Username)
    $safeCsrfToken = [System.Web.HttpUtility]::JavaScriptStringEncode($CsrfToken)

    $template = Get-HtmlTemplate -TemplateName 'server_rdp_logins.html'
    return $template.Replace('__DASHBOARD_TITLE__', $dashboardTitle).Replace('__SAFE_USER__', $safeUser).Replace('__CSRF_TOKEN__', $safeCsrfToken)
}

function Get-UniqueServerList {
    param([string[]]$Servers)

    $seen = @{}
    $result = @()
    foreach ($srv in @($Servers)) {
        $name = ([string]$srv).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $key = $name.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $result += $name
        }
    }

    return $result
}

function Set-ConfiguredServersState {
    param(
            [hashtable]$Farms
    )

    $active = @()
    $normalizedFarms = [ordered]@{}
    $serverFarmMap = @{}

        $farmNames = @($Farms.Keys | Sort-Object -Unique)
    foreach ($farmName in $farmNames) {
        $name = ([string]$farmName).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $farmServers = @(Get-UniqueServerList -Servers @($Farms[$name]))
        $activeKeys = @{}
        foreach ($srv in $farmServers) {
            $activeKeys[$srv.ToLowerInvariant()] = $true
            $active += $srv
            $serverFarmMap[$srv.ToLowerInvariant()] = $name
            $serverShort = (Get-ServerShortName -ServerName $srv).ToLowerInvariant()
            if (-not [string]::IsNullOrWhiteSpace($serverShort)) {
                $serverFarmMap[$serverShort] = $name
            }
        }


        $normalizedFarms[$name] = $farmServers
    }

    Set-Variable -Scope Script -Name servers -Value @(Get-UniqueServerList -Servers $active)
    $script:farmServerMap = $normalizedFarms
    $script:serverFarmMap = $serverFarmMap
}

function Get-CurrentConfigState {
    $cfg = Read-ConfigFile -Path $ConfigFile
    $farms = [ordered]@{}

    foreach ($farmName in @($cfg.FarmNames)) {
        $farms[$farmName] = @(Get-UniqueServerList -Servers @($cfg.Farms[$farmName]))
    }

    return [PSCustomObject]@{
        Title = [string]$cfg.Title
        Farms = $farms
        FarmNames = @($cfg.FarmNames)
        Servers = @($cfg.Servers)
        CollectorTimeoutSeconds = if ($cfg.ContainsKey('CollectorTimeoutSeconds')) { [int]$cfg.CollectorTimeoutSeconds } else { $CollectorTimeoutSeconds }
        CycleDelaySeconds = if ($cfg.ContainsKey('CycleDelaySeconds')) { [int]$cfg.CycleDelaySeconds } else { $CycleDelaySeconds }
        MaxConcurrentJobs = if ($cfg.ContainsKey('MaxConcurrentJobs')) { [int]$cfg.MaxConcurrentJobs } else { 6 }
        CollectCpuRam = if ($cfg.ContainsKey('CollectCpuRam')) { [bool]$cfg.CollectCpuRam } else { $true }
    }
}

function Save-CurrentConfigState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [string]$Actor = 'system',
        [string]$AuditEvent = 'settings_config_save',
        [string]$AuditState = 'Success',
        [string]$AuditDetails = ''
    )

    Write-ConfigFile -Path $ConfigFile -Title ([string]$State.Title) -Farms $State.Farms -CollectorTimeoutSeconds ([int]$State.CollectorTimeoutSeconds) -CycleDelaySeconds ([int]$State.CycleDelaySeconds) -MaxConcurrentJobs ([int]$State.MaxConcurrentJobs) -CollectCpuRam ([bool]$State.CollectCpuRam)
    Set-ConfiguredServersState -Farms $State.Farms
    if ($State.PSObject.Properties['CollectorTimeoutSeconds'] -and [int]$State.CollectorTimeoutSeconds -gt 0) {
        $script:CollectorTimeoutSeconds = [int]$State.CollectorTimeoutSeconds
    }
    if ($State.PSObject.Properties['CycleDelaySeconds'] -and [int]$State.CycleDelaySeconds -gt 0) {
        $script:CycleDelaySeconds = [int]$State.CycleDelaySeconds
    }
    Write-AuditLog -Event $AuditEvent -Actor $Actor -State $AuditState -Details $AuditDetails
}

function Get-PreferredFarmName {
    param([string]$FarmName)

    $resolved = Resolve-FarmName -FarmName $FarmName
    if ($null -eq $resolved -or $resolved -eq $script:allServersFarmName) {
        $configured = @(Get-ConfiguredFarmNames)
        if ($configured.Count -gt 0) {
            return [string]$configured[0]
        }
        return 'Default'
    }

    return $resolved
}

function Resolve-UserDomainContext {
    param([string]$Username)

    $checkUser = [string]$Username
    $checkDomain = $DefaultDomain

    if ($checkUser -match '^(?<dom>[^\\]+)\\(?<usr>.+)$') {
        $checkDomain = $matches.dom
        $checkUser = $matches.usr
    }
    elseif ($checkUser -match '^(?<usr>[^@]+)@(?<dom>.+)$') {
        $checkDomain = $matches.dom
        $checkUser = $matches.usr
    }

    return [PSCustomObject]@{
        Username = $checkUser
        Domain = $checkDomain
    }
}

function Test-UserIsSettingsAdmin {
    param([Parameter(Mandatory = $true)][string]$Username)

    $ctx = Resolve-UserDomainContext -Username $Username
    return (Test-UserIsAdmin -Username $ctx.Username -Domain $ctx.Domain -LocalGroupName 'Administrators')
}

function Test-AuthorizedSettings {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [switch]$Api
    )

    $username = Get-AuthenticatedUser -Request $Context.Request
    if ($null -eq $username) {
        if ($Api) {
            Send-TextResponse -Response $Context.Response -StatusCode 401 -Body 'Unauthorized'
        }
        else {
            Send-Redirect -Response $Context.Response -Location '/login'
        }
        return $null
    }

    if (-not (Test-UserIsSettingsAdmin -Username $username)) {
        $detail = 'Settings access denied: local Administrators membership required.'
        Write-AuditLog -Event 'settings_access' -Actor $username -State 'Denied' -Details $detail
        if ($Api) {
            Send-TextResponse -Response $Context.Response -StatusCode 403 -Body 'Forbidden'
        }
        else {
            $msg = [System.Web.HttpUtility]::UrlEncode('Access denied. Settings require local Administrators membership.')
            Send-Redirect -Response $Context.Response -Location ("/dashboard?msg=$msg")
        }
        return $null
    }

    return $username
}

function Test-TcpPort445 {
    param(
        [Parameter(Mandatory = $true)][string]$ServerName,
        [int]$TimeoutMs = 2500
    )

    $server = ([string]$ServerName).Trim()
    if ([string]::IsNullOrWhiteSpace($server)) {
        return [PSCustomObject]@{ Reachable = $false; Message = 'Server name is empty.' }
    }

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($server, 445, $null, $null)
        $waitOk = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $waitOk) {
            return [PSCustomObject]@{ Reachable = $false; Message = 'TCP 445 timeout.' }
        }

        $client.EndConnect($async)
        return [PSCustomObject]@{ Reachable = $true; Message = 'TCP 445 reachable.' }
    }
    catch {
        return [PSCustomObject]@{ Reachable = $false; Message = $_.Exception.Message }
    }
    finally {
        if ($client) {
            try { $client.Close() } catch {}
        }
    }
}

function Get-SettingsPayload {
    param([string]$ConfigFilePath)
    $cfg = Get-CurrentConfigState
    $configText = ''
    $configReadError = ''

    try {
        if (Test-Path -LiteralPath $ConfigFilePath) {
            $configText = [System.IO.File]::ReadAllText($ConfigFilePath, [System.Text.Encoding]::UTF8)
            if ($null -eq $configText) { $configText = '' }
        }
        else {
            $configReadError = "Config file not found: $ConfigFilePath"
        }
    }
    catch {
        $configReadError = $_.Exception.Message
    }

    $activeRows = @()
    foreach ($farmName in @($cfg.FarmNames)) {
        foreach ($srv in @($cfg.Farms[$farmName])) {
            $activeRows += [PSCustomObject]@{
                Farm = $farmName
                Server = $srv
                Status = 'OK'
                Reachable = $true
            }
        }
    }


    return [PSCustomObject]@{
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Title = [string]$cfg.Title
        Farms = @($cfg.FarmNames)
        ActiveServers = $activeRows
        ConfigPath = $ConfigFilePath
        ConfigText = $configText
        ConfigReadError = $configReadError
    }
}

function Get-SettingsHtml {
    param(
        [string]$Username,
        [string]$CsrfToken = '',
        [string]$FlashMessage = ''
    )

    $safeUser = [System.Web.HttpUtility]::HtmlEncode($Username)
    $safeCsrfToken = [System.Web.HttpUtility]::JavaScriptStringEncode($CsrfToken)
    $safeFlashMessage = [System.Web.HttpUtility]::HtmlEncode($FlashMessage)

    $template = Get-HtmlTemplate -TemplateName 'settings.html'
    return $template.Replace('__DASHBOARD_TITLE__', $dashboardTitle).Replace('__SAFE_USER__', $safeUser).Replace('__CSRF_TOKEN__', $safeCsrfToken).Replace('__FLASH_MESSAGE__', $safeFlashMessage)
}

function Resolve-CollectorHostExecutable {
    try {
        $currentProcess = Get-Process -Id $PID -ErrorAction Stop
        if ($currentProcess -and -not [string]::IsNullOrWhiteSpace([string]$currentProcess.Path)) {
            return [string]$currentProcess.Path
        }
    }
    catch {}

    foreach ($commandName in @('pwsh.exe', 'powershell.exe', 'pwsh', 'powershell')) {
        $cmd = Get-Command -Name $commandName -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            return [string]$cmd.Source
        }
    }

    throw 'Unable to resolve a PowerShell host executable for the collector process.'
}

function Get-CollectorProcess {
    return $collectorJob
}

function Get-CollectorJobState {
    if ($null -eq $collectorJob) {
        return 'NotStarted'
    }

    try {
        if ($collectorJob.Handle.IsCompleted) {
            if ($collectorJob.PowerShell.HadErrors) {
                $script:collectorSnapshotState['Error'] = (($collectorJob.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join '; ')
            }
            return 'Stopped'
        }
        return 'Running'
    }
    catch {
        $script:collectorSnapshotState['Error'] = $_.Exception.Message
        return 'Stopped'
    }
}

function Get-CollectorJobId {
    if ($null -eq $collectorJob) {
        return $null
    }

    return $collectorJob.Runspace.InstanceId.ToString()
}

function Stop-CollectorJob {
    if ($null -eq $collectorJob) {
        return
    }

    try { $collectorJob.PowerShell.Stop() } catch {}
    try { $collectorJob.PowerShell.Dispose() } catch {}
    try { $collectorJob.Runspace.Close() } catch {}
    try { $collectorJob.Runspace.Dispose() } catch {}
    $script:collectorSnapshotState['Snapshot'] = $null
    $script:collectorJob = $null
}

function Start-CollectorJob {
    $collectorPath = Join-Path $scriptRoot 'collector.ps1'
    if (-not (Test-Path -LiteralPath $collectorPath)) {
        throw "Collector script not found at $collectorPath"
    }

    $collectorConfigPath = $ConfigFile
    if (-not [System.IO.Path]::IsPathRooted([string]$collectorConfigPath)) {
        $collectorConfigPath = Join-Path $scriptRoot $collectorConfigPath
    }
    if (Test-Path -LiteralPath $collectorConfigPath) {
        $collectorConfigPath = (Resolve-Path -LiteralPath $collectorConfigPath).Path
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powerShell = [powershell]::Create()
    $powerShell.Runspace = $runspace
    $runspaceScript = {
        param($Path, $Runtime, $Timeout, $Delay, $MaxJobs, $Config, $State)
        . $Path -NoStart -RuntimeDir $Runtime -CollectorTimeoutSeconds $Timeout -CycleDelaySeconds $Delay -MaxConcurrentJobs $MaxJobs -ConfigFile $Config -SharedState $State
        Initialize-Collector
        Main
    }

    $null = $powerShell.AddScript($runspaceScript.ToString())
    $null = $powerShell.AddArgument($collectorPath)
    $null = $powerShell.AddArgument($runtimeDir)
    $null = $powerShell.AddArgument($CollectorTimeoutSeconds)
    $null = $powerShell.AddArgument($CycleDelaySeconds)
    $null = $powerShell.AddArgument($MaxConcurrentJobs)
    $null = $powerShell.AddArgument($collectorConfigPath)
    $null = $powerShell.AddArgument($script:collectorSnapshotState)

    $handle = $powerShell.BeginInvoke()
    $script:collectorJob = [PSCustomObject]@{
        PowerShell = $powerShell
        Runspace = $runspace
        Handle = $handle
    }
    return $script:collectorJob
}

function Get-CollectorLogTail {
    param([string]$Path, [int]$LineCount = 20)
    return ''
}

function Get-CollectorRestartMetrics {
    $nowUtc = (Get-Date).ToUniversalTime()
    $cutoffUtc = $nowUtc.AddHours(-1)
    $script:collectorRestartRequestTimesUtc = @(
        @($script:collectorRestartRequestTimesUtc) | Where-Object { $_ -is [DateTime] -and $_ -ge $cutoffUtc }
    )

    $cooldownRemainingSeconds = 0
    if ($script:collectorRestartNotBeforeUtc -gt $nowUtc) {
        $cooldownRemainingSeconds = [int][math]::Ceiling(($script:collectorRestartNotBeforeUtc - $nowUtc).TotalSeconds)
    }

    return [PSCustomObject]@{
        CooldownSeconds = $script:collectorRestartCooldownSeconds
        CooldownRemainingSeconds = $cooldownRemainingSeconds
        RequestsLastHour = @($script:collectorRestartRequestTimesUtc).Count
        TotalRequests = [int]$script:collectorRestartStats.TotalRequests
        TotalSuccesses = [int]$script:collectorRestartStats.TotalSuccesses
        TotalFailures = [int]$script:collectorRestartStats.TotalFailures
        CooldownBlocked = [int]$script:collectorRestartStats.CooldownBlocked
        LastAttemptUtc = [string]$script:collectorRestartStats.LastAttemptUtc
        LastSuccessUtc = [string]$script:collectorRestartStats.LastSuccessUtc
        LastFailureUtc = [string]$script:collectorRestartStats.LastFailureUtc
        LastFailureMessage = [string]$script:collectorRestartStats.LastFailureMessage
        LastActor = [string]$script:collectorRestartStats.LastActor
        LastOutcome = [string]$script:collectorRestartStats.LastOutcome
        WarningActive = $false
        WarningReason = ''
    }
}

function Restart-CollectorJob {
    param(
        [string]$Actor = 'system',
        [switch]$IgnoreCooldown
    )

    $nowUtc = (Get-Date).ToUniversalTime()
    $script:collectorRestartStats.TotalRequests = [int]$script:collectorRestartStats.TotalRequests + 1
    $script:collectorRestartStats.LastAttemptUtc = $nowUtc.ToString('o')
    $script:collectorRestartStats.LastActor = $Actor
    $script:collectorRestartRequestTimesUtc = @(@($script:collectorRestartRequestTimesUtc) + $nowUtc)

    if (-not $IgnoreCooldown -and $script:collectorRestartNotBeforeUtc -gt $nowUtc) {
        $remainingSeconds = [int][math]::Ceiling(($script:collectorRestartNotBeforeUtc - $nowUtc).TotalSeconds)
        $message = "Restart cooldown active for ${remainingSeconds}s."
        $script:collectorRestartStats.CooldownBlocked = [int]$script:collectorRestartStats.CooldownBlocked + 1
        $script:collectorRestartStats.LastFailureUtc = $nowUtc.ToString('o')
        $script:collectorRestartStats.LastFailureMessage = $message
        $script:collectorRestartStats.LastOutcome = 'CooldownBlocked'

        return [PSCustomObject]@{
            Success = $false
            Message = $message
            JobId = Get-CollectorJobId
            State = Get-CollectorJobState
            Blocked = $true
        }
    }

    try {
        Stop-CollectorJob

        $script:collectorJob = Start-CollectorJob
        # Verify the collector does not exit immediately after launch.
        Start-Sleep -Milliseconds 1200
        $stateAfterStart = Get-CollectorJobState
        if ($stateAfterStart -ne 'Running') {
            $stderrTail = Get-CollectorLogTail -Path $collectorStdErrLog -LineCount 30
            if ([string]::IsNullOrWhiteSpace($stderrTail)) {
                $stdoutTail = Get-CollectorLogTail -Path $collectorStdOutLog -LineCount 30
                if (-not [string]::IsNullOrWhiteSpace($stdoutTail)) {
                    throw ("Collector exited immediately after restart. stdout tail: {0}" -f $stdoutTail)
                }
                throw 'Collector exited immediately after restart.'
            }
            throw ("Collector exited immediately after restart. stderr tail: {0}" -f $stderrTail)
        }

        $script:collectorRestartNotBeforeUtc = $nowUtc.AddSeconds($script:collectorRestartCooldownSeconds)
        $script:collectorRestartStats.TotalSuccesses = [int]$script:collectorRestartStats.TotalSuccesses + 1
        $script:collectorRestartStats.LastSuccessUtc = $nowUtc.ToString('o')
        $script:collectorRestartStats.LastFailureMessage = ''
        $script:collectorRestartStats.LastOutcome = 'Success'
        Write-Log "Collector job restarted by $Actor."
        Write-AuditLog -Event 'collector_restart' -Actor $Actor -State 'Success' -Details 'Collector background job restarted'

        return [PSCustomObject]@{
            Success = $true
            Message = 'Collector restarted.'
            JobId = Get-CollectorJobId
            State = Get-CollectorJobState
            Blocked = $false
        }
    }
    catch {
        $message = $_.Exception.Message
        $script:collectorRestartNotBeforeUtc = $nowUtc.AddSeconds($script:collectorRestartCooldownSeconds)
        $script:collectorRestartStats.TotalFailures = [int]$script:collectorRestartStats.TotalFailures + 1
        $script:collectorRestartStats.LastFailureUtc = $nowUtc.ToString('o')
        $script:collectorRestartStats.LastFailureMessage = $message
        $script:collectorRestartStats.LastOutcome = 'Failed'
        Write-Log "Failed to restart collector job for $Actor : $message"
        Write-AuditLog -Event 'collector_restart' -Actor $Actor -State 'Failed' -Details $message

        return [PSCustomObject]@{
            Success = $false
            Message = $message
            JobId = $null
            State = 'Failed'
            Blocked = $false
        }
    }
}

<#
.SYNOPSIS
    Remove-OldAuditLogs
    
.DESCRIPTION
    Performs automatic cleanup of the audit log by deleting entries older than the specified retention period.
    Runs at service startup to maintain audit log performance and storage efficiency.
    Preserves the pipe-delimited format with header row intact.
    
.PARAMETER DaysToKeep
    Retention period in days. Default is 100 days. Entries with timestamps older than (today - DaysToKeep) are deleted.
    
.RETURNS
    [int] Count of deleted audit log lines. Returns 0 if no deletion occurred or on error.
    
.NOTES
    - Lines with unparseable timestamps are kept (fail-safe behavior)
    - Write failures are logged but do not halt the service
    - Cleanup runs once per service start
#>
function Remove-OldAuditLogs {
    param([int]$DaysToKeep = 100)
    
    # Exit early if audit log doesn't exist yet
    if (-not (Test-Path -LiteralPath $auditLogFile)) {
        return 0
    }
    
    try {
        # Read all lines and verify file has content
        $allLines = @(Get-Content -LiteralPath $auditLogFile -Encoding UTF8)
        if ($allLines.Count -eq 0) {
            return 0
        }
        
        # Separate header (column names) from data rows
        $header = $allLines[0]
        $dataLines = @($allLines | Select-Object -Skip 1)
        
        # Calculate cutoff date: timestamps older than this are deleted
        $cutoffDate = (Get-Date).AddDays(-$DaysToKeep)
        $keptLines = @()
        $deletedCount = 0
        
        # Filter: keep lines newer than cutoff, count deleted lines
        foreach ($line in $dataLines) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            
            # Extract timestamp (first field before first pipe)
            $timestampStr = ([string]$line).Split('|', 2)[0].Trim()
            
            try {
                # Parse timestamp and compare against cutoff
                $lineDate = [datetime]::ParseExact($timestampStr, 'yyyy-MM-dd HH:mm:ss', $null)
                if ($lineDate -ge $cutoffDate) {
                    $keptLines += $line
                }
                else {
                    $deletedCount++
                }
            }
            catch {
                # Fail-safe: keep unparseable lines (corrupted entries are preserved)
                $keptLines += $line
            }
        }
        
        # Write back filtered audit log with header
        if ($deletedCount -gt 0) {
            $newContent = @($header) + $keptLines
            Set-Content -LiteralPath $auditLogFile -Value $newContent -Encoding UTF8
            Write-Log "Cleaned audit log: deleted $deletedCount lines older than $DaysToKeep days"
        }
        
        return $deletedCount
    }
    catch {
        Write-Log "Failed to clean audit logs: $($_.Exception.Message)"
        return 0
    }
}

try {
    Write-Log 'Starting collector background job.'
    $missingTemplates = @(Test-TemplateAvailability)
    if ($missingTemplates.Count -gt 0) {
        Write-Log "WARNING: Missing template files detected: $($missingTemplates -join ', ')"
        Write-AuditLog -Event 'template_status' -Actor 'system' -State 'Missing' -Details ("Missing template files: {0}" -f ($missingTemplates -join ', '))
    }
    else {
        Write-Log 'All required templates found.'
    }
    # Lite has no SQLite support by design; status logging is intentionally omitted.
    $deletedLogs = Remove-OldAuditLogs -DaysToKeep 100
    Confirm-DashboardAccessGroup
    Write-AuditLog -Event 'service_start' -Actor 'system' -Details "RDS Dashboard web service started, version $($script:ApplicationVersion) (cleaned $deletedLogs old audit log entries)"
    $restartResult = Restart-CollectorJob -Actor 'system' -IgnoreCooldown
    if (-not $restartResult.Success) {
        throw "Failed to start collector job: $($restartResult.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($HttpsCertFriendlyName)) {
        Write-Log "No HttpsCertFriendlyName provided. Using existing netsh SSL binding on port $Port."
    }
    else {
        Write-Log "Ensuring HTTPS certificate binding for FriendlyName '$HttpsCertFriendlyName' on port $Port."
        Set-HttpsCertificateBinding -Port $Port -FriendlyName $HttpsCertFriendlyName
    }

    $prefix = "https://$BindHost`:$Port/"
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)

    Write-Log "Starting HTTPS listener on $prefix"
    $listener.Start()
    Write-Log 'Web app started successfully.'
    
    $lastCollectorCheck = Get-Date
    $collectorCheckIntervalSeconds = 30
    $lastMidnightRestartDate = (Get-Date).Date.AddDays(-1)   # Ensure first midnight is not skipped

    $pendingAccept = $null
    while ($listener.IsListening) {
        # Monitor collector job health every 30 seconds
        $now = Get-Date
        if (($now - $lastCollectorCheck).TotalSeconds -ge $collectorCheckIntervalSeconds) {
            $lastCollectorCheck = $now

            # Scheduled midnight collector restart to reclaim memory
            $todayMidnight = $now.Date
            if ($todayMidnight -gt $lastMidnightRestartDate -and $now.TimeOfDay.TotalMinutes -ge 1) {
                $lastMidnightRestartDate = $todayMidnight
                Write-Log "Midnight collector restart: recycling collector to reclaim memory."
                $restartResult = Restart-CollectorJob -Actor 'system' -IgnoreCooldown
                if ($restartResult.Success) {
                    Write-Log "Midnight collector restart completed successfully."
                }
                else {
                    Write-Log "ERROR: Midnight collector restart failed: $($restartResult.Message)"
                }
            }

            if ($null -ne $collectorJob) {
                $jobState = Get-CollectorJobState
                if ($jobState -ne 'Running') {
                    Write-Log "WARNING: Collector job is in '$jobState' state. Attempting to restart..."
                    $snapshotMeta = Get-SnapshotMetadata
                    $restartResult = Restart-CollectorJob -Actor 'system' -IgnoreCooldown
                    if ($restartResult.Success) {
                        Write-Log "Collector job restarted successfully."
                    }
                    elseif ($restartResult.Blocked) {
                        Write-Log "Collector restart skipped: $($restartResult.Message)"
                    }
                    else {
                        Write-Log "ERROR: Failed to restart collector job: $($restartResult.Message)"
                    }
                }
            }
        }
        
        if ($null -eq $pendingAccept) {
            try {
                $pendingAccept = $listener.BeginGetContext($null, $null)
            }
            catch {
                if ($listener.IsListening) {
                    Write-Log "BeginGetContext failed: $($_.Exception.Message)"
                }
                continue
            }
        }

        if (-not $pendingAccept.AsyncWaitHandle.WaitOne(500)) {
            continue
        }

        $ctx = $null
        try {
            $ctx = $listener.EndGetContext($pendingAccept)
        }
        catch {
            if ($listener.IsListening) {
                Write-Log "EndGetContext failed: $($_.Exception.Message)"
            }
            continue
        }
        finally {
            try { $pendingAccept.AsyncWaitHandle.Dispose() } catch {}
            $pendingAccept = $null
        }

        if ($null -eq $ctx) {
            continue
        }
        $req = $ctx.Request
        $res = $ctx.Response

        try {
            $path = $req.Url.AbsolutePath
            $method = $req.HttpMethod

            $removedPaths = @(
                '/farm', '/server', '/server-rdp-logins', '/health', '/logs', '/settings', '/ad-search',
                '/api/health', '/api/health/restart-collector', '/api/server-history', '/api/farm-history',
                '/api/history-debug', '/api/server-session-metrics', '/api/server-host-info', '/api/server-rdp-logins',
                '/api/ad-search', '/api/ad-user-groups', '/api/settings', '/api/settings/add-server',
                '/api/settings/remove-server', '/api/settings/recheck-pending', '/api/settings/activate-pending'
            )
            if ($removedPaths -contains $path) {
                Send-TextResponse -Response $res -StatusCode 404 -Body 'Not found'
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/') {
                $user = Get-AuthenticatedUser -Request $req
                if ($user) {
                    Send-Redirect -Response $res -Location '/dashboard'
                }
                else {
                    Send-Redirect -Response $res -Location '/login'
                }
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/login') {
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body (Get-LoginHtml)
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/login') {
                Invoke-LoginPost -Context $ctx
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/logout') {
                $cookie = $req.Cookies[$cookieName]
                if ($cookie -and $cookie.Value) {
                    Remove-AuthSession -Token $cookie.Value
                }
                Clear-AuthCookie -Response $res
                Send-Redirect -Response $res -Location '/login'
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/dashboard') {
                $user = Test-AuthorizedSession -Context $ctx
                if (-not $user) {
                    continue
                }
                $csrfToken = Get-CsrfTokenForRequest -Request $req
                $query = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
                $flashMessage = [string]$query.Get('msg')
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body (Get-DashboardHtml -Username $user -CsrfToken $csrfToken -FlashMessage $flashMessage)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/help') {
                $user = Test-AuthorizedSession -Context $ctx
                if (-not $user) {
                    continue
                }
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body (Get-HelpHtml -Username $user)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/ad-search') {
                $user = Test-AuthorizedSession -Context $ctx
                if (-not $user) {
                    continue
                }
                $html = Get-ADUserSearchPage -Username $user
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body $html
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/ad-search') {
                $user = Test-AuthorizedSession -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                $query = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query).Get('query')
                if ([string]::IsNullOrWhiteSpace($query)) {
                    Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body (@{ success = $false; error = 'Query parameter is required' } | ConvertTo-Json)
                    continue
                }

                $searchResult = Search-ActiveDirectoryUsers -Query $query
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body ($searchResult | ConvertTo-Json -Depth 5)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/ad-user-groups') {
                $user = Test-AuthorizedSession -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                $samAccountName = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query).Get('sam')
                if ([string]::IsNullOrWhiteSpace($samAccountName)) {
                    Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body (@{ success = $false; error = 'sam query parameter is required' } | ConvertTo-Json)
                    continue
                }

                $groupsResult = Get-ADUserGroupsPayload -SamAccountName $samAccountName
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body ($groupsResult | ConvertTo-Json -Depth 8)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/settings') {
                $user = Test-AuthorizedSettings -Context $ctx
                if (-not $user) {
                    continue
                }

                $csrfToken = Get-CsrfTokenForRequest -Request $req
                $query = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
                $flashMessage = [string]$query.Get('msg')
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body (Get-SettingsHtml -Username $user -CsrfToken $csrfToken -FlashMessage $flashMessage)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/settings') {
                $user = Test-AuthorizedSettings -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                $payload = Get-SettingsPayload -ConfigFilePath $ConfigFile
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body ($payload | ConvertTo-Json -Depth 8)
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/settings/add-server') {
                $user = Test-AuthorizedSettings -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                Send-TextResponse -Response $res -StatusCode 410 -ContentType 'application/json; charset=utf-8' -Body (@{
                        success = $false
                        error = 'Settings write operations are deprecated. Edit config.toml from the Settings page.'
                    } | ConvertTo-Json)
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/settings/remove-server') {
                $user = Test-AuthorizedSettings -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                Send-TextResponse -Response $res -StatusCode 410 -ContentType 'application/json; charset=utf-8' -Body (@{
                        success = $false
                        error = 'Settings write operations are deprecated. Edit config.toml from the Settings page.'
                    } | ConvertTo-Json)
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/settings/recheck-pending') {
                $user = Test-AuthorizedSettings -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                Send-TextResponse -Response $res -StatusCode 410 -ContentType 'application/json; charset=utf-8' -Body (@{
                        success = $false
                        error = 'Settings write operations are deprecated. Edit config.toml from the Settings page.'
                    } | ConvertTo-Json)
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/settings/activate-pending') {
                $user = Test-AuthorizedSettings -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                Send-TextResponse -Response $res -StatusCode 410 -ContentType 'application/json; charset=utf-8' -Body (@{
                        success = $false
                        error = 'Settings write operations are deprecated. Edit config.toml from the Settings page.'
                    } | ConvertTo-Json)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/logs') {
                $user = Test-AuthorizedSession -Context $ctx
                if (-not $user) {
                    continue
                }
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body (Get-LogsHtml -Username $user)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/health') {
                $user = Test-AuthorizedSession -Context $ctx
                if (-not $user) {
                    continue
                }
                $csrfToken = Get-CsrfTokenForRequest -Request $req
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body (Get-HealthHtml -Username $user -CsrfToken $csrfToken)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/data') {
                $user = Test-AuthorizedSession -Context $ctx -Api
                if (-not $user) {
                    continue
                }
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body (Get-DataPayload)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/server-session-metrics') {
                $user = Test-AuthorizedSession -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                $query = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
                $serverName = $query.Get('name')
                $debugMode = $query.Get('debug')
                $includeDebug = ($debugMode -eq '1' -or $debugMode -eq 'true' -or $debugMode -eq 'yes')
                if ([string]::IsNullOrWhiteSpace($serverName)) {
                    Send-TextResponse -Response $res -StatusCode 400 -Body 'Missing server name.'
                    continue
                }

                $metricsPayload = Get-ServerSessionMetricsPayload -ServerName $serverName -IncludeDebug:$includeDebug
                if ($null -eq $metricsPayload) {
                    Send-TextResponse -Response $res -StatusCode 404 -Body 'Unknown server.'
                    continue
                }

                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $metricsPayload
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/server-host-info') {
                $user = Test-AuthorizedSession -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                $query = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
                $serverName = $query.Get('name')
                if ([string]::IsNullOrWhiteSpace($serverName)) {
                    Send-TextResponse -Response $res -StatusCode 400 -Body 'Missing server name.'
                    continue
                }

                $hostPayload = Get-ServerHostInfoPayload -ServerName $serverName
                if ($null -eq $hostPayload) {
                    Send-TextResponse -Response $res -StatusCode 404 -Body 'Unknown server.'
                    continue
                }

                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $hostPayload
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/server-rdp-logins') {
                $user = Test-AuthorizedSession -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                $query = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
                $serverName = $query.Get('name')
                $oldestOnly = $query.Get('oldestOnly')
                $summaryOnly = ($oldestOnly -eq '1' -or $oldestOnly -eq 'true' -or $oldestOnly -eq 'yes')
                if ([string]::IsNullOrWhiteSpace($serverName)) {
                    Send-TextResponse -Response $res -StatusCode 400 -Body 'Missing server name.'
                    continue
                }

                $rdpPayload = Get-ServerRdpLoginsPayload -ServerName $serverName -SummaryOnly:$summaryOnly
                if ($null -eq $rdpPayload) {
                    Send-TextResponse -Response $res -StatusCode 404 -Body 'Unknown server.'
                    continue
                }

                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body $rdpPayload
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/server-history') {
                $user = Test-AuthorizedSession -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                $query = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
                $serverName = $query.Get('name')
                if ([string]::IsNullOrWhiteSpace($serverName)) {
                    Send-TextResponse -Response $res -StatusCode 400 -Body 'Missing server name.'
                    continue
                }

                $serverHistoryPayload = Get-Server24hHistoryPayload -ServerName $serverName
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body ($serverHistoryPayload | ConvertTo-Json -Depth 6)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/farm-history') {
                $user = Test-AuthorizedSession -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                $query = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
                $farmName = $query.Get('farm')
                $daysText = $query.Get('days')
                $days = 70
                $parsedDays = 0
                if (-not [string]::IsNullOrWhiteSpace($daysText) -and [int]::TryParse($daysText, [ref]$parsedDays)) {
                    $days = [math]::Max(1, [math]::Min(70, $parsedDays))
                }

                $farmHistoryPayload = Get-Farm24hHistoryPayload -FarmName $farmName -Days $days
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body ($farmHistoryPayload | ConvertTo-Json -Depth 6)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/history-debug') {
                $user = Test-AuthorizedSession -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                $query = [System.Web.HttpUtility]::ParseQueryString($req.Url.Query)
                $serverName = $query.Get('name')
                $debugPayload = Get-HistoryDebugPayload -ServerName $serverName
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body ($debugPayload | ConvertTo-Json -Depth 8)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/api/health') {
                $user = Test-AuthorizedSession -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                $healthPayload = Get-ServiceHealthPayload
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body ($healthPayload | ConvertTo-Json -Depth 8)
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/health/restart-collector') {
                $user = Test-AuthorizedSession -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                if (-not (Test-CsrfRequest -Context $ctx)) {
                    Write-Log "Rejected collector restart due to CSRF validation failure from $($req.RemoteEndPoint)"
                    Send-TextResponse -Response $res -StatusCode 403 -Body 'Forbidden'
                    continue
                }

                $restartResult = Restart-CollectorJob -Actor $user -IgnoreCooldown
                $statusCode = if ($restartResult.Success) { 200 } else { 500 }
                Send-TextResponse -Response $res -StatusCode $statusCode -ContentType 'application/json; charset=utf-8' -Body ($restartResult | ConvertTo-Json -Depth 4)
                continue
            }

            if ($method -eq 'POST' -and $path -eq '/api/session-action') {
                $user = Test-AuthorizedSession -Context $ctx -Api
                if (-not $user) {
                    continue
                }

                if (-not (Test-CsrfRequest -Context $ctx)) {
                    Write-Log "Rejected session action due to CSRF validation failure from $($req.RemoteEndPoint)"
                    Send-TextResponse -Response $res -StatusCode 403 -Body 'Forbidden'
                    continue
                }

                $form = Get-RequestForm -Request $req
                $action = $form['action']
                $server = $form['server']
                $id = $form['id']
                $message = $form['message']
                $username = $form['username']
                $sessionName = $form['sessionName']

                $result = Invoke-SessionCommand -Action $action -Server $server -Id $id -Message $message -MessageSender $user -Username $username -SessionName $sessionName
                Send-TextResponse -Response $res -StatusCode $result.Status -Body $result.Body
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/farm') {
                $user = Test-AuthorizedSession -Context $ctx
                if (-not $user) {
                    continue
                }
                $csrfToken = Get-CsrfTokenForRequest -Request $req
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body (Get-FarmHtml -Username $user -CsrfToken $csrfToken)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/server') {
                $user = Test-AuthorizedSession -Context $ctx
                if (-not $user) {
                    continue
                }
                $csrfToken = Get-CsrfTokenForRequest -Request $req
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body (Get-ServerHtml -Username $user -CsrfToken $csrfToken)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/server-rdp-logins') {
                $user = Test-AuthorizedSession -Context $ctx
                if (-not $user) {
                    continue
                }
                $csrfToken = Get-CsrfTokenForRequest -Request $req
                Send-TextResponse -Response $res -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body (Get-ServerRdpLoginsHtml -Username $user -CsrfToken $csrfToken)
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/favicon.ico') {
                $faviconPath = $null
                foreach ($faviconFileName in @('favicon-company.ico', 'favicon-generic.ico')) {
                    $candidatePath = Join-Path $PSScriptRoot $faviconFileName
                    if (Test-Path -LiteralPath $candidatePath) {
                        $faviconPath = $candidatePath
                        break
                    }
                }
                if ($faviconPath) {
                    $faviconBytes = [System.IO.File]::ReadAllBytes($faviconPath)
                    Send-BinaryResponse -Response $res -StatusCode 200 -ContentType 'image/x-icon' -Body $faviconBytes
                } else {
                    Send-TextResponse -Response $res -StatusCode 404 -Body 'Not found'
                }
                continue
            }

            if ($method -eq 'GET' -and $path -eq '/logo.png') {
                $logoPath = $null
                foreach ($logoFileName in @('logo-company.png', 'logo-generic.png')) {
                    $candidatePath = Join-Path $PSScriptRoot $logoFileName
                    if (Test-Path -LiteralPath $candidatePath) {
                        $logoPath = $candidatePath
                        break
                    }
                }
                if ($logoPath) {
                    $logoBytes = [System.IO.File]::ReadAllBytes($logoPath)
                    Send-BinaryResponse -Response $res -StatusCode 200 -ContentType 'image/png' -Body $logoBytes
                } else {
                    Send-TextResponse -Response $res -StatusCode 404 -Body 'Not found'
                }
                continue
            }

            Send-TextResponse -Response $res -StatusCode 404 -Body 'Not found'
        }
        catch {
            Write-Log "Request handling failed [$method $path]: $($_.Exception.ToString())"
            try {
                Send-TextResponse -Response $res -StatusCode 500 -Body 'Internal server error.'
            }
            catch {
                Write-Log "Failed to send error response: $($_.Exception.Message)"
            }
        }
    }
}
catch {
    # Catch any fatal error that escaped the request loop (including startup failures).
    $fatalMsg = $_.Exception.ToString()
    $fatalLine = "FATAL: Service stopped due to unhandled exception: $fatalMsg"

    # Write to server.log (best-effort; $logFile may already be set).
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $logFile -Value "[$stamp] $fatalLine" -Encoding UTF8
    }
    catch {}

    # Also write to host so NSSM stdout capture picks it up.
    Write-Host $fatalLine

    # Write to audit log so the error appears in the /logs UI on next start.
    try {
        if (-not (Test-Path -LiteralPath $auditLogFile)) {
            Add-Content -LiteralPath $auditLogFile -Value 'Timestamp|Event|Actor|Server|SessionId|Username|SessionName|State|Details' -Encoding UTF8
        }
        $auditFatalLine = @(
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            'service_error',
            'system',
            '',
            '',
            '',
            '',
            'Fatal',
            ($_.Exception.Message -replace '\|', '/' -replace "`r|`n", ' ').Trim()
        ) -join '|'
        Add-Content -LiteralPath $auditLogFile -Value $auditFatalLine -Encoding UTF8
    }
    catch {}

    # Re-throw so NSSM / SCM sees a non-zero exit and can apply its restart policy.
    throw
}
finally {
    Write-Log 'RDS Dashboard web service stopping.'

    try {
        if ($null -ne $pendingAccept) {
            try { $pendingAccept.AsyncWaitHandle.Dispose() } catch {}
            $pendingAccept = $null
        }
    }
    catch {}

    # Lite has no file-based audit logging (logs folder is not created); Write-Log console output covers shutdown.
    Write-Log 'RDS Dashboard web service stopped'

    if ($listener -and $listener.IsListening) {
        $listener.Stop()
        $listener.Close()
    }

    Stop-CollectorJob
}



