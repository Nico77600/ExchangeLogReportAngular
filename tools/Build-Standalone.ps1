#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'artifacts'),
    [string]$PowerShellArchive
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$product = Get-Content -LiteralPath (Join-Path $root 'product.json') -Raw | ConvertFrom-Json
$documentationImages = @(
    'docs\images\angular-overview.png',
    'docs\images\angular-message-route.png',
    'collector\docs\images\report-smtp-clients.png'
)
$inputFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $root 'collector\src') -File
    Get-ChildItem -LiteralPath (Join-Path $root 'collector\lib\sqlite') -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $root 'host') -File | Where-Object Extension -In '.cs', '.csproj'
    Get-ChildItem -LiteralPath (Join-Path $root 'frontend\src') -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $root 'frontend\contracts') -File
    Get-ChildItem -LiteralPath (Join-Path $root 'frontend\tools') -File
    Get-ChildItem -LiteralPath (Join-Path $root 'frontend') -File -Filter 'tsconfig*.json'
    Get-Item -LiteralPath (Join-Path $root 'frontend\package.json'), (Join-Path $root 'frontend\package-lock.json'),
        (Join-Path $root 'frontend\angular.json'), (Join-Path $root 'product.json'),
        (Join-Path $root 'collector\ExchangeLogReport.psm1'), (Join-Path $root 'collector\ExchangeLogReport.psd1'),
        (Join-Path $root 'collector\Invoke-ExchangeLogReport.ps1'),
        (Join-Path $root 'README.txt'), (Join-Path $root 'SECURITY.md'),
        (Join-Path $root 'PROVENANCE.md'), (Join-Path $root 'CHANGELOG.md'),
        (Join-Path $root 'collector\README.md'),
        (Join-Path $root 'collector\docs\ExchangeLogReport-UserGuide.html'),
        (Join-Path $root 'collector\docs\ExchangeLogReport-Guide.html'),
        (Join-Path $root 'collector\docs\Serve-Guide.txt')
    foreach ($relative in $documentationImages) { Get-Item -LiteralPath (Join-Path $root $relative) }
)
$inputs = @($inputFiles | Sort-Object FullName -Unique | ForEach-Object {
    [pscustomobject]@{ path = $_.FullName.Substring($root.Length + 1); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$name = "$($product.name)-$($product.version)-win-x64"
$destination = Join-Path $OutputRoot $name
$zip = "$destination.zip"
$projectPrefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
$destinationPrefix = [IO.Path]::GetFullPath($destination).TrimEnd('\') + '\'
$artifactsPrefix = (Join-Path $root 'artifacts').TrimEnd('\') + '\'
if ($destinationPrefix.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase) -and
    -not $destinationPrefix.StartsWith($artifactsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Inside the source tree, packages must stay under the ignored artifacts folder.'
}
if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath $zip)) {
    throw "Build destination already exists. Choose a new OutputRoot; existing deliveries are never overwritten: $destination"
}
if (-not (Test-Path -LiteralPath (Join-Path $root 'frontend\node_modules\.bin\ng.cmd'))) {
    throw 'Frontend dependencies are missing. Run npm ci in frontend on the development machine.'
}
Get-Command dotnet, npm.cmd -ErrorAction Stop | Out-Null
$env:NG_CLI_ANALYTICS = 'false'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$cache = Join-Path $root '.cache'
[void][IO.Directory]::CreateDirectory($cache)
$sqliteTool = Join-Path $root 'lib\sqlite-tools\sqlite3.exe'
if (-not (Test-Path -LiteralPath $sqliteTool)) {
    $sqliteArchive = Join-Path $cache "sqlite-tools-$($product.sqliteTools.version)-win-x64.zip"
    if (-not (Test-Path -LiteralPath $sqliteArchive)) {
        Invoke-WebRequest -Uri $product.sqliteTools.url -OutFile $sqliteArchive
    }
    if ((Get-FileHash -LiteralPath $sqliteArchive -Algorithm SHA256).Hash -ne $product.sqliteTools.archiveSha256) {
        throw 'The official SQLite tools archive does not match its pinned SHA256.'
    }
    $sqliteStaging = Join-Path $cache ("sqlite-restore-" + [guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $sqliteArchive -DestinationPath $sqliteStaging
        $executables = @(Get-ChildItem -LiteralPath $sqliteStaging -Filter 'sqlite3.exe' -File -Recurse)
        if ($executables.Count -ne 1) { throw 'Expected exactly one sqlite3.exe in the reviewed archive.' }
        [void][IO.Directory]::CreateDirectory((Split-Path $sqliteTool -Parent))
        Copy-Item -LiteralPath $executables[0].FullName -Destination $sqliteTool
    } finally { if (Test-Path -LiteralPath $sqliteStaging) { Remove-Item -LiteralPath $sqliteStaging -Recurse -Force } }
}
if ((Get-FileHash -LiteralPath $sqliteTool -Algorithm SHA256).Hash -ne $product.sqliteTools.executableSha256) {
    throw 'The SQLite diagnostic executable does not match its pinned SHA256.'
}
if (-not $PowerShellArchive) {
    $PowerShellArchive = Join-Path $cache "PowerShell-$($product.powerShell.version)-win-x64.zip"
    if (-not (Test-Path -LiteralPath $PowerShellArchive)) {
        Invoke-WebRequest -Uri $product.powerShell.url -OutFile $PowerShellArchive
    }
}
if ((Get-FileHash -LiteralPath $PowerShellArchive -Algorithm SHA256).Hash -ne $product.powerShell.sha256) {
    throw 'The portable PowerShell archive does not match its pinned SHA256.'
}
Push-Location (Join-Path $root 'frontend')
try {
    & npm.cmd run build
    if ($LASTEXITCODE -ne 0) { throw "Angular build failed ($LASTEXITCODE)." }
} finally { Pop-Location }
[void][IO.Directory]::CreateDirectory($destination)
& dotnet publish (Join-Path $root 'host\ExchangeLogReportAngular.Host.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=None -p:DebugSymbols=false -o (Join-Path $destination 'host') --verbosity quiet
if ($LASTEXITCODE -ne 0) { throw "Self-contained host publish failed ($LASTEXITCODE)." }
$frontend = Join-Path $root 'frontend\dist\portal\browser'
if (-not (Test-Path -LiteralPath (Join-Path $frontend 'index.html'))) { throw 'Angular output index.html is missing.' }
$wwwroot = Join-Path $destination 'web'
[void][IO.Directory]::CreateDirectory($wwwroot)
Get-ChildItem -LiteralPath $frontend | Copy-Item -Destination $wwwroot -Recurse
$license = Join-Path $root 'frontend\dist\portal\3rdpartylicenses.txt'
if (Test-Path -LiteralPath $license) { Copy-Item -LiteralPath $license -Destination (Join-Path $destination 'Angular-THIRD-PARTY-LICENSES.txt') }
foreach ($relative in $documentationImages) {
    $target = Join-Path $destination $relative
    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $target
}
foreach ($file in @('Start-ExchangeLogReportAngular.cmd', 'Run-Collector.cmd', 'Database-Storage.cmd', 'README.txt', 'SECURITY.md', 'product.json', 'PROVENANCE.md', 'CHANGELOG.md')) {
    Copy-Item -LiteralPath (Join-Path $root $file) -Destination (Join-Path $destination $file)
}
[void][IO.Directory]::CreateDirectory((Join-Path $destination 'tools'))
Copy-Item -LiteralPath (Join-Path $root 'tools\Test-PackageIntegrity.ps1') -Destination (Join-Path $destination 'tools\Test-PackageIntegrity.ps1')
$sqliteDestination = Join-Path $destination 'sqlite-tools'
[void][IO.Directory]::CreateDirectory($sqliteDestination)
Copy-Item -LiteralPath $sqliteTool -Destination (Join-Path $sqliteDestination 'sqlite3.exe')
Copy-Item -LiteralPath (Join-Path $root 'lib\sqlite-tools\NOTICE.txt') -Destination (Join-Path $sqliteDestination 'NOTICE.txt')
$collector = Join-Path $root 'collector'
$runtimeFiles = @('Invoke-ExchangeLogReport.ps1', 'ExchangeLogReport.psd1', 'ExchangeLogReport.psm1', 'README.md', 'THIRD-PARTY-NOTICES.md',
    'config\ExchangeLogReport.config.psd1', 'templates\Report.template.html',
    'docs\ExchangeLogReport-UserGuide.html', 'docs\ExchangeLogReport-Guide.html', 'docs\Serve-Guide.txt')
foreach ($folder in @('src', 'lib\sqlite')) {
    $runtimeFiles += Get-ChildItem -LiteralPath (Join-Path $collector $folder) -Recurse -File |
        ForEach-Object { $_.FullName.Substring($collector.Length + 1) }
}
foreach ($file in $runtimeFiles) {
    $target = Join-Path $destination "collector\$file"
    [void][IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    Copy-Item -LiteralPath (Join-Path $collector $file) -Destination $target
}
$config = Import-PowerShellDataFile -LiteralPath (Join-Path $destination 'collector\config\ExchangeLogReport.config.psd1')
if (($config.Servers.Name -join ',') -ne 'EXCH01,EXCH02' -or $config.Mail.Enabled -or $config.Mail.SmtpServer -or
    $config.Mail.From -or @($config.Mail.To).Count -or @($config.Mail.Cc).Count -or $config.Mail.CertificateThumbprint) {
    throw 'The package configuration is not the reviewed empty/example configuration.'
}
Expand-Archive -LiteralPath $PowerShellArchive -DestinationPath (Join-Path $destination 'powershell')
Get-ChildItem -LiteralPath (Join-Path $destination 'powershell') -Filter '*.pdb' -Recurse -File | Remove-Item
$powerShellExe = Join-Path $destination 'powershell\pwsh.exe'
$signature = Get-AuthenticodeSignature -LiteralPath $powerShellExe
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw "The pinned PowerShell executable signature is not valid Microsoft Authenticode: $($signature.Status)"
}
& $powerShellExe -NoLogo -NoProfile -Command 'if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne "X64") { exit 1 }; $PSVersionTable.PSVersion.ToString()'
if ($LASTEXITCODE -ne 0) { throw 'The bundled PowerShell executable did not start correctly.' }
$prohibited = @(Get-ChildItem -LiteralPath $destination -Recurse -File | Where-Object {
    $_.Name -match '\.(sqlite(?:-.*)?|db|log|credential|pdb)$' -or $_.Name -like '*.paths.psd1'
})
if ($prohibited.Count) { throw "Runtime/private files found in package: $($prohibited.Name -join ', ')" }
foreach ($required in @('host\ExchangeLogReportAngular.exe', 'web\index.html', 'powershell\pwsh.exe', 'Run-Collector.cmd', 'Database-Storage.cmd', 'sqlite-tools\sqlite3.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $destination $required))) { throw "Required package file missing: $required" }
}
foreach ($inputFile in $inputs) {
    if ((Get-FileHash -LiteralPath (Join-Path $root $inputFile.path) -Algorithm SHA256).Hash -ne $inputFile.sha256) {
        throw "Source changed during packaging; do not distribute this incomplete output: $($inputFile.path)"
    }
}
$inputs | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $destination 'BUILD-INPUTS.sha256.json') -Encoding utf8
$immutable = @(Get-ChildItem -LiteralPath $destination -Recurse -File | Sort-Object FullName | Where-Object {
    $_.FullName.Substring($destination.Length + 1) -ne 'collector\config\ExchangeLogReport.config.psd1'
} | ForEach-Object {
    [ordered]@{
        path = $_.FullName.Substring($destination.Length + 1)
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
[ordered]@{
    schemaVersion = 1
    name = $product.name
    version = $product.version
    authenticatedPublisher = $false
    mutableConfiguration = @('collector\config\ExchangeLogReport.config.psd1')
    files = $immutable
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $destination 'PackageIntegrity.json') -Encoding utf8
& (Join-Path $destination 'tools\Test-PackageIntegrity.ps1') -Root $destination | Out-Null
$files = @(Get-ChildItem -LiteralPath $destination -Recurse -File | Sort-Object FullName | ForEach-Object {
    [pscustomobject]@{
        path = $_.FullName.Substring($destination.Length + 1)
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$files | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $destination 'FILES.sha256.json') -Encoding utf8
Compress-Archive -LiteralPath $destination -DestinationPath $zip -CompressionLevel Optimal
[pscustomobject]@{
    Package = $destination
    Zip = $zip
    ZipBytes = (Get-Item -LiteralPath $zip).Length
    ZipSha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    Files = $files.Count
    Signed = $false
    Published = $false
} | ConvertTo-Json
