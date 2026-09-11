# =============================================================================
# common.psm1
# Shared utilities for RDS Dashboard (server.ps1 and collector.ps1)
# Reduces duplication and centralizes maintenance
# =============================================================================

# ---- Configuration File Parsing ----

$script:LegacyDefaultFarmName = 'Default'

function Get-NormalizedConfigServerList {
    param([object]$Values)

    $result = @()
    $seen = @{}
    foreach ($value in @($Values)) {
        $text = ([string]$value).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $key = $text.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $result += $text
        }
    }

    return $result
}

function Read-TomlStringArray {
    param(
        [string]$Content,
        [string]$PropertyName,
        [string]$SectionName = ''
    )

    $prefix = if ([string]::IsNullOrWhiteSpace($SectionName)) { '(?is)(?:^|\r?\n)\s*' } else { '(?ims)^\[' + [regex]::Escape($SectionName) + '\]\s*$.*?' }
    $pattern = $prefix + [regex]::Escape($PropertyName) + '\s*=\s*\[(?<values>.*?)\]'
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) {
        return @()
    }

    $items = @([regex]::Matches($match.Groups['values'].Value, '["\u0027](?<value>[^"\u0027]*)["\u0027]') | ForEach-Object {
        $_.Groups['value'].Value.Trim()
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    return (Get-NormalizedConfigServerList -Values $items)
}

function Read-TomlFarmMap {
    param(
        [string]$Content,
        [string]$SectionName
    )

    $result = [ordered]@{}
    $match = [regex]::Match($Content, '(?ms)^\[' + [regex]::Escape($SectionName) + '\]\s*$(?<body>.*?)(?=^\[[^\]]+\]\s*$|\z)')
    if (-not $match.Success) {
        return $result
    }

    foreach ($farmMatch in [regex]::Matches($match.Groups['body'].Value, '(?ims)^\s*(?<farm>[A-Za-z0-9 _.-]+)\s*=\s*\[(?<values>.*?)\]')) {
        $farmName = ([string]$farmMatch.Groups['farm'].Value).Trim()
        if ([string]::IsNullOrWhiteSpace($farmName)) {
            continue
        }

        $servers = @($farmMatch.Groups['values'].Value -split '\n' | ForEach-Object {
            $_ -replace '["\u0027,]', '' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        })
        $result[$farmName] = @(Get-NormalizedConfigServerList -Values $servers)
    }

    return $result
}

function New-ConfigObject {
    return [ordered]@{
        Title                   = 'RDS Dashboard'
        Farms                   = [ordered]@{}
        FarmNames               = @()
        Servers                 = @()
        ServerFarmMap           = @{}
        CollectorTimeoutSeconds = 15
        CycleDelaySeconds       = 15
        MaxConcurrentJobs       = 6
        CollectorDebugMode      = $false
        CollectCpuRam           = $true
        CustomLoginDomain       = ''
    }
}

function Complete-ConfigObject {
    param([hashtable]$Config)

    if ($null -eq $Config) {
        throw 'Config object cannot be null.'
    }

    if (-not $Config.ContainsKey('Farms') -or $null -eq $Config.Farms) {
        $Config.Farms = [ordered]@{}
    }

    $normalizedFarms = [ordered]@{}
    $farmNames = @()
    $flatServers = @()
    $serverFarmMap = @{}

    foreach ($farmName in @($Config.Farms.Keys)) {
        $name = ([string]$farmName).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $servers = @(Get-NormalizedConfigServerList -Values $Config.Farms[$farmName])
        $normalizedFarms[$name] = $servers
        if ($farmNames -notcontains $name) {
            $farmNames += $name
        }

        foreach ($server in $servers) {
            $serverKey = $server.ToLowerInvariant()
            if ($serverFarmMap.ContainsKey($serverKey) -and $serverFarmMap[$serverKey] -ne $name) {
                throw "Server '$server' is configured in multiple farms: '$($serverFarmMap[$serverKey])' and '$name'."
            }

            $serverFarmMap[$serverKey] = $name
            if ($flatServers -notcontains $server) {
                $flatServers += $server
            }
        }
    }

    foreach ($farmName in $farmNames) {
        if (-not $normalizedFarms.Contains($farmName)) {
            $normalizedFarms[$farmName] = @()
        }
    }

    $Config.Farms = $normalizedFarms
    $Config.FarmNames = $farmNames
    $Config.Servers = $flatServers
    $Config.ServerFarmMap = $serverFarmMap
    return $Config
}

function Read-ConfigFile {
    param([string]$Path)
    
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found at $Path. Please create it with Title and farm settings."
    }
    
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $config = New-ConfigObject
    
    # Parse Title
    $titleMatch = [regex]::Match($content, '(?im)^\s*Title\s*=\s*["\u0027]?([^"\u0027\r\n]+)["\u0027]?\s*$')
    if ($titleMatch.Success) {
        $config.Title = $titleMatch.Groups[1].Value.Trim()
    }

    $farms = Read-TomlFarmMap -Content $content -SectionName 'Farms'
    if ($farms.Count -gt 0) {
        $config.Farms = $farms
    }
    else {
        $legacyServers = Read-TomlStringArray -Content $content -PropertyName 'Servers'
        if ($legacyServers.Count -gt 0) {
            $config.Farms[$script:LegacyDefaultFarmName] = $legacyServers
        }
    }

    $timeoutMatch = [regex]::Match($content, '(?im)^\s*CollectorTimeoutSeconds\s*=\s*(\d+)\s*$')
    if ($timeoutMatch.Success) {
        try {
            $config.CollectorTimeoutSeconds = [int]$timeoutMatch.Groups[1].Value
        }
        catch {}
    }

    $delayMatch = [regex]::Match($content, '(?im)^\s*CycleDelaySeconds\s*=\s*(\d+)\s*$')
    if ($delayMatch.Success) {
        try {
            $config.CycleDelaySeconds = [int]$delayMatch.Groups[1].Value
        }
        catch {}
    }

    $concurrencyMatch = [regex]::Match($content, '(?im)^\s*MaxConcurrentJobs\s*=\s*(\d+)\s*$')
    if ($concurrencyMatch.Success) {
        try {
            $config.MaxConcurrentJobs = [math]::Max(1, [int]$concurrencyMatch.Groups[1].Value)
        }
        catch {}
    }

    $debugMatch = [regex]::Match($content, '(?im)^\s*CollectorDebugMode\s*=\s*(true|false|1|0)\s*$')
    if ($debugMatch.Success) {
        $debugVal = $debugMatch.Groups[1].Value.ToLowerInvariant()
        $config.CollectorDebugMode = ($debugVal -eq 'true' -or $debugVal -eq '1')
    }

    $collectCpuRamMatch = [regex]::Match($content, '(?im)^\s*CollectCpuRam\s*=\s*(true|false|1|0)\s*$')
    if ($collectCpuRamMatch.Success) {
        $collectCpuRamVal = $collectCpuRamMatch.Groups[1].Value.ToLowerInvariant()
        $config.CollectCpuRam = ($collectCpuRamVal -eq 'true' -or $collectCpuRamVal -eq '1')
    }

    $customDomainMatch = [regex]::Match($content, '(?im)^\s*CustomLoginDomain\s*=\s*["\u0027]?([^"\u0027\r\n]+)["\u0027]?\s*$')
    if ($customDomainMatch.Success) {
        $config.CustomLoginDomain = $customDomainMatch.Groups[1].Value.Trim()
    }

    return (Complete-ConfigObject -Config $config)
}

