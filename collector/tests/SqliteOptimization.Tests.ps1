#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    Set-StrictMode -Version Latest
    $script:EngineRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:EngineRoot 'ExchangeLogReport.psd1') -Force
    Initialize-ExlEngine -Root $script:EngineRoot
    $script:Epoch = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z').ToUnixTimeMilliseconds()
    function New-SyntheticStore([string]$Name) {
        [ExchangeLogReport.Store]::new((Join-Path $TestDrive "$Name.db"), $false, 'synthetic')
    }
    function Connection($Store) {
        [ExchangeLogReport.Store].GetProperty('Connection', [Reflection.BindingFlags]'Instance,NonPublic').GetValue($Store)
    }
    function Sql($Store, [string]$Text, [hashtable]$Values = @{}) {
        $c = (Connection $Store).CreateCommand()
        try {
            $c.CommandText = $Text
            foreach ($key in $Values.Keys) {
                $value = $Values[$key]
                if ($null -eq $value) { $value = [DBNull]::Value }
                [void]$c.Parameters.AddWithValue("@$key", $value)
            }
            [void]$c.ExecuteNonQuery()
        } finally { $c.Dispose() }
    }
    function Rows($Store, [string]$Text) { return ,$Store.Query($Text, $null).Rows }
    function Downgrade-SyntheticTo6($Store) {
        # Schema 10 dictionary back to the schema-6 storage: the '#Fields' text in source_file.fields, no fields_id and no source_fields.
        $Store.Exec("UPDATE source_file SET fields=COALESCE((SELECT d.text FROM source_fields d WHERE d.id=source_file.fields_id),'#Fields: date-time,event-id'); ALTER TABLE source_file DROP COLUMN fields_id; DROP TABLE source_fields;")
        foreach ($table in 'message_event', 'smtp_transaction') {
            foreach ($operation in 'insert', 'update', 'delete') {
                $Store.Exec("DROP TRIGGER IF EXISTS tr_${table}_rollup_${operation};")
            }
        }
        $Store.Exec("DROP TABLE IF EXISTS message_rollup_dirty; DROP TABLE IF EXISTS message_rollup;
DROP INDEX IF EXISTS ix_msg_identity_time; DROP INDEX IF EXISTS ix_smtp_identity_time;
DROP INDEX IF EXISTS ix_smtp_latest; DROP INDEX IF EXISTS ix_session_latest;
DROP TABLE IF EXISTS message_rollup_value;
DROP TRIGGER IF EXISTS tr_smtp_transaction_client_insert; DROP TRIGGER IF EXISTS tr_smtp_transaction_client_update; DROP TRIGGER IF EXISTS tr_smtp_transaction_client_delete;
DROP INDEX IF EXISTS ix_smtp_client; DROP INDEX IF EXISTS ix_smtp_unknown_peer;
DROP TABLE IF EXISTS smtp_client_hour; DROP TABLE IF EXISTS smtp_client; DROP TABLE IF EXISTS smtp_client_value; DROP TABLE IF EXISTS smtp_client_pending; DROP TABLE IF EXISTS smtp_client_dirty;")
$Store.Exec("ALTER TABLE smtp_transaction DROP COLUMN client_id;")
        foreach ($table in 'message_event', 'smtp_transaction') {
            $Store.Exec("DROP TRIGGER tr_${table}_hash_insert; DROP TRIGGER tr_${table}_hash_update;")
        }
        $Store.Exec("DROP INDEX IF EXISTS ix_msg_hash; DROP INDEX IF EXISTS ix_smtp_hash; ALTER TABLE message_event DROP COLUMN msg_hash; ALTER TABLE smtp_transaction DROP COLUMN msg_hash;
CREATE INDEX ix_msg_id ON message_event(message_id); CREATE INDEX ix_smtp_message ON smtp_transaction(message_id);
DELETE FROM metadata WHERE key='message_hash_algorithm'; UPDATE metadata SET value='6' WHERE key='schema_version';")
    }
    function Add-SyntheticMail($Store) {
        Sql $Store "INSERT INTO message_event(time_ms,server,event_id,message_id,internal_id,log_id,sender,recipients) VALUES(@t,'EX1','RECEIVE','<Case@test>',NULL,'a','one@test','recipient@test'),(@t+1,'ex1','DELIVER','<case@test>',NULL,'b','two@test','recipient@test'),(@t+2,'EX1','DELIVER',NULL,'fallback','c','one@test','recipient@test'),(@t+3,'EX1','DELIVER','fallback',NULL,'d','one@test','recipient@test'),(@t+4,'EX1','FAIL',NULL,NULL,'e','one@test','recipient@test'),(@t+3600000,'EX1','DSN','<Case@test>',NULL,'f','one@test','recipient@test');" @{ t = $script:Epoch }
        Sql $Store "INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,mail_from) VALUES(@t,'EX1','Receive','s1','<Case@test>','Accepted','one@test'),(@t+1,'EX1','Receive','s2','<case@test>','Accepted','two@test');" @{ t = $script:Epoch }
        $Store.Exec("INSERT INTO source_file(server,kind,path,offset,size,lines,kept,noise,file_key) VALUES('EX1','Tracking','synthetic.log',123456,234567,100,90,10,'SYNTHETIC.LOG');")
    }
    # ---- helpers of the deferred-rollup tests -------------------------------------------------------
    function RollupAt([int]$seconds) { [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch + $seconds * 1000L).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
    function New-RollupTrackingLog([string]$Path, [string[]]$Lines, [int]$Order) {
        [IO.File]::WriteAllLines($Path, [string[]](@('#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address,message-subject') + $Lines))
        [IO.File]::SetLastWriteTimeUtc($Path, [datetime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime().AddMinutes($Order))
    }
    function New-RollupSmtpLog([string]$Path, [hashtable[]]$Sessions, [int]$Order) {
        $lines = foreach ($session in $Sessions) {
            $steps = if ($session['Id']) {
                @('+|', '>|220 ready', '<|EHLO a.test', '>|250 hello', '<|MAIL FROM:<s@test>', '>|250 OK', '<|RCPT TO:<r@test>', '>|250 OK', '<|DATA', ">|250 2.6.0 $($session.Id) [InternalId=7, Hostname=EX1] Queued mail for delivery", '-|')
            } else {
                @('+|', '>|220 ready', '<|EHLO b.test', '>|250 hello', '<|MAIL FROM:<x@test>', '>|250 OK', '<|RCPT TO:<nobody@test>', '>|550 5.1.1 not found', '-|')
            }
            for ($i = 0; $i -lt $steps.Count; $i++) {
                $parts = $steps[$i].Split('|')
                "$(RollupAt ($session.Base + $i)),EX1\Client Frontend EX1,$($session.Session),$i,192.0.2.2:587,192.0.2.1:5$($session.Base),$($parts[0].Trim()),`"$($parts[1].Replace('"','""'))`","
            }
        }
        [IO.File]::WriteAllLines($Path, [string[]](@('#Fields: date-time,connector-id,session-id,sequence-number,local-endpoint,remote-endpoint,event,data,context') + @($lines)))
        [IO.File]::SetLastWriteTimeUtc($Path, [datetime]::Parse('2026-01-01T00:00:00Z').ToUniversalTime().AddMinutes($Order))
    }
    function Start-RollupCollection($Store, [hashtable]$Folders, [string]$Defer, [bool]$Code, [long]$Above = -1, [int]$BatchRows = 1, [long]$WalRestart = -1) {
        $o = [ExchangeLogReport.CollectorOptions]::new()
        $o.NowMs = $script:Epoch + 86400000; $o.Parallelism = 1; $o.BatchRows = $BatchRows
        $o.DisableTriggersDuringApply = $Code
        $o.DeferRollups = [ExchangeLogReport.DeferRollupsMode]$Defer
        if ($Above -ge 0) { $o.DeferRollupsAboveBytes = $Above }
        if ($WalRestart -ge 0) { $o.WalRestartBytes = $WalRestart }
        $o.RunId = $Store.StartRun('Collect', 'synthetic', 'synthetic', 'test')
        $collector = [ExchangeLogReport.Collector]::new($Store, $o)
        $jobs = foreach ($kind in @($Folders.Keys | Sort-Object)) {
            $j = [ExchangeLogReport.SourceJob]::new(); $j.Server = 'EX1'; $j.Kind = $kind; $j.Folder = $Folders[$kind]; $j.Role = 'FrontEnd'; $j
        }
        $collector.Plan(@($jobs), [datetime]::MinValue)
        $collector.Start(@($jobs))
    }
    function Invoke-RollupCollection($Store, [hashtable]$Folders, [string]$Defer, [bool]$Code, [long]$Above = -1, [int]$BatchRows = 1, [long]$WalRestart = -1) {
        $run = Start-RollupCollection $Store $Folders $Defer $Code $Above $BatchRows $WalRestart
        [void]$run.Wait(-1)
        if ($run.Error) { throw $run.Error }
        return $run
    }
    function Get-RollupDecoded($Store) {
        # Every column except id, the codes decoded: the same rows must come out whatever the order the ids were given in.
        $rows = $Store.Query(@'
SELECT r.kind,r.identity,r.msg_hash,r.first_ms,r.last_ms,r.member_first_ms,r.member_last_ms,(SELECT text FROM message_rollup_value WHERE id=r.status),r.sender,r.recipients,
 r.recipient_count,r.delivered,r.failed,r.subject,r.size_kb,(SELECT text FROM message_rollup_value WHERE id=r.direction),(SELECT text FROM message_rollup_value WHERE id=r.servers),
 (SELECT text FROM message_rollup_value WHERE id=r.events),r.events_count,r.smtp_count FROM message_rollup r ORDER BY r.kind,r.identity;
'@, $null).Rows
        return ((@($rows) | ForEach-Object { ($_ | ForEach-Object { "$_" }) -join '|' }) -join "`n")
    }
    function Get-RollupIds($Store) {
        $ids = @{}
        foreach ($row in $Store.Query('SELECT kind,identity,id FROM message_rollup;', $null).Rows) { $ids["$($row[0])|$($row[1])"] = [long]$row[2] }
        return $ids
    }
    function Build-SyntheticReport($Store, [string]$Name, [string[]]$Users = @()) {
        $q = [ExchangeLogReport.ReportRequest]::new()
        $q.StartMs = $script:Epoch; $q.EndMs = $script:Epoch + 7200000
        $q.OutputFolder = Join-Path $TestDrive $Name
        $q.PortalDatabasePath = Join-Path $q.OutputFolder 'portal.db'
        $q.TemplatePath = Join-Path $script:EngineRoot 'assets\report.html'
        $q.WriteHtml = $true; $q.Detailed = $true; $q.MemoryBudgetMB = 64; $q.Parallelism = 1
        $q.Users = $Users
        [void][ExchangeLogReport.ReportBuilder]::Build($Store, $q)
        return $q.OutputFolder
    }
    function Portal-Rows([string]$Folder) {
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$(Join-Path $Folder 'portal.db');Mode=ReadOnly;Pooling=False")
        $db.Open()
        try {
            $c = $db.CreateCommand(); $c.CommandText = 'SELECT dataset,row_id,cells_json,search_text FROM report_rows ORDER BY dataset,row_id;'
            $r = $c.ExecuteReader()
            try { while ($r.Read()) { "$($r.GetString(0))|$($r.GetInt64(1))|$($r.GetString(2))|$($r.GetString(3))" } }
            finally { $r.Dispose(); $c.Dispose() }
        } finally { $db.Dispose() }
    }
    function Collect-Synthetic($Store, [string]$Folder, [string]$Kind = 'HttpProxy') {
        $o = [ExchangeLogReport.CollectorOptions]::new()
        $o.NowMs = $script:Epoch + 86400000; $o.Parallelism = 2; $o.StoreAllRequests = $true
        $o.RunId = $Store.StartRun('Collect', 'synthetic', 'synthetic', 'test')
        $collector = [ExchangeLogReport.Collector]::new($Store, $o)
        $job = [ExchangeLogReport.SourceJob]::new()
        $job.Server = 'EX1'; $job.Kind = $Kind; $job.Folder = $Folder; $job.Role = 'FrontEnd'
        $collector.Plan(@($job), [datetime]::MinValue)
        $run = $collector.Start(@($job))
        [void]$run.Wait(-1)
        if ($run.Error) { throw $run.Error }
        [void]$collector.Complete()
    }
}

Describe 'Lossless SQLite pilot optimization' {
    It 'keeps the byte-compatible Pack API and adaptively packs only smaller UTF8 values of at least 200 bytes' {
        [ExchangeLogReport.Packed].GetMethod('Adaptive').Invoke($null, [object[]]@($null)) | Should -BeNullOrEmpty
        [ExchangeLogReport.Packed]::Adaptive('') | Should -BeExactly ''
        [ExchangeLogReport.Packed]::Adaptive(('x' * 199)) | Should -BeOfType ([string])
        $unicode = 'é界😀' * 100
        $packed = [ExchangeLogReport.Packed]::Adaptive($unicode)
        ,$packed | Should -BeOfType ([byte[]])
        $packed.Length | Should -BeLessThan ([Text.Encoding]::UTF8.GetByteCount($unicode))
        [ExchangeLogReport.Packed]::Text($packed) | Should -BeExactly $unicode
        ,([ExchangeLogReport.Packed]::Adaptive(('é' * 100))) | Should -BeOfType ([byte[]])
        $random = [Random]::new(42)
        $text = -join (1..200 | ForEach-Object { [char]$random.Next(33, 127) })
        [ExchangeLogReport.Packed]::Adaptive($text) | Should -BeOfType ([string])
        ,([ExchangeLogReport.Packed]::Pack('short')) | Should -BeOfType ([byte[]])
        [ExchangeLogReport.Packed]::Text([ExchangeLogReport.Packed]::Pack('short')) | Should -BeExactly 'short'
        { [ExchangeLogReport.Packed]::Text([byte[]]@(9, 8, 7)) } | Should -Throw '*Expected TEXT*'
    }

    It 'uses stable signed FNV1a UTF8 hashes for raw inserts and message-id updates on both tables' {
        [ExchangeLogReport.Store]::MessageHash('') | Should -Be -3750763034362895579
        [ExchangeLogReport.Store]::MessageHash('hello') | Should -Be -6615550055289275125
        [ExchangeLogReport.Store].GetMethod('MessageHash').Invoke($null, [object[]]@($null)) | Should -BeNullOrEmpty
        $s = New-SyntheticStore 'hashes'
        try {
            Add-SyntheticMail $s
            foreach ($table in 'message_event', 'smtp_transaction') {
                $s.Scalar("SELECT COUNT(*) FROM $table WHERE msg_hash IS NOT exl_msg_hash(message_id);", $null) | Should -Be 0
                Sql $s "UPDATE $table SET message_id=@m WHERE id=1;" @{ m = '<界😀@test>' }
                $s.Scalar("SELECT msg_hash FROM $table WHERE id=1;", $null) | Should -Be ([ExchangeLogReport.Store]::MessageHash('<界😀@test>'))
                $s.Exec("UPDATE $table SET message_id=NULL WHERE id=1;")
                $s.Scalar("SELECT COUNT(*) FROM $table WHERE id=1 AND msg_hash IS NULL;", $null) | Should -Be 1
            }
            (Rows $s "SELECT value FROM metadata WHERE key='message_hash_algorithm';")[0][0] | Should -BeExactly 'fnv1a64-utf8-v1'
        } finally { $s.Dispose() }
    }

    It 'validates pre-bound hashes without rewriting correct rows and repairs arbitrary raw hashes' {
        $s = New-SyntheticStore 'conditional-hashes'
        try {
            $s.Exec('PRAGMA recursive_triggers=ON; CREATE TABLE hash_probe(table_name TEXT);')
            foreach ($table in 'message_event', 'smtp_transaction') {
                $s.Exec("CREATE TRIGGER observe_$table AFTER UPDATE OF msg_hash ON $table BEGIN INSERT INTO hash_probe VALUES('$table'); END;")
                $columns = 'id,time_ms,server,message_id,msg_hash'
                $values = "99,1,'EX1',@m,@h"
                if ($table -eq 'smtp_transaction') { $columns += ',direction,session_id'; $values += ",'Receive','correct'" }
                Sql $s "INSERT INTO $table($columns) VALUES($values);" @{m='<correct@test>';h=[ExchangeLogReport.Store]::MessageHash('<correct@test>')}
                $s.Scalar("SELECT COUNT(*) FROM hash_probe WHERE table_name='$table';", $null) | Should -Be 0
                Sql $s "UPDATE $table SET message_id=@m,msg_hash=@h WHERE id=99;" @{m='<next@test>';h=[ExchangeLogReport.Store]::MessageHash('<next@test>')}
                $s.Scalar("SELECT COUNT(*) FROM hash_probe WHERE table_name='$table';", $null) | Should -Be 1
                $s.Exec("UPDATE $table SET message_id='<raw@test>' WHERE id=99;")
                $s.Scalar("SELECT COUNT(*) FROM hash_probe WHERE table_name='$table';", $null) | Should -Be 2
                $s.Exec("UPDATE $table SET msg_hash=17 WHERE id=99;")
                $s.Scalar("SELECT COUNT(*) FROM $table WHERE msg_hash IS NOT exl_msg_hash(message_id);", $null) | Should -Be 0
                $s.Exec("DELETE FROM hash_probe WHERE table_name='$table';")
                $values = $values.Replace('99,1,', '100,2,').Replace("'correct'", "'incorrect'")
                Sql $s "INSERT INTO $table($columns) VALUES($values);" @{m='<wrong@test>';h=17}
                $s.Scalar("SELECT COUNT(*) FROM hash_probe WHERE table_name='$table';", $null) | Should -Be 1
                $s.Scalar("SELECT COUNT(*) FROM $table WHERE msg_hash IS NOT exl_msg_hash(message_id);", $null) | Should -Be 0
            }
        } finally { $s.Dispose() }
    }

    It 'refreshes earlier schema7 unconditional repair triggers without changing metadata or data' {
        $s = New-SyntheticStore 'trigger-refresh'
        try {
            Add-SyntheticMail $s
            $baseline = (Rows $s 'SELECT * FROM message_event ORDER BY id;') | ConvertTo-Json -Depth 10 -Compress
            $metadata = (Rows $s 'SELECT * FROM metadata ORDER BY key;') | ConvertTo-Json -Depth 10 -Compress
            foreach ($table in 'message_event', 'smtp_transaction') {
                $s.Exec("DROP TRIGGER tr_${table}_hash_insert; DROP TRIGGER tr_${table}_hash_update;
CREATE TRIGGER tr_${table}_hash_insert AFTER INSERT ON $table BEGIN UPDATE $table SET msg_hash=exl_msg_hash(NEW.message_id) WHERE id=NEW.id; END;
CREATE TRIGGER tr_${table}_hash_update AFTER UPDATE OF message_id ON $table BEGIN UPDATE $table SET msg_hash=exl_msg_hash(NEW.message_id) WHERE id=NEW.id; END;")
            }
        } finally { $s.Dispose() }
        $s = [ExchangeLogReport.Store]::new((Join-Path $TestDrive 'trigger-refresh.db'), $false, 'synthetic')
        try {
            ((Rows $s 'SELECT * FROM message_event ORDER BY id;') | ConvertTo-Json -Depth 10 -Compress) | Should -BeExactly $baseline
            ((Rows $s 'SELECT * FROM metadata ORDER BY key;') | ConvertTo-Json -Depth 10 -Compress) | Should -BeExactly $metadata
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'tr_%_hash_%' AND sql LIKE '%WHEN NEW.msg_hash IS NOT exl_msg_hash(NEW.message_id)%';", $null) | Should -Be 4
        } finally { $s.Dispose() }
    }

    It 'atomically migrates schema6, preserving row keys, evidence and source positions, and reopens idempotently' {
        $s = New-SyntheticStore 'migration'
        try {
            Add-SyntheticMail $s
            Sql $s "INSERT INTO smtp_auth_fragment(id,source_key,first_offset,first_ms,last_ms,server,direction,session_id,observations,evidence_format,coverage) VALUES(42,'evidence.log',456,@t,@t+1,'EX1','Receive','s1','[]',2,'1-7'); UPDATE smtp_transaction SET auth_user='proven@test',auth_result='Success',auth_source='Direct',auth_fragment_id=42,auth_evidence_id=42 WHERE id=1;" @{t=$script:Epoch}
            Downgrade-SyntheticTo6 $s
        } finally { $s.Dispose() }
        foreach ($readOnly in $true, $false, $true) {
            $s = [ExchangeLogReport.Store]::new((Join-Path $TestDrive 'migration.db'), $readOnly, 'test')
            try {
                (Rows $s "SELECT value FROM metadata WHERE key='schema_version';")[0][0] | Should -Be ([ExchangeLogReport.Store]::SchemaVersion)
                (Rows $s 'SELECT id,offset,size,lines,kept,noise FROM source_file;')[0] | Should -Be @(1,123456,234567,100,90,10)
                (Rows $s 'SELECT d.text,s.fields,typeof(s.fields) FROM source_file s JOIN source_fields d ON d.id=s.fields_id;')[0] | Should -Be @('#Fields: date-time,event-id', $null, 'null')
                (Rows $s 'SELECT id,log_id FROM message_event ORDER BY id;').Count | Should -Be 6
                (Rows $s 'SELECT auth_user,auth_result,auth_source,auth_fragment_id,auth_evidence_id FROM smtp_transaction WHERE id=1;')[0] | Should -Be @('proven@test','Success','Direct',42,42)
                (Rows $s 'SELECT id,first_offset,observations,evidence_format,coverage FROM smtp_auth_fragment;')[0] | Should -Be @(42,456,'[]',2,'1-7')
                $s.Scalar('SELECT COUNT(*) FROM message_event WHERE msg_hash IS NOT exl_msg_hash(message_id);', $null) | Should -Be 0
                $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('ix_msg_id','ix_smtp_message');", $null) | Should -Be 0
                (Rows $s "SELECT sql FROM sqlite_master WHERE name='ix_msg_flow';")[0][0] | Should -Match 'message_id, internal_id'
            } finally { $s.Dispose() }
        }
    }

    It 'rolls back hash columns, backfill, indexes and version together when a migration fails' {
        $s = New-SyntheticStore 'rollback'
        try {
            Add-SyntheticMail $s; Downgrade-SyntheticTo6 $s
            $s.Exec("CREATE TRIGGER synthetic_failure BEFORE UPDATE ON smtp_transaction BEGIN SELECT RAISE(ABORT,'synthetic migration failure'); END;")
        } finally { $s.Dispose() }
        { [ExchangeLogReport.Store]::new((Join-Path $TestDrive 'rollback.db'), $false, 'test') } | Should -Throw '*synthetic migration failure*'
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$(Join-Path $TestDrive 'rollback.db');Pooling=False")
        $db.Open()
        try {
            $c = $db.CreateCommand()
            $c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';"; $c.ExecuteScalar() | Should -Be '6'
            $c.CommandText = "SELECT COUNT(*) FROM pragma_table_info('message_event') WHERE name='msg_hash';"; $c.ExecuteScalar() | Should -Be 0
            $c.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('ix_msg_id','ix_smtp_message');"; $c.ExecuteScalar() | Should -Be 2
            $c.CommandText = "DROP TRIGGER synthetic_failure;"; [void]$c.ExecuteNonQuery(); $c.Dispose()
        } finally { $db.Dispose() }
        $s = [ExchangeLogReport.Store]::new((Join-Path $TestDrive 'rollback.db'), $false, 'test')
        try { $s.Scalar('SELECT COUNT(*) FROM message_event;', $null) | Should -Be 6 } finally { $s.Dispose() }
    }

    It 'rejects newer schemas and incompatible hash metadata without overwriting either' {
        $s = New-SyntheticStore 'newer'
        try { $s.Exec("UPDATE metadata SET value='12' WHERE key='schema_version';") } finally { $s.Dispose() }
        foreach ($ro in $true, $false) {
            { [ExchangeLogReport.Store]::new((Join-Path $TestDrive 'newer.db'), $ro, 'test') } | Should -Throw '*newer schema*'
        }
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$(Join-Path $TestDrive 'newer.db');Pooling=False")
        $db.Open()
        try {
            $c = $db.CreateCommand(); $c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';"
            $c.ExecuteScalar() | Should -Be '12'
            $c.CommandText = "UPDATE metadata SET value='7' WHERE key='schema_version'; UPDATE metadata SET value='other' WHERE key='message_hash_algorithm';"
            [void]$c.ExecuteNonQuery(); $c.Dispose()
        } finally { $db.Dispose() }
        { [ExchangeLogReport.Store]::new((Join-Path $TestDrive 'newer.db'), $false, 'test') } | Should -Throw '*hash algorithm*'
    }

    It 'fails closed for external writers without the registered hash function' {
        $s = New-SyntheticStore 'external'; $s.Dispose()
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$(Join-Path $TestDrive 'external.db');Pooling=False")
        $db.Open()
        try {
            $c = $db.CreateCommand(); $c.CommandText = "INSERT INTO message_event(time_ms,server,message_id) VALUES(1,'EX1','x');"
            { $c.ExecuteNonQuery() } | Should -Throw '*exl_msg_hash*'
            $c.Dispose()
        } finally { $db.Dispose() }
    }

    It 'verifies exact text despite forced stored-hash collisions and counts case-sensitive IDs with internal fallback exactly' {
        $s = New-SyntheticStore 'collisions'
        try {
            Add-SyntheticMail $s
            # Deliberately bypass the invariant only in this synthetic corruption/collision fixture.
            $s.Exec('DROP TRIGGER tr_message_event_hash_update; DROP TRIGGER tr_smtp_transaction_hash_update;')
            $s.Exec('UPDATE message_event SET msg_hash=17 WHERE message_id IS NOT NULL; UPDATE smtp_transaction SET msg_hash=17;')
            $folder = Build-SyntheticReport $s 'collision-report' @('one@test')
            $messages = @(Import-Csv (Join-Path $folder 'ExchangeLogs-Messages.csv') -Delimiter ';')
            @($messages | Where-Object 'Message ID' -CEQ '<case@test>').Count | Should -Be 0
            ($messages | Where-Object 'Message ID' -CEQ '<Case@test>').'SMTP sessions' | Should -Be '1'
            $all = Build-SyntheticReport $s 'exact-report'
            $server = Import-Csv (Join-Path $all 'ExchangeLogs-Servers.csv') -Delimiter ';'
            $server.Messages | Should -Be '3'
            $daily = Import-Csv (Join-Path $all 'ExchangeLogs-Daily.csv') -Delimiter ';'
            $daily.Messages | Should -Be '4'
            $plans = Rows $s 'EXPLAIN QUERY PLAN SELECT id FROM smtp_transaction WHERE (msg_hash,message_id) IN (SELECT msg_hash,message_id FROM message_event WHERE time_ms>0);'
            ($plans | ForEach-Object { $_ -join '|' }) -join "`n" | Should -Match 'SEARCH smtp_transaction USING (COVERING )?INDEX ix_smtp_identity_time \(msg_hash=\?'
        } finally { $s.Dispose() }
    }

    It 're-packs mixed TEXT/BLOB values explicitly and preserves CSV, portal rows, Unicode and source offsets' {
        $s = New-SyntheticStore 'repack'
        try {
            Add-SyntheticMail $s
            $text = 'é界😀 synthetic repeated evidence ' * 80
            Sql $s "INSERT INTO access_event(time_ms,server,source,protocol,user,outcome,url,errors) VALUES(@t,'EX1','HttpProxy','Ews','one@test','Failure',@v,@v);" @{ t = $script:Epoch; v = $text }
            Sql $s 'UPDATE smtp_transaction SET response=@v;' @{ v = $text }
            Sql $s "INSERT INTO smtp_auth_fragment(source_key,first_offset,first_ms,last_ms,server,direction,session_id,observations) VALUES('synthetic',77,@t,@t+1,'EX1','Receive','s1',@v);" @{ t = $script:Epoch; v = ('[]' + (' ' * 1000)) }
            $before = Build-SyntheticReport $s 'before-repack'
            $s.RepackSafeText() | Should -Be 4
            $s.RepackSafeText() | Should -Be 0
            (Rows $s 'SELECT typeof(url),typeof(errors) FROM access_event;')[0] | Should -Be @('blob','blob')
            (Rows $s 'SELECT url,errors FROM access_event;')[0] | Should -Be @($text,$text)
            (Rows $s 'SELECT typeof(observations),json_array_length(observations) FROM smtp_auth_fragment;')[0] | Should -Be @('text',0)
            $after = Build-SyntheticReport $s 'after-repack'
            foreach ($csv in Get-ChildItem $before -Filter '*.csv') {
                [IO.File]::ReadAllText($csv.FullName) | Should -BeExactly ([IO.File]::ReadAllText((Join-Path $after $csv.Name)))
            }
            @(Portal-Rows $before) | Should -BeExactly @(Portal-Rows $after)
            (Rows $s 'SELECT offset,size FROM source_file;')[0] | Should -Be @(123456,234567)
            Sql $s 'UPDATE access_event SET errors=@v;' @{ v = [byte[]]@(9,8,7) }
            $s.RepackSafeText() | Should -Be 0
            (Rows $s 'SELECT hex(errors) FROM access_event;')[0][0] | Should -Be '090807'
            { Build-SyntheticReport $s 'unknown-blob-report' } | Should -Throw '*recognised packed text BLOB*'
        } finally { $s.Dispose() }
        $s = [ExchangeLogReport.Store]::new((Join-Path $TestDrive 'repack.db'), $true, 'test')
        try {
            (Rows $s 'SELECT url FROM access_event;')[0][0] | Should -BeExactly $text
            { $s.RepackSafeText() } | Should -Throw '*writable copy*'
        } finally { $s.Dispose() }
    }

    It 're-packs across bounded batches and rolls back the entire failing batch' {
        $s = New-SyntheticStore 'repack-batches'
        try {
            Sql $s "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<300) INSERT INTO access_event(time_ms,server,source,outcome,errors) SELECT i,'EX1','Synthetic','Failure',@v FROM n;" @{v=('compressible synthetic text ' * 100)}
            $s.Exec("CREATE TRIGGER reject_second BEFORE UPDATE OF errors ON access_event WHEN NEW.id=2 BEGIN SELECT RAISE(ABORT,'synthetic repack failure'); END;")
            { $s.RepackSafeText() } | Should -Throw '*synthetic repack failure*'
            $s.Scalar("SELECT COUNT(*) FROM access_event WHERE typeof(errors)='text';", $null) | Should -Be 300
            $s.Exec('DROP TRIGGER reject_second;')
            $s.RepackSafeText() | Should -Be 300
            $s.Scalar("SELECT COUNT(*) FROM access_event WHERE typeof(errors)='blob';", $null) | Should -Be 300
            $s.RepackSafeText() | Should -Be 0
        } finally { $s.Dispose() }
    }

    It 'reloads packed session counters when merging and re-points every existing timeline step' {
        $s = New-SyntheticStore 'session-merge'
        $dir = Join-Path $TestDrive 'proxy-logs'; [void][IO.Directory]::CreateDirectory($dir)
        $path = Join-Path $dir 'proxy.log'
        $header = '#Fields: DateTime,RequestId,Protocol,AuthenticatedUser,UrlStem,HttpStatus,BackEndStatus,Method,TotalRequestTime,UserAgent,ClientIpAddress'
        function Proxy([int]$Minute) {
            $time = [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch + $Minute * 60000).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            "$time,$([guid]::NewGuid()),Ews,one@test,/ews/exchange.asmx,200,200,POST,42,SyntheticClient,192.0.2.1"
        }
        try {
            [IO.File]::WriteAllLines($path, @($header, (Proxy 0), (Proxy 50)))
            Collect-Synthetic $s $dir
            $s.Scalar('SELECT COUNT(*) FROM client_session;', $null) | Should -Be 2
            $counter = ('preserved-' + ('x' * 220) + '=2;')
            Sql $s 'UPDATE client_session SET actions=@v,statuses=@v;' @{ v = $counter }
            $s.RepackSafeText() | Should -Be 4
            [IO.File]::AppendAllText($path, (Proxy 25) + "`r`n")
            Collect-Synthetic $s $dir
            $s.Scalar('SELECT COUNT(*) FROM client_session;', $null) | Should -Be 1
            (Rows $s 'SELECT actions,statuses FROM client_session;')[0][0] | Should -Match '=4'
            (Rows $s 'SELECT actions,statuses FROM client_session;')[0][1] | Should -Match '=4'
            $s.Scalar('SELECT COUNT(*) FROM session_step WHERE session_id NOT IN (SELECT id FROM client_session);', $null) | Should -Be 0
        } finally { $s.Dispose() }
    }

    It 'binds hashes on the production tracking prepared-insert path without corrective row updates' {
        $s = New-SyntheticStore 'tracking-prebound'
        $dir = Join-Path $TestDrive 'tracking-prebound'; [void][IO.Directory]::CreateDirectory($dir)
        try {
            $s.Exec('CREATE TABLE hash_probe(row_id INTEGER); CREATE TRIGGER observe_hash AFTER UPDATE OF msg_hash ON message_event BEGIN INSERT INTO hash_probe VALUES(NEW.id); END;')
            [IO.File]::WriteAllLines((Join-Path $dir 'tracking.log'), @(
                '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address'
                '2026-01-01T00:00:01.000Z,RECEIVE,<prebound@test>,1,a,sender@test,recipient@test'
                '2026-01-01T00:00:02.000Z,DELIVER,<prebound@test>,1,b,sender@test,recipient@test'
            ))
            Collect-Synthetic $s $dir 'Tracking'
            $s.Scalar('SELECT COUNT(*) FROM message_event;', $null) | Should -Be 2
            $s.Scalar('SELECT COUNT(*) FROM message_event WHERE msg_hash IS NOT exl_msg_hash(message_id);', $null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM hash_probe;', $null) | Should -Be 0
        } finally { $s.Dispose() }
    }

    It 'replays packed SMTP evidence without changing authentication or evidence row identities' {
        $s = New-SyntheticStore 'auth-replay'
        $dir = Join-Path $TestDrive 'smtp-logs'; [void][IO.Directory]::CreateDirectory($dir)
        $steps = @('+|', '> |220 ready', '<|EHLO synthetic.test', '>|250 hello', '<|AUTH LOGIN', '*|one@test|authenticated', '>|235 2.7.0 Authentication successful',
            '<|MAIL FROM:<sender@test>', '>|250 sender OK', '<|RCPT TO:<recipient@test>', '>|250 recipient OK', '<|DATA', '>|354 go', '>|250 2.6.0 <synthetic@test> [InternalId=7, Hostname=EX1] Queued mail for delivery', '-|')
        $lines = @('#Fields: date-time,connector-id,session-id,sequence-number,local-endpoint,remote-endpoint,event,data,context')
        for ($i=0; $i -lt $steps.Count; $i++) {
            $parts = $steps[$i].Split('|', 3); $time = [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch + $i*1000).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $data = $parts[1].Replace('"','""')
            $context = if ($parts.Length -eq 3) { $parts[2] } else { '' }
            $lines += "$time,EX1\Client Frontend EX1,ABCDEF01,$i,192.0.2.2:587,192.0.2.1:50000,$($parts[0].Trim()),`"$data`",$context"
        }
        try {
            $s.Exec('CREATE TABLE hash_probe(row_id INTEGER); CREATE TRIGGER observe_hash AFTER UPDATE OF msg_hash ON smtp_transaction BEGIN INSERT INTO hash_probe VALUES(NEW.id); END;')
            [IO.File]::WriteAllLines((Join-Path $dir 'smtp.log'), $lines)
            Collect-Synthetic $s $dir 'SmtpReceive'
            $s.Scalar('SELECT COUNT(*) FROM hash_probe;', $null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM smtp_transaction WHERE msg_hash IS NOT exl_msg_hash(message_id);', $null) | Should -Be 0
            $baseline = (Rows $s 'SELECT id,message_id,auth_user,auth_result,auth_source,auth_fragment_id,auth_evidence_id FROM smtp_transaction ORDER BY id;') | ConvertTo-Json -Depth 10 -Compress
            $s.Scalar("SELECT COUNT(*) FROM smtp_transaction WHERE auth_user='one@test';", $null) | Should -Be 1
            $s.Scalar("SELECT COUNT(*) FROM smtp_auth_fragment WHERE typeof(observations)='text';", $null) | Should -BeGreaterThan 0
            foreach ($row in (Rows $s 'SELECT id,observations FROM smtp_auth_fragment;')) {
                Sql $s 'UPDATE smtp_auth_fragment SET observations=@v WHERE id=@id;' @{ id=$row[0]; v=[ExchangeLogReport.Packed]::Pack($row[1]) }
            }
            $s.Exec('UPDATE smtp_transaction SET auth_user=NULL,auth_result=NULL,auth_source=NULL,auth_evidence_id=NULL;')
            $writer = [Activator]::CreateInstance([ExchangeLogReport.Store].Assembly.GetType('ExchangeLogReport.Writer'), @($s))
            $resolver = [Activator]::CreateInstance([ExchangeLogReport.Store].Assembly.GetType('ExchangeLogReport.AuthResolver'), @($s,$writer,[long]600000))
            try {
                $tx = $s.Begin()
                try { $resolver.Touch('EX1','Receive','FrontEnd','ABCDEF01'); $resolver.Flush($tx); $tx.Commit() } finally { $tx.Dispose() }
            } finally { $resolver.Dispose(); $writer.Dispose() }
            ((Rows $s 'SELECT id,message_id,auth_user,auth_result,auth_source,auth_fragment_id,auth_evidence_id FROM smtp_transaction ORDER BY id;') | ConvertTo-Json -Depth 10 -Compress) | Should -BeExactly $baseline
        } finally { $s.Dispose() }
    }

    It 'collects with the connection triggers off and writes the same rollup queue and rollups as the trigger path, leaving every trigger defined and active' {
        # The same tracking and SMTP logs collected three times each (new rows; the files read again from the start, so every insert is ignored;
        # appended rows): once with the rollup triggers running (old path), once with them disabled on the apply connection and the
        # invalidations written by the code. The queue is read just before each reconciliation (CollectorOptions.RollupQueueTrace).
        function At([int]$seconds) { [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch + $seconds * 1000L).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
        function Session([string]$sid, [int]$base, [string[]]$steps) {
            for ($i = 0; $i -lt $steps.Count; $i++) {
                $parts = $steps[$i].Split('|')
                "$(At ($base + $i)),EX1\Client Frontend EX1,$sid,$i,192.0.2.2:587,192.0.2.1:5$base,$($parts[0].Trim()),`"$($parts[1].Replace('"','""'))`","
            }
        }
        function Queued([string]$id) { @('+|', '>|220 ready', '<|EHLO a.test', '>|250 hello', '<|MAIL FROM:<s@test>', '>|250 OK', '<|RCPT TO:<r@test>', '>|250 OK', '<|DATA', ">|250 2.6.0 $id [InternalId=7, Hostname=EX1] Queued mail for delivery", '-|') }
        $refused = @('+|', '>|220 ready', '<|EHLO b.test', '>|250 hello', '<|MAIL FROM:<x@test>', '>|250 OK', '<|RCPT TO:<nobody@test>', '>|550 5.1.1 not found', '-|')
        $trkHead = '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address,message-subject'
        $smtpHead = '#Fields: date-time,connector-id,session-id,sequence-number,local-endpoint,remote-endpoint,event,data,context'
        $trkBase = @($trkHead
            "$(At 1),RECEIVE,<Case@test>,1,a1,s@test,r@test,one"
            "$(At 2),DELIVER,<Case@test>,1,a2,s@test,r@test,one"
            "$(At 3),RECEIVE,<case@test>,2,a3,s@test,r@test,two"
            "$(At 4),RECEIVE,<tracking-only@test>,3,a4,s@test,r@test,three"
            "$(At 5),RECEIVE,<`u{e9}`u{1F600}@test>,4,a5,s@test,r@test,unicode"
            # Identities that sort differently by UTF-16 units and by UTF-8 bytes (the order of the queue, hence of the message_rollup ids)
            "$(At 6),RECEIVE,<`u{1F600}@test>,6,a8,s@test,r@test,astral"
            "$(At 7),RECEIVE,<`u{E000}@test>,7,a9,s@test,r@test,private use")
        $smtpBase = @($smtpHead; (Session '0AAA000000000001' 10 (Queued '<Case@test>')); (Session '0AAA000000000002' 30 (Queued '<smtp-only@test>')); (Session '0AAA000000000003' 50 $refused))
        $trkMore = @("$(At 100),DELIVER,<tracking-only@test>,3,a6,s@test,r@test,three", "$(At 101),RECEIVE,<later@test>,5,a7,s@test,r@test,later")
        $smtpMore = @((Session '0AAA000000000004' 120 $refused); (Session '0AAA000000000005' 140 (Queued '<later@test>')))
        function Dump($Store, [string]$Sql) { (Rows $Store $Sql | ForEach-Object { ($_ | ForEach-Object { "$_" }) -join '|' }) -join "`n" }
        $results = @{}
        foreach ($mode in 'triggers', 'code') {
            $trk = Join-Path $TestDrive "norollup-$mode-trk"; $smtp = Join-Path $TestDrive "norollup-$mode-smtp"
            foreach ($d in $trk, $smtp) { [void][IO.Directory]::CreateDirectory($d) }
            [IO.File]::WriteAllLines((Join-Path $trk 'tracking.log'), [string[]]$trkBase)
            [IO.File]::WriteAllLines((Join-Path $smtp 'smtp.log'), [string[]]$smtpBase)
            $s = New-SyntheticStore "norollup-$mode"
            try {
                $trace = [System.Collections.Generic.List[string]]::new()
                foreach ($step in 1..3) {
                    if ($step -eq 2) { $s.Exec('UPDATE source_file SET offset=0,size=0;') }
                    if ($step -eq 3) {
                        [IO.File]::AppendAllLines((Join-Path $trk 'tracking.log'), [string[]]$trkMore)
                        [IO.File]::AppendAllLines((Join-Path $smtp 'smtp.log'), [string[]]$smtpMore)
                    }
                    $o = [ExchangeLogReport.CollectorOptions]::new()
                    $o.NowMs = $script:Epoch + 86400000; $o.Parallelism = 2
                    $o.DisableTriggersDuringApply = ($mode -eq 'code'); $o.RollupQueueTrace = $trace
                    $o.RunId = $s.StartRun('Collect', 'synthetic', 'synthetic', 'test')
                    $collector = [ExchangeLogReport.Collector]::new($s, $o)
                    $jobs = foreach ($spec in @(@('Tracking', $trk), @('SmtpReceive', $smtp))) {
                        $j = [ExchangeLogReport.SourceJob]::new(); $j.Server = 'EX1'; $j.Kind = $spec[0]; $j.Folder = $spec[1]; $j.Role = 'FrontEnd'; $j
                    }
                    $collector.Plan(@($jobs), [datetime]::MinValue)
                    $run = $collector.Start(@($jobs))
                    [void]$run.Wait(-1)
                    if ($run.Error) { throw $run.Error }
                    [void]$collector.Complete()
                    if ($step -eq 2) { ($trace.Count) | Should -BeGreaterThan 0; $trace[$trace.Count - 1] | Should -BeExactly '' }
                }
                $queue = @($trace | ForEach-Object { $_ -split "`n" } | Where-Object { $_ } | Sort-Object -Unique) -join "`n"
                $results[$mode] = [pscustomobject]@{
                    Queue = $queue
                    Data = (Dump $s 'SELECT * FROM message_event ORDER BY id;') + "`n--`n" + (Dump $s 'SELECT * FROM smtp_transaction ORDER BY id;') + "`n--`n" + (Dump $s 'SELECT * FROM message_rollup ORDER BY id;')
                    Mail = [long]$s.Scalar('SELECT COUNT(*) FROM message_event;', $null) + [long]$s.Scalar('SELECT COUNT(*) FROM smtp_transaction;', $null)
                }
                $s.VerifyServeRollups().Verified | Should -BeTrue
                $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;', $null) | Should -Be 0
                # Every trigger is still defined, and runs on this very connection after the collection.
                $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND (name LIKE 'tr_%_rollup_%' OR name LIKE 'tr_%_hash_%');", $null) | Should -Be 10
                Sql $s "INSERT INTO message_event(time_ms,server,event_id,message_id,log_id) VALUES(@t,'EX1','RECEIVE','<after@test>','after');" @{ t = $script:Epoch }
                $s.Scalar("SELECT COUNT(*) FROM message_rollup_dirty WHERE identity='<after@test>';", $null) | Should -Be 1
                # Another connection (the portal, a verifier, an external writer) always runs the triggers.
                $other = [ExchangeLogReport.Store]::new($s.FilePath, $false, 'synthetic')
                try {
                    Sql $other "INSERT INTO message_event(time_ms,server,event_id,message_id,log_id) VALUES(@t,'EX1','RECEIVE','<other@test>','other');" @{ t = $script:Epoch }
                } finally { $other.Dispose() }
                $s.Scalar("SELECT COUNT(*) FROM message_rollup_dirty WHERE identity='<other@test>';", $null) | Should -Be 1
            } finally { $s.Dispose() }
        }
        $results['triggers'].Mail | Should -BeGreaterThan 10
        $results['triggers'].Queue | Should -Match 'smtp\|\d+\|NULL'
        $results['triggers'].Queue | Should -Match 'message\|<later@test>\|'
        $results['code'].Queue | Should -BeExactly $results['triggers'].Queue
        $results['code'].Data | Should -BeExactly $results['triggers'].Data
    }

    It 'deferring the rollups to the end of the collection gives the same rollups as reconciling with every commit, with triggers or with the code' {
        # One file per batch (BatchRows=1), collected three times (new rows; the files read again, every insert ignored; more files and rows).
        # Ids follow the drain order, so the rows are compared without id (codes decoded); ids must be unique, positive, below the sequence and stable.
        $trkOne = @("$(RollupAt 1),RECEIVE,<Case@test>,1,a1,s@test,r@test,one", "$(RollupAt 2),DELIVER,<Case@test>,1,a2,s@test,r@test,one", "$(RollupAt 3),RECEIVE,<case@test>,2,a3,s@test,r@test,two")
        $trkTwo = @("$(RollupAt 4),RECEIVE,<tracking-only@test>,3,a4,s@test,r@test,three", "$(RollupAt 5),RECEIVE,<`u{e9}`u{1F600}@test>,4,a5,s@test,r@test,unicode",
            "$(RollupAt 6),RECEIVE,<`u{1F600}@test>,6,a8,s@test,r@test,astral", "$(RollupAt 7),RECEIVE,<`u{E000}@test>,7,a9,s@test,r@test,private use")
        $trkMore = @("$(RollupAt 100),DELIVER,<tracking-only@test>,3,a6,s@test,r@test,three", "$(RollupAt 101),RECEIVE,<later@test>,5,a7,s@test,r@test,later")
        $decoded = @{}
        foreach ($defer in 'Never', 'Always') {
            foreach ($mode in 'triggers', 'code') {
                $name = "$defer-$mode"
                $trk = Join-Path $TestDrive "defer-$name-trk"; $smtp = Join-Path $TestDrive "defer-$name-smtp"
                foreach ($d in $trk, $smtp) { [void][IO.Directory]::CreateDirectory($d) }
                New-RollupTrackingLog (Join-Path $trk 't1.log') $trkOne 1
                New-RollupTrackingLog (Join-Path $trk 't2.log') $trkTwo 2
                New-RollupSmtpLog (Join-Path $smtp 's1.log') @(@{ Session = '0AAA000000000001'; Base = 10; Id = '<Case@test>' }, @{ Session = '0AAA000000000002'; Base = 30; Id = '<smtp-only@test>' }) 1
                New-RollupSmtpLog (Join-Path $smtp 's2.log') @(@{ Session = '0AAA000000000003'; Base = 50 }) 2
                $s = New-SyntheticStore "defer-$name"
                try {
                    $before = @{}
                    foreach ($step in 1..3) {
                        if ($step -eq 2) { $s.Exec('UPDATE source_file SET offset=0,size=0;') }
                        if ($step -eq 3) {
                            New-RollupTrackingLog (Join-Path $trk 't3.log') $trkMore 3
                            New-RollupSmtpLog (Join-Path $smtp 's3.log') @(@{ Session = '0AAA000000000004'; Base = 120 }, @{ Session = '0AAA000000000005'; Base = 140; Id = '<later@test>' }) 3
                        }
                        $run = Invoke-RollupCollection $s @{ Tracking = $trk; SmtpReceive = $smtp } $defer ($mode -eq 'code')
                        [void]$run.Wait(-1)
                        if ($defer -eq 'Always') { $run.Statistics | Should -Match 'message rollups deferred to the end of the collection' } else { $run.Statistics | Should -Match 'message rollups reconciled with every commit' }
                        if ($step -ne 2) {
                            $run.Statistics -match '\((\d+) batches\)' | Should -BeTrue; [int]$Matches[1] | Should -BeGreaterThan 1 -Because "$name step $step"
                            $run.Statistics -match 'final rollup drain \d+[.,]\d s, (\d+) keys' | Should -BeTrue
                            if ($defer -eq 'Always') { [int]$Matches[1] | Should -BeGreaterThan 0 } else { [int]$Matches[1] | Should -Be 0 }
                        }
                        $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;', $null) | Should -Be 0 -Because "$name step $step"
                        $s.VerifyServeRollups().Verified | Should -BeTrue -Because "$name step $step"
                        $s.Scalar('SELECT COUNT(*) FROM message_rollup;', $null) | Should -BeGreaterThan 0
                        $s.Scalar('SELECT COUNT(DISTINCT id)-COUNT(*) FROM message_rollup;', $null) | Should -Be 0
                        $s.Scalar('SELECT MIN(id) FROM message_rollup;', $null) | Should -BeGreaterThan 0
                        $s.Scalar("SELECT (SELECT seq FROM sqlite_sequence WHERE name='message_rollup')-MAX(id) FROM message_rollup;", $null) | Should -BeGreaterOrEqual 0
                        $ids = Get-RollupIds $s
                        foreach ($key in $before.Keys) { $ids[$key] | Should -Be $before[$key] -Because "$name step $step keeps the id of $key" }
                        $before = $ids
                        $decoded["$name/$step"] = Get-RollupDecoded $s
                    }
                } finally { $s.Dispose() }
            }
        }
        foreach ($step in 1..3) {
            foreach ($name in 'Never-code', 'Always-triggers', 'Always-code') { $decoded["$name/$step"] | Should -BeExactly $decoded["Never-triggers/$step"] -Because "$name step $step" }
        }
    }

    It 'keeps a deferred collection recoverable: the queue stays committed, Serve and the verifier fail closed, and the next collection, Purge or a refresh drains it' {
        $trk = Join-Path $TestDrive 'recover-trk'; [void][IO.Directory]::CreateDirectory($trk)
        foreach ($n in 1..6) {
            New-RollupTrackingLog (Join-Path $trk "t$n.log") @(1..3 | ForEach-Object { "$(RollupAt ($n * 10 + $_)),RECEIVE,<m$n-$_@test>,$n$_,a$n$_,s@test,r@test,subject $n $_" }) $n
        }
        foreach ($recovery in 'collection', 'purge', 'refresh') {
            $s = New-SyntheticStore "recover-$recovery"
            try {
                # A key the drain cannot reconcile (an SMTP identity that is not a row id) fails the run after its batches were committed.
                $s.Exec("INSERT INTO message_rollup_dirty(kind,identity,msg_hash) VALUES('smtp','poison',NULL);")
                $run = Start-RollupCollection $s @{ Tracking = $trk } 'Always' $true
                [void]$run.Wait(-1)
                $run.Error | Should -Not -BeNullOrEmpty -Because 'the drain failed'
                $s.Scalar('SELECT COUNT(*) FROM message_event;', $null) | Should -Be 18 -Because 'the batches are committed'
                $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;', $null) | Should -BeGreaterThan 1
                # The verifier runs Serve's Ready() first: the same RollupPending refusal that Serve answers with 503.
                { $s.VerifyServeRollups() } | Should -Throw '*unreconciled*'
                $s.Exec("DELETE FROM message_rollup_dirty WHERE identity='poison';")
                { $s.VerifyServeRollups() } | Should -Throw '*unreconciled*'
                switch ($recovery) {
                    'collection' {
                        New-RollupTrackingLog (Join-Path $trk 'more.log') @("$(RollupAt 500),RECEIVE,<more@test>,9,a9,s@test,r@test,more") 9
                        [void](Invoke-RollupCollection $s @{ Tracking = $trk } 'Never' $true)
                        Remove-Item -LiteralPath (Join-Path $trk 'more.log')
                    }
                    'purge' { [void]$s.Purge(0, '0000-00-00', 0) }
                    'refresh' { $s.RefreshServeRollups() }
                }
                $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;', $null) | Should -Be 0
                $s.VerifyServeRollups().Verified | Should -BeTrue
                $s.Scalar('SELECT COUNT(*) FROM message_rollup;', $null) | Should -Be $(if ($recovery -eq 'collection') { 19 } else { 18 })
            } finally { $s.Dispose() }
        }
        # A stop after the first batch: the run ends either drained and verified, or with the queue committed and the verifier refusing; then a collection drains it.
        $stopTrk = Join-Path $TestDrive 'stop-trk'; [void][IO.Directory]::CreateDirectory($stopTrk)
        foreach ($n in 1..60) {
            New-RollupTrackingLog (Join-Path $stopTrk ("t{0:00}.log" -f $n)) @(1..40 | ForEach-Object { "$(RollupAt ($n * 100 + $_)),RECEIVE,<s$n-$_@test>,$n$_,a$n$_,s@test,r@test,subject" }) $n
        }
        $s = New-SyntheticStore 'recover-stop'
        try {
            $run = Start-RollupCollection $s @{ Tracking = $stopTrk } 'Always' $true
            while (-not $run.Wait(1)) { if ($run.Progress().FilesDone -ge 1) { $run.Stop(); break } }
            [void]$run.Wait(-1)
            if ($run.Error) { throw $run.Error }
            if ($s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;', $null) -gt 0) { { $s.VerifyServeRollups() } | Should -Throw '*unreconciled*' }
            else { $s.VerifyServeRollups().Verified | Should -BeTrue }
            New-RollupTrackingLog (Join-Path $stopTrk 'zz.log') @("$(RollupAt 9000),RECEIVE,<zz@test>,9,a9,s@test,r@test,zz") 99
            [void](Invoke-RollupCollection $s @{ Tracking = $stopTrk } 'Never' $true)
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;', $null) | Should -Be 0
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
    }

    It 'reconciles with every commit by default, chooses the bulk mode by itself only for an initial import above the threshold, and drains a large leftover queue before the first batch' {
        [ExchangeLogReport.CollectorOptions]::new().DeferRollups | Should -Be ([ExchangeLogReport.DeferRollupsMode]::Never)
        $trk = Join-Path $TestDrive 'auto-trk'; [void][IO.Directory]::CreateDirectory($trk)
        New-RollupTrackingLog (Join-Path $trk 'a.log') @(1..3 | ForEach-Object { "$(RollupAt $_),RECEIVE,<a$_@test>,$_,a$_,s@test,r@test,subject" }) 1
        # Empty database, planned bytes above a tiny threshold: initial import. Then message_rollup is not empty any more: per commit.
        $s = New-SyntheticStore 'auto-empty'
        try {
            $run = Invoke-RollupCollection $s @{ Tracking = $trk } 'Auto' $true 1
            $run.Statistics | Should -Match 'message rollups deferred to the end of the collection \(Auto: initial import'
            $s.Scalar('SELECT COUNT(*) FROM message_rollup;', $null) | Should -Be 3
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;', $null) | Should -Be 0
            New-RollupTrackingLog (Join-Path $trk 'b.log') @("$(RollupAt 20),RECEIVE,<b@test>,9,b9,s@test,r@test,subject") 2
            $run = Invoke-RollupCollection $s @{ Tracking = $trk } 'Auto' $true 1
            $run.Statistics | Should -Match 'message rollups reconciled with every commit'
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
        # Default threshold (5 GB): a small import is reconciled with every commit.
        $s = New-SyntheticStore 'auto-small'
        try {
            (Invoke-RollupCollection $s @{ Tracking = $trk } 'Auto' $true).Statistics | Should -Match 'message rollups reconciled with every commit'
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
        # More than 100 000 keys left in the queue (an interrupted bulk run): Auto and Never drain them in chunks before the first batch, then
        # reconcile with every commit; Always keeps deferring and drains them with its own keys at the end.
        foreach ($defer in 'Auto', 'Never', 'Always') {
            $s = New-SyntheticStore "auto-leftover-$defer"
            try {
                $s.Exec("INSERT INTO message_rollup_dirty(kind,identity,msg_hash) WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<100500) SELECT 'message','<seed'||i||'@test>',NULL FROM n;")
                $run = Invoke-RollupCollection $s @{ Tracking = $trk } $defer $true
                $run.Statistics -match 'final rollup drain \d+[.,]\d s, (\d+) keys' | Should -BeTrue
                if ($defer -eq 'Always') {
                    $run.Statistics | Should -Match 'message rollups deferred to the end of the collection \(DeferRollups Always\)'
                    [int]$Matches[1] | Should -BeGreaterOrEqual 100504
                } else {
                    [int]$Matches[1] | Should -Be 0 -Because "$defer does not defer"
                    $run.Statistics | Should -Match 'message rollups reconciled with every commit, after a drain of 100500 keys left in the queue \(\d+[.,]\d s\)'
                    $run.Statistics -match 'message rollups [\d.,]+ s \((\d+) keys\)' | Should -BeTrue
                    [int]$Matches[1] | Should -BeGreaterOrEqual 100504 -Because 'the leftover and the keys of the batches are reconciled'
                }
                $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;', $null) | Should -Be 0
                $s.Scalar('SELECT COUNT(*) FROM message_rollup;', $null) | Should -Be 4
                $s.VerifyServeRollups().Verified | Should -BeTrue
            } finally { $s.Dispose() }
        }
    }

    It 'keeps the WAL bounded with WalRestartBytes, per commit or deferred, and gives the same rollups as an unbounded WAL' {
        # 40 files of one batch each (BatchRows=1), a few hundred KB of WAL per batch: a 1 MB bound empties the WAL every few batches.
        $trk = Join-Path $TestDrive 'walbound-trk'; [void][IO.Directory]::CreateDirectory($trk)
        $random = [Random]::new(11)
        foreach ($n in 1..40) {
            $lines = foreach ($i in 1..150) {
                $subject = -join (1..120 | ForEach-Object { [char]$random.Next(97, 123) })
                "$(RollupAt ($n * 1000 + $i)),RECEIVE,<w$n-$i@test>,$n$i,l$n-$i,s$i@test,r$n@test,$subject"
            }
            New-RollupTrackingLog (Join-Path $trk ("t{0:00}.log" -f $n)) @($lines) $n
        }
        $decoded = @{}
        $maxWal = @{}
        foreach ($defer in 'Never', 'Always') {
            foreach ($bound in 0L, 1MB) {
                $name = "$defer-$bound"
                $s = New-SyntheticStore "walbound-$name"
                try {
                    $run = Invoke-RollupCollection $s @{ Tracking = $trk } $defer $true -1 1 $bound
                    $run.Statistics -match '\((\d+) batches\)' | Should -BeTrue; [int]$Matches[1] | Should -Be 40
                    $run.Statistics -match '(\d+) WAL restart\(s\) \(\d+[.,]\d s\), max WAL (\d+[.,]\d) MB' | Should -BeTrue -Because $run.Statistics
                    [int]$restarts = $Matches[1]
                    $maxWal[$name] = [double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture) * 1MB
                    if ($bound -eq 0) { $restarts | Should -Be 0 }
                    else {
                        $restarts | Should -BeGreaterOrEqual 1 -Because $run.Statistics
                        # Never more than the bound plus the WAL of a few batches (one commit, or one drain chunk, past the bound).
                        $maxWal[$name] | Should -BeLessThan (6MB) -Because $run.Statistics
                        $s.WalBytes | Should -BeLessThan (6MB)
                    }
                    $s.Scalar('SELECT COUNT(*) FROM message_event;', $null) | Should -Be 6000
                    $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;', $null) | Should -Be 0
                    $s.VerifyServeRollups().Verified | Should -BeTrue -Because $name
                    (Rows $s 'PRAGMA journal_mode;')[0][0] | Should -BeExactly 'wal'
                    (Rows $s 'PRAGMA integrity_check;')[0][0] | Should -BeExactly 'ok'
                    $decoded[$name] = Get-RollupDecoded $s
                } finally { $s.Dispose() }
            }
            $maxWal["$defer-0"] | Should -BeGreaterThan ($maxWal["$defer-$(1MB)"] * 2) -Because 'without a bound the WAL keeps every batch'
            $decoded["$defer-$(1MB)"] | Should -BeExactly $decoded["$defer-0"]
        }
        $decoded["Always-0"] | Should -BeExactly $decoded["Never-0"]
    }

    It 'counts the frames of the background checkpoints as differences of the cumulative backfill, and checkpoints without turning the automatic copies back on' {
        $delta = [ExchangeLogReport.Collector].GetMethod('FrameDelta', [Reflection.BindingFlags]'Static,NonPublic')
        # Rows (log, backfill) of successive PRAGMA wal_checkpoint(PASSIVE) calls: nBackfill is counted from the start of the log, not per call.
        $rows = @(@(100, 100), @(100, 100), @(150, 120), @(150, 150), @(30, 30), @(-1, -1), @(40, 40), @(200, 10))
        $last = @(0L, 0L); $total = 0L; $summed = 0L
        foreach ($row in $rows) {
            $total += [long]$delta.Invoke($null, [object[]]@([long]$last[0], [long]$last[1], [long]$row[0], [long]$row[1]))
            if ($row[1] -gt 0) { $summed += $row[1] }
            if ($row[0] -ge 0) { $last = @([long]$row[0], [long]$row[1]) }
        }
        # 100 + 0 + 20 + 30, the log restarted: 30, nothing for the busy row, + 10, restarted again (backfill went down): 10.
        $total | Should -Be 200
        $summed | Should -Be 550 -Because 'the old statistic summed the cumulative column'
        $s = New-SyntheticStore 'checkpoint-mode'
        try {
            $s.Exec('PRAGMA wal_autocheckpoint=0;')
            Add-SyntheticMail $s
            $s.WalBytes | Should -BeGreaterThan 0
            $r = $s.Checkpoint('TRUNCATE')
            $r.Complete | Should -BeTrue
            $s.WalBytes | Should -Be 0
            $s.Scalar('PRAGMA wal_autocheckpoint;', $null) | Should -Be 0
            $s.Checkpoint('passive').Busy | Should -Be 0
            { $s.Checkpoint('OFF') } | Should -Throw
            (Rows $s 'PRAGMA journal_mode;')[0][0] | Should -BeExactly 'wal'
        } finally { $s.Dispose() }
    }

    It 'orders the in-memory rollup keys like SQLite BINARY on the UTF-8 bytes' {
        $names = @('a', 'Z', "`u{e9}", "`u{E000}", "`u{FFFF}", "`u{10000}", "`u{1F600}", "a`u{1F600}", "a`u{E000}", 'ab', 'a', '<x@test>', "<`u{e9}@test>", '9', '10', '100', '', '9a')
        $s = New-SyntheticStore 'utf8-order'
        try {
            Sql $s 'CREATE TABLE order_check(identity TEXT COLLATE BINARY NOT NULL);'
            foreach ($name in $names) { Sql $s 'INSERT INTO order_check VALUES(@i);' @{ i = $name } }
            $expected = @($s.Query('SELECT identity FROM order_check ORDER BY identity;', $null).Rows | ForEach-Object { $_[0] })
            $sorted = [string[]]$names.Clone()
            [Array]::Sort($sorted, [Comparison[string]]{ param($a, $b) [ExchangeLogReport.Store]::CompareUtf8Binary($a, $b) })
            ($sorted -join "`n") | Should -BeExactly ($expected -join "`n")
            # string.CompareOrdinal differs here, which is why it is not used.
            [string]::CompareOrdinal("`u{1F600}", "`u{E000}") | Should -BeLessThan 0
            [ExchangeLogReport.Store]::CompareUtf8Binary("`u{1F600}", "`u{E000}") | Should -BeGreaterThan 0
            [ExchangeLogReport.Store]::CompareUtf8Binary('10', '9') | Should -BeLessThan 0
        } finally { $s.Dispose() }
    }
}

Describe 'Collection throughput: work of the apply thread done elsewhere, same bytes' {
    BeforeAll {
        $script:Asm = [ExchangeLogReport.Store].Assembly
        $script:Hidden = [Reflection.BindingFlags]'Instance,Static,NonPublic,Public'
        # Reference: the text as written and read back by BinaryWriter / BinaryReader (UTF-8).
        function RoundTrip([string]$Text) {
            $ms = [IO.MemoryStream]::new()
            $w = [IO.BinaryWriter]::new($ms, [Text.Encoding]::UTF8, $true); $w.Write($Text); $w.Dispose()
            $ms.Position = 0
            $r = [IO.BinaryReader]::new($ms, [Text.Encoding]::UTF8); $back = $r.ReadString(); $r.Dispose()
            return $back
        }
        # The bytes SQLite stores for a value bound by Prepared.Set (TEXT: UTF-8; BLOB as is; NULL).
        function BoundBytes($Value) {
            if ($null -eq $Value) { return 'NULL' }
            if ($Value -is [byte[]]) { return 'B:' + [Convert]::ToHexString($Value) }
            return 'T:' + [Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes([string]$Value))
        }
        $script:Tricky = @(
            '', 'ascii only', "caf`u{e9} `u{4e16}`u{754c}", "emoji `u{1F600} pair", (('x' * 11999) + "`u{1F600}"), (('y' * 12000) + "`u{1F600}tail"),
            "lone high at the end $([char]0xD83D)", "$([char]0xDE00) lone low at the start", "mid $([char]0xD800) dle", "two $([char]0xDBFF)$([char]0xDBFF) highs",
            ('z' * 300), ((1..60 | ForEach-Object { "line $_ `u{e9}`u{1F600}" }) -join "`n"))
    }

    It 'packs the SMTP transcripts, responses and message hashes on the parse thread with the bytes the apply thread computed from the spool' {
        $collector = [ExchangeLogReport.Collector]
        $spoolText = $collector.GetMethod('SpoolText', $script:Hidden)
        $packTranscript = $collector.GetMethod('PackTranscript', $script:Hidden)
        $context = [Activator]::CreateInstance($script:Asm.GetType('ExchangeLogReport.Collector+ParseContext'), $true)
        foreach ($text in $script:Tricky) {
            $back = RoundTrip $text
            [string]::CompareOrdinal($spoolText.Invoke($null, @($text)), $back) | Should -Be 0 -Because "SpoolText of '$text'"
            [ExchangeLogReport.Store]::MessageHash($text) | Should -Be ([ExchangeLogReport.Store]::MessageHash($back))
            (BoundBytes ([ExchangeLogReport.Packed]::Adaptive($text))) | Should -BeExactly (BoundBytes ([ExchangeLogReport.Packed]::Adaptive($back)))
            foreach ($preamble in $script:Tricky) {
                # Before: Pack(Cap(preamble + body, 12000)) of the two texts read back from the spool.
                $old = [ExchangeLogReport.Packed]::Pack([ExchangeLogReport.Identity]::Cap((RoundTrip $preamble) + $back, 12000))
                $new = $packTranscript.Invoke($null, @($context, $spoolText.Invoke($null, @($preamble)), $text))
                [Convert]::ToHexString($new) | Should -BeExactly ([Convert]::ToHexString($old))
            }
        }
        $context.PackSeconds | Should -BeGreaterThan 0
        # Through the spool: transactions written before the end of the session (raw body, packed by PackTranscripts) and the last one (packed already).
        $folder = Join-Path $TestDrive 'spool'; [void][IO.Directory]::CreateDirectory($folder)
        $spool = [Activator]::CreateInstance($script:Asm.GetType('ExchangeLogReport.SmtpSpool'), [object[]]@([string]$folder))
        try {
            $txType = $script:Asm.GetType('ExchangeLogReport.SmtpSpoolTx')
            $preamble = "$([char]0xDE00)preamble `u{1F600}`n"
            $expected = @{}
            for ($i = 0; $i -lt $script:Tricky.Count; $i++) {
                $x = [Activator]::CreateInstance($txType, $true)
                $x.StartMs = 1000 + $i; $x.MailFrom = "s$i@test"; $x.MessageId = "<m$i-$($script:Tricky[$i])@test>"; $x.Status = 'Accepted'
                # Set through reflection: PowerShell would turn $null into '' for a string field.
                $txType.GetField('Body').SetValue($x, $(if ($i % 4 -eq 3) { $null } else { $script:Tricky[$i] }))
                $x.PackedResponse = [ExchangeLogReport.Packed]::Adaptive("250 queued $($script:Tricky[$i])")
                $x.MessageHash = [ExchangeLogReport.Store]::MessageHash($x.MessageId)
                if ($i % 2 -eq 0 -and $null -ne $x.Body) { $x.PackedTranscript = $packTranscript.Invoke($null, @($context, $spoolText.Invoke($null, @($preamble)), $x.Body)) }
                $expected[$i] = [pscustomobject]@{
                    Transcript = if ($null -eq $x.Body) { 'NULL' } else { [Convert]::ToHexString([ExchangeLogReport.Packed]::Pack([ExchangeLogReport.Identity]::Cap((RoundTrip $preamble) + (RoundTrip $x.Body), 12000))) }
                    Response = BoundBytes ([ExchangeLogReport.Packed]::Adaptive((RoundTrip "250 queued $($script:Tricky[$i])")))
                    Hash = [ExchangeLogReport.Store]::MessageHash((RoundTrip $x.MessageId))
                }
                $spool.AddTx([long]7, $i, $x)
            }
            { $spool.ReadTx([long]7, 0, 100) } | Should -Throw '*not packed*'
            $pack = [Func[string, byte[]]]{ param($body) $packTranscript.Invoke($null, @($context, $spoolText.Invoke($null, @($preamble)), $body)) }
            $spool.PackTranscripts([long]7, $pack) | Should -Be (@(0..($script:Tricky.Count - 1) | Where-Object { $_ % 4 -ne 3 -and $_ % 2 -eq 1 }).Count)
            $read = @($spool.ReadTx([long]7, 0, 100))
            $read.Count | Should -Be $script:Tricky.Count
            foreach ($kv in $read) {
                $e = $expected[$kv.Key]
                $(if ($null -eq $kv.Value.PackedTranscript) { 'NULL' } else { [Convert]::ToHexString($kv.Value.PackedTranscript) }) | Should -BeExactly $e.Transcript -Because "transaction $($kv.Key)"
                (BoundBytes $kv.Value.PackedResponse) | Should -BeExactly $e.Response
                $kv.Value.MessageHash | Should -Be $e.Hash
            }
        } finally { $spool.Dispose() }
    }

    It 'stores every transcript of a session with its final preamble, the responses packed and the hashes bound, as the apply thread did' {
        $s = New-SyntheticStore 'parse-pack'
        $dir = Join-Path $TestDrive 'parse-pack-smtp'; [void][IO.Directory]::CreateDirectory($dir)
        $long = '250 2.6.0 <two@test> [InternalId=2, Hostname=EX1] Queued mail for delivery ' + ('x' * 250)
        $steps = @('+|', '>|220 ready', '<|EHLO synthetic.test', "> |250 hello `u{e9}", '<|MAIL FROM:<a@test>', '>|250 sender OK', '<|RCPT TO:<r@test>', '>|250 OK', '<|DATA', '>|354 go',
            '>|250 2.6.0 <one@test> [InternalId=1, Hostname=EX1] Queued mail for delivery', '<|RSET', "> |250 reset `u{1F600}", '<|NOOP', '>|250 noop between',
            '<|MAIL FROM:<b@test>', '>|250 sender OK', '<|RCPT TO:<r2@test>', '>|250 OK', '<|DATA', '>|354 go', ">|$long",
            '<|MAIL FROM:<c@test>', '>|250 OK', '<|RCPT TO:<r3@test>', '>|550 5.1.1 unknown', '<|QUIT', '>|221 bye after the last', '-|')
        $lines = @('#Fields: date-time,connector-id,session-id,sequence-number,local-endpoint,remote-endpoint,event,data,context')
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $parts = $steps[$i].Split('|'); $time = [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch + $i * 1000).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $lines += "$time,EX1\Client Frontend EX1,ABCDEF02,$i,192.0.2.2:587,192.0.2.1:50000,$($parts[0].Trim()),`"$($parts[1].Replace('"', '""'))`","
        }
        try {
            [IO.File]::WriteAllLines((Join-Path $dir 'smtp.log'), $lines)
            Collect-Synthetic $s $dir 'SmtpReceive'
            $rows = Rows $s 'SELECT mail_from,transcript,response,typeof(response),message_id,msg_hash FROM smtp_transaction ORDER BY id;'
            $rows.Count | Should -Be 3
            $texts = @($rows | ForEach-Object { [ExchangeLogReport.Packed]::Text($_[1]) })
            # The preamble is every line outside the transactions, also those after the first and the last transaction (known at the end of the session only).
            $head = $texts[2].Substring(0, $texts[2].LastIndexOf("`n", $texts[2].IndexOf('C: MAIL FROM:<c@test>')) + 1)
            $head | Should -Match 'noop between'
            $head | Should -Match 'bye after the last'
            $head | Should -Match "reset `u{1F600}"
            foreach ($t in $texts) { $t.StartsWith($head, [StringComparison]::Ordinal) | Should -BeTrue }
            $texts[0] | Should -Match 'C: RCPT TO:<r@test>'
            $texts[1] | Should -Match 'C: RCPT TO:<r2@test>'
            $rows[1][3] | Should -BeExactly 'blob'
            [ExchangeLogReport.Packed]::Text($rows[1][2]) | Should -BeExactly $long
            $rows[2][2] | Should -BeExactly '550 5.1.1 unknown'
            $s.Scalar('SELECT COUNT(*) FROM smtp_transaction WHERE msg_hash IS NOT exl_msg_hash(message_id);', $null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM smtp_transaction WHERE message_id IS NULL AND msg_hash IS NULL;', $null) | Should -Be 1
        } finally { $s.Dispose() }
    }

    It 'binds the tracking msg_hash computed by the parse thread, NULL without Message-ID, and queues the rollups with it' {
        $s = New-SyntheticStore 'parse-hash'
        $dir = Join-Path $TestDrive 'parse-hash-trk'; [void][IO.Directory]::CreateDirectory($dir)
        try {
            [IO.File]::WriteAllLines((Join-Path $dir 'tracking.log'), [string[]]@(
                '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address'
                "2026-01-01T00:00:01.000Z,RECEIVE,<caf`u{e9}`u{1F600}@test>,1,a,sender@test,recipient@test"
                "2026-01-01T00:00:02.000Z,DELIVER,<caf`u{e9}`u{1F600}@test>,1,b,sender@test,recipient@test"
                '2026-01-01T00:00:03.000Z,FAIL,,2,c,sender@test,recipient@test'))
            Collect-Synthetic $s $dir 'Tracking'
            $s.Scalar('SELECT COUNT(*) FROM message_event;', $null) | Should -Be 3
            $s.Scalar('SELECT COUNT(*) FROM message_event WHERE msg_hash IS NOT exl_msg_hash(message_id);', $null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM message_event WHERE message_id IS NULL AND msg_hash IS NULL;', $null) | Should -Be 1
            $s.Scalar("SELECT msg_hash FROM message_rollup WHERE identity='<caf`u{e9}`u{1F600}@test>';", $null) | Should -Be ([ExchangeLogReport.Store]::MessageHash("<caf`u{e9}`u{1F600}@test>"))
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
    }

    It 'writes the session steps JSON into a reused buffer and packs it with the bytes of Pack(StepsJson) for every step shape' {
        $s = New-SyntheticStore 'steps-json'
        try {
            $o = [ExchangeLogReport.CollectorOptions]::new(); $o.NowMs = $script:Epoch
            $collector = [ExchangeLogReport.Collector]::new($s, $o)
            $stepType = $script:Asm.GetType('ExchangeLogReport.SessionStep')
            $listType = [Collections.Generic.List`1].MakeGenericType($stepType)
            $packSteps = [ExchangeLogReport.Collector].GetMethod('PackSteps', $script:Hidden)
            $stepsJson = [ExchangeLogReport.Collector].GetMethod('StepsJson', $script:Hidden)
            $valid = @($null, '', 'FE', "caf`u{e9}", "`u{1F600} astral", '<script>&"quote"\back', "tab`tnew`nline", ('w' * 5000), "ctl $([char]1)$([char]31)", "`u{2028}`u{2029}`u{FEFF}")
            # Every tenth round also draws texts with a lone surrogate (both paths must then fail, or give the same bytes).
            $lone = @("lone $([char]0xD83D)", "$([char]0xDE00) low")
            $random = [Random]::new(7)
            $pick = { $texts[$random.Next($texts.Count)] }
            $checked = 0; $failedBoth = 0
            foreach ($round in 1..120) {
                $texts = if ($round % 10 -eq 0) { $valid + $lone } else { $valid }
                $list = [Activator]::CreateInstance($listType)
                $n = if ($round % 30 -eq 0) { 400 } else { $random.Next(0, 12) }
                for ($i = 0; $i -lt $n; $i++) {
                    $st = [Activator]::CreateInstance($stepType, $true)
                    $st.T = [long]$random.Next() * 1000; $st.T2 = $st.T + $random.Next(0, 100000)
                    $st.Front = & $pick; $st.Back = & $pick; $st.Action = & $pick; $st.Detail = & $pick; $st.RequestId = & $pick; $st.Needle = & $pick; $st.Needle2 = & $pick
                    $st.Source = if ($random.Next(2) -eq 0) { 'FE' } else { & $pick }
                    $st.Status = $random.Next(-1, 600); $st.Count = $random.Next(0, 50); $st.Failures = $random.Next(0, 3)
                    $st.TotalMs = [long]$random.Next() * 7; $st.MaxMs = $random.Next(); $st.FileId = $random.Next(1, 1000)
                    if ($random.Next(3) -eq 0) {
                        $st.Batch = $true
                        $actions = [Collections.Generic.Dictionary[string, int]]::new()
                        foreach ($k in 1..$random.Next(1, 4)) { $name = [string](& $pick); if ($null -eq $name) { $name = 'none' }; $actions[$name + $k] = $random.Next(1, 9) }
                        $st.BatchActions = $actions
                    }
                    $listType.GetMethod('Add').Invoke($list, @($st))
                }
                $old = $null; $new = $null; $oldError = $null; $newError = $null
                try { $old = [ExchangeLogReport.Packed]::Pack([string]$stepsJson.Invoke($null, [object[]]@(, $list))) } catch { $oldError = $_.Exception.InnerException.GetType().Name }
                try { $new = [byte[]]$packSteps.Invoke($collector, [object[]]@(, $list)) } catch { $newError = $_.Exception.InnerException.GetType().Name }
                $newError | Should -Be $oldError -Because "round $round"
                if ($null -eq $oldError) { [Convert]::ToHexString($new) | Should -BeExactly ([Convert]::ToHexString($old)) -Because "round $round"; $checked++ } else { $failedBoth++ }
            }
            $checked | Should -BeGreaterThan 100
        } finally { $s.Dispose() }
    }

    It 'reads the rollup sources through raw statements with the values of the Microsoft.Data.Sqlite path, whatever the storage class' {
        $field = [ExchangeLogReport.Store].GetField('RawRollupReads', $script:Hidden)
        $field.GetValue($null) | Should -BeTrue
        $dumps = @{}
        try {
            foreach ($raw in $true, $false) {
                $field.SetValue($null, $raw)
                $s = New-SyntheticStore "raw-reads-$raw"
                try {
                    # INTEGER columns holding REAL and TEXT, TEXT columns holding INTEGER, REAL and packed BLOBs, NULLs, non-ASCII and astral text.
                    Sql $s @"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,recipient_count,total_bytes,subject,directionality) VALUES
 (@t+0.5,'EX1','RECEIVE','<m1@test>','l1',NULL,'a@test;b@test',2,1234,'plain','Incoming'),
 (@t+1.5,'EX`u{e9}2','DELIVER','<m1@test>','l2','late@test','a@test',2.5,'4321',@packed,NULL),
 (@t+2,42,NULL,'<m1@test>','l3','s@test','`u{1F600}@test;c@test','7',2047.5,99,3.25),
 (@t+3,'EX1','FAIL','<m2-`u{1F600}@test>','l4',@packedSender,'x@test',NULL,NULL,NULL,'Outgoing'),
 (@t+4.4,'EX1','SEND','<m2-`u{1F600}@test>','l5','s2@test','x@test;y@test',1.5,1e3,'s','Originating'),
 (@t+5,'ex1','RECEIVE','<m3@test>','l6','s3@test','',0,-1,'',''),
 (@t+6,'EX3','EXPAND','<m3@test>','l7','s3@test','z@test',3,0,'zero','Incoming');
INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,session_id,message_id,status,mail_from,rcpts) VALUES
 (@t+10.7,@t+11,'EX1','Receive','s1','<m1@test>','Accepted','s@test','a@test'),
 (@t+3.2,NULL,'EX2','Send','s2','<m1@test>','Sent','s@test','a@test'),
 (@t+20,@t+21,'EX1','Receive','s3','<smtp-only@test>','Accepted','o@test','p@test;q@test'),
 (@t+22.9,NULL,'EX`u{e9}','Receive','s4','<smtp-only@test>','Deferred','o@test','p@test'),
 (@t+30,NULL,'EX1','Receive','s5',NULL,'Rejected','r@test','nobody@test');
"@ @{ t = $script:Epoch; packed = [ExchangeLogReport.Packed]::Pack("packed subject `u{e9}`u{1F600}"); packedSender = [ExchangeLogReport.Packed]::Pack('packed@test') }
                    $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;', $null) | Should -BeGreaterThan 3
                    $s.RefreshServeRollups()
                    $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;', $null) | Should -Be 0
                    $dumps[$raw] = ((Rows $s 'SELECT id,kind,quote(identity),quote(msg_hash),quote(first_ms),quote(last_ms),quote(member_first_ms),quote(member_last_ms),quote(status),quote(sender),quote(recipients),quote(recipient_count),quote(delivered),quote(failed),quote(subject),quote(size_kb),quote(direction),quote(servers),quote(events),quote(events_count),quote(smtp_count) FROM message_rollup ORDER BY id;') |
                        ForEach-Object { $_ -join '|' }) -join "`n"
                    $dumps["$raw-values"] = ((Rows $s 'SELECT id,quote(text) FROM message_rollup_value ORDER BY id;') | ForEach-Object { $_ -join '|' }) -join "`n"
                    $s.Scalar('SELECT COUNT(*) FROM message_rollup;', $null) | Should -Be 5
                    $s.VerifyServeRollups().Verified | Should -BeTrue -Because "raw reads $raw"
                } finally { $s.Dispose() }
            }
        } finally { $field.SetValue($null, $true) }
        $dumps[$true] | Should -BeExactly $dumps[$false]
        $dumps["$true-values"] | Should -BeExactly $dumps["$false-values"]
        # The first non-NULL sender: NULL first, then a TEXT; a packed BLOB (unpacked by S).
        $dumps[$true] | Should -Match "'late@test'"
        $dumps[$true] | Should -Match "'packed@test'"
    }

    It 'copies the WAL at short intervals above half its restart bound, pauses when nothing was copied, and still restarts it' {
        $wait = [ExchangeLogReport.Collector].GetMethod('CheckpointWaitMs', $script:Hidden)
        $pause = [int][ExchangeLogReport.Collector].GetField('CheckpointPauseMs', $script:Hidden).GetValue($null)
        $idle = [int][ExchangeLogReport.Collector].GetField('CheckpointIdleMs', $script:Hidden).GetValue($null)
        $pause | Should -BeGreaterThan 0
        $idle | Should -BeGreaterThan $pause
        $poll = [int][ExchangeLogReport.Collector].GetField('CheckpointPollMs', $script:Hidden).GetValue($null)
        $due = [ExchangeLogReport.Collector].GetMethod('CheckpointDue', $script:Hidden)
        $wait.Invoke($null, @([long]100, [long]1000, 10, $true)) | Should -Be $poll
        $wait.Invoke($null, @([long]500, [long]1000, 10, $true)) | Should -Be $poll
        $wait.Invoke($null, @([long]501, [long]1000, 10, $true)) | Should -Be $pause
        $wait.Invoke($null, @([long]501, [long]1000, 10, $false)) | Should -Be $idle
        $wait.Invoke($null, @([long]5000, [long]0, 10, $true)) | Should -Be $poll -Because 'no bound: the size is only looked at'
        $due.Invoke($null, @([long]100, [long]1000, 10, [long]9999)) | Should -BeFalse
        $due.Invoke($null, @([long]100, [long]1000, 10, [long]10000)) | Should -BeTrue -Because 'CheckpointSeconds since the last copy'
        $due.Invoke($null, @([long]501, [long]1000, 10, [long]0)) | Should -BeTrue -Because 'above half the bound'
        $due.Invoke($null, @([long]5000, [long]0, 10, [long]0)) | Should -BeFalse -Because 'no bound'
        $wait.Invoke($null, @([long]5000, [long]1000, 0, $false)) | Should -Be $idle -Because 'CheckpointSeconds 0 counts as 1 s'
        # The loop itself, on a thread of its own as in a collection: a WAL above half the bound is copied at once, then at short intervals
        # while frames keep coming, and every CheckpointIdleMs only once nothing is left to copy.
        if (-not ('CheckpointProbe' -as [type])) {
            Add-Type -TypeDefinition @"
using System.Reflection;
using System.Threading;
public static class CheckpointProbe {
    public static Thread Start(object collector, ManualResetEventSlim stop, object run) {
        var m = collector.GetType().GetMethod("Checkpoints", BindingFlags.Instance | BindingFlags.NonPublic);
        var t = new Thread(() => m.Invoke(collector, new object[] { stop, run })) { IsBackground = true };
        t.Start();
        return t;
    }
}
"@
        }
        $s = New-SyntheticStore 'checkpoint-loop'
        try {
            $s.Exec('PRAGMA wal_autocheckpoint=0; CREATE TABLE filler(x BLOB);')
            $blob = [byte[]]::new(8192); [Random]::new(3).NextBytes($blob)
            foreach ($i in 1..120) { Sql $s 'INSERT INTO filler VALUES(@b);' @{ b = $blob } }
            $s.WalBytes | Should -BeGreaterThan (600KB)
            $o = [ExchangeLogReport.CollectorOptions]::new(); $o.WalRestartBytes = 1MB; $o.CheckpointSeconds = 3600
            $collector = [ExchangeLogReport.Collector]::new($s, $o)
            $stop = [Threading.ManualResetEventSlim]::new($false)
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $thread = [CheckpointProbe]::Start($collector, $stop, [ExchangeLogReport.CollectionRun]::new())
            foreach ($i in 1..8) { Start-Sleep -Milliseconds 150; foreach ($k in 1..4) { Sql $s 'INSERT INTO filler VALUES(@b);' @{ b = $blob } } }
            Start-Sleep -Milliseconds 600
            $stop.Set(); $thread.Join()
            $elapsed = $watch.Elapsed.TotalMilliseconds
            $collector.CheckpointFastCount | Should -BeGreaterThan 2
            $collector.CheckpointFastCount | Should -Be $collector.CheckpointCount -Because 'CheckpointSeconds is one hour: only the copies above half the bound ran'
            $collector.CheckpointFrames | Should -BeGreaterThan 150
            # No busy loop: a copy that copied nothing waits CheckpointIdleMs; only the 8 rounds of writes give copies that follow at CheckpointPauseMs.
            $collector.CheckpointCount | Should -BeLessOrEqual ([int]($elapsed / $idle) + 2 * 8 + 2)
            $last = $s.Checkpoint('PASSIVE')
            $last.Log - $last.Checkpointed | Should -Be 0 -Because 'every frame was copied in the background'
        } finally { $s.Dispose() }
        $trk = Join-Path $TestDrive 'fastcopy-trk'; [void][IO.Directory]::CreateDirectory($trk)
        $random = [Random]::new(5)
        foreach ($n in 1..30) {
            $lines = foreach ($i in 1..150) { "$(RollupAt ($n * 1000 + $i)),RECEIVE,<f$n-$i@test>,$n$i,l$n-$i,s$i@test,r$n@test,$(-join (1..120 | ForEach-Object { [char]$random.Next(97, 123) }))" }
            New-RollupTrackingLog (Join-Path $trk ("t{0:00}.log" -f $n)) @($lines) $n
        }
        foreach ($bound in 0L, 1MB) {
            $s = New-SyntheticStore "fastcopy-$bound"
            try {
                $o = [ExchangeLogReport.CollectorOptions]::new()
                $o.NowMs = $script:Epoch + 86400000; $o.Parallelism = 1; $o.BatchRows = 1; $o.WalRestartBytes = $bound
                # No timed copy during the run: only the copies above half the bound can run.
                $o.CheckpointSeconds = 3600
                $o.RunId = $s.StartRun('Collect', 'synthetic', 'synthetic', 'test')
                $collector = [ExchangeLogReport.Collector]::new($s, $o)
                $j = [ExchangeLogReport.SourceJob]::new(); $j.Server = 'EX1'; $j.Kind = 'Tracking'; $j.Folder = $trk; $j.Role = 'FrontEnd'
                $collector.Plan(@($j), [datetime]::MinValue)
                $run = $collector.Start(@($j))
                [void]$run.Wait(-1)
                if ($run.Error) { throw $run.Error }
                $run.Statistics | Should -Match 'SMTP authentication \d+[.,]\d s \(0 flushes, 0 sessions'
                $run.Statistics | Should -Match '\(4500 keys\), 4500 distinct keys from the rows of this run'
                $run.Statistics | Should -Match 'compression \d+[.,]\d s \(included in access, rows and sessions; on the parse threads \d+[.,]\d s\)'
                if ($bound -eq 0) {
                    $collector.CheckpointCount | Should -Be 0
                } else {
                    $collector.CheckpointCount | Should -BeLessThan ([int]($run.Seconds * 1000 / $pause) + 2)
                    $run.Statistics | Should -Match 'restarts waiting for a background copy \d+[.,]\d s'
                    $run.Statistics -match '(\d+) WAL restart\(s\)' | Should -BeTrue
                    [int]$Matches[1] | Should -BeGreaterOrEqual 1
                    $s.WalBytes | Should -BeLessThan (6MB)
                }
                $s.Scalar('SELECT COUNT(*) FROM message_event;', $null) | Should -Be 4500
                $s.VerifyServeRollups().Verified | Should -BeTrue
                (Rows $s 'PRAGMA integrity_check;')[0][0] | Should -BeExactly 'ok'
            } finally { $s.Dispose() }
        }
    }

    It 'defaults the page cache of the collection connection to 1 GB and gives the store its own cache back after the collection' {
        [ExchangeLogReport.CollectorOptions]::new().CacheKilobytes | Should -Be 1048576
        $store = [int][ExchangeLogReport.Store]::CacheKilobytes
        $trk = Join-Path $TestDrive 'cache-trk'; [void][IO.Directory]::CreateDirectory($trk)
        New-RollupTrackingLog (Join-Path $trk 'a.log') @("$(RollupAt 1),RECEIVE,<c1@test>,1,c1,s@test,r@test,subject") 1
        $s = New-SyntheticStore 'cache-size'
        try {
            $s.Scalar('PRAGMA cache_size;', $null) | Should -Be (-$store)
            [void](Invoke-RollupCollection $s @{ Tracking = $trk } 'Never' $true)
            $s.Scalar('PRAGMA cache_size;', $null) | Should -Be (-$store)
        } finally { $s.Dispose() }
    }
}

Describe 'Apply thread: fewer allocations and statements, same rows and texts' {
    BeforeAll {
        $script:Asm = [ExchangeLogReport.Store].Assembly
        $script:Hidden = [Reflection.BindingFlags]'Instance,Static,NonPublic,Public'
    }

    It 'skips a Touch of the session the previous Touch queued, and queues it again after a Flush or a Clear' {
        $s = New-SyntheticStore 'touch-repeat'
        $writer = [Activator]::CreateInstance($script:Asm.GetType('ExchangeLogReport.Writer'), @($s))
        $resolver = [Activator]::CreateInstance($script:Asm.GetType('ExchangeLogReport.AuthResolver'), @($s, $writer, [long]600000))
        $last = $resolver.GetType().GetField('_lastKey', $script:Hidden)
        try {
            $tx = $s.Begin()
            try {
                $writer.Use($tx)
                $resolver.Touch('EX1', 'Receive', 'FrontEnd', 'A'); $resolver.Touch('EX1', 'Receive', 'FrontEnd', 'A')
                $resolver.Count | Should -Be 1
                $last.GetValue($resolver) | Should -BeExactly "EX1`u{1}Receive`u{1}FrontEnd`u{1}A"
                # A session queued earlier and still waiting: the statement runs and changes nothing.
                $resolver.Touch('EX1', 'Receive', 'FrontEnd', 'B'); $resolver.Touch('EX1', 'Receive', 'FrontEnd', 'A'); $resolver.Touch('EX1', 'Receive', $null, 'A')
                $resolver.Count | Should -Be 3
                $resolver.Flush($tx)
                $resolver.Count | Should -Be 0
                $last.GetValue($resolver) | Should -BeNullOrEmpty
                $resolver.Touch('EX1', 'Receive', 'FrontEnd', 'A')
                $resolver.Count | Should -Be 1
                $resolver.Clear()
                $last.GetValue($resolver) | Should -BeNullOrEmpty
                $resolver.Touch('EX1', 'Receive', 'FrontEnd', 'A')
                $resolver.Count | Should -Be 1
                $resolver.Flush($tx)
                $tx.Commit()
            } finally { $tx.Dispose() }
        } finally { $resolver.Dispose(); $writer.Dispose(); $s.Dispose() }
    }

    It 'joins the session counters in the order and with the text of the stable LINQ sort, ties included' {
        $s = New-SyntheticStore 'join-order'
        try {
            $collector = [ExchangeLogReport.Collector]::new($s, [ExchangeLogReport.CollectorOptions]::new())
            $join = [ExchangeLogReport.Collector].GetMethod('Join', $script:Hidden, $null, [type[]]@([Collections.Generic.Dictionary[string, long]]), $null)
            function Reference($d) {
                $ordered = [Linq.Enumerable]::ThenBy([Linq.Enumerable]::OrderByDescending($d, [Func[Collections.Generic.KeyValuePair[string, long], long]]{ param($x) $x.Value }),
                    [Func[Collections.Generic.KeyValuePair[string, long], string]]{ param($x) $x.Key }, [StringComparer]::Ordinal)
                (@($ordered) | ForEach-Object { $_.Key.Replace(';', ',').Replace('=', ':') + '=' + $_.Value.ToString([Globalization.CultureInfo]::InvariantCulture) }) -join ';'
            }
            $d = [Collections.Generic.Dictionary[string, long]]::new([StringComparer]::Ordinal)
            $join.Invoke($collector, @(, $d)) | Should -BeNullOrEmpty
            foreach ($pair in @(@('b', 2), @('a', 2), @('B', 2), @('c;x=y', 5), @('z', 1), @('Z', 1), @("`u{e9}", 2), @("`u{1F600}", 2), @("`u{E000}", 2))) { $d[$pair[0]] = [long]$pair[1] }
            $expected = "c,x:y=5;B=2;a=2;b=2;`u{e9}=2;`u{1F600}=2;`u{E000}=2;Z=1;z=1"
            $join.Invoke($collector, @(, $d)) | Should -BeExactly $expected
            Reference $d | Should -BeExactly $expected
            # Many ties, keys that differ only by case or by the characters the text replaces, removals (reused dictionary slots).
            $random = [Random]::new(7)
            $alphabet = @('a', 'A', 'b', ';', '=', ',', ':', "`u{e9}", "`u{1F600}", "`u{E000}", '1')
            for ($round = 0; $round -lt 20; $round++) {
                $d = [Collections.Generic.Dictionary[string, long]]::new([StringComparer]::Ordinal)
                for ($i = 0; $i -lt 60; $i++) {
                    $key = -join (1..$random.Next(1, 4) | ForEach-Object { $alphabet[$random.Next($alphabet.Count)] })
                    if ($random.Next(5) -eq 0) { [void]$d.Remove($key) } else { $d[$key] = [long]$random.Next(1, 4) }
                }
                $join.Invoke($collector, @(, $d)) | Should -BeExactly (Reference $d) -Because "round $round"
            }
        } finally { $s.Dispose() }
    }

    It 'labels the session statuses with the same texts as ToString' {
        $label = [ExchangeLogReport.Collector].GetMethod('StatusLabel', $script:Hidden)
        $type = $script:Asm.GetType('ExchangeLogReport.Collector+AccessRecord')
        $r = [Activator]::CreateInstance($type, $true)
        $r.Source = 'HttpProxy'
        foreach ($status in @([int]::MinValue, -1, 0, 1, 99, 100, 101, 200, 302, 401, 404, 449, 500, 503, 599, 600, 999, 1000, 12345, [int]::MaxValue)) {
            $r.Status = $status
            $label.Invoke($null, @($r)) | Should -BeExactly $status.ToString([Globalization.CultureInfo]::InvariantCulture)
        }
        $r.Status = 200
        [object]::ReferenceEquals($label.Invoke($null, @($r)), $label.Invoke($null, @($r))) | Should -BeTrue
        foreach ($source in 'Imap4', 'Pop3') {
            $r.Source = $source
            $r.Status = 200; $label.Invoke($null, @($r)) | Should -BeExactly 'OK'
            $r.Status = 400; $label.Invoke($null, @($r)) | Should -BeExactly 'NO'
        }
    }

    It 'reuses one journey summary for every key of a reconciliation: a dropped message does not leak into the next one' {
        $field = [ExchangeLogReport.Store].GetField('RawRollupReads', $script:Hidden)
        $dumps = @{}
        try {
            foreach ($raw in $true, $false) {
                $field.SetValue($null, $raw)
                $s = New-SyntheticStore "summary-reuse-$raw"
                try {
                    Sql $s @"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES
 (@t,'EX1','DROP','<a-drop@test>','l1','s@test','x@test'),
 (@t+1,'EX1','RECEIVE','<b-empty@test>','l2','s@test',''),
 (@t+2,'EX2','DELIVER','<c@test>','l3','s@test','y@test;z@test'),
 (@t+3,'EX1','EXPAND','<d@test>','l4','s@test','g@test'),
 (@t+4,'EX1','RECEIVE','<e@test>','l5','s@test',NULL);
"@ @{ t = $script:Epoch }
                    $s.RefreshServeRollups()
                    $dumps[$raw] = ((Rows $s 'SELECT r.id,r.identity,v.text,r.recipients,r.recipient_count,r.delivered,(SELECT text FROM message_rollup_value WHERE id=r.servers),(SELECT text FROM message_rollup_value WHERE id=r.events) FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status ORDER BY r.id;') |
                        ForEach-Object { $_ -join '|' }) -join "`n"
                } finally { $s.Dispose() }
            }
        } finally { $field.SetValue($null, $true) }
        $dumps[$true] | Should -BeExactly $dumps[$false]
        $dumps[$true] | Should -Match '<a-drop@test>\|Dropped\|'
        $dumps[$true] | Should -Match '<b-empty@test>\|In transit\|\[\]\|0\|0\|EX1\|RECEIVE'
        $dumps[$true] | Should -Match '<e@test>\|In transit\|\[\]\|0\|0\|EX1\|RECEIVE'
    }

    It 'shows the reading and writing parts of the message rollups in the statistics, after the keys' {
        $trk = Join-Path $TestDrive 'stats-trk'; [void][IO.Directory]::CreateDirectory($trk)
        New-RollupTrackingLog (Join-Path $trk 'a.log') @("$(RollupAt 1),RECEIVE,<s1@test>,1,s1,s@test,r@test,one", "$(RollupAt 2),RECEIVE,<s2@test>,2,s2,s@test,r@test,two") 1
        New-RollupTrackingLog (Join-Path $trk 'b.log') @("$(RollupAt 3),DELIVER,<s1@test>,1,s3,s@test,r@test,one") 2
        $s = New-SyntheticStore 'rollup-stats'
        try {
            # One batch per file (BatchRows 1): the second batch uses the emptied first one again.
            $run = Invoke-RollupCollection $s @{ Tracking = $trk } 'Never' $true
            $run.GetType().GetField('Batches', $script:Hidden).GetValue($run) | Should -BeGreaterOrEqual 2
            $s.Scalar('SELECT events_count FROM message_rollup WHERE identity=''<s1@test>'';', $null) | Should -Be 2
            $run.Statistics | Should -Match 'message rollups [\d.,]+ s \([1-9]\d* keys\), [^,]*distinct keys[^,]*, rollup reads [\d.,]+ s, rollup writes [\d.,]+ s, waiting for files'
            $run.Statistics -match 'message rollups [\d.,]+ s \((\d+) keys\)' | Should -BeTrue
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
    }
}

Describe 'Parse threads: fewer allocations, same values' {
    BeforeAll {
        $script:Hidden = [Reflection.BindingFlags]'Instance,Static,NonPublic,Public'
    }

    It 'finds the IIS cafeReqId where the regular expression cafeReqId=([0-9a-fA-F-]{36}) found it' {
        $at = [ExchangeLogReport.Collector].GetMethod('CafeIdAt', $script:Hidden)
        $rx = [regex]::new('cafeReqId=([0-9a-fA-F-]{36})')
        function Expected([string]$q) { if ($null -eq $q) { return -1 }; $m = $rx.Match($q); if ($m.Success) { $m.Groups[1].Index } else { -1 } }
        $id = '0123abcd-ABCD-ef01-2345-6789abcdefAB'
        $cases = @($null, '', 'cafeReqId=', "cafeReqId=$id", "a=1&cafeReqId=$id&b=2", "cafeReqId=$($id.Substring(1))", "x cafeReqId=$($id)Z", "cafeReqId=$($id)0",
            "CafeReqId=$id", "cafereqid=$id", "cafeReqId =$id", "cafeReqId==$id", "cafeReqId=$($id.Substring(0, 20))g$($id.Substring(21))&cafeReqId=$id",
            "cafeReqId=cafeReqId=$id", "cafeReqId=$($id.Substring(0, 30))", "cafeReqId=$('-' * 36)", "cafeReqId=$('F' * 35)G", "cafeReqId=$('9' * 35)$([char]0x663)",
            "cafeReqId=$('a' * 35)$([char]0xFF21)", "cafeReqId=$('a' * 36)$([char]0xD800)", "`u{1F600}cafeReqId=$id", "cafeReqId=$($id.Substring(0, 10))_$($id.Substring(11)) cafeReqId=$($id.ToUpperInvariant())")
        foreach ($q in $cases) { $at.Invoke($null, @(, $q)) | Should -Be (Expected $q) -Because "query '$q'" }
        # Random queries over the characters that matter: keys planted, cut, doubled, ids one character short or with a foreign character.
        $random = [Random]::new(11)
        $parts = @('cafeReqId=', 'cafeReqId=', 'cafeReqId=', $id, $id, 'cafeReqId', 'CafeReqId=', '=', '&', ' ', 'g', 'G', '_', "$([char]0x663)", '0123456789', 'abcdef', 'ABCDEF', '-', '--', $id, $id.Substring(0, 35))
        $found = 0; $shifted = 0
        for ($i = 0; $i -lt 3000; $i++) {
            $q = -join (1..$random.Next(1, 12) | ForEach-Object { $parts[$random.Next($parts.Count)] })
            $expected = Expected $q
            $at.Invoke($null, @(, $q)) | Should -Be $expected -Because "query '$q'"
            if ($expected -ge 0) { $found++; if ($expected -ne $q.IndexOf('cafeReqId=', [StringComparison]::Ordinal) + 10) { $shifted++ } }
        }
        $found | Should -BeGreaterThan 200 -Because 'the random queries hold ids'
        $shifted | Should -BeGreaterThan 10 -Because 'some ids are after a first key that has none'
    }

    It 'finds the proxy text in data and context as the joined text did, across the space between them too' {
        $joined = [ExchangeLogReport.Collector].GetMethod('JoinedContains', $script:Hidden)
        $phrase = 'Proxy session was successfully set up'
        function Expected([string]$a, [string]$b) { ($a + ' ' + $b).IndexOf($phrase, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
        $cases = [Collections.Generic.List[object]]::new()
        foreach ($pair in @(@('', ''), @($phrase, ''), @('', $phrase), @("x $phrase y", 'z'), @('PROXY SESSION WAS', 'successfully set up'), @('Proxy session was successfully', 'set up now'),
                @('Proxy', 'session was successfully set up'), @('Proxy session was successfully set', 'up'), @('Proxy session was successfully set ', 'up'), @('Proxy session was', ' successfully set up'),
                @('Proxy session was successfully set u', 'p'), @("Proxy $([char]0x17F)ession was", 'successfully set up'), @('Proxy session  was', 'successfully set up'), @('roxy session was', 'successfully set up'))) { $cases.Add($pair) }
        # Every cut of the phrase, at a space or not, with some characters before and after.
        for ($k = 0; $k -le $phrase.Length; $k++) { $cases.Add(@(('a' + $phrase.Substring(0, $k)), ($phrase.Substring($k) + 'b'))); $cases.Add(@($phrase.Substring(0, $k), $phrase.Substring([Math]::Min($phrase.Length, $k + 1)))) }
        foreach ($pair in $cases) { $joined.Invoke($null, @($pair[0], $pair[1], $phrase)) | Should -Be (Expected $pair[0] $pair[1]) -Because "'$($pair[0])' + ' ' + '$($pair[1])'" }
    }
}

Describe 'Collection throughput: queue of parsed files, file reads, SMTP rollup reads, record lists used again' {
    BeforeAll {
        $script:Asm = [ExchangeLogReport.Store].Assembly
        $script:Hidden = [Reflection.BindingFlags]'Instance,Static,NonPublic,Public'
        $script:PoolType = $script:Asm.GetType('ExchangeLogReport.Collector+ListPool')
        $script:ContextType = $script:Asm.GetType('ExchangeLogReport.Collector+ParseContext')
        function New-PooledContext([string]$Kind, [long]$Bytes, $Pool) {
            [Activator]::CreateInstance($script:ContextType, [Reflection.BindingFlags]'Instance,NonPublic,Public', $null, [object[]]@($Kind, $Bytes, $Pool), $null)
        }
        function ContextList($Context, [string]$Name) { return ,$script:ContextType.GetField($Name).GetValue($Context) }
        function PoolCount($Pool) { [int]$script:PoolType.GetProperty('Count').GetValue($Pool) }
        function PoolReturn($Pool, $Context) { [void]$script:PoolType.GetMethod('Return').Invoke($Pool, @($Context)) }
    }

    It 'holds at most 384 MB read and 256 files in the queue of the parsed files' {
        [ExchangeLogReport.Collector].GetField('QueueBytes', $script:Hidden).GetValue($null) | Should -Be (384MB)
        [ExchangeLogReport.Collector].GetField('QueueMaxFiles', $script:Hidden).GetValue($null) | Should -Be 256
        [ExchangeLogReport.Collector].GetField('QueueMinFiles', $script:Hidden).GetValue($null) | Should -Be 2
    }

    It 'adds the time spent reading the files, main streams and filler apart, at the end of the statistics' {
        $trk = Join-Path $TestDrive 'reads-trk'; [void][IO.Directory]::CreateDirectory($trk)
        $smtp = Join-Path $TestDrive 'reads-smtp'; [void][IO.Directory]::CreateDirectory($smtp)
        New-RollupTrackingLog (Join-Path $trk 'a.log') @(1..50 | ForEach-Object { "$(RollupAt $_),RECEIVE,<r$_@test>,$_,r$_,s@test,r@test,subject $_" }) 1
        New-RollupSmtpLog (Join-Path $smtp 's1.log') @(@{ Session = '0AAA0000000000A1'; Base = 10; Id = '<r1@test>' }) 2
        $s = New-SyntheticStore 'file-reads'
        try {
            $run = Invoke-RollupCollection $s @{ Tracking = $trk; SmtpReceive = $smtp } 'Never' $true
            $run.Statistics | Should -Match 'restarts waiting for a background copy \d+[.,]\d s, file reads (\d+[.,]\d) s \(main (\d+[.,]\d) s, filler (\d+[.,]\d) s\), parse threads waiting for the reads (\d+[.,]\d) s \(main (\d+[.,]\d) s, filler (\d+[.,]\d) s\)$'
            $type = [ExchangeLogReport.CollectionRun]
            $main = [long]$type.GetField('ReadTicksMain', $script:Hidden).GetValue($run)
            $filler = [long]$type.GetField('ReadTicksFiller', $script:Hidden).GetValue($run)
            $main | Should -Be 0 -Because 'message tracking and SMTP files are the filler'
            [long]$type.GetField('ReadWaitTicksMain', $script:Hidden).GetValue($run) | Should -Be 0
            [long]$type.GetField('ReadWaitTicksFiller', $script:Hidden).GetValue($run) | Should -BeGreaterThan 0
            $filler | Should -BeGreaterThan 0
            $s.Scalar('SELECT COUNT(*) FROM message_event;', $null) | Should -Be 50
        } finally { $s.Dispose() }
    }

    It 'counts the reads of a LineBuffer only, the same lines with or without it' {
        $path = Join-Path $TestDrive 'reads-lines.log'
        [IO.File]::WriteAllLines($path, [string[]](1..2000 | ForEach-Object { "line $_ " + ('x' * ($_ % 700)) }))
        $buffer = [ExchangeLogReport.LineBuffer]::new()
        $ticks = [ExchangeLogReport.LineBuffer].GetField('ReadTicks', $script:Hidden)
        $with = @([ExchangeLogReport.LogReader]::Lines($path, 0, $buffer) | ForEach-Object { "$($_.NextOffset)|$($_.Text())" })
        $without = @([ExchangeLogReport.LogReader]::Lines($path, 0) | ForEach-Object { "$($_.NextOffset)|$($_.Text())" })
        $with.Count | Should -Be 2000
        ($with -join "`n") | Should -BeExactly ($without -join "`n")
        [long]$ticks.GetValue($buffer) | Should -BeGreaterThan 0
    }

    It 'reconciles the SMTP keys through a raw statement with the values of the Microsoft.Data.Sqlite path, whatever the storage class' {
        $field = [ExchangeLogReport.Store].GetField('RawRollupReads', $script:Hidden)
        $field.GetValue($null) | Should -BeTrue
        $dumps = @{}
        try {
            foreach ($raw in $true, $false) {
                $field.SetValue($null, $raw)
                $s = New-SyntheticStore "raw-smtp-$raw"
                try {
                    # SMTP rows without Message-ID: REAL and TEXT end times, an INTEGER server, packed BLOB and NULL senders, non-ASCII and astral recipients.
                    Sql $s @"
INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,session_id,message_id,status,mail_from,rcpts) VALUES
 (@t+30,NULL,'EX1','Receive','s1',NULL,'Rejected','r@test','nobody@test'),
 (@t+31,@t+33.5,'EX`u{e9}2','Receive','s2',NULL,'Deferred',@packed,'a@test;`u{1F600}@test'),
 (@t+32,'40','EX1','Receive','s3',NULL,NULL,NULL,''),
 (@t+33,NULL,42,'Receive','s4',NULL,'Rejected','x@test',NULL),
 (@t+34,@t+35.5,'EX3','Receive','s5',NULL,'Accepted','ok@test','p@test'),
 (@t+35,NULL,'EX1','Send','s6',NULL,'Rejected','send@test','q@test');
"@ @{ t = $script:Epoch; packed = [ExchangeLogReport.Packed]::Pack("packed `u{e9}`u{1F600}@test") }
                    $s.RefreshServeRollups()
                    $s.Scalar('SELECT COUNT(*) FROM message_rollup;', $null) | Should -Be 4
                    $first = ((Rows $s 'SELECT id,kind,quote(identity),quote(msg_hash),quote(first_ms),quote(last_ms),quote(member_first_ms),quote(member_last_ms),quote(status),quote(sender),quote(recipients),quote(recipient_count),quote(delivered),quote(failed),quote(subject),quote(size_kb),quote(direction),quote(servers),quote(events),quote(events_count),quote(smtp_count) FROM message_rollup ORDER BY id;') |
                        ForEach-Object { $_ -join '|' }) -join "`n"
                    # A key whose row is accepted afterwards: the rollup row goes (the raw read finds no row).
                    Sql $s "UPDATE smtp_transaction SET status='Accepted' WHERE session_id='s1';"
                    $s.RefreshServeRollups()
                    $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;', $null) | Should -Be 0
                    $dumps[$raw] = $first + "`n--`n" + (((Rows $s 'SELECT id,kind,quote(identity),quote(first_ms),quote(last_ms),quote(member_first_ms),quote(member_last_ms),quote(status),quote(sender),quote(recipients),quote(recipient_count),quote(failed),quote(direction),quote(servers),quote(events),quote(smtp_count) FROM message_rollup ORDER BY id;') |
                        ForEach-Object { $_ -join '|' }) -join "`n")
                    $dumps["$raw-values"] = ((Rows $s 'SELECT id,quote(text) FROM message_rollup_value ORDER BY id;') | ForEach-Object { $_ -join '|' }) -join "`n"
                    $dumps["$raw-count"] = [int]$s.Scalar('SELECT COUNT(*) FROM message_rollup;', $null)
                    $s.VerifyServeRollups().Verified | Should -BeTrue -Because "raw reads $raw"
                } finally { $s.Dispose() }
            }
        } finally { $field.SetValue($null, $true) }
        $dumps[$true] | Should -BeExactly $dumps[$false]
        $dumps["$true-values"] | Should -BeExactly $dumps["$false-values"]
        # The four Receive rows not accepted, then one less once s1 is accepted; the packed sender unpacked.
        $dumps["$true-count"] | Should -Be 3
        $dumps[$true] | Should -Match "packed `u{e9}"
    }

    It 'gives the record lists of an applied file to the next files of the same kind, emptied and bounded' {
        $pool = [Activator]::CreateInstance($script:PoolType, $true)
        $maxLists = [int]$script:PoolType.GetField('MaxLists', $script:Hidden).GetValue($null)
        $maxCapacity = [int]$script:PoolType.GetField('MaxCapacity', $script:Hidden).GetValue($null)
        # Message tracking: one row per KB planned.
        $a = New-PooledContext 'Tracking' (100KB) $pool
        $messages = ContextList $a 'Messages'
        $messages.Capacity | Should -Be 100
        $messages.Add([object[]]@(1, 'x')); $messages.Add([object[]]@(2, 'y'))
        PoolReturn $pool $a
        (PoolCount $pool) | Should -Be 1 -Because 'the empty access list of a tracking file has no array to keep'
        $messages.Count | Should -Be 0
        $b = New-PooledContext 'Tracking' (10KB) $pool
        [object]::ReferenceEquals((ContextList $b 'Messages'), $messages) | Should -BeTrue
        (ContextList $b 'Messages').Capacity | Should -Be 100
        (PoolCount $pool) | Should -Be 0
        PoolReturn $pool $b
        $c = New-PooledContext 'Tracking' (300KB) $pool
        [object]::ReferenceEquals((ContextList $c 'Messages'), $messages) | Should -BeTrue
        $messages.Capacity | Should -Be 300 -Because 'a list smaller than the file is grown to its size'
        # Other kinds keep lists of their own; HttpProxy and IIS share the access lists.
        PoolReturn $pool $c
        $smtp = New-PooledContext 'SmtpReceive' (300KB) $pool
        [object]::ReferenceEquals((ContextList $smtp 'Messages'), $messages) | Should -BeFalse
        (PoolCount $pool) | Should -Be 1
        $h = New-PooledContext 'HttpProxy' (200KB) $pool
        $access = ContextList $h 'Access'
        $access.Capacity | Should -Be 50
        PoolReturn $pool $h
        $iis = New-PooledContext 'Iis' 0 $pool
        [object]::ReferenceEquals((ContextList $iis 'Access'), $access) | Should -BeTrue
        # Bounds: at most MaxLists lists per kind, none above MaxCapacity entries.
        $script:PoolType.GetMethod('Clear').Invoke($pool, @())
        (PoolCount $pool) | Should -Be 0
        $many = @(1..($maxLists + 5) | ForEach-Object { New-PooledContext 'Tracking' (4KB) $pool })
        foreach ($x in $many) { PoolReturn $pool $x }
        (PoolCount $pool) | Should -Be $maxLists
        $script:PoolType.GetMethod('Clear').Invoke($pool, @())
        $large = New-PooledContext 'Tracking' (1KB * ($maxCapacity + 1)) $pool
        PoolReturn $pool $large
        (PoolCount $pool) | Should -Be 0 -Because 'a list above MaxCapacity entries is left to the GC'
    }

    It 'collects the same rows with the record lists used again from one file to the next, and keeps none after the collection' {
        $trk = Join-Path $TestDrive 'pool-trk'; [void][IO.Directory]::CreateDirectory($trk)
        foreach ($f in 1..6) { New-RollupTrackingLog (Join-Path $trk "t$f.log") @(1..(20 * $f) | ForEach-Object { "$(RollupAt ($f * 1000 + $_)),RECEIVE,<p$f-$_@test>,$_,p$f-$_,s@test,r@test,subject $f $_" }) $f }
        $s = New-SyntheticStore 'pool-collect'
        try {
            $o = [ExchangeLogReport.CollectorOptions]::new()
            $o.NowMs = $script:Epoch + 86400000; $o.Parallelism = 1; $o.BatchRows = 50
            $o.RunId = $s.StartRun('Collect', 'synthetic', 'synthetic', 'test')
            $collector = [ExchangeLogReport.Collector]::new($s, $o)
            $j = [ExchangeLogReport.SourceJob]::new(); $j.Server = 'EX1'; $j.Kind = 'Tracking'; $j.Folder = $trk; $j.Role = 'FrontEnd'
            $collector.Plan(@($j), [datetime]::MinValue)
            $run = $collector.Start(@($j))
            [void]$run.Wait(-1)
            if ($run.Error) { throw $run.Error }
            $pool = [ExchangeLogReport.Collector].GetField('_lists', $script:Hidden).GetValue($collector)
            (PoolCount $pool) | Should -Be 0 -Because 'the lists are dropped at the end of the collection'
            $s.Scalar('SELECT COUNT(*) FROM message_event;', $null) | Should -Be (20 * (1 + 2 + 3 + 4 + 5 + 6))
            $s.Scalar("SELECT COUNT(DISTINCT message_id) FROM message_event WHERE message_id LIKE '<p6-%';", $null) | Should -Be 120
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
    }
}

Describe 'Collection throughput: reads ahead, success times in chunks, transcript times, count keys' {
    BeforeAll {
        $script:Asm = [ExchangeLogReport.Store].Assembly
        $script:Hidden = [Reflection.BindingFlags]'Instance,Static,NonPublic,Public'
        # The lines of LogReader.Lines before the reads ahead: one read of the room of the buffer at a time (the reference).
        function Reference-Lines([string]$Path, [long]$Offset) {
            $bytes = [IO.File]::ReadAllBytes($Path)
            if ($Offset -lt 0 -or $Offset -gt $bytes.Length) { $Offset = 0 }
            $start = $Offset
            if ($Offset -eq 0 -and $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
            $out = [Collections.Generic.List[string]]::new()
            $utf8 = [Text.UTF8Encoding]::new($false, $false)
            while ($true) {
                $nl = [Array]::IndexOf($bytes, [byte]10, [int]$start)
                if ($nl -lt 0) { break }
                $length = $nl - $start
                if ($length -gt 0 -and $bytes[$nl - 1] -eq 13) { $length-- }
                $out.Add("$($nl + 1)|" + $utf8.GetString($bytes, [int]$start, [int]$length))
                $start = $nl + 1
            }
            return ,$out
        }
        function Reader-Lines([string]$Path, [long]$Offset, $Buffer) {
            $out = [Collections.Generic.List[string]]::new()
            foreach ($l in [ExchangeLogReport.LogReader]::Lines($Path, $Offset, $Buffer)) { $out.Add("$($l.NextOffset)|" + $l.Text()) }
            return ,$out
        }
    }

    It 'reads ahead the files larger than the buffer with the same lines and offsets, whatever the line lengths and the start' {
        $random = [Random]::new(15)
        $buffer = [ExchangeLogReport.LineBuffer]::new()
        $size = [int][ExchangeLogReport.LineBuffer].GetField('Size', $script:Hidden).GetValue($null)
        $aheadSize = [int][ExchangeLogReport.LineBuffer].GetField('AheadSize', $script:Hidden).GetValue($null)
        $cases = @(
            @{ Name = 'short'; Bom = $true; Lines = { param($i) 'l' + $i + ',' + ('x' * $random.Next(0, 300)) } },
            @{ Name = 'crlf'; Bom = $false; Crlf = $true; Lines = { param($i) "é$i," + ('y' * $random.Next(0, 2000)) } },
            @{ Name = 'long'; Bom = $false; Lines = { param($i) if ($i % 7 -eq 3) { 'L' * ($size + $random.Next(1, 300000)) } else { 'm' * $random.Next(0, 90000) } } })
        foreach ($case in $cases) {
            $path = Join-Path $TestDrive "ahead-$($case.Name).log"
            $sb = [Text.StringBuilder]::new()
            $i = 0
            while ($sb.Length -lt 5 * $size) { [void]$sb.Append((& $case.Lines $i)).Append($(if ($case['Crlf']) { "`r`n" } else { "`n" })); $i++ }
            [void]$sb.Append('partial line without its end')
            $text = [Text.Encoding]::UTF8.GetBytes($sb.ToString())
            $bytes = if ($case.Bom) { [byte[]](0xEF, 0xBB, 0xBF) + $text } else { $text }
            [IO.File]::WriteAllBytes($path, [byte[]]$bytes)
            foreach ($offset in @(0, 1, ($aheadSize - 1), ($size + 17), ($bytes.Length - 40))) {
                $expected = Reference-Lines $path $offset
                $got = Reader-Lines $path $offset $buffer
                $got.Count | Should -Be $expected.Count -Because "$($case.Name) from $offset"
                ($got -join "`n") -ceq ($expected -join "`n") | Should -BeTrue -Because "$($case.Name) from $offset"
                (Reader-Lines $path $offset $null) -join "`n" -ceq ($expected -join "`n") | Should -BeTrue -Because "$($case.Name) from $offset without a buffer"
            }
        }
        [ExchangeLogReport.LineBuffer].GetField('Ahead', $script:Hidden).GetValue($buffer).Length | Should -Be $aheadSize
        [long][ExchangeLogReport.LineBuffer].GetField('WaitTicks', $script:Hidden).GetValue($buffer) | Should -BeGreaterThan 0
    }

    It 'never reads ahead a file that its first read does not fill, and closes a file left before its end' {
        $buffer = [ExchangeLogReport.LineBuffer]::new()
        $small = Join-Path $TestDrive 'ahead-small.log'
        [IO.File]::WriteAllLines($small, [string[]](1..1000 | ForEach-Object { "small $_" }))
        (Reader-Lines $small 0 $buffer).Count | Should -Be 1000
        [ExchangeLogReport.LineBuffer].GetField('Ahead', $script:Hidden).GetValue($buffer) | Should -BeNullOrEmpty
        $big = Join-Path $TestDrive 'ahead-big.log'
        [IO.File]::WriteAllLines($big, [string[]](1..200000 | ForEach-Object { "big line $_ " + ('z' * ($_ % 50)) }))
        $n = 0
        # PowerShell does not dispose an enumerator left by break: the engine (foreach in C#) does.
        $e = [Collections.Generic.IEnumerable[ExchangeLogReport.LogLine]].GetMethod('GetEnumerator').Invoke([ExchangeLogReport.LogReader]::Lines($big, 0, $buffer), @())
        try { while ($n -lt 30000 -and $e.MoveNext()) { $n++ } } finally { $e.Dispose() }
        $n | Should -Be 30000
        # The read ahead in progress ended with the enumeration: the file is closed (it can be deleted) and the buffer is free again.
        Remove-Item -LiteralPath $big
        Test-Path -LiteralPath $big | Should -BeFalse
        [bool][ExchangeLogReport.LineBuffer].GetField('InUse', $script:Hidden).GetValue($buffer) | Should -BeFalse
    }

    It 'finds the first success at or after a failure in the chunks as the sorted list did' {
        $type = $script:Asm.GetType('ExchangeLogReport.Collector+SuccessTimes')
        $chunk = [int]$type.GetField('ChunkSize', $script:Hidden).GetValue($null)
        $random = [Random]::new(8)
        foreach ($count in @(0, 1, 3, 4, 5, ($chunk - 1), $chunk, ($chunk + 1), (3 * $chunk + 77))) {
            $times = [Collections.Generic.List[long]]::new()
            $chunks = [Activator]::CreateInstance($type, $true)
            $part = [Collections.Generic.List[long]]::new()
            for ($i = 0; $i -lt $count; $i++) {
                $t = [long]$random.Next(0, 5000) * 1000 + $random.Next(0, 3)
                $times.Add($t)
                if ($i % 3 -eq 0) { $type.GetMethod('Add').Invoke($chunks, [object[]]@([long]$t)) } else { $part.Add($t); if ($part.Count -ge 50) { $type.GetMethod('AddRange').Invoke($chunks, @(, $part)); $part = [Collections.Generic.List[long]]::new() } }
            }
            if ($part.Count) { $type.GetMethod('AddRange').Invoke($chunks, @(, $part)) }
            [long]$type.GetProperty('Count').GetValue($chunks) | Should -Be $count
            $times.Sort(); [void]$type.GetMethod('Sort').Invoke($chunks, @())
            $first = $type.GetMethod('FirstAtOrAfter')
            foreach ($probe in @(-1L, 0L, 1L, 2500000L, 4999002L, 5000000L) + @(1..200 | ForEach-Object { [long]$random.Next(0, 5001000) }) + @($times | Select-Object -First 20)) {
                $i = $times.BinarySearch($probe)
                if ($i -lt 0) { $i = -bnot $i } else { while ($i -gt 0 -and $times[$i - 1] -eq $probe) { $i-- } }
                $args2 = [object[]]@([long]$probe, [long]0)
                $found = [bool]$first.Invoke($chunks, $args2)
                $found | Should -Be ($i -lt $times.Count) -Because "count $count probe $probe"
                if ($found) { [long]$args2[1] | Should -Be $times[$i] -Because "count $count probe $probe" }
            }
        }
    }

    It 'formats the transcript times as TimeUtil.Format did, in zones of whole hours, half and quarter hours and across summer time' {
        $method = [ExchangeLogReport.Collector].GetMethod('TranscriptText', $script:Hidden)
        $lineType = $script:Asm.GetType('ExchangeLogReport.Collector+SmtpLine')
        $listType = [Collections.Generic.List`1].MakeGenericType($lineType)
        $random = [Random]::new(9)
        foreach ($zoneId in 'UTC', 'Romance Standard Time', 'India Standard Time', 'Nepal Standard Time', 'Pacific Standard Time', 'Lord Howe Standard Time') {
            $zone = [TimeZoneInfo]::FindSystemTimeZoneById($zoneId)
            $s = [ExchangeLogReport.Store]::new((Join-Path $TestDrive "transcript-$($zoneId.Replace(' ', '')).db"), $false, 'synthetic')
            try {
                $o = [ExchangeLogReport.CollectorOptions]::new(); $o.Zone = $zone
                $collector = [ExchangeLogReport.Collector]::new($s, $o)
                # Around the summer time changes of 2026 in Europe and America, and random times.
                $bases = @([DateTimeOffset]::Parse('2026-03-29T00:59:58Z'), [DateTimeOffset]::Parse('2026-10-25T00:59:58.5Z'), [DateTimeOffset]::Parse('2026-03-08T09:59:59Z'),
                    [DateTimeOffset]::Parse('2026-11-01T08:59:59Z'), [DateTimeOffset]::Parse('2026-04-04T14:59:59Z'), [DateTimeOffset]::Parse('1970-01-01T00:00:00Z'))
                foreach ($base in $bases) {
                    $lines = [Activator]::CreateInstance($listType)
                    $t = $base.ToUnixTimeMilliseconds()
                    $expected = [Text.StringBuilder]::new()
                    for ($i = 0; $i -lt 60; $i++) {
                        $t += @(0, 1, 7, 999, 1000, 1001, 60000)[$random.Next(7)]
                        $l = [Activator]::CreateInstance($lineType, $true)
                        $lineType.GetField('Time').SetValue($l, [long]$t); $lineType.GetField('Tag').SetValue($l, '<'); $lineType.GetField('Data').SetValue($l, "data $i")
                        if ($i % 5 -eq 0) { $lineType.GetField('Context').SetValue($l, "ctx $i") }
                        [void]$listType.GetMethod('Add').Invoke($lines, @($l))
                        [void]$expected.Append([ExchangeLogReport.TimeUtil]::Format($t, $zone, 'HH:mm:ss.fff')).Append(' < ').Append("data $i")
                        if ($i % 5 -eq 0) { [void]$expected.Append("  [ctx $i]") }
                        [void]$expected.Append("`n")
                    }
                    [string]$method.Invoke($collector, @(, $lines)) | Should -BeExactly $expected.ToString() -Because "$zoneId from $base"
                }
            } finally { $s.Dispose() }
        }
    }

    It 'counts the requests in the same entries, in the same order, with the entries of the previous record used again' {
        $count = [ExchangeLogReport.Collector].GetMethod('Count', $script:Hidden)
        $recordType = $script:Asm.GetType('ExchangeLogReport.Collector+AccessRecord')
        $memoType = $script:Asm.GetType('ExchangeLogReport.Collector+CountMemo')
        $usageType = $script:Asm.GetType('ExchangeLogReport.Collector+UsageAcc')
        $actionType = $script:Asm.GetType('ExchangeLogReport.Collector+ActionAcc')
        $clientType = $script:Asm.GetType('ExchangeLogReport.Collector+ClientAcc')
        function New-Dict($valueType) { [Activator]::CreateInstance([Collections.Generic.Dictionary`2].MakeGenericType([string], $valueType), @([StringComparer]::Ordinal)) }
        function Dump($dict) {
            (@(foreach ($kv in $dict.GetEnumerator()) {
                $v = $kv.Value
                $fields = if ($v -is [Collections.Generic.List[long]]) { $v -join ',' } else { ($v.GetType().GetFields() | ForEach-Object { "$($_.Name)=$($_.GetValue($v))" }) -join ';' }
                "$($kv.Key)=>$fields"
            }) -join "`n")
        }
        $random = [Random]::new(10)
        $pick = { param($values) $values[$random.Next($values.Count)] }
        $sets = @{}
        foreach ($withMemo in $true, $false) {
            $random = [Random]::new(10)
            $usage = New-Dict $usageType; $actions = New-Dict $actionType; $clients = New-Dict $clientType; $successes = New-Dict ([Collections.Generic.List[long]])
            $memo = if ($withMemo) { [Activator]::CreateInstance($memoType, $true) } else { $null }
            $last = $null
            for ($i = 0; $i -lt 3000; $i++) {
                # Runs of equal records, records that differ in one field, '|' inside the fields (two records with the same key texts), nulls and new string instances.
                if ($null -eq $last -or $random.Next(4) -eq 0) {
                    $r = [Activator]::CreateInstance($recordType, $true)
                    $r.GetType().GetField('Day').SetValue($r, (& $pick @('2026-01-01', '2026-01-02', ('2026-01-0' + '1'))))
                    $r.GetType().GetField('User').SetValue($r, (& $pick @('a@test', 'b@test', 'a', $null, 'a|x', ('a' + '@test'))))
                    $r.GetType().GetField('Protocol').SetValue($r, (& $pick @('Owa', 'Ews', $null, 'x|Owa', 'Owa')))
                    $r.GetType().GetField('Action').SetValue($r, (& $pick @('GetItem', $null, '?', 'Sync')))
                    $r.GetType().GetField('Agent').SetValue($r, (& $pick @('ua1', $null, '')))
                    $r.GetType().GetField('DeviceId').SetValue($r, (& $pick @('d1', $null)))
                    $r.GetType().GetField('ClientIp').SetValue($r, (& $pick @('10.0.0.1', '10.0.0.2', $null)))
                    $r.GetType().GetField('DeviceType').SetValue($r, (& $pick @('Phone', $null)))
                    $r.GetType().GetField('Mailbox').SetValue($r, (& $pick @('mb1', $null)))
                    $r.GetType().GetField('FromBackEnd').SetValue($r, ($random.Next(10) -eq 0))
                    $last = $r
                }
                $r = $last
                $r.GetType().GetField('TimeMs').SetValue($r, [long](1000 * $i + $random.Next(500)))
                $r.GetType().GetField('Failure').SetValue($r, ($random.Next(3) -eq 0))
                $r.GetType().GetField('Outcome').SetValue($r, (& $pick @('ServerError', 'ClientError')))
                $r.GetType().GetField('Slow').SetValue($r, ($random.Next(5) -eq 0))
                $r.GetType().GetField('DurationMs').SetValue($r, [long]$random.Next(1, 9000))
                $r.GetType().GetField('BytesIn').SetValue($r, [long]$random.Next(0, 900))
                $server = & $pick @('EX1', 'EX2', ('EX' + '1'))
                [void]$count.Invoke($null, @($r, $server, $usage, $actions, $clients, $successes, $memo))
            }
            $sets[$withMemo] = (Dump $usage) + "`n--`n" + (Dump $actions) + "`n--`n" + (Dump $clients) + "`n--`n" + (Dump $successes)
        }
        $sets[$true] | Should -BeExactly $sets[$false]
        $sets[$true].Length | Should -BeGreaterThan 1000
    }
}
