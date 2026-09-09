# =============================================================================
# job-pool.psm1
# Reusable job pool manager for RDS Dashboard collector
# Prevents job spawn overhead and enforces timeout discipline
# =============================================================================

# ---- Job Pool Executor ----
# Executes a collection of job scripts with enforced timeout and result collection

function Invoke-JobPool {
    param(
        [Parameter(Mandatory = $true)][int]$MaxConcurrentJobs,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][ScriptBlock]$JobScript,
        [Parameter(Mandatory = $true)][object[]]$InputObjects,
        [string]$JobPrefix = 'Job',
        [object[]]$ArgumentList = @()
    )

    if ($InputObjects.Count -eq 0) {
        return @()
    }

    if ($MaxConcurrentJobs -lt 1) {
        $MaxConcurrentJobs = 1
    }

    $workItems = [System.Collections.Generic.List[object]]::new()
    $results = [System.Collections.Generic.List[object]]::new()
    $failedCount = 0
    $timedOutCount = 0
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $runspacePool = $null

    try {
        $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxConcurrentJobs, $initialState, $Host)
        $runspacePool.Open()

        for ($i = 0; $i -lt $InputObjects.Count; $i++) {
            try {
                $ps = [System.Management.Automation.PowerShell]::Create()
                $ps.RunspacePool = $runspacePool

                $jobArgs = @($InputObjects[$i]) + @($ArgumentList)
                $null = $ps.AddScript($JobScript.ToString())
                foreach ($arg in $jobArgs) {
                    $null = $ps.AddArgument($arg)
                }
                $asyncHandle = $ps.BeginInvoke()

                $workItems.Add([PSCustomObject]@{
                        Index = $i
                        Name = "$JobPrefix-$i"
                        PowerShell = $ps
                        Handle = $asyncHandle
                        Completed = $false
                    }) | Out-Null
            }
            catch {
                $failedCount++
            }
        }

        $pendingItems = [System.Collections.Generic.List[object]]::new()
        foreach ($wi in $workItems) {
            $pendingItems.Add($wi) | Out-Null
        }

        # Harvest completed work fairly across all pending items until global deadline.
        while ($pendingItems.Count -gt 0) {
            $remainingMs = [int][math]::Max(0, (($TimeoutSeconds - $stopwatch.Elapsed.TotalSeconds) * 1000))
            if ($remainingMs -le 0) {
                break
            }

            $completedIndex = -1
            for ($j = 0; $j -lt $pendingItems.Count; $j++) {
                if ($pendingItems[$j].Handle.IsCompleted) {
                    $completedIndex = $j
                    break
                }
            }

            if ($completedIndex -ge 0) {
                $item = $pendingItems[$completedIndex]
                try {
                    $result = $item.PowerShell.EndInvoke($item.Handle)
                    foreach ($obj in @($result)) {
                        if ($null -ne $obj) {
                            $results.Add($obj) | Out-Null
                        }
                    }
                    $item.Completed = $true
                }
                catch {
                    $failedCount++
                }
                finally {
                    $pendingItems.RemoveAt($completedIndex)
                }
                continue
            }

            # No completed item yet: sleep briefly and continue polling until deadline.
            Start-Sleep -Milliseconds ([math]::Min(100, [math]::Max(10, $remainingMs)))
        }

        # Global deadline reached: stop remaining items and mark as timed out.
        foreach ($item in $pendingItems) {
            $timedOutCount++
            try { $item.PowerShell.Stop() } catch {}
        }
    }
    finally {
        foreach ($item in $workItems) {
            try { $item.PowerShell.Dispose() } catch {}
            try { $item.Handle.AsyncWaitHandle.Dispose() } catch {}
        }
        if ($null -ne $runspacePool) {
            try { $runspacePool.Close() } catch {}
            try { $runspacePool.Dispose() } catch {}
        }
    }

    $stopwatch.Stop()

    # Return results with metadata
    $inputCount = @($InputObjects).Count
    $startedCount = $workItems.Count
    return [PSCustomObject]@{
        Results = $results
        InputCount = $inputCount
        StartedCount = $startedCount
        TotalJobs = $workItems.Count
        CompletedCount = $results.Count
        TimedOutCount = $timedOutCount
        FailedCount = $failedCount
        ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    }
}

