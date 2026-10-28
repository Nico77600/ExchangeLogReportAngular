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
            'System.Text.Encoding.Extensions', 'System.IO', 'System.Collections', 'System.Linq.Expressions', 'System.ComponentModel.Primitives', 'netstandard'
        )
    }
    $script:Work = Join-Path $script:Root ('bin\t\s' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $script:Web = Join-Path $script:Work 'web'
    [void][IO.Directory]::CreateDirectory($script:Web)
    [IO.File]::WriteAllText((Join-Path $script:Web 'index.html'), '<!doctype html><script>var scoutTheme;matchMedia("(prefers-color-scheme: dark)");document.documentElement.setAttribute("data-theme","light");</script><p>Synthetic Serve test</p>')
    [IO.File]::WriteAllText((Join-Path $script:Web 'main.js'), 'console.log("synthetic");')
    $script:Epoch = 1792000000000L
    $script:Period = 'from=2026-10-14T00%3A00%3A00Z&to=2026-10-16T00%3A00%3A00Z'
    $script:Hosts = [Collections.Generic.List[object]]::new()
    function New-ServeStore([string]$Name) { [ExchangeLogReport.Store]::new((Join-Path $script:Work "$Name.sqlite"), $false, 'synthetic') }
    function Write-Sql($Store, [string]$Sql, [hashtable]$Values = @{}) {
        $c = [ServeFixtures]::Connection($Store).CreateCommand()
        try {
            $c.CommandText = $Sql
            foreach ($key in $Values.Keys) {
                $value = $Values[$key]
                if ($null -eq $value) { $value = [DBNull]::Value }
                [void]$c.Parameters.AddWithValue("@$key", $value)
            }
            [void]$c.ExecuteNonQuery()
        } finally { $c.Dispose() }
    }
    function Reconcile($Store) {
        $tx = $Store.Begin()
        try { $Store.ReconcileMessageRollups($tx); $tx.Commit() } finally { $tx.Dispose() }
    }
    function Collect-Tracking($Store, [string]$Folder, [bool]$FailOnError = $true, [bool]$TriggersOff = $true) {
        $o = [ExchangeLogReport.CollectorOptions]::new()
        $o.NowMs = $script:Epoch+86400000; $o.Parallelism = 1
        $o.DisableTriggersDuringApply = $TriggersOff
        $o.RunId = $Store.StartRun('Collect','synthetic','synthetic','test')
        $collector = [ExchangeLogReport.Collector]::new($Store,$o)
        $job = [ExchangeLogReport.SourceJob]::new()
        $job.Server='EX1'; $job.Kind='Tracking'; $job.Folder=$Folder
        $collector.Plan(@($job),[datetime]::MinValue)
        $run=$collector.Start(@($job)); [void]$run.Wait(-1)
        if($run.Error -and $FailOnError){throw $run.Error}
        if(-not $run.Error){[void]$collector.Complete()}
        return $run
    }
    function Add-Mail($Store) {
        Write-Sql $Store @"
INSERT INTO source_file(id,server,kind,path,offset,size,first_ms,last_ms,file_key) VALUES(1,'EX1','Tracking','synthetic.log',1234,5678,@t-86400000,@t+86400000,'SYNTHETIC');
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,subject,recipient_count)
VALUES(@t,'EX1','RECEIVE','<Case@invalid>','a','alpha@invalid','one@invalid;two@invalid','=SUM(1)',2),
(@t+100,'EX1','DELIVER','<Case@invalid>','b','alpha@invalid','one@invalid',NULL,1),
(@t+200,'EX2','SEND','<Case@invalid>','c','alpha@invalid','two@invalid',NULL,1),
(@t+300,'EX2','FAIL','<Case@invalid>','d','alpha@invalid','two@invalid',NULL,1),
(@t+400,'EX1','DELIVER','<case@invalid>','e','beta@invalid','one@invalid',NULL,1),
(@t-172800000,'EX1','RECEIVE','<long@invalid>','f','alpha@invalid','one@invalid',NULL,1),
(@t+600,'EX2','DELIVER','<long@invalid>','g','alpha@invalid','one@invalid',NULL,1),
(@t-259200000,'EX1','RECEIVE','<outside@invalid>','h','alpha@invalid','one@invalid',NULL,1),
(@t+900,'EX1','RECEIVE','<scope@invalid>','j','alpha@invalid','one@invalid',NULL,1),
(@t+1000,'EX2','DELIVER','<scope@invalid>','k','beta@invalid','other@invalid',NULL,1);
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,mail_from,rcpts,transcript,auth_user,auth_source,auth_result)
VALUES(@t-100,'EX1','Receive','smtp-case','<Case@invalid>','Accepted','alpha@invalid','one@invalid',@transcript,'proved@invalid','SameSession','Success'),
(@t+500,'EX1','Receive','smtp-refused',NULL,'Rejected','alpha@invalid','one@invalid',@transcript,NULL,NULL,NULL),
(@t+700,'EX1','Receive','smtp-outside','<outside@invalid>','Accepted','alpha@invalid','one@invalid',@transcript,NULL,NULL,NULL);
INSERT INTO client_session(id,skey,day,start_ms,end_ms,user,protocol,front_ends,back_ends,requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,actions,statuses)
VALUES(1,'session','2026-10-14',@t+123,@t+999,'alpha@invalid','Mapi','EX1','EX2',1,1,0,0,@t+123,@t+123,0,0,2,2,0,0,@actions,@actions);
INSERT INTO session_step(session_id,time_ms,data) VALUES(1,@t+123,@steps);
"@ @{ t = $script:Epoch; transcript = [ExchangeLogReport.Packed]::Pack("AUTH <redacted>`n250 synthetic"); actions = [ExchangeLogReport.Packed]::Adaptive(('Bind=1;' * 60)); steps = "[[$($script:Epoch+123),$($script:Epoch+999),`"EX1`",null,`"Bind`",200,1,2,2,0,`"ok`",`"req-1`",`"FE`",false,1,`"find-request`",null]]" }
        Reconcile $Store
    }
    function Add-ClientRows($Store) {
        Add-Mail $Store
        Write-Sql $Store @"
UPDATE smtp_transaction SET role='FrontEnd',connector='Default',remote_ep='198.51.100.10:25001',helo='client.invalid',tls='TLS1.2',
 auth_mechanism='LOGIN',auth_result='Succeeded',auth_attempt_result='Succeeded',auth_source='Direct' WHERE id=1;
INSERT INTO smtp_transaction(id,time_ms,server,direction,role,connector,session_id,remote_ep,helo,mail_from,rcpts,rcpt_count,message_id,status,auth_user,auth_mechanism,auth_result,auth_attempt_result,auth_source,transcript) VALUES
(10,@t+2000,'EX1','Receive','FrontEnd','Default','a2','198.51.100.10:25099','client.invalid','forged-from@invalid','r@invalid',1,'<a2@invalid>','Rejected','proved@invalid','LOGIN','Succeeded','Failed','Direct',@transcript),
(11,@t+3000,'EX1','Receive','FrontEnd','Default','a3','198.51.100.10:25100','client.invalid','forged-from@invalid','r@invalid',2,'<a3@invalid>','Deferred','proved@invalid','LOGIN','Succeeded','Succeeded','Direct',NULL),
(12,@t+4000,'EX1','Receive','Mailbox','Default','role','198.51.100.10:25101','client.invalid','s@invalid','r@invalid',1,'<role@invalid>','Accepted','proved@invalid','LOGIN','Succeeded','Succeeded','Direct',NULL),
(13,@t+5000,'EX2','Receive','FrontEnd','Default','server','198.51.100.10:25102','client.invalid','s@invalid','r@invalid',1,'<server@invalid>','Accepted','proved@invalid','LOGIN','Succeeded','Succeeded','Direct',NULL),
(14,@t+6000,'EX1','Receive','FrontEnd','Other','connector','198.51.100.10:25103','client.invalid','s@invalid','r@invalid',1,'<connector@invalid>','Accepted','proved@invalid','LOGIN','Succeeded','Succeeded','Direct',NULL),
(15,@t+7000,'EX1','Receive','FrontEnd','Default','helo','198.51.100.10:25104','other.invalid','s@invalid','r@invalid',1,'<helo@invalid>','Accepted','proved@invalid','LOGIN','Succeeded','Succeeded','Direct',NULL),
(16,@t+8000,'EX1','Receive','FrontEnd','Default','account','198.51.100.10:25105','client.invalid','s@invalid','r@invalid',1,'<account@invalid>','Accepted','other@invalid','LOGIN','Succeeded','Succeeded','Direct',NULL),
(17,@t+9000,'EX1','Receive','FrontEnd','Default','unknown-a',NULL,'client.invalid','s@invalid','r@invalid',1,NULL,'Rejected',NULL,NULL,NULL,NULL,'Missing',NULL),
(18,@t+10000,'EX1','Receive','FrontEnd','Default','unknown-b',NULL,'client.invalid','s@invalid','r@invalid',1,NULL,'Rejected',NULL,NULL,NULL,NULL,'Missing',NULL),
(19,@t+11000,'EX1','Receive','FrontEnd','Default','v6-a','[2001:db8::1]:30001','client.invalid','s@invalid','r@invalid',1,'<v6a@invalid>','Accepted','proved@invalid','LOGIN','Succeeded','Succeeded','FrontEndProxy',NULL),
(20,@t+12000,'EX1','Receive','FrontEnd','Default','v6-b','[2001:DB8::1]:30002','client.invalid','s@invalid','r@invalid',1,'<v6b@invalid>','Accepted','proved@invalid','LOGIN','Succeeded','Succeeded','FrontEndProxy',NULL),
(21,@t+13000,'EX1','Receive','FrontEnd','Default','retired','198.51.100.30:25','client.invalid','s@invalid','r@invalid',1,'<retired@invalid>','Accepted','RETIRED-IDENTITY@invalid','LOGIN','Succeeded','Succeeded','Overflow',NULL);
"@ @{t=$script:Epoch;transcript=[ExchangeLogReport.Packed]::Pack("12:00:00.000 C: AUTH LOGIN`n12:00:00.001 S: 334 SYNTHETICCHALLENGE`n12:00:00.002 C: SYNTHETICPAYLOAD`n12:00:00.003 S: 235 2.7.0 Authentication successful")}
        Reconcile $Store
    }
    function Start-ServeTest([string]$Path, [int]$Timeout = 5) {
        $o = [ExchangeLogReport.ServeOptions]::new()
        $o.DatabasePath = $Path; $o.WebRoot = $script:Web; $o.Port = 0; $o.NoBrowser = $true
        $o.ReadyFile = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        $o.ReadyFileWithToken = $true; $o.RequestTimeoutSeconds = $Timeout
        $task = [ExchangeLogReport.ServeHost]::RunAsync($o)
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $o.ReadyFile)) {
            if ($task.IsCompleted) { $task.GetAwaiter().GetResult(); throw 'Host stopped before ready.' }
            if ($wait.Elapsed.TotalSeconds -gt 10) { throw 'Ready timeout.' }
            Start-Sleep -Milliseconds 20
        }
        $ready = Get-Content -LiteralPath $o.ReadyFile -Raw | ConvertFrom-Json
        $hostInfo = [pscustomobject]@{ Options = $o; Task = $task; Url = $ready.url.TrimEnd('/'); Port = $ready.port; Token = $ready.token }
        $script:Hosts.Add($hostInfo)
        return $hostInfo
    }
    function Request($HostInfo, [string]$Path, [hashtable]$Headers = @{}, [string]$Method = 'GET') {
        $h = @{ 'X-Portal-Token' = $HostInfo.Token }
        foreach ($key in $Headers.Keys) { $h[$key] = $Headers[$key] }
        Invoke-WebRequest -Uri ($HostInfo.Url + $Path) -Headers $h -Method $Method -SkipHttpErrorCheck -TimeoutSec 15
    }
    function Downgrade($Store, [int]$Version) {
        [ServeFixtures]::ConvertToLegacySyntheticFixture($Store,$Version)
    }
    $script:HttpStore = New-ServeStore 'http'
    Add-Mail $script:HttpStore
    $script:Http = Start-ServeTest $script:HttpStore.FilePath
}

