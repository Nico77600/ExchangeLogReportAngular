#Requires -Version 7.4
# Shared by the comparison coordinator and its isolated, single-engine children.
function Get-ComparisonSha256 {
    param([string]$Path)
    # 1 MiB sequential reads: the default 4 KiB buffer is latency-bound (~30 MB/s) on cloud disks across 100+ GB fixtures.
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, 1MB, [IO.FileOptions]::SequentialScan)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
    finally { $stream.Dispose() }
}

function Get-ComparisonSafeFiles {
    param([string]$Root, [switch]$MutableOutputSample)
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($Root)
    while ($pending.Count) {
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($pending.Dequeue())) {
            $length = 0L
            if ($MutableOutputSample) {
                try {
                    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
                    $attributes = $item.Attributes
                    # .NET reports -1 (every flag, ReparsePoint included) for an entry deleted after Get-Item resolved it.
                    if ([int]$attributes -eq -1) { throw [IO.FileNotFoundException]::new('Entry vanished while sampled.', $path) }
                    if (-not ($attributes -band [IO.FileAttributes]::Directory)) { $length = $item.Length }
                } catch {
                    # A sidecar removed by SQLite during Dispose, or a report row spill file (.report-<guid>.tmp)
                    # deleted by the engine, surfaces as ItemNotFound/FileNotFound, or as a
                    # MethodInvocationException/GetValueInvocationException wrapping one: inspect the whole chain.
                    $vanished = $false
                    for ($e = $_.Exception; $e; $e = $e.InnerException) {
                        if ($e -is [Management.Automation.ItemNotFoundException] -or $e -is [IO.FileNotFoundException] -or
                            $e -is [IO.DirectoryNotFoundException]) { $vanished = $true; break }
                    }
                    if (-not $vanished -or [IO.Path]::GetFileName($path) -notmatch '(\.sqlite-(wal|shm)|^\.report-[0-9a-f]{32}\.tmp)$') { throw }
                    [pscustomobject]@{ path = $path; bytes = $null; vanishedSidecar = $true }
                    continue
                }
            } else { $attributes = [IO.File]::GetAttributes($path) }
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $path" }
            if ($attributes -band [IO.FileAttributes]::Directory) { $pending.Enqueue($path) }
            elseif ($MutableOutputSample) { [pscustomobject]@{ path = $path; bytes = $length; vanishedSidecar = $false } }
            else { $path }
        }
    }
}

function Assert-ComparisonExecutionPath {
    param([string]$Path, [string]$Within)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':') -or
        $Path -match '(^|\\)\.{1,2}(\\|$)|[. ](\\|$)|[\x00-\x1f*?/]' -or
        [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path)).DriveType -ne 'Fixed') {
        throw "Unsafe comparison path: $Path"
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -le 2) { throw 'A drive root is not accepted.' }
    if ($Within -and -not $full.StartsWith($Within.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Comparison path escapes its designated root: $Path"
    }
    $cursor = $full
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and
            ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point in comparison path: $cursor"
        }
        $cursor = Split-Path $cursor -Parent
    }
    return $full
}

function Write-ComparisonExecutionJson {
    param([string]$Path, $Value)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 24), [Text.UTF8Encoding]::new($false))
}

