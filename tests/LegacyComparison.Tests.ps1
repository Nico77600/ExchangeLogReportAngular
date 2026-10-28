#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }
param([Parameter(Mandatory)][string]$WorkRoot)

BeforeAll {
    $script:Harness = Join-Path $PSScriptRoot 'Measure-LegacyComparison.ps1'
    . (Join-Path $PSScriptRoot 'support\LegacyComparison.Execution.ps1')
    $tokens = $null; $parseErrors = $null
    $script:Ast = [Management.Automation.Language.Parser]::ParseFile($script:Harness, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors.Message -join "`n") }
    # Load only pure helpers: never invoke preparation, generation or an engine.
    foreach ($function in $script:Ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $script:Work = Assert-ComparisonLocalPath $WorkRoot
    if (Test-Path -LiteralPath $script:Work) { throw 'Use a fresh evidence WorkRoot for the targeted semantic tests.' }
    [void][IO.Directory]::CreateDirectory($script:Work)
    $script:End = [datetimeoffset]::new([datetime]::UtcNow.Date.AddDays(-1))
    $script:FakeLegacy = Join-Path $script:Work 'public-source'
    [void][IO.Directory]::CreateDirectory((Join-Path $script:FakeLegacy '.git'))
    [void][IO.Directory]::CreateDirectory((Join-Path $script:FakeLegacy 'package'))
    [IO.File]::WriteAllText((Join-Path $script:FakeLegacy 'package\ExchangeLogReport.psd1'), "@{ ModuleVersion = '2.1.1' }")
    $script:Commit = 'a' * 40
}

AfterAll {
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) {
        Remove-Item -LiteralPath $script:Work -Recurse -Force
    }
}

