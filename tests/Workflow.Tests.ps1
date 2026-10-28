#Requires -Version 7.4
BeforeAll {
    Set-StrictMode -Version Latest
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Workflows = Join-Path $script:Root '.github\workflows'
    $script:Ci = Get-Content -LiteralPath (Join-Path $script:Workflows 'ci.yml') -Raw | ConvertFrom-Json
    $script:Codeql = Get-Content -LiteralPath (Join-Path $script:Workflows 'codeql.yml') -Raw | ConvertFrom-Json
    $script:Attestation = Get-Content -LiteralPath (Join-Path $script:Workflows 'attest-release.yml') -Raw
    $tokens = $null
    $errors = $null
    $preflightAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $script:Root '.github\scripts\Test-NodeEngine.ps1'), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Node engine helper does not parse.' }
    $selector = $preflightAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-CachedNode24Directory'
    }, $true)
    if ($null -eq $selector) { throw 'The cached Node 24 selector is missing.' }
    . ([scriptblock]::Create($selector.Extent.Text))
    function New-CachedNodeFixture([string]$Root, [string]$Version) {
        $directory = Join-Path $Root "node\$Version\x64"
        [void][IO.Directory]::CreateDirectory($directory)
        foreach ($name in 'node.exe', 'npm.cmd') {
            [IO.File]::WriteAllText((Join-Path $directory $name), 'synthetic-only, never executed')
        }
        return $directory
    }
}

