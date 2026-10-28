#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
$product = Get-Content -LiteralPath (Join-Path $root 'product.json') -Raw | ConvertFrom-Json
$runtime = Join-Path $PackageRoot 'powershell'
if ([IO.Path]::GetFullPath($PSHOME).TrimEnd('\') -ine $runtime -or
    $PSVersionTable.PSVersion.ToString() -cne [string]$product.powerShell.version -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64') {
    throw 'Tests must run under the newly packaged, configured x64 PowerShell runtime.'
}
& (Join-Path $PackageRoot 'tools\Test-PackageIntegrity.ps1') -Root $PackageRoot | Out-Null
$env:PATH = $runtime + ';' + $env:PATH
if (-not $env:CI_MODULE_PATH) { throw 'The pinned CI module path is missing.' }
Import-Module (Join-Path $env:CI_MODULE_PATH 'Pester\6.1.0\Pester.psd1') -RequiredVersion 6.1.0 -Force
$testWork = Join-Path $root 'artifacts\ci-test-work'
[void][IO.Directory]::CreateDirectory($testWork)
$env:TEMP = $testWork
$env:TMP = $testWork
$collectorTests = Join-Path $root 'collector\tests'
$serveTests = @(Get-ChildItem -LiteralPath $collectorTests -Filter 'Serve*.Tests.ps1' -File)
if (-not $serveTests.Count) { throw 'The Serve regression tests are required before CI can pass.' }
$configuration = New-PesterConfiguration
$configuration.Run.Path = @(
    $collectorTests
    (Join-Path $root 'tests\PackageIntegrity.Tests.ps1')
    (Join-Path $root 'tests\Workflow.Tests.ps1')
)
$configuration.Run.Container = @(
    New-PesterContainer -Path (Join-Path $root 'tests\LegacyComparison.Tests.ps1') -Data @{
        WorkRoot = Join-Path $testWork ('legacy-comparison-' + [guid]::NewGuid().ToString('N'))
    }
)
$configuration.Run.PassThru = $true
$configuration.Run.Exit = $false
$configuration.Output.Verbosity = 'Normal'
$result = Invoke-Pester -Configuration $configuration
$evidence = Join-Path $root 'artifacts\ci-evidence'
[void][IO.Directory]::CreateDirectory($evidence)
# Do not upload test working directories, databases, ready files, tokens or raw logs.
@{
    result = [string]$result.Result
    passed = $result.PassedCount
    failed = $result.FailedCount
    skipped = $result.SkippedCount
    total = $result.TotalCount
    powerShellVersion = $PSVersionTable.PSVersion.ToString()
    runtime = '.\powershell\pwsh.exe from the freshly built package'
    fixturePolicy = 'Synthetic fixtures only; no lab configuration or source database'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence 'validation-summary.json') -Encoding utf8
if ($result.Result -ne 'Passed' -or $result.FailedCount -gt 0 -or $result.TotalCount -eq 0) {
    throw 'Pester validation did not pass.'
}
