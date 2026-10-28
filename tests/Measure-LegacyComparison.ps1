#Requires -Version 7.4
<#
.SYNOPSIS
    Prepares or explicitly executes a bounded LOCAL SYNTHETIC comparison.
.DESCRIPTION
    Requires an explicitly designated clean public legacy checkout and its exact
    locally cached origin/main commit. No fetch, infrastructure discovery, mail,
    real logs/databases or browser automation. Collection/report/listener work
    requires the explicit -Execute opt-in described below.

    Default: records source hashes, isolated synthetic configurations and PENDING
    measurement rows. -GenerateLogs additionally runs the existing seeded generator
    in a child PowerShell, then hashes and marks those new fixture files read-only.
    It never accepts existing logs or databases. A new destination is mandatory.

    -Execute requires -GenerateLogs and an explicit compiled -WebRoot. It imports
    each engine only in separate child PowerShell processes, compares effective
    settings/source jobs before collecting, then measures fresh collection,
    static Usage on both engines, legacy Detailed, and Angular Serve HTTP.
    Browser readiness and full business-value parity remain separate PENDING rows.
    Timings are always labelled FunctionalConcurrent, never an exclusive benchmark.
    The ordinary Collect CLI performs infrastructure checks and is NOT a safe
    substitute for that synthetic-only executor.
.EXAMPLE
    .\tests\Measure-LegacyComparison.ps1 -LegacyRoot C:\Public\ExchangeLogReport `
        -LegacyCommit <40-character-local-origin-main-commit> `
        -OutputRoot C:\Evidence\new-comparison -FixtureEnd 2026-10-15T00:00:00Z
.NOTES
    Days is 7 or 14; the report interval is always the last explicit seven days
    of that fixture, UTC [start,end). Default scale is 0.001, one synthetic server.
    -Representative explicitly enables larger bounded synthetic runs. Defaults
    remain tiny. TargetLegacyDatabaseGiB records a measured disposed legacy DB
    target (GiB = 1073741824 bytes), never input-log size or SQL padding.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LegacyRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$LegacyCommit,
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][datetimeoffset]$FixtureEnd,
    [ValidateSet(7, 14)][int]$Days = 7,
    [ValidateRange(0.001, 20)][double]$Scale = 0.001,
    [ValidateRange(1, 8)][int]$ServerCount = 1,
    [ValidateRange(10, 1000000)][int]$Users = 40,
    [int]$Seed = 1,
    [switch]$GenerateLogs,
    [switch]$Execute,
    [string]$WebRoot,
    [switch]$DevelopmentMode,
    [switch]$Representative,
    [ValidateRange(0, 128)][double]$TargetLegacyDatabaseGiB = 0,
    [ValidateRange(60, 14400)][int]$ChildTimeoutSeconds = 300,
    [ValidateRange(512, 8192)][int]$MaximumWorkingSetMB = 1536,
    [ValidateRange(3, 20)][int]$HttpIterations = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'support\LegacyComparison.Execution.ps1')

function Get-ComparisonWorkloadLimits {
    param([bool]$Representative, [double]$Scale, [int]$ServerCount, [int]$Users,
        [int]$TimeoutSeconds, [int]$WorkingSetMB, [double]$TargetGiB)
    if (-not $Representative -and ($Scale -gt 0.002 -or $ServerCount -gt 2 -or
            $Users -gt 100 -or $TimeoutSeconds -gt 900 -or $WorkingSetMB -gt 4096 -or $TargetGiB -ne 0)) {
        throw 'Larger workloads or a database-size target require explicit -Representative.'
    }
    [pscustomobject]@{
        representative = $Representative
        maximumLogBytes = if ($Representative) { 160GB } else { 64MB }
        maximumOutputBytes = if ($Representative) { 384GB } else { 512MB }
        generatorTimeoutSeconds = if ($Representative) { 14400 } else { 180 }
        minimumFreeDiskBytes = if ($Representative) { 32GB } else { 1GB }
        minimumFreeMemoryBytes = if ($Representative) { 2GB } else { 0L }
    }
}

