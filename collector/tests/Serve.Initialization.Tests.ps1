#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0' }

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Module = Import-Module (Join-Path $script:Root 'ExchangeLogReport.psd1') -Force -PassThru
    $script:Work = Join-Path $script:Root ('bin\t\i' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($script:Work)
    function Invoke-ServeChild([string]$Code) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
        $output = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -EncodedCommand $encoded 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
        return $output -join "`n"
    }
    function Write-TestVerifier([string]$Code) {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:Package 'tools'))
        [IO.File]::WriteAllText((Join-Path $script:Package 'PackageIntegrity.json'), '{}')
        [IO.File]::WriteAllText((Join-Path $script:Package 'tools\Test-PackageIntegrity.ps1'), $Code)
    }
}

AfterAll {
    & $script:Module { param($Root) $script:ToolRoot = $Root } $script:Root
    if ($script:Work) { Remove-Item -LiteralPath $script:Work -Recurse -Force }
}

Describe 'Serve package preflight' {
    BeforeEach {
        $script:Package = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 8))
        [void][IO.Directory]::CreateDirectory((Join-Path $script:Package 'collector'))
        & $script:Module { param($Root) $script:ToolRoot = $Root } (Join-Path $script:Package 'collector')
        Mock Initialize-ExlEngine -ModuleName ExchangeLogReport { throw 'initialize-sentinel' }
    }
    AfterEach {
        & $script:Module { param($Root) $script:ToolRoot = $Root } $script:Root
    }
    It 'requires explicit development acknowledgement when the manifest is absent' {
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -NoBrowser } | Should -Throw '*DevelopmentMode*'
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 0 -Exactly
    }
    It 'permits an explicitly acknowledged source checkout before initializing the engine' {
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -NoBrowser -DevelopmentMode -WarningAction SilentlyContinue } | Should -Throw '*initialize-sentinel*'
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 1 -Exactly
    }
    It 'does not let development mode bypass a present manifest with a missing verifier' {
        [IO.File]::WriteAllText((Join-Path $script:Package 'PackageIntegrity.json'), '{}')
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -DevelopmentMode -NoBrowser } | Should -Throw '*verifier is missing*'
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 0 -Exactly
    }
    It 'does not interpret a manifest directory as an unmanifested development checkout' {
        [void][IO.Directory]::CreateDirectory((Join-Path $script:Package 'PackageIntegrity.json'))
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -DevelopmentMode -NoBrowser } | Should -Throw '*must be a file*'
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 0 -Exactly
    }
    It 'fails before initialization when the package verifier rejects its bytes' {
        Write-TestVerifier 'param($Root) throw "synthetic-integrity-rejected"'
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -DevelopmentMode -NoBrowser } | Should -Throw '*synthetic-integrity-rejected*'
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 0 -Exactly
    }
    It 'requires one explicit successful verifier result rather than trusting an exit or arbitrary output' {
        foreach ($code in @('', '[pscustomobject]@{Integrity="Failed"}', '"Passed"', '[pscustomobject]@{Integrity="Passed"}; "extra"')) {
            Write-TestVerifier ("param(`$Root) $code")
            { Start-ExlServe -DatabasePath 'synthetic.sqlite' -NoBrowser } | Should -Throw '*did not return an explicit Passed*'
        }
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 0 -Exactly
    }
    It 'passes the portable root to its verifier and completes verification before initialization' {
        Write-TestVerifier 'param($Root) [IO.File]::WriteAllText((Join-Path $Root "verified"),"yes"); [pscustomobject]@{Integrity="Passed";AuthenticatedPublisher=$false}'
        { Start-ExlServe -DatabasePath 'synthetic.sqlite' -NoBrowser } | Should -Throw '*initialize-sentinel*'
        Get-Content -LiteralPath (Join-Path $script:Package 'verified') -Raw | Should -BeExactly 'yes'
        Should -Invoke Initialize-ExlEngine -ModuleName ExchangeLogReport -Times 1 -Exactly
    }
}

Describe 'In-memory engine initialization' {
    It 'verifies a present package manifest before loading SQLite or reusing any engine' {
        $package = Join-Path $script:Work 'direct'
        [void][IO.Directory]::CreateDirectory((Join-Path $package 'collector'))
        [void][IO.Directory]::CreateDirectory((Join-Path $package 'tools'))
        [IO.File]::WriteAllText((Join-Path $package 'PackageIntegrity.json'), '{}')
        [IO.File]::WriteAllText((Join-Path $package 'tools\Test-PackageIntegrity.ps1'), 'param($Root) throw "direct-integrity-rejected"')
        foreach ($root in @((Join-Path $package 'collector'), (Join-Path $package 'collector\'))) {
            { Initialize-ExlEngine -Root $root } | Should -Throw '*direct-integrity-rejected*'
        }
    }
    It 'ignores an untrusted hash-named cache and does not emit any executable engine cache' {
        $sources = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'src') -Filter 'Engine.*.cs' -File | Sort-Object Name)
        $text = [Text.StringBuilder]::new()
        foreach ($file in $sources) { [void]$text.Append($file.Name).Append((Get-FileHash -LiteralPath $file.FullName).Hash) }
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text.ToString())))
        $cache = Join-Path $script:Root ('bin\ExchangeLogReport.Engine.' + $hash.Substring(0,16) + '.dll')
        $created = $false
        try {
            if (-not (Test-Path -LiteralPath $cache)) {
                $file = [IO.File]::Open($cache, [IO.FileMode]::CreateNew)
                try { $file.Write([Text.Encoding]::UTF8.GetBytes('Untrusted synthetic cache: never load this file.')) } finally { $file.Dispose() }
                $created = $true
            }
            $before = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'bin') -File -Filter '*.dll' | ForEach-Object Name)
            $module = (Join-Path $script:Root 'ExchangeLogReport.psd1').Replace("'", "''")
            $code = "`$ErrorActionPreference='Stop'; Import-Module '$module'; Initialize-ExlEngine; Initialize-ExlEngine; if([ExchangeLogReport.Store].Assembly.Location){throw 'Disk engine was loaded'}; 'ENGINE_IN_MEMORY'"
            Invoke-ServeChild $code | Should -Match 'ENGINE_IN_MEMORY'
            @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'bin') -File -Filter '*.dll' | ForEach-Object Name) -join ';' | Should -BeExactly ($before -join ';')
        } finally { if ($created) { Remove-Item -LiteralPath $cache -Force } }
    }
    It 'rejects an already loaded file-backed engine instead of trusting its type name' {
        $dll = (Join-Path $script:Work 'preloaded.dll').Replace("'", "''")
        $module = (Join-Path $script:Root 'ExchangeLogReport.psd1').Replace("'", "''")
        $code = @"
`$ErrorActionPreference='Stop'
Add-Type -TypeDefinition 'namespace ExchangeLogReport { public class Store {} }' -OutputAssembly '$dll'
Add-Type -LiteralPath '$dll'
Import-Module '$module'
try { Initialize-ExlEngine; throw 'Unexpected reuse' }
catch { if(`$_.Exception.Message -notlike '*engine from disk*'){throw}; 'REJECTED_PRELOADED_DISK' }
"@
        Invoke-ServeChild $code | Should -Match 'REJECTED_PRELOADED_DISK'
    }
}
