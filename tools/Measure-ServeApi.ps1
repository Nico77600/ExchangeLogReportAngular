#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReadyFile,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory)][datetimeoffset]$From,
    [Parameter(Mandatory)][datetimeoffset]$To,
    [ValidateRange(3, 100)][int]$Iterations = 10,
    [string]$FilterUser,
    [string]$FilterServer,
    [switch]$Synthetic
)
$ErrorActionPreference = 'Stop'
if ($From -ge $To) { throw 'From must precede To.' }
if (Test-Path -LiteralPath $Output) { throw 'Measurement output must be a new file.' }
$ready = Get-Content -LiteralPath $ReadyFile -Raw | ConvertFrom-Json
if ($ready.status -ne 'ready' -or -not $ready.token) { throw 'Authenticated ready-file information is required.' }
$origin = [uri]$ready.url
if ($origin.Host -ne '127.0.0.1' -or $origin.Scheme -ne 'http') { throw 'Only the exact local Serve listener is accepted.' }
$headers = @{ 'X-Portal-Token' = $ready.token }
$query = '?from=' + [uri]::EscapeDataString($From.ToString('o')) + '&to=' + [uri]::EscapeDataString($To.ToString('o')) + '&size=100&page=1'
$selections = @([pscustomobject]@{ name = 'unfiltered'; query = $query })
if ($FilterUser -or $FilterServer) {
    $filtered = $query
    if ($FilterUser) { $filtered += '&user=' + [uri]::EscapeDataString($FilterUser) }
    if ($FilterServer) { $filtered += '&server=' + [uri]::EscapeDataString($FilterServer) }
    $selections += [pscustomobject]@{ name = 'selected-user-server'; query = $filtered }
}
$cases = foreach ($selection in $selections) {
foreach ($view in @('messages', 'sessions', 'smtp/clients')) {
    $measurements = for ($i = 0; $i -lt $Iterations; $i++) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $page = Invoke-RestMethod -Uri ($ready.url.TrimEnd('/') + "/api/$view" + $selection.query) -Headers $headers -TimeoutSec 30
        $watch.Stop()
        [pscustomobject]@{ milliseconds = $watch.Elapsed.TotalMilliseconds; rows = @($page.rows).Count }
    }
    $warm = @($measurements | Select-Object -Skip 1 | ForEach-Object milliseconds | Sort-Object)
    [pscustomobject]@{
        selection = $selection.name
        view = $view
        firstMeasuredMilliseconds = $measurements[0].milliseconds
        warmP95Milliseconds = $warm[[int][Math]::Ceiling($warm.Count * 0.95) - 1]
        maxMilliseconds = ($measurements | Measure-Object milliseconds -Maximum).Maximum
        rows = $measurements[0].rows
        requests = $measurements.Count
    }
}
}
$result = [ordered]@{
    synthetic = [bool]$Synthetic
    osCacheCold = $false
    firstRequestNote = 'First request in this measurement, not necessarily the first request of the process.'
    from = $From.ToString('o')
    to = $To.ToString('o')
    thresholdMilliseconds = 1000
    allMeasuredListsUnderThreshold = @($cases | Where-Object maxMilliseconds -GE 1000).Count -eq 0
    cases = @($cases)
}
$stream = [IO.FileStream]::new([IO.Path]::GetFullPath($Output), [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
try {
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    try { $writer.Write(($result | ConvertTo-Json -Depth 5)) } finally { $writer.Dispose() }
} finally { $stream.Dispose() }
$cases | Format-Table selection, view, firstMeasuredMilliseconds, warmP95Milliseconds, maxMilliseconds, rows
if (-not $result.allMeasuredListsUnderThreshold) { throw 'A measured list exceeded one second; see the saved evidence.' }