function Assert-ComparisonFrozenInventory {
    param([string]$Root, [object[]]$Inventory, [string[]]$Subtrees, [switch]$ReadOnly)
    if (-not $Inventory.Count) { throw 'An empty frozen input inventory is not accepted.' }
    [void](Assert-ComparisonExecutionPath $Root)
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $parents = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $Inventory) {
        if ([IO.Path]::IsPathRooted($file.path) -or $file.path -match '(^|\\)\.{1,2}(\\|$)|[:/]') { throw 'Invalid relative frozen path.' }
        $path = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $file.path))
        if (-not $path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Frozen path escaped its root.' }
        $parent = [IO.Path]::GetDirectoryName($path)
        if ($parents.Add($parent)) { [void](Assert-ComparisonExecutionPath $parent) }
        if (-not $expected.Add($path)) { throw 'Duplicate frozen input path.' }
        $item = [IO.FileInfo]::new($path)
        if (-not $item.Exists -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne $file.bytes -or
            ($ReadOnly -and -not $item.IsReadOnly) -or
            (Get-ComparisonSha256 $path) -cne $file.sha256) {
            throw "Frozen input changed; never update an earlier receipt to heal drift: $path"
        }
        if ($ReadOnly -and $item.LastWriteTimeUtc.ToString('o') -cne $file.lastWriteTimeUtc) {
            throw "Frozen fixture timestamp changed: $path"
        }
    }
    foreach ($subtree in $Subtrees) {
        $path = if ($subtree -eq '.') { $Root } else { Join-Path $Root $subtree }
        foreach ($file in Get-ComparisonSafeFiles $path) {
            if (-not $expected.Contains($file)) {
                throw "Uninventoried input appeared: $file"
            }
        }
    }
}

function Assert-ComparisonExecutionInputs {
    param($Plan)
    if ($Plan.PSObject.Properties['planSha256'] -and (Get-ComparisonSha256 $Plan.planPath) -cne $Plan.planSha256) {
        throw 'The immutable execution plan changed.'
    }
    $head = & git --no-optional-locks -C $Plan.legacy.root rev-parse HEAD
    if ($LASTEXITCODE -or $head -ne $Plan.legacy.head) { throw 'Public legacy HEAD changed.' }
    $cached = & git --no-optional-locks -C $Plan.legacy.root rev-parse refs/remotes/origin/main
    if ($LASTEXITCODE -or $cached -ne $Plan.legacy.head) { throw 'Public cached origin/main changed.' }
    $dirty = & git --no-optional-locks -C $Plan.legacy.root status --porcelain=v1 --untracked-files=all
    if ($LASTEXITCODE -or $dirty) { throw 'Public legacy source is dirty.' }
    Assert-ComparisonFrozenInventory $Plan.legacy.root @($Plan.sourceInventories.legacy) @('package\src', 'package\templates', 'package\lib')
    Assert-ComparisonFrozenInventory $Plan.angular.root @($Plan.sourceInventories.angular) @('collector\src', 'collector\templates', 'collector\lib')
    Assert-ComparisonFrozenInventory $Plan.logs @($Plan.fixtureFiles) @('.') -ReadOnly
    Assert-ComparisonFrozenInventory $Plan.webRoot @($Plan.webInventory) @('.')
    foreach ($configuration in $Plan.configurations) {
        [void](Assert-ComparisonExecutionPath $configuration.path $Plan.outputRoot)
        if ((Get-ComparisonSha256 $configuration.path) -cne $configuration.sha256) {
            throw 'A frozen synthetic configuration changed.'
        }
        if (Test-Path -LiteralPath (Join-Path $configuration.workRoot 'ExchangeLogReport.paths.psd1')) {
            throw 'Discovery sidecar files are forbidden in a synthetic comparison.'
        }
    }
}

function Get-ComparisonFootprint {
    param([string]$Database)
    $result = [ordered]@{}
    foreach ($part in @(@('database', ''), @('wal', '-wal'), @('shm', '-shm'))) {
        $path = $Database + $part[1]
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        $result[$part[0]] = [pscustomobject]@{ exists = $exists; bytes = if ($exists) { (Get-Item -LiteralPath $path).Length } else { 0L } }
    }
    return [pscustomobject]$result
}

function Assert-ComparisonResourceReserve {
    param([string]$Path, [long]$MinimumFreeDiskBytes, [long]$MinimumFreeMemoryBytes)
    $free = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($Path)).AvailableFreeSpace
    if ($free -lt $MinimumFreeDiskBytes) { throw 'Comparison stopped before exhausting its free-disk reserve.' }
    if ($MinimumFreeMemoryBytes) {
        $memory = [long](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory * 1024
        if ($memory -lt $MinimumFreeMemoryBytes) { throw 'Comparison stopped before exhausting its available-memory reserve.' }
    }
}