function Write-ConfigFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Title,
        [hashtable]$Farms = $null,
        [string[]]$Servers = @(),
        [int]$CollectorTimeoutSeconds = 15,
        [int]$CycleDelaySeconds = 15,
        [int]$MaxConcurrentJobs = 6,
        [bool]$CollectCpuRam = $true
    )

    $config = New-ConfigObject
    $config.Title = $Title
    $config.CollectorTimeoutSeconds = $CollectorTimeoutSeconds
    $config.CycleDelaySeconds = $CycleDelaySeconds
    $config.MaxConcurrentJobs = [math]::Max(1, $MaxConcurrentJobs)
    $config.CollectCpuRam = $CollectCpuRam
    if ($null -ne $Farms -and $Farms.Count -gt 0) {
        $config.Farms = $Farms
    }
    elseif (@($Servers).Count -gt 0) {
        $config.Farms[$script:LegacyDefaultFarmName] = $Servers
    }


    $config = Complete-ConfigObject -Config $config
    $titleValue = if ([string]::IsNullOrWhiteSpace($Title)) { 'RDS Dashboard' } else { $Title.Trim() }

    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine('# RDS Dashboard Configuration')
    $null = $sb.AppendLine()
    $null = $sb.AppendLine(('Title = "{0}"' -f ($titleValue -replace '"', '\\"')))
    $null = $sb.AppendLine(('CollectorTimeoutSeconds = {0}' -f [math]::Max(1, $CollectorTimeoutSeconds)))
    $null = $sb.AppendLine(('CycleDelaySeconds = {0}' -f [math]::Max(1, $CycleDelaySeconds)))
    $null = $sb.AppendLine(('MaxConcurrentJobs = {0}' -f [math]::Max(1, $MaxConcurrentJobs)))
    $null = $sb.AppendLine(('CollectCpuRam = {0}' -f ($(if ($CollectCpuRam) { 'true' } else { 'false' }))))
    $null = $sb.AppendLine()

    $null = $sb.AppendLine('[Farms]')
    foreach ($farmName in @($config.FarmNames)) {
        $serversList = @($config.Farms[$farmName])
        $null = $sb.AppendLine(('"{0}" = [' -f ($farmName -replace '"', '\\"')))
        foreach ($srv in $serversList) {
            $null = $sb.AppendLine(('    "{0}",' -f ($srv -replace '"', '\\"')))
        }
        $null = $sb.AppendLine(']')
    }
    $null = $sb.AppendLine()


    $dir = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $tmp = ('{0}.{1}.tmp' -f $Path, ([guid]::NewGuid().ToString('N')))
    Set-Content -LiteralPath $tmp -Value $sb.ToString() -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# ---- SQL Value Escaping ----

function ConvertTo-SqliteLiteral {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return 'NULL'
    }

    if ($Value -is [string]) {
        return ("'{0}'" -f (($Value -replace "'", "''")))
    }

    if ($Value -is [bool]) {
        return $(if ($Value) { '1' } else { '0' })
    }

    if ($Value -is [ValueType]) {
        return ([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
    }

    return ("'{0}'" -f ((([string]$Value) -replace "'", "''")))
}

# ---- Logging ----

$script:LogFilePath = ''

function Initialize-Logging {
    param([string]$LogPath)
    $script:LogFilePath = ''
}

function Write-Log {
    param([string]$Message)
    
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$stamp] $Message"
    Write-Host $line
}

# Export all functions
Export-ModuleMember -Function Read-ConfigFile, Write-ConfigFile, ConvertTo-SqliteLiteral, Write-Log, Initialize-Logging
