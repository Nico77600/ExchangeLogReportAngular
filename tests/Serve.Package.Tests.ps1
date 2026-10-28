#Requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$Database
)
BeforeAll {
    $ErrorActionPreference = 'Stop'
    $script:Package = [IO.Path]::GetFullPath($PackageRoot)
    $script:Database = [IO.Path]::GetFullPath($Database)
    $script:SourceHash = (Get-FileHash -LiteralPath $script:Database).Hash
    $script:ReadyPath = Join-Path $TestDrive 'ready.json'
    $script:ResultFile = Join-Path $TestDrive 'http-timings.json'
    $saved = @{ PATH = $env:PATH; DOTNET_ROOT = $env:DOTNET_ROOT; DOTNET_MULTILEVEL_LOOKUP = $env:DOTNET_MULTILEVEL_LOOKUP }
    try {
        $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
        $env:DOTNET_ROOT = Join-Path $TestDrive 'no-installed-runtime'
        $env:DOTNET_MULTILEVEL_LOOKUP = '0'
        $arguments = @('-NoLogo', '-NoProfile', '-File', "`"$(Join-Path $script:Package 'collector\Invoke-ExchangeLogReport.ps1')`"",
            '-Mode', 'Serve', '-DatabasePath', "`"$script:Database`"", '-WebRoot', "`"$(Join-Path $script:Package 'web')`"",
            '-Port', '0', '-NoBrowser', '-ReadyFile', "`"$script:ReadyPath`"", '-ReadyFileWithToken')
        $script:Process = Start-Process -FilePath (Join-Path $script:Package 'powershell\pwsh.exe') -ArgumentList $arguments `
            -PassThru -RedirectStandardOutput (Join-Path $TestDrive 'stdout.txt') -RedirectStandardError (Join-Path $TestDrive 'stderr.txt')
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
    $deadline = [datetime]::UtcNow.AddSeconds(60)
    while (-not (Test-Path -LiteralPath $script:ReadyPath) -and -not $script:Process.HasExited -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $script:ReadyPath)) {
        throw "Portable Serve failed to start: $(Get-Content -LiteralPath (Join-Path $TestDrive 'stderr.txt') -Raw)"
    }
    $ready = Get-Content -LiteralPath $script:ReadyPath -Raw | ConvertFrom-Json
    if ($ready.status -ne 'ready') { throw "Serve is blocked: $($ready.message)" }
    $script:Url = $ready.url.TrimEnd('/')
    $script:Headers = @{ 'X-Portal-Token' = $ready.token }
    $meta = Invoke-RestMethod -Uri ($script:Url + '/api/meta') -Headers $script:Headers
    if ($meta.requiresMigration -or -not $meta.coveredFrom -or -not $meta.coveredTo) {
        throw 'Packaged Serve tests require a compatible synthetic database with recorded source coverage.'
    }
    $from = [DateTimeOffset]::Parse($meta.coveredFrom, [Globalization.CultureInfo]::InvariantCulture)
    $to = [DateTimeOffset]::Parse($meta.coveredTo, [Globalization.CultureInfo]::InvariantCulture).AddMilliseconds(1)
    $script:Filter = '?from=' + [Uri]::EscapeDataString($from.ToString('O')) +
        '&to=' + [Uri]::EscapeDataString($to.ToString('O'))
    function Serve-Request([string]$Path) {
        Invoke-WebRequest -Uri ($script:Url + $Path) -Headers $script:Headers -SkipHttpErrorCheck
    }
}
AfterAll {
    if ($script:Process -and -not $script:Process.HasExited) {
        try { Invoke-WebRequest -Uri ($script:Url + '/api/shutdown') -Method Post -Headers $script:Headers | Out-Null }
        finally { if (-not $script:Process.WaitForExit(15000)) { Stop-Process -Id $script:Process.Id } }
    }
}
Describe 'Packaged HttpListener Serve' {
    It 'uses the real portable runtime and serves the compiled lazy Angular application' {
        $manifest = Get-Content -LiteralPath (Join-Path $script:Package 'PackageIntegrity.json') -Raw | ConvertFrom-Json
        $manifest.files.path | Should -Contain 'collector\README.md'
        $readme = Get-Content -LiteralPath (Join-Path $script:Package 'collector\README.md') -Raw
        $readme | Should -Match '## Requirements'
        $readme | Should -Match '## Disclaimer'
        $html = Serve-Request '/'
        $html.StatusCode | Should -Be 200
        $html.Content | Should -Match '<app-root>'
        $html.Content | Should -Match 'main-[A-Z0-9]+\.js'
        $meta = (Serve-Request '/api/meta').Content | ConvertFrom-Json
        $meta.mode | Should -Be 'Serve'
        $meta.version | Should -Be '0.3.0'
        $meta.schemaVersion | Should -Be 11
        $meta.requiresMigration | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $script:Package 'collector') -Filter '*.dll' -Recurse -File |
            Where-Object FullName -Match '\\bin\\').Count | Should -Be 0
    }
    It 'supports directly reopened filtered SPA URLs but never exposes arbitrary files' {
        (Serve-Request ('/messages' + $script:Filter + '&page=1&size=100')).StatusCode | Should -Be 200
        (Serve-Request '/api/not-a-route').StatusCode | Should -Be 404
        (Serve-Request '/collector/config/ExchangeLogReport.config.psd1').StatusCode | Should -Not -Be 200
        (Invoke-WebRequest -Uri ($script:Url + '/api/meta') -SkipHttpErrorCheck).StatusCode | Should -Be 401
    }
    It 'loads only bounded list pages with no transcripts and measures the selected dataset honestly' {
        $timings = foreach ($view in @('messages', 'sessions', 'smtp/clients')) {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $response = Serve-Request ("/api/$view" + $script:Filter + '&size=50&page=1')
            $watch.Stop()
            $response.StatusCode | Should -Be 200
            $body = $response.Content | ConvertFrom-Json
            @($body.rows).Count | Should -BeLessOrEqual 50
            $body.columns.name | Should -Not -Contain 'SMTP transcripts'
            [pscustomobject]@{ view = $view; milliseconds = $watch.Elapsed.TotalMilliseconds; rows = @($body.rows).Count }
        }
        $timings | ConvertTo-Json | Set-Content -LiteralPath $script:ResultFile -Encoding utf8
        foreach ($timing in $timings) { $timing.milliseconds | Should -BeLessThan 1000 -Because $timing.view }
    }
    It 'serves the hourly Overview from the delivered collector source' {
        $response = Serve-Request ('/api/overview' + $script:Filter)
        $response.StatusCode | Should -Be 200
        $body = $response.Content | ConvertFrom-Json
        $body.columns[0].name | Should -BeExactly 'Hour'
        $body.columns[9].name | Should -BeExactly 'Retained access requests'
        @($body.rows).Count | Should -BeGreaterThan 0
        @($body.rows).Count | Should -BeLessOrEqual 10000
        $body.basis | Should -Match 'exact BINARY Message-IDs distinct within each bin'
        (Get-FileHash -LiteralPath $script:Database).Hash | Should -Be $script:SourceHash
    }
    It 'loads a selected message detail without building any Detailed report file' {
        $page = (Serve-Request ('/api/messages' + $script:Filter + '&size=1&page=1')).Content | ConvertFrom-Json
        @($page.rows).Count | Should -Be 1
        $detail = (Serve-Request ("/api/messages/$($page.rows[0].id)" + $script:Filter)).Content | ConvertFrom-Json
        $detail.id | Should -Be $page.rows[0].id
        $detail.columns.name | Should -Contain 'Route'
        Test-Path -LiteralPath (Join-Path $script:Package 'reports') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Package 'collector\reports') | Should -BeFalse
        (Get-FileHash -LiteralPath $script:Database).Hash | Should -Be $script:SourceHash
    }
}