function Get-ComparisonArtifactInventory {
    param([string]$Root)
    [void](Assert-ComparisonExecutionPath $Root)
    foreach ($path in Get-ComparisonSafeFiles $Root | Sort-Object) {
        [pscustomobject]@{ path = [IO.Path]::GetRelativePath($Root, $path); bytes = [IO.FileInfo]::new($path).Length
            sha256 = Get-ComparisonSha256 $path }
    }
}

function Get-ComparisonExpectedSources {
    param([string]$Logs, [string[]]$Servers)
    foreach ($server in $Servers) {
        foreach ($entry in @(
                @('HttpProxy', '', 'Exchange\Logging\HttpProxy', '*.log', $true, $false),
                @('Iis', '', 'inetpub\logs\LogFiles\W3SVC1', '*.log', $false, $false),
                @('MapiBackEnd', '', 'Exchange\Logging\MapiHttp\Mailbox', '*.log', $false, $true),
                @('EasBackEnd', '', 'inetpub\logs\LogFiles\W3SVC2', '*.log', $false, $false),
                @('SmtpReceive', 'FrontEnd', 'Exchange\TransportRoles\Logs\FrontEnd\ProtocolLog\SmtpReceive', '*.log', $true, $true),
                @('SmtpSend', 'FrontEnd', 'Exchange\TransportRoles\Logs\FrontEnd\ProtocolLog\SmtpSend', '*.log', $true, $true),
                @('Tracking', '', 'Exchange\TransportRoles\Logs\MessageTracking', 'MSGTRK*.log', $false, $false))) {
            [pscustomobject][ordered]@{ server = $server; kind = $entry[0]; role = $entry[1]
                folder = Join-Path $Logs "$server\$($entry[2])"; filter = $entry[3]; recurse = $entry[4]; optional = $entry[5] }
        }
    }
}

$script:ComparisonEngineTuningKeys = @('DeferRollups')

function Get-ComparisonEngineTuning {
    param($Settings)
    $tuning = [ordered]@{}
    foreach ($key in $script:ComparisonEngineTuningKeys) {
        if ($Settings.Collection.Contains($key)) { $tuning[$key] = $Settings.Collection[$key] }
    }
    return $tuning
}

function Get-ComparisonEffectiveSettings {
    param($Settings, $Plan)
    $jobs = @(foreach ($server in $Settings.Servers) {
        foreach ($source in Get-ExlSources -Server $server -Settings $Settings) {
            $folder = Assert-ComparisonExecutionPath $source.Folder $Plan.logs
            [pscustomobject][ordered]@{ server = $server.Name; kind = $source.Kind; role = [string]$source.Role
                folder = $folder; filter = $source.Filter; recurse = [bool]$source.Recurse; optional = [bool]$source.Optional }
        }
    })
    $jobs = @($jobs | Sort-Object server, kind, role)
    $expected = @(Get-ComparisonExpectedSources $Plan.logs @($Plan.servers) | Sort-Object server, kind, role)
    if (($jobs | ConvertTo-Json -Depth 6 -Compress) -cne ($expected | ConvertTo-Json -Depth 6 -Compress)) {
        throw 'Resolved collector sources differ from the exact seven synthetic source jobs per server.'
    }
    foreach ($job in $jobs) {
        if (-not (Test-Path -LiteralPath $job.folder -PathType Container)) { throw "Expected fixture folder missing: $($job.folder)" }
    }
    if ($Settings.Mail.Enabled -or $Settings.Mail.SmtpServer -or $Settings.Discovery -or
        $Settings.Collection.StaleSourceHours -ne 0 -or $Settings.Collection.Parallelism -ne 1 -or
        $Settings.Report.TimeZone -ne 'UTC' -or $Settings.Storage.RetentionDays -ne 3650 -or
        $Settings.Storage.DetailRetentionDays -ne 3650) { throw 'Unsafe or mismatched synthetic effective settings.' }
    # Engine-only tuning keys change how rows are written, not which rows: recorded apart (engineTuning), never compared.
    $collection = [ordered]@{}
    foreach ($key in $Settings.Collection.Keys | Sort-Object) {
        if ($key -notin $script:ComparisonEngineTuningKeys) { $collection[$key] = $Settings.Collection[$key] }
    }
    $effective = [ordered]@{
        sourceJobs = $jobs
        sources = $Settings.Sources
        noise = $Settings.Noise
        collection = $collection
        storage = [ordered]@{ RetentionDays = $Settings.Storage.RetentionDays; DetailRetentionDays = $Settings.Storage.DetailRetentionDays }
        report = [ordered]@{}
    }
    foreach ($key in $Settings.Report.Keys | Sort-Object) {
        if ($key -notin @('OutputPath', 'TemplatePath')) { $effective.report[$key] = $Settings.Report[$key] }
    }
    return $effective
}

