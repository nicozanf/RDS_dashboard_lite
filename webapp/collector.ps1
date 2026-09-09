param(
    [string]$RuntimeDir,
    [Alias('OutputPath')][string]$LegacyOutputPath,
    [int]$CollectorTimeoutSeconds = 15,
    [int]$CycleDelaySeconds = 10,
    [int]$MaxConcurrentJobs = 6,
    [string]$ConfigFile = "$PSScriptRoot\config.toml",
    [switch]$NoStart,
    [hashtable]$SharedState
)

# Import shared utilities modules
Import-Module -Name (Join-Path $PSScriptRoot 'common.psm1') -ErrorAction Stop
Import-Module -Name (Join-Path $PSScriptRoot 'job-pool.psm1') -ErrorAction Stop

# Debug mode: set to $true to enable cycle diagnostics (CYCLE START, per-server DBG, TIMED OUT, CYCLE END logs)
$script:debugMode = $false
$script:collectCpuRam = $true

$script:allServersFarmName = 'All servers'
$script:sharedState = $SharedState

function Get-CollectorServerShortName {
    param([string]$ServerName)

    $name = ([string]$ServerName).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return ''
    }

    return ($name.Split('.', 2)[0]).Trim()
}

function Get-CollectorServerFarmName {
    param([string]$ServerName)

    $normalized = ([string]$ServerName).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ''
    }

    if ($script:serverFarmMap.ContainsKey($normalized)) {
        return [string]$script:serverFarmMap[$normalized]
    }

    $short = (Get-CollectorServerShortName -ServerName $ServerName).ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($short) -and $script:serverFarmMap.ContainsKey($short)) {
        return [string]$script:serverFarmMap[$short]
    }

    return ''
}

function Get-CollectorFarmCatalog {
    $catalog = @([PSCustomObject]@{
            Name = $script:allServersFarmName
            ServerCount = @($script:servers).Count
            IsAllServers = $true
        })

    foreach ($farmName in @($script:farmServerMap.Keys)) {
        $catalog += [PSCustomObject]@{
            Name = $farmName
            ServerCount = @($script:farmServerMap[$farmName]).Count
            IsAllServers = $false
        }
    }

    return $catalog
}


function Initialize-Collector {

	$script:servers = @()
	$script:farmServerMap = [ordered]@{}
	$script:serverFarmMap = @{}

    if ([string]::IsNullOrWhiteSpace([string]$RuntimeDir) -and -not [string]::IsNullOrWhiteSpace([string]$LegacyOutputPath)) {
        try {
            # Backward compatibility for callers that still pass the old file path argument.
            $legacyPath = [string]$LegacyOutputPath
            if ([System.IO.Path]::HasExtension($legacyPath)) {
                $RuntimeDir = Split-Path -Path $legacyPath -Parent
            }
            else {
                $RuntimeDir = $legacyPath
            }
        }
        catch {
            $RuntimeDir = [string]$LegacyOutputPath
        }
    }

    Write-CollectorLog "Collector script starting. RuntimeDir='$RuntimeDir'"

    $ErrorActionPreference = 'Stop'

    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) {
        throw 'RuntimeDir is required.'
    }

    if (-not (Test-Path -LiteralPath $RuntimeDir)) {
        try {
            New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
        }
        catch {
            throw
        }
    }

    $script:collectorLogPath = $null

    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $scriptRoot = $PSScriptRoot
    }
    else {
        $scriptRoot = Split-Path -Path $PSCommandPath -Parent
    }

    $resolvedConfigPath = Resolve-CollectorConfigPath -CandidatePath $ConfigFile -ScriptRoot $scriptRoot -OutputDir $RuntimeDir
    $ConfigFile = $resolvedConfigPath

    $configData = Read-ConfigFile -Path $ConfigFile
    $script:servers = @($configData.Servers)
    foreach ($farmName in @($configData.FarmNames)) {
        $script:farmServerMap[$farmName] = @($configData.Farms[$farmName])
    }
    foreach ($key in @($configData.ServerFarmMap.Keys)) {
        $script:serverFarmMap[$key] = [string]$configData.ServerFarmMap[$key]
    }
    if ($script:servers.Count -eq 0) {
        throw "No servers configured in $ConfigFile"
    }
    if ($configData.ContainsKey('CollectorDebugMode') -and [bool]$configData.CollectorDebugMode) {
        $script:debugMode = $true
    }
    $script:collectCpuRam = if ($configData.ContainsKey('CollectCpuRam')) { [bool]$configData.CollectCpuRam } else { $true }

    $serversCount = @($script:servers).Count
    Write-CollectorLog "Collector initialized with $serversCount configured servers across $(@($script:farmServerMap.Keys).Count) farms."

}

function Inizia {
    Initialize-Collector
    Main
}

