#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SyntheticSeed,
    [Parameter(Mandatory)][string]$Destination,
    [ValidateRange(100, 2000000)][int]$Messages = 20000
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sqlite = Join-Path $root 'lib\sqlite-tools\sqlite3.exe'
$SyntheticSeed = [IO.Path]::GetFullPath($SyntheticSeed)
$Destination = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw 'The synthetic benchmark destination must not exist.' }
if (-not (Test-Path -LiteralPath $sqlite)) { throw 'The pinned SQLite CLI is missing.' }
$product = Get-Content -LiteralPath (Join-Path $root 'product.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $sqlite -Algorithm SHA256).Hash -ne $product.sqliteTools.executableSha256) {
    throw 'SQLite CLI hash mismatch.'
}
# Only a synthetic fixture produced by the project can seed this benchmark.
$fixture = Join-Path (Split-Path $SyntheticSeed -Parent) 'synthetic.config.psd1'
if (-not (Test-Path -LiteralPath $fixture)) { throw 'A synthetic fixture configuration is required.' }
$configuration = Import-PowerShellDataFile -LiteralPath $fixture
if (@($configuration.Servers.Name | Where-Object { $_ -notmatch '^DEMO0[123]$' }).Count -or
    @($configuration.Servers).Count -ne 3) { throw 'This helper accepts only the three-server synthetic fixture.' }
$schema = & $sqlite -safe -init NUL -readonly -batch $SyntheticSeed "SELECT value FROM metadata WHERE key='schema_version';"
if ($LASTEXITCODE -or $schema -ne '6') { throw 'Use a frozen schema-6 synthetic fixture to measure the 6-to-7 change.' }
[void][IO.Directory]::CreateDirectory((Split-Path $Destination -Parent))
$beforeHash = (Get-FileHash -LiteralPath $SyntheticSeed -Algorithm SHA256).Hash
$sourceGuard = [IO.FileStream]::new($SyntheticSeed, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    $copySql = "VACUUM INTO '" + $Destination.Replace("'", "''") + "';"
    & $sqlite -init NUL -readonly -batch $SyntheticSeed $copySql
    if ($LASTEXITCODE) { throw 'Could not create the new synthetic benchmark database.' }
} finally { $sourceGuard.Dispose() }
$sql = @"
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
BEGIN;
WITH RECURSIVE seq(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<$Messages),
events(k) AS (VALUES(0),(1),(2))
INSERT INTO message_event(time_ms,server,event_id,source,message_id,internal_id,sender,recipients,
recipient_status,recipient_count,total_bytes,subject,client_ip,server_host,connector,directionality,log_id)
SELECT 1792022400000+n*1000+k*100,'BENCH01',
CASE k WHEN 0 THEN 'RECEIVE' WHEN 1 THEN 'TRANSFER' ELSE 'DELIVER' END,'SMTP',
'<storage-benchmark-only-long-message-identifier-'||printf('%012d',n)||'@synthetic-only.example.invalid>',
'benchmark-internal-'||printf('%012d',n),'sender@synthetic-only.example.invalid',
'recipient@synthetic-only.example.invalid','250 2.1.5',1,76800,
'Synthetic storage benchmark - no client data','192.0.2.10','BENCH01',
'Synthetic receive connector','Incoming','storage-benchmark-'||n||'-'||k
FROM seq CROSS JOIN events;
WITH RECURSIVE seq(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<$Messages)
INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,role,connector,session_id,
local_ep,remote_ep,helo,tls,auth,mail_from,rcpt_count,rcpts,message_id,internal_id,status,response,transcript)
SELECT 1792022400000+n*1000,1792022400100+n*1000,'BENCH01','Receive','Hub','Synthetic receive connector',
'storage-benchmark-session-'||n,'192.0.2.20:25','192.0.2.10:40000','synthetic-only.example.invalid','TLS1.3','Anonymous',
'sender@synthetic-only.example.invalid',1,'recipient@synthetic-only.example.invalid',
'<storage-benchmark-only-long-message-identifier-'||printf('%012d',n)||'@synthetic-only.example.invalid>',
'benchmark-internal-'||printf('%012d',n),'Success','250 2.0.0 Queued',NULL
FROM seq;
WITH RECURSIVE seq(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<$Messages)
INSERT INTO access_event(time_ms,server,source,protocol,user,mailbox,client_ip,user_agent,method,url,action,
status,backend_status,duration_ms,outcome,request_id,errors)
SELECT 1792022400000+n*1000,'BENCH01','HttpProxy','Ews','SYNTHETIC\benchmark',
'benchmark@synthetic-only.example.invalid','192.0.2.10','Synthetic benchmark client','POST',
'/EWS/Exchange.asmx?synthetic='||replace(printf('%0064d',0),'0','repeated-value-'),
'FindItem',500,500,32,'Failure','synthetic-storage-request-'||n,
'Synthetic error context: '||replace(printf('%0064d',0),'0','repeated-error-')
FROM seq;
DELETE FROM message_event WHERE server='BENCH01' AND id%7=0;
DELETE FROM smtp_transaction WHERE server='BENCH01' AND id%7=0;
DELETE FROM access_event WHERE server='BENCH01' AND id%7=0;
COMMIT;
PRAGMA wal_checkpoint(TRUNCATE);
PRAGMA journal_mode=DELETE;
"@
& $sqlite -init NUL -batch -bail $Destination $sql | Out-Null
if ($LASTEXITCODE) { throw 'Synthetic benchmark population failed.' }
if ((Get-FileHash -LiteralPath $SyntheticSeed -Algorithm SHA256).Hash -ne $beforeHash) { throw 'Synthetic seed bytes changed.' }
$measurementSql = @'
SELECT name,SUM(pgsize) AS bytes,SUM(unused) AS unused_bytes FROM dbstat GROUP BY name ORDER BY bytes DESC;
PRAGMA freelist_count;
PRAGMA page_count;
PRAGMA page_size;
'@
$measurement = & $sqlite -safe -init NUL -readonly -batch -json $Destination $measurementSql
if ($LASTEXITCODE) { throw 'Synthetic baseline measurement failed.' }
[pscustomobject]@{
    Synthetic = $true
    Database = $Destination
    GeneratedMessageIdentities = $Messages
    GeneratedEventsBeforeFragmentation = $Messages * 3
    Purpose = 'Controlled long message identifiers and repetitive URL/error text; not representative client sizing.'
    Bytes = (Get-Item -LiteralPath $Destination).Length
    BaselineDbstat = $measurement -join "`n"
} | ConvertTo-Json -Depth 4