function Get-ComparisonQueryRows {
    param($Store, [string]$Sql)
    $table = $Store.Query($Sql, $null)
    foreach ($row in $table.Rows) {
        $value = [ordered]@{}
        for ($i = 0; $i -lt $table.Columns.Count; $i++) {
            $cell = $row[$i]
            $value[$table.Columns[$i]] = if ($cell -is [DBNull]) { $null } else { $cell }
        }
        [pscustomobject]$value
    }
}

function Start-ComparisonBoundedChild {
    param($Plan, [string]$Task, [string]$Engine, [string]$ReportType)
    $name = "$Engine-$Task" + $(if ($ReportType) { "-$ReportType" })
    $info = [Diagnostics.ProcessStartInfo]::new($Plan.pwsh)
    $info.WorkingDirectory = $Plan.outputRoot; $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $scratch = Join-Path $Plan.outputRoot "$name-scratch"
    [void][IO.Directory]::CreateDirectory($scratch)
    $info.Environment['TMP'] = $scratch; $info.Environment['TEMP'] = $scratch
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Plan.childScript,
            '-PlanPath', $Plan.planPath, '-PlanSha256', $Plan.planSha256,
            '-Task', $Task, '-Engine', $Engine)) { $info.ArgumentList.Add($argument) }
    if ($ReportType) { $info.ArgumentList.Add('-ReportType'); $info.ArgumentList.Add($ReportType) }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($info)
    [pscustomobject]@{ process = $process; clock = $watch; name = $name
        maximumObservedWorkingSetBytes = 0L
        vanishedOutputSidecarSamples = 0L
        stdout = $process.StandardOutput.ReadToEndAsync(); stderr = $process.StandardError.ReadToEndAsync() }
}

function Assert-ComparisonChildBounds {
    param($Child, $Plan)
    $Child.process.Refresh()
    if (-not $Child.process.HasExited) {
        $Child.maximumObservedWorkingSetBytes = [Math]::Max($Child.maximumObservedWorkingSetBytes, $Child.process.WorkingSet64)
    }
    if ($Child.clock.Elapsed.TotalSeconds -gt $Plan.timeoutSeconds) { throw "Child timed out: $($Child.name)" }
    if (-not $Child.process.HasExited -and $Child.process.WorkingSet64 -gt $Plan.maximumWorkingSetMB * 1MB) {
        throw "Child exceeded its sampled working-set limit: $($Child.name)"
    }
    if (-not $Child.PSObject.Properties['lastSizeCheck'] -or $Child.clock.Elapsed.TotalSeconds - $Child.lastSizeCheck -ge 2) {
        Assert-ComparisonResourceReserve $Plan.outputRoot $Plan.minimumFreeDiskBytes $Plan.minimumFreeMemoryBytes
        $bytes = 0L
        foreach ($sample in Get-ComparisonSafeFiles $Plan.outputRoot -MutableOutputSample) {
            if ($sample.vanishedSidecar) { $Child.vanishedOutputSidecarSamples++ }
            else { $bytes += $sample.bytes }
        }
        if ($bytes -gt $Plan.maximumOutputBytes) { throw "Child run exceeded its output-size budget: $($Child.name)" }
        $Child | Add-Member -NotePropertyName lastSizeCheck -NotePropertyValue $Child.clock.Elapsed.TotalSeconds -Force
    }
}