function Resolve-CollectorConfigPath {
    param(
        [string]$CandidatePath,
        [string]$ScriptRoot,
        [string]$OutputDir
    )

    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($CandidatePath)) {
        $candidates.Add($CandidatePath) | Out-Null

        try {
            if (-not [System.IO.Path]::IsPathRooted($CandidatePath)) {
                if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
                    $candidates.Add((Join-Path $ScriptRoot $CandidatePath)) | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
                    $candidates.Add((Join-Path $PSScriptRoot $CandidatePath)) | Out-Null
                }
            }
        }
        catch {}
    }

    if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
        $candidates.Add((Join-Path $ScriptRoot 'config.toml')) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $candidates.Add((Join-Path $PSScriptRoot 'config.toml')) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputDir)) {
        try {
            $appDir = Split-Path -Path $OutputDir -Parent
            if (-not [string]::IsNullOrWhiteSpace($appDir)) {
                $candidates.Add((Join-Path $appDir 'config.toml')) | Out-Null
            }
        }
        catch {}
    }

    foreach ($path in $candidates) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        try {
            if (Test-Path -LiteralPath $path) {
                return (Resolve-Path -LiteralPath $path).Path
            }
        }
        catch {}
    }

    throw "Unable to resolve config.toml. Candidate paths: $($candidates -join '; ')"
}

