#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or -not $env:GITHUB_ENV) {
    throw 'Module download is permitted only on the disposable GitHub Actions runner.'
}
if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
    throw 'PSGallery is not registered. Review the runner configuration; no repository is registered automatically.'
}
if (Test-Path -LiteralPath $Destination) { throw 'Use a new module destination.' }
Save-Module -Name Pester -RequiredVersion 6.1.0 -Repository PSGallery -Path $Destination -ErrorAction Stop
$manifest = Join-Path $Destination 'Pester\6.1.0\Pester.psd1'
if ((Import-PowerShellDataFile -LiteralPath $manifest).ModuleVersion -cne '6.1.0') {
    throw 'The downloaded Pester manifest does not match the exact version pin.'
}
$moduleRoot = Split-Path $manifest -Parent
$evidence = Join-Path $PSScriptRoot '..\..\artifacts\ci-evidence'
[void][IO.Directory]::CreateDirectory($evidence)
@{
    name = 'Pester'
    version = '6.1.0'
    hashPurpose = 'Observed downloaded-file inventory, not an independently trusted package checksum'
    files = @(Get-ChildItem -LiteralPath $moduleRoot -File -Recurse | Sort-Object FullName | ForEach-Object {
        @{
            path = $_.FullName.Substring($moduleRoot.Length + 1).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidence 'module-inventory.json') -Encoding utf8
'CI_MODULE_PATH={0}' -f [IO.Path]::GetFullPath($Destination) |
    Out-File -LiteralPath $env:GITHUB_ENV -Encoding utf8 -Append
