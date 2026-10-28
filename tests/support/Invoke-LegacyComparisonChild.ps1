#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-F]{64}$')][string]$PlanSha256,
    [Parameter(Mandatory)][ValidateSet('Inspect', 'Collect', 'Report', 'Serve')][string]$Task,
    [Parameter(Mandatory)][ValidateSet('legacy', 'angular')][string]$Engine,
    [ValidateSet('Usage', 'Detailed')][string]$ReportType = 'Usage'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'LegacyComparison.Execution.ps1')
$PlanPath = Assert-ComparisonExecutionPath $PlanPath
if ((Get-ComparisonSha256 $PlanPath) -cne $PlanSha256) { throw 'Execution plan hash mismatch.' }
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json -DateKind String
[void](Assert-ComparisonExecutionPath $PlanPath $plan.outputRoot)
$configuration = @($plan.configurations | Where-Object engine -EQ $Engine)
if ($configuration.Count -ne 1 -or -not $plan.syntheticOnly) { throw 'Invalid synthetic comparison execution plan.' }
$configuration = $configuration[0]
$name = "$Engine-$Task" + $(if ($Task -eq 'Report') { "-$ReportType" })
$receipt = Join-Path $plan.outputRoot "$name.child.json"
if (Test-Path -LiteralPath $receipt) { throw 'Child receipts are never resumed or replaced by another run.' }
$result = [ordered]@{ status = 'RUNNING'; task = $Task; engine = $Engine; syntheticOnly = $true
    pid = $PID; processStartedUtc = [datetimeoffset]::UtcNow.ToString('o') }