function Build-CyclePayload {
    $cycleStarted = Get-Date
    $serversCount = [math]::Max(1, @($script:servers).Count)
    # 12 concurrent is the proven baseline: batches 1+2 complete reliably within 60s on this farm.
    # Higher concurrency (18+) saturates the outbound WinRM connection queue and causes all jobs to
    # hang silently past the global deadline. Lower concurrency recovers naturally once we stagger starts.
    $maxConcurrentJobs = [math]::Min($serversCount, [math]::Max(1, $MaxConcurrentJobs))
    $cimTimeoutSeconds = [int][math]::Min(15, [math]::Max(5, [math]::Floor($CollectorTimeoutSeconds / 3)))
    $quserTimeoutSeconds = [int][math]::Min(12, [math]::Max(4, [math]::Floor($CollectorTimeoutSeconds / 4)))
    if ($script:debugMode) {
        Write-CollectorLog ("CYCLE START: servers={0} maxConcurrent={1} globalTimeout={2}s cimTimeout={3}s quserTimeout={4}s" -f $serversCount, $maxConcurrentJobs, $CollectorTimeoutSeconds, $cimTimeoutSeconds, $quserTimeoutSeconds)
    }

    $jobScript = {
        param($srv, $cimTimeoutSeconds, $quserTimeoutSeconds, $collectorTimeoutSeconds, $collectCpuRam)

        function Convert-IdleToMinutesInner {
            param([string]$IdleTime)

            if ([string]::IsNullOrWhiteSpace($IdleTime) -or $IdleTime -eq '.' -or $IdleTime -eq 'none') {
                return 0
            }

            if ($IdleTime -match '^(?<d>\d+)\+(?<h>\d{1,2}):(?<m>\d{2})$') {
                $d = [int64]$matches.d
                $h = [int]$matches.h
                $m = [int]$matches.m
                if ($h -gt 23 -or $m -gt 59) {
                    return 0
                }
                $total = ($d * 1440) + ($h * 60) + $m
                return [int][Math]::Min($total, 9999L * 1440L)
            }

            if ($IdleTime -match '^(?<h>\d{1,2}):(?<m>\d{2})$') {
                $h = [int]$matches.h
                $m = [int]$matches.m
                if ($m -gt 59) {
                    return 0
                }
                return ($h * 60) + $m
            }

            if ($IdleTime -match '^\d+$') {
                return [int]$IdleTime
            }

            return 0
        }

        function Format-IdleTimeInner {
            param([string]$IdleTime)

            if ([string]::IsNullOrWhiteSpace($IdleTime) -or $IdleTime -eq '.' -or $IdleTime -eq 'none') {
                return '0m'
            }

            if ($IdleTime -match '^(?<d>\d+)\+(?<h>\d{1,2}):(?<m>\d{2})$') {
                $days = [int64]$matches.d
                $hours = [int]$matches.h
                $minutes = [int]$matches.m
                if ($hours -le 23 -and $minutes -le 59) {
                    return '{0}d {1}h {2}m' -f $days, $hours, $minutes
                }
            }

            if ($IdleTime -match '^(?<h>\d{1,2}):(?<m>\d{2})$') {
                $hours = [int]$matches.h
                $minutes = [int]$matches.m
                if ($minutes -le 59) {
                    return '{0}h {1}m' -f $hours, $minutes
                }
            }

            if ($IdleTime -match '^\d+$') {
                return '{0}m' -f ([int]$IdleTime)
            }

            return $IdleTime
        }

        function Convert-LogonTimeToSortValueInner {
            param([string]$LogonTime)

            try {
                $parsed = [DateTime]::Parse($LogonTime)
                return [int64]([DateTimeOffset]$parsed).ToUnixTimeSeconds()
            }
            catch {
                return 0
            }
        }

        function Get-QuserOutputLinesInner {
            param(
                [string]$Server,
                [int]$TimeoutSeconds
            )

            function Invoke-SessionCommandInner {
                param(
                    [string]$FilePath,
                    [string[]]$Arguments,
                    [int]$TimeoutSeconds
                )

                $tempDir = ''
                try {
                    $tempDir = [System.IO.Path]::GetTempPath()
                }
                catch {
                    $tempDir = ''
                }

                if ([string]::IsNullOrWhiteSpace($tempDir)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$env:TEMP)) {
                        $tempDir = [string]$env:TEMP
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace([string]$env:TMP)) {
                        $tempDir = [string]$env:TMP
                    }
                    elseif (-not [string]::IsNullOrWhiteSpace([string]$env:windir)) {
                        $tempDir = (Join-Path $env:windir 'Temp')
                    }
                    else {
                        $tempDir = 'C:\Windows\Temp'
                    }
                }

                try {
                    if (-not (Test-Path -LiteralPath $tempDir)) {
                        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
                    }
                }
                catch {
                    $tempDir = 'C:\Windows\Temp'
                }

                $stdoutPath = Join-Path $tempDir ("quser_{0}_{1}.out" -f $PID, [guid]::NewGuid().ToString('N'))
                $stderrPath = Join-Path $tempDir ("quser_{0}_{1}.err" -f $PID, [guid]::NewGuid().ToString('N'))
                $proc = $null

                try {
                    $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru
                    $waitMs = [int][math]::Max(1000, ($TimeoutSeconds * 1000))
                    if (-not $proc.WaitForExit($waitMs)) {
                        try { $proc.Kill() } catch {}
                        return @()
                    }

                    $outLines = @(Read-TextFileLinesInner -Path $stdoutPath)
                    if ($outLines.Count -gt 0) {
                        return $outLines
                    }

                    $errLines = @(Read-TextFileLinesInner -Path $stderrPath)
                    if ($errLines.Count -gt 0) {
                        return $errLines
                    }

                    return @()
                }
                catch {
                    try {
                        $directOut = (& $FilePath @Arguments 2>&1 | Out-String)
                        if (-not [string]::IsNullOrWhiteSpace($directOut)) {
                            return @($directOut -split "`r?`n")
                        }
                    }
                    catch {}

                    return @()
                }
                finally {
                    if ($proc) {
                        try { $proc.Dispose() } catch {}
                    }
                    try {
                        if (Test-Path -LiteralPath $stdoutPath) { Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue }
                        if (Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }
                    }
                    catch {}
                }
            }

            function Read-TextFileLinesInner {
                param([string]$Path)

                if (-not (Test-Path -LiteralPath $Path)) {
                    return @()
                }

                try {
                    $bytes = [System.IO.File]::ReadAllBytes($Path)
                    if ($null -eq $bytes -or $bytes.Length -eq 0) {
                        return @()
                    }

                    $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
                    if ($raw.Contains("`0")) {
                        if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
                            $raw = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes)
                        }
                        else {
                            $raw = [System.Text.Encoding]::Unicode.GetString($bytes)
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace($raw)) {
                        $raw = [System.Text.Encoding]::Default.GetString($bytes)
                    }

                    return @($raw -split "`r?`n")
                }
                catch {
                    return @()
                }
            }

            $quserExe = Join-Path $env:SystemRoot 'System32\quser.exe'
            if (-not (Test-Path -LiteralPath $quserExe)) {
                $quserExe = 'quser.exe'
            }

            $quserLines = @(Invoke-SessionCommandInner -FilePath $quserExe -Arguments @("/server:$Server") -TimeoutSeconds $TimeoutSeconds)
            if ($quserLines.Count -gt 0) {
                return $quserLines
            }

            return @()
        }

        function ConvertFrom-QuserSessionLineInner {
            param([string]$Line)

            $rawLine = [string]$Line
            if ([string]::IsNullOrWhiteSpace($rawLine)) {
                return $null
            }

            $line = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($line)) {
                return $null
            }

            if ($line -match '^(?i)USERNAME\s+' -or $line -match '^(?i)SESSIONNAME\s+') {
                return $null
            }

            $line = ($line -replace '^>', '').Trim()

            $username = ''
            $sessionName = ''
            $id = ''
            $state = ''
            $idleRaw = ''
            $logonTime = ''

            if ($line -match '^(?<Username>\S+)\s+(?<SessionName>\S+)\s+(?<ID>\d+)\s+(?<State>\S+)\s+(?<IdleTime>\S+)\s+(?<LogonTime>.+)$') {
                $username = [string]$matches.Username
                $sessionName = [string]$matches.SessionName
                $id = [string]$matches.ID
                $state = [string]$matches.State
                $idleRaw = [string]$matches.IdleTime
                $logonTime = [string]$matches.LogonTime
            }
            elseif ($line -match '^(?<Username>\S+)\s+(?<ID>\d+)\s+(?<State>\S+)\s+(?<IdleTime>\S+)\s+(?<LogonTime>.+)$') {
                $username = [string]$matches.Username
                $sessionName = ''
                $id = [string]$matches.ID
                $state = [string]$matches.State
                $idleRaw = [string]$matches.IdleTime
                $logonTime = [string]$matches.LogonTime
            }
            elseif ($line -match '^(?<SessionName>\S+)\s+(?<ID>\d+)\s+(?<State>\S+)\s+(?<IdleTime>\S+)\s+(?<LogonTime>.+)$') {
                $username = ''
                $sessionName = [string]$matches.SessionName
                $id = [string]$matches.ID
                $state = [string]$matches.State
                $idleRaw = [string]$matches.IdleTime
                $logonTime = [string]$matches.LogonTime
            }
            else {
                return $null
            }

            $serverShort = ([string]$srv).Trim()
            if ($serverShort.Contains('.')) {
                $serverShort = $serverShort.Split('.', 2)[0]
            }
            return [PSCustomObject]@{
                Server      = $srv
                ServerShort = $serverShort
                Farm        = ''
                Username    = $username
                SessionName = $sessionName
                ID          = $id
                State       = $state
                IdleTime    = Format-IdleTimeInner -IdleTime $idleRaw
                IdleMinutes = Convert-IdleToMinutesInner -IdleTime $idleRaw
                LogonTime   = ([string]$logonTime).Trim()
                LogonSort   = Convert-LogonTimeToSortValueInner -LogonTime ([string]$logonTime).Trim()
            }
        }

        $jobStarted = Get-Date
        $cpuPct = $null
        $ramPct = $null
        $skipRemainingProbes = $false
        $dbg = [System.Collections.Generic.List[string]]::new()

        if ($collectCpuRam) {
            # RAM probe — Get-CimInstance -OperationTimeoutSec bounds the WMI query phase.
            # Connection/Kerberos phase is bounded by the job-pool global deadline + staggered start.
            $t0 = Get-Date
            $ramErr = ''
            try {
                $os = Get-CimInstance -ComputerName $srv -ClassName Win32_OperatingSystem -ErrorAction Stop -OperationTimeoutSec $cimTimeoutSeconds
                $ramPct = [int](100 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize * 100))
                $ramErr = 'ok'
            }
            catch {
                $ramPct = $null
                $skipRemainingProbes = $true
                $m = ([string]$_.Exception.Message -replace '[\r\n\t]+',' ').Trim()
                $ramErr = 'ERR:' + $(if ($m.Length -gt 90) { $m.Substring(0,90)+'...' } else { $m })
            }
            $dbg.Add(('RAM={0}({1:F1}s)' -f $ramErr, ((Get-Date)-$t0).TotalSeconds))

            # CPU probe
            $cpuErr = 'skipped'
            if (-not $skipRemainingProbes) {
                $t0 = Get-Date
                $cpuErr = ''
                try {
                    $cpu = Get-CimInstance -ComputerName $srv -ClassName Win32_Processor -ErrorAction Stop -OperationTimeoutSec $cimTimeoutSeconds
                    $cpuPct = [int](($cpu | Measure-Object -Property LoadPercentage -Average).Average)
                    $cpuErr = 'ok'
                }
                catch {
                    $cpuPct = $null
                    $m = ([string]$_.Exception.Message -replace '[\r\n\t]+',' ').Trim()
                    $cpuErr = 'ERR:' + $(if ($m.Length -gt 90) { $m.Substring(0,90)+'...' } else { $m })
                }
                $dbg.Add(('CPU={0}({1:F1}s)' -f $cpuErr, ((Get-Date)-$t0).TotalSeconds))
            }
            else {
                $dbg.Add('CPU=skipped(ram-probe-failed)')
            }
        }
        else {
            $dbg.Add('RAM/CPU=disabled')
        }

        # quser probe (skip if already past 60% of global budget)
        $sessions = @()
        $elapsedSoFar = ((Get-Date) - $jobStarted).TotalSeconds
        if ((-not $skipRemainingProbes) -and ($elapsedSoFar -lt ($collectorTimeoutSeconds * 0.6))) {
            $t0 = Get-Date
            $quserErr = ''
            try {
                $quserLines = @(Get-QuserOutputLinesInner -Server $srv -TimeoutSeconds $quserTimeoutSeconds)
                $sessions = @($quserLines | ForEach-Object {
                    ConvertFrom-QuserSessionLineInner -Line $_
                } | Where-Object { $null -ne $_ })
                $quserErr = ('ok:rows={0},sess={1}' -f $quserLines.Count, $sessions.Count)
            }
            catch {
                $sessions = @()
                $m = ([string]$_.Exception.Message -replace '[\r\n\t]+',' ').Trim()
                $quserErr = 'ERR:' + $(if ($m.Length -gt 80) { $m.Substring(0,80)+'...' } else { $m })
            }
            $dbg.Add(('QUSER={0}({1:F1}s)' -f $quserErr, ((Get-Date)-$t0).TotalSeconds))
        }
        elseif ($skipRemainingProbes) {
            $dbg.Add('QUSER=skipped(ram-probe-failed)')
        }
        else {
            $dbg.Add(('QUSER=skipped(elapsed={0:F1}s)' -f $elapsedSoFar))
        }
        $dbg.Add(('total={0:F1}s' -f ((Get-Date)-$jobStarted).TotalSeconds))

        [PSCustomObject]@{
            Server   = $srv
            Sessions = $sessions
            CPU      = $cpuPct
            RAM      = $ramPct
            Debug    = ($dbg -join ' | ')
        }
    }

    $jobPoolResult = Invoke-JobPool -MaxConcurrentJobs $maxConcurrentJobs -TimeoutSeconds $CollectorTimeoutSeconds -JobScript $jobScript -InputObjects @($script:servers) -JobPrefix 'RdsCollector' -ArgumentList @($cimTimeoutSeconds, $quserTimeoutSeconds, $CollectorTimeoutSeconds, $script:collectCpuRam)
    $jobResults = @($jobPoolResult.Results)
    $timedOutCount = [int]$jobPoolResult.TimedOutCount
    $inputCount = if ($null -ne $jobPoolResult.PSObject.Properties['InputCount']) { [int]$jobPoolResult.InputCount } else { @($script:servers).Count }
    $startedCount = if ($null -ne $jobPoolResult.PSObject.Properties['StartedCount']) { [int]$jobPoolResult.StartedCount } else { [int]$jobPoolResult.TotalJobs }
    $startFailedCount = [int][math]::Max(0, ($inputCount - $startedCount))

    # Log per-server stage diagnostics for every completed job
    if ($script:debugMode) {
        foreach ($jr in $jobResults) {
            if (-not [string]::IsNullOrWhiteSpace([string]$jr.Debug)) {
                Write-CollectorLog ("  DBG [{0}]: {1}" -f $jr.Server, $jr.Debug)
            }
        }
    }
    else {
        # Always log probe failures for servers that completed but returned no metric data at all.
        foreach ($jr in $jobResults) {
            if ($null -eq $jr.CPU -and $null -eq $jr.RAM -and @($jr.Sessions).Count -eq 0) {
                if (-not [string]::IsNullOrWhiteSpace([string]$jr.Debug)) {
                    Write-CollectorLog ("  PROBE FAIL [{0}]: {1}" -f $jr.Server, $jr.Debug)
                }
            }
        }
    }

    # Log names of servers whose jobs were killed by the global deadline
    $completedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($jr in $jobResults) { $completedSet.Add([string]$jr.Server) | Out-Null }
    $timedOutServers = @($script:servers | Where-Object { -not $completedSet.Contains([string]$_) })
    if ($script:debugMode -and $timedOutServers.Count -gt 0) {
        Write-CollectorLog ("  TIMED OUT ({0}): {1}" -f $timedOutServers.Count, ($timedOutServers -join ', '))
    }
    if ($startFailedCount -gt 0) {
        Write-CollectorLog ("  START FAIL ({0}): some worker invocations could not be started." -f $startFailedCount)
    }

    $cycleDuration = [int]((Get-Date) - $cycleStarted).TotalSeconds
    if ($script:debugMode) {
        Write-CollectorLog ("CYCLE END: elapsed={0}s pool_started={1}/{2} pool_completed={3}/{4} pool_timedOut={5} pool_failed={6} pool_elapsed={7}s" -f $cycleDuration, $startedCount, $inputCount, $jobPoolResult.CompletedCount, $jobPoolResult.TotalJobs, $jobPoolResult.TimedOutCount, $jobPoolResult.FailedCount, $jobPoolResult.ElapsedSeconds)
    }
    Add-CycleTimeRecord -DurationSeconds $cycleDuration -TimeoutCount $timedOutCount -Summary "Servers: $($script:servers.Count), Started: $startedCount/$inputCount, MaxConcurrent: $maxConcurrentJobs, Timeout: $timedOutCount, Failed: $($jobPoolResult.FailedCount)"

    $sessions = @($jobResults | ForEach-Object { $_.Sessions } | Where-Object { $null -ne $_ })

    $serverStats = foreach ($server in $script:servers) {
        $jr = $jobResults | Where-Object { $_.Server -eq $server } | Select-Object -First 1
        $farmName = Get-CollectorServerFarmName -ServerName $server
        [PSCustomObject]@{
            Server = $server
            Short  = (Get-CollectorServerShortName -ServerName $server)
            Farm   = $farmName
            Count  = if ($jr) { @($jr.Sessions).Count } else { 0 }
            CPU    = if ($jr) { $jr.CPU } else { $null }
            RAM    = if ($jr) { $jr.RAM } else { $null }
        }
    }

    $farmServerMapPayload = [ordered]@{}
    foreach ($farmName in @($script:farmServerMap.Keys)) {
        $farmServerMapPayload[$farmName] = @($script:farmServerMap[$farmName])
    }

    $payload = [PSCustomObject]@{
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        CycleStartedUtc = $cycleStarted.ToUniversalTime().ToString('o')
        CycleDurationSeconds = $cycleDuration
        MaxConcurrentJobs = $maxConcurrentJobs
        InputServersCount = $inputCount
        StartedWorkersCount = $startedCount
        StartFailedServersCount = $startFailedCount
        NextCycleDelaySeconds = $CycleDelaySeconds
        CollectorTimeoutSeconds = $CollectorTimeoutSeconds
        TimedOutServersCount = $timedOutCount
        FailedServersCount = [int]$jobPoolResult.FailedCount
        Summary = [PSCustomObject]@{
            Total = @($sessions).Count
            Active = @($sessions | Where-Object { $_.State -eq 'Active' }).Count
            Disconnected = @($sessions | Where-Object { $_.State -match '^Disc' }).Count
        }
        AllServersFarmName = $script:allServersFarmName
        FarmCatalog = (Get-CollectorFarmCatalog)
        FarmServerMap = $farmServerMapPayload
        Servers = $serverStats
        Sessions = $sessions
    }

    return $payload
}

