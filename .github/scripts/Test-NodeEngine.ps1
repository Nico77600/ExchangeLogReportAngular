#Requires -Version 7.4
[CmdletBinding()]
param([switch]$UseRunnerToolCache)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-CachedNode24Directory([Parameter(Mandatory)][string]$ToolCacheRoot) {
    $cache = Join-Path $ToolCacheRoot 'node'
    if (-not (Test-Path -LiteralPath $cache -PathType Container)) {
        throw 'The runner Node tool cache is missing; no runtime will be downloaded.'
    }
    $versions = @(Get-ChildItem -LiteralPath $cache -Directory |
        Where-Object Name -Match '^24\.\d+\.\d+$' |
        Sort-Object { [version]$_.Name } -Descending)
    if (-not $versions.Count) {
        throw 'The runner has no cached stable Node 24; review the image rather than bypassing the engine requirement.'
    }
    $directory = Join-Path $versions[0].FullName 'x64'
    foreach ($name in 'node.exe', 'npm.cmd') {
        if (-not (Test-Path -LiteralPath (Join-Path $directory $name) -PathType Leaf)) {
            throw "The selected cached Node 24 is incomplete: $name. No fallback or download is allowed."
        }
    }
    return $directory
}
$nodeDirectory = $null
if ($UseRunnerToolCache) {
    if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or
        [string]::IsNullOrWhiteSpace($env:RUNNER_TOOL_CACHE) -or [string]::IsNullOrWhiteSpace($env:GITHUB_PATH)) {
        throw 'Explicit runner-cache selection requires the Windows GitHub Actions environment.'
    }
    $nodeDirectory = Get-CachedNode24Directory -ToolCacheRoot $env:RUNNER_TOOL_CACHE
    $env:PATH = $nodeDirectory + ';' + $env:PATH
}
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$npm = Get-Command npm.cmd -ErrorAction Stop
# Use npm's already-installed range evaluator, not an npm install/exec download.
$semver = Join-Path (Split-Path $npm.Source -Parent) 'node_modules\npm\node_modules\semver'
if (-not (Test-Path -LiteralPath $semver -PathType Container)) {
    throw 'The preinstalled npm semver library is missing; review the runner image rather than installing another tool.'
}
$script = @'
const fs = require('node:fs');
const path = require('node:path');
const semver = require(process.argv[1]);
const root = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'frontend', 'package.json'), 'utf8'));
const lock = JSON.parse(fs.readFileSync(path.join(root, 'frontend', 'package-lock.json'), 'utf8'));
if (semver.major(process.version) !== 24) {
  throw new Error(`The reviewed pilot CI requires preinstalled Node 24; found ${process.version}`);
}
const ranges = [
  ['frontend engines.node', pkg.engines?.node],
  ['lockfile root engines.node', lock.packages?.['']?.engines?.node],
  ['locked Angular CLI engines.node', lock.packages?.['node_modules/@angular/cli']?.engines?.node]
];
for (const [label, range] of ranges) {
  if (typeof range !== 'string' || !semver.validRange(range) || !semver.satisfies(process.version, range)) {
    throw new Error(`${process.version} does not satisfy ${label}: ${String(range)}`);
  }
}
if (pkg.engines.node !== lock.packages[''].engines.node || pkg.version !== lock.packages[''].version) {
  throw new Error('The committed package-lock root metadata must match package.json');
}
console.log(`Preinstalled Node ${process.version} satisfies project and locked Angular CLI engines.`);
'@
& node -e $script $semver $root
if ($LASTEXITCODE -ne 0) { throw 'Node engine preflight failed. No npm command was run.' }
if ($UseRunnerToolCache) {
    Add-Content -LiteralPath $env:GITHUB_PATH -Value $nodeDirectory -Encoding utf8
}