function Assert-ComparisonLocalPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.Substring(2).Contains(':') -or
        $Path.Contains('/') -or $Path -match '[\x00-\x1f*?]' -or
        $Path -match '(^|\\)\.{1,2}(\\|$)' -or $Path -match '[. ](\\|$)') {
        throw 'Use an ordinary absolute local drive path, without traversal, streams or wildcards.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -le 2) { throw 'A drive root is not a comparison destination.' }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))
    if ($drive.DriveType -ne [IO.DriveType]::Fixed) { throw 'Only a fixed local drive is accepted.' }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Reparse points are not accepted: $cursor"
            }
        }
        $cursor = Split-Path $cursor -Parent
    }
    return $full
}

function Test-ComparisonWithin {
    param([string]$Path, [string]$Root)
    return $Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-ComparisonGit {
    param([string]$Root, [string[]]$Arguments)
    $text = @(& git --no-optional-locks -C $Root --no-pager @Arguments 2>&1)
    if ($LASTEXITCODE) { throw "Read-only git inspection failed ($($Arguments -join ' ')): $($text -join ' ')" }
    return ($text -join "`n").Trim()
}

function Get-ComparisonLegacyDesignation {
    param([string]$Root, [string]$Commit)
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) { throw 'LegacyRoot must be the public repository root, not its parent or package folder.' }
    $top = (Invoke-ComparisonGit $Root @('rev-parse', '--show-toplevel')).Replace('/', '\')
    if (-not $top.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) { throw 'LegacyRoot is not the exact repository root.' }
    $origin = Invoke-ComparisonGit $Root @('config', '--get', 'remote.origin.url')
    if ($origin -notin @('https://github.com/Nico77600/ExchangeLogReport.git', 'https://github.com/Nico77600/ExchangeLogReport',
            'git@github.com:Nico77600/ExchangeLogReport.git')) {
        throw 'The designated legacy source must be the Nico77600/ExchangeLogReport public clone.'
    }
    if (Invoke-ComparisonGit $Root @('status', '--porcelain=v1', '--untracked-files=all')) {
        throw 'The public legacy clone is dirty; do not repair, reset or silently substitute another baseline.'
    }
    $head = Invoke-ComparisonGit $Root @('rev-parse', 'HEAD')
    $cachedMain = Invoke-ComparisonGit $Root @('rev-parse', 'refs/remotes/origin/main')
    if ($head -ne $Commit -or $cachedMain -ne $Commit) {
        throw 'LegacyCommit must equal both HEAD and the locally cached origin/main. No fetch is performed.'
    }
    $module = Join-Path $Root 'package\ExchangeLogReport.psd1'
    $manifest = Import-PowerShellDataFile -LiteralPath $module
    [pscustomobject]@{
        designation = 'Explicit public legacy source checkout (not an installed/customer copy)'
        root = $Root; origin = $origin; head = $head; cachedOriginMain = $cachedMain
        remoteFreshness = 'NOT VERIFIED: offline cached ref only; no GitHub access'
        moduleVersion = [string]$manifest.ModuleVersion
    }
}

function Get-ComparisonInventory {
    param([string]$Root, [string[]]$RelativePaths)
    $files = foreach ($relative in $RelativePaths) {
        $path = if ($relative -eq '.') { $Root } else { Join-Path $Root $relative }
        [void](Assert-ComparisonLocalPath $path)
        if (-not (Test-Path -LiteralPath $path)) { throw "Required comparison input is missing: $path" }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer) {
            $entries = @(Get-ChildItem -LiteralPath $path -Recurse -Force)
            if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
                throw "A comparison input contains a reparse point: $path"
            }
            $entries | Where-Object { -not $_.PSIsContainer }
        } else { $item }
    }
    foreach ($file in @($files | Sort-Object FullName -Unique)) {
        [pscustomobject]@{
            path = [IO.Path]::GetRelativePath($Root, $file.FullName)
            bytes = $file.Length
            sha256 = Get-ComparisonSha256 $file.FullName
        }
    }
}

function Get-ComparisonPrivateGitBaseline {
    param([string]$Root)
    [void](Invoke-ComparisonGit $Root @('rev-parse', '--git-dir'))
    $head = @(& git --no-optional-locks -C $Root rev-parse --verify --quiet HEAD 2>$null)
    if ($LASTEXITCODE -eq 1) {
        return [pscustomobject]@{
            head = $null
            status = 'UNBORN: no committed private baseline; use the recorded source-file inventory, not a release/commit claim.'
        }
    }
    if ($LASTEXITCODE -or $head.Count -ne 1 -or $head[0] -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'Could not establish the private Git baseline state.'
    }
    return [pscustomobject]@{ head = [string]$head[0]; status = 'Local commit only; working-tree inventory is authoritative.' }
}

