#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$Destination = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $Destination) { throw 'Use a new empty destination for synthetic demonstration data.' }
[void][IO.Directory]::CreateDirectory($Destination)
$logs = Join-Path $Destination 'synthetic-logs'
& (Join-Path $PSScriptRoot 'support\New-ExlSyntheticLogs.ps1') -Path $logs -Server DEMO01, DEMO02, DEMO03 -Days 2 -Scale 0.001 -Users 40 -Profile Decommission
$quoted = { param([string]$Value) "'" + $Value.Replace("'", "''") + "'" }
$servers = foreach ($server in @('DEMO01', 'DEMO02', 'DEMO03')) {
    "@{ Name = '$server'; Role = 'Mailbox'; ExchangePath = $(& $quoted (Join-Path $logs "$server\Exchange")); IisLogPath = $(& $quoted (Join-Path $logs "$server\inetpub\logs\LogFiles")) }"
}
$database = Join-Path $Destination 'ExchangeLogReport.sqlite'
$defaults = Import-PowerShellDataFile -LiteralPath (Join-Path $root 'collector\config\ExchangeLogReport.config.psd1')
$noise = foreach ($entry in $defaults.Noise.GetEnumerator() | Sort-Object Key) {
    $items = @($entry.Value | ForEach-Object { & $quoted ([string]$_) })
    "$($entry.Key) = @($($items -join ','))"
}
$config = @"
@{
    Servers = @($($servers -join ','))
    Sources = @{}
    Noise = @{ $($noise -join "`n") }
    Collection = @{ StaleSourceHours = 0 }
    Storage = @{ DatabasePath = $(& $quoted $database) }
    Report = @{ OutputPath = $(& $quoted (Join-Path $Destination 'legacy-baseline')); Formats = @('Csv','Html') }
    Logging = @{ Path = $(& $quoted (Join-Path $Destination 'logs')) }
    Mail = @{ Enabled = `$false }
}
"@
$configPath = Join-Path $Destination 'synthetic.config.psd1'
[IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))
Import-Module (Join-Path $root 'collector\ExchangeLogReport.psd1') -Force
Initialize-ExlEngine -Root (Join-Path $root 'collector')
$settings = Import-ExlConfiguration -Path $configPath -Root (Join-Path $root 'collector')
# Bypass infrastructure discovery entirely; every source must remain under the synthetic root.
foreach ($server in $settings.Servers) {
    foreach ($source in Get-ExlSources -Server $server -Settings $settings) {
        $folder = [IO.Path]::GetFullPath($source.Folder)
        if (-not $folder.StartsWith($logs.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Synthetic fixture attempted an external source: $folder"
        }
    }
}
$store = Open-ExlStore -Settings $settings
try {
    $runId = $store.StartRun('Collect', 'SYNTHETIC', 'SYNTHETIC', '2.0.1')
    $collection = Invoke-ExlCollection -Store $store -Settings $settings -RunId $runId
    if ($collection.Errors -or $collection.Unreachable.Count) { throw 'Synthetic collection did not complete.' }
    $store.EndRun($runId, 'Completed', $collection.Files, $collection.Bytes, $collection.Lines, $collection.Kept, $collection.Noise, $null)
} finally { $store.Dispose() }
[pscustomobject]@{
    Database = $database
    Config = $configPath
    Synthetic = $true
    CollectionErrors = $collection.Errors
} | ConvertTo-Json
