BeforeAll {
    $ErrorActionPreference = 'Stop'
    $hostRoot = Split-Path $PSScriptRoot -Parent
    $publish = Join-Path $hostRoot 'publish'
    $exe = Join-Path $publish 'ExchangeLogReportAngular.exe'
    $tool = Join-Path (Split-Path $hostRoot -Parent) 'lib\sqlite-tools\sqlite3.exe'
    if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $tool)) { throw 'Publish host and supply the reviewed dev lib\sqlite-tools\sqlite3.exe first.' }
    $work = Join-Path $hostRoot ('test-artifacts\' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($work)
    $oldPath = $env:PATH
    $env:PATH = $publish + ';' + $env:PATH
    foreach ($name in @('SQLitePCLRaw.core.dll', 'SQLitePCLRaw.provider.e_sqlite3.dll', 'SQLitePCLRaw.batteries_v2.dll', 'Microsoft.Data.Sqlite.dll', 'ExchangeLogReportAngular.dll')) {
        Add-Type -Path (Join-Path $publish $name)
    }
    [SQLitePCL.Batteries_V2]::Init()
    . (Join-Path $PSScriptRoot 'Storage.Fixtures.ps1')
    $marker = 'SYNTHETIC_PRIVATE_PAYLOAD_NEVER_EMIT'
    function New-Fixture([string]$Name, [switch]$Schema6, [switch]$Schema7, [switch]$Schema8, [switch]$Schema9, [switch]$Schema10, [switch]$StandaloneSmtp) {
        $path = Join-Path $work ($Name + '.sqlite')
        $store = [ExchangeLogReport.Store]::new($path, $false, 'synthetic-preserved-tool')
        try {
            $text = ($marker + ' repeated evidence ') * 100
            $packed = [Convert]::ToHexString([ExchangeLogReport.Packed]::Pack($text))
            $store.Exec("INSERT INTO metadata(key,value) VALUES('custom_setting','$marker');")
            $store.Exec("INSERT INTO source_file(id,server,kind,path,offset,size,file_key) VALUES(41,'synthetic-mail','SMTPReceive','synthetic-only',98307,100000,'synthetic-key');")
            # '#Fields' header texts, kept in the schema-10 dictionary (the legacy fixtures below turn them back into source_file.fields text).
            $store.Exec("INSERT INTO source_fields(id,text) VALUES(1,'#Fields: date-time,connector-id'),(2,'#Fields: ' || char(233) || char(30028) || ' tracking,' || char(13) || char(10));
UPDATE source_file SET fields_id=1 WHERE id=41;
INSERT INTO source_file(id,server,kind,path,offset,size,file_key,fields_id) VALUES(42,'synthetic-mail','SMTPSend','synthetic-two',7,8,'synthetic-key-2',1),(43,'synthetic-mail','Tracking','synthetic-three',9,10,'synthetic-key-3',2),(44,'synthetic-mail','Tracking','synthetic-four',0,0,'synthetic-key-4',NULL);")
            $store.Exec("INSERT INTO message_event(id,time_ms,server,message_id,event_id,log_id,subject) VALUES(101,1791979200000,'synthetic-mail','<Mixed@example.invalid>','RECEIVE','synthetic-101','$marker'),(102,1791979200000,'synthetic-mail','<mixed@example.invalid>','DELIVER','synthetic-102','$marker');")
            $store.Exec("INSERT INTO smtp_transaction(id,time_ms,server,direction,session_id,message_id,response,transcript) VALUES(201,1791979200000,'synthetic-mail','Receive','synthetic-session','<Mixed@example.invalid>','$text',X'$packed');")
            $store.Exec("INSERT INTO smtp_auth_fragment(id,source_file_id,source_key,first_offset,first_ms,last_ms,server,direction,session_id,observations) VALUES(301,41,'synthetic-key',98307,1791979200000,1791979200001,'synthetic-mail','Receive','synthetic-session','$text');")
            $store.Exec("INSERT INTO access_event(id,time_ms,server,source,outcome,url,errors) VALUES(401,1791979200000,'synthetic-mail','synthetic','Failure','$text','$text');")
            $store.Exec("CREATE TABLE synthetic_pages(id INTEGER PRIMARY KEY,payload BLOB); WITH RECURSIVE n(x) AS(VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100) INSERT INTO synthetic_pages SELECT x,zeroblob(4096) FROM n; DELETE FROM synthetic_pages WHERE id>2; CREATE TABLE synthetic_ordered(value TEXT); INSERT INTO synthetic_ordered VALUES('first'),('second'); CREATE TABLE synthetic_opaque(id INTEGER PRIMARY KEY,value BLOB); INSERT INTO synthetic_opaque VALUES(1,X'002AFF'),(2,X'01FFFF00'),(3,'$marker'); CREATE TABLE synthetic_typed(id INTEGER PRIMARY KEY,value); INSERT INTO synthetic_typed VALUES(1,NULL),(2,123),(3,1.25),(4,'123'),(5,X'002AFF');")
            if ($StandaloneSmtp) {
                $store.Exec("INSERT INTO smtp_transaction(id,time_ms,server,direction,session_id,status,mail_from,rcpts) VALUES(202,1791979200000,'synthetic-mail','Receive','synthetic-null-rejected','Rejected','sender@example.invalid','recipient@example.invalid'),(203,1791979200000,'synthetic-mail','Receive','synthetic-null-accepted','Accepted','sender@example.invalid','recipient@example.invalid'),(204,1791979200000,'synthetic-mail','Send','synthetic-null-send','Rejected','sender@example.invalid','recipient@example.invalid');")
            }
            if ($Schema8 -or $Schema9 -or $Schema10) {
                Complete-StorageFixture $store
                Set-LegacyStorageFixture ([ServeFixtures]::Connection($store)) $(if ($Schema8) { 8 } elseif ($Schema9) { 9 } else { 10 })
            } elseif ($Schema6 -or $Schema7) {
                Set-LegacyStorageFixture ([ServeFixtures]::Connection($store)) $(if ($Schema6) { 6 } else { 7 })
                $store.Exec("WITH RECURSIVE n(x) AS(VALUES(3) UNION ALL SELECT x+1 FROM n WHERE x<100) INSERT INTO synthetic_pages SELECT x,zeroblob(4096) FROM n; DELETE FROM synthetic_pages WHERE id>2;")
            } else { Complete-StorageFixture $store }
            $store.Exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")
        } finally { $store.Dispose() }
        return $path
    }
    function Invoke-Storage([string[]]$Arguments, [switch]$NoTool) {
        $id = [guid]::NewGuid().ToString('N')
        $stdout = Join-Path $work ($id + '.stdout.log')
        $stderr = Join-Path $work ($id + '.stderr.log')
        $argsList = @($Arguments)
        if (-not $NoTool) { $argsList += @('--sqlite-tool', $tool) }
        $escaped = @($argsList | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' })
        $p = Start-Process -FilePath $exe -ArgumentList $escaped -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if (-not $p.WaitForExit(60000)) { Stop-Process -Id $p.Id -Force; throw 'Storage CLI timed out.' }
        $text = Get-Content -LiteralPath $stdout -Raw
        $errorText = Get-Content -LiteralPath $stderr -Raw
        [pscustomobject]@{ Code = $p.ExitCode; Text = $text; Error = $errorText; Json = $(if ($text) { $text | ConvertFrom-Json }) }
    }
    function Read-Scalar([string]$Path, [string]$Sql) {
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$Path;Mode=ReadOnly;Pooling=False")
        try {
            $db.Open()
            $c = $db.CreateCommand()
            try { $c.CommandText = $Sql; return $c.ExecuteScalar() } finally { $c.Dispose() }
        } finally { $db.Dispose() }
    }
    function Shared-Hash([string]$Path) {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) } finally { $stream.Dispose() }
    }
    function Write-FixtureSql([string]$Path, [string]$Sql) {
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$Path;Mode=ReadWrite;Pooling=False")
        try {
            $db.Open()
            $c = $db.CreateCommand()
            try { $c.CommandText = $Sql; [void]$c.ExecuteNonQuery() } finally { $c.Dispose() }
        } finally { $db.Dispose() }
    }
    $source = New-Fixture 'source6' -Schema6
    $source7 = New-Fixture 'source7' -Schema7
    $source8 = New-Fixture 'source8' -Schema8
    $source9 = New-Fixture 'source9'   # the CURRENT schema (11); $source9Genuine is a genuine schema-9 database, $source10Genuine a genuine schema-10 one
    $source9Genuine = New-Fixture 'source9genuine' -Schema9
    $source10Genuine = New-Fixture 'source10genuine' -Schema10
    $sourceHash = (Get-FileHash -LiteralPath $source).Hash
    $source7Hash = (Get-FileHash -LiteralPath $source7).Hash
    $source8Hash = (Get-FileHash -LiteralPath $source8).Hash
    $source9Hash = (Get-FileHash -LiteralPath $source9).Hash
    $source9GenuineHash = (Get-FileHash -LiteralPath $source9Genuine).Hash
    $source10GenuineHash = (Get-FileHash -LiteralPath $source10Genuine).Hash
}

