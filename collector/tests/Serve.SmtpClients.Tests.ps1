#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

<#
    Schema 11: SMTP clients pre-aggregated per client x UTC hour (smtp_client_value / smtp_client / smtp_client_hour, smtp_transaction.client_id) and the
    message_rollup dictionary. Serve must answer exactly as the schema-10 implementation did (SmtpClientReference.cs, run on a schema-10 copy of the same data),
    the structures must stay exact through every writer (collector, external SQL, retention), the 10 to 11 migration must be lossless and atomic, the
    verification must see every alteration, the status filter must keep its case-insensitive text semantics and the message counts must not change.
#>

BeforeAll {
    Set-StrictMode -Version Latest
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'ExchangeLogReport.psd1') -Force
    Initialize-ExlEngine -Root $script:Root
    $references = @((Join-Path $script:Root 'lib\sqlite\Microsoft.Data.Sqlite.dll'), 'System.Runtime', 'System.Data.Common', 'System.Reflection', 'System.Net.Sockets', 'System.Net.Primitives',
        'System.Text.Encoding.Extensions', 'System.IO', 'System.Collections', 'System.Linq', 'System.Linq.Expressions', 'System.ComponentModel.Primitives', 'System.Text.Json',
        'System.Memory', 'System.Runtime.Extensions', 'netstandard')
    if (-not ('ServeFixtures' -as [type])) { Add-Type -LiteralPath (Join-Path $PSScriptRoot 'ServeFixtures.cs') -IgnoreWarnings -WarningAction SilentlyContinue -ReferencedAssemblies $references }
    if (-not ('SmtpClientReference' -as [type])) { Add-Type -LiteralPath (Join-Path $PSScriptRoot 'SmtpClientReference.cs') -IgnoreWarnings -WarningAction SilentlyContinue -ReferencedAssemblies $references }
    $script:Work = Join-Path $script:Root ('bin\t\k' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $script:Web = Join-Path $script:Work 'web'
    [void][IO.Directory]::CreateDirectory($script:Web)
    [IO.File]::WriteAllText((Join-Path $script:Web 'index.html'), '<!doctype html><p>Synthetic Serve test</p>')
    [IO.File]::WriteAllText((Join-Path $script:Web 'main.js'), 'console.log("synthetic");')
    $script:Epoch = [SmtpClientReference]::Epoch
    $script:Hosts = [Collections.Generic.List[object]]::new()
    $script:Disposables = [Collections.Generic.List[object]]::new()
    $script:Flags = [Reflection.BindingFlags]'Instance,NonPublic,Public'

    function New-ClientStore([string]$Name) { [ExchangeLogReport.Store]::new((Join-Path $script:Work "$Name.sqlite"), $false, 'synthetic') }
    function Reconcile($Store) {
        $tx = $Store.Begin()
        try { $Store.ReconcileMessageRollups($tx); $tx.Commit() } finally { $tx.Dispose() }
    }
    function Scalar($Store, [string]$Sql) { $Store.Scalar($Sql, $null) }
    function Text($Store, [string]$Sql) { [string]$Store.Query($Sql, $null).Rows[0][0] }
    function Start-ServeTest([string]$Path, [int]$Timeout = 30) {
        $o = [ExchangeLogReport.ServeOptions]::new()
        $o.DatabasePath = $Path; $o.WebRoot = $script:Web; $o.Port = 0; $o.NoBrowser = $true
        $o.ReadyFile = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        $o.ReadyFileWithToken = $true; $o.RequestTimeoutSeconds = $Timeout
        $task = [ExchangeLogReport.ServeHost]::RunAsync($o)
        $wait = [Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $o.ReadyFile)) {
            if ($task.IsCompleted) { $task.GetAwaiter().GetResult(); throw 'Host stopped before ready.' }
            if ($wait.Elapsed.TotalSeconds -gt 15) { throw 'Ready timeout.' }
            Start-Sleep -Milliseconds 20
        }
        $ready = Get-Content -LiteralPath $o.ReadyFile -Raw | ConvertFrom-Json
        $hostInfo = [pscustomobject]@{ Options = $o; Task = $task; Url = $ready.url.TrimEnd('/'); Port = $ready.port; Token = $ready.token }
        $script:Hosts.Add($hostInfo)
        return $hostInfo
    }
    function Stop-ServeTest($HostInfo) {
        if (-not $HostInfo.Task.IsCompleted) {
            try { [void](Request $HostInfo '/api/shutdown' 'POST') } catch { }
            if (-not $HostInfo.Task.Wait(10000)) { throw 'Serve did not stop cleanly.' }
        }
        [void]$HostInfo.Task.GetAwaiter().GetResult()
        [void]$script:Hosts.Remove($HostInfo)
    }
    function Request($HostInfo, [string]$Path, [string]$Method = 'GET') {
        Invoke-WebRequest -Uri ($HostInfo.Url + $Path) -Headers @{ 'X-Portal-Token' = $HostInfo.Token } -Method $Method -SkipHttpErrorCheck -TimeoutSec 60
    }
    function New-Reference($Store, [string]$Name) {
        # The schema-10 shape of the same data: the reference SQL reads it exactly as 0.3.0 read the production database.
        $connection = [ServeFixtures]::LegacyCopy($Store, (Join-Path $script:Work ("$Name-ref-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.sqlite')), 10)
        [SmtpClientReference]::Register($connection)
        $script:Disposables.Add($connection)
        return $connection
    }
    function Add-EdgeRows($Store, [int]$Rows, [int]$Seed) {
        [SmtpClientReference]::BuildEdge([ServeFixtures]::Connection($Store), $Rows, $Seed)
        Reconcile $Store
    }
    function Compare-Case($HostInfo, $Reference, $Case) {
        # Returns $null when the HTTP answer equals the schema-10 reference, otherwise a description of the first difference.
        switch ($Case.Route) {
            'list' {
                $expected = [SmtpClientReference]::List($Reference, $Case.Filter, $false, 0)
                $response = Request $HostInfo "/api/smtp/clients?$($Case.Query)"
                if ($response.StatusCode -ne 200) { return "status $($response.StatusCode) $($response.Content)" }
                $more = $false; $actual = [SmtpClientReference]::ApiRows($response.Content, [ref]$more)
                if ($more -ne $expected.HasMore) { return "hasMore $more instead of $($expected.HasMore)" }
                if ($actual.Count -ne $expected.Rows.Count) { return "$($actual.Count) rows instead of $($expected.Rows.Count)" }
                for ($i = 0; $i -lt $actual.Count; $i++) { if ($actual[$i] -cne $expected.Rows[$i]) { return "row $i`n  actual   $($actual[$i])`n  expected $($expected.Rows[$i])" } }
                return $(if ($expected.Rows.Count) { 'rows' } else { $null })
            }
            'export' {
                $expected = [SmtpClientReference]::List($Reference, $Case.Filter, $true, 0)
                $response = Request $HostInfo "/api/export.csv?$($Case.Query)"
                if ($response.StatusCode -ne 200) { return "status $($response.StatusCode) $($response.Content)" }
                if ([SmtpClientReference]::CsvBody($response.Content) -cne [SmtpClientReference]::Csv($expected)) { return 'the CSV export differs' }
                return $(if ($expected.Rows.Count) { 'rows' } else { $null })
            }
            'client' {
                $expected = [SmtpClientReference]::List($Reference, $Case.Filter, $true, $Case.Id)
                $response = Request $HostInfo "/api/smtp/clients/$($Case.Id)?$($Case.Query)"
                if ($expected.Note) { return $(if ($response.StatusCode -ne 404) { "expected 404 ($($expected.Note)), got $($response.StatusCode)" } else { $null }) }
                if ($response.StatusCode -ne 200) { return "status $($response.StatusCode) $($response.Content)" }
                $actual = [SmtpClientReference]::ApiClientRow($response.Content)
                if ($actual -cne [SmtpClientReference]::CellsJson($expected)) { return "client cells`n  actual   $actual`n  expected $([SmtpClientReference]::CellsJson($expected))" }
                return 'rows'
            }
            'tx' {
                $expected = [SmtpClientReference]::Transactions($Reference, $Case.Id, $Case.Filter)
                $response = Request $HostInfo "/api/smtp/clients/$($Case.Id)/transactions?$($Case.Query)"
                if ($expected.Note) { return $(if ($response.StatusCode -ne 404) { "expected 404 ($($expected.Note)), got $($response.StatusCode)" } else { $null }) }
                if ($response.StatusCode -ne 200) { return "status $($response.StatusCode) $($response.Content)" }
                $more = $false; $ids = [SmtpClientReference]::ApiRowIds($response.Content, [ref]$more)
                if ($more -ne $expected.HasMore -or ($ids -join ',') -ne ($expected.Ids -join ',')) { return "transactions $($ids -join ',') (more $more) instead of $($expected.Ids -join ',') (more $($expected.HasMore))" }
                return 'rows'
            }
        }
    }
    function Compare-Cases($Store, [int]$Seed, [int]$Cases, [string]$Name) {
        $reference = New-Reference $Store $Name
        $hostInfo = Start-ServeTest $Store.FilePath
        $maxId = [long](Scalar $Store 'SELECT MAX(id) FROM smtp_transaction;')
        $bad = [Collections.Generic.List[string]]::new(); $nonEmpty = 0; $n = 0
        foreach ($case in [SmtpClientReference]::Scenarios($Seed, $Cases, $maxId)) {
            $n++
            $result = Compare-Case $hostInfo $reference $case
            if ($result -eq 'rows') { $nonEmpty++ }
            elseif ($result) { $bad.Add("case $n $($case.Route) ?$($case.Query) id=$($case.Id): $result") }
        }
        Stop-ServeTest $hostInfo
        [pscustomobject]@{ Mismatches = $bad; NonEmpty = $nonEmpty }
    }
    function Invoke-StoreMethod($Store, [string]$Name, [object[]]$Arguments) {
        [ExchangeLogReport.Store].GetMethod($Name, $script:Flags).Invoke($Store, $Arguments)
    }
    function Dump($Store, [string]$Sql) { (($Store.Query($Sql, $null).Rows) | ForEach-Object { ($_ | ForEach-Object { "$_" }) -join '|' }) -join "`n" }
    # The clients of the transactions and their buckets, by key and by text: no id, so that two histories can be compared.
    function Dump-Clients($Store) {
        (Dump $Store "SELECT e.id,e.time_ms,e.server,e.direction,e.session_id,COALESCE(c.remote_host,'-'),COALESCE(c.helo,'-'),COALESCE(c.account,'-'),COALESCE(c.role,'-'),COALESCE(c.connector,'-') FROM smtp_transaction e LEFT JOIN smtp_client c ON c.id=e.client_id ORDER BY e.id;") + "`n--`n" +
        (Dump $Store "SELECT c.remote_host,COALESCE(c.helo,'-'),COALESCE(c.account,'-'),c.server,c.direction,COALESCE(c.role,'-'),COALESCE(c.connector,'-'),h.hour_ms,COALESCE(v1.text,'-'),COALESCE(v2.text,'-'),COALESCE(v3.text,'-'),COALESCE(v4.text,'-'),COALESCE(v5.text,'-'),COALESCE(v6.text,'-'),h.n,h.rcpts,h.min_id,h.min_ms,h.max_ms FROM smtp_client_hour h JOIN smtp_client c ON c.id=h.client_id LEFT JOIN smtp_client_value v1 ON v1.id=h.status LEFT JOIN smtp_client_value v2 ON v2.id=h.tls LEFT JOIN smtp_client_value v3 ON v3.id=h.mechanism LEFT JOIN smtp_client_value v4 ON v4.id=h.result LEFT JOIN smtp_client_value v5 ON v5.id=h.attempt LEFT JOIN smtp_client_value v6 ON v6.id=h.source ORDER BY 1,2,3,4,5,6,7,8,9,10,11,12,13,14;")
    }
}

AfterAll {
    foreach ($h in $script:Hosts) {
        if (-not $h.Task.IsCompleted) {
            try { [void](Request $h '/api/shutdown' 'POST') } catch { }
            if (-not $h.Task.Wait(10000)) { throw 'Serve did not stop cleanly.' }
        }
        $h.Task.GetAwaiter().GetResult()
    }
    foreach ($d in $script:Disposables) { try { $d.Dispose() } catch { } }
    if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'SMTP clients: schema 11 gives the schema-10 answers' {
    It 'matches the schema-10 reference on a randomized edge-case fixture (seed <Seed>): lists, exports, client details and client transactions, byte for byte' -ForEach @(@{ Seed = 11 }, @{ Seed = 23 }, @{ Seed = 37 }) {
        $s = New-ClientStore "equivalence$Seed"
        try {
            Add-EdgeRows $s 12000 $Seed
            $s.VerifyServeRollups().SmtpClientsVerified | Should -BeTrue
            Scalar $s 'SELECT COUNT(*) FROM smtp_client;' | Should -BeGreaterThan 1000
            Scalar $s 'SELECT COUNT(*) FROM smtp_transaction WHERE client_id IS NULL;' | Should -BeGreaterThan 100
            $r = Compare-Cases $s ($Seed + 1) 600 "equivalence$Seed"
            @($r).Count | Should -Be 1
            $r.Mismatches | Should -BeNullOrEmpty -Because ($r.Mismatches | Select-Object -First 5 | Out-String)
            $r.NonEmpty | Should -BeGreaterThan 100
        } finally { $s.Dispose() }
    }

    It 'matches the schema-10 reference after the 10 to 11 migration of the same rows' {
        $s = New-ClientStore 'migrated-source'
        try {
            Add-EdgeRows $s 8000 5
            $path = Join-Path $script:Work 'migrated.sqlite'
            $old = [ServeFixtures]::LegacyCopy($s, $path, 10); $old.Dispose()
        } finally { $s.Dispose() }
        $m = [ExchangeLogReport.Store]::new($path, $false, 'synthetic')
        try {
            Scalar $m "SELECT value FROM metadata WHERE key='schema_version';" | Should -Be 11
            $m.VerifyServeRollups().SmtpClientsVerified | Should -BeTrue
            $r = Compare-Cases $m 6 400 'migrated'
            $r.Mismatches | Should -BeNullOrEmpty -Because ($r.Mismatches | Select-Object -First 5 | Out-String)
            $r.NonEmpty | Should -BeGreaterThan 60
        } finally { $m.Dispose() }
    }

    It 'reads the sparse and the very long periods without walking every hour' {
        $s = New-ClientStore 'sparse'
        try {
            $s.Exec("INSERT INTO smtp_transaction(time_ms,server,direction,session_id,remote_ep,helo,status) VALUES($($script:Epoch),'EX1','Receive','a','198.51.100.1:25','h','Accepted'),($($script:Epoch + 86400000L * 400),'EX1','Receive','b','198.51.100.2:25','h','Accepted'),($($script:Epoch + 86400000L * 900),'EX1','Receive','c',NULL,'h','Rejected');")
            Reconcile $s
            $hostInfo = Start-ServeTest $s.FilePath
            $from = [Uri]::EscapeDataString('0001-01-02T00:00:00Z'); $to = [Uri]::EscapeDataString('2200-01-01T00:00:00Z')
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $page = (Request $hostInfo "/api/smtp/clients?from=$from&to=$to").Content | ConvertFrom-Json
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 10
            $page.rows.Count | Should -Be 3
            (@($page.rows | ForEach-Object { [string]$_.cells[6] }) -join ',') | Should -BeExactly ',198.51.100.2,198.51.100.1'
            $page.hasMore | Should -BeFalse
            Stop-ServeTest $hostInfo
        } finally { $s.Dispose() }
    }
}

Describe 'SMTP clients: maintenance' {
    It 'queues raw INSERT, UPDATE and DELETE statements: 503 SmtpClientsPending, then an exact answer after the explicit refresh' {
        $s = New-ClientStore 'raw-writers'
        try {
            Add-EdgeRows $s 3000 9
            $hostInfo = Start-ServeTest $s.FilePath
            $period = "from=$([Uri]::EscapeDataString([SmtpClientReference]::Iso($script:Epoch - 1000)))&to=$([Uri]::EscapeDataString([SmtpClientReference]::Iso($script:Epoch + 90 * 3600000L)))"
            (Request $hostInfo "/api/smtp/clients?$period").StatusCode | Should -Be 200
            $steps = @(
                @{ Name = 'insert'; Sql = "INSERT INTO smtp_transaction(time_ms,server,direction,session_id,remote_ep,helo,status,auth_user,auth_source,tls) VALUES($($script:Epoch + 7200000L),'EX1','Receive','raw-new-1','203.0.113.9:25','raw.invalid','Accepted','raw@invalid','Direct','TLS 1.3'),($($script:Epoch + 7260000L),'EX1','Receive','raw-new-2','203.0.113.9:26','raw.invalid','Rejected','raw@invalid','Direct','TLS 1.3');" },
                @{ Name = 'update the account'; Sql = "UPDATE smtp_transaction SET auth_user='moved@invalid' WHERE id IN (SELECT id FROM smtp_transaction WHERE remote_ep IS NOT NULL ORDER BY id LIMIT 60);" },
                @{ Name = 'update the key'; Sql = "UPDATE smtp_transaction SET helo='moved.example', server='EX9' WHERE id % 7 = 0;" },
                @{ Name = 'update the time'; Sql = "UPDATE smtp_transaction SET time_ms=time_ms+5400000 WHERE id % 13 = 0;" },
                @{ Name = 'delete'; Sql = "DELETE FROM smtp_transaction WHERE id % 11 = 0;" })
            foreach ($step in $steps) {
                $s.Exec($step.Sql)
                (Scalar $s 'SELECT (SELECT COUNT(*) FROM smtp_client_pending)+(SELECT COUNT(*) FROM smtp_client_dirty);') | Should -BeGreaterThan 0 -Because $step.Name
                $pending = Request $hostInfo "/api/smtp/clients?$period"
                $pending.StatusCode | Should -Be 503 -Because $step.Name
                # The rollup queue is checked first (an SMTP row without Message-ID also queues a rollup identity); a change that leaves it empty is reported as SmtpClientsPending.
                $expectedCode = if ([long](Scalar $s 'SELECT COUNT(*) FROM message_rollup_dirty;') -gt 0) { 'RollupPending' } else { 'SmtpClientsPending' }
                ($pending.Content | ConvertFrom-Json).error.code | Should -BeExactly $expectedCode -Because $step.Name
                if ($step.Name -eq 'update the account') { $expectedCode | Should -BeExactly 'SmtpClientsPending' }
                (Request $hostInfo "/api/smtp/clients/1?$period").StatusCode | Should -Be 503
                { $s.VerifyServeRollups() } | Should -Throw '*unreconciled*'
                $s.RefreshServeRollups()
                (Scalar $s 'SELECT (SELECT COUNT(*) FROM smtp_client_pending)+(SELECT COUNT(*) FROM smtp_client_dirty);') | Should -Be 0
                $s.VerifyServeRollups().SmtpClientsVerified | Should -BeTrue -Because $step.Name
                $r = Compare-Cases $s (100 + $steps.IndexOf($step)) 60 'raw-step'
                $r.Mismatches | Should -BeNullOrEmpty -Because ($step.Name + ' ' + ($r.Mismatches | Select-Object -First 3 | Out-String))
            }
            # The inserted pair belongs to one client of its own, with the account it carried.
            Scalar $s "SELECT COUNT(*) FROM smtp_client WHERE remote_host='203.0.113.9' AND account='raw@invalid';" | Should -Be 1
        } finally { $s.Dispose() }
    }

    It 'recomputes the hour cut by the retention cutoff and drops the clients that have nothing left' {
        $s = New-ClientStore 'retention'
        try {
            Add-EdgeRows $s 6000 13
            $cutoff = $script:Epoch + 20 * 3600000L + 1800000L   # in the middle of an hour
            $kept = [long](Scalar $s "SELECT COUNT(*) FROM smtp_transaction WHERE time_ms >= $cutoff;")
            $before = [long](Scalar $s 'SELECT COUNT(*) FROM smtp_transaction;')
            $kept | Should -BeGreaterThan 0; $kept | Should -BeLessThan $before
            $p = $s.Purge($cutoff, '1970-01-01', $cutoff)
            $p.Smtp | Should -Be ($before - $kept)
            Scalar $s 'SELECT COUNT(*) FROM smtp_transaction;' | Should -Be $kept
            (Scalar $s 'SELECT (SELECT COUNT(*) FROM smtp_client_pending)+(SELECT COUNT(*) FROM smtp_client_dirty);') | Should -Be 0
            $s.VerifyServeRollups().SmtpClientsVerified | Should -BeTrue
            # The cut hour holds only what remains; no bucket and no client without a transaction is left.
            $cutHour = $script:Epoch + 20 * 3600000L
            Scalar $s "SELECT COALESCE(SUM(n),0) FROM smtp_client_hour WHERE hour_ms=$cutHour;" | Should -Be (Scalar $s "SELECT COUNT(*) FROM smtp_transaction e WHERE e.client_id IS NOT NULL AND e.time_ms>=$cutHour AND e.time_ms<$($cutHour + 3600000L);")
            Scalar $s "SELECT COUNT(*) FROM smtp_client_hour WHERE hour_ms < $cutHour;" | Should -Be 0
            Scalar $s 'SELECT COUNT(*) FROM smtp_client c WHERE NOT EXISTS(SELECT 1 FROM smtp_transaction e WHERE e.client_id=c.id);' | Should -Be 0
            $r = Compare-Cases $s 99 80 'retention'
            $r.Mismatches | Should -BeNullOrEmpty -Because ($r.Mismatches | Select-Object -First 3 | Out-String)
        } finally { $s.Dispose() }
    }

    It 're-keys a transaction resolved by the next batch, moves it between clients, drops the orphan and forgets what a rolled back batch created' {
        $s = New-ClientStore 'maintenance'
        $maintenanceType = [ExchangeLogReport.Store].Assembly.GetType('ExchangeLogReport.SmtpClientMaintenance')
        $connection = [ServeFixtures]::Connection($s)
        try {
            # As the collection apply thread: the triggers of its connection are off, the code maintains the structures in the batch transaction.
            $before = Invoke-StoreMethod $s 'SetTriggersEnabled' @($false)
            $m = [Activator]::CreateInstance($maintenanceType, @($s))
            function Insert-Row($Tx, $Id, [string]$Ep, [long]$Time, [string]$Source, [bool]$Updatable) {
                $client = $m.Client('EX1', 'Receive', 'FrontEnd', 'Default', $Ep, 'helo.invalid', $null, $Source)
                $c = $connection.CreateCommand(); $c.Transaction = $Tx
                try {
                    $c.CommandText = 'INSERT INTO smtp_transaction(id,time_ms,server,direction,role,connector,session_id,remote_ep,helo,tls,rcpt_count,status,auth_source,client_id) VALUES(@id,@t,''EX1'',''Receive'',''FrontEnd'',''Default'',@sid,@ep,''helo.invalid'',''TLS 1.2'',2,''Accepted'',@src,@client);'
                    [void]$c.Parameters.AddWithValue('@id', [long]$Id); [void]$c.Parameters.AddWithValue('@t', $Time); [void]$c.Parameters.AddWithValue('@sid', "s$Id"); [void]$c.Parameters.AddWithValue('@ep', $Ep)
                    [void]$c.Parameters.AddWithValue('@src', $(if ($Source) { $Source } else { [DBNull]::Value })); [void]$c.Parameters.AddWithValue('@client', $(if ($null -eq $client) { [DBNull]::Value } else { $client }))
                    [void]$c.ExecuteNonQuery()
                } finally { $c.Dispose() }
                $m.Inserted([long]$Id, $Time, $client, 'Accepted', 2L, 'TLS 1.2', $null, $null, $null, $Source, $Updatable)
                return $client
            }
            function Resolve-Row($Tx, $Id, $OldClient, [string]$Ep, [long]$Time, [string]$User) {
                $client = $m.Client('EX1', 'Receive', 'FrontEnd', 'Default', $Ep, 'helo.invalid', $User, 'Direct')
                $c = $connection.CreateCommand(); $c.Transaction = $Tx
                try {
                    $c.CommandText = 'UPDATE smtp_transaction SET auth_user=@u,auth_mechanism=''LOGIN'',auth_result=''Succeeded'',auth_attempt_result=''Succeeded'',auth_source=''Direct'',client_id=@client WHERE id=@id;'
                    [void]$c.Parameters.AddWithValue('@u', $User); [void]$c.Parameters.AddWithValue('@client', $client); [void]$c.Parameters.AddWithValue('@id', [long]$Id)
                    [void]$c.ExecuteNonQuery()
                } finally { $c.Dispose() }
                $m.Updated([long]$Id, $Time, $OldClient, $client, 'LOGIN', 'Succeeded', 'Succeeded', 'Direct')
                $m.Left($OldClient, $client)
                return $client
            }
            $t0 = $script:Epoch + 3600000L
            # Batch 1: five transactions of one peer (account not resolved yet) and one of another peer, all written at once.
            $tx = $s.Begin(); $m.Use($tx)
            $first = $null
            foreach ($i in 1..5) { $c = Insert-Row $tx $i '198.51.100.20:2501' ($t0 + $i * 1000) 'Missing' $true; if (-not $first) { $first = $c } }
            $other = Insert-Row $tx 6 '198.51.100.21:2501' ($t0 + 6000) 'Missing' $false
            # The first two are resolved inside the same batch (in-memory re-keying), the other three only by the next batch.
            $account1 = $null
            foreach ($i in 1..2) { $account1 = Resolve-Row $tx $i $first '198.51.100.20:2501' ($t0 + $i * 1000) 'one@invalid' }
            $m.Flush(); $tx.Commit(); $tx.Dispose()
            $m.Rekeyed | Should -Be 2
            $account1 | Should -Not -Be $first
            Scalar $s "SELECT COUNT(*) FROM smtp_client_hour WHERE client_id=$first;" | Should -BeGreaterThan 0
            $s.VerifyServeRollups().SmtpClientsVerified | Should -BeTrue
            # Batch 2: the next batch resolves the other three (rows of an earlier batch: the buckets are recomputed from the rows), the old client has no transaction left.
            $tx = $s.Begin(); $m.Use($tx)
            foreach ($i in 3..5) { [void](Resolve-Row $tx $i $first '198.51.100.20:2501' ($t0 + $i * 1000) 'one@invalid') }
            $m.Flush(); $tx.Commit(); $tx.Dispose()
            $m.OrphansDeleted | Should -BeGreaterOrEqual 1
            Scalar $s "SELECT COUNT(*) FROM smtp_client WHERE id=$first;" | Should -Be 0
            Scalar $s "SELECT COUNT(*) FROM smtp_client_hour WHERE client_id=$first;" | Should -Be 0
            Scalar $s "SELECT n FROM smtp_client_hour WHERE client_id=$account1;" | Should -Be 5
            $s.VerifyServeRollups().SmtpClientsVerified | Should -BeTrue
            # Batch 3: a duplicate insert (ignored by the database) must not leave the client it asked for; a second account moves one transaction on.
            $tx = $s.Begin(); $m.Use($tx)
            [void]$m.Client('EX1', 'Receive', 'FrontEnd', 'Default', '198.51.100.99:25', 'helo.invalid', $null, 'Missing')   # created for a row that is then ignored
            [void](Resolve-Row $tx 5 $account1 '198.51.100.20:2501' ($t0 + 5000) 'two@invalid')
            $m.Flush(); $tx.Commit(); $tx.Dispose()
            Scalar $s "SELECT COUNT(*) FROM smtp_client WHERE remote_host='198.51.100.99';" | Should -Be 0
            Scalar $s "SELECT COUNT(*) FROM smtp_client WHERE remote_host='198.51.100.20';" | Should -Be 2
            $s.VerifyServeRollups().SmtpClientsVerified | Should -BeTrue
            # Batch 4 is rolled back: the client and the value it created no longer exist, and the same key must be created again by the next batch.
            $tx = $s.Begin(); $m.Use($tx)
            [void](Insert-Row $tx 7 '198.51.100.30:25' ($t0 + 7000) 'Rolled back source' $true)
            $tx.Rollback(); $tx.Dispose(); $m.Reset()
            Scalar $s "SELECT COUNT(*) FROM smtp_client WHERE remote_host='198.51.100.30';" | Should -Be 0
            Scalar $s "SELECT COUNT(*) FROM smtp_client_value WHERE text='Rolled back source';" | Should -Be 0
            $tx = $s.Begin(); $m.Use($tx)
            [void](Insert-Row $tx 7 '198.51.100.30:25' ($t0 + 7000) 'Rolled back source' $false)
            $m.Flush(); $tx.Commit(); $tx.Dispose()
            Scalar $s "SELECT COUNT(*) FROM smtp_client WHERE remote_host='198.51.100.30';" | Should -Be 1
            $s.VerifyServeRollups().SmtpClientsVerified | Should -BeTrue
        } finally {
            if ($m) { $m.Dispose() }
            $s.Dispose()
        }
    }

    It 'recomputes a client x hour that holds more transactions than one recomputation slice, with thousands of rows in one millisecond' {
        $s = New-ClientStore 'big-bucket'
        try {
            # 30000 transactions of one peer in the first half hour, 10000 of them in the same millisecond, several statuses, TLS values and evidence sources.
            $s.Exec(@"
WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<30000)
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,remote_ep,helo,status,tls,rcpt_count,auth_source)
SELECT $($script:Epoch) + CASE WHEN i%3=0 THEN 1234 ELSE (i%1800)*1000 END, 'EX1', 'Receive', 'b'||i, '198.51.100.77:25', 'big.invalid',
  CASE WHEN i%7=0 THEN 'Rejected' WHEN i%11=0 THEN NULL ELSE 'Accepted' END, CASE WHEN i%5=0 THEN 'TLS 1.3' ELSE 'TLS 1.2' END, i%4, CASE WHEN i%2=0 THEN 'Direct' ELSE 'Missing' END FROM n;
"@)
            Reconcile $s
            $s.VerifySmtpClients().Verified | Should -BeTrue
            Scalar $s 'SELECT COUNT(*) FROM smtp_client;' | Should -Be 1
            Scalar $s 'SELECT SUM(n) FROM smtp_client_hour;' | Should -Be 30000
            # Half of the transactions move to another client: both buckets are recomputed from the rows, slice by slice.
            $s.Exec("UPDATE smtp_transaction SET auth_user='moved@invalid' WHERE id%2=0;")
            Reconcile $s
            $s.VerifySmtpClients().Verified | Should -BeTrue
            Scalar $s 'SELECT COUNT(*) FROM smtp_client;' | Should -Be 2
            Scalar $s 'SELECT MIN(t) FROM (SELECT SUM(n) t FROM smtp_client_hour GROUP BY client_id);' | Should -Be 15000
            $s.Exec("UPDATE smtp_transaction SET status='Deferred' WHERE id%9=0; DELETE FROM smtp_transaction WHERE id%13=0;")
            Reconcile $s
            $s.VerifySmtpClients().Verified | Should -BeTrue
            Scalar $s 'SELECT SUM(n) FROM smtp_client_hour;' | Should -Be (Scalar $s 'SELECT COUNT(*) FROM smtp_transaction;')
        } finally { $s.Dispose() }
    }

    It 'maintains the same structures whether the collection writes them (triggers off) or the triggers queue them (triggers on), across several batches and a re-read file' {
        function At([int]$seconds) { [DateTimeOffset]::FromUnixTimeMilliseconds($script:Epoch + $seconds * 1000L).ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
        function Session([string]$sid, [int]$base, [string]$remote, [string]$helo, [string]$user) {
            $steps = @('+|', '>|220 ready', "<|EHLO $helo", '>|250 hello')
            if ($user) { $steps += @('<|AUTH LOGIN', "*|$user|authenticated", '>|235 2.7.0 Authentication successful') }
            $steps += @('<|MAIL FROM:<s@test>', '>|250 OK', '<|RCPT TO:<r@test>', '>|250 OK', '<|DATA', ">|250 2.6.0 <$sid@test> [InternalId=7, Hostname=EX1] Queued mail for delivery", '-|')
            for ($i = 0; $i -lt $steps.Count; $i++) {
                $parts = $steps[$i].Split('|', 3)
                $context = if ($parts.Length -eq 3) { $parts[2] } else { '' }
                "$(At ($base + $i)),EX1\Client Frontend EX1,$sid,$i,192.0.2.2:587,$remote,$($parts[0].Trim()),`"$($parts[1].Replace('"','""'))`",$context"
            }
        }
        $head = '#Fields: date-time,connector-id,session-id,sequence-number,local-endpoint,remote-endpoint,event,data,context'
        $users = @('one@test', $null, 'two@test', $null, 'one@test')
        $files = @{}
        foreach ($file in 1..4) {
            $files[$file] = @($head)
            foreach ($n in (($file - 1) * 8 + 1)..($file * 8)) { $files[$file] += Session ('0BBB{0:D12}' -f $n) ($n * 40) "192.0.2.$(1 + $n % 6):5$($n % 4)000" "helo$($n % 3).test" $users[$n % $users.Count] }
        }
        $more = @($head)
        foreach ($n in 33..40) { $more += Session ('0BBB{0:D12}' -f $n) ($n * 40) "192.0.2.$(1 + $n % 6):5$($n % 4)000" "helo$($n % 3).test" $users[$n % $users.Count] }
        $dumps = @{}
        foreach ($mode in 'triggers', 'code') {
            $folder = Join-Path $script:Work "collect-$mode"; [void][IO.Directory]::CreateDirectory($folder)
            foreach ($file in 1..4) { $log = Join-Path $folder "smtp-$file.log"; [IO.File]::WriteAllLines($log, [string[]]$files[$file]); [IO.File]::SetLastWriteTimeUtc($log, [DateTime]::UtcNow.AddHours(-20 + $file)) }   # the files are read oldest first: a fixed order
            $s = New-ClientStore "collect-$mode"
            try {
                foreach ($step in 1..3) {
                    if ($step -eq 2) { $s.Exec('UPDATE source_file SET offset=0,size=0;') }   # the file is read again from the start: every insert is ignored
                    if ($step -eq 3) { $log = Join-Path $folder "smtp-5.log"; [IO.File]::WriteAllLines($log, [string[]]$more); [IO.File]::SetLastWriteTimeUtc($log, [DateTime]::UtcNow.AddHours(-10)) }
                    $o = [ExchangeLogReport.CollectorOptions]::new()
                    $o.NowMs = $script:Epoch + 86400000; $o.Parallelism = 1; $o.BatchRows = 25   # one parse thread (the row ids follow the order of the files); several batches per run
                    $o.DisableTriggersDuringApply = ($mode -eq 'code')
                    $o.RunId = $s.StartRun('Collect', 'synthetic', 'synthetic', 'test')
                    $collector = [ExchangeLogReport.Collector]::new($s, $o)
                    $job = [ExchangeLogReport.SourceJob]::new(); $job.Server = 'EX1'; $job.Kind = 'SmtpReceive'; $job.Folder = $folder; $job.Role = 'FrontEnd'
                    $collector.Plan(@($job), [datetime]::MinValue)
                    $run = $collector.Start(@($job)); [void]$run.Wait(-1)
                    if ($run.Error) { throw $run.Error }
                    [void]$collector.Complete()
                    $run.Statistics | Should -Match 'SMTP clients \d+[.,]\d s'
                    if ($step -eq 1) { $run.Statistics -match '\((\d+) batches\)' | Should -BeTrue; [int]$Matches[1] | Should -BeGreaterThan 1 -Because "$mode step $step" }
                    $v = $s.VerifyServeRollups()
                    $v.SmtpClientsVerified | Should -BeTrue -Because "$mode step $step"
                    (Scalar $s 'SELECT (SELECT COUNT(*) FROM smtp_client_pending)+(SELECT COUNT(*) FROM smtp_client_dirty);') | Should -Be 0
                }
                Scalar $s 'SELECT COUNT(*) FROM smtp_transaction;' | Should -Be 40
                Scalar $s "SELECT COUNT(*) FROM smtp_transaction WHERE auth_user='one@test';" | Should -BeGreaterThan 5
                Scalar $s 'SELECT COUNT(*) FROM smtp_client WHERE account IS NULL;' | Should -BeGreaterThan 0
                Scalar $s 'SELECT COUNT(*) FROM smtp_client WHERE account IS NOT NULL;' | Should -BeGreaterThan 0
                $dumps[$mode] = Dump-Clients $s
                # The triggers are still active on the connection after the run (a raw write is queued again).
                $s.Exec("INSERT INTO smtp_transaction(time_ms,server,direction,session_id,remote_ep) VALUES(1,'EX1','Receive','after-run','203.0.113.1:25');")
                Scalar $s 'SELECT COUNT(*) FROM smtp_client_pending;' | Should -Be 1
            } finally { $s.Dispose() }
        }
        $dumps['code'] | Should -BeExactly $dumps['triggers']
    }
}

Describe 'SMTP clients and message_rollup: migration 10 to 11' {
    It 'keeps ids, the stable-id sequence and the decoded content, derives the client structures and is idempotent' {
        $s = New-ClientStore 'migration'
        try {
            Add-EdgeRows $s 4000 3
            [ServeFixtures]::Populate($s, 1792100000000L, 300)
            $s.Exec("INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,directionality) VALUES(1792100000500,'EX2','FAIL','<fail@invalid>','f1','a@invalid','b@invalid','Originating');")
            Reconcile $s
            # An id that was used and then deleted: the sequence is ahead of the largest id and must stay so.
            $s.Exec("INSERT INTO message_event(time_ms,server,event_id,message_id,log_id) VALUES(1792100001000,'EX1','RECEIVE','<last-id@invalid>','li');")
            Reconcile $s
            $s.Exec("DELETE FROM message_event WHERE message_id='<last-id@invalid>';")
            Reconcile $s
            $rollup = [ServeFixtures]::DecodedRollup($s)
            $sequence = Scalar $s "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';"
            $sequence | Should -BeGreaterThan ([long](Scalar $s 'SELECT MAX(id) FROM message_rollup;'))
            $raw = [ServeFixtures]::RawBaseline($s)
            $clients = Dump-Clients $s
            $path = Join-Path $script:Work 'migration-10.sqlite'
            $old = [ServeFixtures]::LegacyCopy($s, $path, 10)
            try {
                # What schema 10 stored: text columns, no dictionary, no client structures, ix_smtp_latest.
                $c = $old.CreateCommand()
                $c.CommandText = "SELECT typeof(kind)||','||typeof(status)||','||(SELECT COUNT(*) FROM sqlite_master WHERE name IN('message_rollup_value','smtp_client','smtp_client_hour','smtp_client_pending','smtp_client_dirty','ix_smtp_client'))||','||(SELECT COUNT(*) FROM sqlite_master WHERE name='ix_smtp_latest')||','||(SELECT COUNT(*) FROM pragma_table_info('smtp_transaction') WHERE name='client_id') FROM message_rollup LIMIT 1;"
                $c.ExecuteScalar() | Should -BeExactly 'text,text,0,1,0'
                $c.Dispose()
            } finally { $old.Dispose() }
        } finally { $s.Dispose() }
        $m = [ExchangeLogReport.Store]::new($path, $false, 'synthetic')
        try {
            Scalar $m "SELECT value FROM metadata WHERE key='schema_version';" | Should -Be 11
            [ServeFixtures]::DecodedRollup($m) | Should -BeExactly $rollup
            Scalar $m "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';" | Should -Be $sequence
            Scalar $m "SELECT COUNT(*) FROM sqlite_sequence WHERE name LIKE 'message_rollup%';" | Should -Be 1
            [ServeFixtures]::RawBaseline($m) | Should -BeExactly $raw
            Dump-Clients $m | Should -BeExactly $clients
            Scalar $m "SELECT COUNT(*) FROM sqlite_master WHERE name='ix_smtp_latest';" | Should -Be 0
            Text $m "SELECT typeof(kind)||','||typeof(status) FROM message_rollup LIMIT 1;" | Should -BeExactly 'integer,integer'
            Text $m "SELECT sql FROM sqlite_master WHERE name='message_rollup';" | Should -Match 'UNIQUE\(kind,identity\)'
            $v = $m.VerifyServeRollups(); $v.Verified | Should -BeTrue; $v.SmtpClientsVerified | Should -BeTrue
            $cookie = Scalar $m 'PRAGMA schema_version;'
            $m.Dispose()
            $m = [ExchangeLogReport.Store]::new($path, $false, 'synthetic')
            Scalar $m 'PRAGMA schema_version;' | Should -Be $cookie   # a second open changes nothing
            # A new rollup is appended after the preserved sequence: no id is reused.
            $m.Exec("INSERT INTO message_event(time_ms,server,event_id,message_id,log_id) VALUES(1792100009000,'EX1','RECEIVE','<after-migration@invalid>','am');")
            Reconcile $m
            Scalar $m "SELECT id FROM message_rollup WHERE identity='<after-migration@invalid>';" | Should -BeGreaterThan $sequence
        } finally { $m.Dispose() }
    }

    It 'rolls back everything when the migration fails (<Failure>): schema 10 stays, no client structure, no recoded rollup' -ForEach @(
        # The version is written last: everything done before it (the recoded rollup and the client structures) is undone.
        @{ Failure = 'version write'; Sql = "CREATE TRIGGER fail_schema11 BEFORE UPDATE ON metadata WHEN NEW.key='schema_version' AND NEW.value='11' BEGIN SELECT RAISE(ABORT,'synthetic migration failure'); END;" },
        # The client_id of the transactions is written after message_rollup was recoded: that part is undone too.
        @{ Failure = 'client assignment'; Sql = "CREATE TRIGGER fail_clients BEFORE UPDATE ON smtp_transaction BEGIN SELECT RAISE(ABORT,'synthetic migration failure'); END;" }
    ) {
        $s = New-ClientStore "rollback-$($Failure -replace ' ','-')"
        try {
            Add-EdgeRows $s 1500 4
            [ServeFixtures]::Populate($s, 1792100000000L, 50)
            $path = Join-Path $script:Work "rollback-$($Failure -replace ' ','-')-10.sqlite"
            $old = [ServeFixtures]::LegacyCopy($s, $path, 10)
            try { $c = $old.CreateCommand(); $c.CommandText = $Sql; [void]$c.ExecuteNonQuery(); $c.Dispose() } finally { $old.Dispose() }
        } finally { $s.Dispose() }
        $snapshot = {
            param($p)
            $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$p;Mode=ReadOnly;Pooling=False"); $db.Open()
            try {
                $c = $db.CreateCommand()
                $c.CommandText = "SELECT (SELECT value FROM metadata WHERE key='schema_version')||'|'||(SELECT COUNT(*) FROM sqlite_master WHERE name IN('message_rollup_value','smtp_client','smtp_client_value','smtp_client_hour','smtp_client_pending','smtp_client_dirty','ix_smtp_client','ix_smtp_unknown_peer','ux_smtp_client','message_rollup_10','tr_smtp_transaction_client_insert'))||'|'||(SELECT COUNT(*) FROM sqlite_master WHERE name='ix_smtp_latest')||'|'||(SELECT COUNT(*) FROM pragma_table_info('smtp_transaction') WHERE name='client_id')||'|'||(SELECT typeof(kind)||typeof(status) FROM message_rollup LIMIT 1)||'|'||(SELECT seq FROM sqlite_sequence WHERE name='message_rollup')||'|'||(SELECT COUNT(*) FROM message_rollup)||'|'||(SELECT group_concat(id||identity||status||first_ms,',') FROM (SELECT * FROM message_rollup ORDER BY id));"
                $c.ExecuteScalar()
            } finally { $db.Dispose() }
        }
        $expected = & $snapshot $path
        $expected | Should -Match '^10\|0\|1\|0\|texttext\|'
        { [ExchangeLogReport.Store]::new($path, $false, 'synthetic') } | Should -Throw '*synthetic migration failure*'
        (& $snapshot $path) | Should -BeExactly $expected
        # The failure is removed: the same file now migrates completely.
        $db = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$path;Pooling=False"); $db.Open()
        try { $c = $db.CreateCommand(); $c.CommandText = "DROP TRIGGER IF EXISTS fail_schema11; DROP TRIGGER IF EXISTS fail_clients;"; [void]$c.ExecuteNonQuery() } finally { $db.Dispose() }
        $m = [ExchangeLogReport.Store]::new($path, $false, 'synthetic')
        try { $m.VerifyServeRollups().SmtpClientsVerified | Should -BeTrue } finally { $m.Dispose() }
    }
}

Describe 'SMTP clients: performance guard' {
    It 'answers lists, details and transactions of a fixture of 120000 SMTP transactions in well under a second (p95), whatever the period' {
        $s = New-ClientStore 'performance'
        try {
            # 120000 transactions of 6000 clients over 14 days (the SMTP clients of a busy relay), derived by the explicit reconciliation.
            $s.Exec(@"
WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<120000)
INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,role,connector,session_id,remote_ep,helo,tls,mail_from,rcpt_count,rcpts,message_id,status,auth_user,auth_mechanism,auth_result,auth_attempt_result,auth_source)
SELECT $($script:Epoch) + (i*7919 % 1209600)*1000, NULL, 'EX'||(1+i%3), 'Receive', 'FrontEnd', 'Default', 's'||i,
  '198.'||(51+(i%6000)/250)||'.'||((i%6000)%250)||'.1:'||(20000+i%4000), 'helo'||(i%900)||'.invalid', CASE WHEN i%5=0 THEN 'TLS 1.3' ELSE 'TLS 1.2' END,
  'sender'||(i%100)||'@invalid', 1+i%3, 'r@invalid', '<perf'||i||'@invalid>', CASE WHEN i%17=0 THEN 'Rejected' WHEN i%19=0 THEN 'Deferred' ELSE 'Accepted' END,
  CASE WHEN i%4=0 THEN 'user'||(i%300)||'@invalid' ELSE NULL END, CASE WHEN i%4=0 THEN 'LOGIN' ELSE NULL END, CASE WHEN i%4=0 THEN 'Succeeded' ELSE NULL END, CASE WHEN i%4=0 THEN 'Succeeded' ELSE NULL END,
  CASE WHEN i%4=0 THEN 'Direct' ELSE 'Missing' END FROM n;
"@)
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Reconcile $s
            $reconcileSeconds = $clock.Elapsed.TotalSeconds
            Scalar $s 'SELECT COUNT(*) FROM smtp_client;' | Should -BeGreaterThan 5000
            $s.VerifySmtpClients().Verified | Should -BeTrue
            $hostInfo = Start-ServeTest $s.FilePath 60
            $day = 86400000L
            $paths = @()
            foreach ($period in @(@(($script:Epoch - 1000), ($script:Epoch + 15 * $day)), @(($script:Epoch + 7 * $day), ($script:Epoch + 14 * $day + 1800000)), @(($script:Epoch + 3 * $day + 1234), ($script:Epoch + 4 * $day + 99)), @($script:Epoch, ($script:Epoch + 1800000)))) {
                $q = "from=$([Uri]::EscapeDataString([SmtpClientReference]::Iso($period[0])))&to=$([Uri]::EscapeDataString([SmtpClientReference]::Iso($period[1])))"
                $paths += "/api/smtp/clients?$q", "/api/smtp/clients?$q&size=500&page=11", "/api/smtp/clients?$q&server=EX2", "/api/smtp/clients?$q&status=Rejected", "/api/smtp/clients?$q&server=EX1&status=Rejected",
                    "/api/smtp/clients/1?$q", "/api/smtp/clients/4000?$q", "/api/smtp/clients/1/transactions?$q"
            }
            $times = @()
            foreach ($path in $paths) {
                $one = [Diagnostics.Stopwatch]::StartNew()
                $r = Request $hostInfo $path
                $times += $one.Elapsed.TotalMilliseconds
                $r.StatusCode | Should -BeIn 200, 404 -Because $path
            }
            $sorted = $times | Sort-Object
            $p95 = $sorted[[Math]::Min($sorted.Count - 1, [int][Math]::Ceiling($sorted.Count * 0.95) - 1)]
            Write-Host ("SMTP clients performance: reconciliation of 120000 transactions $([Math]::Round($reconcileSeconds, 1)) s; $($paths.Count) requests, median $([Math]::Round($sorted[[int]($sorted.Count / 2)], 1)) ms, p95 $([Math]::Round($p95, 1)) ms, max $([Math]::Round($sorted[-1], 1)) ms")
            $p95 | Should -BeLessThan 500
            Stop-ServeTest $hostInfo
        } finally { $s.Dispose() }
    }

    It 'verifies the SMTP client structures alone, with their counts, and refuses queued work' {
        $s = New-ClientStore 'verify-alone'
        try {
            Add-EdgeRows $s 2000 21
            $v = $s.VerifySmtpClients()
            $v.Verified | Should -BeTrue
            $v.Clients | Should -Be (Scalar $s 'SELECT COUNT(*) FROM smtp_client;')
            $v.HourRows | Should -Be (Scalar $s 'SELECT COUNT(*) FROM smtp_client_hour;')
            $v.Values | Should -Be (Scalar $s 'SELECT COUNT(*) FROM smtp_client_value;')
            $s.Exec("INSERT INTO smtp_transaction(time_ms,server,direction,session_id,remote_ep) VALUES(1,'EX1','Receive','queued','203.0.113.1:25');")
            { $s.VerifySmtpClients() } | Should -Throw '*unreconciled*'
        } finally { $s.Dispose() }
    }
}

Describe 'SMTP clients: the verification sees every alteration' {
    It 'rejects an alteration of <Change>' -ForEach @(
        @{ Change = 'bucket count'; Sql = 'UPDATE smtp_client_hour SET n=n+1 WHERE client_id=(SELECT MIN(client_id) FROM smtp_client_hour);' },
        @{ Change = 'bucket recipients'; Sql = 'UPDATE smtp_client_hour SET rcpts=rcpts+1 WHERE client_id=(SELECT MIN(client_id) FROM smtp_client_hour);' },
        @{ Change = 'bucket first id'; Sql = 'UPDATE smtp_client_hour SET min_id=min_id+1000000 WHERE client_id=(SELECT MIN(client_id) FROM smtp_client_hour);' },
        @{ Change = 'bucket last time'; Sql = 'UPDATE smtp_client_hour SET max_ms=max_ms+1 WHERE client_id=(SELECT MIN(client_id) FROM smtp_client_hour);' },
        @{ Change = 'missing bucket'; Sql = 'DELETE FROM smtp_client_hour WHERE client_id=(SELECT MIN(client_id) FROM smtp_client_hour);' },
        @{ Change = 'extra bucket'; Sql = 'INSERT INTO smtp_client_hour SELECT client_id,hour_ms+86400000,status,tls,mechanism,result,attempt,source,n,rcpts,min_id,min_ms,max_ms FROM smtp_client_hour LIMIT 1;' },
        @{ Change = 'bucket value code'; Sql = 'UPDATE smtp_client_hour SET tls=(SELECT MAX(id) FROM smtp_client_value)+1000 WHERE client_id=(SELECT MIN(client_id) FROM smtp_client_hour);' },
        @{ Change = 'dictionary text'; Sql = "UPDATE smtp_client_value SET text='Altered '||text WHERE text='Accepted';" },
        @{ Change = 'client_id of a transaction'; Sql = 'UPDATE smtp_transaction SET client_id=(SELECT MAX(id) FROM smtp_client) WHERE client_id=(SELECT MIN(id) FROM smtp_client);' },
        @{ Change = 'client_id removed'; Sql = 'UPDATE smtp_transaction SET client_id=NULL WHERE client_id=(SELECT MIN(id) FROM smtp_client);' },
        @{ Change = 'client_id dangling'; Sql = 'UPDATE smtp_transaction SET client_id=99999999 WHERE client_id=(SELECT MIN(id) FROM smtp_client);' },
        @{ Change = 'client_id on a transaction without endpoint'; Sql = 'UPDATE smtp_transaction SET client_id=(SELECT MIN(id) FROM smtp_client) WHERE id=(SELECT MIN(id) FROM smtp_transaction WHERE remote_ep IS NULL OR remote_ep='''');' },
        @{ Change = 'client key'; Sql = "UPDATE smtp_client SET account='tampered@invalid' WHERE id=(SELECT MIN(id) FROM smtp_client);" },
        @{ Change = 'client server'; Sql = "UPDATE smtp_client SET server='EX9' WHERE id=(SELECT MIN(id) FROM smtp_client);" },
        @{ Change = 'orphan client'; Sql = "INSERT INTO smtp_client(server,direction,remote_host) VALUES('EX1','Receive','198.51.100.250');" },
        @{ Change = 'queued transaction'; Sql = 'INSERT INTO smtp_client_pending VALUES(1);' },
        @{ Change = 'queued bucket'; Sql = 'INSERT INTO smtp_client_dirty VALUES(1,0);' }
    ) {
        $s = New-ClientStore ('tamper-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        try {
            Add-EdgeRows $s 1200 17
            $s.VerifyServeRollups().SmtpClientsVerified | Should -BeTrue
            $s.Exec($Sql)
            $message = $null
            try { [void]$s.VerifyServeRollups() } catch { $message = $_.Exception.GetBaseException().Message }
            $message | Should -Match 'InvalidSmtpClients|unreconciled' -Because "$Change must not verify"
        } finally { $s.Dispose() }
    }
}

Describe 'message_rollup: dictionary codes, status filter and counts' {
    BeforeAll {
        function Add-MessageFixture($Store, [int]$Count) {
            # Journeys of every shape: delivered at once, hours or days later (they cross the bounds of a period), failed, still open, SMTP-only and refused SMTP rows.
            $Store.Exec(@"
WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<$Count)
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,recipient_count,subject,directionality)
SELECT $($script:Epoch) + (i*7919 % 432000)*1000, 'EX'||(1+i%2), 'RECEIVE', '<g'||i||'@invalid>', 'r'||i, 'sender'||(i%30)||'@invalid', 'rcpt'||(i%7)||'@invalid', 1 + i%3, 's'||i, CASE WHEN i%4=0 THEN 'Originating' ELSE NULL END FROM n;
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,recipient_count,subject)
SELECT time_ms + CASE WHEN id%5=0 THEN 3*86400000 WHEN id%7=0 THEN 3600000 ELSE 2000 END, server, CASE WHEN id%3=0 THEN 'FAIL' WHEN id%11=0 THEN 'SEND' ELSE 'DELIVER' END, message_id, 'd'||id, sender, recipients, recipient_count, subject
FROM message_event WHERE event_id='RECEIVE' AND id%13<>0;
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,remote_ep,helo,mail_from,rcpts)
SELECT time_ms - 500, server, 'Receive', 'x'||id, message_id, CASE WHEN id%9=0 THEN 'Rejected' ELSE 'Accepted' END, '198.51.100.'||(id%40)||':25', 'h'||(id%5), sender, recipients FROM message_event WHERE event_id='RECEIVE' AND id%4=0;
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,remote_ep,helo,mail_from,rcpts)
SELECT $($script:Epoch) + (id*104729 % 432000)*1000, 'EX1', 'Receive', 'o'||id, '<smtp-only'||id||'@invalid>', 'Accepted', '203.0.113.'||(id%20)||':25', 'h', 's@invalid', 'r@invalid' FROM message_event WHERE event_id='RECEIVE' AND id%25=0;
INSERT INTO smtp_transaction(time_ms,server,direction,session_id,message_id,status,remote_ep,helo,mail_from,rcpts)
SELECT $($script:Epoch) + (id*15485863 % 432000)*1000, 'EX2', 'Receive', 'u'||id, NULL, CASE WHEN id%2=0 THEN 'Rejected' ELSE NULL END, NULL, 'h', 's@invalid', 'r@invalid' FROM message_event WHERE event_id='RECEIVE' AND id%30=0;
"@)
            Reconcile $Store
        }
        # The plain predicate of schema 10 (no guard, no scan hint), the reference of the counts and of the list.
        $script:PlainMember = "(EXISTS(SELECT 1 FROM message_event e WHERE e.msg_hash=r.msg_hash AND e.message_id=r.identity COLLATE BINARY AND e.time_ms>=@f AND e.time_ms<@t) OR EXISTS(SELECT 1 FROM smtp_transaction e WHERE e.msg_hash=r.msg_hash AND e.message_id=r.identity COLLATE BINARY AND e.time_ms>=@f AND e.time_ms<@t))"
        $script:PlainSmtp = "EXISTS(SELECT 1 FROM smtp_transaction e WHERE e.id=CAST(r.identity AS INTEGER) AND e.time_ms>=@f AND e.time_ms<@t)"
        $script:PlainWhere = "r.member_last_ms>=@f AND r.member_first_ms<@t AND ((r.kind=0 AND $script:PlainMember) OR (r.kind=1 AND $script:PlainSmtp))"
        function Get-ReferenceCounts($Store, [long]$From, [long]$To) {
            $rows = $Store.Query("SELECT s.text,COUNT(*) FROM message_rollup r JOIN message_rollup_value s ON s.id=r.status WHERE $script:PlainWhere GROUP BY s.text;", @{ f = $From; t = $To }).Rows
            $pairs = foreach ($row in $rows) { [pscustomobject]@{ Name = [string]$row[0]; Count = $row[1] } }
            $names = [string[]]@($pairs | ForEach-Object { $_.Name }); $order = [string[]]$names.Clone(); [Array]::Sort($order, [StringComparer]::Ordinal)
            (@($order | ForEach-Object { $n = $_; "$n=" + (@($pairs | Where-Object { $_.Name -ceq $n })[0].Count) })) -join ';'
        }
        function Get-ReferenceIds($Store, [long]$From, [long]$To) {
            $rows = $Store.Query("SELECT r.id FROM message_rollup r INDEXED BY ix_rollup_last WHERE $script:PlainWhere ORDER BY r.member_last_ms DESC,r.id DESC LIMIT 101;", @{ f = $From; t = $To }).Rows
            @($rows | ForEach-Object { [long]$_[0] })
        }
        function Get-Period([long]$From, [long]$To) { "from=$([Uri]::EscapeDataString([SmtpClientReference]::Iso($From)))&to=$([Uri]::EscapeDataString([SmtpClientReference]::Iso($To)))" }
    }

    It 'stores codes: kind 0/1, dictionary statuses, NULL first/last equal to the member bounds, and a unique (kind, identity)' {
        $s = New-ClientStore 'rollup-codes'
        try {
            Add-MessageFixture $s 400
            Text $s "SELECT sql FROM sqlite_master WHERE name='message_rollup';" | Should -Match 'kind INTEGER NOT NULL CHECK\(kind IN\(0,1\)\)'
            Text $s "SELECT sql FROM sqlite_master WHERE name='message_rollup';" | Should -Match 'status INTEGER NOT NULL'
            Text $s "SELECT sql FROM sqlite_master WHERE name='message_rollup';" | Should -Match 'UNIQUE\(kind,identity\)'
            Scalar $s "SELECT COUNT(*) FROM sqlite_master WHERE name='sqlite_autoindex_message_rollup_1';" | Should -Be 1
            Scalar $s 'SELECT COUNT(*) FROM message_rollup WHERE kind=1;' | Should -BeGreaterThan 0
            Scalar $s 'SELECT COUNT(*) FROM message_rollup WHERE kind=0;' | Should -BeGreaterThan 100
            Scalar $s 'SELECT COUNT(*) FROM message_rollup WHERE first_ms IS NOT NULL AND first_ms=member_first_ms;' | Should -Be 0
            Scalar $s 'SELECT COUNT(*) FROM message_rollup WHERE last_ms IS NOT NULL AND last_ms=member_last_ms;' | Should -Be 0
            Scalar $s 'SELECT COUNT(*) FROM message_rollup WHERE first_ms IS NULL;' | Should -BeGreaterThan 100
            Scalar $s 'SELECT COUNT(*) FROM message_rollup_value;' | Should -BeLessThan 60
            Scalar $s 'SELECT COUNT(*) FROM message_rollup WHERE typeof(kind)<>''integer'' OR typeof(status)<>''integer'' OR (direction IS NOT NULL AND typeof(direction)<>''integer'');' | Should -Be 0
            # The unique constraint is enforced by SQLite itself.
            { $s.Exec("INSERT INTO message_rollup(kind,identity,msg_hash,member_first_ms,member_last_ms,status,recipients,recipient_count,delivered,failed,events_count,smtp_count) SELECT kind,identity,msg_hash,member_first_ms,member_last_ms,status,recipients,recipient_count,delivered,failed,events_count,smtp_count FROM message_rollup LIMIT 1;") } | Should -Throw '*UNIQUE*'
            { $s.Exec("UPDATE message_rollup SET kind=2 WHERE id=1;") } | Should -Throw '*CHECK*'
            $s.VerifyServeRollups().Verified | Should -BeTrue
        } finally { $s.Dispose() }
    }

    It 'resolves the status filter to codes: any letter case, an unknown status, and statuses that differ only by case' {
        $s = New-ClientStore 'rollup-status'
        try {
            Add-MessageFixture $s 1500
            $statuses = @($s.Query('SELECT DISTINCT v.text FROM message_rollup r JOIN message_rollup_value v ON v.id=r.status ORDER BY v.text;', $null).Rows | ForEach-Object { [string]$_[0] })
            $statuses.Count | Should -BeGreaterThan 3
            $hostInfo = Start-ServeTest $s.FilePath
            $period = Get-Period ($script:Epoch - 86400000L) ($script:Epoch + 8 * 86400000L)
            function Get-Ids([string]$Query) {
                $ids = @(); $page = 1
                do {
                    $answer = (Request $hostInfo "/api/messages?$period&size=500&page=$page$Query").Content | ConvertFrom-Json
                    $ids += @($answer.rows | ForEach-Object { [pscustomobject]@{ id = $_.id; status = $_.cells[3] } })
                    $page++
                } while ($answer.hasMore -and $page -le 20)
                ,$ids
            }
            $all = Get-Ids ''
            $all.Count | Should -BeGreaterThan 1000
            foreach ($status in $statuses) {
                $expected = @($all | Where-Object { $_.status -ceq $status } | ForEach-Object { $_.id })
                $expected.Count | Should -BeGreaterThan 0
                foreach ($variant in @($status, $status.ToUpperInvariant(), $status.ToLowerInvariant())) {
                    $got = @((Get-Ids "&status=$([Uri]::EscapeDataString($variant))") | ForEach-Object { $_.id })
                    ($got -join ',') | Should -BeExactly ($expected -join ',') -Because "status filter '$variant'"
                }
            }
            $none = (Request $hostInfo "/api/messages?$period&status=No%20such%20status").Content | ConvertFrom-Json
            $none.rows.Count | Should -Be 0; $none.hasMore | Should -BeFalse
            ((Request $hostInfo "/api/messages?$period&status=No%20such%20status&server=EX1").Content | ConvertFrom-Json).rows.Count | Should -Be 0
            # An exact-code filter reads the ordered status index and needs no sorter.
            $one = [ExchangeLogReport.ServeDiagnostics]::ExplainMessageList($s.FilePath, $script:Epoch - 86400000L, $script:Epoch + 8 * 86400000L, $null, $null, $statuses[0]) | ConvertFrom-Json
            ($one -join "`n") | Should -Match 'ix_rollup_status_last \(status=\?'
            ($one -join "`n") | Should -Not -Match 'TEMP B-TREE'
            # Two texts that differ only by case: both codes are selected (IN list), exactly as the case-insensitive text comparison selected both rows.
            $delivered = $statuses | Where-Object { $_ -ceq 'Delivered' } | Select-Object -First 1
            $delivered | Should -Not -BeNullOrEmpty
            $s.Exec("INSERT INTO message_rollup_value(text) VALUES('delivered'); UPDATE message_rollup SET status=(SELECT id FROM message_rollup_value WHERE text='delivered') WHERE id IN (SELECT id FROM message_rollup WHERE status=(SELECT id FROM message_rollup_value WHERE text='Delivered') ORDER BY id LIMIT 5);")
            $both = @((Get-Ids '&status=DELIVERED') | ForEach-Object { $_.id })
            $lower = @((Get-Ids '&status=delivered') | ForEach-Object { $_.id })
            ($both -join ',') | Should -BeExactly ($lower -join ',')
            $both.Count | Should -Be (@($all | Where-Object { $_.status -ceq 'Delivered' }).Count)
            @((Get-Ids '&status=Delivered')).Count | Should -Be (@($all | Where-Object { $_.status -ceq 'Delivered' }).Count)
            Stop-ServeTest $hostInfo
        } finally { $s.Dispose() }
    }

    It 'counts and lists exactly as the plain predicate does, for narrow, partial and whole periods (guard and sequential scan are only access paths)' {
        $s = New-ClientStore 'rollup-counts'
        try {
            Add-MessageFixture $s 2500
            $s.VerifyServeRollups().Verified | Should -BeTrue
            $hostInfo = Start-ServeTest $s.FilePath
            $rng = [Random]::new(2026)
            $periods = [Collections.Generic.List[object]]::new()
            $periods.Add(@(($script:Epoch - 86400000L), ($script:Epoch + 20 * 86400000L)))           # the whole table
            $periods.Add(@(($script:Epoch + 3600000L), ($script:Epoch + 3600000L + 60000L)))         # one minute
            $periods.Add(@(($script:Epoch), ($script:Epoch + 432000000L)))                           # exactly the span of the receptions
            foreach ($n in 1..120) {
                $a = $script:Epoch + [long]($rng.NextDouble() * 6 * 86400000L)
                $span = @(1000L, 600000L, 3600000L, 86400000L, (2 * 86400000L), (5 * 86400000L))[$rng.Next(6)]
                $periods.Add(@($a, ($a + 1 + [long]($rng.NextDouble() * $span))))
            }
            $checked = 0
            foreach ($p in $periods) {
                $expected = Get-ReferenceCounts $s $p[0] $p[1]
                $answer = (Request $hostInfo "/api/overview/counts?$(Get-Period $p[0] $p[1])").Content | ConvertFrom-Json
                $actual = (@($answer.rows | Where-Object { $_.cells[0] -eq 'Messages' } | ForEach-Object { "$($_.cells[1])=$($_.cells[2])" })) -join ';'
                $actual | Should -BeExactly $expected -Because "counts of $($p -join '..')"
                $ids = @(Get-ReferenceIds $s $p[0] $p[1])
                $list = (Request $hostInfo "/api/messages?$(Get-Period $p[0] $p[1])&size=100").Content | ConvertFrom-Json
                $got = @($list.rows | ForEach-Object { [long]$_.id })
                ($got -join ',') | Should -BeExactly ((@($ids | Select-Object -First 100)) -join ',') -Because "list of $($p -join '..')"
                $list.hasMore | Should -Be ($ids.Count -gt 100)
                if ($expected) { $checked++ }
            }
            $checked | Should -BeGreaterThan 60
            Stop-ServeTest $hostInfo
        } finally { $s.Dispose() }
    }

    It 'keeps the groups of the counts in ordinal order of their status text, with sequential ids' {
        $s = New-ClientStore 'rollup-order'
        try {
            Add-MessageFixture $s 600
            $hostInfo = Start-ServeTest $s.FilePath
            $answer = (Request $hostInfo "/api/overview/counts?$(Get-Period ($script:Epoch - 86400000L) ($script:Epoch + 8 * 86400000L))").Content | ConvertFrom-Json
            $names = @($answer.rows | Where-Object { $_.cells[0] -eq 'Messages' } | ForEach-Object { [string]$_.cells[1] })
            $names.Count | Should -BeGreaterThan 3
            $sorted = [string[]]$names.Clone(); [Array]::Sort($sorted, [StringComparer]::Ordinal)
            ($names -join '|') | Should -BeExactly ($sorted -join '|')
            (@($answer.rows | ForEach-Object { $_.id }) -join ',') | Should -BeExactly ((1..$answer.rows.Count) -join ',')
            Stop-ServeTest $hostInfo
        } finally { $s.Dispose() }
    }
}