Describe 'Public pilot workflow contracts' {
    It 'declares the public target without claiming a published release' {
        $product = Get-Content -LiteralPath (Join-Path $script:Root 'product.json') -Raw | ConvertFrom-Json
        $product.visibility | Should -BeExactly 'public'
        $product.status | Should -BeExactly 'experimental-local-pilot'
    }

    It 'locks public npm archive origins without development feed identities or credentials' {
        $lock = Get-Content -LiteralPath (Join-Path $script:Root 'frontend\package-lock.json') -Raw | ConvertFrom-Json -AsHashtable
        $resolvedCount = 0
        foreach ($key in $lock.packages.Keys) {
            $entry = $lock.packages[$key]
            if (-not $entry.ContainsKey('resolved')) { continue }
            $uri = [Uri]$entry.resolved
            $uri.Scheme | Should -BeExactly 'https'
            $uri.Host | Should -BeExactly 'registry.npmjs.org'
            $uri.UserInfo | Should -BeNullOrEmpty
            $uri.Query | Should -BeNullOrEmpty
            $uri.Fragment | Should -BeNullOrEmpty
            $entry.integrity | Should -Match '^sha(?:512|256|1)-[A-Za-z0-9+/=]+$'
            $name = if ($entry.ContainsKey('name')) { $entry.name } else {
                $key.Substring($key.LastIndexOf('node_modules/', [StringComparison]::Ordinal) + 'node_modules/'.Length)
            }
            $basename = ($name -split '/')[-1]
            $entry.resolved | Should -BeExactly "https://registry.npmjs.org/$name/-/$basename-$($entry.version).tgz"
            $resolvedCount++
        }
        $resolvedCount | Should -BeGreaterThan 0
    }

    It 'declares the actual collector runtime and existing validation paths without inventing required checks' {
        $profile = Get-Content -LiteralPath (Join-Path $script:Root '.github\ci.json') -Raw | ConvertFrom-Json
        $profile.runtimeRoot | Should -BeExactly 'collector'
        $profile.testMode | Should -BeExactly 'pester'
        $profile.packageBuilder | Should -BeExactly 'tools/Build-Standalone.ps1'
        $profile.packageEntry | Should -BeExactly 'Invoke-ExchangeLogReport.ps1'
        foreach ($path in @($profile.tests) + @($profile.packageBuilder, "$($profile.runtimeRoot)/$($profile.packageEntry)")) {
            Test-Path -LiteralPath (Join-Path $script:Root $path.Replace('/', '\')) | Should -BeTrue -Because $path
        }
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:Root 'collector\tests') -Filter '*.Tests.ps1' -File) {
            $profile.tests | Should -Contain ('collector/tests/' + $file.Name)
        }
    }

    It 'uses only the existing four reviewed full action SHAs' {
        $allowed = @{
            'actions/checkout' = '11d5960a326750d5838078e36cf38b85af677262'
            'actions/upload-artifact' = 'ea165f8d65b6e75b540449e92b4886f43607fa02'
            'github/codeql-action/init' = '24c54180a607b1449ed407dd24f251e4e9147c8d'
            'github/codeql-action/analyze' = '24c54180a607b1449ed407dd24f251e4e9147c8d'
            'actions/attest' = '1e69f48acb82d1966a394da916b4c1698aa569d6'
        }
        $text = (Get-ChildItem -LiteralPath $script:Workflows -Filter '*.yml' -File |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
        $uses = [regex]::Matches($text, '(?m)["'']?uses["'']?\s*:\s*["'']?([^@\s"'']+)@([^\s"'']+)')
        $uses.Count | Should -BeGreaterThan 0
        foreach ($use in $uses) {
            $allowed.ContainsKey($use.Groups[1].Value) | Should -BeTrue
            $use.Groups[2].Value | Should -BeExactly $allowed[$use.Groups[1].Value]
        }
        $text | Should -Not -Match 'pull_request_target|secrets\.'
    }

    It 'limits CI to the intended public repository with read-only permissions' {
        $script:Ci.permissions.contents | Should -Be 'read'
        @($script:Ci.permissions.PSObject.Properties).Count | Should -Be 1
        $script:Ci.jobs.validate.'runs-on' | Should -Be 'windows-2022'
        $script:Ci.jobs.validate.if | Should -Match "github.repository_owner == 'Nico77600'"
        $script:Ci.jobs.validate.if | Should -Match "github.repository == 'Nico77600/ExchangeLogReportAngular'"
        $script:Ci.jobs.validate.if | Should -Match 'github.event.repository.private == false'
        ($script:Ci.jobs.validate.steps | Where-Object { $_.PSObject.Properties['uses'] -and $_.uses -like 'actions/checkout@*' }).with.'persist-credentials' | Should -BeFalse
    }

    It 'checks Node before npm and never falls back from the committed lockfile or bypasses audit' {
        $steps = @($script:Ci.jobs.validate.steps)
        $runs = @($steps | Where-Object { $_.PSObject.Properties['run'] } | ForEach-Object run)
        $runs[0] | Should -BeExactly '& .\.github\scripts\Test-NodeEngine.ps1 -UseRunnerToolCache'
        $runs | Should -Contain 'npm ci --no-fund'
        $runs | Should -Contain 'npm audit --audit-level=high'
        $runs | Should -Contain 'npm run build'
        $runs | Should -Contain 'npm test -- --watch=false'
        ($runs -join "`n") | Should -Not -Match 'npm install|--no-audit|--audit=false|\|\|\s*true|continue-on-error'
        $preflight = Get-Content -LiteralPath (Join-Path $script:Root '.github\scripts\Test-NodeEngine.ps1') -Raw
        $preflight | Should -Match 'package-lock\.json'
        $preflight | Should -Match 'semver\.satisfies'
        $preflight | Should -Match 'semver\.major\(process\.version\) !== 24'
    }

    It 'selects the newest cached stable Node 24 without accepting other majors or prereleases' {
        $cache = Join-Path $TestDrive 'node-cache'
        [void](New-CachedNodeFixture $cache '22.23.4')
        [void](New-CachedNodeFixture $cache '24.20.0')
        $expected = New-CachedNodeFixture $cache '24.22.1'
        [void](New-CachedNodeFixture $cache '24.23.0-rc.1')
        [void](New-CachedNodeFixture $cache '26.0.0')
        Get-CachedNode24Directory -ToolCacheRoot $cache | Should -BeExactly $expected
    }

    It 'fails explicitly when the runner cache is missing' {
        { Get-CachedNode24Directory -ToolCacheRoot (Join-Path $TestDrive 'missing-cache') } |
            Should -Throw '*tool cache is missing*'
    }

    It 'refuses a cache without stable Node 24 instead of using the default major' {
        $cache = Join-Path $TestDrive 'wrong-node-cache'
        [void](New-CachedNodeFixture $cache '22.23.4')
        { Get-CachedNode24Directory -ToolCacheRoot $cache } | Should -Throw '*no cached stable Node 24*'
    }

    It 'rejects the incomplete selected version rather than silently using an older cache entry' {
        $cache = Join-Path $TestDrive 'incomplete-node-cache'
        [void](New-CachedNodeFixture $cache '24.20.0')
        [void][IO.Directory]::CreateDirectory((Join-Path $cache 'node\24.22.1\x64'))
        { Get-CachedNode24Directory -ToolCacheRoot $cache } | Should -Throw '*selected cached Node 24 is incomplete*'
    }

    It 'keeps runner selection opt-in, publishes its path only after validation and never downloads a runtime' {
        $preflight = [IO.File]::ReadAllText((Join-Path $script:Root '.github\scripts\Test-NodeEngine.ps1'))
        $preflight | Should -Match 'param\(\[switch\]\$UseRunnerToolCache\)'
        $preflight | Should -Match '\$env:GITHUB_ACTIONS -cne ''true'''
        $preflight | Should -Match 'Get-CachedNode24Directory -ToolCacheRoot \$env:RUNNER_TOOL_CACHE'
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($preflight, [ref]$tokens, [ref]$errors)
        $commands = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object { $_.GetCommandName() })
        foreach ($name in 'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer', 'npm', 'npm.cmd') {
            $commands | Should -Not -Contain $name
        }
        $preflight.IndexOf('Add-Content -LiteralPath $env:GITHUB_PATH') |
            Should -BeGreaterThan $preflight.IndexOf("throw 'Node engine preflight failed.")
    }

    It 'creates the new module destination before the pinned download without executing that download in this regression' {
        $initializer = [IO.File]::ReadAllText((Join-Path $script:Root '.github\scripts\Initialize-CIModules.ps1'))
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($initializer, [ref]$tokens, [ref]$errors)
        $create = @($ast.EndBlock.Statements | Where-Object {
            $_.Extent.Text -ceq '[void][IO.Directory]::CreateDirectory($Destination)'
        })
        $download = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Save-Module'
        }, $true))
        $create.Count | Should -Be 1
        $download.Count | Should -Be 1
        $create[0].Extent.StartOffset | Should -BeLessThan $download[0].Extent.StartOffset
        $initializer.IndexOf('if (Test-Path -LiteralPath $Destination)') |
            Should -BeLessThan $create[0].Extent.StartOffset
        $download[0].Extent.Text |
            Should -BeExactly 'Save-Module -Name Pester -RequiredVersion 6.1.0 -Repository PSGallery -Path $Destination -ErrorAction Stop'
        $Destination = Join-Path $TestDrive 'new-module-parent\ci-modules'
        Test-Path -LiteralPath $Destination | Should -BeFalse
        . ([scriptblock]::Create($create[0].Extent.Text))
        Test-Path -LiteralPath $Destination -PathType Container | Should -BeTrue
    }

    It 'builds linked collector source and verifies the standalone package without publishing it' {
        $runs = @($script:Ci.jobs.validate.steps | Where-Object { $_.PSObject.Properties['run'] } | ForEach-Object run) -join "`n"
        $runs | Should -Match 'dotnet build .*host\\ExchangeLogReportAngular.Host.csproj'
        $runs | Should -Match 'Build-Standalone\.ps1'
        $runs | Should -Match "Join-Path .package 'tools\\Test-PackageIntegrity\.ps1'"
        $runs | Should -Match '-Root \$package'
        $runs | Should -Not -Match 'git push|gh release|npm publish'
        $upload = $script:Ci.jobs.validate.steps | Where-Object { $_.PSObject.Properties['uses'] -and $_.uses -like 'actions/upload-artifact@*' }
        $upload.with.path | Should -Not -Match '\*\*|\.zip|\.sqlite|\.log|ready'
        $testRunner = Get-Content -LiteralPath (Join-Path $script:Root '.github\scripts\Invoke-CITests.ps1') -Raw
        $testRunner | Should -Match "Join-Path .root 'collector\\tests'"
        $testRunner | Should -Match "LiteralPath .collectorTests -Filter 'Serve\*\.Tests\.ps1'"
        $testRunner | Should -Match 'tests\\PackageIntegrity\.Tests\.ps1'
        $testRunner | Should -Match 'New-PesterContainer -Path'
        $testRunner | Should -Match 'tests\\LegacyComparison\.Tests\.ps1'
        $testRunner | Should -Not -Match 'host\\Tests'
        $testRunner | Should -Match 'PSVersionTable.PSVersion.ToString\(\)'
        $testRunner | Should -Match 'product.powerShell.version'
        $testRunner | Should -Match 'GetFullPath\(\$PSHOME\)'
        $runs | Should -Match "Join-Path .package 'powershell\\pwsh\.exe'"
        $runs | Should -Match 'Invoke-CITests.ps1 -PackageRoot \$package'
        $steps = @($script:Ci.jobs.validate.steps)
        $packageStep = $steps | Where-Object name -EQ 'Build and verify the standalone package'
        $testStep = $steps | Where-Object name -Like '*tests under the packaged runtime'
        [array]::IndexOf($steps, $packageStep) | Should -BeLessThan ([array]::IndexOf($steps, $testStep))
    }

    It 'keeps CodeQL manual, advisory, default-branch-only and covers C#, Angular and workflows' {
        @($script:Codeql.on.PSObject.Properties.Name) | Should -Be @('workflow_dispatch')
        $script:Codeql.name | Should -Match 'advisory'
        $script:Codeql.jobs.analyze.if | Should -Match "github.repository == 'Nico77600/ExchangeLogReportAngular'"
        $script:Codeql.jobs.analyze.if | Should -Match 'repository.private == false'
        $script:Codeql.jobs.analyze.if | Should -Match 'repository.default_branch'
        $languages = @($script:Codeql.jobs.analyze.strategy.matrix.include.language)
        $languages | Should -Contain 'csharp'
        $languages | Should -Contain 'javascript-typescript'
        $languages | Should -Contain 'actions'
        ($script:Codeql.jobs.analyze.steps | Where-Object { $_.PSObject.Properties['uses'] -and $_.uses -like 'actions/checkout@*' }).with.'persist-credentials' | Should -BeFalse
    }

    It 'requires actual stable release ZIPs and never builds or checks out attestation subjects' {
        $script:Attestation | Should -Match "github.repository_owner == 'Nico77600'"
        $script:Attestation | Should -Match "github.repository == 'Nico77600/ExchangeLogReportAngular'"
        $script:Attestation | Should -Match 'github.event.repository.private == false'
        $script:Attestation | Should -Match 'repository_metadata\.get\("private"\) is not False'
        $script:Attestation | Should -Match 'github.event.repository.default_branch'
        $script:Attestation | Should -Match 'no source archive fallback'
        $script:Attestation | Should -Match 'Release ZIP assets changed during download'
        $script:Attestation | Should -Match 'The release tag changed during verification'
        $script:Attestation | Should -Match "subject-path: 'dist/\*\.zip'"
        $script:Attestation | Should -Not -Match 'uses: actions/checkout|dotnet build|npm ci|gh release create|gh release upload'
    }

    It 'syntax-parses every CI PowerShell helper without executing it' {
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:Root '.github\scripts') -Filter '*.ps1' -File) {
            $tokens = $null
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            @($errors).Count | Should -Be 0 -Because $file.Name
        }
    }

    It 'refuses to run backend tests outside the newly packaged configured runtime' {
        {
            & (Join-Path $script:Root '.github\scripts\Invoke-CITests.ps1') -PackageRoot (Join-Path $TestDrive 'not-a-package')
        } | Should -Throw '*newly packaged, configured x64 PowerShell runtime*'
    }

    It 'accepts only complete hash-verified compiled bundles in synthetic in-memory ZIPs' {
        $python = Get-Command python -ErrorAction Stop
        $test = @'
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import zipfile

text = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"(?ms)^          import hashlib\r?\n.*?^          PY\r?$", text)
assert match, "The reviewed inline verifier must remain inspectable"
lines = match.group(0).splitlines()
source = "\n".join(line[10:] for line in lines[:-1])
compile(source, "attest-release.yml", "exec")
namespace = {}
exec(compile(source.split("# Runtime entrypoint:")[0], "verifier", "exec"), namespace)
verify = namespace["verify_bundle"]

