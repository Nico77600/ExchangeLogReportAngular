BeforeAll {
    $ErrorActionPreference = 'Stop'
    $hostRoot = Split-Path $PSScriptRoot -Parent
    $publish = Join-Path $hostRoot 'publish'
    $exe = Join-Path $publish 'ExchangeLogReportAngular.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw 'Publish the self-contained host before these tests.' }
    $work = Join-Path $hostRoot ('test-artifacts\' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($work)
    $oldPath = $env:PATH
    $env:PATH = $publish + ';' + $env:PATH
    foreach ($name in @('SQLitePCLRaw.core.dll', 'SQLitePCLRaw.provider.e_sqlite3.dll', 'SQLitePCLRaw.batteries_v2.dll', 'Microsoft.Data.Sqlite.dll', 'ExchangeLogReportAngular.dll')) {
        Add-Type -Path (Join-Path $publish $name)
    }
    [SQLitePCL.Batteries_V2]::Init()
    . (Join-Path $PSScriptRoot 'Storage.Fixtures.ps1')
    $database = Join-Path $work 'synthetic.sqlite'
    $store = [ExchangeLogReport.Store]::new($database, $false, 'synthetic-test')
    try {
        $t = [DateTimeOffset]::Parse('2026-10-14T12:00:00Z').ToUnixTimeMilliseconds()
        $store.Exec("INSERT INTO source_file(server,kind,path) VALUES('synthetic-mail-01','SMTPReceive','synthetic-only');")
        for ($i = 0; $i -lt 205; $i++) {
            $user = if ($i -eq 0) { '=SYNTHETIC_FORMULA' } else { 'synthetic-user-' + $i.ToString('000') }
            $requests = $i + 2
            $store.Exec("INSERT INTO access_usage(day,server,user,protocol,requests,successes,client_errors,server_errors,bytes_in,bytes_out,total_ms,max_ms,first_ms,last_ms,last_success_ms,last_failure_ms) VALUES('2026-10-14','synthetic-mail-01','$user','MAPI',$requests,$requests,0,0,100,200,30,20,$t,$t,$t,0);")
        }
        $transcript = "12:00:00.000 C: AUTH LOGIN`n12:00:00.001 C: c3ludGhldGljLXNlY3JldA==`n12:00:00.002 S: 235 2.7.0 Authentication successful`n12:00:01.000 C: MAIL FROM:<sender@example.invalid>"
        $safeTranscript = $transcript.Replace("'", "''")
        $store.Exec("INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,role,session_id,remote_ep,helo,mail_from,rcpt_count,rcpts,message_id,status,response,transcript) VALUES($t,$t,'synthetic-mail-01','Receive','Hub','SYNTHETIC','192.0.2.10:1234','synthetic.example.invalid','sender@example.invalid',1,'recipient@example.invalid','<synthetic@example.invalid>','Success','250 OK','$safeTranscript');")
        Complete-StorageFixture $store
    } finally { $store.Dispose() }
    $hash = (Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash
    $readyPath = Join-Path $work 'ready.json'
    $reportsPath = Join-Path $work 'reports'
    $process = Start-Process -FilePath $exe -ArgumentList @('--database', "`"$database`"", '--reports', "`"$reportsPath`"", '--port', '0', '--no-browser', '--ready-file', "`"$readyPath`"", '--ready-file-with-token') -PassThru -RedirectStandardOutput (Join-Path $work 'stdout.log') -RedirectStandardError (Join-Path $work 'stderr.log')
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $readyPath)) {
        if ($process.HasExited) { throw ('Host exited: ' + (Get-Content (Join-Path $work 'stderr.log') -Raw)) }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Host did not become ready.' }
        Start-Sleep -Milliseconds 100
    }
    $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
    $base = $ready.url
    $headers = @{ 'X-Portal-Token' = $ready.token }
    function Request([string]$Path, [string]$Method = 'GET', $Body = $null, [hashtable]$Extra = @{}) {
        $h = @{} + $headers + $Extra
        $parameters = @{ Uri = $base + $Path; Method = $Method; Headers = $h; SkipHttpErrorCheck = $true }
        if ($null -ne $Body) { $parameters.Body = ($Body | ConvertTo-Json -Compress); $parameters.ContentType = 'application/json' }
        Invoke-WebRequest @parameters
    }
    function BuildReport([string]$TimeZone = 'UTC', [switch]$CheckConflict) {
        $input = @{ start = '2026-10-14T00:00:00Z'; end = '2026-10-15T00:00:00Z'; reportType = 'Detailed'; timeZone = $TimeZone }
        $result = Request '/api/reports' 'POST' $input
        $result.StatusCode | Should -Be 202
        if ($CheckConflict) { (Request '/api/reports' 'POST' $input).StatusCode | Should -Be 409 }
        $id = ($result.Content | ConvertFrom-Json).id
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        do {
            $job = (Request "/api/jobs/$id").Content | ConvertFrom-Json
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Synthetic report timed out.' }
            if ($job.state -eq 'Running') { Start-Sleep -Milliseconds 100 }
        } while ($job.state -eq 'Running')
        $job.state | Should -Be 'Completed' -Because $job.error
        return $id
    }
    function WaitJob([string]$Id) {
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            $job = (Request "/api/jobs/$Id").Content | ConvertFrom-Json
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Synthetic job timed out.' }
            if ($job.state -eq 'Running') { Start-Sleep -Milliseconds 100 }
        } while ($job.state -eq 'Running')
        return $job
    }
}

