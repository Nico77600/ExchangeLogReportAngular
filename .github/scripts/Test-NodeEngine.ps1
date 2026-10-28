#Requires -Version 7.4
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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