Write-ComparisonExecutionJson $receipt $result
$store = $null
try {
    Assert-ComparisonExecutionInputs $plan
    [void](Assert-ComparisonExecutionPath $configuration.database $configuration.workRoot)
    if ($configuration.database -cne (Join-Path $configuration.workRoot 'ExchangeLogReport.sqlite')) { throw 'Unexpected database path.' }
    $root = if ($Engine -eq 'legacy') { Join-Path $plan.legacy.root 'package' } else { Join-Path $plan.angular.root 'collector' }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Import-Module (Join-Path $root 'ExchangeLogReport.psd1') -Force
    $settings = Import-ExlConfiguration -Path $configuration.path -Root $root
    $effective = Get-ComparisonEffectiveSettings $settings $plan
    if ($settings.Storage.DatabasePath -cne $configuration.database -or
        $settings.Report.OutputPath -cne (Join-Path $configuration.workRoot 'reports') -or
        $settings.Logging.Path -cne (Join-Path $configuration.workRoot 'execution-logs')) { throw 'Resolved output paths escaped synthetic work roots.' }
    $result['moduleImportMilliseconds'] = $watch.Elapsed.TotalMilliseconds
    $result['effective'] = $effective
    $result['engineTuning'] = Get-ComparisonEngineTuning $settings
    if ($Task -ne 'Inspect') {
        $watch.Restart()
        Initialize-ExlEngine -Root $root
        $result['engineInitializeMilliseconds'] = $watch.Elapsed.TotalMilliseconds
        if ($Task -eq 'Collect') {
            foreach ($suffix in @('', '-wal', '-shm', '.lock')) {
                if (Test-Path -LiteralPath ($configuration.database + $suffix)) { throw 'Collection requires a completely fresh independent database.' }
            }
            $phase = [Diagnostics.Stopwatch]::StartNew()
            $store = Open-ExlStore -Settings $settings
            $runId = $store.StartRun('Collect', 'SYNTHETIC', 'LOCAL-COMPARISON', [string]$plan.$Engine.moduleVersion)
            $collectWatch = [Diagnostics.Stopwatch]::StartNew()
            $collection = Invoke-ExlCollection -Store $store -Settings $settings -RunId $runId
            $collectWatch.Stop()
            if ($collection.Errors -or $collection.Unreachable.Count -or $collection.Stale.Count -or
                $collection.Files -le 0 -or $collection.Lines -le 0 -or $collection.Kept -le 0) {
                throw 'Synthetic collection was incomplete, empty or stale.'
            }
            $store.EndRun($runId, 'Completed', $collection.Files, $collection.Bytes, $collection.Lines,
                $collection.Kept, $collection.Noise, $null)
            $phase.Stop()
            $result['phaseWallMilliseconds'] = $phase.Elapsed.TotalMilliseconds
            $result['phaseWallBoundary'] = 'Open-ExlStore through EndRun; excludes module import/compile, post-collection diagnostics and disposal.'
            $result['collection'] = [ordered]@{}
            foreach ($key in @('Files', 'Bytes', 'Lines', 'Kept', 'Noise', 'Stored', 'Errors', 'Threads')) {
                $result.collection[$key] = $collection.$key
            }
            # Per-phase timing string of the engine ("... message rollups N s (K keys) ..." for Angular); absent or empty -> null.
            # Kept beside, not inside, 'collection': that object is compared across engines (identicalCollectionTotals) and timings differ.
            $statistics = if ($collection.PSObject.Properties['Statistics']) { [string]$collection.Statistics } else { '' }
            $result['collectionStatistics'] = if ($statistics) { $statistics } else { $null }
            $result['engineCollectionMilliseconds'] = [double]$collection.Seconds * 1000
            $result['invokeCollectionMilliseconds'] = $collectWatch.Elapsed.TotalMilliseconds
            $result['retention'] = 'No retention operation invoked; both effective retention cutoffs are 3650 days, fixture backfill 365 days.'
            $result['sourceCounts'] = @(Get-ComparisonQueryRows $store @'
SELECT server,kind,COUNT(*) AS files,SUM(size) AS bytes,SUM(offset) AS consumed_bytes,
MIN(first_ms) AS first_ms,MAX(last_ms) AS last_ms FROM source_file GROUP BY server,kind ORDER BY server,kind;
'@)
            $result['fixtureFileCount'] = @($plan.fixtureFiles).Count
            $result['fixtureBytes'] = [long](($plan.fixtureFiles | Measure-Object bytes -Sum).Sum)
            if (($result.sourceCounts | Measure-Object files -Sum).Sum -ne $result.fixtureFileCount -or
                ($result.sourceCounts | Measure-Object bytes -Sum).Sum -ne $result.fixtureBytes) {
                throw 'The database source-file inventory does not cover the exact generated fixture.'
            }
            $result['rowCounts'] = @(foreach ($table in @('access_event', 'message_event', 'smtp_transaction', 'client_session', 'session_step')) {
                $count = @(Get-ComparisonQueryRows $store "SELECT COUNT(*) AS rows FROM $table;")
                [pscustomobject]@{ table = $table; rows = $count[0].rows }
            })
            $result['schema'] = @(Get-ComparisonQueryRows $store "SELECT value FROM metadata WHERE key='schema_version';")
            $open = Get-ComparisonFootprint $configuration.database
            $disposeWatch = [Diagnostics.Stopwatch]::StartNew()
            $store.Dispose(); $store = $null
            $result['disposeMilliseconds'] = $disposeWatch.Elapsed.TotalMilliseconds
            $result['footprint'] = @{ open = $open; disposed = Get-ComparisonFootprint $configuration.database
                note = 'Actual allocated file lengths, not peak WAL, DBSTAT payload or representative production sizing.' }
            $result['databaseSha256'] = (Get-ComparisonSha256 $configuration.database)
        } else {
            $collectionReceipt = Join-Path $plan.outputRoot "$Engine-Collect.child.json"
            $collected = Get-Content -LiteralPath $collectionReceipt -Raw | ConvertFrom-Json -DateKind String
            if ($collected.status -ne 'PASS' -or -not $collected.syntheticOnly -or
                (Get-ComparisonSha256 $configuration.database) -cne $collected.databaseSha256) {
                throw 'Only the unchanged database collected by this exact synthetic run is accepted.'
            }
            $databaseHash = $collected.databaseSha256
            if ($Task -eq 'Report') {
                $period = Resolve-ExlPeriod -Range Custom -Start $plan.period.reportStart -End $plan.period.reportEndExclusive -Zone $settings.Zone
                if ($period.StartMs -ne ([datetimeoffset]$plan.period.reportStart).ToUnixTimeMilliseconds() -or
                    $period.EndMs -ne ([datetimeoffset]$plan.period.reportEndExclusive).ToUnixTimeMilliseconds()) { throw 'Report interval was clamped or changed.' }
                $store = Open-ExlStore -Settings $settings -ReadOnly
                $watch.Restart()
                $built = New-ExlReport -Store $store -Settings $settings -Period $period -ReportType $ReportType `
                    -IncludeRoutingDetails $true -IncludeSessionDetails $true
                $watch.Stop()
                $folder = Assert-ComparisonExecutionPath $built.Folder $settings.Report.OutputPath
                $result['generationMilliseconds'] = $watch.Elapsed.TotalMilliseconds
                $result['reportType'] = $ReportType; $result['period'] = $plan.period
                $result['folder'] = $folder
                $result['files'] = @(Get-ComparisonArtifactInventory $folder)
                $result['bytes'] = [long](($result.files | Measure-Object bytes -Sum).Sum)
                if (-not @($result.files | Where-Object path -Like '*.html').Count -or
                    -not @($result.files | Where-Object path -Like '*.csv').Count) { throw 'Static report is missing HTML or CSV output.' }
                $store.Dispose(); $store = $null
            } elseif ($Task -eq 'Serve') {
                if ($Engine -ne 'angular') { throw 'Only the Angular engine may start Serve.' }
                # Marks the end of the harness's own SHA-256 of the database, so the parent times Serve startup alone.
                [IO.File]::WriteAllText(($plan.readyFile -replace '\.ready\.json$', '.starting.json'), '{}')
                Start-ExlServe -DatabasePath $configuration.database -WebRoot $plan.webRoot -Port 0 -NoBrowser `
                    -ReadyFile $plan.readyFile -ReadyFileWithToken -DevelopmentMode:([bool]$plan.developmentMode)
            }
            if ((Get-ComparisonSha256 $configuration.database) -cne $databaseHash) {
                throw 'Read-only report/Serve changed the synthetic database bytes.'
            }
            $result['databaseUnchanged'] = $true
            $result['databaseFootprintAfterRead'] = Get-ComparisonFootprint $configuration.database
        }
    }
    Assert-ComparisonExecutionInputs $plan
    $result['status'] = 'PASS'
} catch {
    $result['status'] = 'BLOCKED'; $result['error'] = $_.Exception.Message
    Write-ComparisonExecutionJson $receipt $result
    throw
} finally {
    if ($store) {
        $result['partialFootprintOpen'] = Get-ComparisonFootprint $configuration.database
        $store.Dispose()
        $result['partialFootprintDisposed'] = Get-ComparisonFootprint $configuration.database
    }
    Write-ComparisonExecutionJson $receipt $result
}