Describe 'Private loopback portal' {
    It 'hashes only the first explicit theme script after HTML newline normalization' {
        $type = [ExchangeLogReport.Store].Assembly.GetType('ExchangeLogReportAngular.PortalContentSecurity', $true)
        $method = $type.GetMethod('ForHtml')
        $theme = "`r`n(()=>{const p='scoutTheme';window.matchMedia('prefers-color-scheme: dark');document.documentElement.setAttribute('data-theme',p)})();`r`n"
        $normalized = $theme.Replace("`r`n", "`n")
        $hash = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalized)))
        $html = '<html><head><script>' + $theme + '</script><script>window.unapproved=true;</script></head></html>'
        $policy = $method.Invoke($null, [object[]]@($html))
        $policy | Should -Match ([regex]::Escape("script-src 'self' 'sha256-$hash';"))
        ([regex]::Matches($policy, 'sha256-')).Count | Should -Be 1
        $policy | Should -Not -Match "script-src[^;]*unsafe-inline"
        $notFirst = $method.Invoke($null, [object[]]@('<script>window.unapproved=true;</script>' + $html))
        $notFirst | Should -Not -Match 'sha256-'
        $externalFirst = $method.Invoke($null, [object[]]@('<script src="theme.js"></script>' + $html))
        $externalFirst | Should -Not -Match 'sha256-'
    }

    It 'defaults data and reports to the package root above the executable directory' {
        $assembly = [ExchangeLogReport.Store].Assembly
        $type = $assembly.GetType('ExchangeLogReportAngular.PortalOptions', $true)
        $arguments = [object[]]::new(1)
        $arguments[0] = [string[]]@()
        $defaults = $type.GetMethod('Parse').Invoke($null, $arguments)
        $root = [IO.Path]::GetFullPath((Join-Path ([AppContext]::BaseDirectory) '..'))
        $defaults.Database | Should -Be (Join-Path $root 'collector\data\ExchangeLogReport.sqlite')
        $defaults.Reports | Should -Be (Join-Path $root 'reports')
    }

    It 'requires a capability token and rejects foreign Host and Origin' {
        (Invoke-WebRequest -Uri ($base + '/api/status') -SkipHttpErrorCheck).StatusCode | Should -Be 401
        (Request '/api/status' -Extra @{ Origin = 'https://example.invalid' }).StatusCode | Should -Be 403
        (Request '/api/status' -Extra @{ Host = 'localhost:' + ([uri]$base).Port }).StatusCode | Should -Be 400
        (Request '/api/status' -Extra @{ 'Sec-Fetch-Site' = 'cross-site' }).StatusCode | Should -Be 403
        (Request '/collector/ExchangeLogReport.psm1').StatusCode | Should -Be 404
        (Request '/api/does-not-exist').StatusCode | Should -Be 404
    }

    It 'gives actionable dependency diagnostics without copying private exception messages' {
        $type = [ExchangeLogReport.Store].Assembly.GetType('ExchangeLogReportAngular.PortalDiagnostics', $true)
        $method = $type.GetMethod('Describe')
        $missing = [IO.FileNotFoundException]::new('SYNTHETIC_PRIVATE_TRANSCRIPT_AND_TOKEN', 'Microsoft.Data.Sqlite.dll')
        $wrapped = [TypeInitializationException]::new('Synthetic', $missing)
        $message = $method.Invoke($null, [object[]]@($wrapped))
        $message | Should -Match 'Microsoft.Data.Sqlite.dll'
        $message | Should -Match 'Re-extract'
        $message | Should -Not -Match 'SYNTHETIC_PRIVATE_TRANSCRIPT_AND_TOKEN'
        $other = $method.Invoke($null, [object[]]@([InvalidOperationException]::new('SYNTHETIC_PRIVATE_TRANSCRIPT_AND_TOKEN')))
        $other | Should -Not -Match 'SYNTHETIC_PRIVATE_TRANSCRIPT_AND_TOKEN'
        $other | Should -Match 'HRESULT'
    }

    It 'prints an actionable underlying error when the requested loopback port is occupied' {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $failed = $null
        try {
            $port = $listener.LocalEndpoint.Port
            $stderr = Join-Path $work 'occupied-port-stderr.log'
            $failed = Start-Process -FilePath $exe -ArgumentList @('--database', "`"$database`"", '--reports', "`"$reportsPath`"", '--port', $port, '--no-browser') -PassThru -RedirectStandardOutput (Join-Path $work 'occupied-port-stdout.log') -RedirectStandardError $stderr
            $failed.WaitForExit(10000) | Should -BeTrue
            $failed.ExitCode | Should -Be 2
            Get-Content -LiteralPath $stderr -Raw | Should -Match 'AddressAlreadyInUse'
        } finally {
            $listener.Stop()
            if ($failed -and -not $failed.HasExited) { Stop-Process -Id $failed.Id -Force }
        }
    }

    It 'reports the source schema and validates input without starting a job' {
        $response = Request '/api/status'
        $status = $response.Content | ConvertFrom-Json
        $status.schemaVersion | Should -Be ([ExchangeLogReport.Store]::SchemaVersion)
        $status.version | Should -Be '0.3.0'
        $status.supportedSchemaVersion | Should -Be ([ExchangeLogReport.Store]::SchemaVersion)
        $status.readOnly | Should -BeTrue
        $response.Headers['Cache-Control'] | Should -Contain 'no-store'
        $policy = [string]$response.Headers['Content-Security-Policy']
        $policy | Should -Match "script-src 'self'(?: 'sha256-[A-Za-z0-9+/=]+')?;"
        $policy | Should -Match "style-src 'self' 'unsafe-inline'"
        $policy | Should -Not -Match "script-src[^;]*unsafe-inline"
        (Request '/api/reports' 'POST' @{ start = '2026-10-14T00:00:00'; end = '2026-10-15T00:00:00Z'; reportType = 'Usage'; timeZone = 'UTC' }).StatusCode | Should -Be 400
        (Request '/api/reports' 'POST' @{ start = '2026-10-14T00:00:00Z'; end = '2026-10-15T00:00:00Z'; reportType = 'Usage'; timeZone = 'Not/A/Zone' }).StatusCode | Should -Be 400
    }

    It 'builds a committed complete snapshot and retains CSV but no HTML' {
        $script:reportId = BuildReport -CheckConflict
        $report = (Request "/api/reports/$script:reportId").Content | ConvertFrom-Json
        ($report.datasets | Where-Object name -EQ 'users').total | Should -Be 205
        ($report.datasets | Where-Object name -EQ 'smtp').total | Should -Be 1
        @(Get-ChildItem -LiteralPath (Join-Path $reportsPath $script:reportId) -Filter '*.html').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $reportsPath $script:reportId) -Filter '*.csv').Count | Should -BeGreaterThan 0
        @(Get-ChildItem -LiteralPath $reportsPath -Directory -Force | Where-Object Name -Like '*.building').Count | Should -Be 0
    }

    It 'paginates, validates queries, and treats LIKE wildcards literally' {
        $page = (Request "/api/reports/$script:reportId/datasets/users?offset=200&limit=200").Content | ConvertFrom-Json
        $page.total | Should -Be 205
        $page.rows.Count | Should -Be 5
        $literal = (Request "/api/reports/$script:reportId/datasets/users?q=%25").Content | ConvertFrom-Json
        $literal.total | Should -Be 0
        (Request "/api/reports/$script:reportId/datasets/users?limit=201").StatusCode | Should -Be 400
        (Request "/api/reports/$script:reportId/datasets/users?sort=999").StatusCode | Should -Be 400
        (Request "/api/reports/$script:reportId/datasets/users?surprise=true").StatusCode | Should -Be 400
        (Request "/api/reports/$script:reportId/datasets/unknown").StatusCode | Should -Be 404
        $detail = (Request "/api/reports/$script:reportId").Content | ConvertFrom-Json
        $columns = ($detail.datasets | Where-Object name -EQ 'users').columns
        $index = [array]::IndexOf(@($columns.name), 'Requests')
        $index | Should -BeGreaterOrEqual 0
        $sorted = (Request "/api/reports/$script:reportId/datasets/users?sort=$index&limit=2").Content | ConvertFrom-Json
        $sorted.rows[0].cells[$index] | Should -Be 2
        $sorted.rows[1].cells[$index] | Should -Be 3
        $desc = (Request "/api/reports/$script:reportId/datasets/users?sort=$index&limit=2&descending=true").Content | ConvertFrom-Json
        $desc.rows[0].cells[$index] | Should -Be 206
    }

    It 'streams every filtered CSV row with a BOM and formula protection' {
        $response = Request "/api/reports/$script:reportId/datasets/users/csv"
        $csvPath = Join-Path $work 'users.csv'
        Invoke-WebRequest -Uri ($base + "/api/reports/$script:reportId/datasets/users/csv") -Headers $headers -OutFile $csvPath
        $bytes = [IO.File]::ReadAllBytes($csvPath)
        [Convert]::ToHexString($bytes[0..2]) | Should -Be 'EFBBBF'
        $csv = [IO.File]::ReadAllText($csvPath)
        $csv | Should -Match "'=SYNTHETIC_FORMULA"
        ($csv | ConvertFrom-Csv -Delimiter ';').Count | Should -Be 205
        $filtered = (Request "/api/reports/$script:reportId/datasets/users/csv?q=synthetic-user-001").Content
        ($filtered | ConvertFrom-Csv -Delimiter ';').Count | Should -Be 1
    }

    It 'persists nested transcripts using the existing redaction and leaves source bytes unchanged' {
        $smtp = (Request "/api/reports/$script:reportId/datasets/smtp").Content
        $smtp | Should -Not -Match 'c3ludGhldGljLXNlY3JldA=='
        $smtp | Should -Match 'sender@example.invalid'
        (Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash | Should -Be $hash
        $logs = (Get-Content (Join-Path $work 'stdout.log') -Raw) + (Get-Content (Join-Path $work 'stderr.log') -Raw)
        $logs | Should -Not -Match ([regex]::Escape($ready.token))
    }

    It 'formats time values as report-local wall seconds in filtered CSV' {
        $id = BuildReport 'Pacific Standard Time'
        $csv = (Request "/api/reports/$id/datasets/smtp/csv").Content
        $csv | Should -Match '2026-10-14 05:00:00'
    }

    It 'applies the delivered fourteen-day retention default to source coverage notes' {
        $start = [DateTimeOffset]::UtcNow.AddDays(-30)
        $result = Request '/api/reports' 'POST' @{ start = $start.ToString('o'); end = $start.AddDays(1).ToString('o'); reportType = 'Usage'; timeZone = 'UTC' }
        $result.StatusCode | Should -Be 202
        $id = ($result.Content | ConvertFrom-Json).id
        (WaitJob $id).state | Should -Be 'Completed'
        $report = (Request "/api/reports/$id").Content | ConvertFrom-Json
        ($report.notes -join ' ') | Should -Match 'kept 14 days'
        $report.title | Should -Be 'Exchange Server usage report'
    }

    It 'rejects unknown source servers explicitly and accepts known servers case-insensitively' {
        $input = @{ start = '2026-10-14T00:00:00Z'; end = '2026-10-15T00:00:00Z'; reportType = 'Usage'; timeZone = 'UTC'; server = "unknown-server' OR 1=1 --" }
        $result = Request '/api/reports' 'POST' $input
        $result.StatusCode | Should -Be 202
        $job = WaitJob (($result.Content | ConvertFrom-Json).id)
        $job.state | Should -Be 'Failed'
        $job.error | Should -Match 'requested server is not present'
        $input.server = 'SYNTHETIC-MAIL-01'
        $known = Request '/api/reports' 'POST' $input
        (WaitJob (($known.Content | ConvertFrom-Json).id)).state | Should -Be 'Completed'
    }

    It 'labels explicit Edge Transport usage and detailed reports correctly' {
        $edgeReady = Join-Path $work 'edge-ready.json'
        $edgeReports = Join-Path $work 'edge-reports'
        $edgeProcess = Start-Process -FilePath $exe -ArgumentList @('--database', "`"$database`"", '--reports', "`"$edgeReports`"", '--port', '0', '--no-browser', '--edge', '--ready-file', "`"$edgeReady`"", '--ready-file-with-token') -PassThru -RedirectStandardOutput (Join-Path $work 'edge-stdout.log') -RedirectStandardError (Join-Path $work 'edge-stderr.log')
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath $edgeReady)) {
                if ($edgeProcess.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Edge host did not start.' }
                Start-Sleep -Milliseconds 100
            }
            $info = Get-Content -LiteralPath $edgeReady -Raw | ConvertFrom-Json
            $h = @{ 'X-Portal-Token' = $info.token }
            foreach ($reportType in @('Usage', 'Detailed')) {
                $input = @{ start = '2026-10-14T00:00:00Z'; end = '2026-10-15T00:00:00Z'; reportType = $reportType; timeZone = 'UTC' } | ConvertTo-Json -Compress
                $result = Invoke-RestMethod -Uri ($info.url + '/api/reports') -Headers $h -Method Post -Body $input -ContentType 'application/json'
                $deadline = [DateTime]::UtcNow.AddSeconds(30)
                do {
                    $job = Invoke-RestMethod -Uri ($info.url + "/api/jobs/$($result.id)") -Headers $h
                    if ([DateTime]::UtcNow -gt $deadline) { throw 'Edge report timed out.' }
                    if ($job.state -eq 'Running') { Start-Sleep -Milliseconds 100 }
                } while ($job.state -eq 'Running')
                $job.state | Should -Be 'Completed' -Because $job.error
                $report = Invoke-RestMethod -Uri ($info.url + "/api/reports/$($result.id)") -Headers $h
                $report.edge | Should -BeTrue
                $report.title | Should -Be ('Edge Transport ' + $reportType.ToLowerInvariant() + ' report')
            }
            [void](Invoke-RestMethod -Uri ($info.url + '/api/shutdown') -Headers $h -Method Post)
            $edgeProcess.WaitForExit(10000) | Should -BeTrue
        } finally {
            if (-not $edgeProcess.HasExited) { Stop-Process -Id $edgeProcess.Id -Force }
        }
    }

    It 'persists all engine rows even when the HTML row cap is one' {
        $output = Join-Path $work 'row-cap-test'
        $q = [ExchangeLogReport.ReportRequest]::new()
        $q.StartMs = [DateTimeOffset]::Parse('2026-10-14T00:00:00Z').ToUnixTimeMilliseconds()
        $q.EndMs = [DateTimeOffset]::Parse('2026-10-15T00:00:00Z').ToUnixTimeMilliseconds()
        $q.OutputFolder = $output
        $q.PortalDatabasePath = Join-Path $output 'report.sqlite'
        $q.WriteCsv = $false
        $q.WriteHtml = $true
        $q.MaxHtmlRows = 1
        $readStore = [ExchangeLogReport.Store]::new($database, $true, 'synthetic-test')
        try { $result = [ExchangeLogReport.ReportBuilder]::Build($readStore, $q) } finally { $readStore.Dispose() }
        $result.HtmlPath | Should -BeNullOrEmpty
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$($q.PortalDatabasePath);Mode=ReadOnly;Pooling=False")
        try {
            $db.Open()
            $command = $db.CreateCommand()
            try {
                $command.CommandText = "SELECT count(*) FROM report_rows WHERE dataset='users';"
                $command.ExecuteScalar() | Should -Be 205
            } finally { $command.Dispose() }
        } finally { $db.Dispose() }
    }

    It 'makes source-open failures pollable' {
        $held = [IO.File]::Open($database, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $input = @{ start = '2026-10-14T00:00:00Z'; end = '2026-10-15T00:00:00Z'; reportType = 'Usage'; timeZone = 'UTC' }
            $first = Request '/api/reports' 'POST' $input
            $first.StatusCode | Should -Be 202
            $job = WaitJob (($first.Content | ConvertFrom-Json).id)
            $job.state | Should -Be 'Failed'
            $job.error | Should -Match 'Checking read-only source schema'
        } finally { $held.Dispose() }
    }

    It 'rejects old schemas before Store can migrate and preserves old source bytes' {
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$database;Pooling=False")
        try {
            $db.Open()
            Set-LegacyStorageFixture $db 6
        } finally { $db.Dispose() }
        $oldHash = (Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash
        $status = (Request '/api/status').Content | ConvertFrom-Json
        $status.schemaVersion | Should -Be '6'
        $status.requiresMigration | Should -BeTrue
        $result = Request '/api/reports' 'POST' @{ start = '2026-10-14T00:00:00Z'; end = '2026-10-15T00:00:00Z'; reportType = 'Usage'; timeZone = 'UTC' }
        $result.StatusCode | Should -Be 202
        $job = WaitJob (($result.Content | ConvertFrom-Json).id)
        $job.state | Should -Be 'Failed'
        $job.error | Should -Match 'never migrates'
        (Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash | Should -Be $oldHash
    }

    It 'keeps status available for a missing source and reports failed builds' {
        $moved = $database + '.moved'
        [IO.File]::Move($database, $moved)
        try {
            $response = Request '/api/status'
            $response.StatusCode | Should -Be 200
            ($response.Content | ConvertFrom-Json).databaseAvailable | Should -BeFalse
            $result = Request '/api/reports' 'POST' @{ start = '2026-10-14T00:00:00Z'; end = '2026-10-15T00:00:00Z'; reportType = 'Usage'; timeZone = 'UTC' }
            $job = WaitJob (($result.Content | ConvertFrom-Json).id)
            $job.state | Should -Be 'Failed'
            $job.error | Should -Match 'does not exist'
        } finally { [IO.File]::Move($moved, $database) }
    }

    It 'recognizes committed snapshots on restart independently of source schema' {
        $restartReady = Join-Path $work 'restart-ready.json'
        $restart = Start-Process -FilePath $exe -ArgumentList @('--database', "`"$database`"", '--reports', "`"$reportsPath`"", '--port', '0', '--no-browser', '--ready-file', "`"$restartReady`"", '--ready-file-with-token') -PassThru -RedirectStandardOutput (Join-Path $work 'restart-stdout.log') -RedirectStandardError (Join-Path $work 'restart-stderr.log')
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath $restartReady)) {
                if ($restart.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Restart host did not start.' }
                Start-Sleep -Milliseconds 100
            }
            $info = Get-Content -LiteralPath $restartReady -Raw | ConvertFrom-Json
            $h = @{ 'X-Portal-Token' = $info.token }
            $list = Invoke-RestMethod -Uri ($info.url + '/api/reports') -Headers $h
            $list.id | Should -Contain $script:reportId
            $metadata = Invoke-RestMethod -Uri ($info.url + "/api/reports/$script:reportId") -Headers $h
            ($metadata.datasets | Where-Object name -EQ 'users').total | Should -Be 205
            [void](Invoke-RestMethod -Uri ($info.url + '/api/shutdown') -Headers $h -Method Post)
            $restart.WaitForExit(10000) | Should -BeTrue
        } finally {
            if (-not $restart.HasExited) { Stop-Process -Id $restart.Id -Force }
        }
    }

    It 'uses fresh capabilities per process and defaults ready files to token-free' {
        $secondReady = Join-Path $work 'second-ready.json'
        $second = Start-Process -FilePath $exe -ArgumentList @('--database', "`"$database`"", '--reports', "`"$reportsPath`"", '--port', '0', '--no-browser', '--ready-file', "`"$secondReady`"") -PassThru -RedirectStandardOutput (Join-Path $work 'second-stdout.log') -RedirectStandardError (Join-Path $work 'second-stderr.log')
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath $secondReady)) {
                if ($second.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Second host did not start.' }
                Start-Sleep -Milliseconds 100
            }
            $secondInfo = Get-Content -LiteralPath $secondReady -Raw | ConvertFrom-Json
            $secondInfo.PSObject.Properties.Name | Should -Not -Contain 'token'
            $logs = Get-Content (Join-Path $work 'second-stdout.log') -Raw
            $logs | Should -Not -Match '#token='
            $response = Invoke-WebRequest -Uri ($secondInfo.url + '/api/reports') -Headers $headers -SkipHttpErrorCheck
            $response.StatusCode | Should -Be 401
        } finally {
            if (-not $second.HasExited) { Stop-Process -Id $second.Id -Force }
        }
    }
}

AfterAll {
    if ($process -and -not $process.HasExited) {
        try {
            [void](Request '/api/shutdown' 'POST')
            if (-not $process.WaitForExit(10000)) { Stop-Process -Id $process.Id -Force }
        } catch {
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
            throw
        }
    }
    $env:PATH = $oldPath
    if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Force -Recurse }
}