# ---- Cycle Time Monitor ----
# Tracks collection cycle times to detect bottlenecks

$script:CycleMetrics = @{
    MinSeconds = [double]::MaxValue
    MaxSeconds = 0.0
    TotalSeconds = 0.0
    CycleCount = 0
    RecentDurations = @()
    SlowCycles = @()  # Cycles > threshold
    SlowCycleThreshold = 10  # seconds
}

function Get-PercentileValue {
    param(
        [double[]]$Values,
        [double]$Percentile
    )

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return 0.0
    }

    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) {
        return [math]::Round([double]$sorted[0], 2)
    }

    $rank = ($Percentile / 100.0) * ($sorted.Count - 1)
    $lowerIndex = [int][math]::Floor($rank)
    $upperIndex = [int][math]::Ceiling($rank)
    if ($lowerIndex -eq $upperIndex) {
        return [math]::Round([double]$sorted[$lowerIndex], 2)
    }

    $weight = $rank - $lowerIndex
    $value = ([double]$sorted[$lowerIndex] * (1.0 - $weight)) + ([double]$sorted[$upperIndex] * $weight)
    return [math]::Round($value, 2)
}

function Add-CycleTimeRecord {
    param(
        [Parameter(Mandatory = $true)][double]$DurationSeconds,
        [int]$TimeoutCount = 0,
        [string]$Summary = ''
    )

    $script:CycleMetrics.MinSeconds = [math]::Min($script:CycleMetrics.MinSeconds, $DurationSeconds)
    $script:CycleMetrics.MaxSeconds = [math]::Max($script:CycleMetrics.MaxSeconds, $DurationSeconds)
    $script:CycleMetrics.TotalSeconds += $DurationSeconds
    $script:CycleMetrics.CycleCount++
    $script:CycleMetrics.RecentDurations += [double]$DurationSeconds

    # Keep recent window bounded for lightweight percentile calculations.
    if ($script:CycleMetrics.RecentDurations.Count -gt 300) {
        $script:CycleMetrics.RecentDurations = @($script:CycleMetrics.RecentDurations | Select-Object -Last 300)
    }

    if ($DurationSeconds -gt $script:CycleMetrics.SlowCycleThreshold) {
        $script:CycleMetrics.SlowCycles += [PSCustomObject]@{
            TimeUtc = (Get-Date).ToUniversalTime()
            DurationSeconds = $DurationSeconds
            TimeoutCount = $TimeoutCount
            Summary = $Summary
        }
    }

    # Keep only last 100 slow cycles
    if ($script:CycleMetrics.SlowCycles.Count -gt 100) {
        $script:CycleMetrics.SlowCycles = @($script:CycleMetrics.SlowCycles | Select-Object -Last 100)
    }
}

function Get-CycleMetrics {
    $avgSeconds = if ($script:CycleMetrics.CycleCount -gt 0) {
        [math]::Round(($script:CycleMetrics.TotalSeconds / $script:CycleMetrics.CycleCount), 2)
    }
    else {
        0.0
    }

    return [PSCustomObject]@{
        CycleCount = $script:CycleMetrics.CycleCount
        MinSeconds = if ($script:CycleMetrics.MinSeconds -eq [double]::MaxValue) { 0.0 } else { [math]::Round($script:CycleMetrics.MinSeconds, 2) }
        MaxSeconds = [math]::Round($script:CycleMetrics.MaxSeconds, 2)
        AvgSeconds = $avgSeconds
        P50Seconds = (Get-PercentileValue -Values @($script:CycleMetrics.RecentDurations) -Percentile 50)
        P95Seconds = (Get-PercentileValue -Values @($script:CycleMetrics.RecentDurations) -Percentile 95)
        RecentWindowCount = @($script:CycleMetrics.RecentDurations).Count
        SlowCycleCount = $script:CycleMetrics.SlowCycles.Count
        SlowCycleThreshold = $script:CycleMetrics.SlowCycleThreshold
    }
}

# Export all functions
Export-ModuleMember -Function Invoke-JobPool, Add-CycleTimeRecord, Get-CycleMetrics
