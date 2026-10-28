#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$Baseline,
    [ValidateRange(1000, 100000)][int]$Messages = 12000,
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'ExchangeLogReport.psd1') -Force
Initialize-ExlEngine -Root $root
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'bin\t' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
if (-not ('ServeFixtures' -as [type])) {
    Add-Type -LiteralPath (Join-Path $PSScriptRoot 'ServeFixtures.cs') -IgnoreWarnings -WarningAction SilentlyContinue -ReferencedAssemblies @(
        (Join-Path $root 'lib\sqlite\Microsoft.Data.Sqlite.dll'),
        'System.Runtime', 'System.Data.Common', 'System.Reflection', 'System.Net.Sockets', 'System.Net.Primitives',
        'System.Text.Encoding.Extensions', 'System.IO', 'System.Collections', 'System.Linq.Expressions', 'System.ComponentModel.Primitives', 'netstandard')
}
$id = [guid]::NewGuid().ToString('N').Substring(0, 8)
$path = Join-Path $OutputDirectory "serve-$id.sqlite"
$ready = Join-Path $OutputDirectory "ready-$id.json"
$web = Join-Path $OutputDirectory "web-$id"
[void][IO.Directory]::CreateDirectory($web)
[IO.File]::WriteAllText((Join-Path $web 'index.html'), '<!doctype html><title>Synthetic benchmark</title>')
$evidence = [ordered]@{ scale24GBProven = $false; osCacheCold = $false; sqliteConnectionColdEveryRequest = $true;
    fixturePreparationWarmsOsPages = $true; cacheMBPerRequest = 16; mmapMB = 0;
    mmapReason = 'Safe default retained: legacy read-only 0/256 MB probes measured; no large-file Serve mapping benefit proved. Indexed lists meet the latency gate without mapping.';
    fixture = $path; generatedMessages = $(if($Baseline){$null}else{$Messages}); baseline = $Baseline }
