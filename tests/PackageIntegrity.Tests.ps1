BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Disclaimer = "This Script is a Personal project.`nIt's provided `"AS-IS`". It's not an official Microsoft product so no support can be expected from Microsoft.`n`nAs any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production."
    function New-IntegrityFixture([string]$Name) {
        $root = Join-Path $TestDrive $Name
        $paths = @('tools\Test-PackageIntegrity.ps1', 'collector\Invoke-ExchangeLogReport.ps1',
            'collector\ExchangeLogReport.psm1', 'web\index.html', 'web\main-test.js', 'web\styles-test.css', 'powershell\pwsh.exe')
        foreach ($relative in $paths) {
            $path = Join-Path $root $relative
            [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
            if ($relative -eq 'tools\Test-PackageIntegrity.ps1') {
                Copy-Item -LiteralPath (Join-Path $script:Root $relative) -Destination $path
            } else { [IO.File]::WriteAllText($path, "synthetic-only $relative") }
        }
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'collector\config'))
        [IO.File]::WriteAllText((Join-Path $root 'collector\config\ExchangeLogReport.config.psd1'), '@{}')
        $files = @($paths | ForEach-Object {
            $path = Join-Path $root $_
            [ordered]@{ path = $_; bytes = (Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path).Hash }
        })
        [ordered]@{ schemaVersion = 1; name = 'ExchangeLogReportAngular'; version = 'synthetic'; files = $files } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'PackageIntegrity.json') -Encoding utf8
        return $root
    }
}
Describe 'Portable package byte integrity' {
    It 'keeps the root presentation, exact disclaimer, SECURITY and local links aligned with the documentation standard' {
        $text = [IO.File]::ReadAllText((Join-Path $script:Root 'README.md')).Replace("`r`n", "`n")
        $headings = @([regex]::Matches($text, '(?m)^## ([^\n]+)$') | ForEach-Object { $_.Groups[1].Value })
        $headings | Should -Be @('Why', 'How it works', 'Reports', 'Requirements', 'Quick start', 'Documentation', 'Tests', 'License', 'Disclaimer')
        $text | Should -Match 'Nicolas Fabert'
        $text | Should -Match 'unreleased'
        $text.TrimEnd().EndsWith($script:Disclaimer, [StringComparison]::Ordinal) | Should -BeTrue
        $text | Should -Match '(?s)^<p align="center">\s*<picture>.*?prefers-color-scheme: dark.*?</picture>'
        [regex]::Matches($text, '<a href="#').Count | Should -BeGreaterOrEqual 3
        foreach ($match in [regex]::Matches($text, '(?:src|srcset|href)="([^"#]+)"|\[[^\]\n]+\]\(([^)#]+)\)')) {
            $relative = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
            Test-Path -LiteralPath (Join-Path $script:Root $relative.Replace('/', '\')) | Should -BeTrue -Because $relative
        }
        $security = [IO.File]::ReadAllText((Join-Path $script:Root 'SECURITY.md')).TrimStart([char]0xFEFF).Replace("`r`n", "`n").TrimEnd()
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($security))) |
            Should -BeExactly '53E60B9EDFEEFCB085817ECA745DE00A62F7BD891386834366E1E3243D48972F'
    }

    It 'keeps the delivered runtime README aligned with the exact documentation contract' {
        $text = [IO.File]::ReadAllText((Join-Path $script:Root 'collector\README.md')).Replace("`r`n", "`n")
        $headings = @([regex]::Matches($text, '(?m)^## ([^\n]+)$') | ForEach-Object { $_.Groups[1].Value })
        $headings | Should -Be @('Requirements', 'Quick start', 'Content', 'Documentation', 'Disclaimer')
        $text | Should -Match 'Nicolas Fabert'
        $text.TrimEnd().EndsWith($script:Disclaimer, [StringComparison]::Ordinal) | Should -BeTrue
        $text | Should -Not -Match 'Unblock-File|Version:\*\* 2\.0\.1|tools\\New-ExchangeLogReportPackage'
        $builder = Get-Content -LiteralPath (Join-Path $script:Root 'tools\Build-Standalone.ps1') -Raw
        $builder | Should -Match "\`$runtimeFiles = @\([^\r\n]*'README.md'"
        $builder | Should -Match "Join-Path \`$root 'collector\\README\.md'"
        foreach ($match in [regex]::Matches($text, '\[[^\]\n]+\]\(([^)#]+)\)')) {
            $target = Join-Path (Join-Path $script:Root 'collector') $match.Groups[1].Value.Replace('/', '\')
            Test-Path -LiteralPath $target | Should -BeTrue -Because $match.Groups[1].Value
        }
    }

    It 'documents the Angular workflow and keeps its illustrated guide assets inside the portable source tree' {
        $docs = Join-Path $script:Root 'collector\docs'
        $user = [IO.File]::ReadAllText((Join-Path $docs 'ExchangeLogReport-UserGuide.html'))
        $developer = [IO.File]::ReadAllText((Join-Path $docs 'ExchangeLogReport-Guide.html'))
        $user | Should -Match 'data-target="c-angular-investigation"'
        foreach ($anchor in @('angular-prepare', 'angular-launch', 'angular-selection', 'angular-session',
            'angular-smtp', 'angular-export', 'angular-refresh-stop')) {
            $user | Should -Match ('id="' + $anchor + '"')
        }
        $developer | Should -Match 'data-target="angular-serve"'
        $developer | Should -Match 'id="angular-data-lifecycle"'
        $developer | Should -Match 'id="angular-selection-freshness"'
        $images = @([regex]::Matches($user, 'src="(\.\./\.\./docs/images/[^"]+)"') |
            ForEach-Object { $_.Groups[1].Value })
        $images | Should -Be @('../../docs/images/angular-overview.png', '../../docs/images/angular-message-route.png')
        foreach ($image in $images) {
            Test-Path -LiteralPath (Join-Path $docs $image.Replace('/', '\')) -PathType Leaf | Should -BeTrue
        }
        $developer | Should -Match 'src="images/report-smtp-clients\.png"'
        Test-Path -LiteralPath (Join-Path $docs 'images\report-smtp-clients.png') -PathType Leaf | Should -BeTrue
        $builder = [IO.File]::ReadAllText((Join-Path $script:Root 'tools\Build-Standalone.ps1'))
        [regex]::Matches($builder, 'foreach \(\$relative in \$documentationImages\)').Count | Should -Be 2
    }

    It 'covers compiled Angular and executable source without claiming publisher authentication' {
        $root = New-IntegrityFixture 'valid'
        $result = & (Join-Path $root 'tools\Test-PackageIntegrity.ps1') -Root $root
        $result.Integrity | Should -Be 'Passed'
        $result.AuthenticatedPublisher | Should -BeFalse
    }
    It 'keeps packaged guides from recommending blanket unblocking or execution-policy bypass' {
        foreach ($name in @('ExchangeLogReport-Guide.html', 'ExchangeLogReport-UserGuide.html')) {
            $html = Get-Content -LiteralPath (Join-Path $script:Root "collector\docs\$name") -Raw
            $html | Should -Not -Match 'Unblock-File|ExecutionPolicy\s+Bypass'
            $html | Should -Match 'application-control'
            $html | Should -Match 'href="\.\./README\.md"'
        }
    }
    It 'rejects modified JavaScript, CSS and source bytes' {
        foreach ($relative in @('web\main-test.js', 'web\styles-test.css', 'collector\ExchangeLogReport.psm1')) {
            $root = New-IntegrityFixture ([guid]::NewGuid().ToString('N'))
            [IO.File]::AppendAllText((Join-Path $root $relative), ' changed')
            { & (Join-Path $root 'tools\Test-PackageIntegrity.ps1') -Root $root } | Should -Throw '*mismatch*'
        }
    }
    It 'permits explicitly mutable configuration and generated report data only' {
        $root = New-IntegrityFixture 'mutable'
        [IO.File]::AppendAllText((Join-Path $root 'collector\config\ExchangeLogReport.config.psd1'), '# operator')
        [void][IO.Directory]::CreateDirectory((Join-Path $root 'collector\data'))
        [IO.File]::WriteAllText((Join-Path $root 'collector\data\synthetic.sqlite'), 'synthetic')
        { & (Join-Path $root 'tools\Test-PackageIntegrity.ps1') -Root $root } | Should -Not -Throw
        [IO.File]::WriteAllText((Join-Path $root 'web\unreviewed.js'), 'extra')
        { & (Join-Path $root 'tools\Test-PackageIntegrity.ps1') -Root $root } | Should -Throw '*unexpected immutable*'
    }
    It 'rejects traversal and duplicated manifest entries' {
        foreach ($relative in @('..\outside.ps1', 'web\index.html')) {
            $root = New-IntegrityFixture ([guid]::NewGuid().ToString('N'))
            $manifest = Get-Content -LiteralPath (Join-Path $root 'PackageIntegrity.json') -Raw | ConvertFrom-Json
            $manifest.files += [pscustomobject]@{ path = $relative; bytes = 0; sha256 = '0' * 64 }
            $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'PackageIntegrity.json') -Encoding utf8
            { & (Join-Path $root 'tools\Test-PackageIntegrity.ps1') -Root $root } | Should -Throw '*invalid or duplicate*'
        }
    }
}
