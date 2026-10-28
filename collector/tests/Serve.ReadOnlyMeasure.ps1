#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Evidence, [ValidateRange(5,200)][int]$Samples=20)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'ExchangeLogReport.psd1') -Force
Initialize-ExlEngine
$source=Get-Content -LiteralPath $Evidence -Raw|ConvertFrom-Json
$id=[guid]::NewGuid().ToString('N').Substring(0,8)
$work=Join-Path $root "bin\t\r$id"
[void][IO.Directory]::CreateDirectory($work)
[IO.File]::WriteAllText((Join-Path $work 'index.html'),'<!doctype html><title>Synthetic read-only measurement</title>')
$options=[ExchangeLogReport.ServeOptions]::new()
$options.DatabasePath=$source.fixture;$options.WebRoot=$work;$options.Port=0;$options.NoBrowser=$true
$options.ReadyFile=Join-Path $work 'ready.json';$options.ReadyFileWithToken=$true
$before=(Get-FileHash -LiteralPath $source.fixture).Hash
$task=$null;$results=@()
try {
    $task=[ExchangeLogReport.ServeHost]::RunAsync($options)
    while(-not(Test-Path -LiteralPath $options.ReadyFile)){
        if($task.IsCompleted){$task.GetAwaiter().GetResult();throw 'Host stopped before readiness.'}
        Start-Sleep -Milliseconds 20
    }
    $ready=Get-Content -LiteralPath $options.ReadyFile -Raw|ConvertFrom-Json
    if($ready.status -ne 'ready'){throw $ready.message}
    $headers=@{'X-Portal-Token'=$ready.token}
    $period='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($source.schema7LegacySelection.from).ToString('O'))+
        '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($source.schema7LegacySelection.to).ToString('O'))
    $filter='&user='+[Uri]::EscapeDataString($source.filterUser)
    $server='&server='+[Uri]::EscapeDataString($source.filterServer)
    $cases=@(
        @{name='messages';route="/api/messages?$period&size=100"},
        @{name='filteredMessages';route="/api/messages?$period&size=100$filter$server"},
        @{name='filteredUserOnly';route="/api/messages?$period&size=100$filter"},
        @{name='broadUserOnly';route="/api/messages?$period&size=100&user=%40"},
        @{name='broadFilteredMessages';route="/api/messages?$period&size=100&user=%40$server"},
        @{name='sessions';route="/api/sessions?$period&size=100"},
        @{name='smtpClients';route="/api/smtp/clients?$period&size=100"},
        @{name='smtpTransactions';route="/api/smtp/transactions?$period&size=100"},
        @{name='hourlyOverview';route="/api/overview?$period"}
    )
    foreach($case in $cases){
        $times=@();$rows=0
        for($n=0;$n -lt $Samples;$n++){
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $response=Invoke-WebRequest -Uri ($ready.url.TrimEnd('/')+$case.route) -Headers $headers -TimeoutSec 20
            $times+=$clock.Elapsed.TotalMilliseconds
            $body=$response.Content|ConvertFrom-Json;$rows=$body.rows.Count
            if(@($body.columns|Where-Object kind -EQ 'steps').Count){throw 'Summary endpoint exposed detail steps.'}
        }
        $warm=@($times|Select-Object -Skip 1|Sort-Object)
        $rank=[int][Math]::Ceiling(.95*$warm.Count)-1
        $results+=[ordered]@{name=$case.name;rows=$rows;firstRequestMilliseconds=$times[0];warmP95Milliseconds=$warm[$rank];
            maxMilliseconds=($times|Measure-Object -Maximum).Maximum;samplesMilliseconds=$times;
            passed=(($times|Measure-Object -Maximum).Maximum -lt 1000)}
    }
} finally {
    if($task -and -not $task.IsCompleted -and (Test-Path -LiteralPath $options.ReadyFile)){
        $ready=Get-Content -LiteralPath $options.ReadyFile -Raw|ConvertFrom-Json
        [void](Invoke-WebRequest -Uri ($ready.url.TrimEnd('/')+'/api/shutdown') -Method Post -Headers @{'X-Portal-Token'=$ready.token})
        if(-not $task.Wait(10000)){throw 'Shutdown timeout.'}
    }
    Remove-Item -LiteralPath $work -Recurse -Force
}
$lists=@($results|Where-Object name -NE 'hourlyOverview')
$after=(Get-FileHash -LiteralPath $source.fixture).Hash
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$output=Join-Path $root "bin\t\serve-readonly-measurement-$id.json"
[ordered]@{
    measuredAtUtc=[DateTimeOffset]::UtcNow.ToString('O');fixture=$source.fixture;sourceEvidence=$Evidence;readOnlyFixture=$true;
    mainHashBefore=$before;mainHashAfter=$after;unchanged=($before -eq $after);scale24GBProven=$false;osCacheCold=$false;
    sqliteConnectionColdEveryRequest=$true;mmapMB=0;cacheMBPerRequest=16;latencySamplesPerCase=$Samples;warmSamplesPerCase=$Samples-1;
    percentileMethod='Nearest-rank ceil(.95*n)-1, excludes first request; max and all samples retained';
    administratorToken=([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);
    powerShellVersion=$PSVersionTable.PSVersion.ToString();dotNetVersion=[Environment]::Version.ToString();
    engineSourceHash=[AppDomain]::CurrentDomain.GetData('ExchangeLogReportAngular.EngineSourceHash');
    engineSources=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter 'Engine.*.cs' -File|Sort-Object Name|ForEach-Object{[ordered]@{name=$_.Name;sha256=(Get-FileHash -LiteralPath $_.FullName).Hash}});
    lists=$lists;overview=@($results|Where-Object name -EQ 'hourlyOverview')[0];
    gatePassed=(@($results|Where-Object {-not $_.passed}).Count -eq 0 -and $before -eq $after)
}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $output -Encoding utf8
Write-Output $output
if(@($results|Where-Object {-not $_.passed}).Count -or $before -ne $after){throw 'Read-only list/overview gate failed; see recorded samples.'}
