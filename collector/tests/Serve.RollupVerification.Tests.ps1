#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'ExchangeLogReport.psd1') -Force
    Initialize-ExlEngine -Root $script:Root
    if (-not ('ServeFixtures' -as [type])) {
        Add-Type -LiteralPath (Join-Path $PSScriptRoot 'ServeFixtures.cs') -IgnoreWarnings -WarningAction SilentlyContinue -ReferencedAssemblies @(
            (Join-Path $script:Root 'lib\sqlite\Microsoft.Data.Sqlite.dll'),
            'System.Runtime', 'System.Data.Common', 'System.Reflection', 'System.Net.Sockets', 'System.Net.Primitives',
            'System.Text.Encoding.Extensions', 'System.IO', 'System.Collections', 'System.Linq.Expressions', 'System.ComponentModel.Primitives', 'netstandard')
    }
    $script:Work = Join-Path $script:Root ('bin\t\v' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($script:Work)
    function Get-SchemaMaster($Store) {
        # Every object name and every index/trigger definition, plus the table definitions this schema changed. The other table definitions are not
        # compared: the synthetic schema-6 fixture drops and re-adds msg_hash, which legitimately moves the column in the stored CREATE TABLE text.
        ($Store.Query("SELECT type,name,tbl_name,CASE WHEN type<>'table' OR name IN('source_file','source_fields','message_rollup','message_rollup_dirty','message_rollup_value','smtp_client_value','smtp_client','smtp_client_hour','smtp_client_pending','smtp_client_dirty') THEN sql END FROM sqlite_master ORDER BY type,name;",$null).Rows | ForEach-Object { $_ -join '|' }) -join "`n"
    }
    function Get-SchemaObjects($Store) {
        ($Store.Query("SELECT type,name,tbl_name,sql FROM sqlite_master WHERE type IN('index','trigger') ORDER BY type,name;",$null).Rows | ForEach-Object { $_ -join '|' }) -join "`n"
    }
    function New-VerificationStore {
        $s=[ExchangeLogReport.Store]::new((Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0,8)+'.sqlite')),$false,'synthetic')
        $s.Exec(@"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,recipient_count,total_bytes,subject) VALUES
(1792000000000,'EX1','RECEIVE','<Case@invalid>','a','alpha@invalid','one@invalid;two@invalid',2,8192,'subject'),
(1792000000100,'EX1','DELIVER','<Case@invalid>','b','alpha@invalid','one@invalid',1,8192,NULL),
(1792000000200,'EX2','FAIL','<Case@invalid>','c','alpha@invalid','two@invalid',1,8192,NULL),
(1792000000300,'EX1','DELIVER','<case@invalid>','d','beta@invalid','one@invalid',1,4096,'case-sensitive'),
(1792000000400,'EX1','NOTIFYMAPI','<é😀@invalid>','e','beta@invalid','one@invalid',1,1024,'Unicode'),
(1791900000000,'EX1','RECEIVE','<long@invalid>','f','beta@invalid','one@invalid',1,1024,'long');
INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,session_id,message_id,status,mail_from,rcpts) VALUES
(1791999999000,1792000000000,'EX1','Receive','case','<Case@invalid>','Accepted','alpha@invalid','one@invalid'),
(1792000000500,1792000000600,'EX1','Receive','only','<smtp-only@invalid>','Rejected','gamma@invalid','one@invalid'),
(1792000000700,1792000000800,'EX1','Receive','long','<long@invalid>','Accepted','beta@invalid','one@invalid'),
(1792000000900,1792000001000,'EX1','Receive','rejected',NULL,'Rejected','gamma@invalid','one@invalid'),
(1792000001100,NULL,'EX1','Receive','incomplete',NULL,NULL,'gamma@invalid','one@invalid'),
(1792000001200,NULL,'EX1','Receive','accepted',NULL,'Accepted','gamma@invalid','one@invalid'),
(1792000001300,NULL,'EX1','Send','send',NULL,'Rejected','gamma@invalid','one@invalid');
"@)
        $tx=$s.Begin()
        try { $s.ReconcileMessageRollups($tx); $tx.Commit() } finally { $tx.Dispose() }
        return $s
    }
}

AfterAll {
    if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
}