AfterAll {
    foreach ($h in $script:Hosts) {
        if (-not $h.Task.IsCompleted) {
            try { [void](Request $h '/api/shutdown' @{} 'POST') } catch { }
            if (-not $h.Task.Wait(10000)) { throw 'Serve did not stop cleanly.' }
        }
        $h.Task.GetAwaiter().GetResult()
    }
    if ($script:HttpStore) { $script:HttpStore.Dispose() }
    if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
}

Describe 'Serve schema and incremental publication' {
    It 'matches the existing Detailed journey status semantics without replacing Usage HTML' {
        $q = [ExchangeLogReport.ReportRequest]::new()
        $q.StartMs=$script:Epoch-86400000; $q.EndMs=$script:Epoch+86400000
        $q.OutputFolder=Join-Path $script:Work 'legacy-status'; $q.Detailed=$true
        $q.WriteHtml=$false; $q.WriteCsv=$true; $q.MemoryBudgetMB=64; $q.Parallelism=1
        $result=[ExchangeLogReport.ReportBuilder]::Build($script:HttpStore,$q)
        $messages=@(Import-Csv -LiteralPath ($result.Files | Where-Object Dataset -EQ 'messages').Path -Delimiter ';')
        foreach($row in $messages | Where-Object { $_.'Message ID' }){
            $expected=$script:HttpStore.Query("SELECT v.text FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status WHERE r.kind=0 AND r.identity=@id COLLATE BINARY;",@{id=$row.'Message ID'}).Rows[0][0]
            $row.Status | Should -BeExactly $expected
        }
    }

    It 'reconciles the production collector transaction, partial final lines and subsequent incremental reads' {
        $s=New-ServeStore 'production'
        $folder=Join-Path $script:Work 'tracking'; [void][IO.Directory]::CreateDirectory($folder)
        $file=Join-Path $folder 'tracking.log'
        [IO.File]::WriteAllLines($file,@(
            '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address'
            '2026-10-14T17:46:40.000Z,RECEIVE,<production@invalid>,1,p1,sender@invalid,r@invalid'
            '2026-10-14T17:46:41.000Z,AGENTINFO,<production@invalid>,1,p2,sender@invalid,r@invalid'
            '2026-10-14T17:46:42.000Z,NOTIFYMAPI,<production@invalid>,1,p3,sender@invalid,r@invalid'
        ))
        try{
            [IO.File]::AppendAllText($file,'2026-10-14T17:46:43.000Z,DELIVER,<production@invalid>,1,p4,sender@invalid,r@invalid')
            $run=Collect-Tracking $s $folder
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            $s.Scalar('SELECT events_count FROM message_rollup;',$null) | Should -Be 3
            $s.Scalar('SELECT offset FROM source_file;',$null) | Should -BeLessThan (Get-Item -LiteralPath $file).Length
            [IO.File]::AppendAllText($file,"`r`n")
            [void](Collect-Tracking $s $folder)
            $s.Scalar('SELECT events_count FROM message_rollup;',$null) | Should -Be 4
            $s.Query('SELECT v.text FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status;',$null).Rows[0][0] | Should -BeExactly 'Delivered'
            $s.Scalar('SELECT offset FROM source_file;',$null) | Should -Be (Get-Item -LiteralPath $file).Length
            $run.Statistics | Should -Match 'message rollups'
            $run.Statistics | Should -Match 'message rollups \d+[.,]\d s \([1-9]\d* keys\)'
        }finally{$s.Dispose()}
    }

    It 'rolls back source offsets, evidence and the dirty queue if production rollup reconciliation fails' {
        $s=New-ServeStore 'production-rollback'
        $folder=Join-Path $script:Work 'tracking-fail'; [void][IO.Directory]::CreateDirectory($folder)
        [IO.File]::WriteAllLines((Join-Path $folder 'tracking.log'),@(
            '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address'
            '2026-10-14T17:46:40.000Z,DELIVER,<rollback@invalid>,1,p1,sender@invalid,r@invalid'
        ))
        try{
            $s.Exec("CREATE TRIGGER reject_rollup BEFORE INSERT ON message_rollup BEGIN SELECT RAISE(ABORT,'synthetic rollup failure'); END;")
            $run=Collect-Tracking $s $folder $false $false   # triggers kept on: this failure is injected by a trigger
            $run.Error | Should -Not -BeNullOrEmpty
            $s.Scalar('SELECT COUNT(*) FROM message_event;',$null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM source_file;',$null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            $s.Exec('DROP TRIGGER reject_rollup;')
            [void](Collect-Tracking $s $folder)
            $s.Scalar('SELECT COUNT(*) FROM message_rollup;',$null) | Should -Be 1
        }finally{$s.Dispose()}
    }

    It 'rolls back source offsets, evidence, dictionary and the dirty queue if reconciliation fails while the apply connection runs without triggers' {
        $s=New-ServeStore 'production-rollback-notriggers'
        $folder=Join-Path $script:Work 'tracking-fail-notriggers'; [void][IO.Directory]::CreateDirectory($folder)
        [IO.File]::WriteAllLines((Join-Path $folder 'tracking.log'),@(
            '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address'
            '2026-10-14T17:46:40.000Z,DELIVER,<rollback@invalid>,1,p1,sender@invalid,r@invalid'
        ))
        try{
            # No trigger can inject this failure here: the stable-ID sequence is exhausted, so the first rollup INSERT fails (SQLITE_FULL).
            $s.Exec("INSERT INTO sqlite_sequence(name,seq) VALUES('message_rollup',9223372036854775807);")
            $run=Collect-Tracking $s $folder $false
            $run.Error | Should -Not -BeNullOrEmpty
            $s.Scalar('SELECT COUNT(*) FROM message_event;',$null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM source_file;',$null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM source_fields;',$null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
            # The failed run gave the connection its triggers back: a raw insert on it still queues its identity.
            $s.Exec("INSERT INTO message_event(time_ms,server,event_id,message_id,log_id) VALUES(1,'EX1','RECEIVE','<queued@invalid>','q');")
            $s.Scalar("SELECT COUNT(*) FROM message_rollup_dirty WHERE identity='<queued@invalid>';",$null) | Should -Be 1
            $s.Exec("DELETE FROM message_rollup_dirty; DELETE FROM message_event; UPDATE sqlite_sequence SET seq=0 WHERE name='message_rollup';")
            [void](Collect-Tracking $s $folder)
            $s.Scalar('SELECT COUNT(*) FROM message_rollup;',$null) | Should -Be 1
            $s.Scalar('SELECT COUNT(*) FROM source_fields;',$null) | Should -Be 1
            $s.Query("SELECT d.text FROM source_file f JOIN source_fields d ON d.id=f.fields_id;",$null).Rows[0][0] | Should -BeExactly '#Fields: date-time,event-id,message-id,internal-message-id,log-id,sender-address,recipient-address'
            $s.Scalar('SELECT COUNT(*) FROM source_file WHERE fields IS NOT NULL;',$null) | Should -Be 0
        }finally{$s.Dispose()}
    }

    It 'migrates schema <Version> losslessly and reopens idempotently' -ForEach @(@{Version=6},@{Version=7},@{Version=8},@{Version=9},@{Version=10}) {
        $s = New-ServeStore "migration$Version"
        Add-Mail $s
        Downgrade $s $Version
        $rawBaseline=[ServeFixtures]::RawBaseline($s)
        $tables = @('source_file','smtp_auth_fragment','session_step','client_session')
        # source_file is read through its logical columns: schema 10 adds fields_id and moves the header text to source_fields (message_rollup: schema 11 stores codes, compared decoded).
        $select = @{ source_file = 'SELECT s.id,s.server,s.kind,s.path,s.offset,s.size,s.last_write_ms,COALESCE(d.text,s.fields),s.first_ms,s.last_ms,s.lines,s.kept,s.noise,s.updated_ms,s.file_key FROM source_file s LEFT JOIN source_fields d ON d.id=s.fields_id ORDER BY 1;' }
        $selectOld = @{ source_file = 'SELECT id,server,kind,path,offset,size,last_write_ms,fields,first_ms,last_ms,lines,kept,noise,updated_ms,file_key FROM source_file ORDER BY 1;' }
        $baseline = @{}
        foreach ($name in $tables) { $baseline[$name] = $s.Query($(if ($selectOld[$name]) { $selectOld[$name] } else { "SELECT * FROM $name ORDER BY 1;" }), $null).Rows | ConvertTo-Json -Depth 30 -Compress }
        $msg = $s.Query('SELECT id,time_ms,server,event_id,message_id,log_id,sender,recipients,subject FROM message_event ORDER BY id;', $null).Rows | ConvertTo-Json -Depth 30 -Compress
        $smtp = $s.Query('SELECT id,time_ms,server,direction,session_id,message_id,status,transcript,auth_user,auth_source FROM smtp_transaction ORDER BY id;', $null).Rows | ConvertTo-Json -Depth 30 -Compress
        $path = $s.FilePath; $s.Dispose()
        $s = [ExchangeLogReport.Store]::new($path,$false,'synthetic')
        try {
            $s.Scalar("SELECT CAST(value AS INTEGER) FROM metadata WHERE key='schema_version';",$null) | Should -Be 11
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='ix_smtp_latest';",$null) | Should -Be 0
            $s.Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN('ix_msg_hash','ix_smtp_hash','ix_session_latest');",$null) | Should -Be 0
            [ServeFixtures]::RawBaseline($s) | Should -BeExactly $rawBaseline
            foreach ($name in $tables) { ($s.Query($(if ($select[$name]) { $select[$name] } else { "SELECT * FROM $name ORDER BY 1;" }), $null).Rows | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $baseline[$name] }
            ($s.Query('SELECT id,time_ms,server,event_id,message_id,log_id,sender,recipients,subject FROM message_event ORDER BY id;',$null).Rows | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $msg
            ($s.Query('SELECT id,time_ms,server,direction,session_id,message_id,status,transcript,auth_user,auth_source FROM smtp_transaction ORDER BY id;',$null).Rows | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $smtp
            $rows = [ServeFixtures]::DecodedRollup($s)
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
        $s = [ExchangeLogReport.Store]::new($path,$false,'synthetic')
        try { ([ServeFixtures]::DecodedRollup($s)) | Should -BeExactly $rows }
        finally { $s.Dispose() }
    }

    It 'rolls back a failed schema-11 publication of a schema-7 database atomically' {
        $s = New-ServeStore 'rollback'; Add-Mail $s; Downgrade $s 7
        $s.Exec("CREATE TRIGGER fail_schema11 BEFORE UPDATE ON metadata WHEN NEW.key='schema_version' AND NEW.value='11' BEGIN SELECT RAISE(ABORT,'synthetic migration failure'); END;")
        $path = $s.FilePath; $s.Dispose()
        { [ExchangeLogReport.Store]::new($path,$false,'synthetic') } | Should -Throw '*synthetic migration failure*'
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False"); $db.Open()
        try {
            $c = $db.CreateCommand()
            $c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';"; $c.ExecuteScalar() | Should -BeExactly '7'
            $c.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'message_rollup%' OR name LIKE 'smtp_client%' OR name IN('ix_smtp_client','ix_smtp_unknown_peer','ux_smtp_client');"; $c.ExecuteScalar() | Should -Be 0
            $c.CommandText = "SELECT COUNT(*) FROM pragma_table_info('smtp_transaction') WHERE name='client_id';"; $c.ExecuteScalar() | Should -Be 0
        } finally { $db.Dispose() }
    }

    It 'keeps exact binary identities under a forced nonunique hash collision' {
        $s = New-ServeStore 'collision'
        try {
            [ServeFixtures]::ForceHashCollision($s)
            Add-Mail $s
            $s.Scalar("SELECT COUNT(*) FROM message_rollup WHERE kind=0 AND msg_hash=17;",$null) | Should -Be 5
            $h = Start-ServeTest $s.FilePath
            $rows = (Request $h "/api/messages?$script:Period").Content | ConvertFrom-Json
            $case = @($rows.rows | Where-Object { $_.cells[15] -ceq '<Case@invalid>' })
            $case.Count | Should -Be 1
            $case[0].cells[3] | Should -BeExactly 'Partially failed'
            $detail = (Request $h "/api/messages/$($case[0].id)?$script:Period").Content | ConvertFrom-Json
            $detail.cells[15] | Should -BeExactly '<Case@invalid>'
            @($detail.cells[16] | Where-Object { $_[3] -eq 'DELIVER' }).Count | Should -Be 1
        } finally { $s.Dispose() }
    }

    It 'publishes late SMTP, changed IDs, deletes and retention only with the surrounding transaction' {
        $s = New-ServeStore 'changes'; Add-Mail $s
        try {
            $id = $s.Scalar("SELECT id FROM message_rollup WHERE identity='<Case@invalid>';",$null)
            $s.Exec("INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status) VALUES(1792000005000,'EX1','Send','late','<Case@invalid>','Accepted');")
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -BeGreaterThan 0
            Reconcile $s
            $s.Scalar("SELECT smtp_count FROM message_rollup WHERE id=$id;",$null) | Should -Be 2
            $tx = $s.Begin()
            try {
                $c = [ServeFixtures]::Connection($s).CreateCommand(); $c.Transaction = $tx
                $c.CommandText = "DELETE FROM message_event WHERE message_id='<Case@invalid>';"; [void]$c.ExecuteNonQuery()
                $s.ReconcileMessageRollups($tx)
            } finally { $tx.Dispose() }
            $s.Scalar("SELECT events_count FROM message_rollup WHERE id=$id;",$null) | Should -Be 4
            $s.Exec("UPDATE message_event SET message_id='<new@invalid>' WHERE message_id='<case@invalid>';")
            Reconcile $s
            $s.Scalar("SELECT COUNT(*) FROM message_rollup WHERE identity='<case@invalid>';",$null) | Should -Be 0
            $s.Scalar("SELECT COUNT(*) FROM message_rollup WHERE identity='<new@invalid>';",$null) | Should -Be 1
            [void]$s.Purge($script:Epoch+86400000,'2026-10-17',$script:Epoch+86400000)
            $s.Scalar('SELECT COUNT(*) FROM message_rollup;',$null) | Should -Be 0
            $s.Scalar('SELECT COUNT(*) FROM message_rollup_dirty;',$null) | Should -Be 0
        } finally { $s.Dispose() }
    }

    It 'keeps refused and incomplete missing-Message-ID SMTP transactions as separate stable identities' {
        $s=New-ServeStore 'missing-id'; Add-Mail $s
        try {
            $s.Exec("INSERT INTO smtp_transaction(id,time_ms,server,direction,session_id,status) VALUES(41,1792000002000,'EX1','Receive','incomplete',NULL),(42,1792000003000,'EX1','Receive','accepted-no-id','Accepted');")
            Reconcile $s
            $s.Scalar("SELECT COUNT(*) FROM message_rollup WHERE kind=1;",$null) | Should -Be 2
            $h=Start-ServeTest $s.FilePath
            $id=$s.Scalar("SELECT id FROM message_rollup WHERE kind=1 AND identity='41';",$null)
            $r=Request $h "/api/messages/$($id)?$script:Period"
            $d=$r.Content | ConvertFrom-Json
            $d.cells[3] | Should -BeExactly 'Not completed (SMTP)'
            $d.cells[18].Count | Should -Be 0
            $d.cells[19].Count | Should -Be 1
            $r.Content | Should -Not -Match 'smtp-case|smtp-refused|accepted-no-id'
            $s.Exec('UPDATE smtp_transaction SET time_ms=time_ms+1 WHERE id=41;')
            Reconcile $s
            $s.Scalar("SELECT id FROM message_rollup WHERE kind=1 AND identity='41';",$null) | Should -Be $id
        } finally {$s.Dispose()}
    }
}

Describe 'Serve actual HttpListener endpoints' {
    It 'starts on the real loopback listener and reports the exact supported schema' {
        $r = Request $script:Http '/api/meta'
        $r.StatusCode | Should -Be 200
        $m = $r.Content | ConvertFrom-Json
        $m.schemaVersion | Should -Be 11
        $m.supportedSchemaVersion | Should -Be 11
        $m.version | Should -BeExactly '0.3.0'
        $m.readOnly | Should -BeTrue
        $m.mode | Should -BeExactly 'Serve'
        $r.Headers['Cache-Control'] | Should -Contain 'no-store'
        $r.Headers.ContainsKey('Access-Control-Allow-Origin') | Should -BeFalse
        (Get-Acl $script:Http.Options.ReadyFile).AreAccessRulesProtected | Should -BeTrue
    }

    It 'requires the token and rejects cross-origin, hostile authorities and traversal' {
        (Request $script:Http '/api/meta' @{'X-Portal-Token'='bad'}).StatusCode | Should -Be 401
        (Request $script:Http '/api/meta' @{Origin='https://invalid.example'}).StatusCode | Should -Be 403
        (Request $script:Http '/api/meta' @{'Sec-Fetch-Site'='same-site'}).StatusCode | Should -Be 403
        (Request $script:Http '/api/meta' @{Origin=$script:Http.Url;'Sec-Fetch-Site'='same-origin'}).StatusCode | Should -Be 200
        [ServeFixtures]::RawGet($script:Http.Port,'/api/meta',"localhost:$($script:Http.Port)",$script:Http.Token) | Should -Match 'HTTP/1.1 (400|403)'
        [ServeFixtures]::RawGet($script:Http.Port,'/%2e%2e/config/secret.psd1',"127.0.0.1:$($script:Http.Port)",$script:Http.Token) | Should -Match 'HTTP/1.1 (400|403)'
        [ServeFixtures]::RawGet($script:Http.Port,'/%252e%252e/secret',"127.0.0.1:$($script:Http.Port)",$script:Http.Token) | Should -Match 'HTTP/1.1 400'
    }

    It 'serves only known SPA routes and allowlisted static assets with the theme hash' {
        (Request $script:Http '/messages').StatusCode | Should -Be 200
        (Request $script:Http '/main.js').Headers['Content-Type'][0] | Should -Match 'javascript'
        (Request $script:Http '/unrecognized').StatusCode | Should -Be 404
        (Request $script:Http '/api/not-found').StatusCode | Should -Be 404
        (Request $script:Http '/').Headers['Content-Security-Policy'][0] | Should -Match "sha256-"
    }

    It 'serves copyable SPA filter URLs but never arbitrary asset parameters or query-string tokens' {
        foreach($route in '/messages','/messages/1','/sessions','/smtp','/smtp/clients','/smtp/transactions','/smtp/clients/1/transactions','/overview'){
            (Request $script:Http "$route`?$script:Period&user=under_%25%5Cliteral&server=ex1&page=2&size=100").StatusCode | Should -Be 200
        }
        foreach($path in '/main.js?size=1','/index.html?size=1','/unrecognized?size=1','/messages?token=secret','/messages?unknown=x',
            '/messages?size=501','/messages?page=500&size=100','/messages?size=1&size=2','/messages?from=2026-10-14T00:00:00','/messages?user=%00'){
            (Request $script:Http $path).StatusCode | Should -Be 400
        }
    }

    It 'returns hourly UTC bins per server with exact binary message counts and explicit retained-access caveats' {
        $s=New-ServeStore 'hourly'
        [ServeFixtures]::ForceHashCollision($s)
        $hour=$script:Epoch-($script:Epoch%3600000)
        try {
            Write-Sql $s @"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES
(@h+1000,'EX1','RECEIVE','<Case@invalid>','h1','alpha@invalid','r@invalid'),
(@h+2000,'EX1','DELIVER','<Case@invalid>','h2','alpha@invalid','r@invalid'),
(@h+3000,'ex1','RECEIVE','<case@invalid>','h3','beta@invalid','r@invalid'),
(@h+3600500,'EX2','DELIVER','<Case@invalid>','h4','beta@invalid','r@invalid');
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,mail_from,rcpts) VALUES
(@h+4000,'EX1','Receive','h1','<Case@invalid>','Accepted','alpha@invalid','r@invalid'),
(@h+5000,'EX1','Receive','h2',NULL,'Rejected','alpha@invalid','r@invalid'),
(@h+6000,'EX2','Receive','h3',NULL,'Deferred','beta@invalid','r@invalid'),
(@h+3600100,'EX2','Receive','h4','<incomplete@invalid>',NULL,'alpha@invalid','r@invalid');
INSERT INTO access_event(time_ms,server,source,user,outcome,request_id) VALUES
(@h+8000,'EX1','Synthetic','alpha@invalid','Failed','h1'),(@h+9000,'EX1','Synthetic','beta@invalid','OK','h2');
"@ @{h=$hour}
            Reconcile $s
            $h=Start-ServeTest $s.FilePath
            $period='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($hour).ToString('O'))+
                '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($hour+7200000).ToString('O'))
            $p=(Request $h "/api/overview?$period").Content|ConvertFrom-Json
            $p.columns[0].kind | Should -BeExactly 'time'
            $p.rows.Count | Should -Be 3
            $bin=@($p.rows|Where-Object {$_.cells[1] -ieq 'EX1'})[0]
            ([DateTimeOffset]$bin.cells[0]).ToUnixTimeMilliseconds() | Should -Be $hour
            ($bin.cells[2..9] -join ',') | Should -BeExactly '3,2,2,1,1,0,0,2'
            $p.basis | Should -Match 'Daily access_usage cannot establish hourly'
            $scope=(Request $h "/api/overview?$period&server=ex1&user=alpha").Content|ConvertFrom-Json
            $scope.rows.Count | Should -Be 1
            ($scope.rows[0].cells[2..9] -join ',') | Should -BeExactly '2,1,2,1,1,0,0,1'
            $counts=(Request $h "/api/overview/counts?$period").Content|ConvertFrom-Json
            $counts.columns[0].name | Should -BeExactly 'Source'
        } finally {$s.Dispose()}
    }

    It 'preserves partial exclusive UTC hours and ordering across the Unix epoch at <Hour>' -ForEach @(
        @{Hour=1791997200000L},@{Hour=-3600000L},@{Hour=0L}
    ) {
        $s=New-ServeStore ('partial-hour-'+$Hour)
        try {
            Write-Sql $s @"
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES
(@h-1,'EX1','RECEIVE','<outside@invalid>','p0','alpha@invalid','r@invalid'),
(@h+1000,'EX1','RECEIVE','<Case@invalid>','p1','alpha@invalid','r@invalid'),
(@h+2000,'EX1','DELIVER','<Case@invalid>','p2','alpha@invalid','r@invalid'),
(@h+3599999,'ex1','SEND','<case@invalid>','p3','alpha@invalid','r@invalid'),
(@h+3600000,'EX1','DELIVER','<Case@invalid>','p4','alpha@invalid','r@invalid'),
(@h+3602000,'EX1','DELIVER','<excluded@invalid>','p5','alpha@invalid','r@invalid');
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,status,mail_from,rcpts) VALUES
(@h+1500,'EX1','Receive','p1','Accepted','alpha@invalid','r@invalid'),
(@h+3599999,'ex1','Receive','p2','Rejected','alpha@invalid','r@invalid'),
(@h+3600000,'EX1','Receive','p3',NULL,'alpha@invalid','r@invalid'),
(@h+3602000,'EX1','Receive','p4','Deferred','alpha@invalid','r@invalid');
INSERT INTO access_event(time_ms,server,source,user,mailbox,outcome,request_id) VALUES
(@h+1500,'EX1','Synthetic','other@invalid','alpha@invalid','OK','p1'),
(@h+3599999,'ex1','Synthetic','alpha@invalid',NULL,'Failed','p2'),
(@h+3600000,'EX1','Synthetic','alpha@invalid',NULL,'OK','p3'),
(@h+3601000,'EX2','Synthetic','alpha@invalid',NULL,'OK','p4'),
(@h+3602000,'EX1','Synthetic','alpha@invalid',NULL,'OK','p5');
"@ @{h=$Hour}
            Reconcile $s
            $h=Start-ServeTest $s.FilePath
            $period='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($Hour+1500).ToString('O'))+
                '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($Hour+3602000).ToString('O'))
            $p=(Request $h "/api/overview?$period").Content|ConvertFrom-Json
            $p.rows.Count | Should -Be 3
            ($p.rows.id -join ',') | Should -BeExactly '1,2,3'
            ([DateTimeOffset]$p.rows[0].cells[0]).ToUnixTimeMilliseconds() | Should -Be ($Hour+3600000)
            $p.rows[0].cells[1] | Should -BeExactly 'EX1'
            ($p.rows[0].cells[2..9] -join ',') | Should -BeExactly '1,1,1,0,0,0,1,1'
            $p.rows[1].cells[1] | Should -BeExactly 'EX2'
            ($p.rows[1].cells[2..9] -join ',') | Should -BeExactly '0,0,0,0,0,0,0,1'
            ([DateTimeOffset]$p.rows[2].cells[0]).ToUnixTimeMilliseconds() | Should -Be $Hour
            ($p.rows[2].cells[2..9] -join ',') | Should -BeExactly '2,2,2,1,1,0,0,2'
            $scoped=(Request $h "/api/overview?$period&server=ex1&user=alpha").Content|ConvertFrom-Json
            $scoped.rows.Count | Should -Be 2
            ($scoped.rows[0].cells[2..9] -join ',') | Should -BeExactly '1,1,1,0,0,0,1,1'
            ($scoped.rows[1].cells[2..9] -join ',') | Should -BeExactly '2,2,2,1,1,0,0,2'
            $empty=(Request $h "/api/overview?$period&server=absent").Content|ConvertFrom-Json
            $empty.rows.Count | Should -Be 0
            $wide='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($Hour-32L*86400000).ToString('O'))+
                '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($Hour+3602000).ToString('O'))
            $sparse=(Request $h "/api/overview?$wide&server=EX2").Content|ConvertFrom-Json
            $sparse.rows.Count | Should -Be 1
            ($sparse.rows[0].cells[2..9] -join ',') | Should -BeExactly '0,0,0,0,0,0,0,1'
        } finally {$s.Dispose()}
    }

    It 'rejects more than 10000 bins without partial success for a <Days>-day selection' -ForEach @(
        @{Days=1},@{Days=32}
    ) {
        $s=New-ServeStore "overview-limit-$Days"
        try {
            Write-Sql $s @"
WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<10001)
INSERT INTO access_event(time_ms,server,source,user,outcome,request_id)
SELECT @t,printf('EX%05d',i),'Synthetic','alpha@invalid','OK',printf('limit-%d',i) FROM n;
"@ @{t=$script:Epoch}
            $h=Start-ServeTest $s.FilePath
            $period='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch).ToString('O'))+
                '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch+$Days*86400000L).ToString('O'))
            $response=Request $h "/api/overview?$period"
            $response.StatusCode | Should -Be 422
            $response.Content | Should -Match 'OverviewTooLarge'
            $selected=(Request $h "/api/overview?$period&server=EX00001").Content|ConvertFrom-Json
            $selected.rows.Count | Should -Be 1
            $selected.rows[0].cells[9] | Should -Be 1
        } finally {$s.Dispose()}
    }

    It 'groups SMTP peers across ephemeral ports without merging accounts, servers, roles, connectors or unknown endpoints' {
        $s=New-ServeStore 'clients';Add-ClientRows $s
        try {
            $h=Start-ServeTest $s.FilePath
            $response=Request $h "/api/smtp/clients?$script:Period"
            $p=$response.Content|ConvertFrom-Json
            $client=@($p.rows|Where-Object {$_.id -eq 1})[0]
            $client.cells[6] | Should -BeExactly '198.51.100.10'
            $client.cells[8] | Should -BeExactly 'proved@invalid'
            ($client.cells[9..13] -join ',') | Should -BeExactly '3,1,1,1,0'
            $client.cells[19] | Should -Contain 'Direct server log'
            @($p.rows|Where-Object {$_.id -in 12,13,14,15,16}).Count | Should -Be 5
            @($p.rows|Where-Object {$_.id -in 17,18}).Count | Should -Be 2
            $v6=@($p.rows|Where-Object {$_.cells[6] -eq '2001:db8::1'})[0]
            $v6.cells[9] | Should -Be 2
            $v6.cells[19] | Should -Contain 'Front end proxy'
            $retired=@($p.rows|Where-Object {$_.id -eq 21})[0]
            $retired.cells[8] | Should -BeExactly 'Not available'
            $retired.cells[19] | Should -Contain 'Missing'
            $response.Content | Should -Not -Match 'SYNTHETICCHALLENGE|SYNTHETICPAYLOAD|RETIRED-IDENTITY|forged-from'
            @($p.columns|Where-Object kind -EQ 'steps').Count | Should -Be 0
            $small=(Request $h "/api/smtp/clients?$script:Period&size=2").Content|ConvertFrom-Json
            $small.rows.Count | Should -Be 2
            $small.hasMore | Should -BeTrue
            $small.total | Should -BeNullOrEmpty
        } finally {$s.Dispose()}
    }

    It 'drills from a scoped SMTP client to paginated transactions and redacts only selected transaction detail' {
        $s=New-ServeStore 'client-details';Add-ClientRows $s
        try {
            $h=Start-ServeTest $s.FilePath
            $detail=(Request $h "/api/smtp/clients/1?$script:Period&server=EX1&user=proved").Content|ConvertFrom-Json
            $detail.title | Should -BeExactly 'SMTP client'
            $detail.cells[9] | Should -Be 3
            $detail.cells[-1] | Should -Match '^/api/smtp/clients/1/transactions\?'
            $page=(Request $h "/api/smtp/clients/1/transactions?$script:Period&server=EX1&user=proved&size=1").Content|ConvertFrom-Json
            $page.rows[0].id | Should -Be 11
            $page.hasMore | Should -BeTrue
            $next=(Request $h "/api/smtp/clients/1/transactions?$script:Period&server=EX1&user=proved&size=1&page=2").Content|ConvertFrom-Json
            $next.rows[0].id | Should -Be 10
            $rejected=(Request $h "/api/smtp/clients?$script:Period&server=EX1&user=proved&status=Rejected").Content|ConvertFrom-Json
            $rejected.rows.Count | Should -Be 1
            $rejected.rows[0].id | Should -Be 10
            $rejected.rows[0].cells[9] | Should -Be 1
            $scoped=(Request $h "/api/smtp/clients/10?$script:Period&server=EX1&user=proved&status=Rejected").Content|ConvertFrom-Json
            $scoped.cells[9] | Should -Be 1
            $scoped.cells[-1] | Should -Match 'status=Rejected'
            $single=Request $h "/api/smtp/transactions/10?$script:Period"
            $single.Content | Should -Match 'SMTP conversation|AUTH.*redacted'
            $single.Content | Should -Not -Match 'SYNTHETICCHALLENGE|SYNTHETICPAYLOAD'
            (Request $h "/api/smtp/clients/1?$script:Period&server=EX2").StatusCode | Should -Be 404
            (Request $h "/api/smtp/clients/1/transactions?$script:Period&user=other").StatusCode | Should -Be 404
            $unknown=(Request $h "/api/smtp/clients/17/transactions?$script:Period").Content|ConvertFrom-Json
            $unknown.rows.Count | Should -Be 1
            $unknown.rows[0].id | Should -Be 17
            $all=(Request $h "/api/smtp/transactions?$script:Period").Content|ConvertFrom-Json
            $all.rows.Count | Should -Be 15
            $csv=(Request $h "/api/export.csv?view=smtp&$script:Period").Content
            $csv | Should -Match 'Remote IP'
            $csv | Should -Not -Match 'SYNTHETICPAYLOAD'
            $txcsv=(Request $h "/api/export.csv?view=smtp-transactions&$script:Period").Content
            $txcsv | Should -Match 'Mail from'
        } finally {$s.Dispose()}
    }

    It 'rolls back a failed schema10 publication of a schema-8 database atomically (indexes, triggers and version)' {
        $s = New-ServeStore 'rollback9'; Add-Mail $s; Downgrade $s 8
        $s.Exec("CREATE TRIGGER fail_schema10 BEFORE UPDATE ON metadata WHEN NEW.key='schema_version' AND NEW.value='10' BEGIN SELECT RAISE(ABORT,'synthetic migration failure'); END;")
        $path = $s.FilePath; $s.Dispose()
        { [ExchangeLogReport.Store]::new($path,$false,'synthetic') } | Should -Throw '*synthetic migration failure*'
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Mode=ReadOnly;Pooling=False"); $db.Open()
        try {
            $c = $db.CreateCommand()
            $c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';"; $c.ExecuteScalar() | Should -BeExactly '8'
            $c.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE name IN('ix_msg_hash','ix_smtp_hash','ix_session_latest');"; $c.ExecuteScalar() | Should -Be 3
            $c.CommandText = "SELECT sql FROM sqlite_master WHERE name='ix_smtp_latest';"; $c.ExecuteScalar() | Should -BeExactly 'CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms DESC,id DESC)'
            $c.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE name='tr_smtp_transaction_rollup_update' AND sql LIKE '%auth_user%';"; $c.ExecuteScalar() | Should -Be 1
        } finally { $db.Dispose() }
    }

    It 'reads grouped SMTP clients from the hourly buckets and touches source rows only at the partial ends, and preserves exclusive bounds' {
        $s=New-ServeStore 'client-scan';Add-ClientRows $s
        try {
            $from=$script:Epoch-1000000L; $to=$script:Epoch+86400000L
            $full=[ExchangeLogReport.ServeDiagnostics]::ExplainSmtpClients($s.FilePath,$from,$to,$null,$null)|ConvertFrom-Json
            $empty=[ExchangeLogReport.ServeDiagnostics]::ExplainSmtpClients($s.FilePath,$from,$to,'','')|ConvertFrom-Json
            ($full -join "`n") | Should -BeExactly ($empty -join "`n")
            # A page is discovered hour by hour from the end in the covering bucket index, then only its candidates are aggregated through their primary keys.
            ($full -join "`n") | Should -Match '\[discover hour\] SEARCH h USING COVERING INDEX ix_smtp_client_hour \(hour_ms=\?\)'
            ($full -join "`n") | Should -Match '\[discover unknown\] SEARCH e USING INDEX ix_smtp_unknown_peer'
            ($full -join "`n") | Should -Match '\[aggregate hours\] SEARCH h USING PRIMARY KEY \(client_id=\? AND hour_ms>\? AND hour_ms<\?\)'
            ($full -join "`n") | Should -Match '\[aggregate edges\] (MULTI-INDEX OR \| INDEX 1 \| )?SEARCH e USING INDEX ix_smtp_client \(client_id=\? AND time_ms>\? AND time_ms<\?\)'
            ($full -join "`n") | Should -Not -Match 'ix_smtp_latest'
            ($full -join "`n") | Should -Not -Match 'SCAN e'
            $partial=[ExchangeLogReport.ServeDiagnostics]::ExplainSmtpClients($s.FilePath,$from,$script:Epoch+2000,$null,$null)|ConvertFrom-Json
            ($partial -join "`n") | Should -Match 'SEARCH e USING INDEX'
            $scoped=[ExchangeLogReport.ServeDiagnostics]::ExplainSmtpClients($s.FilePath,$from,$to,'EX1',$null)|ConvertFrom-Json
            ($scoped -join "`n") | Should -Match '\[discover hour\] SEARCH h USING COVERING INDEX ix_smtp_client_hour \(hour_ms=\?\) \| SEARCH c USING INTEGER PRIMARY KEY \(rowid=\?\)'
            # A user filter cannot use the buckets (substring LIKE): matching rows newest first, then the older rows of the candidates through ix_smtp_client.
            $user=[ExchangeLogReport.ServeDiagnostics]::ExplainSmtpClients($s.FilePath,$from,$to,$null,'proved')|ConvertFrom-Json
            ($user -join "`n") | Should -Match '\[newest\] SEARCH e USING INDEX ix_smtp_flow'
            # ix_smtp_flow has (server,direction,status) between time_ms and the rowid: only the id inside one millisecond is sorted (streaming, no full sort).
            ($user -join "`n") | Should -Not -Match '\[newest\][^\[]*USE TEMP B-TREE FOR ORDER BY'
            ($user -join "`n") | Should -Match '\[complete\] SEARCH e USING INDEX ix_smtp_client \(client_id=\? AND time_ms>\? AND time_ms<\?\)'
            $overview=[ExchangeLogReport.ServeDiagnostics]::ExplainOverview($s.FilePath,$from,$to,$null,$null)|ConvertFrom-Json
            ($overview -join "`n") | Should -Match 'COVERING INDEX ix_msg_flow'
            ($overview -join "`n") | Should -Match 'COVERING INDEX ix_smtp_flow'
            $h=Start-ServeTest $s.FilePath
            $period='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($from).ToString('O'))+
                '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($to).ToString('O'))
            $all=(Request $h "/api/smtp/clients?$period").Content|ConvertFrom-Json
            ($all.rows | ForEach-Object {$_.cells[9]} | Measure-Object -Sum).Sum | Should -Be 15
            $end=[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch+2000).ToString('O'))
            $partialPeriod=$period -replace '&to=.*$',"&to=$end"
            $selected=(Request $h "/api/smtp/clients?$partialPeriod").Content|ConvertFrom-Json
            ($selected.rows | ForEach-Object {$_.cells[9]} | Measure-Object -Sum).Sum | Should -Be 3
            @($selected.rows|Where-Object id -EQ 1)[0].cells[9] | Should -Be 1
        } finally {$s.Dispose()}
    }

    It 'interrupts expensive aggregate <View> queries instead of retrying or returning partial data' -ForEach @(@{View='clients'},@{View='overview'}) {
        $s=New-ServeStore "aggregate-$View"
        if($View -eq 'clients'){Add-ClientRows $s}else{Add-Mail $s}
        try {
            # Schema 11 reads the client list from smtp_client_hour / smtp_client_value / smtp_transaction: the value dictionary is read first, whatever the period.
            $table=if($View -eq 'clients'){'smtp_client_value'}else{'access_event'}
            if($View -eq 'overview'){
                $s.Exec("INSERT INTO access_event(time_ms,server,source,user,outcome,request_id) VALUES($script:Epoch,'EX1','Synthetic','s@invalid','Failed','aggregate-deadline');")
            }
            $s.Exec("ALTER TABLE $table RENAME TO ${table}_base; CREATE VIEW $table AS SELECT e.* FROM ${table}_base e CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<100000000) SELECT SUM(i) FROM n);")
            $h=Start-ServeTest $s.FilePath 1
            $path=if($View -eq 'clients'){"/api/smtp/clients?$script:Period"}else{"/api/overview?$script:Period"}
            $clock=[Diagnostics.Stopwatch]::StartNew()
            (Request $h $path).StatusCode | Should -Be 504
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
            (Request $h '/api/meta').StatusCode | Should -Be 200
        } finally {$s.Dispose()}
    }

    It 'rejects unknown/repeated parameters, oversized pages and offsetless timestamps' {
        foreach ($q in 'size=501','page=0','page=500&size=100','unknown=x','size=1&size=2','from=2026-10-14T00:00:00') {
            (Request $script:Http "/api/messages?$q").StatusCode | Should -Be 400
        }
    }

    It 'returns bounded summary rows only and selects real membership for long journeys and SMTP-only dates' {
        $r = Request $script:Http "/api/messages?$script:Period&size=2"
        $p = $r.Content | ConvertFrom-Json
        $p.rows.Count | Should -Be 2
        $p.hasMore | Should -BeTrue
        $p.total | Should -BeNullOrEmpty
        @($p.columns | Where-Object kind -EQ 'steps').Count | Should -Be 0
        $r.Content | Should -Not -Match 'redacted|req-1|find-request'
        $all = (Request $script:Http "/api/messages?$script:Period").Content | ConvertFrom-Json
        @($all.rows | Where-Object { $_.cells[15] -ceq '<long@invalid>' }).Count | Should -Be 1
        @($all.rows | Where-Object { $_.cells[15] -ceq '<outside@invalid>' }).Count | Should -Be 1
        @($all.rows | Where-Object { $_.cells[16] -eq 'smtp' }).Count | Should -Be 1
        ([datetimeoffset]$all.rows[0].cells[0]).ToUnixTimeMilliseconds() | Should -BeGreaterThan 0
    }

    It 'uses literal escaped user substring and same-row server/user membership, including detail authorization' {
        $p = (Request $script:Http "/api/messages?$script:Period&server=ex1&user=beta").Content | ConvertFrom-Json
        @($p.rows | Where-Object { $_.cells[15] -ceq '<scope@invalid>' }).Count | Should -Be 0
        $id = $script:HttpStore.Scalar("SELECT id FROM message_rollup WHERE identity='<scope@invalid>';",$null)
        (Request $script:Http "/api/messages/$($id)?$script:Period&server=EX1&user=beta").StatusCode | Should -Be 404
        ((Request $script:Http "/api/messages?$script:Period&user=%25").Content | ConvertFrom-Json).rows.Count | Should -Be 0
    }

    It 'loads the exact selected route, redacted packed SMTP transcript and authentication facts only on detail' {
        $id = $script:HttpStore.Scalar("SELECT id FROM message_rollup WHERE identity='<Case@invalid>';",$null)
        $r = Request $script:Http "/api/messages/$($id)?$script:Period"
        $d = $r.Content | ConvertFrom-Json
        $d.cells[3] | Should -BeExactly 'Partially failed'
        $d.cells[16].Count | Should -Be 5
        $d.cells[18].Count | Should -Be 4
        $d.cells[19].Count | Should -Be 1
        $r.Content | Should -Match 'internal_id|auth_evidence_id'
        $r.Content | Should -Match 'proved@invalid|AUTH.*redacted'
        $r.Content | Should -Not -Match 'smtp-refused|smtp-outside'
        $smtp = (Request $script:Http "/api/smtp/clients?$script:Period").Content | ConvertFrom-Json
        @($smtp.columns | Where-Object name -EQ 'Transcript').Count | Should -Be 0
    }

    It 'returns a full selected client timeline with request IDs, raw log references and UTC milliseconds' {
        $d = (Request $script:Http "/api/sessions/1?$script:Period").Content | ConvertFrom-Json
        $d.cells[25].Count | Should -Be 1
        $d.cells[25][0][10] | Should -BeExactly 'req-1'
        $d.cells[25][0][11][0][3] | Should -BeExactly 'synthetic.log'
        ([DateTimeOffset]$d.cells[25][0][0]).ToUnixTimeMilliseconds() | Should -Be ($script:Epoch+123)
        $d.cells[26] | Should -BeExactly ('Bind=1;' * 60)
        $d.cells[27] | Should -BeExactly ('Bind=1;' * 60)
        ((Request $script:Http "/api/sessions?$script:Period").Content | ConvertFrom-Json).rows.Count | Should -Be 1
    }

    It 're-redacts legacy packed SMTP AUTH challenges and payloads on both selected detail routes' {
        $s=New-ServeStore 'legacy-secrets'; Add-Mail $s
        try {
            $raw="12:00:00.000 C: AUTH LOGIN`n12:00:00.001 S: 334 SYNTHETICCHALLENGE`n12:00:00.002 C: SYNTHETICPAYLOAD`n12:00:00.003 S: 235 2.7.0 Authentication successful"
            Write-Sql $s 'UPDATE smtp_transaction SET transcript=@v WHERE id=1;' @{v=[ExchangeLogReport.Packed]::Pack($raw)}
            $h=Start-ServeTest $s.FilePath
            $id=$s.Scalar("SELECT id FROM message_rollup WHERE identity='<Case@invalid>';",$null)
            foreach($route in "/api/messages/$($id)?$script:Period","/api/smtp/1?$script:Period"){
                $r=Request $h $route
                $r.StatusCode | Should -Be 200
                $r.Content | Should -Not -Match 'SYNTHETICCHALLENGE|SYNTHETICPAYLOAD'
            }
            $s.Query('SELECT transcript FROM smtp_transaction WHERE id=1;',$null).Rows[0][0] | Should -BeExactly $raw
        } finally {$s.Dispose()}
    }

    It 'exports every matching row, not a page, as BOM semicolon CSV with formula neutralization' {
        $r = Request $script:Http "/api/export.csv?view=messages&$script:Period"
        $r.StatusCode | Should -Be 200
        $r.Content | Should -Match "'=SUM"
        ($r.RawContentStream.ToArray()[0..2] -join ',') | Should -BeExactly '239,187,191'
        @($r.Content -split "`r?`n" | Where-Object Length -GT 0).Count | Should -Be 7
        $r.Headers.ContainsKey('X-Export-Completion') | Should -BeTrue
        (Request $script:Http "/api/export.csv?view=messages&$script:Period&size=1").StatusCode | Should -Be 400
    }

    It 'does not migrate an older schema, write reports, or change source database bytes' {
        $s = New-ServeStore 'old'; Add-Mail $s; Downgrade $s 7
        $path = $s.FilePath; $s.Dispose()
        $before = (Get-FileHash -LiteralPath $path).Hash
        $files = @(Get-ChildItem -LiteralPath $script:Work -Recurse -File | Select-Object -ExpandProperty FullName)
        $h = Start-ServeTest $path
        ((Request $h '/api/meta').Content | ConvertFrom-Json).requiresMigration | Should -BeTrue
        (Request $h "/api/messages?$script:Period").StatusCode | Should -Be 422
        (Get-FileHash -LiteralPath $path).Hash | Should -BeExactly $before
        @(Get-ChildItem -LiteralPath $script:Work -Recurse -File | Where-Object { $_.FullName -notin $files -and $_.Extension -in '.html','.csv','.log' }).Count | Should -Be 0
        $missing = Start-ServeTest (Join-Path $script:Work 'missing.sqlite')
        ((Request $missing '/api/meta').Content | ConvertFrom-Json).schemaVersion | Should -Be 0
        (Request $missing "/api/sessions?$script:Period").StatusCode | Should -Be 422
        Test-Path -LiteralPath $missing.Options.DatabasePath | Should -BeFalse
    }

    It 'fails explicitly rather than serving stale data from a committed dirty queue' {
        $s = New-ServeStore 'dirty'; Add-Mail $s
        try {
            $s.Exec("UPDATE message_event SET event_id='FAIL' WHERE id=2;")
            $h = Start-ServeTest $s.FilePath
            $r = Request $h "/api/messages?$script:Period"
            $r.StatusCode | Should -Be 503
            $r.Content | Should -Match 'RollupPending'
            Reconcile $s
            (Request $h "/api/messages?$script:Period").StatusCode | Should -Be 200
        } finally { $s.Dispose() }
    }

    It 'preserves scoped membership, order and paging when rare filters exceed the bounded latest-row probe' {
        $s=New-ServeStore 'selectivity'; Add-Mail $s
        try {
            [ServeFixtures]::Populate($s,$script:Epoch+10000,600)
            Write-Sql $s "INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients) VALUES(@t,'EX1','DELIVER','<literal@invalid>','literal',@sender,'r@invalid');" @{
                t=$script:Epoch+500; sender='under_%\literal@invalid'
            }
            Reconcile $s
            $h=Start-ServeTest $s.FilePath
            $rare=(Request $h "/api/messages?$script:Period&user=alpha%40invalid&server=ex1").Content | ConvertFrom-Json
            $rare.rows.Count | Should -Be 4
            $rare.hasMore | Should -BeFalse
            @($rare.rows | Where-Object {$_.cells[15] -ceq '<long@invalid>'}).Count | Should -Be 0
            $beta=(Request $h "/api/messages?$script:Period&user=beta%40invalid&server=EX1").Content | ConvertFrom-Json
            $beta.rows.Count | Should -Be 1
            $beta.rows[0].cells[15] | Should -BeExactly '<case@invalid>'
            $literal=[Uri]::EscapeDataString('under_%\literal')
            $escaped=(Request $h "/api/messages?$script:Period&user=$literal").Content | ConvertFrom-Json
            $escaped.rows.Count | Should -Be 1
            $escaped.rows[0].cells[15] | Should -BeExactly '<literal@invalid>'
            $fullFrom=$script:Epoch-7*86400000L; $fullTo=$script:Epoch+86400000L
            $fullPeriod='from='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($fullFrom).ToString('O'))+
                '&to='+[Uri]::EscapeDataString([DateTimeOffset]::FromUnixTimeMilliseconds($fullTo).ToString('O'))
            $whole=(Request $h "/api/messages?$fullPeriod&user=$literal").Content|ConvertFrom-Json
            $whole.rows.Count | Should -Be 1
            $whole.rows[0].cells[15] | Should -BeExactly '<literal@invalid>'
            $wholePlan=[ExchangeLogReport.ServeDiagnostics]::ExplainMessageList($s.FilePath,$fullFrom,$fullTo,$null,'under_%\literal',$null)|ConvertFrom-Json
            $wholePlan -join "`n" | Should -Match 'SCAN e'
            $one=(Request $h "/api/messages?$script:Period&user=%40&page=1&size=100").Content | ConvertFrom-Json
            $two=(Request $h "/api/messages?$script:Period&user=%40&page=2&size=100").Content | ConvertFrom-Json
            $one.hasMore | Should -BeTrue; $two.hasMore | Should -BeTrue
            @($one.rows.id | Where-Object {$_ -in $two.rows.id}).Count | Should -Be 0
            $tail=(Request $h "/api/messages?$script:Period&user=%40&page=2&size=500").Content | ConvertFrom-Json
            $tail.rows.Count | Should -Be 107
            $tail.hasMore | Should -BeFalse
            $csv=(Request $h "/api/export.csv?view=messages&$script:Period&user=beta%40invalid&server=EX1").Content
            $export=@(($csv -replace '^\uFEFF','') | ConvertFrom-Csv -Delimiter ';')
            $export.Count | Should -Be 1
            $export[0].'Message ID' | Should -BeExactly '<case@invalid>'
            $plan=[ExchangeLogReport.ServeDiagnostics]::ExplainMessageList($s.FilePath,$script:Epoch-86400000,$script:Epoch+86400000,'EX1','beta@invalid',$null) | ConvertFrom-Json
            $plan -join "`n" | Should -Match 'Bounded latest-candidate probe: 256'
            $plan -join "`n" | Should -Match 'LIST SUBQUERY'
        } finally {$s.Dispose()}
    }

    It 'does not merge binary identities in the noncorrelated membership set even when every hash collides' {
        $s=New-ServeStore 'set-collision'
        try {
            [ServeFixtures]::ForceHashCollision($s)
            Add-Mail $s; [ServeFixtures]::Populate($s,$script:Epoch+10000,600)
            $h=Start-ServeTest $s.FilePath
            $page=(Request $h "/api/messages?$script:Period&user=beta%40invalid&server=ex1").Content | ConvertFrom-Json
            $page.rows.Count | Should -Be 1
            $page.rows[0].cells[15] | Should -BeExactly '<case@invalid>'
            $page.rows[0].cells[3] | Should -BeExactly 'Delivered'
        } finally {$s.Dispose()}
    }

    It 'interrupts SQLite on the real request deadline and keeps subsequent requests responsive (scoped=<Scoped>)' -ForEach @(@{Scoped=$false},@{Scoped=$true}) {
        $s = New-ServeStore "deadline$Scoped"; Add-Mail $s
        try {
            $s.Exec("ALTER TABLE message_event RENAME TO message_event_base; CREATE VIEW message_event AS SELECT e.* FROM message_event_base e CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<100000000) SELECT SUM(i) FROM n);")
            $h = Start-ServeTest $s.FilePath 1
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $selection="/api/messages?$script:Period" + $(if($Scoped){'&user=alpha%40invalid'}else{''})
            (Request $h $selection).StatusCode | Should -Be 504
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
            (Request $h '/api/meta').StatusCode | Should -Be 200
        } finally { $s.Dispose() }
    }

    It 'bounds active SQLite requests and rejects excess work with an explicit retryable 429' {
        $s = New-ServeStore 'concurrency'; Add-Mail $s
        $client=[Net.Http.HttpClient]::new()
        try {
            $s.Exec("ALTER TABLE message_event RENAME TO message_event_base; CREATE VIEW message_event AS SELECT e.* FROM message_event_base e CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<100000000) SELECT SUM(i) FROM n);")
            $h = Start-ServeTest $s.FilePath 2
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Portal-Token',$h.Token)
            $pending=@(1..4 | ForEach-Object {$client.GetAsync($h.Url+"/api/messages?$script:Period")})
            Start-Sleep -Milliseconds 100
            $r=Request $h "/api/messages?$script:Period"
            $r.StatusCode | Should -Be 429
            $r.Headers['Retry-After'][0] | Should -BeExactly '1'
            foreach($task in $pending) { $task.GetAwaiter().GetResult().StatusCode | Should -Be ([Net.HttpStatusCode]::GatewayTimeout) }
        } finally {$client.Dispose();$s.Dispose()}
    }

    It 'cancels an active SQLite request and exits promptly on authenticated shutdown' {
        $s=New-ServeStore 'shutdown-active'; Add-Mail $s
        $client=[Net.Http.HttpClient]::new()
        try {
            $s.Exec("ALTER TABLE message_event RENAME TO message_event_base; CREATE VIEW message_event AS SELECT e.* FROM message_event_base e CROSS JOIN (WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<100000000) SELECT SUM(i) FROM n);")
            $h=Start-ServeTest $s.FilePath 15
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('X-Portal-Token',$h.Token)
            $pending=$client.GetAsync($h.Url+"/api/messages?$script:Period")
            Start-Sleep -Milliseconds 100
            $pending.IsCompleted | Should -BeFalse
            $writerClock=[Diagnostics.Stopwatch]::StartNew()
            $tx=$s.Begin()
            try {
                $write=[ServeFixtures]::Connection($s).CreateCommand(); $write.Transaction=$tx
                $write.CommandText='UPDATE source_file SET offset=offset+1 WHERE id=1;'
                [void]$write.ExecuteNonQuery(); $s.ReconcileMessageRollups($tx); $tx.Commit()
            } finally {$tx.Dispose()}
            $writerClock.Elapsed.TotalMilliseconds | Should -BeLessThan 1000
            $pending.IsCompleted | Should -BeFalse
            $clock=[Diagnostics.Stopwatch]::StartNew()
            (Request $h '/api/shutdown' @{} 'POST').StatusCode | Should -Be 200
            $h.Task.Wait(3000) | Should -BeTrue
            [void]$h.Task.GetAwaiter().GetResult()
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
            Test-Path -LiteralPath $h.Options.ReadyFile | Should -BeFalse
            try {[void]$pending.GetAwaiter().GetResult()} catch {}
        } finally {$client.Dispose();$s.Dispose()}
    }

    It 'refuses to overwrite readiness evidence and requires authenticated empty shutdown' {
        (Request $script:Http '/api/shutdown' @{} 'GET').StatusCode | Should -Be 400
        (Request $script:Http '/api/shutdown?token=x' @{} 'POST').StatusCode | Should -Be 400
        $o = [ExchangeLogReport.ServeOptions]::new(); $o.DatabasePath = $script:HttpStore.FilePath
        $o.WebRoot=$script:Web; $o.ReadyFile=$script:Http.Options.ReadyFile; $o.Port=0; $o.NoBrowser=$true
        { [ExchangeLogReport.ServeHost]::RunAsync($o).GetAwaiter().GetResult() } | Should -Throw '*refusing to overwrite*'
    }

    It 'reports a blocked listener bind in a private readiness file without a token or configuration changes' {
        $o=[ExchangeLogReport.ServeOptions]::new()
        $o.DatabasePath=$script:HttpStore.FilePath; $o.WebRoot=$script:Web
        $o.Port=$script:Http.Port; $o.NoBrowser=$true; $o.ReadyFileWithToken=$true
        $o.ReadyFile=Join-Path $script:Work 'blocked-ready.json'
        try {
            { [ExchangeLogReport.ServeHost]::RunAsync($o).GetAwaiter().GetResult() } | Should -Throw '*No URL ACL, firewall or service setting was changed*'
            $signal=Get-Content -LiteralPath $o.ReadyFile -Raw | ConvertFrom-Json
            $signal.status | Should -BeExactly 'blocked'
            $signal.code | Should -BeIn 'HttpListenerBindFailed','HttpListenerAccessDenied'
            $signal.nativeErrorCode | Should -BeGreaterThan 0
            $signal.PSObject.Properties.Name | Should -Not -Contain 'token'
            (Get-Acl -LiteralPath $o.ReadyFile).AreAccessRulesProtected | Should -BeTrue
            (Request $script:Http '/api/meta').StatusCode | Should -Be 200
        } finally { if(Test-Path -LiteralPath $o.ReadyFile){Remove-Item -LiteralPath $o.ReadyFile -Force} }
    }

    It 'enters CLI Serve before configuration, mail, collection, locks and report output setup' {
        $ready=Join-Path $script:Work 'cli-ready.json'
        $out=Join-Path $script:Work 'must-not-exist'
        $start=[Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        foreach($arg in @('-NoProfile','-File',(Join-Path $script:Root 'Invoke-ExchangeLogReport.ps1'),'-Mode','Serve',
            '-DatabasePath',$script:HttpStore.FilePath,'-ConfigPath',(Join-Path $script:Work 'missing-config.psd1'),
            '-WebRoot',$script:Web,'-Port','0','-NoBrowser','-ReadyFile',$ready,'-ReadyFileWithToken','-DevelopmentMode','-Collect','-SendMail','-OutputPath',$out)){
            $start.ArgumentList.Add($arg)
        }
        $process=[Diagnostics.Process]::Start($start)
        try {
            $clock=[Diagnostics.Stopwatch]::StartNew()
            while(-not(Test-Path -LiteralPath $ready)){
                if($process.HasExited){throw ($process.StandardError.ReadToEnd()+$process.StandardOutput.ReadToEnd())}
                if($clock.Elapsed.TotalSeconds -gt 15){throw 'CLI ready timeout.'}
                Start-Sleep -Milliseconds 30
            }
            $signal=Get-Content -LiteralPath $ready -Raw | ConvertFrom-Json
            Invoke-WebRequest -Uri ($signal.url.TrimEnd('/')+'/api/shutdown') -Method Post -Headers @{'X-Portal-Token'=$signal.token} | Out-Null
            $process.WaitForExit(10000) | Should -BeTrue
            $process.ExitCode | Should -Be 0
            Test-Path -LiteralPath $out | Should -BeFalse
            Test-Path -LiteralPath $ready | Should -BeFalse
            $process.StandardOutput.ReadToEnd() | Should -Not -Match $signal.token
        } finally {
            if(-not $process.HasExited){Stop-Process -Id $process.Id -Force}
            $process.Dispose()
        }
    }
}