$collectorDefaultRuntimeDir = $RuntimeDir
if ([string]::IsNullOrWhiteSpace([string]$collectorDefaultRuntimeDir)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$LegacyOutputPath)) {
        try {
            if ([System.IO.Path]::HasExtension([string]$LegacyOutputPath)) {
                $collectorDefaultRuntimeDir = Split-Path -Path $LegacyOutputPath -Parent
            }
            else {
                $collectorDefaultRuntimeDir = [string]$LegacyOutputPath
            }
        }
        catch {
            $collectorDefaultRuntimeDir = [string]$LegacyOutputPath
        }
    }
}
if ([string]::IsNullOrWhiteSpace([string]$collectorDefaultRuntimeDir)) {
    $collectorDefaultRuntimeDir = Join-Path $PSScriptRoot 'runtime'
}
$collectorDefaultAppDir = ''
try {
    $collectorDefaultAppDir = Split-Path -Path $collectorDefaultRuntimeDir -Parent
}
catch {
    $collectorDefaultAppDir = ''
}
if ([string]::IsNullOrWhiteSpace($collectorDefaultAppDir)) {
    $script:collectorLogPath = Join-Path (Join-Path $collectorDefaultRuntimeDir 'logs') 'collector.log'
}
else {
    $script:collectorLogPath = Join-Path (Join-Path $collectorDefaultAppDir 'logs') 'collector.log'
}