base = {
    "web/index.html": b'<app-root></app-root><script src="main-TEST.js"></script><link href="styles-TEST.css" rel="stylesheet">',
    "web/main-TEST.js": b"console.log('synthetic');",
    "web/styles-TEST.css": b"app-root { display: block }",
    "collector/src/Engine.Serve.cs": b"// synthetic source placeholder",
    "collector/Invoke-ExchangeLogReport.ps1": b"# synthetic collector",
    "collector/ExchangeLogReport.psm1": b"# synthetic module",
    "tools/Test-PackageIntegrity.ps1": b"# synthetic verifier",
    "powershell/pwsh.exe": b"synthetic executable placeholder",
    "collector/config/ExchangeLogReport.config.psd1": b"@{Synthetic=$true}",
}

def make_zip(files=None, *, prefix="pilot/", manifest=True, changed=False, extra=False, traversal=False, bad_schema=False, duplicate=False, omit_full_inventory=False, mutable_tamper=False, unix_inventory=False, omit_mutable_metadata=False):
    files = dict(base if files is None else files)
    inventory = {
        "schemaVersion": 2 if bad_schema else 1,
        "name": "ExchangeLogReportAngular",
        "version": "0.3.0",
        "mutableConfiguration": ["collector\\config\\ExchangeLogReport.config.psd1"],
        "files": [
        {"path": name.replace("/", "\\"), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        for name, data in files.items() if name != "collector/config/ExchangeLogReport.config.psd1"
    ]}
    if traversal:
        inventory["files"][0]["path"] = "..\\index.html"
    if unix_inventory:
        inventory["files"][0]["path"] = "web/index.html"
    if omit_mutable_metadata:
        del inventory["mutableConfiguration"]
    manifest_bytes = json.dumps(inventory).encode()
    full_files = dict(files)
    if manifest:
        full_files["PackageIntegrity.json"] = manifest_bytes
    full_inventory = [
        {"path": name.replace("/", "\\"), "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        for name, data in full_files.items()
    ]
    result = io.BytesIO()
    with zipfile.ZipFile(result, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in files.items():
            if changed and name.endswith(".js"):
                data = data.replace(b"synthetic", b"tampered!")
            if mutable_tamper and name.endswith(".psd1"):
                data = data.replace(b"true", b"True")
            archive.writestr(prefix + name, data)
        if manifest:
            archive.writestr(prefix + "PackageIntegrity.json", manifest_bytes)
        if not omit_full_inventory:
            archive.writestr(prefix + "FILES.sha256.json", json.dumps(full_inventory))
        if extra:
            archive.writestr(prefix + "unlisted.txt", b"not in manifest")
        if duplicate:
            archive.writestr(prefix + "WEB/MAIN-test.JS", b"case collision")
    result.seek(0)
    return result

assert verify(make_zip(), expected_version="0.3.0")["compiled_javascript_files"] == 1
assert verify(make_zip(prefix=""))["compiled_stylesheet_files"] == 1
assert verify(make_zip(omit_mutable_metadata=True))["compiled_javascript_files"] == 1
missing_css = {name: data for name, data in base.items() if not name.endswith(".css")}
missing_index = {name: data for name, data in base.items() if name != "web/index.html"}
unbound_index = dict(base, **{"web/index.html": b"<app-root></app-root>"})
generated_cache = dict(base, **{"collector/bin/poisoned.dll": b"synthetic cache"})
cases = [
    make_zip(manifest=False), make_zip(changed=True), make_zip(extra=True),
    make_zip(traversal=True), make_zip(bad_schema=True), make_zip(duplicate=True),
    make_zip(missing_css), make_zip(missing_index), make_zip(unbound_index),
    make_zip(omit_full_inventory=True), make_zip(mutable_tamper=True),
    make_zip(unix_inventory=True),
    make_zip(generated_cache),
]
for number, fixture in enumerate(cases):
    try:
        verify(fixture)
    except (SystemExit, ValueError, zipfile.BadZipFile):
        continue
    raise AssertionError(f"Invalid bundle fixture {number} was accepted")
try:
    verify(make_zip(), expected_version="0.2.0")
except SystemExit:
    pass
else:
    raise AssertionError("Wrong release version was accepted")
print("3 complete bundles accepted; 14 incomplete, tampered, unsafe, noncanonical, state-polluted or wrong-version bundles rejected; no network or disk fixtures")
'@
        $output = & $python.Source -c $test (Join-Path $script:Workflows 'attest-release.yml') 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }
}