function Close-ComparisonBoundedChild {
    param($Child, $Plan)
    try {
        if (-not $Child.process.HasExited) { $Child.process.Kill($true); $Child.process.WaitForExit() }
        [IO.File]::WriteAllText((Join-Path $Plan.outputRoot "$($Child.name).stdout.txt"), $Child.stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText((Join-Path $Plan.outputRoot "$($Child.name).stderr.txt"), $Child.stderr.GetAwaiter().GetResult())
    } finally { $Child.process.Dispose() }
}

function Invoke-ComparisonBoundedChild {
    param($Plan, [string]$Task, [string]$Engine, [string]$ReportType)
    $child = Start-ComparisonBoundedChild $Plan $Task $Engine $ReportType
    try {
        while (-not $child.process.WaitForExit(250)) { Assert-ComparisonChildBounds $child $Plan }
        $path = Join-Path $Plan.outputRoot "$($child.name).child.json"
        if (-not (Test-Path -LiteralPath $path)) { throw "Child produced no receipt: $($child.name), exit $($child.process.ExitCode)" }
        $result = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -DateKind String
        if ($child.process.ExitCode -or $result.status -ne 'PASS') { throw "Child failed: $($child.name); inspect $path" }
        $result | Add-Member -NotePropertyName processWallMilliseconds -NotePropertyValue $child.clock.Elapsed.TotalMilliseconds
        $result | Add-Member -NotePropertyName sampledMaximumWorkingSetBytes -NotePropertyValue $child.maximumObservedWorkingSetBytes
        $result | Add-Member -NotePropertyName vanishedOutputSidecarSamples -NotePropertyValue $child.vanishedOutputSidecarSamples
        return $result
    } finally { Close-ComparisonBoundedChild $child $Plan }
}

function Invoke-ComparisonHttp {
    param($Client, [string]$Path, [switch]$Shutdown)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = if ($Shutdown) {
        $Client.PostAsync($Path, [Net.Http.HttpContent]$null).GetAwaiter().GetResult()
    } else { $Client.GetAsync($Path).GetAwaiter().GetResult() }
    try {
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $watch.Stop()
        if ((-not $Shutdown -and [int]$response.StatusCode -ne 200) -or
            ($Shutdown -and -not $response.IsSuccessStatusCode)) {
            throw "Local API returned HTTP $([int]$response.StatusCode): $Path; $([Text.Encoding]::UTF8.GetString($bytes))"
        }
        [pscustomobject]@{ milliseconds = $watch.Elapsed.TotalMilliseconds; bytes = $bytes.Length
            body = [Text.Encoding]::UTF8.GetString($bytes) }
    } finally { $response.Dispose() }
}

function Invoke-ComparisonServeMeasurement {
    param($Plan)
    $child = Start-ComparisonBoundedChild $Plan 'Serve' 'angular'
    $client = $null; $handler = $null
    $resultPath = Join-Path $Plan.outputRoot 'angular-Serve.http.json'
    $result = [ordered]@{ status = 'RUNNING'; executionLabel = 'FunctionalConcurrent'; exclusiveTimingWindow = $false
        osCacheCold = $false; browserReadiness = 'PENDING'; cases = @() }
    Write-ComparisonExecutionJson $resultPath $result
    try {
        # The child hashes the whole database before starting Serve; that check is excluded from the startup time.
        $startingFile = $Plan.readyFile -replace '\.ready\.json$', '.starting.json'
        $serveStartedAt = $null
        while (-not (Test-Path -LiteralPath $Plan.readyFile)) {
            if ($null -eq $serveStartedAt -and (Test-Path -LiteralPath $startingFile)) { $serveStartedAt = $child.clock.Elapsed }
            Assert-ComparisonChildBounds $child $Plan
            if ($child.process.HasExited) { throw 'Serve child exited before readiness.' }
            Start-Sleep -Milliseconds 50
        }
        # Serve may become ready within one bounds-check iteration, so the marker is first seen only after the ready file.
        if ($null -eq $serveStartedAt -and (Test-Path -LiteralPath $startingFile)) {
            $serveStartedAt = $child.clock.Elapsed - ([datetime]::UtcNow - (Get-Item -LiteralPath $startingFile).LastWriteTimeUtc)
        }
        if ($null -eq $serveStartedAt) { $serveStartedAt = [timespan]::Zero }
        $result['childToReadyMilliseconds'] = $child.clock.Elapsed.TotalMilliseconds
        $result['preServeCheckMilliseconds'] = $serveStartedAt.TotalMilliseconds
        $ready = Get-Content -LiteralPath $Plan.readyFile -Raw | ConvertFrom-Json
        $origin = [uri]$ready.url
        if ($ready.status -ne 'ready' -or -not $ready.token -or $origin.Scheme -ne 'http' -or
            $origin.Host -cne '127.0.0.1' -or $origin.AbsolutePath -ne '/' -or $origin.UserInfo -or
            $origin.Query -or $origin.Fragment) { throw 'Serve did not produce an authenticated exact loopback readiness record.' }
        $result['startupMilliseconds'] = ($child.clock.Elapsed - $serveStartedAt).TotalMilliseconds
        $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false; $handler.UseProxy = $false
        $client = [Net.Http.HttpClient]::new($handler)
        $client.BaseAddress = $origin; $client.Timeout = [timespan]::FromSeconds(30)
        [void]$client.DefaultRequestHeaders.Add('X-Portal-Token', [string]$ready.token)
        $query = '?from=' + [uri]::EscapeDataString($Plan.period.reportStart) +
            '&to=' + [uri]::EscapeDataString($Plan.period.reportEndExclusive) + '&size=100&page=1'
        foreach ($view in @('messages', 'sessions', 'smtp/clients')) {
            $samples = @()
            for ($i = 0; $i -lt $Plan.httpIterations; $i++) {
                Assert-ComparisonChildBounds $child $Plan
                $sample = Invoke-ComparisonHttp $client ("/api/$view" + $query)
                $page = $sample.body | ConvertFrom-Json -DateKind String
                if (-not $page.PSObject.Properties['rows'] -or @($page.rows).Count -eq 0) {
                    throw "A synthetic list returned no rows or an unexpected contract: $view"
                }
                $rowsJson = $page.rows | ConvertTo-Json -Depth 20 -Compress
                $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($rowsJson)))
                $samples += [pscustomobject]@{ ordinal = $i + 1; milliseconds = $sample.milliseconds
                    bytes = $sample.bytes; rows = @($page.rows).Count; rowsSha256 = $hash }
            }
            $warm = @($samples | Select-Object -Skip 1 | ForEach-Object milliseconds | Sort-Object)
            $case = [pscustomobject]@{ view = $view; from = $Plan.period.reportStart; to = $Plan.period.reportEndExclusive
                firstMilliseconds = $samples[0].milliseconds; warmP95Milliseconds = $warm[[int][Math]::Ceiling($warm.Count * 0.95) - 1]
                samples = $samples; stableRows = @($samples.rowsSha256 | Sort-Object -Unique).Count -eq 1 }
            $result.cases += $case
            Write-ComparisonExecutionJson $resultPath $result
            if (-not $case.stableRows) { throw "Repeated immutable-fixture list rows changed: $view" }
        }
        $result['status'] = 'PASS'
    } catch {
        $result['status'] = 'BLOCKED'; $result['error'] = $_.Exception.Message
        throw
    } finally {
        if ($client -and -not $child.process.HasExited) {
            try {
                $null = Invoke-ComparisonHttp $client '/api/shutdown' -Shutdown
                while (-not $child.process.WaitForExit(250)) { Assert-ComparisonChildBounds $child $Plan }
            } catch {
                $result['shutdownNote'] = $_.Exception.Message
                $result['status'] = 'BLOCKED'
            }
        }
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
        Close-ComparisonBoundedChild $child $Plan
        Write-ComparisonExecutionJson $resultPath $result
    }
    if ($result.status -ne 'PASS') { throw 'Serve measurement/shutdown did not complete cleanly; see its partial receipt.' }
    $completion = Join-Path $Plan.outputRoot 'angular-Serve.child.json'
    if (-not (Test-Path -LiteralPath $completion) -or
        (Get-Content -LiteralPath $completion -Raw | ConvertFrom-Json -DateKind String).status -ne 'PASS') {
        $result['status'] = 'BLOCKED'; $result['error'] = 'Serve child did not verify its inputs/database and complete after shutdown.'
        Write-ComparisonExecutionJson $resultPath $result
        throw $result.error
    }
    return [pscustomobject]$result
}