function Write-CollectorLog {
    param([string]$Message)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] $Message"
    Write-Host $line
    # Collector diagnostics are intentionally console-only in the lite build.
}

function Initialize-MetricsStore {
    return

    $candidateDirs = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace([string]$scriptRoot)) {
        $candidateDirs.Add($scriptRoot) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$PSScriptRoot)) {
        $candidateDirs.Add($PSScriptRoot) | Out-Null
    }
    try {
        $runtimeDir = $RuntimeDir
        $appDir = Split-Path -Path $runtimeDir -Parent
        if (-not [string]::IsNullOrWhiteSpace([string]$appDir)) {
            $candidateDirs.Add($appDir) | Out-Null
        }
    }
    catch {}

    foreach ($dir in $candidateDirs) {
        if ([string]::IsNullOrWhiteSpace([string]$dir)) {
            continue
        }

        try {
            $localSqliteExe = Join-Path $dir 'sqlite3.exe'
            if (Test-Path -LiteralPath $localSqliteExe) {
                $script:sqliteExe = $localSqliteExe
                break
            }
        }
        catch {}
    }

    if ([string]::IsNullOrWhiteSpace([string]$script:sqliteExe)) {
        $cmd = Get-Command -Name 'sqlite3.exe' -ErrorAction SilentlyContinue
        if ($null -ne $cmd) {
            $script:sqliteExe = $cmd.Source
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$script:sqliteExe)) {
        return
    }

    $createSql = @"
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
CREATE TABLE IF NOT EXISTS farm_metrics (
    ts_epoch INTEGER PRIMARY KEY,
    ts_utc TEXT NOT NULL,
    avg_cpu REAL,
    avg_ram REAL,
    avg_sessions REAL,
    server_count INTEGER,
    total_sessions INTEGER
);
CREATE INDEX IF NOT EXISTS idx_farm_metrics_ts_epoch ON farm_metrics(ts_epoch);
CREATE TABLE IF NOT EXISTS farm_metrics_by_farm (
    farm_name TEXT NOT NULL,
    ts_epoch INTEGER NOT NULL,
    ts_utc TEXT NOT NULL,
    avg_cpu REAL,
    avg_ram REAL,
    avg_sessions REAL,
    server_count INTEGER,
    total_sessions INTEGER,
    PRIMARY KEY (farm_name, ts_epoch)
);
CREATE INDEX IF NOT EXISTS idx_farm_metrics_by_farm_ts_epoch ON farm_metrics_by_farm(ts_epoch);
CREATE INDEX IF NOT EXISTS idx_farm_metrics_by_farm_name_ts ON farm_metrics_by_farm(farm_name, ts_epoch);
CREATE TABLE IF NOT EXISTS server_metrics (
    server_short TEXT NOT NULL,
    ts_epoch INTEGER NOT NULL,
    ts_utc TEXT NOT NULL,
    cpu REAL,
    ram REAL,
    sessions INTEGER,
    PRIMARY KEY (server_short, ts_epoch)
);
CREATE INDEX IF NOT EXISTS idx_server_metrics_server_ts ON server_metrics(server_short, ts_epoch);
CREATE TABLE IF NOT EXISTS snapshot_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    ts_utc TEXT NOT NULL,
    payload_json TEXT NOT NULL
);
"@

    try {
        $initOut = (& $script:sqliteExe -cmd "PRAGMA busy_timeout=5000;" $script:farmMetricsDbPath $createSql 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw $initOut
        }

        # Backward-compatible schema migration for existing databases.
        $schemaSql = "PRAGMA table_info(server_metrics);"
        $schemaRows = @(& $script:sqliteExe -cmd "PRAGMA busy_timeout=5000;" -noheader -separator '|' $script:farmMetricsDbPath $schemaSql 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw (($schemaRows | Out-String).Trim())
        }

        $hasSessionsColumn = $false
        foreach ($schemaRow in $schemaRows) {
            $line = ([string]$schemaRow).Trim()
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            $parts = $line -split '\|', 3
            if ($parts.Count -ge 2 -and ([string]$parts[1]).Trim().ToLowerInvariant() -eq 'sessions') {
                $hasSessionsColumn = $true
                break
            }
        }

        if (-not $hasSessionsColumn) {
            $migrateSql = "ALTER TABLE server_metrics ADD COLUMN sessions INTEGER;"
            $migrateOut = (& $script:sqliteExe -cmd "PRAGMA busy_timeout=5000;" $script:farmMetricsDbPath $migrateSql 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) {
                throw $migrateOut
            }
        }

        $script:sqliteEnabled = $true
        Write-CollectorLog "SQLite metrics store initialized at $script:farmMetricsDbPath"
    }
    catch {
        $script:sqliteEnabled = $false
        throw "Failed to initialize SQLite metrics store: $($_.Exception.Message)"
    }
}

