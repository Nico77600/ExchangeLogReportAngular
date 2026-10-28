#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Evidence)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'ExchangeLogReport.psd1') -Force
Initialize-ExlEngine
if(-not('AggregateProbe' -as [type])){
    Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @'
using System;
using Microsoft.Data.Sqlite;
public static class AggregateProbe {
    public static void Register(SqliteConnection db) {
        db.CreateFunction<string,string>("exl_remote_host", s => {
            if(string.IsNullOrWhiteSpace(s)) return null;
            s=s.Trim();
            if(s.StartsWith("[")) { int n=s.IndexOf(']'); return (n>0?s.Substring(1,n-1):s).ToLowerInvariant(); }
            int c=s.LastIndexOf(':');
            return (c>0&&s.IndexOf(':')==c?s.Substring(0,c):s).ToLowerInvariant();
        },isDeterministic:true);
    }
}
'@ -ReferencedAssemblies @((Join-Path $root 'lib\sqlite\Microsoft.Data.Sqlite.dll'),'System.Runtime','System.Data.Common','System.ComponentModel.Primitives','System.Linq.Expressions','netstandard')
}
$e=Get-Content -LiteralPath $Evidence -Raw|ConvertFrom-Json
$hour='e.time_ms-((e.time_ms%3600000+3600000)%3600000)'
$auth="CASE WHEN e.auth_source='Overflow' THEN NULL ELSE e.auth_user END"
$clientHost='exl_remote_host(e.remote_ep)'
$where='e.time_ms>=@f AND e.time_ms<@t'
$group=@"
SELECT MIN(e.id),MIN(e.time_ms),MAX(e.time_ms),e.server,e.direction,e.role,e.connector,$clientHost,e.helo,$auth,COUNT(*),
SUM(CASE WHEN e.status='Accepted' THEN 1 ELSE 0 END),SUM(CASE WHEN e.status='Rejected' THEN 1 ELSE 0 END),
SUM(CASE WHEN e.status='Deferred' THEN 1 ELSE 0 END),SUM(e.status IS NULL OR e.status NOT IN('Accepted','Rejected','Deferred')),
SUM(COALESCE(e.rcpt_count,0)),json_group_array(DISTINCT e.tls),json_group_array(DISTINCT e.auth_mechanism),
json_group_array(DISTINCT e.auth_result),json_group_array(DISTINCT e.auth_attempt_result),json_group_array(DISTINCT e.auth_source),SUM(($auth) IS NULL)
FROM smtp_transaction e WHERE $where
GROUP BY e.server COLLATE NOCASE,e.direction,e.role,e.connector,$clientHost,e.helo,$auth,CASE WHEN $clientHost IS NULL THEN e.id END
ORDER BY MAX(e.time_ms) DESC,MIN(e.id) DESC LIMIT 101;
"@
$overview=@"
SELECT hour,server,SUM(tracking),SUM(messages),SUM(smtp),SUM(accepted),SUM(rejected),SUM(deferred),SUM(incomplete),SUM(access) FROM(
SELECT $hour hour,e.server server,COUNT(*) tracking,COUNT(DISTINCT e.message_id COLLATE BINARY) messages,0 smtp,0 accepted,0 rejected,0 deferred,0 incomplete,0 access
FROM message_event e WHERE $where GROUP BY hour,e.server COLLATE NOCASE
UNION ALL SELECT $hour,e.server,0,0,COUNT(*),SUM(CASE WHEN e.status='Accepted' THEN 1 ELSE 0 END),SUM(CASE WHEN e.status='Rejected' THEN 1 ELSE 0 END),
SUM(CASE WHEN e.status='Deferred' THEN 1 ELSE 0 END),SUM(CASE WHEN e.status IS NULL OR e.status NOT IN('Accepted','Rejected','Deferred') THEN 1 ELSE 0 END),0
FROM smtp_transaction e WHERE $where GROUP BY 1,e.server COLLATE NOCASE
UNION ALL SELECT $hour,e.server,0,0,0,0,0,0,0,COUNT(*) FROM access_event e WHERE $where GROUP BY 1,e.server COLLATE NOCASE
) GROUP BY hour,server COLLATE NOCASE ORDER BY hour DESC,server COLLATE NOCASE LIMIT 10001;
"@
$out=@()
foreach($case in @(@{name='smtpClients';sql=$group},@{name='hourlyOverview';sql=$overview})){
    $samples=@();$plan=@();$rows=0
    foreach($n in -1,0,1,2){
        $db=[Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$($e.fixture);Mode=ReadOnly;Pooling=False;Cache=Private")
        $db.Open()
        try{
            [AggregateProbe]::Register($db)
            $c=$db.CreateCommand()
            $c.CommandText='PRAGMA query_only=ON;PRAGMA cache_size=-16384;PRAGMA temp_store=FILE;PRAGMA mmap_size=0;'
            [void]$c.ExecuteNonQuery()
            $c.CommandText=if($n -eq -1){'EXPLAIN QUERY PLAN '+$case.sql}else{$case.sql}
            [void]$c.Parameters.AddWithValue('@f',$e.schema7LegacySelection.from)
            [void]$c.Parameters.AddWithValue('@t',$e.schema7LegacySelection.to)
            $clock=[Diagnostics.Stopwatch]::StartNew();$r=$c.ExecuteReader();$count=0
            while($r.Read()){
                if($n -eq -1){$plan+=$r.GetString(3)}
                else{for($i=0;$i -lt $r.FieldCount;$i++){[void]$r.GetValue($i)};$count++}
            }
            $r.Dispose()
            if($n -ne -1){$samples+=$clock.Elapsed.TotalMilliseconds;$rows=$count}
            $c.Dispose()
        }finally{$db.Dispose()}
    }
    $out+=[ordered]@{name=$case.name;samplesMs=$samples;rows=$rows;plan=$plan}
}
$output=Join-Path $root 'bin\t\serve-client-hourly-plans.json'
$out|ConvertTo-Json -Depth 7|Set-Content -LiteralPath $output -Encoding utf8
$out|ForEach-Object{[pscustomobject]@{name=$_.name;milliseconds=($_.samplesMs -join ',');rows=$_.rows}}|Format-Table -AutoSize
