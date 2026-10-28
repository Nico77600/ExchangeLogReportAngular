#Requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$Database
)
BeforeAll {
    $script:Package = [IO.Path]::GetFullPath($PackageRoot)
    $script:Database = [IO.Path]::GetFullPath($Database)
    $script:Ready = Join-Path $TestDrive 'ready.json'
    $script:ReportRoot = Join-Path $TestDrive 'snapshots'
    $script:SourceHash = (Get-FileHash -LiteralPath $script:Database -Algorithm SHA256).Hash
    $arguments = @('--database', "`"$script:Database`"", '--reports', "`"$script:ReportRoot`"",
        '--port', '0', '--no-browser', '--ready-file', "`"$script:Ready`"", '--ready-file-with-token')
    $savedPath = $env:PATH
    $savedRoot = $env:DOTNET_ROOT
    $savedLookup = $env:DOTNET_MULTILEVEL_LOOKUP
    try {
        $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
        $env:DOTNET_ROOT = Join-Path $TestDrive 'no-installed-dotnet'
        $env:DOTNET_MULTILEVEL_LOOKUP = '0'
        $script:HostProcess = Start-Process -FilePath (Join-Path $script:Package 'host\ExchangeLogReportAngular.exe') `
            -ArgumentList $arguments -PassThru -RedirectStandardOutput (Join-Path $TestDrive 'host.stdout.txt') `
            -RedirectStandardError (Join-Path $TestDrive 'host.stderr.txt')
    } finally {
        $env:PATH = $savedPath
        $env:DOTNET_ROOT = $savedRoot
        $env:DOTNET_MULTILEVEL_LOOKUP = $savedLookup
    }
    $deadline = [datetime]::UtcNow.AddSeconds(45)
    while (-not (Test-Path -LiteralPath $script:Ready) -and [datetime]::UtcNow -lt $deadline -and -not $script:HostProcess.HasExited) {
        Start-Sleep -Milliseconds 200
    }
    if (-not (Test-Path -LiteralPath $script:Ready)) {
        throw "The packaged host failed to start: $(Get-Content -LiteralPath (Join-Path $TestDrive 'host.stderr.txt') -Raw)"
    }
    $ready = Get-Content -LiteralPath $script:Ready -Raw | ConvertFrom-Json
    $script:Url = $ready.url.TrimEnd('/')
    $script:Headers = @{ 'X-Portal-Token' = $ready.token }
    function Api-Response([string]$Path, [string]$Method = 'GET', [string]$Body) {
        $parameters = @{ Uri = "$script:Url$Path"; Method = $Method; Headers = $script:Headers; SkipHttpErrorCheck = $true }
        if ($Body) { $parameters.ContentType = 'application/json'; $parameters.Body = $Body }
        Invoke-WebRequest @parameters
    }
}
AfterAll {
    if ($script:HostProcess -and -not $script:HostProcess.HasExited) {
        try { Api-Response '/api/shutdown' -Method POST -Body '{}' | Out-Null }
        finally {
            if (-not $script:HostProcess.WaitForExit(10000)) { Stop-Process -Id $script:HostProcess.Id }
        }
    }
}
Describe 'Portable Angular report portal' {
    It 'serves an actual Angular build from a self-contained loopback host' {
        $script:HostProcess.HasExited | Should -BeFalse
        ([uri]$script:Url).Host | Should -Be '127.0.0.1'
        $response = Invoke-WebRequest -Uri "$script:Url/"
        $response.StatusCode | Should -Be 200
        $response.Content | Should -Match '<app-root>'
        $response.Content | Should -Match 'main-[A-Z0-9]+\.js'
        $response.Content | Should -Not -Match 'data-beasties-media'
        ([regex]::Matches($response.Content, '<script(?![^>]*\bsrc=)[^>]*>')).Count | Should -Be 1
        $response.Headers['Content-Security-Policy'] | Should -Match "frame-ancestors 'none'"
    }
    It 'requires the per-launch token and rejects a foreign origin' {
        (Invoke-WebRequest -Uri "$script:Url/api/status" -SkipHttpErrorCheck).StatusCode | Should -Be 401
        $foreign = @{ 'X-Portal-Token' = $script:Headers['X-Portal-Token']; Origin = 'https://example.test' }
        (Invoke-WebRequest -Uri "$script:Url/api/status" -Headers $foreign -SkipHttpErrorCheck).StatusCode | Should -Be 403
        (Api-Response '/api/not-a-route').StatusCode | Should -Be 404
    }
    It 'reports the existing source database as read-only' {
        $status = (Api-Response '/api/status').Content | ConvertFrom-Json
        $status.databaseAvailable | Should -BeTrue
        $status.readOnly | Should -BeTrue
        $status.sourceVersion | Should -Be '2.0.1'
    }
    It 'exposes only a read-only user-initiated SQLite footprint diagnostic' {
        $response = Api-Response '/api/storage/audit'
        $response.StatusCode | Should -Be 200
        $audit = $response.Content | ConvertFrom-Json
        $audit.dbstatAvailable | Should -BeTrue
        $audit.objects.name | Should -Contain 'message_event'
        (Api-Response '/api/storage/vacuum' -Method POST -Body '{}').StatusCode | Should -Be 404
        (Get-FileHash -LiteralPath $script:Database -Algorithm SHA256).Hash | Should -Be $script:SourceHash
    }
    It 'builds a complete Detailed snapshot through the preserved engine without report HTML' {
        $request = @{
            start = [datetimeoffset]::UtcNow.AddDays(-7).ToString('o')
            end = [datetimeoffset]::UtcNow.AddDays(1).ToString('o')
            reportType = 'Detailed'; user = ''; server = ''; timeZone = 'Europe/Paris'
        } | ConvertTo-Json
        $response = Api-Response '/api/reports' -Method POST -Body $request
        $response.StatusCode | Should -Be 202
        $job = $response.Content | ConvertFrom-Json
        $deadline = [datetime]::UtcNow.AddSeconds(120)
        do {
            Start-Sleep -Milliseconds 250
            $job = (Api-Response "/api/jobs/$($job.id)").Content | ConvertFrom-Json
        } while ($job.state -eq 'Running' -and [datetime]::UtcNow -lt $deadline)
        $job.state | Should -Be 'Completed' -Because $job.error
        $script:ReportId = $job.reportId
        $script:Report = (Api-Response "/api/reports/$script:ReportId").Content | ConvertFrom-Json
        $script:Report.detailed | Should -BeTrue
        $script:Report.datasets.name | Should -Contain 'messages'
        $script:Report.datasets.name | Should -Contain 'sessions'
        @(Get-ChildItem -LiteralPath $script:ReportRoot -Recurse -Filter '*.html').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:ReportRoot -Recurse -Filter '*.csv').Count | Should -BeGreaterThan 0
        (Get-FileHash -LiteralPath $script:Database -Algorithm SHA256).Hash | Should -Be $script:SourceHash
    }
    It 'paginates without moving the entire dataset into the browser' {
        $response = Api-Response "/api/reports/$script:ReportId/datasets/messages?offset=0&limit=2&sort=0&descending=false"
        $response.StatusCode | Should -Be 200
        $first = $response.Content | ConvertFrom-Json
        $first.rows.Count | Should -Be 2
        $first.total | Should -BeGreaterThan 2
        $second = (Api-Response "/api/reports/$script:ReportId/datasets/messages?offset=2&limit=2&sort=0&descending=false").Content | ConvertFrom-Json
        $second.rows[0].id | Should -Not -BeIn @($first.rows.id)
        $second.total | Should -Be $first.total
    }
    It 'uses literal parameterized search and validates requested columns and page bounds' {
        $needle = [uri]::EscapeDataString("%' OR 1=1 --")
        $page = (Api-Response "/api/reports/$script:ReportId/datasets/messages?offset=0&limit=50&q=$needle&sort=0").Content | ConvertFrom-Json
        $page.total | Should -Be 0
        (Api-Response "/api/reports/$script:ReportId/datasets/messages?limit=201").StatusCode | Should -Be 400
        (Api-Response "/api/reports/$script:ReportId/datasets/messages?sort=999").StatusCode | Should -Be 400
        (Api-Response "/api/reports/$script:ReportId/datasets/not-a-dataset").StatusCode | Should -Be 404
    }
    It 'exports all matching CSV rows rather than only the selected page' {
        $page = (Api-Response "/api/reports/$script:ReportId/datasets/messages?limit=2").Content | ConvertFrom-Json
        $csv = Api-Response "/api/reports/$script:ReportId/datasets/messages/csv?sort=0"
        $csv.StatusCode | Should -Be 200
        $csv.Headers['Content-Disposition'] | Should -Match 'attachment'
        $text = if ($csv.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($csv.Content) } else { [string]$csv.Content }
        $text = $text.TrimStart([char]0xFEFF)
        @($text | ConvertFrom-Csv -Delimiter ';').Count | Should -Be $page.total
    }
    It 'rejects invalid report ranges without changing source bytes' {
        $bad = @{ start = '2026-10-15T00:00:00Z'; end = '2026-10-14T00:00:00Z'; reportType = 'Detailed'; timeZone = 'UTC' } | ConvertTo-Json
        (Api-Response '/api/reports' -Method POST -Body $bad).StatusCode | Should -Be 400
        (Get-FileHash -LiteralPath $script:Database -Algorithm SHA256).Hash | Should -Be $script:SourceHash
    }
}