$evidence.measuredAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
$evidence.powerShellVersion = $PSVersionTable.PSVersion.ToString()
$evidence.dotNetVersion = [Environment]::Version.ToString()
$evidence.processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
$evidence.engineAssembly = [ExchangeLogReport.Store].Assembly.Location
$evidence.engineCompiledInMemory = -not [ExchangeLogReport.Store].Assembly.Location
$evidence.engineSourceHash = [AppDomain]::CurrentDomain.GetData('ExchangeLogReportAngular.EngineSourceHash')
$evidence.latencySamplesPerCase = 20
$evidence.warmSamplesPerCase = 19
$evidence.percentileMethod = 'Nearest-rank ceil(0.95*n)-1, warm samples only. With 19 warm samples p95 is their maximum; final integration should use more samples.'
$evidence.engineSources = @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter 'Engine.*.cs' -File | Sort-Object Name | ForEach-Object {
    [ordered]@{name=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
})
$started = [Diagnostics.Stopwatch]::StartNew()
$store = $null; $hostTask = $null
try {
    if ($Baseline) {
        $evidence.baselineHashBefore = (Get-FileHash -LiteralPath $Baseline).Hash
        [ServeFixtures]::Schema7Copy($Baseline, $path)
        $raw = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False"); $raw.Open()
        try {
            $c=$raw.CreateCommand(); $c.CommandText='SELECT MIN(time_ms),MAX(time_ms) FROM message_event;'
            $r=$c.ExecuteReader(); [void]$r.Read(); $from=$r.GetInt64(0); $to=$r.GetInt64(1)+1; $r.Dispose()
        } finally { $raw.Dispose() }
        $evidence.schema7LegacySelection = [ExchangeLogReport.ServeDiagnostics]::MeasureLegacySelection($path,$from,$to,3) | ConvertFrom-Json
    } else { $from=1792000000000L; $to=$from+86400000 }
    $store = [ExchangeLogReport.Store]::new($path,$false,'synthetic-benchmark')
    if (-not $Baseline) { [ServeFixtures]::Populate($store,$from,$Messages) }
    $evidence.rollupVerification = $store.VerifyServeRollups()
    $evidence.prepareMilliseconds = $started.Elapsed.TotalMilliseconds
    $evidence.schema = 10
    $evidence.messageRows = $store.Scalar('SELECT COUNT(*) FROM message_rollup;',$null)
    $evidence.trackingEvents = $store.Scalar('SELECT COUNT(*) FROM message_event;',$null)
    $evidence.databaseBytes = (Get-Item -LiteralPath $path).Length
    $evidence.walBytes = if (Test-Path -LiteralPath ($path+'-wal')) { (Get-Item -LiteralPath ($path+'-wal')).Length } else { 0 }
    $filterRow = $store.Query("SELECT server,sender FROM message_event WHERE sender IS NOT NULL LIMIT 1;", $null).Rows[0]
    $filterServer = [string]$filterRow[0]; $filterUser = [string]$filterRow[1]
    $evidence.filterServer = $filterServer; $evidence.filterUser = $filterUser
    $evidence.unfilteredPlan = [ExchangeLogReport.ServeDiagnostics]::ExplainMessageList($path,$from,$to,$null,$null,$null) | ConvertFrom-Json
    $evidence.filteredPlan = [ExchangeLogReport.ServeDiagnostics]::ExplainMessageList($path,$from,$to,$filterServer,$filterUser,$null) | ConvertFrom-Json
    $evidence.userOnlyPlan = [ExchangeLogReport.ServeDiagnostics]::ExplainMessageList($path,$from,$to,$null,$filterUser,$null) | ConvertFrom-Json
    $evidence.smtpClientsPlan = [ExchangeLogReport.ServeDiagnostics]::ExplainSmtpClients($path,$from,$to,$null,$null) | ConvertFrom-Json
    $evidence.hourlyOverviewPlan = [ExchangeLogReport.ServeDiagnostics]::ExplainOverview($path,$from,$to,$null,$null) | ConvertFrom-Json
    $evidence.filteredSelectionStrategy = 'Bounded latest-candidate probe; exact noncorrelated source-membership set only if the probe cannot fill the requested page and is not exhaustive. One snapshot/deadline; no failure retry.'
    $o = [ExchangeLogReport.ServeOptions]::new()
    $o.DatabasePath=$path; $o.WebRoot=$web; $o.Port=0; $o.NoBrowser=$true; $o.ReadyFile=$ready; $o.ReadyFileWithToken=$true
    $hostTask=[ExchangeLogReport.ServeHost]::RunAsync($o)
    while(-not(Test-Path -LiteralPath $ready)) { if($hostTask.IsCompleted){$hostTask.GetAwaiter().GetResult()}; Start-Sleep -Milliseconds 10 }
    $signal=Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
    $evidence.listenerStarted = $true
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $evidence.administratorToken = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $headers=@{'X-Portal-Token'=$signal.token}
    $period='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($from).ToString('O'))+'&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($to).ToString('O'))
    $cases=@(
        @{name='messages'; route="/api/messages?$period&size=100"},
        @{name='filteredMessages'; route="/api/messages?$period&size=100&user=$([Uri]::EscapeDataString($filterUser))&server=$([Uri]::EscapeDataString($filterServer))"},
        @{name='filteredUserOnly'; route="/api/messages?$period&size=100&user=$([Uri]::EscapeDataString($filterUser))"},
        @{name='broadUserOnly'; route="/api/messages?$period&size=100&user=%40"},
        @{name='broadFilteredMessages'; route="/api/messages?$period&size=100&user=%40&server=$([Uri]::EscapeDataString($filterServer))"},
        @{name='sessions'; route="/api/sessions?$period&size=100"},
        @{name='smtpClients'; route="/api/smtp/clients?$period&size=100"},
        @{name='smtpTransactions'; route="/api/smtp/transactions?$period&size=100"},
        @{name='hourlyOverview'; route="/api/overview?$period"}
    )
    $results=@()
    foreach($case in $cases){
        $samples=@(); $rows=0
        for($i=0;$i -lt 20;$i++){
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $r=Invoke-WebRequest -Uri ($signal.url.TrimEnd('/')+$case.route) -Headers $headers -TimeoutSec 20
            $samples+=$clock.Elapsed.TotalMilliseconds
            $body=$r.Content | ConvertFrom-Json
            $rows=$body.rows.Count
            if(@($body.columns | Where-Object kind -EQ 'steps').Count){throw 'List contains detail columns.'}
        }
        $sorted=@($samples | Sort-Object)
        $warm=@($samples | Select-Object -Skip 1 | Sort-Object)
        $results += [ordered]@{name=$case.name; rows=$rows; firstRequestMilliseconds=$samples[0]; warmP95Milliseconds=$warm[18]; maxMilliseconds=$sorted[-1]; samplesMilliseconds=$samples; passed=($sorted[-1] -lt 1000)}
    }
    $evidence.lists=@($results | Where-Object name -NE 'hourlyOverview')
    $evidence.overview=@($results | Where-Object name -EQ 'hourlyOverview')[0]
    # Hold a streaming HTTP reader while the normal source/rollup transaction commits.
    $client=[Net.Http.HttpClient]::new()
    $request=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,($signal.url.TrimEnd('/')+"/api/export.csv?view=messages&$period"))
    [void]$request.Headers.TryAddWithoutValidation('X-Portal-Token',$signal.token)
    $streaming=$client.SendAsync($request,[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    try {
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $tx=$store.Begin()
        try {
            $c=[ServeFixtures]::Connection($store).CreateCommand(); $c.Transaction=$tx
            $c.CommandText="INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES($from,'EX1','DELIVER','<concurrent@invalid>','concurrent','sender@invalid','r@invalid');"
            [void]$c.ExecuteNonQuery(); $store.ReconcileMessageRollups($tx); $tx.Commit()
        } finally { $tx.Dispose() }
        $evidence.writerCommitDuringHttpStreamMilliseconds=$clock.Elapsed.TotalMilliseconds
        $evidence.writerCommittedDuringHttpStream=$true
    } finally { $streaming.Dispose(); $request.Dispose(); $client.Dispose() }
    $evidence.noScaleClaim='Bounded synthetic fixture, fresh SQLite connection per request; first request is connection-cold, NOT OS-cache-cold. No 24 GB database was supplied.'
    if($Baseline){$evidence.baselineHashAfter=(Get-FileHash -LiteralPath $Baseline).Hash; if($evidence.baselineHashBefore -ne $evidence.baselineHashAfter){throw 'Frozen baseline changed.'}}
    $evidence.gatePassed = @($results | Where-Object {-not $_.passed}).Count -eq 0
} finally {
    if($hostTask -and -not $hostTask.IsCompleted -and (Test-Path -LiteralPath $ready)){
        $signal=Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
        Invoke-WebRequest -Uri ($signal.url.TrimEnd('/')+'/api/shutdown') -Method Post -Headers @{'X-Portal-Token'=$signal.token} | Out-Null
        if(-not $hostTask.Wait(10000)){throw 'Serve shutdown timeout.'}
        [void]$hostTask.GetAwaiter().GetResult()
    }
    if($store){$store.Dispose()}
    Remove-Item -LiteralPath $web -Recurse -Force
}
$output=Join-Path $OutputDirectory "serve-measurement-$id.json"
$evidence | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $output -Encoding utf8
Write-Output $output
if(-not $evidence.gatePassed){throw 'List/overview latency gate failed; see evidence.'}
