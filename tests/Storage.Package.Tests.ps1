#Requires -Version 7.4
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$LegacyDatabase
)
BeforeAll {
    $script:Package = [IO.Path]::GetFullPath($PackageRoot)
    $script:Source = [IO.Path]::GetFullPath($LegacyDatabase)
    $script:Exe = Join-Path $script:Package 'host\ExchangeLogReportAngular.exe'
    $script:Sqlite = Join-Path $script:Package 'sqlite-tools\sqlite3.exe'
    $script:SourceHash = (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash
    $script:SavedPath = $env:PATH
    $script:SavedDotnet = $env:DOTNET_ROOT
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
    $env:DOTNET_ROOT = Join-Path $TestDrive 'no-installed-runtime'
    $script:NativeCall = 0
    function Run-Storage([string[]]$Arguments) {
        $script:NativeCall++
        $stderr = Join-Path $TestDrive "native-$script:NativeCall.stderr.txt"
        $output = & $script:Exe @Arguments 2> $stderr
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $output -join "`n"; Error = Get-Content -LiteralPath $stderr -Raw }
    }
    function Read-Scalar([string]$Path, [string]$Sql) {
        $value = & $script:Sqlite -safe -init NUL -readonly -batch $Path $Sql
        if ($LASTEXITCODE) { throw 'The packaged read-only SQLite probe failed.' }
        return $value -join "`n"
    }
    $script:BeforeCounts = Read-Scalar $script:Source @'
SELECT (SELECT count(*) FROM message_event)||'|'||
(SELECT count(*) FROM smtp_transaction)||'|'||
(SELECT count(*) FROM access_event)||'|'||
(SELECT count(DISTINCT message_id) FROM message_event)||'|'||
(SELECT coalesce(sum(offset),0) FROM source_file);
'@
}
AfterAll {
    $env:PATH = $script:SavedPath
    $env:DOTNET_ROOT = $script:SavedDotnet
}
Describe 'Packaged lossless SQLite maintenance' {
    It 'measures real DBSTAT object sizes without a running portal or source writes' {
        $result = Run-Storage @('--storage-audit', '--database', $script:Source)
        $result.ExitCode | Should -Be 0 -Because $result.Error
        $audit = $result.Text | ConvertFrom-Json
        $audit.dbstatAvailable | Should -BeTrue
        $audit.sqliteVersion | Should -Be '3.54.0'
        $audit.objects.name | Should -Contain 'message_event'
        $audit.objects.name | Should -Contain 'ix_msg_flow'
        $audit.pageSize | Should -Be 16384
        $audit.databaseBytes | Should -Be (Get-Item -LiteralPath $script:Source).Length
        $objectBytes = ($audit.objects | Measure-Object bytes -Sum).Sum
        ($objectBytes + $audit.freePageBytes + $audit.unaccountedBytes) | Should -Be ($audit.pageCount * $audit.pageSize)
        (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash | Should -Be $script:SourceHash
    }
    It 'refuses an unconfirmed copy and never overwrites an existing destination' {
        $unconfirmed = Join-Path $TestDrive 'unconfirmed.sqlite'
        (Run-Storage @('--storage-copy', '--database', $script:Source, '--destination', $unconfirmed, '--output', (Join-Path $TestDrive 'unconfirmed.json'), '--vacuum')).ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath $unconfirmed | Should -BeFalse
        $existing = Join-Path $TestDrive 'existing.sqlite'
        Copy-Item -LiteralPath $script:Source -Destination $existing
        $before = (Get-FileHash -LiteralPath $existing -Algorithm SHA256).Hash
        (Run-Storage @('--storage-copy', '--database', $script:Source, '--destination', $existing, '--output', (Join-Path $TestDrive 'existing.json'), '--confirm-copy', '--vacuum')).ExitCode | Should -Not -Be 0
        (Get-FileHash -LiteralPath $existing -Algorithm SHA256).Hash | Should -Be $before
    }
    It 'compacts a new copy without migrating the legacy schema' {
        $script:VacuumCopy = Join-Path $TestDrive 'vacuum-only.sqlite'
        $result = Run-Storage @('--storage-copy', '--database', $script:Source, '--destination', $script:VacuumCopy,
            '--output', (Join-Path $TestDrive 'vacuum-only.json'), '--confirm-copy', '--vacuum')
        $result.ExitCode | Should -Be 0 -Because $result.Error
        Read-Scalar $script:VacuumCopy "SELECT value FROM metadata WHERE key='schema_version';" | Should -Be '6'
        Read-Scalar $script:VacuumCopy 'PRAGMA integrity_check;' | Should -Be 'ok'
        (Get-Item -LiteralPath $script:VacuumCopy).Length | Should -BeLessOrEqual (Get-Item -LiteralPath $script:Source).Length
        (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash | Should -Be $script:SourceHash
    }
    It 'migrates and repacks only a new copy while retaining exact row and identity counts' {
        $script:OptimizedCopy = Join-Path $TestDrive 'optimized.sqlite'
        $result = Run-Storage @('--storage-copy', '--database', $script:Source, '--destination', $script:OptimizedCopy,
            '--output', (Join-Path $TestDrive 'optimized.json'), '--confirm-copy', '--migrate', '--repack', '--vacuum')
        $result.ExitCode | Should -Be 0 -Because $result.Error
        Read-Scalar $script:OptimizedCopy "SELECT value FROM metadata WHERE key='schema_version';" | Should -Be '11'
        Read-Scalar $script:OptimizedCopy 'PRAGMA integrity_check;' | Should -Be 'ok'
        $afterCounts = Read-Scalar $script:OptimizedCopy @'
SELECT (SELECT count(*) FROM message_event)||'|'||
(SELECT count(*) FROM smtp_transaction)||'|'||
(SELECT count(*) FROM access_event)||'|'||
(SELECT count(DISTINCT message_id) FROM message_event)||'|'||
(SELECT coalesce(sum(offset),0) FROM source_file);
'@
        $afterCounts | Should -Be $script:BeforeCounts
        [long](Read-Scalar $script:OptimizedCopy "SELECT count(*) FROM message_event WHERE message_id IS NOT NULL AND msg_hash IS NULL;") | Should -Be 0
        [long](Read-Scalar $script:OptimizedCopy "SELECT count(*) FROM access_event WHERE typeof(url)='blob' OR typeof(errors)='blob';") | Should -BeGreaterThan 0
        (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash | Should -Be $script:SourceHash
    }
    It 'rejects source/destination aliasing without touching source bytes' {
        $result = Run-Storage @('--storage-copy', '--database', $script:Source, '--destination', $script:Source,
            '--output', (Join-Path $TestDrive 'alias.json'), '--confirm-copy', '--vacuum')
        $result.ExitCode | Should -Not -Be 0
        (Get-FileHash -LiteralPath $script:Source -Algorithm SHA256).Hash | Should -Be $script:SourceHash
    }
}