Describe 'Bounded synthetic comparison preparation' {
    It 'has no parser errors and makes generation opt-in with tiny bounded defaults' {
        $parameters = $script:Ast.ParamBlock.Parameters
        ($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Scale' }).DefaultValue.Value | Should -Be 0.001
        ($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ServerCount' }).DefaultValue.Value | Should -Be 1
        ($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Days' }).DefaultValue.Value | Should -Be 7
        ($parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'GenerateLogs' }).DefaultValue | Should -BeNullOrEmpty
    }

    It 'does not contain any engine, database, report, listener or Git write invocation' {
        $commands = @($script:Ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() })
        foreach ($name in @('Import-Module', 'Open-ExlStore', 'Invoke-ExlCollection', 'New-ExlReport',
                'Start-ExlServe', 'Invoke-ExlDiscovery', 'Invoke-ExlRetention', 'Invoke-WebRequest',
                'Invoke-RestMethod', 'Send-MailMessage')) {
            $commands | Should -Not -Contain $name
        }
        $script:Ast.Extent.Text | Should -Not -Match '(?im)^\s*&?\s*git\s+(fetch|reset|commit|push|pull)\b'
        $script:Ast.Extent.Text | Should -Match 'comparisonCompleted = \$false'
    }

    It 'rejects unsafe path <Path>' -ForEach @(
        @{ Path = '\\server\share\logs' }, @{ Path = 'relative\logs' },
        @{ Path = 'C:\evidence\..\logs' }, @{ Path = 'C:\evidence\alternate:stream' },
        @{ Path = 'C:\evidence\file.' }, @{ Path = 'C:\evidence\file ' },
        @{ Path = 'C:\' }, @{ Path = 'C:/evidence' }, @{ Path = 'C:\evidence\*' }
    ) {
        { Assert-ComparisonLocalPath $Path } | Should -Throw
    }

    It 'compares directory boundaries rather than a permissive string prefix' {
        Test-ComparisonWithin 'C:\sources\legacy\package' 'C:\sources\legacy' | Should -BeTrue
        Test-ComparisonWithin 'C:\sources\legacy-copy' 'C:\sources\legacy' | Should -BeFalse
        Test-ComparisonWithin 'C:\SOURCES\LEGACY' 'C:\sources\legacy' | Should -BeTrue
    }

    It 'preserves tiny limits unless representative execution is explicit' {
        $limits = Get-ComparisonWorkloadLimits $false 0.001 1 40 300 1536 0
        $limits.maximumLogBytes | Should -Be 64MB
        $limits.maximumOutputBytes | Should -Be 512MB
        $limits.generatorTimeoutSeconds | Should -Be 180
        { Get-ComparisonWorkloadLimits $false 0.01 1 40 300 1536 0 } | Should -Throw '*Representative*'
        { Get-ComparisonWorkloadLimits $false 0.001 3 40 300 1536 0 } | Should -Throw '*Representative*'
        { Get-ComparisonWorkloadLimits $false 0.001 1 4000 300 1536 0 } | Should -Throw '*Representative*'
        { Get-ComparisonWorkloadLimits $false 0.001 1 40 14400 8192 24 } | Should -Throw '*Representative*'
    }

    It 'keeps representative generation, output, memory and disk bounded' {
        $limits = Get-ComparisonWorkloadLimits $true 1 2 4000 14400 8192 24
        $limits.maximumLogBytes | Should -Be 160GB
        $limits.maximumOutputBytes | Should -Be 384GB
        $limits.generatorTimeoutSeconds | Should -Be 14400
        $limits.minimumFreeDiskBytes | Should -Be 32GB
        $limits.minimumFreeMemoryBytes | Should -Be 2GB
        { Assert-ComparisonResourceReserve $script:Work ([long]::MaxValue) 0 } | Should -Throw '*free-disk reserve*'
    }

    It 'uses the same exact seven-day UTC interval within seven or fourteen fixture days' {
        foreach ($days in @(7, 14)) {
            $period = Get-ComparisonPeriod $script:End $days
            ([datetimeoffset]$period.reportEndExclusive - [datetimeoffset]$period.reportStart).TotalDays | Should -Be 7
            ([datetimeoffset]$period.fixtureEndExclusive - [datetimeoffset]$period.fixtureStart).TotalDays | Should -Be $days
            [datetimeoffset]$period.reportStart | Should -BeGreaterOrEqual ([datetimeoffset]$period.fixtureStart)
            $period.timeZone | Should -Be 'UTC'
            $period.intervalConvention | Should -Be '[start,end)'
        }
    }

    It 'refuses a non-UTC, partial-hour, future, stale or too-short fixture period' {
        { Get-ComparisonPeriod ($script:End.ToOffset([timespan]::FromHours(2))) 7 } | Should -Throw
        { Get-ComparisonPeriod ($script:End.AddSeconds(1)) 7 } | Should -Throw
        { Get-ComparisonPeriod ($script:End.AddDays(4)) 7 } | Should -Throw
        { Get-ComparisonPeriod ($script:End.AddDays(-365)) 7 } | Should -Throw
        { Get-ComparisonPeriod $script:End 2 } | Should -Throw
    }

    It 'writes only local synthetic sources and independent output roots with mail disabled' {
        $logs = Join-Path $script:Work "shared'fixture"
        $configs = foreach ($engine in @('legacy', 'angular')) {
            $work = Join-Path $script:Work $engine
            $path = Join-Path $script:Work "$engine.config.psd1"
            [IO.File]::WriteAllText($path, (New-ComparisonConfigText $logs $work @('SYNTH01') @{ SystemUserPatterns = @('^HealthMailbox', "apostrophe'pattern") }))
            $config = Import-PowerShellDataFile -LiteralPath $path
            $config.Mail.Enabled | Should -BeFalse
            $config.Mail.SmtpServer | Should -BeNullOrEmpty
            $config.Collection.Parallelism | Should -Be 1
            $config.Report.TimeZone | Should -Be 'UTC'
            $config.Report.Formats | Should -Be @('Csv', 'Html')
            $config.Report.MaxDataAgeMinutes | Should -Be 0
            $config.Noise.SystemUserPatterns[1] | Should -Be "apostrophe'pattern"
            Test-ComparisonWithin $config.Servers[0].ExchangePath $logs | Should -BeTrue
            Test-ComparisonWithin $config.Storage.DatabasePath $work | Should -BeTrue
            $config.Storage.DatabasePath
        }
        $configs[0] | Should -Not -Be $configs[1]
    }

    It 'hashes actual fixture bytes and detects changed content without padding' {
        $fixture = Join-Path $script:Work 'hash-fixture'
        [void][IO.Directory]::CreateDirectory($fixture)
        $file = Join-Path $fixture 'synthetic.log'
        [IO.File]::WriteAllText($file, 'synthetic-only')
        $before = @(Get-ComparisonInventory $fixture @('.'))
        $before.Count | Should -Be 1
        $before[0].bytes | Should -Be 14
        $before[0].sha256 | Should -Be (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        [IO.File]::WriteAllText($file, 'different')
        $after = @(Get-ComparisonInventory $fixture @('.'))
        $after[0].sha256 | Should -Not -Be $before[0].sha256
    }

    It 'leaves all unperformed metrics pending and distinguishes HTTP from browser readiness' {
        $rows = @(Get-ComparisonPendingMeasurements)
        $rows.Count | Should -Be 12
        @($rows | Where-Object status -NE 'PENDING').Count | Should -Be 0
        @($rows | Where-Object { $null -ne $_.measurement }).Count | Should -Be 0
        $rows.metric | Should -Contain 'angular.serve.http-first'
        $rows.metric | Should -Contain 'angular.serve.http-warm'
        $rows.metric | Should -Contain 'angular.browser-ready'
        $rows.metric | Should -Contain 'legacy.detailed-seven-days'
        ($rows | Where-Object metric -EQ 'angular.browser-ready').requirement | Should -Match 'not inferred from HTTP'
    }

    It 'never overwrites a CreateNew evidence file' {
        $path = Join-Path $script:Work 'receipt.json'
        Write-ComparisonJson $path @{ status = 'PENDING' } -CreateNew
        { Write-ComparisonJson $path @{ status = 'PASS' } -CreateNew } | Should -Throw
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).status | Should -Be 'PENDING'
    }
}

Describe 'Explicit offline public legacy designation' {
    BeforeEach {
        $script:GitOrigin = 'https://github.com/Nico77600/ExchangeLogReport.git'
        $script:GitDirty = ''; $script:GitHead = $script:Commit; $script:GitMain = $script:Commit
        Mock Invoke-ComparisonGit {
            switch ($Arguments -join '|') {
                'rev-parse|--show-toplevel' { $script:FakeLegacy }
                'config|--get|remote.origin.url' { $script:GitOrigin }
                'status|--porcelain=v1|--untracked-files=all' { $script:GitDirty }
                'rev-parse|HEAD' { $script:GitHead }
                'rev-parse|refs/remotes/origin/main' { $script:GitMain }
                default { throw 'Unexpected git invocation in semantic test.' }
            }
        }
    }
        Describe 'Isolated synthetic execution guards' {
            It 'parses both new execution helpers without errors' {
                foreach ($file in @('LegacyComparison.Execution.ps1', 'Invoke-LegacyComparisonChild.ps1')) {
                    $tokens = $null; $errors = $null
                    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "support\$file"), [ref]$tokens, [ref]$errors)
                    $errors.Count | Should -Be 0
                }
            }

            It 'enumerates exactly seven expected local source jobs per actual server' {
                $logs = Join-Path $script:Work 'expected-logs'
                $sources = @(Get-ComparisonExpectedSources $logs @('SYNTH01', 'SYNTH02'))
                $sources.Count | Should -Be 14
                @($sources | Where-Object server -EQ 'SYNTH01').Count | Should -Be 7
                @($sources | Where-Object server -EQ 'SYNTH02').Count | Should -Be 7
                @($sources | Where-Object folder -Match ',|^\\\\').Count | Should -Be 0
                @($sources | Where-Object kind -EQ 'Tracking').filter | Should -Be @('MSGTRK*.log', 'MSGTRK*.log')
            }

            It 'rejects execution paths outside the owned synthetic root' {
                { Assert-ComparisonExecutionPath 'C:\other\real.sqlite' $script:Work } | Should -Throw '*escapes*'
                { Assert-ComparisonExecutionPath '\\server\share\logs' } | Should -Throw '*Unsafe*'
                { Assert-ComparisonExecutionPath ($script:Work + '\..\other') } | Should -Throw '*Unsafe*'
            }

            It 'detects changed frozen bytes and refuses to heal the inventory' {
                $root = Join-Path $script:Work 'frozen'
                [void][IO.Directory]::CreateDirectory($root)
                $path = Join-Path $root 'synthetic.log'
                [IO.File]::WriteAllText($path, 'original')
                $inventory = @(Get-ComparisonArtifactInventory $root)
                { Assert-ComparisonFrozenInventory $root $inventory @('.') } | Should -Not -Throw
                [IO.File]::WriteAllText($path, 'modified')
                { Assert-ComparisonFrozenInventory $root $inventory @('.') } | Should -Throw '*changed*'
                $inventory[0].sha256 | Should -Not -Be (Get-ComparisonSha256 $path)
            }

            It 'rejects an extra file even when all original frozen hashes still match' {
                $root = Join-Path $script:Work 'extra-input'
                [void][IO.Directory]::CreateDirectory($root)
                [IO.File]::WriteAllText((Join-Path $root 'original.log'), 'original')
                $inventory = @(Get-ComparisonArtifactInventory $root)
                [IO.File]::WriteAllText((Join-Path $root 'unexpected.log'), 'unexpected')
                { Assert-ComparisonFrozenInventory $root $inventory @('.') } | Should -Throw '*Uninventoried*'
            }

            It 'distinguishes an absent sidecar from a measured zero-length sidecar' {
                $database = Join-Path $script:Work 'footprint.sqlite'
                [IO.File]::WriteAllText($database, 'synthetic')
                [IO.File]::WriteAllText(($database + '-wal'), '')
                $value = Get-ComparisonFootprint $database
                $value.database.bytes | Should -Be 9
                $value.wal.exists | Should -BeTrue
                $value.wal.bytes | Should -Be 0
                $value.shm.exists | Should -BeFalse
                $value.shm.bytes | Should -Be 0
            }

            It 'records a vanished mutable SQLite <Suffix> sidecar without relaxing frozen-input enumeration' -ForEach @(
                @{Suffix='wal'},@{Suffix='shm'}
            ) {
                $root = Join-Path $script:Work "vanished-$Suffix"
                [void][IO.Directory]::CreateDirectory($root)
                $sidecar = Join-Path $root "ExchangeLogReport.sqlite-$Suffix"
                [IO.File]::WriteAllText($sidecar, 'synthetic')
                Mock Get-Item {
                    throw [Management.Automation.ItemNotFoundException]::new('Simulated sidecar removal after enumeration.')
                } -ParameterFilter { $LiteralPath -like '*.sqlite-*' }
                $samples = @(Get-ComparisonSafeFiles $root -MutableOutputSample)
                $samples.Count | Should -Be 1
                $samples[0].path | Should -Be $sidecar
                $samples[0].vanishedSidecar | Should -BeTrue
                $samples[0].bytes | Should -BeNullOrEmpty
                @(Get-ComparisonSafeFiles $root) | Should -Be @($sidecar)
                Should -Invoke Get-Item -Times 1 -Exactly
            }

            It 'records a sidecar whose removal surfaces as an invocation exception wrapping FileNotFoundException' -ForEach @(
                @{Suffix='wal'},@{Suffix='shm'}
            ) {
                $root = Join-Path $script:Work "wrapped-$Suffix"
                [void][IO.Directory]::CreateDirectory($root)
                $sidecar = Join-Path $root "ExchangeLogReport.sqlite-$Suffix"
                [IO.File]::WriteAllText($sidecar, 'synthetic')
                Mock Get-Item {
                    throw [Management.Automation.MethodInvocationException]::new('Exception calling "GetAttributes" with "1" argument(s)',
                        [IO.FileNotFoundException]::new('Simulated sidecar removal during Dispose.'))
                } -ParameterFilter { $LiteralPath -like '*.sqlite-*' }
                $samples = @(Get-ComparisonSafeFiles $root -MutableOutputSample)
                $samples.Count | Should -Be 1
                $samples[0].vanishedSidecar | Should -BeTrue
                $samples[0].bytes | Should -BeNullOrEmpty
            }

            It 'still rethrows a wrapped not-found error for an ordinary output and a wrapped access error for a sidecar' {
                $root = Join-Path $script:Work 'wrapped-errors'
                [void][IO.Directory]::CreateDirectory($root)
                $ordinary = Join-Path $root 'ExchangeLogReport.sqlite'
                [IO.File]::WriteAllText($ordinary, 'synthetic')
                Mock Get-Item {
                    throw [Management.Automation.MethodInvocationException]::new('Exception calling "GetAttributes"', [IO.FileNotFoundException]::new('Wrapped missing database.'))
                }
                { Get-ComparisonSafeFiles $root -MutableOutputSample } | Should -Throw '*GetAttributes*'
                [IO.File]::Delete($ordinary)
                [IO.File]::WriteAllText((Join-Path $root 'ExchangeLogReport.sqlite-wal'), 'synthetic')
                Mock Get-Item {
                    throw [Management.Automation.MethodInvocationException]::new('Exception calling "GetAttributes"', [UnauthorizedAccessException]::new('Wrapped denied sidecar.'))
                }
                { Get-ComparisonSafeFiles $root -MutableOutputSample } | Should -Throw '*GetAttributes*'
            }

            It 'never swallows a vanished ordinary output or access-denied sidecar' {
                $root = Join-Path $script:Work 'output-errors'
                [void][IO.Directory]::CreateDirectory($root)
                $ordinary = Join-Path $root 'ExchangeLogReport.sqlite'
                [IO.File]::WriteAllText($ordinary, 'synthetic')
                Mock Get-Item { throw [Management.Automation.ItemNotFoundException]::new('Missing main database.') }
                { Get-ComparisonSafeFiles $root -MutableOutputSample } | Should -Throw '*Missing main database*'
                [IO.File]::Delete($ordinary)
                [IO.File]::WriteAllText((Join-Path $root 'ExchangeLogReport.sqlite-wal'), 'synthetic')
                Mock Get-Item { throw [UnauthorizedAccessException]::new('Denied sidecar access.') }
                { Get-ComparisonSafeFiles $root -MutableOutputSample } | Should -Throw '*Denied sidecar access*'
            }

            It 'samples existing mutable outputs including zero-length sidecars with exact bytes' {
                $root = Join-Path $script:Work 'output-sample'
                [void][IO.Directory]::CreateDirectory($root)
                [IO.File]::WriteAllText((Join-Path $root 'ExchangeLogReport.sqlite'), 'synthetic')
                [IO.File]::WriteAllText((Join-Path $root 'ExchangeLogReport.sqlite-wal'), '')
                $samples = @(Get-ComparisonSafeFiles $root -MutableOutputSample)
                $samples.Count | Should -Be 2
                @($samples | Where-Object vanishedSidecar).Count | Should -Be 0
                ($samples | Measure-Object bytes -Sum).Sum | Should -Be 9
            }

            It 'reads the engine TableResult string-column/object-array contract without DataTable assumptions' {
                $rows = [Collections.Generic.List[object[]]]::new()
                $rows.Add(@('SYNTH01', 7L, [DBNull]::Value))
                $table = [pscustomobject]@{ Columns = @('server', 'files', 'optional'); Rows = $rows }
                $store = [pscustomobject]@{ Result = $table }
                $store | Add-Member -MemberType ScriptMethod -Name Query -Value { param($sql, $parameters) return $this.Result }
                $actual = @(Get-ComparisonQueryRows $store 'SELECT synthetic')
                $actual.Count | Should -Be 1
                $actual[0].server | Should -Be 'SYNTH01'
                $actual[0].files | Should -Be 7
                $actual[0].optional | Should -BeNullOrEmpty
            }

            It 'never promotes HTTP measurements into browser or full parity completion' {
                $record = @{ measurements = @(Get-ComparisonPendingMeasurements) }
                Set-ComparisonMeasuredRow $record 'angular.serve.http-first' @{ milliseconds = 1 }
                ($record.measurements | Where-Object metric -EQ 'angular.serve.http-first').status | Should -Be 'PASS'
                ($record.measurements | Where-Object metric -EQ 'angular.browser-ready').status | Should -Be 'PENDING'
                ($record.measurements | Where-Object metric -EQ 'semantic-equivalence').status | Should -Be 'PENDING'
            }

            It 'uses module APIs only in single-engine child processes without discovery/mail or Collect CLI' {
                $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'support\Invoke-LegacyComparisonChild.ps1') -Raw
                $text | Should -Match 'Invoke-ExlCollection'
                $text | Should -Match 'New-ExlReport'
                $text | Should -Match 'Start-ExlServe'
                $text | Should -Match "collectionStatistics"
                $text | Should -Not -Match 'Invoke-ExchangeLogReport|Invoke-ExlDiscovery|Test-ExlServerAccess|Test-ExlIisSites|Invoke-ExlRetention|Send-Exl.*Mail'
                $text | Should -Not -Match '(?i)ExecutionPolicy|Skip.*Signature|Bypass'
                $text | Should -Match 'PlanSha256'
            }

            It 'matches the frontend empty-body shutdown POST contract rather than sending JSON' {
                ${function:Invoke-ComparisonHttp}.ToString() | Should -Match '\.PostAsync\(\$Path, \[Net.Http.HttpContent\]\$null\)'
                ${function:Invoke-ComparisonHttp}.ToString() | Should -Not -Match 'StringContent'
            }
        }
    It 'records the actual public module version without claiming a fresh remote or identical version' {
        $source = Get-ComparisonLegacyDesignation $script:FakeLegacy $script:Commit
        $source.moduleVersion | Should -Be '2.1.1'
        $source.head | Should -Be $script:Commit
        $source.remoteFreshness | Should -Match 'NOT VERIFIED'
    }

    It 'refuses an unrelated source origin' {
        $script:GitOrigin = 'https://github.com/unrelated/ExchangeLogReport.git'
        { Get-ComparisonLegacyDesignation $script:FakeLegacy $script:Commit } | Should -Throw '*public clone*'
    }

    It 'refuses tracked or untracked changes rather than repairing the source' {
        $script:GitDirty = '?? unreviewed.ps1'
        { Get-ComparisonLegacyDesignation $script:FakeLegacy $script:Commit } | Should -Throw '*dirty*'
    }

    It 'refuses a mismatched HEAD, cached main or explicit commit' {
        $script:GitHead = 'b' * 40
        { Get-ComparisonLegacyDesignation $script:FakeLegacy $script:Commit } | Should -Throw '*LegacyCommit*'
        $script:GitHead = $script:Commit; $script:GitMain = 'b' * 40
        { Get-ComparisonLegacyDesignation $script:FakeLegacy $script:Commit } | Should -Throw '*LegacyCommit*'
        $script:GitMain = $script:Commit
        { Get-ComparisonLegacyDesignation $script:FakeLegacy ('c' * 40) } | Should -Throw '*LegacyCommit*'
    }
}