Describe 'Serve exact derived-rollup verification' {
    It 'recomputes every identity, canonical source hash and field without changing any retained rows' {
        $s=New-VerificationStore
        try {
            $before=[ServeFixtures]::RawBaseline($s)
            $derived=[ServeFixtures]::DecodedRollup($s)
            $result=$s.VerifyServeRollups()
            $result.Verified | Should -BeTrue
            $result.SchemaVersion | Should -Be 11
            $result.SmtpClientsVerified | Should -BeTrue
            # The fixture's SMTP transactions have no observed endpoint: each one is a group of its own and none is aggregated.
            $result.SmtpClientRows | Should -Be 0
            $result.SmtpClientHourRows | Should -Be 0
            $result.RowsVerified | Should -Be 7
            $result.TrackingIdentities | Should -Be 4
            $result.SmtpOnlyIdentities | Should -Be 1
            $result.MissingMessageIdSmtpIdentities | Should -Be 2
            $result.SourceHashGroupsVerified | Should -Be 7
            $result.SourceHashesVerified | Should -BeTrue
            $result.SchemaObjectsVerified | Should -BeTrue
            $result.ReadOnlySnapshot | Should -BeTrue
            $result.CacheKilobytes | Should -Be 16384
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $before
            ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $derived
            foreach ($table in 'message_event','smtp_transaction') {
                # Schema 10: the identity indexes hold (msg_hash,time_ms), so the exact-identity grouping of the verifier is one table scan with a sorter (allowed).
                $plan=$s.Query("EXPLAIN QUERY PLAN SELECT msg_hash,message_id FROM $table NOT INDEXED WHERE message_id IS NOT NULL GROUP BY msg_hash,message_id COLLATE BINARY ORDER BY msg_hash,message_id COLLATE BINARY;",$null)
                ($plan.Rows | ForEach-Object {$_[3]}) -join "`n" | Should -Match "SCAN $table(\r?\n|$)"
            }
            $path=$s.FilePath; $s.Dispose()
            $hash=(Get-FileHash -LiteralPath $path).Hash
            $s=[ExchangeLogReport.Store]::new($path,$true,'synthetic')
            $s.VerifyServeRollups().RowsVerified | Should -Be 7
            (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $hash
        } finally { $s.Dispose() }
    }

    It 'migrates a schema-8 database to schema 11 in place: derived rows (decoded) and the sequence stay identical, ids are kept, the SMTP client structures are derived' {
        $s=New-VerificationStore
        try {
            $rollups=[ServeFixtures]::DecodedRollup($s)
            $sequence=$s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null)
            $raw=[ServeFixtures]::RawBaseline($s)
            $fresh=Get-SchemaObjects $s
            [ServeFixtures]::ConvertToLegacySyntheticFixture($s,8)
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN('ix_msg_hash','ix_smtp_hash','ix_session_latest');",$null) | Should -Be 3
            $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '8'
            $path=$s.FilePath; $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '11'
            Get-SchemaObjects $s | Should -BeExactly $fresh
            ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $rollups
            $s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null) | Should -Be $sequence
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $raw
            $s.VerifyServeRollups().Verified | Should -BeTrue
            $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally {$s.Dispose()}
    }

    It 'ends schema-6, 7, 8, 9 and 10 databases in the same schema-11 sqlite_master as a fresh one, without hash-only indexes and without ix_smtp_latest' {
        $s=New-VerificationStore
        try { $fresh=Get-SchemaObjects $s; $freshMaster=Get-SchemaMaster $s } finally {$s.Dispose()}
        foreach ($version in 6,7,8,9,10) {
            $s=New-VerificationStore
            try {
                [ServeFixtures]::ConvertToLegacySyntheticFixture($s,$version)
                $path=$s.FilePath; $s.Dispose()
                $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
                Get-SchemaObjects $s | Should -BeExactly $fresh
                Get-SchemaMaster $s | Should -BeExactly $freshMaster
                $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '11'
                $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN('ix_msg_hash','ix_smtp_hash','ix_session_latest','ix_smtp_latest');",$null) | Should -Be 0
                $s.VerifyServeRollups().Verified | Should -BeTrue
            } finally {$s.Dispose()}
        }
    }

    It 'leaves the dirty queue empty and the rollups verified when UPDATE touches only a column the rollup is not derived from (<Table>.<Column>)' -ForEach @(
        @{Table='message_event';Column='source';Value='changed'}, @{Table='message_event';Column='internal_id';Value='changed'},
        @{Table='message_event';Column='recipient_status';Value='changed'}, @{Table='message_event';Column='client_ip';Value='changed'},
        @{Table='message_event';Column='client_host';Value='changed'}, @{Table='message_event';Column='server_host';Value='changed'},
        @{Table='message_event';Column='connector';Value='changed'}, @{Table='message_event';Column='source_context';Value='changed'},
        @{Table='message_event';Column='related_recipient';Value='changed'}, @{Table='message_event';Column='reference';Value='changed'},
        @{Table='smtp_transaction';Column='role';Value='changed'}, @{Table='smtp_transaction';Column='connector';Value='changed'},
        @{Table='smtp_transaction';Column='remote_ep';Value='changed'}, @{Table='smtp_transaction';Column='local_ep';Value='changed'},
        @{Table='smtp_transaction';Column='helo';Value='changed'}, @{Table='smtp_transaction';Column='tls';Value='changed'},
        @{Table='smtp_transaction';Column='auth';Value='changed'}, @{Table='smtp_transaction';Column='rcpt_count';Value=77},
        @{Table='smtp_transaction';Column='auth_user';Value='changed@invalid'}
    ) {
        $s=New-VerificationStore
        try {
            $before=[ServeFixtures]::DecodedRollup($s)
            $c=[ServeFixtures]::Connection($s).CreateCommand()
            try {
                $c.CommandText="UPDATE $Table SET $Column=@value;"
                [void]$c.Parameters.AddWithValue('@value',$Value); [void]$c.ExecuteNonQuery()
            } finally {$c.Dispose()}
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            if ($Table -eq 'smtp_transaction' -and $Column -in 'role','connector','remote_ep','helo','tls','rcpt_count','auth_user') {
                # These columns are part of the SMTP client key or of its buckets (schema 11): the update trigger queues them for ReconcileSmtpClients.
                $s.Scalar('SELECT COUNT(*) FROM smtp_client_pending;',$null) | Should -BeGreaterThan 0
                { $s.VerifyServeRollups() } | Should -Throw '*unreconciled*'
                [ServeFixtures]::RefreshServeRollups($s)
                $s.Scalar('SELECT COUNT(*) FROM smtp_client_pending;',$null) + $s.Scalar('SELECT COUNT(*) FROM smtp_client_dirty;',$null) | Should -Be 0
            } else {
                $s.Scalar('SELECT COUNT(*) FROM smtp_client_pending;',$null) + $s.Scalar('SELECT COUNT(*) FROM smtp_client_dirty;',$null) | Should -Be 0
            }
            $s.VerifyServeRollups().Verified | Should -BeTrue
            ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $before
        } finally { $s.Dispose() }
    }

    It 'marks the identity dirty when UPDATE touches a column the rollup is derived from (<Table>.<Column>)' -ForEach @(
        @{Table='message_event';Column='message_id';Value='<moved@invalid>'}, @{Table='message_event';Column='time_ms';Value=1792000000050},
        @{Table='message_event';Column='server';Value='EX9'}, @{Table='message_event';Column='event_id';Value='FAIL'},
        @{Table='message_event';Column='sender';Value='changed@invalid'}, @{Table='message_event';Column='recipients';Value='changed@invalid'},
        @{Table='message_event';Column='recipient_count';Value=77}, @{Table='message_event';Column='total_bytes';Value=99999},
        @{Table='message_event';Column='subject';Value='changed'}, @{Table='message_event';Column='directionality';Value='Originating'},
        @{Table='smtp_transaction';Column='message_id';Value='<moved@invalid>'}, @{Table='smtp_transaction';Column='time_ms';Value=1792000000050},
        @{Table='smtp_transaction';Column='end_ms';Value=1792009999999}, @{Table='smtp_transaction';Column='server';Value='EX9'},
        @{Table='smtp_transaction';Column='direction';Value='Send'}, @{Table='smtp_transaction';Column='mail_from';Value='changed@invalid'},
        @{Table='smtp_transaction';Column='rcpts';Value='changed@invalid'}, @{Table='smtp_transaction';Column='status';Value='Deferred'}
    ) {
        $s=New-VerificationStore
        try {
            $c=[ServeFixtures]::Connection($s).CreateCommand()
            try {
                $c.CommandText="UPDATE $Table SET $Column=@value WHERE id=(SELECT MIN(id) FROM $Table);"
                [void]$c.Parameters.AddWithValue('@value',$Value); [void]$c.ExecuteNonQuery()
            } finally {$c.Dispose()}
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -BeGreaterThan 0
            [ServeFixtures]::RefreshServeRollups($s)
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
    }

    It 'migrates a schema-9 database to schema 11: narrowed identity indexes, exact fields dictionary, no source or (decoded) rollup row changes, idempotent' {
        $texts = @('#Fields: date-time,a', ('#Fields: ' + ('x,' * 2500)), '', ' padded ', "line`r`nbreak", 'Case', 'case', ([string][char]0xE9 + [char]::ConvertFromUtf32(0x1F600) + [char]0x754C))
        $s=New-VerificationStore
        try {
            $rollups=[ServeFixtures]::DecodedRollup($s)
            $sequence=$s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null)
            $fresh=Get-SchemaObjects $s; $freshMaster=Get-SchemaMaster $s
            [ServeFixtures]::ConvertToLegacySyntheticFixture($s,9)
            $c=[ServeFixtures]::Connection($s).CreateCommand()
            try {
                $c.CommandText="INSERT INTO source_file(server,kind,path,file_key,offset,size,fields) VALUES('EX1','Tracking',@p,@p,10,20,@f);"
                $pp=$c.Parameters.Add('@p',[Microsoft.Data.Sqlite.SqliteType]::Text); $pf=$c.Parameters.Add('@f',[Microsoft.Data.Sqlite.SqliteType]::Text)
                $n=0
                foreach ($round in 1..3) { foreach ($t in $texts) { $pp.Value="p$((++$n))"; $pf.Value=$t; [void]$c.ExecuteNonQuery() } }
                $pp.Value='p-null'; $pf.Value=[DBNull]::Value; [void]$c.ExecuteNonQuery()
                $c.CommandText="INSERT INTO source_file(server,kind,path,offset,size,fields) VALUES('EX1','Tracking','blob-row',1,2,X'00FF');"
                [void]$c.ExecuteNonQuery()
            } finally {$c.Dispose()}
            $beforeRows=($s.Query("SELECT id,server,kind,path,file_key,offset,size,last_write_ms,typeof(fields),hex(fields),first_ms,last_ms,lines,kept,noise,updated_ms FROM source_file ORDER BY id;",$null).Rows | ConvertTo-Json -Depth 5 -Compress)
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN('source_fields');",$null) | Should -Be 0
            $path=$s.FilePath; $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Query("SELECT value FROM metadata WHERE key='schema_version';",$null).Rows[0][0] | Should -Be '11'
            Get-SchemaObjects $s | Should -BeExactly $fresh
            Get-SchemaMaster $s | Should -BeExactly $freshMaster
            $s.Scalar('SELECT COUNT(*) FROM source_fields;',$null) | Should -Be $texts.Count
            # The dictionary holds each distinct text once, byte for byte; every text row points at it and does not repeat the text.
            foreach ($t in $texts) { $s.Scalar('SELECT COUNT(*) FROM source_fields WHERE hex(text)=@h;',@{h=[Convert]::ToHexString([Text.Encoding]::UTF8.GetBytes($t))}) | Should -Be 1 }
            $s.Scalar("SELECT COUNT(*) FROM source_file WHERE fields_id IS NOT NULL AND fields IS NULL;",$null) | Should -Be ($texts.Count * 3)
            $s.Scalar("SELECT COUNT(*) FROM source_file WHERE fields_id IS NULL AND fields IS NULL;",$null) | Should -Be 1
            $s.Scalar("SELECT COUNT(*) FROM source_file WHERE fields_id IS NULL AND fields IS NOT NULL AND typeof(fields)='blob';",$null) | Should -Be 1
            $afterRows=($s.Query("SELECT s.id,s.server,s.kind,s.path,s.file_key,s.offset,s.size,s.last_write_ms,typeof(COALESCE(d.text,s.fields)),hex(COALESCE(d.text,s.fields)),s.first_ms,s.last_ms,s.lines,s.kept,s.noise,s.updated_ms FROM source_file s LEFT JOIN source_fields d ON d.id=s.fields_id ORDER BY s.id;",$null).Rows | ConvertTo-Json -Depth 5 -Compress)
            $afterRows | Should -BeExactly $beforeRows
            # KnownFiles hands the collector the same logical text.
            $known=$s.KnownFiles()
            $known.Count | Should -Be ($texts.Count * 3 + 1)
            $s.Scalar("SELECT COUNT(*) FROM source_file WHERE file_key IS NOT NULL;",$null) | Should -Be ($texts.Count * 3 + 1)
            foreach ($k in $known.Keys) { $v=$known[$k]; if ($v.Path -ne 'p-null') { @($texts | Where-Object { $_ -ceq $v.Fields }).Count | Should -Be 1 } else { $v.Fields | Should -BeNullOrEmpty } }
            @($known.Values | Where-Object { $_.Fields -ceq '' }).Count | Should -Be 3
            ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $rollups
            $s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null) | Should -Be $sequence
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            $s.VerifyServeRollups().Verified | Should -BeTrue
            $cookie=$s.Scalar('PRAGMA schema_version;',$null)
            $s.Dispose()
            # A second open changes no schema object and no row (the SQLite schema cookie counts every DDL change).
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Scalar('PRAGMA schema_version;',$null) | Should -Be $cookie
            Get-SchemaMaster $s | Should -BeExactly $freshMaster
            ($s.Query("SELECT s.id,COALESCE(d.text,s.fields) FROM source_file s LEFT JOIN source_fields d ON d.id=s.fields_id ORDER BY s.id;",$null).Rows | ConvertTo-Json -Depth 5 -Compress) | Should -Not -BeNullOrEmpty
        } finally {$s.Dispose()}
    }

    It 'rolls back a failed schema-10 publication of a schema-9 database atomically (indexes, dictionary, header text and version)' {
        $s=New-VerificationStore
        [ServeFixtures]::ConvertToLegacySyntheticFixture($s,9)
        $s.Exec("INSERT INTO source_file(server,kind,path,file_key,fields) VALUES('EX1','Tracking','a','A','#Fields: one'),('EX1','Tracking','b','B','#Fields: one');")
        $s.Exec("CREATE TRIGGER fail_schema10 BEFORE UPDATE ON metadata WHEN NEW.key='schema_version' AND NEW.value='10' BEGIN SELECT RAISE(ABORT,'synthetic migration failure'); END;")
        $path=$s.FilePath; $s.Dispose()
        { [ExchangeLogReport.Store]::new($path,$false,'synthetic') } | Should -Throw '*synthetic migration failure*'
        $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False"); $db.Open()
        try {
            $c=$db.CreateCommand()
            $c.CommandText="SELECT value FROM metadata WHERE key='schema_version';"; $c.ExecuteScalar() | Should -BeExactly '9'
            $c.CommandText="SELECT COUNT(*) FROM sqlite_master WHERE name='source_fields';"; $c.ExecuteScalar() | Should -Be 0
            $c.CommandText="SELECT COUNT(*) FROM pragma_table_info('source_file') WHERE name='fields_id';"; $c.ExecuteScalar() | Should -Be 0
            $c.CommandText="SELECT COUNT(*) FROM source_file WHERE fields='#Fields: one';"; $c.ExecuteScalar() | Should -Be 2
            $c.CommandText="SELECT sql FROM sqlite_master WHERE name='ix_msg_identity_time';"; $c.ExecuteScalar() | Should -Match 'message_id COLLATE BINARY,time_ms,id'
        } finally { $db.Dispose() }
    }

    It 'looks identities up through the narrowed hash index with the exact BINARY compare on the row and no sorter (schema 10)' {
        $s=New-VerificationStore
        try {
            $s.Query("SELECT sql FROM sqlite_master WHERE name='ix_msg_identity_time';",$null).Rows[0][0] | Should -BeExactly 'CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,time_ms)'
            $s.Query("SELECT sql FROM sqlite_master WHERE name='ix_smtp_identity_time';",$null).Rows[0][0] | Should -BeExactly 'CREATE INDEX ix_smtp_identity_time ON smtp_transaction(msg_hash,time_ms)'
            foreach ($table in 'message_event','smtp_transaction') {
                $plan=($s.Query("EXPLAIN QUERY PLAN SELECT time_ms FROM $table WHERE msg_hash=1 AND message_id='<Case@invalid>' COLLATE BINARY ORDER BY time_ms,id;",$null).Rows | ForEach-Object {$_[3]}) -join "`n"
                $plan | Should -Match "SEARCH $table USING INDEX ix_(msg|smtp)_identity_time \(msg_hash=\?\)"
                $plan | Should -Not -Match 'TEMP B-TREE'
                $plan=($s.Query("EXPLAIN QUERY PLAN SELECT 1 FROM $table e WHERE e.msg_hash=1 AND e.message_id='<Case@invalid>' COLLATE BINARY AND e.time_ms>=0 AND e.time_ms<5 LIMIT 1;",$null).Rows | ForEach-Object {$_[3]}) -join "`n"
                $plan | Should -Match "SEARCH e USING INDEX ix_(msg|smtp)_identity_time \(msg_hash=\? AND time_ms>\? AND time_ms<\?\)"
            }
            # The exact identity still decides: a forced hash collision between differently-cased IDs is separated by the row compare.
            [ServeFixtures]::ForceHashCollision($s)
            $s.Exec("UPDATE message_event SET msg_hash=0;")   # the repair trigger now stores 17 for every row
            $s.Scalar("SELECT COUNT(*) FROM message_event WHERE msg_hash=17;",$null) | Should -BeGreaterThan 4
            $s.Scalar("SELECT COUNT(*) FROM message_event WHERE msg_hash=17 AND message_id='<Case@invalid>' COLLATE BINARY;",$null) | Should -Be 3
            $s.Scalar("SELECT COUNT(*) FROM message_event WHERE msg_hash=17 AND message_id='<case@invalid>' COLLATE BINARY;",$null) | Should -Be 1
        } finally {$s.Dispose()}
    }

    It 'verifies an empty schema9 store without requiring an allocated sequence row' {
        $s=[ExchangeLogReport.Store]::new((Join-Path $script:Work 'empty.sqlite'),$false,'synthetic')
        try { $s.VerifyServeRollups().RowsVerified | Should -Be 0 } finally { $s.Dispose() }
    }

    It 'publishes raw synthetic fixture inserts only after an explicit transactional refresh' {
        $s=New-VerificationStore
        try {
            $s.Exec("INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES(1792000001500,'EX1','DELIVER','<fixture@invalid>','fixture','s@invalid','r@invalid');")
            { $s.VerifyServeRollups() } | Should -Throw '*unreconciled*'
            [ServeFixtures]::RefreshServeRollups($s)
            $s.VerifyServeRollups().RowsVerified | Should -Be 8
        } finally {$s.Dispose()}
    }

    It 'converts a synthetic connection to real legacy objects while preserving raw source values' {
        $s=New-VerificationStore
        try {
            $before=[ServeFixtures]::RawBaseline($s)
            [ServeFixtures]::ConvertToLegacySyntheticFixture([ServeFixtures]::Connection($s),7)
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN('message_rollup','message_rollup_dirty','ix_msg_identity_time','ix_smtp_identity_time','ix_smtp_latest','ix_session_latest') OR name GLOB 'tr_*_rollup_*';",$null) | Should -Be 0
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $before
            $path=$s.FilePath; $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.VerifyServeRollups().RowsVerified | Should -Be 7
            [ServeFixtures]::ConvertToLegacySyntheticFixture($s,6)
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $before
            $s.Scalar("SELECT COUNT(*) FROM pragma_table_info('message_event') WHERE name='msg_hash';",$null) | Should -Be 0
        } finally {$s.Dispose()}
    }

    It 'keeps all derived rows and sequence identical after safe repacking and an explicit empty refresh' {
        $s=New-VerificationStore
        try {
            $text='synthetic compressible safe text ' * 100
            $opaque='opaque synthetic evidence; deliberately not JSON ' * 80
            $c=[ServeFixtures]::Connection($s).CreateCommand()
            try {
                $c.CommandText=@"
INSERT INTO access_event(time_ms,server,source,protocol,url,errors,outcome,request_id)
VALUES(1792000000000,'EX1','Synthetic','Mapi',@text,@text,'OK','safe-request');
INSERT INTO client_session(skey,day,start_ms,end_ms,user,protocol,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,actions,statuses)
VALUES('safe-session','2026-10-14',1792000000000,1792000000001,'s@invalid','Mapi',1,1,0,0,1792000000000,1792000000001,0,0,1,1,0,0,@text,@text);
UPDATE smtp_transaction SET response=@text,transcript=@opaque WHERE session_id='case';
INSERT INTO smtp_auth_fragment(source_key,first_offset,first_ms,last_ms,server,direction,session_id,observations)
VALUES('SYNTHETIC',0,1792000000000,1792000000001,'EX1','Receive','opaque',@opaque);
"@
                [void]$c.Parameters.AddWithValue('@text',$text)
                [void]$c.Parameters.AddWithValue('@opaque',$opaque)
                [void]$c.ExecuteNonQuery()
            } finally {$c.Dispose()}
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            $before=[ServeFixtures]::DecodedRollup($s)
            $sequence=$s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null)
            $s.RepackSafeText() | Should -Be 5
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            $s.RefreshServeRollups()
            ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $before
            $s.Scalar("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';",$null) | Should -Be $sequence
            $s.Query("SELECT typeof(observations),observations FROM smtp_auth_fragment WHERE session_id='opaque';",$null).Rows[0][0] | Should -BeExactly 'text'
            $s.Query("SELECT observations FROM smtp_auth_fragment WHERE session_id='opaque';",$null).Rows[0][0] | Should -BeExactly $opaque
            $s.Query("SELECT transcript FROM smtp_transaction WHERE session_id='case';",$null).Rows[0][0] | Should -BeExactly $opaque
            $path=$s.FilePath; $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Query("SELECT observations FROM smtp_auth_fragment WHERE session_id='opaque';",$null).Rows[0][0] | Should -BeExactly $opaque
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally {$s.Dispose()}
    }

    It 'preserves opaque TEXT auth observations across schema6 migration and rejects read-only refresh' {
        $s=New-VerificationStore
        try {
            $opaque='synthetic opaque evidence, not JSON'
            $s.Exec("INSERT INTO smtp_auth_fragment(source_key,first_offset,first_ms,last_ms,server,direction,session_id,observations) VALUES('SYNTHETIC',0,1792000000000,1792000000001,'EX1','Receive','opaque','$opaque');")
            [ServeFixtures]::ConvertToLegacySyntheticFixture($s,6)
            $path=$s.FilePath; $s.Dispose()
            $s=[ExchangeLogReport.Store]::new($path,$false,'synthetic')
            $s.Query("SELECT typeof(observations),observations FROM smtp_auth_fragment WHERE session_id='opaque';",$null).Rows[0][0] | Should -BeExactly 'text'
            $s.Query("SELECT observations FROM smtp_auth_fragment WHERE session_id='opaque';",$null).Rows[0][0] | Should -BeExactly $opaque
            $s.Dispose(); $s=[ExchangeLogReport.Store]::new($path,$true,'synthetic')
            { $s.RefreshServeRollups() } | Should -Throw '*writable store*'
        } finally {$s.Dispose()}
    }

    It 'rejects corruption in derived column <Column>' -ForEach @(
        @{Column='kind';Value=1}, @{Column='identity';Value='<corrupt@invalid>'},
        @{Column='msg_hash';Value=0}, @{Column='first_ms';Value=0}, @{Column='last_ms';Value=0},
        @{Column='member_first_ms';Value=0}, @{Column='member_last_ms';Value=0},
        @{Column='status';Value=99999}, @{Column='sender';Value='corrupt@invalid'},
        @{Column='recipients';Value='["corrupt@invalid"]'}, @{Column='recipient_count';Value=0},
        @{Column='delivered';Value=999}, @{Column='failed';Value=999},
        @{Column='subject';Value='corrupt'}, @{Column='size_kb';Value=0},
        @{Column='direction';Value=99999}, @{Column='servers';Value=99999},
        @{Column='events';Value=99999}, @{Column='events_count';Value=0}, @{Column='smtp_count';Value=0}
    ) {
        $s=New-VerificationStore
        try {
            $c=[ServeFixtures]::Connection($s).CreateCommand()
            try {
                $c.CommandText="UPDATE message_rollup SET $Column=@value WHERE kind=0 AND identity='<Case@invalid>';"
                [void]$c.Parameters.AddWithValue('@value',$Value); [void]$c.ExecuteNonQuery()
            } finally {$c.Dispose()}
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidServeRollup*'
        } finally { $s.Dispose() }
    }

    It 'rejects missing or extra identities and never repairs them implicitly' {
        $s=New-VerificationStore
        try {
            $s.Exec("INSERT INTO message_rollup(kind,identity,msg_hash,first_ms,last_ms,member_first_ms,member_last_ms,status,sender,recipients,recipient_count,delivered,failed,subject,size_kb,direction,servers,events,events_count,smtp_count) SELECT kind,'<orphan@invalid>',msg_hash,first_ms,last_ms,member_first_ms,member_last_ms,status,sender,recipients,recipient_count,delivered,failed,subject,size_kb,direction,servers,events,events_count,smtp_count FROM message_rollup WHERE identity='<Case@invalid>';")
            { $s.VerifyServeRollups() } | Should -Throw '*extra or missing*'
            $s.Scalar('SELECT COUNT(*) FROM message_rollup;',$null) | Should -Be 8
            $s.Exec("DELETE FROM message_rollup WHERE identity='<orphan@invalid>'; DELETE FROM message_rollup WHERE identity='<Case@invalid>';")
            { $s.VerifyServeRollups() } | Should -Throw '*missing derived identity*'
            $s.Scalar('SELECT COUNT(*) FROM message_rollup;',$null) | Should -Be 6
        } finally { $s.Dispose() }
    }

    It 'rejects nonpositive URL IDs and invalid or duplicated stable-ID sequence state' {
        $s=New-VerificationStore
        try {
            $id=$s.Scalar("SELECT id FROM message_rollup WHERE identity='<Case@invalid>';",$null)
            $s.Exec("UPDATE message_rollup SET id=-1 WHERE id=$id;")
            { $s.VerifyServeRollups() } | Should -Throw '*positive INTEGER*'
            $s.Exec("UPDATE message_rollup SET id=$id WHERE id=-1; UPDATE sqlite_sequence SET seq=0 WHERE name='message_rollup';")
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidServeRollupSequence*'
            $s.Exec("UPDATE sqlite_sequence SET seq=100 WHERE name='message_rollup'; INSERT INTO sqlite_sequence(name,seq) VALUES('message_rollup',100);")
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidServeRollupSequence*'
        } finally { $s.Dispose() }
    }

    It 'refuses pending invalidations and verifies again after normal transactional reconciliation' {
        $s=New-VerificationStore
        try {
            $s.Exec("UPDATE message_event SET event_id='SEND' WHERE log_id='b';")
            { $s.VerifyServeRollups() } | Should -Throw '*unreconciled*'
            $tx=$s.Begin()
            try {$s.ReconcileMessageRollups($tx);$tx.Commit()}finally{$tx.Dispose()}
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
    }

    It 'rejects noncanonical added source hashes instead of certifying an incompatible accelerator' {
        $s=New-VerificationStore
        try {
            [ServeFixtures]::ForceHashCollision($s)
            $s.Exec("UPDATE message_event SET msg_hash=17 WHERE log_id='d';")
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidSourceHash*'
        } finally {$s.Dispose()}
        $s=New-VerificationStore
        try {
            [ServeFixtures]::ForceInvalidNullHash($s)
            $s.Exec("UPDATE smtp_transaction SET msg_hash=17 WHERE message_id IS NULL;")
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidSourceHash*'
        } finally {$s.Dispose()}
    }

    It 'does not accept a different hash algorithm merely because synthetic collisions were injected' {
        $s=New-VerificationStore
        try {
            [ServeFixtures]::ForceHashCollision($s)
            $s.Exec("UPDATE message_event SET msg_hash=17; UPDATE smtp_transaction SET msg_hash=17 WHERE message_id IS NOT NULL;")
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidSourceHash*'
        } finally {$s.Dispose()}
    }

    It 'does not certify a committed snapshot while its caller has an active collection transaction' {
        $s=New-VerificationStore
        try {
            $tx=$s.Begin()
            try { { $s.VerifyServeRollups() } | Should -Throw } finally {$tx.Dispose()}
        } finally {$s.Dispose()}
    }

    It 'interrupts verification at its explicit deadline and preserves source evidence' {
        $s=New-VerificationStore
        try {
            [ServeFixtures]::Populate($s,1792100000000L,20000)
            $before=[ServeFixtures]::RawBaseline($s)
            $clock=[Diagnostics.Stopwatch]::StartNew()
            { $s.VerifyServeRollupsWithDeadline(1,[Threading.CancellationToken]::None) } | Should -Throw '*explicit deadline*'
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $before
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally {$s.Dispose()}
    }

    It 'rejects missing, changed or extra canonical schema objects (<Change>)' -ForEach @(
        @{Change='missing-index';Sql='DROP INDEX ix_rollup_last;'},
        @{Change='changed-index';Sql='DROP INDEX ix_rollup_last; CREATE INDEX ix_rollup_last ON message_rollup(id,member_last_ms);'},
        @{Change='schema8-desc-index';Sql='DROP INDEX ix_rollup_last; CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms DESC,id DESC);'},
        @{Change='schema10-nocase-status-index';Sql='DROP INDEX ix_rollup_status_last; CREATE INDEX ix_rollup_status_last ON message_rollup(status COLLATE NOCASE,member_last_ms);'},
        @{Change='obsolete-smtp-latest-index';Sql='CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms);'},
        @{Change='missing-smtp-client-index';Sql='DROP INDEX ix_smtp_client;'},
        @{Change='changed-smtp-client-index';Sql='DROP INDEX ix_smtp_client; CREATE INDEX ix_smtp_client ON smtp_transaction(client_id);'},
        @{Change='missing-unknown-peer-index';Sql='DROP INDEX ix_smtp_unknown_peer;'},
        @{Change='missing-client-key';Sql='DROP INDEX ux_smtp_client;'},
        @{Change='missing-hour-index';Sql='DROP INDEX ix_smtp_client_hour;'},
        @{Change='missing-client-trigger';Sql='DROP TRIGGER tr_smtp_transaction_client_update;'},
        @{Change='changed-client-trigger';Sql='DROP TRIGGER tr_smtp_transaction_client_delete; CREATE TRIGGER tr_smtp_transaction_client_delete AFTER DELETE ON smtp_transaction BEGIN SELECT 1; END;'},
        @{Change='extra-client-table-index';Sql='CREATE INDEX unapproved_client_index ON smtp_client(server);'},
        @{Change='changed-client-table';Sql='ALTER TABLE smtp_client ADD COLUMN unapproved TEXT;'},
        @{Change='changed-rollup-value-table';Sql='ALTER TABLE message_rollup_value ADD COLUMN unapproved TEXT;'},
        @{Change='obsolete-message-hash-index';Sql='CREATE INDEX ix_msg_hash ON message_event(msg_hash);'},
        @{Change='obsolete-smtp-hash-index';Sql='CREATE INDEX ix_smtp_hash ON smtp_transaction(msg_hash);'},
        @{Change='obsolete-session-index';Sql='CREATE INDEX ix_session_latest ON client_session(start_ms DESC,id DESC);'},
        @{Change='schema8-wide-update-trigger';Sql='DROP TRIGGER tr_smtp_transaction_rollup_update; CREATE TRIGGER tr_smtp_transaction_rollup_update AFTER UPDATE OF id,message_id,time_ms,end_ms,server,direction,role,mail_from,rcpts,status,auth_user ON smtp_transaction BEGIN SELECT 1; END;'},
        @{Change='rollup-trigger';Sql='DROP TRIGGER tr_message_event_rollup_insert; CREATE TRIGGER tr_message_event_rollup_insert AFTER INSERT ON message_event BEGIN SELECT 1; END;'},
        @{Change='hash-trigger';Sql='DROP TRIGGER tr_message_event_hash_update; CREATE TRIGGER tr_message_event_hash_update AFTER UPDATE ON message_event BEGIN SELECT 1; END;'},
        @{Change='extra-derived-index';Sql='CREATE INDEX unapproved_rollup_index ON message_rollup(sender);'},
        @{Change='changed-table';Sql='ALTER TABLE message_rollup ADD COLUMN unapproved TEXT;'}
    ) {
        $s=New-VerificationStore
        try {
            $s.Exec($Sql)
            { $s.VerifyServeRollups() } | Should -Throw '*InvalidServeSchema*'
        } finally {$s.Dispose()}
    }

    It 'verifies statically without Store construction or modifying caller connection settings, transaction or lifetime' {
        $s=New-VerificationStore
        $path=$s.FilePath; $s.Dispose()
        $before=(Get-FileHash -LiteralPath $path).Hash
        $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False")
        $db.Open()
        try {
            $c=$db.CreateCommand(); $c.CommandText='PRAGMA query_only=ON; PRAGMA cache_size=-2048; PRAGMA mmap_size=1048576;'
            [void]$c.ExecuteNonQuery();$c.Dispose()
            $tx=$db.BeginTransaction($true)
            try {
                $receipt=[ExchangeLogReport.Store]::VerifyServeRollups($db)
                $receipt.Verified | Should -BeTrue
                $receipt.SchemaObjectsVerified | Should -BeTrue
                $receipt.RowsVerified | Should -Be 7
                $receipt.CallerSnapshotUsed | Should -BeFalse
                $receipt.CacheKilobytes | Should -Be 16384
                $db.State | Should -Be ([Data.ConnectionState]::Open)
                $c=$db.CreateCommand();$c.Transaction=$tx
                try {
                    foreach($pragma in @{cache_size=-2048;mmap_size=1048576;query_only=1}.GetEnumerator()){
                        $c.CommandText="PRAGMA $($pragma.Key);"
                        $c.ExecuteScalar() | Should -Be $pragma.Value
                    }
                } finally {$c.Dispose()}
            } finally {$tx.Dispose()}
            (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $before
        } finally {$db.Dispose()}
    }

    It 'rejects writable or closed caller connections and never migrates an old schema in the static entrypoint' {
        $s=New-VerificationStore
        try { { [ExchangeLogReport.Store]::VerifyServeRollups([ServeFixtures]::Connection($s)) } | Should -Throw '*open read-only*' }
        finally {$s.Dispose()}
        $path=Join-Path $script:Work 'static-old.sqlite'
        $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Pooling=False");$db.Open()
        try {
            $c=$db.CreateCommand();$c.CommandText="CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT); INSERT INTO metadata VALUES('schema_version','7');"
            [void]$c.ExecuteNonQuery();$c.Dispose()
        } finally {$db.Dispose()}
        $before=(Get-FileHash -LiteralPath $path).Hash
        $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False")
        try {
            { [ExchangeLogReport.Store]::VerifyServeRollups($db) } | Should -Throw '*open read-only*'
            $db.Open()
            { [ExchangeLogReport.Store]::VerifyServeRollups($db) } | Should -Throw '*Schema 11 is required*'
            (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $before
        } finally {$db.Dispose()}
    }

    It 'honors explicit cancellation and bounds selectable deadlines' {
        $s=New-VerificationStore
        $cancel=[Threading.CancellationTokenSource]::new()
        try {
            $cancel.Cancel()
            try { $s.VerifyServeRollupsWithDeadline(10,$cancel.Token); throw 'Unexpected verification success.' }
            catch { $_.Exception.GetBaseException().GetType().Name | Should -BeExactly 'OperationCanceledException' }
            foreach ($seconds in 0,3601) {
                { $s.VerifyServeRollupsWithDeadline($seconds,[Threading.CancellationToken]::None) } | Should -Throw '*timeoutSeconds*'
            }
        } finally {$cancel.Dispose();$s.Dispose()}
    }
}