function Set-ComparisonMeasuredRow {
    param($Record, [string]$Metric, $Measurement, [string]$Status = 'PASS')
    $row = @($Record.measurements | Where-Object metric -EQ $Metric)
    if ($row.Count -ne 1) { throw "Unknown comparison metric: $Metric" }
    $row[0].status = $Status; $row[0].measurement = $Measurement
}

function Invoke-ComparisonExecution {
    param($Plan, $Record, [string]$Receipt)
    $Record['preparationOnly'] = $false; $Record['executionStatus'] = 'RUNNING'
    $Record['executionLabel'] = 'FunctionalConcurrent'
    $Record['exclusiveTimingWindow'] = $false
    $Record['executionLimits'] = @{ timeoutSecondsPerChild = $Plan.timeoutSeconds; sampledMaximumWorkingSetMB = $Plan.maximumWorkingSetMB
        note = 'Polling bounds, not an OS-enforced hard memory limit; no exclusive timing or cold-cache claim.' }
    Write-ComparisonJson $Receipt $Record
    try {
        $preflights = @{}
        foreach ($engine in @('legacy', 'angular')) {
            Write-Host "Inspecting $engine effective configuration and frozen sources."
            Assert-ComparisonExecutionInputs $Plan
            $preflights[$engine] = Invoke-ComparisonBoundedChild $Plan 'Inspect' $engine
            Assert-ComparisonExecutionInputs $Plan
        }
        $Record['effectiveConfigurations'] = $preflights
        if (($preflights.legacy.effective | ConvertTo-Json -Depth 24 -Compress) -cne
            ($preflights.angular.effective | ConvertTo-Json -Depth 24 -Compress)) {
            throw 'Effective settings/source jobs differ across versions; preflight receipts preserved, collection refused.'
        }
        $collections = @{}
        foreach ($engine in @('legacy', 'angular')) {
            Write-Host "Collecting $engine into a fresh independent SQLite database."
            Assert-ComparisonExecutionInputs $Plan
            $collections[$engine] = Invoke-ComparisonBoundedChild $Plan 'Collect' $engine
            Assert-ComparisonExecutionInputs $Plan
            Set-ComparisonMeasuredRow $Record "$engine.collection" $collections[$engine]
            Set-ComparisonMeasuredRow $Record "$engine.database" $collections[$engine].footprint
            Write-ComparisonJson $Receipt $Record
            Write-Host "$engine collected: $($collections[$engine].footprint.disposed.database.bytes) database bytes; $([Math]::Round($collections[$engine].engineCollectionMilliseconds/1000,2)) seconds."
        }
        if ($Record.databaseTarget.targetBytes) {
            $actual = [long]$collections.legacy.footprint.disposed.database.bytes
            $target = [long]$Record.databaseTarget.targetBytes
            $Record.databaseTarget['actualBytes'] = $actual
            $Record.databaseTarget['actualGiB'] = $actual / 1GB
            $Record.databaseTarget.status = if ([Math]::Abs($actual - $target) -le $target * $Record.databaseTarget.toleranceFraction) {
                'PASS'
            } else { 'NOT REACHED' }
            Write-ComparisonJson $Receipt $Record
        }
        $countsSame = ($collections.legacy.sourceCounts | ConvertTo-Json -Depth 8 -Compress) -ceq
            ($collections.angular.sourceCounts | ConvertTo-Json -Depth 8 -Compress)
        $totalsSame = ($collections.legacy.collection | ConvertTo-Json -Depth 8 -Compress) -ceq
            ($collections.angular.collection | ConvertTo-Json -Depth 8 -Compress)
        $rowsSame = ($collections.legacy.rowCounts | ConvertTo-Json -Depth 8 -Compress) -ceq
            ($collections.angular.rowCounts | ConvertTo-Json -Depth 8 -Compress)
        $semantics = [pscustomobject]@{ identicalSourceCounts = $countsSame; identicalCollectionTotals = $totalsSame
            identicalCommonTableCounts = $rowsSame; note = 'Counts alone are not full business-value equivalence; static report content and browser comparisons remain pending.' }
        Set-ComparisonMeasuredRow $Record 'semantic-equivalence' $semantics 'PENDING'
        if (-not ($countsSame -and $totalsSame -and $rowsSame)) {
            $Record['versionDifferences'] = 'Collection/source/common-table counts differ between explicitly designated versions. See both child receipts; no parity or performance-equivalence claim.'
        }
        foreach ($engine in @('legacy', 'angular')) {
            foreach ($type in $(if ($engine -eq 'legacy') { @('Usage', 'Detailed') } else { @('Usage') })) {
                Write-Host "Generating $engine $type for the fixed last-seven-day interval."
                Assert-ComparisonExecutionInputs $Plan
                $report = Invoke-ComparisonBoundedChild $Plan 'Report' $engine $type
                Assert-ComparisonExecutionInputs $Plan
                Set-ComparisonMeasuredRow $Record "$engine.$($type.ToLowerInvariant())-seven-days" $report
                Write-ComparisonJson $Receipt $Record
            }
        }
        Assert-ComparisonExecutionInputs $Plan
        Write-Host 'Measuring Angular Serve startup and first/warm HTTP responses.'
        $serve = Invoke-ComparisonServeMeasurement $Plan
        Assert-ComparisonExecutionInputs $Plan
        Set-ComparisonMeasuredRow $Record 'angular.serve.startup' @{ milliseconds = $serve.startupMilliseconds; exclusiveTimingWindow = $false }
        Set-ComparisonMeasuredRow $Record 'angular.serve.http-first' @($serve.cases | Select-Object view, from, to, firstMilliseconds)
        Set-ComparisonMeasuredRow $Record 'angular.serve.http-warm' @($serve.cases | Select-Object view, from, to, warmP95Milliseconds, samples, stableRows)
        $Record['executionStatus'] = 'PASS'
        $Record['executionNote'] = 'Bounded local synthetic execution; browser/full business-value comparison remain PENDING. Exact measured bytes govern the database-size target; no global capacity or exclusive timing claim.'
    } catch {
        $Record['executionStatus'] = 'BLOCKED'; $Record['executionError'] = $_.Exception.Message
        throw
    } finally { Write-ComparisonJson $Receipt $Record }
}