function Set-MetricsFromPayload {
    param([Parameter(Mandatory = $true)]$Payload)

    if (-not $script:sqliteEnabled) {
        return
    }

    $serversList = @($Payload.Servers | Where-Object { $null -ne $_ })
    $serverCount = @($serversList).Count

    $totalSessions = 0
    try {
        if ($null -ne $Payload.Summary -and $null -ne $Payload.Summary.Total) {
            $totalSessions = [int]$Payload.Summary.Total
        }
    }
    catch {}

    $avgSessions = if ($serverCount -gt 0) { [math]::Round(($totalSessions / $serverCount), 1) } else { 0.0 }

    $cpuValues = @($serversList | ForEach-Object { if ($null -ne $_.CPU) { [double]$_.CPU } })
    $ramValues = @($serversList | ForEach-Object { if ($null -ne $_.RAM) { [double]$_.RAM } })
    $avgCpu = if ($cpuValues.Count -gt 0) { [math]::Round((($cpuValues | Measure-Object -Average).Average), 1) } else { 0.0 }
    $avgRam = if ($ramValues.Count -gt 0) { [math]::Round((($ramValues | Measure-Object -Average).Average), 1) } else { 0.0 }
    $sessionsList = @($Payload.Sessions | Where-Object { $null -ne $_ })

    $farmStats = @{}
    $farmStats[$script:allServersFarmName] = [PSCustomObject]@{
        CpuValues = @()
        RamValues = @()
        ServerCount = 0
        TotalSessions = $totalSessions
    }
    foreach ($farmName in @($script:farmServerMap.Keys)) {
        $farmStats[$farmName] = [PSCustomObject]@{
            CpuValues = @()
            RamValues = @()
            ServerCount = 0
            TotalSessions = 0
        }
    }

    foreach ($srv in $serversList) {
        $farmName = Get-CollectorServerFarmName -ServerName ([string]$srv.Server)

        $farmStats[$script:allServersFarmName].ServerCount = [int]$farmStats[$script:allServersFarmName].ServerCount + 1

        $cpuVal = $null
        $ramVal = $null
        try { if ($null -ne $srv.CPU) { $cpuVal = [double]$srv.CPU } } catch {}
        try { if ($null -ne $srv.RAM) { $ramVal = [double]$srv.RAM } } catch {}

        if ($null -ne $cpuVal) {
            $farmStats[$script:allServersFarmName].CpuValues += $cpuVal
        }
        if ($null -ne $ramVal) {
            $farmStats[$script:allServersFarmName].RamValues += $ramVal
        }

        if (-not [string]::IsNullOrWhiteSpace($farmName) -and $farmStats.ContainsKey($farmName)) {
            $farmStats[$farmName].ServerCount = [int]$farmStats[$farmName].ServerCount + 1
            if ($null -ne $cpuVal) {
                $farmStats[$farmName].CpuValues += $cpuVal
            }
            if ($null -ne $ramVal) {
                $farmStats[$farmName].RamValues += $ramVal
            }
        }
    }

    foreach ($session in $sessionsList) {
        $farmName = Get-CollectorServerFarmName -ServerName ([string]$session.Server)
        if (-not [string]::IsNullOrWhiteSpace($farmName) -and $farmStats.ContainsKey($farmName)) {
            $farmStats[$farmName].TotalSessions = [int]$farmStats[$farmName].TotalSessions + 1
        }
    }

    $tsUtc = [string]$Payload.GeneratedAtUtc
    $tsEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    try {
        if (-not [string]::IsNullOrWhiteSpace($tsUtc)) {
            $dto = [DateTimeOffset]::Parse($tsUtc)
            $tsEpoch = $dto.ToUnixTimeSeconds()
            $tsUtc = $dto.UtcDateTime.ToString('o')
        }
        else {
            $tsUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
    catch {
        $tsUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    $insertStatements = New-Object System.Collections.Generic.List[string]
    $insertStatements.Add('BEGIN IMMEDIATE;') | Out-Null
    $payloadJson = $null
    try {
        $payloadJson = ($Payload | ConvertTo-Json -Depth 8 -Compress)
    }
    catch {
        $payloadJson = ($Payload | ConvertTo-Json -Depth 8)
    }

    $insertStatements.Add((
        "INSERT OR REPLACE INTO snapshot_state (id, ts_utc, payload_json) VALUES (1, {0}, {1});" -f
        (ConvertTo-SqliteLiteral -Value $tsUtc),
        (ConvertTo-SqliteLiteral -Value $payloadJson)
    )) | Out-Null

    $insertStatements.Add((
        "INSERT OR REPLACE INTO farm_metrics (ts_epoch, ts_utc, avg_cpu, avg_ram, avg_sessions, server_count, total_sessions) VALUES ({0}, {1}, {2}, {3}, {4}, {5}, {6});" -f
        $tsEpoch,
        (ConvertTo-SqliteLiteral -Value $tsUtc),
        (ConvertTo-SqliteLiteral -Value $avgCpu),
        (ConvertTo-SqliteLiteral -Value $avgRam),
        (ConvertTo-SqliteLiteral -Value $avgSessions),
        $serverCount,
        $totalSessions
    )) | Out-Null
    $insertStatements.Add("DELETE FROM farm_metrics WHERE ts_epoch < CAST(strftime('%s','now','-70 days') AS INTEGER);") | Out-Null

    foreach ($farmName in $farmStats.Keys) {
        $stat = $farmStats[$farmName]
        $farmCpu = if (@($stat.CpuValues).Count -gt 0) { [math]::Round(((@($stat.CpuValues) | Measure-Object -Average).Average), 1) } else { 0.0 }
        $farmRam = if (@($stat.RamValues).Count -gt 0) { [math]::Round(((@($stat.RamValues) | Measure-Object -Average).Average), 1) } else { 0.0 }
        $farmServerCount = [int]$stat.ServerCount
        $farmTotalSessions = [int]$stat.TotalSessions
        $farmAvgSessions = if ($farmServerCount -gt 0) { [math]::Round(($farmTotalSessions / $farmServerCount), 1) } else { 0.0 }

        $insertStatements.Add((
            "INSERT OR REPLACE INTO farm_metrics_by_farm (farm_name, ts_epoch, ts_utc, avg_cpu, avg_ram, avg_sessions, server_count, total_sessions) VALUES ({0}, {1}, {2}, {3}, {4}, {5}, {6}, {7});" -f
            (ConvertTo-SqliteLiteral -Value $farmName),
            $tsEpoch,
            (ConvertTo-SqliteLiteral -Value $tsUtc),
            (ConvertTo-SqliteLiteral -Value $farmCpu),
            (ConvertTo-SqliteLiteral -Value $farmRam),
            (ConvertTo-SqliteLiteral -Value $farmAvgSessions),
            $farmServerCount,
            $farmTotalSessions
        )) | Out-Null
    }
    $insertStatements.Add("DELETE FROM farm_metrics_by_farm WHERE ts_epoch < CAST(strftime('%s','now','-70 days') AS INTEGER);") | Out-Null

    foreach ($srv in $serversList) {
        $serverShort = ([string]$srv.Short).Trim()
        if ([string]::IsNullOrWhiteSpace($serverShort)) {
            continue
        }

        $insertStatements.Add((
            "INSERT OR REPLACE INTO server_metrics (server_short, ts_epoch, ts_utc, cpu, ram, sessions) VALUES ({0}, {1}, {2}, {3}, {4}, {5});" -f
            (ConvertTo-SqliteLiteral -Value $serverShort.ToLowerInvariant()),
            $tsEpoch,
            (ConvertTo-SqliteLiteral -Value $tsUtc),
            (ConvertTo-SqliteLiteral -Value $srv.CPU),
            (ConvertTo-SqliteLiteral -Value $srv.RAM),
            (ConvertTo-SqliteLiteral -Value $srv.Count)
        )) | Out-Null
    }

    $insertStatements.Add("DELETE FROM server_metrics WHERE ts_epoch < CAST(strftime('%s','now','-2 hours') AS INTEGER);") | Out-Null
    $insertStatements.Add('COMMIT;') | Out-Null

    try {
        $sql = ($insertStatements -join [Environment]::NewLine)
        $maxAttempts = 4
        $script:sqliteWriteAttempts++
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            # Pipe SQL through stdin to avoid Windows command-line length limits for large snapshot payloads.
            $writeOut = ($sql | & $script:sqliteExe -cmd "PRAGMA busy_timeout=5000;" $script:farmMetricsDbPath 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) {
                break
            }

            $isLock = (-not [string]::IsNullOrWhiteSpace($writeOut)) -and ($writeOut -match '(?i)database is locked')
            if ($isLock -and $attempt -lt $maxAttempts) {
                $script:sqliteWriteRetryCount++
                Start-Sleep -Milliseconds (150 * $attempt)
                continue
            }

            if ($isLock) {
                $script:sqliteWriteLockErrors++
            }

            throw $writeOut
        }
    }
    catch {
        Write-CollectorLog "Failed to persist metrics from collector: $($_.Exception.Message)"
    }
}

function Publish-CurrentSnapshot {
    param([Parameter(Mandatory = $true)]$Payload)

    if ($null -eq $script:sharedState) {
        return
    }

    $script:sharedState['Snapshot'] = $Payload
    $script:sharedState['UpdatedAtUtc'] = (Get-Date).ToUniversalTime().ToString('o')
}

function Main {
    while ($true) {
        try {
            $payload = $null
            try {
                $payload = Build-CyclePayload
                $serverCount = @($payload.Servers).Count
                Write-CollectorLog "Build-CyclePayload completed in $($payload.CycleDurationSeconds)s (servers: $serverCount, timeout: $($payload.TimedOutServersCount), failed: $($payload.FailedServersCount))."
                if ($payload.TimedOutServersCount -gt 0) {
                    Write-CollectorLog "WARNING: $($payload.TimedOutServersCount)/$serverCount servers exceeded $($payload.CollectorTimeoutSeconds)s timeout."
                }
                if ($payload.FailedServersCount -gt 0) {
                    Write-CollectorLog "WARNING: $($payload.FailedServersCount)/$serverCount server jobs failed during the collection cycle."
                }
            } catch {
                Write-CollectorLog "ERROR in Build-CyclePayload: $($_.Exception.Message)"
                throw
            }

            Publish-CurrentSnapshot -Payload $payload

        }
        catch {
            Write-CollectorLog "ERROR in collection cycle: $($_.Exception.Message)"
            # Continue running even if there was an error - don't crash
        }

        Start-Sleep -Seconds $CycleDelaySeconds
    }
}

if (-not $NoStart) {
    Inizia
}