function Get-ComparisonPeriod {
    param([datetimeoffset]$End, [int]$LogDays)
    if ($End.Offset -ne [timespan]::Zero -or $End.Ticks % [timespan]::TicksPerHour) {
        throw 'FixtureEnd must be an explicit UTC whole-hour boundary.'
    }
    if ($LogDays -notin @(7, 14)) { throw 'Only 7 or 14 fixture days are supported.' }
    if ($End -gt [datetimeoffset]::UtcNow -or $End.AddDays(-$LogDays) -lt [datetimeoffset]::UtcNow.AddDays(-364)) {
        throw 'The full fixture must be in the past and within the 365-day synthetic backfill.'
    }
    [pscustomobject]@{
        fixtureStart = $End.AddDays(-$LogDays).ToString('o')
        fixtureEndExclusive = $End.ToString('o')
        reportStart = $End.AddDays(-7).ToString('o')
        reportEndExclusive = $End.ToString('o')
        timeZone = 'UTC'; intervalConvention = '[start,end)'; reportDays = 7
    }
}

function ConvertTo-ComparisonLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function New-ComparisonConfigText {
    param([string]$Logs, [string]$Work, [string[]]$Servers, [hashtable]$Noise)
    $blocks = foreach ($server in $Servers) {
        "@{ Name = $(ConvertTo-ComparisonLiteral $server); Role = 'Mailbox'; ExchangePath = $(ConvertTo-ComparisonLiteral (Join-Path $Logs "$server\Exchange")); IisLogPath = $(ConvertTo-ComparisonLiteral (Join-Path $Logs "$server\inetpub\logs\LogFiles")) }"
    }
    $noiseEntries = foreach ($key in @($Noise.Keys | Sort-Object)) {
        if ($key -notmatch '^\w+$') { throw 'Unsafe noise configuration key.' }
        $values = @($Noise[$key] | ForEach-Object { ConvertTo-ComparisonLiteral ([string]$_) })
        "$key = @($($values -join ','))"
    }
    # Only known synthetic inputs and fresh outputs are emitted; no user config is copied.
    return @"
@{
    Servers = @($($blocks -join ','))
    Sources = @{ TransportRoles = @('FrontEnd'); PopImap = `$false }
    Noise = @{ $($noiseEntries -join "`n") }
    Collection = @{ BackfillDays = 365; StaleSourceHours = 0; Parallelism = 1; MaxFilesPerServer = 1 }
    Storage = @{ DatabasePath = $(ConvertTo-ComparisonLiteral (Join-Path $Work 'ExchangeLogReport.sqlite')); RetentionDays = 3650; DetailRetentionDays = 3650 }
    Report = @{ TimeZone = 'UTC'; OutputPath = $(ConvertTo-ComparisonLiteral (Join-Path $Work 'reports')); Formats = @('Csv','Html'); MaxDataAgeMinutes = 0; Parallelism = 1 }
    Logging = @{ Path = $(ConvertTo-ComparisonLiteral (Join-Path $Work 'execution-logs')) }
    Mail = @{ Enabled = `$false; SmtpServer = ''; CredentialFile = $(ConvertTo-ComparisonLiteral (Join-Path $Work 'unused-mail-credential')) }
}
"@
}

function Get-ComparisonPendingMeasurements {
    $rows = @(
        @('legacy.collection', 'collection wall time and engine-only time; fresh database'),
        @('angular.collection', 'collection wall time and engine-only time; fresh independent database'),
        @('legacy.database', 'actual main DB, WAL and SHM bytes before close and after dispose; no forced vacuum'),
        @('angular.database', 'actual main DB, WAL and SHM bytes before close and after dispose; include rollup/index cost'),
        @('legacy.usage-seven-days', 'static Usage generation elapsed, HTML/CSV inventory and bytes'),
        @('angular.usage-seven-days', 'static Usage generation elapsed, HTML/CSV inventory and bytes'),
        @('legacy.detailed-seven-days', 'Detailed generation elapsed, HTML/CSV inventory and bytes'),
        @('angular.serve.startup', 'new process start to authenticated loopback ready file'),
        @('angular.serve.http-first', 'first request in this process for each view; not an OS-cold cache claim'),
        @('angular.serve.http-warm', 'separate subsequent requests and p95 per view using the identical seven-day range'),
        @('angular.browser-ready', 'real browser navigation to rendered usable rows; not inferred from HTTP milliseconds'),
        @('semantic-equivalence', 'same collected fixture counts and comparable report/list values, with explained version differences')
    )
    foreach ($row in $rows) {
        [pscustomobject]@{ metric = $row[0]; status = 'PENDING'; measurement = $null; requirement = $row[1] }
    }
}

function Write-ComparisonJson {
    param([string]$Path, $Value, [switch]$CreateNew)
    $mode = if ($CreateNew) { [IO.FileMode]::CreateNew } else { [IO.FileMode]::Create }
    $stream = [IO.FileStream]::new($Path, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        try { $writer.Write(($Value | ConvertTo-Json -Depth 12)) } finally { $writer.Dispose() }
    } finally { $stream.Dispose() }
}

$angularRoot = Assert-ComparisonLocalPath (Split-Path $PSScriptRoot -Parent)
$limits = Get-ComparisonWorkloadLimits ([bool]$Representative) $Scale $ServerCount $Users `
    $ChildTimeoutSeconds $MaximumWorkingSetMB $TargetLegacyDatabaseGiB
if ($Execute -and (-not $GenerateLogs -or -not $WebRoot)) {
    throw '-Execute requires -GenerateLogs and an explicitly designated compiled -WebRoot; prior receipts are never healed or resumed.'
}
if (-not $Execute -and ($WebRoot -or $DevelopmentMode)) { throw '-WebRoot and -DevelopmentMode require -Execute.' }
$LegacyRoot = Assert-ComparisonLocalPath $LegacyRoot
$OutputRoot = Assert-ComparisonLocalPath $OutputRoot
Assert-ComparisonResourceReserve $OutputRoot $limits.minimumFreeDiskBytes $limits.minimumFreeMemoryBytes
if ($Representative -and $GenerateLogs) {
    $freeMemory = [long](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory * 1024
    if ($freeMemory -lt $MaximumWorkingSetMB * 1MB + $limits.minimumFreeMemoryBytes) {
        throw 'Insufficient available physical memory for the requested working-set budget plus reserve.'
    }
}
if (Test-Path -LiteralPath $OutputRoot) { throw 'OutputRoot must not exist; preparation never resumes or overwrites an earlier comparison.' }
if (-not (Test-Path -LiteralPath (Split-Path $OutputRoot -Parent) -PathType Container)) {
    throw 'OutputRoot must have an existing local parent directory.'
}
if ((Test-ComparisonWithin $OutputRoot $angularRoot) -or (Test-ComparisonWithin $OutputRoot $LegacyRoot)) {
    throw 'Keep comparison evidence outside both source trees.'
}
if ((Test-ComparisonWithin $LegacyRoot $angularRoot) -or (Test-ComparisonWithin $angularRoot $LegacyRoot)) {
    throw 'The legacy and Angular source trees must be independent.'
}
$period = Get-ComparisonPeriod $FixtureEnd $Days
$legacy = Get-ComparisonLegacyDesignation $LegacyRoot $LegacyCommit
$runtimeFiles = @('ExchangeLogReport.psd1', 'ExchangeLogReport.psm1', 'Invoke-ExchangeLogReport.ps1',
    'config\ExchangeLogReport.config.psd1', 'src', 'templates', 'lib')
$legacyFiles = @($runtimeFiles | ForEach-Object { 'package\' + $_ }) + @('package\PackageIntegrity.psd1')
$angularFiles = @($runtimeFiles | ForEach-Object { 'collector\' + $_ }) +
    @('product.json', 'tests\support\New-ExlSyntheticLogs.ps1', 'tests\Measure-LegacyComparison.ps1',
        'tests\support\LegacyComparison.Execution.ps1', 'tests\support\Invoke-LegacyComparisonChild.ps1')
$legacyInventory = @(Get-ComparisonInventory $LegacyRoot $legacyFiles)
$angularInventory = @(Get-ComparisonInventory $angularRoot $angularFiles)
$product = Get-Content -LiteralPath (Join-Path $angularRoot 'product.json') -Raw | ConvertFrom-Json
$angularManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $angularRoot 'collector\ExchangeLogReport.psd1')
$defaults = Import-PowerShellDataFile -LiteralPath (Join-Path $LegacyRoot 'package\config\ExchangeLogReport.config.psd1')
if ($defaults.Mail.Enabled -or $defaults.Mail.SmtpServer -or -not ($defaults.Noise -is [hashtable])) {
    throw 'The public default configuration is not the expected mail-disabled baseline.'
}
$pwsh = Assert-ComparisonLocalPath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
if ([IO.Path]::GetFileName($pwsh) -ne 'pwsh.exe') { throw 'Run preparation under PowerShell 7, not a hosted engine.' }
$servers = @(1..$ServerCount | ForEach-Object { 'SYNTH{0:00}' -f $_ })
$logs = Join-Path $OutputRoot 'synthetic-logs'
$generation = [ordered]@{
    status = 'PENDING'; note = 'Not requested; no logs or database have been generated.'
    days = $Days; scale = $Scale; servers = $servers; users = $Users; seed = $Seed
    profile = 'Production'; end = $period.fixtureEndExclusive
    maximumLogBytes = $limits.maximumLogBytes; timeoutSeconds = $limits.generatorTimeoutSeconds
    files = @(); bytes = $null
}
$record = [ordered]@{
    formatVersion = 1; syntheticOnly = $true; preparationOnly = $true; comparisonCompleted = $false
    createdUtc = [datetimeoffset]::UtcNow.ToString('o'); period = $period
    legacy = $legacy
    angular = [ordered]@{
        designation = 'Private experimental source tree; dirty/untracked status recorded, not a public release'
        root = $angularRoot; productVersion = $product.version; declaredSourceVersion = $product.sourceVersion
        moduleVersion = [string]$angularManifest.ModuleVersion
        gitBaseline = Get-ComparisonPrivateGitBaseline $angularRoot
        status = Invoke-ComparisonGit $angularRoot @('status', '--porcelain=v1', '--untracked-files=all')
    }
    powerShell = @{ path = $pwsh; version = $PSVersionTable.PSVersion.ToString(); sha256 = (Get-FileHash -LiteralPath $pwsh -Algorithm SHA256).Hash }
    sourceInventories = @{ legacy = $legacyInventory; angular = $angularInventory }
    fixture = $generation; configurations = @(); measurements = @(Get-ComparisonPendingMeasurements)
    workloadLimits = $limits
    databaseTarget = @{ basis = 'Disposed legacy SQLite main file, not input logs or WAL'
        targetGiB = $TargetLegacyDatabaseGiB; targetBytes = [long]($TargetLegacyDatabaseGiB * 1GB)
        toleranceFraction = 0.05; status = if ($TargetLegacyDatabaseGiB) { 'PENDING' } else { 'NOT REQUESTED' } }
    limitations = @(
        'No complete comparison or global performance conclusion exists until every required measurement and semantic check is executed and reviewed.',
        'Public legacy and private declared-source versions may differ. Their exact designations, versions and hashes govern interpretation.',
        'No remote freshness, release-asset identity, package authenticity or publication approval is established by offline preparation.',
        'Synthetic scale is a generator input, not a DB-size multiplier. Only measured disposed database bytes can establish the selected database-size target.',
        'Synthetic configs contain controlled overrides, not a claim that different engine versions have identical effective defaults; compare those before execution.',
        'Preparation-only runs designate no compiled web bundle; executed runs separately freeze the explicitly supplied WebRoot. Neither establishes browser readiness.',
        'Detailed generation, Serve HTTP latency and browser readiness are different operations; do not report them as equivalent.',
        'No OS cache flush or cold-cache guarantee. Future runs must state order, repetitions, startup/compile boundaries and machine load.'
    )
    requiredExecutionProtocol = @(
        'Recheck the exact source inventory, public clean baseline and every immutable fixture hash before and after each child process.',
        'Use a fresh child pwsh per engine definition and fresh independent legacy/angular work roots; never import both engines together.',
        'Use Import-ExlConfiguration and Get-ExlSources on the generated synthetic configuration. Compare effective defaults/source jobs across versions; reject unexplained differences, discovery files and every source outside synthetic-logs.',
        'Use Initialize-ExlEngine, Open-ExlStore and Invoke-ExlCollection directly, without infrastructure access/discovery helpers; reject errors/unreachable/zero data.',
        'Resolve-ExlPeriod -Range Custom using the recorded UTC report boundaries; assert no clamping. Use New-ExlReport, never automatic collection or mail.',
        'Record DB/WAL/SHM bytes while open and after dispose, source counts, errors and artifact inventories; no SQL row padding or manual schema downgrade.',
        'Designate and hash the compiled web bundle. New Serve must use the collected compatible schema, explicit loopback ready file and DevelopmentMode only when required by this source checkout.',
        'Measure /api/messages, /api/sessions and /api/smtp/clients first and warm separately using from/to; use a real browser for rendered readiness.',
        'No generic real-log or real-database input, -Discover, -Mail, retention, default Collect CLI, network sources or source-tree writes.'
    )
}
if ($Execute) {
    $WebRoot = Assert-ComparisonLocalPath $WebRoot
    if (-not (Test-Path -LiteralPath (Join-Path $WebRoot 'index.html') -PathType Leaf)) {
        throw 'WebRoot must contain an existing compiled application index.html.'
    }
    $record['web'] = @{ root = $WebRoot; inventory = @(Get-ComparisonInventory $WebRoot @('.'))
        designation = 'Explicit compiled web bytes; not assumed identical to current source or proof of browser readiness.' }
}
[void][IO.Directory]::CreateDirectory($OutputRoot)
$receipt = Join-Path $OutputRoot 'comparison-preparation.json'
Write-ComparisonJson $receipt $record -CreateNew
try {
    foreach ($name in @('legacy', 'angular')) {
        $work = Join-Path $OutputRoot $name
        [void][IO.Directory]::CreateDirectory($work)
        $configPath = Join-Path $work 'synthetic.config.psd1'
        [IO.File]::WriteAllText($configPath, (New-ComparisonConfigText $logs $work $servers $defaults.Noise), [Text.UTF8Encoding]::new($false))
        $record.configurations += [pscustomobject]@{
            engine = $name; workRoot = $work; path = $configPath
            sha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
            database = Join-Path $work 'ExchangeLogReport.sqlite'
        }
    }
    if ($GenerateLogs) {
        Write-Host "Generating $Days synthetic days: scale=$Scale, servers=$ServerCount, users=$Users."
        $generation.status = 'RUNNING'; $generation.note = 'Fixture generation only; measurements remain pending.'
        Write-ComparisonJson $receipt $record
        $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
        $start.WorkingDirectory = $OutputRoot; $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        foreach ($arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                (Join-Path $PSScriptRoot 'support\New-ExlSyntheticLogs.ps1'), '-Path', $logs,
                '-Server', ($servers -join ','), '-Days', [string]$Days, '-Scale', $Scale.ToString([Globalization.CultureInfo]::InvariantCulture),
                '-Users', [string]$Users, '-Profile', 'Production', '-Seed', [string]$Seed, '-End', $period.fixtureEndExclusive)) {
            $start.ArgumentList.Add($arg)
        }
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $lastSizeCheck = -2.0
            while (-not $process.WaitForExit(250)) {
                if ($watch.Elapsed.TotalSeconds -gt $generation.timeoutSeconds) { throw 'Bounded synthetic generator timed out.' }
                $process.Refresh()
                if (-not $process.HasExited -and $process.WorkingSet64 -gt $MaximumWorkingSetMB * 1MB) {
                    throw 'Synthetic generator exceeded its sampled working-set limit.'
                }
                if ($watch.Elapsed.TotalSeconds - $lastSizeCheck -ge 2) {
                    Assert-ComparisonResourceReserve $OutputRoot $limits.minimumFreeDiskBytes $limits.minimumFreeMemoryBytes
                    if (Test-Path -LiteralPath $logs) {
                        $size = (Get-ChildItem -LiteralPath $logs -Recurse -File | Measure-Object Length -Sum).Sum
                        if ($size -gt $generation.maximumLogBytes) { throw 'Bounded synthetic log limit exceeded.' }
                    }
                    $lastSizeCheck = $watch.Elapsed.TotalSeconds
                }
            }
            [IO.File]::WriteAllText((Join-Path $OutputRoot 'generator.stdout.txt'), $stdout.GetAwaiter().GetResult())
            [IO.File]::WriteAllText((Join-Path $OutputRoot 'generator.stderr.txt'), $stderr.GetAwaiter().GetResult())
            if ($process.ExitCode -ne 0) { throw 'Synthetic generator failed; see generator.stderr.txt.' }
        } finally {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
        $generation.files = @(Get-ComparisonInventory $logs @('.'))
        if (-not $generation.files.Count) { throw 'The generator produced no fixture files.' }
        $generation.bytes = [long](($generation.files | Measure-Object bytes -Sum).Sum)
        if ($generation.bytes -gt $generation.maximumLogBytes) { throw 'Bounded synthetic log limit exceeded.' }
        foreach ($file in $generation.files) {
            $item = [IO.FileInfo]::new((Join-Path $logs $file.path))
            $file | Add-Member -NotePropertyName lastWriteTimeUtc -NotePropertyValue $item.LastWriteTimeUtc.ToString('o')
            $item.IsReadOnly = $true
        }
        $generation.status = 'PASS'
        Write-Host "Frozen synthetic logs: $($generation.bytes) bytes in $($generation.files.Count) files."
        $generation.note = 'Only fixture generation completed. Read-only attributes deter accidental changes; future consumers must verify hashes.'
    }
    $null = Get-ComparisonLegacyDesignation $LegacyRoot $LegacyCommit
    if (($legacyInventory | ConvertTo-Json -Depth 4 -Compress) -cne
        (@(Get-ComparisonInventory $LegacyRoot $legacyFiles) | ConvertTo-Json -Depth 4 -Compress) -or
        ($angularInventory | ConvertTo-Json -Depth 4 -Compress) -cne
        (@(Get-ComparisonInventory $angularRoot $angularFiles) | ConvertTo-Json -Depth 4 -Compress)) {
        throw 'Source bytes changed during preparation; start over with a new destination after source work is frozen.'
    }
    $record['preparationStatus'] = 'PASS'
    if ($Execute) {
        $plan = [pscustomobject]@{
            syntheticOnly = $true; outputRoot = $OutputRoot; logs = $logs; servers = $servers
            period = $period; fixtureFiles = $generation.files; sourceInventories = $record.sourceInventories
            legacy = $record.legacy; angular = $record.angular; configurations = $record.configurations
            webRoot = $WebRoot; webInventory = $record.web.inventory
            developmentMode = [bool]$DevelopmentMode; pwsh = $pwsh
            childScript = Join-Path $PSScriptRoot 'support\Invoke-LegacyComparisonChild.ps1'
            planPath = Join-Path $OutputRoot 'execution-plan.json'; readyFile = Join-Path $OutputRoot 'angular-Serve.ready.json'
            timeoutSeconds = $ChildTimeoutSeconds; maximumWorkingSetMB = $MaximumWorkingSetMB
            maximumOutputBytes = $limits.maximumOutputBytes; httpIterations = $HttpIterations
            minimumFreeDiskBytes = $limits.minimumFreeDiskBytes
            minimumFreeMemoryBytes = $limits.minimumFreeMemoryBytes
        }
        Write-ComparisonExecutionJson $plan.planPath $plan
        $plan | Add-Member -NotePropertyName planSha256 -NotePropertyValue (Get-ComparisonSha256 $plan.planPath)
        Invoke-ComparisonExecution $plan $record $receipt
    }
} catch {
    if (-not $record.Contains('preparationStatus')) { $record['preparationStatus'] = 'BLOCKED' }
    $record['error'] = $_.Exception.Message
    if ($generation.status -eq 'RUNNING') { $generation.status = 'BLOCKED' }
    Write-ComparisonJson $receipt $record
    throw
}
Write-ComparisonJson $receipt $record
[pscustomobject]@{
    PreparationStatus = $record.preparationStatus; ComparisonStatus = 'PENDING'
    GeneratedLogs = $generation.status; Evidence = $receipt
    ExecutionStatus = if ($record.Contains('executionStatus')) { $record.executionStatus } else { 'NOT REQUESTED' }
    Note = 'Read individual metric statuses: browser/full business-value parity remain pending; no exclusive performance or capacity claim.'
}