Describe 'Explicit copy-only SQLite storage maintenance' {
    It 'audits real dbstat through the pinned tool with integer sizes and no row values or web startup' {
        $output = Join-Path $work 'audit.json'
        $r = Invoke-Storage @('--storage-audit', '--database', $source, '--output', $output)
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.sqliteVersion | Should -Be '3.54.0'
        $r.Json.nativeSqliteVersion | Should -Be '3.53.3'
        $r.Json.dbstatAvailable | Should -BeTrue
        $r.Json.objects.name | Should -Contain 'message_event'
        $r.Json.objects.name | Should -Contain 'ix_msg_flow'
        for ($i = 1; $i -lt $r.Json.objects.Count; $i++) {
            $r.Json.objects[$i - 1].bytes | Should -BeGreaterOrEqual $r.Json.objects[$i].bytes
            if ($r.Json.objects[$i - 1].bytes -eq $r.Json.objects[$i].bytes) {
                [string]::CompareOrdinal($r.Json.objects[$i - 1].name, $r.Json.objects[$i].name) | Should -BeLessOrEqual 0
            }
        }
        $r.Json.databaseBytes | Should -Be (Get-Item -LiteralPath $source).Length
        $r.Json.freelistBytes | Should -Be ($r.Json.freelistCount * $r.Json.pageSize)
        $r.Json.freePageBytes | Should -Be $r.Json.freelistBytes
        $r.Json.unaccountedBytes | Should -Be $r.Json.residualBytes
        $r.Json.elapsedMilliseconds | Should -Be $r.Json.durationMs
        $r.Json.recommendations.Count | Should -BeGreaterThan 0
        $r.Json.objectBytes | Should -BeGreaterThan 0
        $r.Json.residualBytes | Should -BeGreaterOrEqual 0
        $r.Text | Should -Not -Match ([regex]::Escape($marker))
        $r.Text | Should -Not -Match 'portal ready|Now listening'
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
        Test-Path -LiteralPath $output | Should -BeTrue
    }

    It 'makes a verified coherent copy without implicit migration, repacking or vacuum' {
        $dest = Join-Path $work 'plain.sqlite'
        $output = Join-Path $work 'plain.json'
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $dest, '--confirm-copy', '--output', $output)
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.success | Should -BeTrue
        $r.Json.actions.migrate | Should -BeFalse
        $r.Json.actions.vacuum | Should -BeFalse
        $r.Json.actions.repack | Should -BeFalse
        $r.Json.before.schemaVersion | Should -Be '6'
        $r.Json.after.schemaVersion | Should -Be '6'
        $r.Json.after.freelistCount | Should -Be $r.Json.before.freelistCount
        (Read-Scalar $dest "SELECT value FROM metadata WHERE key='tool_version';") | Should -Be 'synthetic-preserved-tool'
        (Read-Scalar $dest "SELECT offset FROM source_file WHERE id=41;") | Should -Be 98307
        (Read-Scalar $dest "SELECT count(*) FROM message_event WHERE id IN (101,102);") | Should -Be 2
        (Read-Scalar $dest "SELECT group_concat(kind,',') FROM (SELECT typeof(value) AS kind FROM synthetic_typed ORDER BY id);") | Should -Be 'null,integer,real,text,blob'
        $r.Json.vacuumCapacity | Should -BeNullOrEmpty
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
        $r.Text | Should -Not -Match ([regex]::Escape($marker))
    }

    It 'runs full vacuum independently without changing schema or normalized rows' {
        $dest = Join-Path $work 'vacuum.sqlite'
        $output = Join-Path $work 'vacuum.json'
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $dest, '--confirm-copy', '--vacuum', '--output', $output)
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.after.schemaVersion | Should -Be '6'
        $r.Json.actions.migrate | Should -BeFalse
        $r.Json.phases.stage | Should -Contain 'vacuumIntoSibling'
        $r.Json.vacuumCapacity.tempStore | Should -Be 'FILE'
        $r.Json.vacuumCapacity.destinationVolume | Should -Not -BeNullOrEmpty
        $r.Json.vacuumCapacity.temporaryVolume | Should -Not -BeNullOrEmpty
        $r.Json.vacuumCapacity.destinationAvailableFreeBytes | Should -BeGreaterOrEqual $r.Json.vacuumCapacity.destinationRequiredFreeBytes
        $r.Json.vacuumCapacity.temporaryAvailableFreeBytes | Should -BeGreaterOrEqual $r.Json.vacuumCapacity.temporaryRequiredFreeBytes
        $r.Json.verification.before.sha256 | Should -Be $r.Json.verification.after.sha256
        $r.Json.sourceUnchanged | Should -BeTrue
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
    }

    It 'writes a new default evidence report when copy output is omitted' {
        $dest = Join-Path $work 'default-report.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $dest, '--confirm-copy')
        $r.Code | Should -Be 0 -Because $r.Error
        Test-Path -LiteralPath ($dest + '.maintenance.json') | Should -BeTrue
        $r.Json.after.schemaVersion | Should -Be '6'
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
    }

    It 'migrates and repacks only the new copy and preserves metadata, offsets and auth evidence' {
        $dest = Join-Path $work 'optimized.sqlite'
        $output = Join-Path $work 'optimized.json'
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $dest, '--confirm-copy', '--migrate', '--repack', '--vacuum', '--output', $output)
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.after.schemaVersion | Should -Be '11'
        $r.Json.verification.smtpClients.applicable | Should -BeTrue
        (Read-Scalar $dest "SELECT count(*) FROM pragma_table_info('smtp_transaction') WHERE name='client_id';") | Should -Be 1
        (Read-Scalar $dest "SELECT count(*) FROM sqlite_schema WHERE name='ix_smtp_latest';") | Should -Be 0
        $r.Json.verification.derivedRollups.validated | Should -BeTrue
        ($r.Json.verification.derivedRollups.tables -join ',') | Should -Be 'message_rollup,message_rollup_dirty'
        ($r.Json.verification.derivedRollups.newlyAddedTables -join ',') | Should -Be 'message_rollup,message_rollup_dirty'
        ($r.Json.verification.derivedRollups.newlyAddedBookkeepingTables -join ',') | Should -Be 'sqlite_sequence'
        (Read-Scalar $dest 'SELECT count(*) FROM message_rollup_dirty;') | Should -Be 0
        (Read-Scalar $dest "SELECT count(*) FROM message_rollup WHERE identity IN ('<Mixed@example.invalid>','<mixed@example.invalid>');") | Should -Be 2
        $r.Json.repackedCells | Should -Be 3
        (Read-Scalar $dest "SELECT value FROM metadata WHERE key='tool_version';") | Should -Be 'synthetic-preserved-tool'
        (Read-Scalar $dest "SELECT value FROM metadata WHERE key='custom_setting';") | Should -Be $marker
        (Read-Scalar $dest 'SELECT offset FROM source_file WHERE id=41;') | Should -Be 98307
        (Read-Scalar $dest 'SELECT first_offset FROM smtp_auth_fragment WHERE id=301;') | Should -Be 98307
        (Read-Scalar $dest 'SELECT typeof(observations) FROM smtp_auth_fragment WHERE id=301;') | Should -Be 'text'
        (Read-Scalar $dest 'SELECT typeof(response) FROM smtp_transaction WHERE id=201;') | Should -Be 'blob'
        (Read-Scalar $dest "SELECT hex(value) FROM synthetic_opaque WHERE id=1;") | Should -Be '002AFF'
        (Read-Scalar $dest "SELECT hex(value) FROM synthetic_opaque WHERE id=2;") | Should -Be '01FFFF00'
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
        $r.Text | Should -Not -Match ([regex]::Escape($marker))
    }

    It 'can repack a current-schema copy without requesting migration or vacuum' {
        $dest = Join-Path $work 'repack9.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $source9, '--destination', $dest, '--confirm-copy', '--repack', '--output', (Join-Path $work 'repack9.json'))
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.actions.migrate | Should -BeFalse
        $r.Json.actions.vacuum | Should -BeFalse
        $r.Json.repackedCells | Should -Be 3
        (Get-FileHash -LiteralPath $source9).Hash | Should -Be $source9Hash
    }

    It 'refuses to repack a schema-8 copy without explicit migration' {
        $dest = Join-Path $work 'repack8-refused.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $source8, '--destination', $dest, '--confirm-copy', '--repack', '--output', (Join-Path $work 'repack8-refused.json'))
        $r.Code | Should -Be 2
        Test-Path -LiteralPath $dest | Should -BeFalse
        (Get-FileHash -LiteralPath $source8).Hash | Should -Be $source8Hash
    }

    It 'counts two changed cells in a single access-event row' {
        $path = New-Fixture 'two-cells-one-row'
        $store = [ExchangeLogReport.Store]::new($path, $false, 'synthetic-preserved-tool')
        try { $store.Exec("UPDATE smtp_transaction SET response='short' WHERE id=201;") } finally { $store.Dispose() }
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'two-cells-one-row-copy.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--repack', '--output', (Join-Path $work 'two-cells-one-row.json'))
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.repackedCells | Should -Be 2
        (Read-Scalar $dest "SELECT typeof(url)||','||typeof(errors) FROM access_event WHERE id=401;") | Should -Be 'blob,blob'
        (Read-Scalar $dest 'SELECT typeof(observations) FROM smtp_auth_fragment WHERE id=301;') | Should -Be 'text'
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }

    It 'can migrate hashes independently without repacking or vacuum' {
        $dest = Join-Path $work 'hash-only.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $dest, '--confirm-copy', '--migrate', '--output', (Join-Path $work 'hash-only.json'))
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.after.schemaVersion | Should -Be '11'
        $r.Json.actions.repack | Should -BeFalse
        $r.Json.actions.vacuum | Should -BeFalse
        $r.Json.measurements.stage | Should -Contain 'afterMigration'
        (Read-Scalar $dest "SELECT count(*) FROM message_event WHERE msg_hash IS NOT NULL;") | Should -Be 2
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
    }

    It 'migrates genuine schema 7 without excluding existing hash metadata or hash columns' {
        (Read-Scalar $source7 "SELECT count(*) FROM sqlite_schema WHERE name IN ('message_rollup','message_rollup_dirty','sqlite_sequence');") | Should -Be 0
        $dest = Join-Path $work 'schema7-copy.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $source7, '--destination', $dest, '--confirm-copy', '--migrate')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.before.schemaVersion | Should -Be '7'
        $r.Json.after.schemaVersion | Should -Be '11'
        $r.Json.verification.derivedRollups.validated | Should -BeTrue
        $r.Json.verification.exclusions | Should -Contain 'metadata.schema_version'
        $r.Json.verification.exclusions | Should -Not -Contain 'metadata.message_hash_algorithm'
        $r.Json.verification.exclusions | Should -Not -Contain 'added msg_hash only'
        $r.Json.actions.repack | Should -BeFalse
        $r.Json.actions.vacuum | Should -BeFalse
        (Read-Scalar $dest "SELECT value FROM metadata WHERE key='message_hash_algorithm';") | Should -Be 'fnv1a64-utf8-v1'
        (Get-FileHash -LiteralPath $source7).Hash | Should -Be $source7Hash
    }

    It 'preserves every existing current-schema rollup ID and sequence in plain, migration and vacuum copies' {
        $path = New-Fixture 'existing-rollups'
        Write-FixtureSql $path 'UPDATE message_rollup SET id=id+900; UPDATE sqlite_sequence SET seq=1200 WHERE name=''message_rollup''; CREATE TABLE synthetic_existing_auto(id INTEGER PRIMARY KEY AUTOINCREMENT,value TEXT); INSERT INTO synthetic_existing_auto VALUES(42,''synthetic'');'
        $hash = (Get-FileHash -LiteralPath $path).Hash
        foreach ($mode in @('plain', 'migrate', 'vacuum')) {
            $dest = Join-Path $work ("existing-rollups-$mode.sqlite")
            $arguments = @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy')
            if ($mode -ne 'plain') { $arguments += "--$mode" }
            $r = Invoke-Storage $arguments
            $r.Code | Should -Be 0 -Because $r.Error
            $r.Json.verification.derivedRollups.validated | Should -BeTrue
            $r.Json.verification.derivedRollups.baselineTablesPreserved | Should -BeTrue
            @($r.Json.verification.derivedRollups.newlyAddedTables).Count | Should -Be 0
            @($r.Json.verification.exclusions).Count | Should -Be 0
            foreach ($table in @('message_rollup', 'message_rollup_dirty', 'sqlite_sequence')) {
                ($r.Json.verification.after | Where-Object name -EQ $table).sha256 |
                    Should -Be ($r.Json.verification.before | Where-Object name -EQ $table).sha256
            }
            (Read-Scalar $dest 'SELECT min(id) FROM message_rollup;') | Should -Be 901
            (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -Be 1200
            (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='synthetic_existing_auto';") | Should -Be 42
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'migrates a genuine schema-8 copy to schema 11 changing only indexes, triggers, dictionaries and the SMTP client structures, with every derived row (decoded), ID and sequence identical' {
        (Read-Scalar $source8 "SELECT count(*) FROM sqlite_schema WHERE name IN ('ix_msg_hash','ix_smtp_hash','ix_session_latest');") | Should -Be 3
        $path = New-Fixture 'existing-rollups8' -Schema8
        Write-FixtureSql $path 'UPDATE message_rollup SET id=id+900; UPDATE sqlite_sequence SET seq=1200 WHERE name=''message_rollup'';'
        $hash = (Get-FileHash -LiteralPath $path).Hash
        foreach ($mode in @('plain', 'migrate', 'migrate-vacuum')) {
            $dest = Join-Path $work ("schema8-$mode.sqlite")
            $arguments = @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy')
            if ($mode -ne 'plain') { $arguments += '--migrate' }
            if ($mode -eq 'migrate-vacuum') { $arguments += '--vacuum' }
            $r = Invoke-Storage $arguments
            $r.Code | Should -Be 0 -Because $r.Error
            $r.Json.before.schemaVersion | Should -Be '8'
            $r.Json.after.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '8' } else { '11' })
            $r.Json.verification.derivedRollups.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '8' } else { '11' })
            $r.Json.verification.derivedRollups.validated | Should -BeTrue
            $r.Json.verification.derivedRollups.baselineTablesPreserved | Should -BeTrue
            @($r.Json.verification.derivedRollups.newlyAddedTables).Count | Should -Be 0
            @($r.Json.verification.derivedRollups.newlyAddedBookkeepingTables).Count | Should -Be 0
            if ($mode -eq 'plain') { @($r.Json.verification.exclusions).Count | Should -Be 0 }
            else {
                $r.Json.verification.exclusions[0] | Should -Be 'metadata.schema_version'
                $r.Json.verification.exclusions | Should -Contain 'added source_fields table and source_file.fields_id column only (source_file.fields is compared as its logical dictionary text)'
                ($r.Json.verification.exclusions -join '|') | Should -Match 'message_rollup is compared through its decoded rows'
            }
            # The decoded message_rollup of a migrated copy has the very same logical digest as its schema-8 source (the codes are not compared, their texts are).
            foreach ($table in @('message_rollup', 'message_rollup_dirty', 'sqlite_sequence')) {
                ($r.Json.verification.after | Where-Object name -EQ $table).sha256 |
                    Should -Be ($r.Json.verification.before | Where-Object name -EQ $table).sha256
            }
            (Read-Scalar $dest 'SELECT min(id) FROM message_rollup;') | Should -Be 901
            (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -Be 1200
            (Read-Scalar $dest "SELECT count(*) FROM sqlite_schema WHERE name IN ('ix_msg_hash','ix_smtp_hash','ix_session_latest');") | Should -Be $(if ($mode -eq 'plain') { 3 } else { 0 })
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'migrates a genuine schema-9 copy to schema 11: narrowed identity indexes, fields dictionary compared as logical text, every derived row (decoded), ID and sequence identical' {
        (Read-Scalar $source9Genuine "SELECT count(*) FROM sqlite_schema WHERE name IN ('source_fields');") | Should -Be 0
        (Read-Scalar $source9Genuine "SELECT sql FROM sqlite_schema WHERE name='ix_msg_identity_time';") | Should -Match 'message_id COLLATE BINARY,time_ms,id'
        $path = New-Fixture 'existing-rollups9' -Schema9
        Write-FixtureSql $path 'UPDATE message_rollup SET id=id+900; UPDATE sqlite_sequence SET seq=1200 WHERE name=''message_rollup'';'
        $hash = (Get-FileHash -LiteralPath $path).Hash
        foreach ($mode in @('plain', 'migrate', 'migrate-vacuum')) {
            $dest = Join-Path $work ("schema9-$mode.sqlite")
            $arguments = @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy')
            if ($mode -ne 'plain') { $arguments += '--migrate' }
            if ($mode -eq 'migrate-vacuum') { $arguments += '--vacuum' }
            $r = Invoke-Storage $arguments
            $r.Code | Should -Be 0 -Because $r.Error
            $r.Json.before.schemaVersion | Should -Be '9'
            $r.Json.after.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '9' } else { '11' })
            $r.Json.verification.derivedRollups.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '9' } else { '11' })
            $r.Json.verification.derivedRollups.validated | Should -BeTrue
            $r.Json.verification.derivedRollups.baselineTablesPreserved | Should -BeTrue
            @($r.Json.verification.derivedRollups.newlyAddedTables).Count | Should -Be 0
            $r.Json.verification.fieldsDictionary.applicable | Should -Be ($mode -ne 'plain')
            foreach ($table in @('message_rollup', 'message_rollup_dirty', 'sqlite_sequence')) {
                ($r.Json.verification.after | Where-Object name -EQ $table).sha256 |
                    Should -Be ($r.Json.verification.before | Where-Object name -EQ $table).sha256
            }
            # The logical '#Fields' text of source_file is the same in the copy, whatever its storage form.
            $logical = "SELECT group_concat(id || ':' || hex(COALESCE(fields,'~')),',') FROM (SELECT s.id AS id,{0} AS fields FROM source_file s {1} ORDER BY s.id);"
            if ($mode -eq 'plain') {
                (Read-Scalar $dest ($logical -f 's.fields', '')) | Should -Be (Read-Scalar $path ($logical -f 's.fields', ''))
                (Read-Scalar $dest "SELECT sql FROM sqlite_schema WHERE name='ix_msg_identity_time';") | Should -Match 'message_id COLLATE BINARY,time_ms,id'
            } else {
                (Read-Scalar $dest ($logical -f 'COALESCE(d.text,s.fields)', 'LEFT JOIN source_fields d ON d.id=s.fields_id')) | Should -Be (Read-Scalar $path ($logical -f 's.fields', ''))
                (Read-Scalar $dest 'SELECT count(*) FROM source_file WHERE fields IS NOT NULL;') | Should -Be 0
                (Read-Scalar $dest 'SELECT count(*) FROM source_fields;') | Should -Be 2
                (Read-Scalar $dest "SELECT sql FROM sqlite_schema WHERE name='ix_msg_identity_time';") | Should -Be 'CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,time_ms)'
                (Read-Scalar $dest "SELECT sql FROM sqlite_schema WHERE name='ix_smtp_identity_time';") | Should -Be 'CREATE INDEX ix_smtp_identity_time ON smtp_transaction(msg_hash,time_ms)'
            }
            (Read-Scalar $dest 'SELECT min(id) FROM message_rollup;') | Should -Be 901
            (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -Be 1200
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'migrates a genuine schema-10 copy to schema 11: rollup codes and SMTP client structures verified, every derived row (decoded), ID and sequence identical, source untouched' {
        (Read-Scalar $source10Genuine "SELECT count(*) FROM sqlite_schema WHERE name IN ('message_rollup_value','smtp_client','smtp_client_hour');") | Should -Be 0
        (Read-Scalar $source10Genuine "SELECT count(*) FROM sqlite_schema WHERE name='ix_smtp_latest';") | Should -Be 1
        $path = New-Fixture 'existing-rollups10' -Schema10
        Write-FixtureSql $path 'UPDATE message_rollup SET id=id+900; UPDATE sqlite_sequence SET seq=1200 WHERE name=''message_rollup''; UPDATE smtp_transaction SET remote_ep=''198.51.100.7:2525'',helo=''client.invalid'',tls=''TLS1.2'',auth_user=''proved@invalid'',auth_source=''Direct'',auth_result=''Succeeded'' WHERE id=201;'
        $hash = (Get-FileHash -LiteralPath $path).Hash
        foreach ($mode in @('plain', 'migrate', 'migrate-vacuum')) {
            $dest = Join-Path $work ("schema10-$mode.sqlite")
            $arguments = @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy')
            if ($mode -ne 'plain') { $arguments += '--migrate' }
            if ($mode -eq 'migrate-vacuum') { $arguments += '--vacuum' }
            $r = Invoke-Storage $arguments
            $r.Code | Should -Be 0 -Because $r.Error
            $r.Json.before.schemaVersion | Should -Be '10'
            $r.Json.after.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '10' } else { '11' })
            $r.Json.verification.derivedRollups.schemaVersion | Should -Be $(if ($mode -eq 'plain') { '10' } else { '11' })
            $r.Json.verification.derivedRollups.validated | Should -BeTrue
            $r.Json.verification.smtpClients.applicable | Should -Be ($mode -ne 'plain')
            @($r.Json.verification.derivedRollups.newlyAddedTables).Count | Should -Be 0
            foreach ($table in @('message_rollup', 'message_rollup_dirty', 'sqlite_sequence', 'smtp_transaction', 'source_file')) {
                ($r.Json.verification.after | Where-Object name -EQ $table).sha256 |
                    Should -Be ($r.Json.verification.before | Where-Object name -EQ $table).sha256
            }
            (Read-Scalar $dest 'SELECT min(id) FROM message_rollup;') | Should -Be 901
            (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';") | Should -Be 1200
            if ($mode -ne 'plain') {
                (Read-Scalar $dest 'SELECT count(*) FROM message_rollup_value;') | Should -BeGreaterThan 0
                (Read-Scalar $dest 'SELECT count(*) FROM smtp_client;') | Should -Be 1
                (Read-Scalar $dest 'SELECT count(*) FROM smtp_client_hour;') | Should -Be 1
                (Read-Scalar $dest 'SELECT client_id FROM smtp_transaction WHERE id=201;') | Should -Not -BeNullOrEmpty
                (Read-Scalar $dest "SELECT count(*) FROM sqlite_schema WHERE name='ix_smtp_latest';") | Should -Be 0
            } else {
                (Read-Scalar $dest "SELECT count(*) FROM sqlite_schema WHERE name='ix_smtp_latest';") | Should -Be 1
            }
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'publishes no copy when the dictionary migration cannot reproduce a header text exactly' {
        $path = New-Fixture 'dictionary-failure' -Schema9
        # The trigger alters the header text of a row right after the migration pointed it at the dictionary: the byte-for-byte check must refuse it.
        Write-FixtureSql $path "CREATE TRIGGER synthetic_bad_dictionary AFTER UPDATE ON source_file WHEN NEW.fields IS NOT NULL AND NEW.fields NOT LIKE '%!' BEGIN UPDATE source_file SET fields=NEW.fields || '!' WHERE id=NEW.id; END;"
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'dictionary-failure-copy.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate', '--output', (Join-Path $work 'dictionary-failure.json'))
        $r.Code | Should -Be 2
        $r.Json.success | Should -BeFalse
        $r.Error | Should -Match 'InvalidOperationException'   # the migration's own check; the host diagnostic does not echo exception text
        Test-Path -LiteralPath $dest | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $work 'dictionary-failure.json') | Should -BeFalse
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        @(Get-ChildItem -LiteralPath $work -Filter '*dictionary-failure*.stage.sqlite' -Force).Count | Should -Be 0
    }

    It 'verifies SMTP-only rollups against exact raw transaction IDs without inventing accepted or send groups' {
        $path = New-Fixture 'standalone-smtp' -Schema7 -StandaloneSmtp
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'standalone-smtp-copy.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
        $r.Code | Should -Be 0 -Because $r.Error
        $r.Json.verification.derivedRollups.validated | Should -BeTrue
        (Read-Scalar $dest "SELECT group_concat(identity,',') FROM message_rollup WHERE kind=1;") | Should -Be '202'
        (Read-Scalar $dest 'SELECT count(*) FROM smtp_transaction WHERE id IN (202,203,204);') | Should -Be 3
        (Read-Scalar $dest 'SELECT count(*) FROM message_rollup_dirty;') | Should -Be 0
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }

    It 'migrates genuinely empty legacy stores with empty derived tables and no invented sequence value' {
        foreach ($schema in @(6, 7)) {
            $path = Join-Path $work ("empty-$schema.sqlite")
            $store = [ExchangeLogReport.Store]::new($path, $false, 'synthetic-preserved-tool')
            try {
                Set-LegacyStorageFixture ([ServeFixtures]::Connection($store)) $schema
                $store.Exec('PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;')
            } finally { $store.Dispose() }
            $hash = (Get-FileHash -LiteralPath $path).Hash
            $dest = Join-Path $work ("empty-$schema-copy.sqlite")
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
            $r.Code | Should -Be 0 -Because $r.Error
            $r.Json.verification.derivedRollups.validated | Should -BeTrue
            (Read-Scalar $dest 'SELECT count(*) FROM message_rollup;') | Should -Be 0
            (Read-Scalar $dest "SELECT count(*) FROM sqlite_sequence WHERE name='message_rollup';") | Should -Be 0
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'rejects inconsistent rollups, dirty queues, missing groups and changed derived schemas without repairing sources' {
        $cases = [ordered]@{
            summary = 'UPDATE message_rollup SET events_count=999 WHERE id=1;'
            dirty = "INSERT INTO message_rollup_dirty VALUES('message','<untracked@example.invalid>',123);"
            missing = 'DELETE FROM message_rollup WHERE id=1;'
            identity = "UPDATE message_rollup SET identity='<untracked@example.invalid>' WHERE id=1;"
            schema = 'ALTER TABLE message_rollup ADD COLUMN unexpected TEXT;'
            dictionary = 'UPDATE source_file SET fields_id=999 WHERE id=41;'
            wideindex = 'DROP INDEX ix_msg_identity_time; CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,message_id COLLATE BINARY,time_ms,id);'
            dictionarytable = 'DROP TABLE source_fields;'
            trigger = 'DROP TRIGGER tr_message_event_rollup_delete; CREATE TRIGGER tr_message_event_rollup_delete AFTER DELETE ON message_event BEGIN SELECT 1; END;'
            danglingstatus = 'UPDATE message_rollup SET status=99999 WHERE id=1;'
            clientorphan = "INSERT INTO smtp_client(server,direction,remote_host) VALUES('SYNTHETIC','Receive','198.51.100.9');"
            clientbucket = "INSERT INTO smtp_client(id,server,direction,remote_host) VALUES(7,'SYNTHETIC','Receive','198.51.100.9'); UPDATE smtp_transaction SET client_id=7 WHERE id=201;"
            clienttrigger = 'DROP TRIGGER tr_smtp_transaction_client_insert;'
            clientindex = 'DROP INDEX ix_smtp_client;'
            clientpending = 'INSERT INTO smtp_client_pending VALUES(201);'
        }
        foreach ($case in $cases.Keys) {
            $path = New-Fixture ("invalid-rollups-$case")
            Write-FixtureSql $path $cases[$case]
            $hash = (Get-FileHash -LiteralPath $path).Hash
            $dest = Join-Path $work ("invalid-rollups-$case-copy.sqlite")
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
            $r.Code | Should -Be 2
            $r.Json.success | Should -BeFalse
            $r.Error | Should -Match 'derived rollup verification failed'
            Test-Path -LiteralPath $dest | Should -BeFalse
            Test-Path -LiteralPath ($dest + '.maintenance.json') | Should -BeFalse
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'rejects disguised schema-7 databases that retain any schema-8 derived objects' {
        $path = New-Fixture 'disguised-legacy'
        Write-FixtureSql $path "UPDATE metadata SET value='7' WHERE key='schema_version';"
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'disguised-legacy-copy.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
        $r.Code | Should -Be 2
        $r.Error | Should -Match 'reserved schema-8 derived objects'
        Test-Path -LiteralPath $dest | Should -BeFalse
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }

    It 'rejects duplicate, missing, stale and incorrectly typed existing schema-8 rollup sequences without repairing them' {
        $cases = [ordered]@{
            duplicate = "INSERT INTO sqlite_sequence(name,seq) SELECT name,seq FROM sqlite_sequence WHERE name='message_rollup';"
            missing = "DELETE FROM sqlite_sequence WHERE name='message_rollup';"
            stale = "UPDATE sqlite_sequence SET seq=0 WHERE name='message_rollup';"
            type = "UPDATE sqlite_sequence SET seq='2' WHERE name='message_rollup';"
        }
        foreach ($case in $cases.Keys) {
            $path = New-Fixture ("existing-sequence-$case")
            Write-FixtureSql $path $cases[$case]
            $hash = (Get-FileHash -LiteralPath $path).Hash
            $dest = Join-Path $work ("existing-sequence-$case-copy.sqlite")
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
            $r.Code | Should -Be 2
            $r.Json.success | Should -BeFalse
            $r.Error | Should -Match 'derived rollup verification failed'
            Test-Path -LiteralPath $dest | Should -BeFalse
            Test-Path -LiteralPath ($dest + '.maintenance.json') | Should -BeFalse
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'allows only the new rollup sequence row and preserves every other AUTOINCREMENT value' {
        foreach ($mode in @('preserve', 'other-sequence', 'rollup-sequence', 'extra-sequence')) {
            $path = New-Fixture ("sequence-$mode") -Schema7
            if ($mode -ne 'extra-sequence') {
                Write-FixtureSql $path 'CREATE TABLE synthetic_auto(id INTEGER PRIMARY KEY AUTOINCREMENT,value TEXT); INSERT INTO synthetic_auto VALUES(42,''synthetic'');'
            }
            if ($mode -ne 'preserve') {
                $body = switch ($mode) {
                    'other-sequence' { "UPDATE sqlite_sequence SET seq=999 WHERE name='synthetic_auto';" }
                    'rollup-sequence' { "UPDATE sqlite_sequence SET seq=999 WHERE name='message_rollup';" }
                    'extra-sequence' { "INSERT INTO sqlite_sequence VALUES('unapproved_sequence',999);" }
                }
                Write-FixtureSql $path "CREATE TRIGGER synthetic_bad_sequence AFTER UPDATE OF value ON metadata WHEN NEW.key='schema_version' AND NEW.value='11' BEGIN $body END;"
            }
            $hash = (Get-FileHash -LiteralPath $path).Hash
            $dest = Join-Path $work ("sequence-$mode-copy.sqlite")
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate')
            if ($mode -eq 'preserve') {
                $r.Code | Should -Be 0 -Because $r.Error
                (Read-Scalar $dest "SELECT seq FROM sqlite_sequence WHERE name='synthetic_auto';") | Should -Be 42
                @($r.Json.verification.derivedRollups.newlyAddedBookkeepingTables).Count | Should -Be 0
            } else {
                $r.Code | Should -Be 2
                $r.Json.success | Should -BeFalse
                Test-Path -LiteralPath $dest | Should -BeFalse
                Test-Path -LiteralPath ($dest + '.maintenance.json') | Should -BeFalse
            }
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'refuses existing destinations, hardlink aliases, existing reports and missing confirmation' {
        $existing = Join-Path $work 'existing.sqlite'
        [IO.File]::WriteAllText($existing, 'existing synthetic file')
        $existingHash = (Get-FileHash -LiteralPath $existing).Hash
        $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $existing, '--confirm-copy', '--output', (Join-Path $work 'refused.json'))
        $r.Code | Should -Be 2
        (Get-FileHash -LiteralPath $existing).Hash | Should -Be $existingHash
        $alias = Join-Path $work 'source-alias.sqlite'
        [void](New-Item -ItemType HardLink -Path $alias -Target $source)
        (Invoke-Storage @('--storage-copy', '--database', $source, '--destination', $alias, '--confirm-copy', '--output', (Join-Path $work 'alias.json'))).Code | Should -Be 2
        (Invoke-Storage @('--storage-copy', '--database', $source, '--destination', (Join-Path $work 'no-confirm.sqlite'), '--output', (Join-Path $work 'no-confirm.json'))).Code | Should -Be 2
        (Invoke-Storage @('--storage-copy', '--database', $source, '--destination', (Join-Path $work 'existing-report.sqlite'), '--confirm-copy', '--output', (Join-Path $work 'audit.json'))).Code | Should -Be 2
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
    }

    It 'rejects reparse-directory aliases rather than following them' {
        $target = Join-Path $work 'junction-target'
        $junction = Join-Path $work 'junction'
        [void][IO.Directory]::CreateDirectory($target)
        [void](New-Item -ItemType Junction -Path $junction -Target $target)
        try {
            $r = Invoke-Storage @('--storage-copy', '--database', $source, '--destination', (Join-Path $junction 'copy.sqlite'), '--confirm-copy', '--output', (Join-Path $work 'junction.json'))
            $r.Code | Should -Be 2
            Test-Path -LiteralPath (Join-Path $target 'copy.sqlite') | Should -BeFalse
        } finally { Remove-Item -LiteralPath $junction -Force }
    }

    It 'rejects active writers before any copy or output report is published' {
        $path = New-Fixture 'held-writer'
        $writer = [ExchangeLogReport.Store]::new($path, $false, 'synthetic-preserved-tool')
        try {
            $hash = Shared-Hash $path
            $dest = Join-Path $work 'held-copy.sqlite'
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--output', (Join-Path $work 'held.json'))
            $r.Code | Should -Be 2
            Test-Path -LiteralPath $dest | Should -BeFalse
            (Shared-Hash $path) | Should -Be $hash
        } finally { $writer.Dispose() }
    }

    It 'copies committed WAL contents through BackupDatabase and preserves source bytes' {
        $path = New-Fixture 'wal'
        $writer = [ExchangeLogReport.Store]::new($path, $false, 'synthetic-preserved-tool')
        $reader = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False")
        $tx = $null
        try {
            $writer.Exec("PRAGMA wal_autocheckpoint=0; INSERT INTO synthetic_ordered VALUES('committed-in-wal');")
            $reader.Open()
            $tx = $reader.BeginTransaction($true)
            $c = $reader.CreateCommand()
            try { $c.Transaction = $tx; $c.CommandText = 'SELECT count(*) FROM synthetic_ordered;'; $c.ExecuteScalar() | Should -Be 3 } finally { $c.Dispose() }
            $writer.Dispose()
            Test-Path -LiteralPath ($path + '-wal') | Should -BeTrue
            $mainHash = Shared-Hash $path
            $walHash = Shared-Hash ($path + '-wal')
            $dest = Join-Path $work 'wal-copy.sqlite'
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--output', (Join-Path $work 'wal-copy.json'))
            $r.Code | Should -Be 0 -Because $r.Error
            (Read-Scalar $dest 'SELECT count(*) FROM synthetic_ordered;') | Should -Be 3
            (Shared-Hash $path) | Should -Be $mainHash
            (Shared-Hash ($path + '-wal')) | Should -Be $walHash
        } finally { if ($tx) { $tx.Dispose() }; $reader.Dispose(); $writer.Dispose() }
    }

    It 'fails explicitly for missing SQLite tooling and future schemas without publishing destinations' {
        $missing = Join-Path $work 'sqlite3.exe'
        $r = Invoke-Storage @('--storage-audit', '--database', $source, '--sqlite-tool', $missing) -NoTool
        $r.Code | Should -Be 2
        $r.Json.success | Should -BeFalse
        $r.Error | Should -Match 'unavailable'
        $future = New-Fixture 'future'
        $s = [ExchangeLogReport.Store]::new($future, $false, 'synthetic-preserved-tool')
        try { $s.Exec("UPDATE metadata SET value='99' WHERE key='schema_version';") } finally { $s.Dispose() }
        $hash = (Get-FileHash -LiteralPath $future).Hash
        $dest = Join-Path $work 'future-copy.sqlite'
        (Invoke-Storage @('--storage-copy', '--database', $future, '--destination', $dest, '--confirm-copy', '--migrate', '--output', (Join-Path $work 'future.json'))).Code | Should -Be 2
        Test-Path -LiteralPath $dest | Should -BeFalse
        (Get-FileHash -LiteralPath $future).Hash | Should -Be $hash
    }

    It 'refuses unpinned tool bytes before invoking the executable' {
        $folder = Join-Path $work 'untrusted-tool'
        [void][IO.Directory]::CreateDirectory($folder)
        $fake = Join-Path $folder 'sqlite3.exe'
        [IO.File]::WriteAllText($fake, 'Synthetic non-executable pin mismatch fixture.')
        $r = Invoke-Storage @('--storage-audit', '--database', $source, '--sqlite-tool', $fake) -NoTool
        $r.Code | Should -Be 2
        $r.Json.success | Should -BeFalse
        $r.Error | Should -Match 'SHA-256 does not match'
        $r.Error | Should -Match 'not executed'
        (Get-FileHash -LiteralPath $source).Hash | Should -Be $sourceHash
    }

    It 'fails closed when staged migration changes non-bookkeeping logical values' {
        $path = New-Fixture 'verification-failure' -Schema6
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Pooling=False")
        try {
            $db.Open()
            $c = $db.CreateCommand()
            try {
                $c.CommandText = "CREATE TRIGGER synthetic_bad_update AFTER UPDATE OF msg_hash ON message_event BEGIN UPDATE metadata SET value='SYNTHETIC_CHANGED_VALUE' WHERE key='custom_setting'; END;"
                [void]$c.ExecuteNonQuery()
            } finally { $c.Dispose() }
        } finally { $db.Dispose() }
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'unverified.sqlite'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate', '--output', (Join-Path $work 'unverified.json'))
        $r.Code | Should -Be 2
        $r.Json.success | Should -BeFalse
        $r.Error | Should -Match 'logical contents'
        Test-Path -LiteralPath $dest | Should -BeFalse
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        @(Get-ChildItem -LiteralPath $work -Filter '*.stage.sqlite' -Force).Count | Should -Be 0
    }

    It 'rejects TEXT-to-valid-Packed-BLOB conversions outside the approved slots' {
        $packed = [Convert]::ToHexString([ExchangeLogReport.Packed]::Pack($marker))
        foreach ($target in @('metadata', 'opaque')) {
            $path = New-Fixture ('type-loss-' + $target) -Schema6
            $body = if ($target -eq 'metadata') {
                "UPDATE metadata SET value=X'$packed' WHERE key='custom_setting';"
            } else {
                "UPDATE synthetic_opaque SET value=X'$packed' WHERE id=3;"
            }
            $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Pooling=False")
            try {
                $db.Open()
                $c = $db.CreateCommand()
                try {
                    $c.CommandText = "CREATE TRIGGER synthetic_type_loss AFTER UPDATE OF msg_hash ON message_event BEGIN $body END;"
                    [void]$c.ExecuteNonQuery()
                } finally { $c.Dispose() }
            } finally { $db.Dispose() }
            $hash = (Get-FileHash -LiteralPath $path).Hash
            $dest = Join-Path $work ('type-loss-copy-' + $target + '.sqlite')
            $output = Join-Path $work ('type-loss-' + $target + '.json')
            $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate', '--output', $output)
            $r.Code | Should -Be 2
            $r.Json.success | Should -BeFalse
            $r.Error | Should -Match 'logical contents'
            Test-Path -LiteralPath $dest | Should -BeFalse
            Test-Path -LiteralPath $output | Should -BeFalse
            (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        }
    }

    It 'preserves NULL and numeric SQLite types even in approved packed slots' {
        $type = [ExchangeLogReport.Store].Assembly.GetType('ExchangeLogReportAngular.StorageFingerprint', $true)
        $normalize = $type.GetMethod('Normalize', [Reflection.BindingFlags]'NonPublic,Static')
        foreach ($value in @([DBNull]::Value, [long]42, [double]1.25)) {
            $result = $normalize.Invoke($null, [object[]]@('smtp_transaction', 'response', $value))
            $result.GetType() | Should -Be $value.GetType()
            $result | Should -Be $value
        }
        $path = New-Fixture 'slot-null-loss' -Schema6
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Pooling=False")
        try {
            $db.Open()
            $c = $db.CreateCommand()
            try {
                $c.CommandText = "UPDATE smtp_transaction SET response=NULL WHERE id=201; CREATE TRIGGER synthetic_slot_type_loss AFTER UPDATE OF msg_hash ON message_event BEGIN UPDATE smtp_transaction SET response='' WHERE id=201; END;"
                [void]$c.ExecuteNonQuery()
            } finally { $c.Dispose() }
        } finally { $db.Dispose() }
        $hash = (Get-FileHash -LiteralPath $path).Hash
        $dest = Join-Path $work 'slot-null-loss-copy.sqlite'
        $output = Join-Path $work 'slot-null-loss.json'
        $r = Invoke-Storage @('--storage-copy', '--database', $path, '--destination', $dest, '--confirm-copy', '--migrate', '--output', $output)
        $r.Code | Should -Be 2
        $r.Error | Should -Match 'logical contents'
        Test-Path -LiteralPath $dest | Should -BeFalse
        Test-Path -LiteralPath $output | Should -BeFalse
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
    }

    It 'exposes only fixed-source authenticated audit on the web with no maintenance route' {
        $readyPath = Join-Path $work 'web-ready.json'
        $reportsPath = Join-Path $work 'web-reports'
        $p = Start-Process -FilePath $exe -ArgumentList @('--database', "`"$source7`"", '--reports', "`"$reportsPath`"", '--sqlite-tool', "`"$tool`"", '--port', '0', '--no-browser', '--ready-file', "`"$readyPath`"", '--ready-file-with-token') -PassThru -RedirectStandardOutput (Join-Path $work 'web.stdout.log') -RedirectStandardError (Join-Path $work 'web.stderr.log')
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath $readyPath)) {
                if ($p.HasExited -or [DateTime]::UtcNow -gt $deadline) { throw 'Storage web test did not become ready.' }
                Start-Sleep -Milliseconds 100
            }
            $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
            $headers = @{ 'X-Portal-Token' = $ready.token }
            (Invoke-WebRequest -Uri ($ready.url + '/api/storage/audit') -SkipHttpErrorCheck).StatusCode | Should -Be 401
            $audit = Invoke-WebRequest -Uri ($ready.url + '/api/storage/audit') -Headers $headers
            ($audit.Content | ConvertFrom-Json).readOnly | Should -BeTrue
            ($audit.Content | ConvertFrom-Json).dbstatAvailable | Should -BeTrue
            ($audit.Content | ConvertFrom-Json).recommendations.Count | Should -BeGreaterThan 0
            $audit.Content | Should -Not -Match ([regex]::Escape($marker))
            (Invoke-WebRequest -Uri ($ready.url + '/api/storage/audit?sql=anything') -Headers $headers -SkipHttpErrorCheck).StatusCode | Should -Be 400
            (Invoke-WebRequest -Uri ($ready.url + '/api/storage/copy') -Headers $headers -Method Post -SkipHttpErrorCheck).StatusCode | Should -Be 404
            [void](Invoke-RestMethod -Uri ($ready.url + '/api/shutdown') -Headers $headers -Method Post)
            $p.WaitForExit(10000) | Should -BeTrue
            (Get-FileHash -LiteralPath $source7).Hash | Should -Be $source7Hash
        } finally { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } }
    }
}

AfterAll {
    $env:PATH = $oldPath
    if ($work -and (Test-Path -LiteralPath $work)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
