#Requires -Version 7.4
<#
.SYNOPSIS
    Exchange Log Report - PowerShell module.

.DESCRIPTION
    Helper functions used by Invoke-ExchangeLogReport.ps1, organised in regions in the
    order of an execution:

        1. Console and log        Write-Exl* functions (what the administrator sees)
        2. Configuration          Import-ExlConfiguration (reads and checks the .psd1 file)
        3. Engine                 Initialize-ExlEngine (SQLite + compiled C# engine)
        4. Command line, periods  Resolve-ExlRange, Resolve-ExlPeriod, Get-ExlIgnoredParameter
        5. Sources                Get-ExlSources (log folders of each Exchange server)
        6. Collection             Invoke-ExlCollection (log files -> SQLite)
        7. Report                 New-ExlReport (SQLite -> CSV / HTML)
        8. Status and maintenance Show-ExlStatus, Invoke-ExlRetention, Enter-ExlLock

    Reading and parsing the log files, the database and the report files are handled by
    the C# engine (src\Engine.*.cs), compiled on first use.

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.1
    History : see CHANGELOG.md

    This Script is a Personal project.
    It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

    As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolVersion = '2.0.1'
$script:ToolRoot = $PSScriptRoot
$script:LogWriter = $null
$script:LogPath = $null
# Per-server settings of the configuration. Root keys only serve to derive the path keys that are
# neither in the Servers block nor in the file written by -Mode Discover (PathsFileName).
$script:ServerRootKeys = @('ExchangePath', 'IisLogPath', 'LoggingPath', 'TransportLogPath')
$script:ServerPathKeys = @('HttpProxyPath', 'MapiHttpPath', 'ImapLogPath', 'PopLogPath', 'IisFrontEndPath', 'IisBackEndPath',
    'FrontEndReceivePath', 'FrontEndSendPath', 'HubReceivePath', 'HubSendPath', 'MailboxReceivePath', 'MailboxSendPath',
    'EdgeReceivePath', 'EdgeSendPath', 'MessageTrackingPath')
$script:PathsFileName = 'ExchangeLogReport.paths.psd1'
# Entropy of the DPAPI protection of the mail password (Mail.CredentialFile).
$script:MailEntropy = [Text.Encoding]::UTF8.GetBytes('Exchange Log Report - mail credential')
Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction SilentlyContinue
# Role of a server (Servers block, -Mode Discover or detected at collection time). An Edge Transport server has
# no client access (no IIS, HttpProxy, MAPI, ActiveSync, POP3 or IMAP4): only its SMTP protocol logs
# (TransportRoles\Logs\Edge\ProtocolLog) and its message tracking are read.
$script:ServerRoles = @('Mailbox', 'Edge')
$script:EdgeRoleKey = 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\EdgeTransportRole'
# Default report title: an Edge report gets its own title unless Report.Title was changed.
$script:DefaultReportTitle = 'Exchange Server usage and troubleshooting'
# Sources that Exchange itself writes all the time (health probes hit every web site within minutes):
# a newest file older than Collection.StaleSourceHours means that logging stopped or that the logs were
# moved. Not message tracking nor SMTP: a server without mail flow writes nothing there for months.
$script:AlwaysActiveKinds = @('HttpProxy', 'Iis', 'EasBackEnd')
# Sources whose folder exists only where the logging is enabled or has been used.
$script:OptionalKinds = @('SmtpReceive', 'SmtpSend', 'Imap4', 'Pop3', 'MapiBackEnd')
# IIS sites created by Exchange setup. Any other site hosting Exchange virtual directories (a second
# OWA/ECP site for instance) is a custom site: found in applicationHost.config and read as well.
$script:ExchangeSites = [ordered]@{ IisFrontEndPath = 'Default Web Site'; IisBackEndPath = 'Exchange Back End' }
# ---------------------------------------------------------------------------------------------
# Console theme (same rules as Purview DLP Report):
#   - ANSI colours are disabled when the output is redirected (scheduled task) or NO_COLOR is
#     set; EXL_FORCE_COLOR=1 forces them.
#   - Icons: emoji in Windows Terminal / VS Code, symbols of the classic console fonts elsewhere.
#     EXL_ICONS = Emoji | Symbols | Ascii forces a style.
# ---------------------------------------------------------------------------------------------
$script:C = @{ Reset = ''; Bold = ''; Dim = ''; Accent = ''; AccentBg = ''; Cyan = ''; Green = ''; Yellow = ''; Red = ''; White = '' }
if ($env:EXL_FORCE_COLOR -eq '1' -or (-not [Console]::IsOutputRedirected -and -not $env:NO_COLOR)) {
    $e = [char]27
    $script:C = @{
        Reset = "$e[0m"; Bold = "$e[1m"; Dim = "$e[90m"; White = "$e[97m"
        Accent = "$e[38;2;214;62;115m"; AccentBg = "$e[48;2;177;31;75m$e[97m"
        Cyan = "$e[38;2;97;214;214m"; Green = "$e[38;2;80;200;120m"; Yellow = "$e[38;2;240;200;90m"; Red = "$e[38;2;240;90;90m"
    }
}
$script:IconStyle = if ($env:EXL_ICONS -in 'Emoji', 'Symbols', 'Ascii') { $env:EXL_ICONS }
    elseif ([Console]::IsOutputRedirected) { 'Symbols' }
    elseif ($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode') { 'Emoji' }
    else { 'Symbols' }

function Get-ExlIconSet {
    <# Icons of one console style. Symbols: only characters of the classic console fonts. #>
    param([Parameter(Mandatory)][ValidateSet('Emoji', 'Symbols', 'Ascii')][string]$Style)
    $u = { param([int]$Code) [char]::ConvertFromUtf32($Code) }
    switch ($Style) {
        'Emoji' { return @{
                Logo = & $u 0x1F4EC; Ok = & $u 0x2705; Warn = (& $u 0x26A0) + [char]0xFE0F; Fail = & $u 0x274C; Info = & $u 0x1F539; Skip = & $u 0x23E9
                Database = & $u 0x1F4BE; Plan = & $u 0x1F50E; Server = & $u 0x1F5A5; Download = & $u 0x1F4E5; Report = & $u 0x1F4CA; Calendar = & $u 0x1F4C5
                File = & $u 0x1F4C4; Folder = & $u 0x1F4C1; Clock = & $u 0x23F3; Mail = & $u 0x1F4E8; Target = & $u 0x1F3AF; Log = & $u 0x1F4DD
                Done = & $u 0x1F389; People = & $u 0x1F465; Chart = & $u 0x1F4C8; Broom = & $u 0x1F9F9; Filter = & $u 0x1F9F9
            } }
        'Symbols' { return @{
                Logo = & $u 0x2666; Ok = & $u 0x221A; Warn = & $u 0x25B2; Fail = & $u 0x00D7; Info = & $u 0x2022; Skip = & $u 0x00BB
                Database = & $u 0x25A0; Plan = & $u 0x25BA; Server = & $u 0x2261; Download = & $u 0x2193; Report = & $u 0x2261; Calendar = & $u 0x263C
                File = & $u 0x25AC; Folder = & $u 0x2302; Clock = & $u 0x25CB; Mail = '@'; Target = & $u 0x25D9; Log = & $u 0x00B6
                Done = & $u 0x221A; People = & $u 0x2192; Chart = & $u 0x2191; Broom = & $u 0x00F7; Filter = & $u 0x00F7
            } }
        default { return @{
                Logo = '*'; Ok = '+'; Warn = '!'; Fail = 'x'; Info = '-'; Skip = '>'; Database = '#'; Plan = '?'; Server = '='; Download = 'v'; Report = '='
                Calendar = ':'; File = '-'; Folder = '>'; Clock = '~'; Mail = '@'; Target = 'o'; Log = '='; Done = '*'; People = '&'; Chart = '^'; Broom = '/'; Filter = '/'
            } }
    }
}

function Get-ExlFrameSet {
    <# Frame characters: rounded corners, square with the fonts that lack them (Lucida Console, raster font). #>
    param([Parameter(Mandatory)][ValidateSet('Emoji', 'Symbols', 'Ascii')][string]$Style, [AllowNull()][string]$FontName)
    if ($Style -eq 'Ascii') { return @{ TopLeft = [char]'+'; TopRight = [char]'+'; BottomLeft = [char]'+'; BottomRight = [char]'+'; Horizontal = [char]'-'; Vertical = [char]'|' } }
    if ($Style -eq 'Symbols' -and $FontName -in 'Lucida Console', 'Terminal') {
        return @{ TopLeft = [char]0x250C; TopRight = [char]0x2510; BottomLeft = [char]0x2514; BottomRight = [char]0x2518; Horizontal = [char]0x2500; Vertical = [char]0x2502 }
    }
    return @{ TopLeft = [char]0x256D; TopRight = [char]0x256E; BottomLeft = [char]0x2570; BottomRight = [char]0x256F; Horizontal = [char]0x2500; Vertical = [char]0x2502 }
}

function Get-ExlFrame {
    if ($script:Frame) { return $script:Frame }
    $engine = [bool]('ExchangeLogReport.ConsoleFont' -as [type])
    $font = if ($script:IconStyle -eq 'Symbols' -and $engine) { [ExchangeLogReport.ConsoleFont]::FaceName() }
    $frame = Get-ExlFrameSet $script:IconStyle $font
    if ($script:IconStyle -ne 'Symbols' -or $engine) { $script:Frame = $frame }
    return $frame
}

$script:Icons = Get-ExlIconSet $script:IconStyle
$script:Frame = $null
$script:IconPad = if ($script:IconStyle -eq 'Emoji') { ' ' } else { '  ' }

#region 1. Console and log ---------------------------------------------------------------

function Get-ExlIcon { param([Parameter(Mandatory)][string]$Name) return $script:Icons[$Name] + $script:IconPad }

function Format-ExlNumber {
    param([Parameter(Mandatory)][AllowNull()]$Value)
    if ($null -eq $Value) { return '-' }
    return ([long]$Value).ToString('N0', [Globalization.CultureInfo]::GetCultureInfo('en-US'))
}

function Format-ExlDuration {
    param([Parameter(Mandatory)][double]$Seconds)
    $t = [TimeSpan]::FromTicks([long]([Math]::Max(0.0, $Seconds) * 10000000))
    if ($t.TotalDays -ge 2) { return '{0} d {1:00} h' -f [int][Math]::Floor($t.TotalDays), $t.Hours }
    if ($t.TotalHours -ge 1) { return '{0} h {1:00} min' -f [int][Math]::Floor($t.TotalHours), $t.Minutes }
    if ($t.TotalMinutes -ge 1) { return '{0} min {1:00} s' -f $t.Minutes, $t.Seconds }
    return '{0:0.0} s' -f $t.TotalSeconds
}

function Format-ExlBytes {
    param([Parameter(Mandatory)][double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:0.00} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:0.0} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:0} KB' -f ($Bytes / 1KB) }
    return '{0:0} B' -f $Bytes
}

function Format-ExlLocalTime {
    param([Parameter(Mandatory)][long]$UnixMs, [Parameter(Mandatory)][TimeZoneInfo]$Zone, [string]$Format = 'yyyy-MM-dd HH:mm')
    return [TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeMilliseconds($UnixMs), $Zone).ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}

function Format-ExlRange {
    param([long]$StartMs, [long]$EndMs, [TimeZoneInfo]$Zone)
    return '{0} {2} {1}' -f (Format-ExlLocalTime $StartMs $Zone), (Format-ExlLocalTime $EndMs $Zone), [char]0x2192
}

function Start-ExlLog {
    <# Opens (or continues) today's log file and deletes the log files older than the retention. #>
    param([Parameter(Mandatory)][string]$Directory, [int]$RetentionDays = 14)
    [void][IO.Directory]::CreateDirectory($Directory)
    $script:LogPath = Join-Path $Directory ('ExchangeLogReport_{0:yyyyMMdd}.log' -f (Get-Date))
    $stream = [IO.FileStream]::new($script:LogPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $script:LogWriter = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    $script:LogWriter.AutoFlush = $true
    $limit = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $Directory -Filter 'ExchangeLogReport_*.log' -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -lt $limit | Remove-Item -Force -ErrorAction SilentlyContinue
    return $script:LogPath
}

function Stop-ExlLog { if ($script:LogWriter) { $script:LogWriter.Dispose(); $script:LogWriter = $null } }

function Write-ExlLog {
    <# One line in the log file only. The log never contains colours or icons. #>
    param([ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP', 'DEBUG')][string]$Level = 'INFO', [Parameter(Mandatory)][AllowEmptyString()][string]$Message)
    if ($script:LogWriter) { $script:LogWriter.WriteLine(('{0:yyyy-MM-ddTHH:mm:ss.fffzzz} [{1,-5}] {2}' -f (Get-Date), $Level, $Message)) }
}

function Write-ExlBanner {
    <# Title card at the start of an execution, followed by the context rows (label -> @(Icon, Text)). #>
    param([Parameter(Mandatory)][string]$Title, [string]$Subtitle, [System.Collections.Specialized.OrderedDictionary]$Details)
    $C = $script:C; $F = Get-ExlFrame; $width = 74
    $right = "v$($script:ToolVersion) $([char]0x00B7) Nicolas Fabert"
    $iconWidth = if ($script:IconStyle -eq 'Emoji') { 2 } else { 1 }
    $left = "  $($script:Icons.Logo)  $Title"
    $gap = [Math]::Max(1, $width - ($left.Length - $script:Icons.Logo.Length + $iconWidth) - $right.Length - 2)
    Write-Host ''
    Write-Host ("  {0}{1}{2}{3}{4}" -f $C.Accent, $F.TopLeft, [string]::new($F.Horizontal, $width), $F.TopRight, $C.Reset)
    Write-Host ("  {0}{1}{2}{3}{4}{5}{6}{7}{8}{9}{10}{11}" -f $C.Accent, $F.Vertical, $C.Reset, $C.Bold, $left, $C.Reset, [string]::new(' ', $gap), $C.Dim, $right, '  ', ($C.Accent + $F.Vertical), $C.Reset)
    if ($Subtitle) {
        $sub = "     $Subtitle"
        if ($sub.Length -gt $width - 2) { $sub = $sub.Substring(0, $width - 5) + '...' }
        Write-Host ("  {0}{1}{2}{3}{4}{5}{0}{6}{2}" -f $C.Accent, $F.Vertical, $C.Reset, $C.Dim, $sub.PadRight($width), $C.Reset, $F.Vertical)
    }
    Write-Host ("  {0}{1}{2}{3}{4}" -f $C.Accent, $F.BottomLeft, [string]::new($F.Horizontal, $width), $F.BottomRight, $C.Reset)
    if ($Details) {
        foreach ($key in $Details.Keys) {
            $value = $Details[$key]
            $icon, $text = if ($value -is [array]) { (Get-ExlIcon $value[0]), $value[1] } else { '   ', $value }
            Write-Host ("     {0}{1}{2,-10}{3} {4}" -f $icon, $C.Dim, $key, $C.Reset, $text)
        }
    }
    Write-ExlLog 'STEP' "=== $Title v$($script:ToolVersion) ==="
    if ($Details) { foreach ($key in $Details.Keys) { $v = $Details[$key]; Write-ExlLog 'INFO' ("{0}: {1}" -f $key, $(if ($v -is [array]) { $v[1] } else { $v })) } }
}

function Write-ExlStep {
    <# Step header with a coloured number pill and an icon:  ─ 3/5 ─ 📥  Reading the logs #>
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][int]$Total, [Parameter(Mandatory)][string]$Title, [string]$Icon = 'Info')
    $C = $script:C
    Write-Host ''
    Write-Host ("  {0} {1}/{2} {3} {4}{5}{6}{3}" -f $C.AccentBg, $Number, $Total, $C.Reset, (Get-ExlIcon $Icon), $C.Bold, $Title)
    Write-ExlLog 'STEP' "[$Number/$Total] $Title"
}

function Write-ExlItem {
    <# One indented result line with a status icon, also written to the log. #>
    param([ValidateSet('Ok', 'Warn', 'Fail', 'Info', 'Skip')][string]$Status = 'Info', [Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Icon)
    $color = @{ Ok = $script:C.Green; Warn = $script:C.Yellow; Fail = $script:C.Red; Info = ''; Skip = $script:C.Dim }[$Status]
    $level = @{ Ok = 'OK'; Warn = 'WARN'; Fail = 'ERROR'; Info = 'INFO'; Skip = 'INFO' }[$Status]
    $symbol = Get-ExlIcon $(if ($Icon) { $Icon } else { $Status })
    $textColor = if ($Status -in 'Warn', 'Fail', 'Skip') { $color } else { '' }
    Write-Host ("      {0}{1}{2}{3}{4}{2}" -f $color, $symbol, $script:C.Reset, $textColor, $Text)
    Write-ExlLog $level $Text
}

function Write-ExlDetail {
    <# A dimmed detail line under an item (an SMTP conversation for instance), also written to the log. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    Write-Host ("          {0}{1}{2}" -f $script:C.Dim, $Text, $script:C.Reset)
    Write-ExlLog 'INFO' $Text
}

function Write-ExlTableRow {
    <# One aligned row of the collection table: server, source, files, read, lines, kept, noise, duration, rate. #>
    param([switch]$Header, [ValidateSet('Ok', 'Warn', 'Fail', 'Skip')][string]$Status = 'Ok', [string]$Server, [string]$Source, [string]$Files,
        [string]$Read, $Lines, $Kept, [string]$Noise, [string]$Duration, [string]$Rate)
    $C = $script:C
    if ($Header) {
        Write-Host ("      {0}{1}{2,-10} {3,-19} {4,9} {5,10} {6,12} {7,10} {8,7} {9,10} {10,10}{11}" -f $C.Dim, ('  ' + $script:IconPad), 'Server', 'Source', 'Files', 'Read', 'Lines', 'Kept', 'Noise', 'Duration', 'Rate', $C.Reset)
        return
    }
    $color = @{ Ok = $C.Green; Warn = $C.Yellow; Fail = $C.Red; Skip = $C.Dim }[$Status]
    $keptText = Format-ExlNumber $Kept
    $keptColor = if ([long]$Kept -gt 0) { $C.White + $C.Bold } else { $C.Dim }
    Write-Host ("      {0}{1}{2}{3,-10} {4,-19} {5,9} {6,10} {7,12} {8}{9,10}{2} {10,7} {11,10} {12}{13,10}{2}" -f $color, (Get-ExlIcon $Status), $C.Reset, $Server, $Source, $Files, $Read,
        (Format-ExlNumber $Lines), $keptColor, $keptText, $Noise, $Duration, $C.Dim, $Rate)
    Write-ExlLog $(if ($Status -eq 'Ok' -or $Status -eq 'Skip') { 'OK' } else { 'WARN' }) ("{0} {1}: files {2}, read {3}, {4} lines, {5} kept, noise {6}, {7}, {8}" -f $Server, $Source, $Files, $Read, (Format-ExlNumber $Lines), $keptText, $Noise, $Duration, $Rate)
}

function Write-ExlSummary {
    <# Final summary card (label -> @(Icon, Text)). #>
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Values, [ValidateSet('Ok', 'Warn', 'Fail')][string]$Status = 'Ok')
    $C = $script:C; $F = Get-ExlFrame; $width = 74
    $color = @{ Ok = $C.Green; Warn = $C.Yellow; Fail = $C.Red }[$Status]
    $icon = $script:Icons[@{ Ok = 'Done'; Warn = 'Warn'; Fail = 'Fail' }[$Status]]
    $iconWidth = if ($script:IconStyle -eq 'Emoji') { 2 } else { 1 }
    $head = " $icon  $Title "
    $rest = [Math]::Max(2, $width - 1 - ($head.Length - $icon.Length + $iconWidth))
    Write-Host ''
    Write-Host ("  {0}{1}{2}{3}{4}{0}{5}{6}{7}" -f $color, $F.TopLeft, $F.Horizontal, $C.Bold, $head, ($C.Reset + $color), ([string]::new($F.Horizontal, $rest) + $F.TopRight), $C.Reset)
    foreach ($key in $Values.Keys) {
        $value = $Values[$key]
        $rowIcon, $text = if ($value -is [array]) { (Get-ExlIcon $value[0]), $value[1] } else { '   ', $value }
        Write-Host ("    {0}{1}{2,-10}{3} {4}" -f $rowIcon, $C.Dim, $key, $C.Reset, $text)
        Write-ExlLog 'INFO' ("Summary - {0}: {1}" -f $key, $text)
    }
    Write-Host ("  {0}{1}{2}{3}{4}" -f $color, $F.BottomLeft, [string]::new($F.Horizontal, $width), $F.BottomRight, $C.Reset)
    Write-Host ''
}

#endregion

#region 2. Configuration ------------------------------------------------------------------

function Resolve-ExlPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([IO.Path]::IsPathRooted($expanded)) { return [IO.Path]::GetFullPath($expanded) }
    return [IO.Path]::GetFullPath((Join-Path $Root $expanded))
}

function Get-ExlTimeZone {
    <# Accepts an IANA name (Europe/Paris) or a Windows name (Romance Standard Time). #>
    param([Parameter(Mandatory)][string]$Id)
    try { return [TimeZoneInfo]::FindSystemTimeZoneById($Id) } catch [TimeZoneNotFoundException] { }
    # Windows without ICU uses native registry IDs; the delivered default must not depend on IANA conversion.
    if ($IsWindows -and $Id -ieq 'Europe/Paris') { return [TimeZoneInfo]::FindSystemTimeZoneById('Romance Standard Time') }
    $windowsId = $null
    if ([TimeZoneInfo]::TryConvertIanaIdToWindowsId($Id, [ref]$windowsId)) { return [TimeZoneInfo]::FindSystemTimeZoneById($windowsId) }
    throw "Unknown time zone '$Id' (Report.TimeZone). On Windows without IANA support, use a Windows ID such as 'Romance Standard Time' (Paris); otherwise an IANA ID such as 'Europe/Paris'."
}

function Import-ExlConfiguration {
    <#
    .SYNOPSIS
        Reads the configuration file, checks every value and returns it with absolute paths.
        All problems are reported together so that they can be fixed in one go.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$Root = $script:ToolRoot)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path" }
    try { $config = Import-PowerShellDataFile -LiteralPath $Path }
    catch { throw "The configuration file is not valid PowerShell data ($Path): $($_.Exception.Message)" }

    $errors = [Collections.Generic.List[string]]::new()
    foreach ($section in 'Sources', 'Noise', 'Collection', 'Storage', 'Report', 'Logging') {
        if (-not $config.ContainsKey($section) -or $config[$section] -isnot [hashtable]) { $errors.Add("Section '$section' is missing.") }
    }
    if (-not $config.ContainsKey('Servers') -or @($config.Servers).Count -eq 0) { $errors.Add("Section 'Servers' must list at least one Exchange server.") }
    if ($errors.Count) { throw ("Invalid configuration ($Path):`n - " + ($errors -join "`n - ")) }

    function Get-Value([hashtable]$Section, [string]$SectionName, [string]$Key, $Default, [switch]$Required) {
        if ($Section.ContainsKey($Key) -and $null -ne $Section[$Key] -and "$($Section[$Key])" -ne '') { return $Section[$Key] }
        if ($Required) { $errors.Add("$SectionName.$Key is required.") }
        return $Default
    }
    function Test-Int($Value, [string]$Name, [long]$Min, [long]$Max) {
        $n = 0L
        if (-not [long]::TryParse("$Value", [ref]$n) -or $n -lt $Min -or $n -gt $Max) { $errors.Add("$Name must be a whole number between $Min and $Max (current value: '$Value').") }
        return [int]$n
    }
    function Test-Bool($Value, [string]$Name) {
        if ($Value -isnot [bool]) { $errors.Add("$Name must be `$true or `$false (current value: '$Value').") ; return $false }
        return $Value
    }
    function Test-Choice($Value, [string]$Name, [string[]]$Allowed) {
        $match = @($Allowed | Where-Object { $_ -ieq "$Value" })
        if ($match.Count -ne 1) { $errors.Add("$Name must be one of: $($Allowed -join ', ') (current value: '$Value')."); return $Allowed[0] }
        return [string]$match[0]
    }
    function Test-Patterns($Value, [string]$Name) {
        $list = @($Value | Where-Object { $_ })
        foreach ($p in $list) { try { [void][regex]::new($p) } catch { $errors.Add("$Name contains an invalid regular expression: '$p'.") } }
        return [string[]]$list
    }

    # ---- servers (paths are resolved once the sources are known) ----------------------------------
    $blocks = [Collections.Generic.List[hashtable]]::new()
    $index = 0
    $allowed = @('Name', 'Role') + $script:ServerRootKeys + $script:ServerPathKeys
    foreach ($s in @($config.Servers)) {
        $index++
        if ($s -isnot [hashtable]) { $errors.Add("Servers[$index] must be a @{ } block."); continue }
        if (-not [string]$s['Name']) { $errors.Add("Servers[$index].Name is required."); continue }
        foreach ($key in $s.Keys) { if ($key -notin $allowed) { $errors.Add("Servers[$index].$key is not a known setting. Allowed: $($allowed -join ', ').") } }
        if ($s.ContainsKey('Role') -and [string]$s['Role'] -notin $script:ServerRoles) { $errors.Add("Servers[$index].Role must be $($script:ServerRoles -join ' or ') (current value: '$($s['Role'])').") }
        $blocks.Add($s)
    }
    $duplicates = @($blocks | ForEach-Object { ([string]$_['Name']).ToUpperInvariant() } | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name)
    foreach ($d in $duplicates) { $errors.Add("Server '$d' is listed more than once.") }
    $pathsFile = Join-Path (Split-Path ([IO.Path]::GetFullPath($Path)) -Parent) $script:PathsFileName
    $discovery = $null
    if (Test-Path -LiteralPath $pathsFile -PathType Leaf) {
        try { $discovery = Import-PowerShellDataFile -LiteralPath $pathsFile }
        catch { $errors.Add("The paths file written by -Mode Discover is not valid ($pathsFile): $($_.Exception.Message). Run -Mode Discover again.") }
    }

    $src = $config.Sources; $n = $config.Noise; $c = $config.Collection; $st = $config.Storage; $r = $config.Report; $l = $config.Logging
    $settings = [ordered]@{
        ConfigPath = [IO.Path]::GetFullPath($Path)
        PathsFile  = $pathsFile
        Discovery  = if ($discovery) { [pscustomobject]@{ When = [string]$discovery['Discovered']; By = [string]$discovery['By']; Via = [string]$discovery['Via']; Collector = [string]$discovery['Collector'] } } else { $null }
        Servers    = @()
        Sources    = [ordered]@{
            HttpProxy       = Test-Bool (Get-Value $src 'Sources' 'HttpProxy' $true) 'Sources.HttpProxy'
            IisFrontEnd     = Test-Bool (Get-Value $src 'Sources' 'IisFrontEnd' $true) 'Sources.IisFrontEnd'
            SmtpReceive     = Test-Bool (Get-Value $src 'Sources' 'SmtpReceive' $true) 'Sources.SmtpReceive'
            SmtpSend        = Test-Bool (Get-Value $src 'Sources' 'SmtpSend' $true) 'Sources.SmtpSend'
            MessageTracking = Test-Bool (Get-Value $src 'Sources' 'MessageTracking' $true) 'Sources.MessageTracking'
            TransportRoles  = [string[]]@(Get-Value $src 'Sources' 'TransportRoles' @('FrontEnd', 'Hub', 'Mailbox'))
            IisSite         = [string](Get-Value $src 'Sources' 'IisSite' 'W3SVC1')
            MapiBackEnd     = Test-Bool (Get-Value $src 'Sources' 'MapiBackEnd' $true) 'Sources.MapiBackEnd'
            EasBackEnd      = Test-Bool (Get-Value $src 'Sources' 'EasBackEnd' $true) 'Sources.EasBackEnd'
            IisBackEndSite  = [string](Get-Value $src 'Sources' 'IisBackEndSite' 'W3SVC2')
            PopImap         = Test-Bool (Get-Value $src 'Sources' 'PopImap' $false) 'Sources.PopImap'
        }
        Noise      = [ordered]@{
            SystemUserPatterns     = Test-Patterns (Get-Value $n 'Noise' 'SystemUserPatterns' @()) 'Noise.SystemUserPatterns'
            ProbeUserAgentPatterns = Test-Patterns (Get-Value $n 'Noise' 'ProbeUserAgentPatterns' @()) 'Noise.ProbeUserAgentPatterns'
            ProbeUrlPatterns       = Test-Patterns (Get-Value $n 'Noise' 'ProbeUrlPatterns' @()) 'Noise.ProbeUrlPatterns'
            ProbeSenderPatterns    = Test-Patterns (Get-Value $n 'Noise' 'ProbeSenderPatterns' @()) 'Noise.ProbeSenderPatterns'
            ExcludedClientIps      = [string[]]@(Get-Value $n 'Noise' 'ExcludedClientIps' @() | Where-Object { $_ })
            IgnoredTrackingEvents  = [string[]]@(Get-Value $n 'Noise' 'IgnoredTrackingEvents' @() | Where-Object { $_ })
        }
        Collection = [ordered]@{
            BackfillDays           = Test-Int (Get-Value $c 'Collection' 'BackfillDays' 14) 'Collection.BackfillDays' 1 365
            RecoveryWindowMinutes  = Test-Int (Get-Value $c 'Collection' 'RecoveryWindowMinutes' 30) 'Collection.RecoveryWindowMinutes' 1 1440
            SmtpSessionIdleMinutes = Test-Int (Get-Value $c 'Collection' 'SmtpSessionIdleMinutes' 10) 'Collection.SmtpSessionIdleMinutes' 1 120
            FullDetailUsers        = [string[]]@(Get-Value $c 'Collection' 'FullDetailUsers' @() | Where-Object { $_ })
            StoreAllRequests       = Test-Bool (Get-Value $c 'Collection' 'StoreAllRequests' $false) 'Collection.StoreAllRequests'
            SessionIdleMinutes     = Test-Int (Get-Value $c 'Collection' 'SessionIdleMinutes' 30) 'Collection.SessionIdleMinutes' 1 720
            SlowRequestMs          = Test-Int (Get-Value $c 'Collection' 'SlowRequestMs' 5000) 'Collection.SlowRequestMs' 0 3600000
            LongRunningPatterns    = Test-Patterns (Get-Value $c 'Collection' 'LongRunningPatterns' @('^Mapi\|NotificationWait\|', '^Eas\|Ping\|', '^RpcHttp\|', '^Owa\|.*(notificationchannel|/ev\.owa)', '^PowerShell\|', '^Imap4\|IDLE\|')) 'Collection.LongRunningPatterns'
            SessionDetailRequests  = Test-Int (Get-Value $c 'Collection' 'SessionDetailRequests' 40) 'Collection.SessionDetailRequests' 0 100000
            MaxSessionSteps        = Test-Int (Get-Value $c 'Collection' 'MaxSessionSteps' 80) 'Collection.MaxSessionSteps' 10 100000
            StaleSourceHours       = Test-Int (Get-Value $c 'Collection' 'StaleSourceHours' 24) 'Collection.StaleSourceHours' 0 8760
            Parallelism            = Test-Int (Get-Value $c 'Collection' 'Parallelism' 0) 'Collection.Parallelism' 0 64
            MaxFilesPerServer      = Test-Int (Get-Value $c 'Collection' 'MaxFilesPerServer' 4) 'Collection.MaxFilesPerServer' 0 64
            DeferRollups           = Test-Choice (Get-Value $c 'Collection' 'DeferRollups' 'Never') 'Collection.DeferRollups' @('Auto', 'Never', 'Always')
        }
        Storage    = [ordered]@{
            DatabasePath        = Resolve-ExlPath ([string](Get-Value $st 'Storage' 'DatabasePath' '.\data\ExchangeLogReport.sqlite')) $Root
            RetentionDays       = Test-Int (Get-Value $st 'Storage' 'RetentionDays' 60) 'Storage.RetentionDays' 1 3650
            DetailRetentionDays = Test-Int (Get-Value $st 'Storage' 'DetailRetentionDays' 14) 'Storage.DetailRetentionDays' 1 3650
        }
        Report     = [ordered]@{
            DefaultRange          = [string](Get-Value $r 'Report' 'DefaultRange' 'Last7Days')
            DefaultType           = [string](Get-Value $r 'Report' 'DefaultType' 'Usage')
            TimeZone              = [string](Get-Value $r 'Report' 'TimeZone' 'Europe/Paris')
            OutputPath            = Resolve-ExlPath ([string](Get-Value $r 'Report' 'OutputPath' '.\reports')) $Root
            FilePrefix            = [string](Get-Value $r 'Report' 'FilePrefix' 'ExchangeLogs')
            Formats               = [string[]]@(Get-Value $r 'Report' 'Formats' @('Csv', 'Html'))
            IncludeRoutingDetails = Test-Bool (Get-Value $r 'Report' 'IncludeRoutingDetails' $true) 'Report.IncludeRoutingDetails'
            IncludeSessionDetails = Test-Bool (Get-Value $r 'Report' 'IncludeSessionDetails' $true) 'Report.IncludeSessionDetails'
            CsvDelimiter          = [string](Get-Value $r 'Report' 'CsvDelimiter' ';')
            MaxHtmlRows           = Test-Int (Get-Value $r 'Report' 'MaxHtmlRows' 200000) 'Report.MaxHtmlRows' 1000 2000000
            MemoryBudgetMB        = Test-Int (Get-Value $r 'Report' 'MemoryBudgetMB' 512) 'Report.MemoryBudgetMB' 64 16384
            Parallelism           = Test-Int (Get-Value $r 'Report' 'Parallelism' 0) 'Report.Parallelism' 0 16
            MaxDataAgeMinutes     = Test-Int (Get-Value $r 'Report' 'MaxDataAgeMinutes' 90) 'Report.MaxDataAgeMinutes' 0 525600
            Title                 = [string](Get-Value $r 'Report' 'Title' $script:DefaultReportTitle)
            TemplatePath          = Join-Path $Root 'templates\Report.template.html'
        }
        Logging    = [ordered]@{
            Path          = Resolve-ExlPath ([string](Get-Value $l 'Logging' 'Path' '.\logs')) $Root
            RetentionDays = Test-Int (Get-Value $l 'Logging' 'RetentionDays' 14) 'Logging.RetentionDays' 1 3650
        }
    }
    # ---- e-mail (optional section) ------------------------------------------------------------------------
    $ml = if ($config.ContainsKey('Mail') -and $config.Mail -is [hashtable]) { $config.Mail } else { @{} }
    if ($config.ContainsKey('Mail') -and $config.Mail -isnot [hashtable]) { $errors.Add('Mail must be a @{ } block.') }
    $mail = [ordered]@{
        Enabled               = Test-Bool (Get-Value $ml 'Mail' 'Enabled' $false) 'Mail.Enabled'
        SmtpServer            = ([string](Get-Value $ml 'Mail' 'SmtpServer' '')).Trim()
        Port                  = Test-Int (Get-Value $ml 'Mail' 'Port' 0) 'Mail.Port' 0 65535
        Encryption            = [string](Get-Value $ml 'Mail' 'Encryption' 'StartTls')
        Authentication        = [string](Get-Value $ml 'Mail' 'Authentication' 'Anonymous')
        CredentialFile        = Resolve-ExlPath ([string](Get-Value $ml 'Mail' 'CredentialFile' '.\config\ExchangeLogReport.mail.credential')) $Root
        CredentialScope       = [string](Get-Value $ml 'Mail' 'CredentialScope' 'User')
        TargetName            = ([string](Get-Value $ml 'Mail' 'TargetName' '')).Trim()
        CertificateThumbprint = ([string](Get-Value $ml 'Mail' 'CertificateThumbprint' '')).Replace(' ', '').ToUpperInvariant()
        HeloName              = ([string](Get-Value $ml 'Mail' 'HeloName' '')).Trim()
        From                  = ([string](Get-Value $ml 'Mail' 'From' '')).Trim()
        FromName              = [string](Get-Value $ml 'Mail' 'FromName' 'Exchange Log Report')
        To                    = [string[]]@(Get-Value $ml 'Mail' 'To' @() | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
        Cc                    = [string[]]@(Get-Value $ml 'Mail' 'Cc' @() | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
        Bcc                   = [string[]]@(Get-Value $ml 'Mail' 'Bcc' @() | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
        Subject               = [string](Get-Value $ml 'Mail' 'Subject' '{Title} - {Type} report - {Period}')
        Attach                = [string](Get-Value $ml 'Mail' 'Attach' 'Html')
        MaxAttachmentMB       = Test-Int (Get-Value $ml 'Mail' 'MaxAttachmentMB' 7) 'Mail.MaxAttachmentMB' 1 150
        TimeoutSeconds        = Test-Int (Get-Value $ml 'Mail' 'TimeoutSeconds' 60) 'Mail.TimeoutSeconds' 5 600
    }
    foreach ($key in $ml.Keys) { if ($key -notin $mail.Keys) { $errors.Add("Mail.$key is not a known setting. Allowed: $($mail.Keys -join ', ').") } }
    $enum = @{ Encryption = 'None', 'StartTls', 'Tls'; Authentication = 'Anonymous', 'Basic', 'Kerberos'; CredentialScope = 'User', 'Computer'; Attach = 'Html', 'Zip', 'None' }
    foreach ($key in $enum.Keys) {
        $match = @($enum[$key] | Where-Object { $_ -eq $mail[$key] }) | Select-Object -First 1
        if ($match) { $mail[$key] = $match } else { $errors.Add("Mail.$key must be $($enum[$key] -join ', ') (current value: '$($mail[$key])').") }
    }
    if ($mail.Port -eq 0) { $mail.Port = if ($mail.Encryption -eq 'Tls') { 465 } else { 25 } }
    if ($mail.Authentication -eq 'Basic' -and $mail.Encryption -eq 'None') { $errors.Add("Mail.Authentication = 'Basic' sends a password: it needs Mail.Encryption = 'StartTls' or 'Tls'.") }
    if ($mail.CertificateThumbprint -and $mail.CertificateThumbprint -notmatch '^[0-9A-F]{40}$') { $errors.Add('Mail.CertificateThumbprint must be the 40 hexadecimal characters of the SHA-1 thumbprint of the certificate of the SMTP server.') }
    if ($mail.SmtpServer -and $mail.SmtpServer -match '\s|/') { $errors.Add("Mail.SmtpServer must be a host name (current value: '$($mail.SmtpServer)').") }
    foreach ($a in @(@($mail.From | Where-Object { $_ }) + $mail.To + $mail.Cc + $mail.Bcc)) {
        try { $parsed = [Net.Mail.MailAddress]::new($a); if ($parsed.Address -ne $a) { throw 'display name' } } catch { $errors.Add("Mail: '$a' is not an e-mail address (write the address only, for example 'team@contoso.com').") }
    }
    if ($mail.Enabled) { foreach ($p in @(Test-ExlMailReady -Settings ([pscustomobject]@{ Mail = $mail }))) { $errors.Add("Mail.Enabled is `$true but $p") } }
    $settings['Mail'] = $mail
    if ($settings.Storage.DetailRetentionDays -gt $settings.Storage.RetentionDays) { $errors.Add('Storage.DetailRetentionDays cannot be greater than Storage.RetentionDays.') }
    foreach ($role in $settings.Sources.TransportRoles) { if ($role -notin 'FrontEnd', 'Hub', 'Mailbox') { $errors.Add("Sources.TransportRoles accepts FrontEnd, Hub and Mailbox (current value: '$role').") } }
    if ($settings.Report.DefaultRange -notin 'Last24Hours', 'Last7Days', 'Last30Days', 'PreviousMonth') { $errors.Add('Report.DefaultRange must be Last24Hours, Last7Days, Last30Days or PreviousMonth.') }
    if ($settings.Report.DefaultType -notin 'Usage', 'Detailed') { $errors.Add("Report.DefaultType must be 'Usage' or 'Detailed'.") }
    if (-not $settings.Report.Formats.Count -or @($settings.Report.Formats | Where-Object { $_ -notin 'Csv', 'Html' }).Count) { $errors.Add("Report.Formats must contain 'Csv', 'Html' or both.") }
    if ($settings.Report.CsvDelimiter -notin ';', ',', "`t", '|') { $errors.Add("Report.CsvDelimiter must be ';', ',', '|' or a tab.") }
    if (-not $settings.Report.FilePrefix -or $settings.Report.FilePrefix.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { $errors.Add('Report.FilePrefix must be a valid file name part.') }
    try { $settings['Zone'] = Get-ExlTimeZone $settings.Report.TimeZone } catch { $errors.Add($_.Exception.Message) }
    $found = if ($discovery -and $discovery['Servers'] -is [hashtable]) { $discovery['Servers'] } else { @{} }
    $settings.Servers = @(foreach ($b in $blocks) {
            $name = ([string]$b['Name']).ToUpperInvariant()
            $match = @($found.Keys | Where-Object { $_ -eq $name })
            Resolve-ExlServerPaths -Name $name -Configured $b -Discovered $(if ($match.Count) { $found[$match[0]] }) -Sources $settings.Sources
        })
    if ($errors.Count) { throw ("Invalid configuration ($Path):`n - " + ($errors -join "`n - ")) }
    return $settings
}

function Join-ExlPath {
    <# Joins two path parts as text: unlike Join-Path, the drive does not need to exist on this computer (D:\ of another server). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$ChildPath)
    if (-not $ChildPath) { return $Path.TrimEnd('\') }
    return $Path.TrimEnd('\') + '\' + $ChildPath.TrimStart('\')
}

function Resolve-ExlServerPaths {
    <#
    .SYNOPSIS
        Folder of each log source of one server, with where it comes from (Origin):
          Configuration      a path key of the Servers block (always wins)
          ConfigurationRoot  derived from a root key of the Servers block (ExchangePath, IisLogPath,
                             LoggingPath, TransportLogPath)
          Discover           config\ExchangeLogReport.paths.psd1, written by -Mode Discover from the
                             real Exchange and IIS settings
          Default            derived from the roots found by Discover, or from the default
                             installation folders on C:
          IIS                set during a collection from applicationHost.config (Test-ExlIisSites)
        Role (Mailbox or Edge) comes from the Servers block or the paths file (RoleOrigin Configuration
        or Discover); otherwise it is Mailbox until Resolve-ExlServerRole detects an Edge Transport server.
    #>
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Configured = @{}, [hashtable]$Discovered, [Parameter(Mandatory)]$Sources)
    $origin = [ordered]@{}
    $rootOrigin = @{}
    $root = {
        param([string]$Key, [string]$Default, [string]$Parent)
        if ($Configured[$Key]) { $rootOrigin[$Key] = 'Configuration'; return ([string]$Configured[$Key]).TrimEnd('\') }
        if ($Discovered -and $Discovered[$Key]) { $rootOrigin[$Key] = 'Discover'; return ([string]$Discovered[$Key]).TrimEnd('\') }
        $rootOrigin[$Key] = if ($Parent) { $rootOrigin[$Parent] } else { 'Default' }
        return $Default
    }
    $exchange = & $root 'ExchangePath' "\\$Name\c$\Program Files\Microsoft\Exchange Server\V15"
    $iis = & $root 'IisLogPath' "\\$Name\c$\inetpub\logs\LogFiles"
    $logging = & $root 'LoggingPath' (Join-ExlPath $exchange 'Logging') 'ExchangePath'
    $transport = & $root 'TransportLogPath' (Join-ExlPath $exchange 'TransportRoles\Logs') 'ExchangePath'
    $defaults = [ordered]@{
        HttpProxyPath       = Join-ExlPath $logging 'HttpProxy'
        MapiHttpPath        = Join-ExlPath $logging 'MapiHttp\Mailbox'
        ImapLogPath         = Join-ExlPath $logging 'Imap4'
        PopLogPath          = Join-ExlPath $logging 'Pop3'
        IisFrontEndPath     = Join-ExlPath $iis $Sources.IisSite
        IisBackEndPath      = Join-ExlPath $iis $Sources.IisBackEndSite
        FrontEndReceivePath = Join-ExlPath $transport 'FrontEnd\ProtocolLog\SmtpReceive'
        FrontEndSendPath    = Join-ExlPath $transport 'FrontEnd\ProtocolLog\SmtpSend'
        HubReceivePath      = Join-ExlPath $transport 'Hub\ProtocolLog\SmtpReceive'
        HubSendPath         = Join-ExlPath $transport 'Hub\ProtocolLog\SmtpSend'
        MailboxReceivePath  = Join-ExlPath $transport 'Mailbox\ProtocolLog\SmtpReceive'
        MailboxSendPath     = Join-ExlPath $transport 'Mailbox\ProtocolLog\SmtpSend'
        EdgeReceivePath     = Join-ExlPath $transport 'Edge\ProtocolLog\SmtpReceive'
        EdgeSendPath        = Join-ExlPath $transport 'Edge\ProtocolLog\SmtpSend'
        MessageTrackingPath = Join-ExlPath $transport 'MessageTracking'
    }
    $canonical = { param($Value) @($script:ServerRoles | Where-Object { $_ -eq [string]$Value }) | Select-Object -First 1 }
    $role = 'Mailbox'; $roleOrigin = 'Default'
    if ($Configured['Role'] -and (& $canonical $Configured['Role'])) { $role = & $canonical $Configured['Role']; $roleOrigin = 'Configuration' }
    elseif ($Discovered -and $Discovered['Role'] -and (& $canonical $Discovered['Role'])) { $role = & $canonical $Discovered['Role']; $roleOrigin = 'Discover' }
    $server = [ordered]@{ Name = $Name; Role = $role; RoleOrigin = $roleOrigin; ExchangePath = $exchange; IisLogPath = $iis; Discovered = [bool]$Discovered }
    foreach ($key in $script:ServerPathKeys) {
        if ($Configured[$key]) { $server[$key] = ([string]$Configured[$key]).TrimEnd('\'); $origin[$key] = 'Configuration' }
        elseif ($Discovered -and $Discovered[$key]) { $server[$key] = ([string]$Discovered[$key]).TrimEnd('\'); $origin[$key] = 'Discover' }
        else {
            $server[$key] = $defaults[$key]
            $parent = if ($key -in 'HttpProxyPath', 'MapiHttpPath', 'ImapLogPath', 'PopLogPath') { 'LoggingPath' } elseif ($key -like 'Iis*') { 'IisLogPath' } else { 'TransportLogPath' }
            $origin[$key] = if ($rootOrigin[$parent] -eq 'Configuration') { 'ConfigurationRoot' } else { 'Default' }
        }
    }
    $server['ImapProtocolLog'] = if ($Discovered -and $Discovered.ContainsKey('ImapProtocolLog')) { [bool]$Discovered['ImapProtocolLog'] } else { $null }
    $server['PopProtocolLog'] = if ($Discovered -and $Discovered.ContainsKey('PopProtocolLog')) { [bool]$Discovered['PopProtocolLog'] } else { $null }
    # Other IIS sites hosting Exchange virtual directories (found by -Mode Discover, checked by every collection).
    $server['IisCustomSites'] = @(if ($Discovered -and $Discovered['IisCustomSites']) {
            foreach ($c in @($Discovered['IisCustomSites'])) {
                if ($c -and $c.Name -and $c.Folder) { [pscustomobject]@{ Name = [string]$c.Name; Id = [string]$c.Id; Role = [string]$c.Role; Vdirs = [string]$c.Vdirs; Folder = ([string]$c.Folder).TrimEnd('\') } }
            }
        })
    $server['ApplicationLogSources'] = @(if ($Discovered -and $Discovered['ApplicationLogSources']) {
            foreach ($a in $Discovered['ApplicationLogSources']) {
                if ($a.Kind -notin 'HttpProxy', 'MapiBackEnd' -or -not $a.Folder -or -not $a.Application -or -not $a.Site) {
                    throw "Invalid ApplicationLogSources entry for $Name in the paths file. Run -Mode Discover again."
                }
                [pscustomobject]@{ Kind = [string]$a.Kind; Protocol = [string]$a.Protocol; Site = [string]$a.Site; Application = [string]$a.Application
                    Folder = [string]$a.Folder; DefaultFolder = [string]$a.DefaultFolder; ConfigFile = [string]$a.ConfigFile; Setting = [string]$a.Setting; Customized = [bool]$a.Customized }
            }
        })
    $server['ApplicationLogForcedKinds'] = @(
        if ($Configured['HttpProxyPath'] -or $Configured['LoggingPath']) { 'HttpProxy' }
        if ($Configured['MapiHttpPath'] -or $Configured['LoggingPath']) { 'MapiBackEnd' }
    )
    $server['Origin'] = $origin
    return [pscustomobject]$server
}

#endregion

#region 3. Engine (SQLite + compiled C#) ------------------------------------------------------

function Assert-ExlPackageIntegrity {
    param([string]$Root, [switch]$RequireManifest, [switch]$DevelopmentMode)
    $packageRoot = Split-Path ([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Root))) -Parent
    $manifest = Join-Path $packageRoot 'PackageIntegrity.json'
    if ((Test-Path -LiteralPath $manifest) -and -not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw 'PackageIntegrity.json must be a file; engine initialization is blocked.'
    }
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        if ($RequireManifest -and -not $DevelopmentMode) {
            throw 'PackageIntegrity.json is missing. Serve requires a verified portable package; use -DevelopmentMode explicitly for an unverified source checkout.'
        }
        if ($RequireManifest) { Write-Warning 'DevelopmentMode: no package manifest; package byte integrity and publisher authentication are not established.' }
        return
    }
    $verifier = Join-Path $packageRoot 'tools\Test-PackageIntegrity.ps1'
    if (-not (Test-Path -LiteralPath $verifier -PathType Leaf)) { throw 'Package integrity verifier is missing; no engine or SQLite library was loaded.' }
    $result = @(& $verifier -Root $packageRoot)
    if ($result.Count -ne 1 -or -not $result[0].PSObject.Properties['Integrity'] -or $result[0].Integrity -ne 'Passed') {
        throw 'Package integrity verifier did not return an explicit Passed result; engine initialization is blocked.'
    }
}

function Initialize-ExlEngine {
    <#
    .SYNOPSIS
        Loads SQLite (lib\sqlite) and compiles src\Engine.*.cs into memory.
        Existing collector\bin assemblies are never loaded or created by this pilot.
    #>
    [CmdletBinding()]
    param([string]$Root = $script:ToolRoot)
    Assert-ExlPackageIntegrity -Root $Root
    $sources = @(Get-ChildItem -LiteralPath (Join-Path $Root 'src') -Filter 'Engine.*.cs' -File | Sort-Object Name)
    if (-not $sources.Count) { throw "Engine source files not found in $(Join-Path $Root 'src')." }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $all = [Text.StringBuilder]::new()
        foreach ($f in $sources) { [void]$all.Append($f.Name).Append((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash) }
        $hash = [Convert]::ToHexString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($all.ToString())))
    } finally { $hasher.Dispose() }
    $existing = 'ExchangeLogReport.Store' -as [type]
    if ($existing) {
        if ($existing.Assembly.Location -or [AppDomain]::CurrentDomain.GetData('ExchangeLogReportAngular.EngineSourceHash') -ne $hash) {
            throw 'An engine from disk or different source is already loaded. Restart PowerShell; the pilot only uses its current in-memory engine.'
        }
        return
    }
    $lib = Join-Path $Root 'lib\sqlite'
    $arch = if ([Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq 'Arm64') { 'win-arm64' } else { 'win-x64' }
    $native = Join-Path $lib "runtimes\$arch\e_sqlite3.dll"
    if (-not (Test-Path -LiteralPath $native)) { throw "SQLite native library not found: $native" }
    [void][Runtime.InteropServices.NativeLibrary]::Load($native)
    foreach ($name in 'SQLitePCLRaw.core', 'SQLitePCLRaw.provider.e_sqlite3', 'SQLitePCLRaw.batteries_v2', 'Microsoft.Data.Sqlite') {
        Add-Type -LiteralPath (Join-Path $lib "$name.dll")
    }
    [SQLitePCL.Batteries_V2]::Init()

    $references = @(
            (Join-Path $lib 'Microsoft.Data.Sqlite.dll'), (Join-Path $lib 'SQLitePCLRaw.core.dll'), 'System.IO.Compression', 'System.Text.Json', 'System.Text.Encodings.Web', 'System.Data.Common', 'System.Linq',
            'System.Collections', 'System.Text.RegularExpressions', 'System.Runtime', 'System.Memory', 'System.ComponentModel.Primitives', 'System.ComponentModel',
            'System.Transactions.Local', 'System.Text.Encoding.Extensions', 'System.Runtime.Extensions', 'System.IO', 'System.Runtime.InteropServices', 'System.Console',
            'System.Collections.NonGeneric', 'System.Diagnostics.Process', 'System.Linq.Expressions', 'System.Collections.Concurrent', 'System.Threading',
            'System.Threading.Thread', 'System.Threading.Tasks.Parallel', 'System.IO.FileSystem', 'System.Net.Primitives', 'System.Net.Security', 'System.Net.Sockets',
            'System.Net.NetworkInformation', 'System.Security.Cryptography', 'System.Security.Cryptography.X509Certificates', 'Microsoft.Win32.Primitives', 'System.IO.Compression.ZipFile',
            'System.Net.HttpListener', 'System.Net.WebHeaderCollection', 'System.Threading.Tasks', 'System.Security.AccessControl', 'System.Security.Claims', 'System.IO.FileSystem.AccessControl', 'System.Security.Principal.Windows', 'System.Security.Principal', 'System.ObjectModel', 'System.Collections.Specialized', 'netstandard')
    Add-Type -LiteralPath $sources.FullName -ReferencedAssemblies $references -IgnoreWarnings -WarningAction SilentlyContinue
    [AppDomain]::CurrentDomain.SetData('ExchangeLogReportAngular.EngineSourceHash', $hash)
}

function Start-ExlServe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatabasePath,
        [string]$WebRoot = (Join-Path $script:ToolRoot '..\web'),
        [ValidateRange(0, 65535)][int]$Port = 8765,
        [switch]$NoBrowser,
        [string]$ReadyFile,
        [switch]$ReadyFileWithToken,
        [ValidateRange(1, 120)][int]$RequestTimeoutSeconds = 15,
        [ValidateRange(0, 256)][int]$MmapMB = 0,
        [switch]$DevelopmentMode
    )
    Assert-ExlPackageIntegrity -Root $script:ToolRoot -RequireManifest -DevelopmentMode:$DevelopmentMode
    Initialize-ExlEngine
    $options = [ExchangeLogReport.ServeOptions]::new()
    $options.DatabasePath = [IO.Path]::GetFullPath($DatabasePath)
    $options.WebRoot = [IO.Path]::GetFullPath($WebRoot)
    $options.Port = $Port
    $options.NoBrowser = [bool]$NoBrowser
    if ($ReadyFile) { $options.ReadyFile = [IO.Path]::GetFullPath($ReadyFile) }
    $options.ReadyFileWithToken = [bool]$ReadyFileWithToken
    $options.RequestTimeoutSeconds = $RequestTimeoutSeconds
    $options.MmapMB = $MmapMB
    [ExchangeLogReport.ServeHost]::Run($options)
}

function Resolve-ExlReportCollection {
    <#
    .SYNOPSIS
        Report mode: does the report read the new log lines first? The age of the data is the end of the last
        collection recorded in the database (scheduled task or not, any account).
          -Collect                                         yes (first collection: the last BackfillDays days)
          no collection in the database (or no database)   no: the report stops, run -Mode Collect first
          -NoCollect                                       no
          the period ends before the last collection       no: the data of the period is complete
          last collection younger than MaxDataAgeMinutes   no (an hourly scheduled collection keeps it fresh)
          Report.MaxDataAgeMinutes = 0                     no, the age is shown
          otherwise                                        yes: only the lines written since the last collection
        Returns Collect, NoData, LastMs and Text (banner and log).
    #>
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Period, [switch]$Collect, [switch]$NoCollect, [long]$NowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    if ($Collect -and $NoCollect) { throw '-Collect and -NoCollect cannot be used together.' }
    $last = $null
    if (Test-Path -LiteralPath $Settings.Storage.DatabasePath) {
        $store = Open-ExlStore -Settings $Settings -ReadOnly
        try {
            $v = $store.Query("SELECT MAX(ended_ms) FROM run WHERE status IN ('Completed', 'Incomplete');", $null).Rows[0][0]
            if ($null -ne $v -and $v -isnot [DBNull]) { $last = [long]$v }
        }
        finally { $store.Dispose() }
    }
    $maxAge = [int]$Settings.Report.MaxDataAgeMinutes
    $when = if ($null -ne $last) { 'collected until {0} ({1} ago)' -f (Format-ExlLocalTime $last $Settings.Zone), (Format-ExlDuration ([Math]::Max(0, $NowMs - $last) / 1000.0)) }
    $r = [pscustomobject]@{ Collect = $false; NoData = $false; LastMs = $last; Text = $when }
    if ($Collect) {
        $r.Collect = $true
        $r.Text = '-Collect: the new log lines are read first' + $(if ($null -ne $last) { " (last collection $(Format-ExlLocalTime $last $Settings.Zone))" } else { " (first collection: the last $($Settings.Collection.BackfillDays) days)" })
    }
    elseif ($null -eq $last) { $r.NoData = $true; $r.Text = 'no collection in the database yet' }
    elseif ($NoCollect) { $r.Text = "$when $([char]0x00B7) -NoCollect" }
    elseif ($Period.EndMs -le $last) { $r.Text = "$when $([char]0x00B7) the period is complete" }
    elseif ($NowMs - $last -le [long]$maxAge * 60000) { }
    elseif ($maxAge -eq 0) { $r.Text = "$when $([char]0x00B7) add -Collect to read the new log lines first" }
    else { $r.Collect = $true; $r.Text = "$when, more than $maxAge min (Report.MaxDataAgeMinutes): the new log lines are read first" }
    return $r
}

function Open-ExlStore {
    param([Parameter(Mandatory)]$Settings, [switch]$ReadOnly)
    $path = $Settings.Storage.DatabasePath
    if ($ReadOnly -and -not (Test-Path -LiteralPath $path)) { throw "The database does not exist yet: $path. Run a collection first (-Mode Collect)." }
    return [ExchangeLogReport.Store]::new($path, [bool]$ReadOnly, $script:ToolVersion)
}

#endregion

#region 4. Command line and periods ---------------------------------------------------------------

function Get-ExlIgnoredParameter {
    <#
    .SYNOPSIS
        Parameters of the command line that the mode does not use, one sentence per group with the reason:
        a parameter is never ignored silently (the script shows these sentences as warnings).
          period      -Range -Month -Date -Start -End        -Mode Report only
          report      -ReportType -User -Include*Details      -Mode Report only
                      -OutputPath -Collect -NoCollect
          servers     -Server                                 -Mode Report and Collect
          discovery   -ConnectTo                              -Mode Discover only
          credential  -Credential                             -Mode Discover and MailTest
          mail        -SendMail                               -Mode Report only
    #>
    param([Parameter(Mandatory)][ValidateSet('Report', 'Collect', 'Status', 'Discover', 'MailTest')][string]$Mode, [string[]]$Name)
    $groups = @(
        @{ Names = 'Range', 'Month', 'Date', 'Start', 'End'; Modes = @('Report'); Why = @{
                Collect  = 'a collection reads every new log line, whatever its date; the period only selects what the report shows (-Mode Report)'
                Status   = '-Mode Status describes the whole database, whatever the period'
                Discover = '-Mode Discover reads no log line, it only finds the log folders'
                MailTest = '-Mode MailTest only sends a test message' } }
        @{ Names = 'ReportType', 'User', 'IncludeRoutingDetails', 'IncludeSessionDetails', 'OutputPath', 'Collect', 'NoCollect', 'SendMail'; Modes = @('Report'); Why = 'used by -Mode Report only' }
        @{ Names = 'Server'; Modes = 'Report', 'Collect'; Why = @{
                Status   = '-Mode Status describes the whole database'
                Discover = '-Mode Discover reads the settings of every Exchange server'
                MailTest = '-Mode MailTest reads no log' } }
        @{ Names = @('ConnectTo'); Modes = @('Discover'); Why = 'used by -Mode Discover only' }
        @{ Names = @('Credential'); Modes = 'Discover', 'MailTest'; Why = 'used by -Mode Discover (remote PowerShell) and -Mode MailTest (account of the SMTP server) only' }
    )
    foreach ($g in $groups) {
        if ($Mode -in $g.Modes) { continue }
        $hit = @($g.Names | Where-Object { $_ -in $Name })
        if (-not $hit.Count) { continue }
        $why = if ($g.Why -is [hashtable]) { $g.Why[$Mode] } else { $g.Why }
        '{0} ignored with -Mode {1}: {2}.' -f (($hit | ForEach-Object { "-$_" }) -join ', '), $Mode, $why
    }
}

function Resolve-ExlRange {
    <#
    .SYNOPSIS
        Range of the report from the command line. A period parameter selects its range on its own:
        -Start / -End Custom, -Month Month, -Date Day. Without one: -Range, else the default range.
        A period parameter is never ignored: with another -Range, or with the parameter of another range,
        it is an error.
    #>
    param([string]$Range, [string]$Month, [string]$Date, [string]$Start, [string]$End, [Parameter(Mandatory)][string]$Default)
    $given = [ordered]@{}
    if ($Start -or $End) { $given['Custom'] = '-Start / -End' }
    if ($Month) { $given['Month'] = '-Month' }
    if ($Date) { $given['Day'] = '-Date' }
    if ($given.Count -gt 1) { throw ('{0} each define the period of the report: use only one of them.' -f (@($given.Values) -join ' and ')) }
    if (-not $given.Count) { return $(if ($Range) { $Range } else { $Default }) }
    $implied = @($given.Keys)[0]
    if ($Range -and $Range -ne $implied) {
        $verb = if ($implied -eq 'Custom') { 'define' } else { 'defines' }
        throw ('{0} {1} the period of the report (-Range {2}) and cannot be combined with -Range {3}: remove -Range {3}.' -f $given[$implied], $verb, $implied, $Range)
    }
    return $implied
}

function ConvertTo-ExlUnixMs {
    <# Text date -> Unix ms. Without an explicit offset (Z, +02:00) the date is read in the report time zone. #>
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][TimeZoneInfo]$Zone)
    $culture = [Globalization.CultureInfo]::InvariantCulture
    if ($Text -match '(Z|[+-]\d{2}:?\d{2})$') { return [DateTimeOffset]::Parse($Text, $culture).ToUnixTimeMilliseconds() }
    $formats = [string[]]@('yyyy-MM-dd', 'yyyy-MM-dd HH:mm', 'yyyy-MM-ddTHH:mm', 'yyyy-MM-dd HH:mm:ss', 'yyyy-MM-ddTHH:mm:ss')
    $local = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Text, $formats, $culture, [Globalization.DateTimeStyles]::None, [ref]$local)) {
        throw "Invalid date '$Text'. Use yyyy-MM-dd, 'yyyy-MM-dd HH:mm' or an ISO 8601 value with an offset."
    }
    return [ExchangeLogReport.TimeUtil]::LocalToUnixMs($local, $Zone)
}

function Resolve-ExlPeriod {
    <#
    .SYNOPSIS
        Converts a range name into a [start, end) period in Unix milliseconds. The end is never later than now.
        Last24Hours / Last7Days / Last30Days, PreviousMonth, Month (-Month yyyy-MM), Day (-Date yyyy-MM-dd), Custom (-Start / -End).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Last24Hours', 'Last7Days', 'Last30Days', 'PreviousMonth', 'Month', 'Day', 'Custom')][string]$Range,
        [string]$Month, [string]$Date, [string]$Start, [string]$End,
        [Parameter(Mandatory)][TimeZoneInfo]$Zone,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $nowMs = $Now.ToUnixTimeMilliseconds(); $nowMs -= $nowMs % 1000
    $day = 86400000L
    switch ($Range) {
        'Last24Hours' { $s = $nowMs - $day; $e = $nowMs }
        'Last7Days' { $s = $nowMs - 7 * $day; $e = $nowMs }
        'Last30Days' { $s = $nowMs - 30 * $day; $e = $nowMs }
        'PreviousMonth' {
            $local = [TimeZoneInfo]::ConvertTime($Now, $Zone).DateTime
            $first = [datetime]::new($local.Year, $local.Month, 1).AddMonths(-1)
            $s = [ExchangeLogReport.TimeUtil]::LocalToUnixMs($first, $Zone)
            $e = [ExchangeLogReport.TimeUtil]::LocalToUnixMs($first.AddMonths(1), $Zone)
        }
        'Month' {
            $first = [datetime]::MinValue
            if (-not $Month -or -not [datetime]::TryParseExact($Month, 'yyyy-MM', $culture, 'None', [ref]$first)) { throw '-Range Month requires -Month in the format yyyy-MM (for example -Month 2026-09).' }
            $s = [ExchangeLogReport.TimeUtil]::LocalToUnixMs($first, $Zone)
            $e = [ExchangeLogReport.TimeUtil]::LocalToUnixMs($first.AddMonths(1), $Zone)
        }
        'Day' {
            $d = [datetime]::MinValue
            if (-not $Date -or -not [datetime]::TryParseExact($Date, 'yyyy-MM-dd', $culture, 'None', [ref]$d)) { throw '-Range Day requires -Date in the format yyyy-MM-dd.' }
            $s = [ExchangeLogReport.TimeUtil]::LocalToUnixMs($d, $Zone)
            $e = [ExchangeLogReport.TimeUtil]::LocalToUnixMs($d.AddDays(1), $Zone)
        }
        'Custom' {
            if (-not $Start -or -not $End) { throw '-Range Custom requires -Start and -End.' }
            $s = ConvertTo-ExlUnixMs $Start $Zone
            $e = ConvertTo-ExlUnixMs $End $Zone
        }
    }
    if ($e -gt $nowMs) { $e = $nowMs }
    if ($e -le $s) { throw "The requested period is empty or in the future ($Range)." }
    [pscustomobject]@{ Range = $Range; StartMs = [long]$s; EndMs = [long]$e }
}

#endregion

#region 5. Sources --------------------------------------------------------------------------------

function Get-ExlSources {
    <#
    .SYNOPSIS
        Lists the log folders to read for one server, as (Kind, Role, Label, Folder, Filter, Recurse, PathKey, Optional) entries.
          HttpProxy    <HttpProxyPath>\<protocol>\*.log
          Iis          <IisFrontEndPath>\*.log (front end: Default Web Site, W3SVC1 by default)
                       + the folder of each custom IIS site hosting front-end Exchange virtual directories
          SmtpReceive  <FrontEnd|Hub|Mailbox>ReceivePath (Mailbox: with the Delivery and Submission sub-folders)
          SmtpSend     <FrontEnd|Hub|Mailbox>SendPath
          Tracking     <MessageTrackingPath>\MSGTRK*.log (hub, delivery, submission, moderation)
          MapiBackEnd  <MapiHttpPath>\*.log (Outlook MAPI over HTTP, back end)
          EasBackEnd   <IisBackEndPath>\*.log (Exchange Back End web site: ActiveSync results)
                       + the folder of each custom back-end IIS site hosting ActiveSync
          Imap4, Pop3  <ImapLogPath>, <PopLogPath> (optional: protocol logging must be enabled)
        Edge Transport server (Role Edge): SmtpReceive <EdgeReceivePath>, SmtpSend <EdgeSendPath> and
        Tracking only; it has no client access, and Sources.TransportRoles does not apply to it.
        Optional: the folder may not exist yet (logging off or never used, custom site without traffic).
    #>
    param([Parameter(Mandatory)]$Server, [Parameter(Mandatory)]$Settings)
    $src = $Settings.Sources
    $list = [Collections.Generic.List[object]]::new()
    $add = { param($Kind, $Role, $Label, $Key, $Filter, $Recurse) $list.Add([pscustomobject]@{ Kind = $Kind; Role = $Role; Label = $Label; Folder = $Server.$Key; Filter = $Filter; Recurse = $Recurse; PathKey = $Key; Optional = $Kind -in $script:OptionalKinds }) }
    if (Test-ExlEdgeServer $Server) {
        if ($src.SmtpReceive) { & $add 'SmtpReceive' 'Edge' 'SMTP in (Edge)' 'EdgeReceivePath' '*.log' $true }
        if ($src.SmtpSend) { & $add 'SmtpSend' 'Edge' 'SMTP out (Edge)' 'EdgeSendPath' '*.log' $true }
        if ($src.MessageTracking) { & $add 'Tracking' $null 'Tracking' 'MessageTrackingPath' 'MSGTRK*.log' $false }
        return $list.ToArray()
    }
    $custom = {
        param($Kind, $Role, [scriptblock]$Where)
        foreach ($c in @($Server.IisCustomSites | Where-Object { $_ -and $_.Role -eq $Role } | Where-Object $Where)) {
            $label = 'IIS ' + $(if ($c.Name.Length -gt 15) { $c.Name.Substring(0, 14) + [char]0x2026 } else { $c.Name })
            $list.Add([pscustomobject]@{ Kind = $Kind; Role = $null; Label = $label; Folder = $c.Folder; Filter = '*.log'; Recurse = $false; PathKey = 'IisCustomSites'; Optional = $true; Site = $c.Name })
        }
    }
    $appSources = @($Server.ApplicationLogSources)
    $folderKey = { param([string]$Folder) (ConvertTo-ExlRemotePath -Server $Server.Name -Path $Folder).TrimEnd('\') }
    if ($src.HttpProxy) {
        & $add 'HttpProxy' $null 'HttpProxy' 'HttpProxyPath' '*.log' $true
        if ('HttpProxy' -notin $Server.ApplicationLogForcedKinds) {
            $apps = @($appSources | Where-Object Kind -eq 'HttpProxy')
            if ($apps.Count -and -not @($apps | Where-Object { -not $_.Customized }).Count) { $list[$list.Count - 1].Optional = $true }
            foreach ($a in $apps | Sort-Object { $_.Folder.Length }) {
                $key = & $folderKey $a.Folder
                $covered = @($list | Where-Object {
                    $_.Kind -eq 'HttpProxy' -and ($key -eq (& $folderKey $_.Folder) -or
                        ($_.Recurse -and $key.StartsWith((& $folderKey $_.Folder) + '\', [StringComparison]::OrdinalIgnoreCase)))
                })
                if ($covered.Count) { continue }
                # A customized parent folder covers a previously added child folder too.
                for ($i = $list.Count - 1; $i -ge 0; $i--) {
                    if ($list[$i].Kind -eq 'HttpProxy' -and (& $folderKey $list[$i].Folder).StartsWith($key + '\', [StringComparison]::OrdinalIgnoreCase)) { $list.RemoveAt($i) }
                }
                $list.Add([pscustomobject]@{ Kind = 'HttpProxy'; Role = $null; Label = "HttpProxy $($a.Protocol)"; Folder = $a.Folder
                        Filter = '*.log'; Recurse = $true; PathKey = 'ApplicationLogSources'; Optional = -not $a.Customized })
            }
        }
    }
    if ($src.IisFrontEnd) {
        & $add 'Iis' $null 'IIS front end' 'IisFrontEndPath' '*.log' $false
        & $custom 'Iis' 'FrontEnd' { $_.Folder -ne $Server.IisFrontEndPath }
    }
    if ($src.MapiBackEnd) {
        & $add 'MapiBackEnd' $null 'MAPI back end' 'MapiHttpPath' '*.log' $false
        if ('MapiBackEnd' -notin $Server.ApplicationLogForcedKinds) {
            foreach ($a in $appSources | Where-Object Kind -eq 'MapiBackEnd') {
                $existing = @($list | Where-Object { $_.Kind -eq 'MapiBackEnd' -and (& $folderKey $_.Folder) -eq (& $folderKey $a.Folder) })
                if ($existing.Count) { if ($a.Customized) { $existing[0].Optional = $false }; continue }
                $list.Add([pscustomobject]@{ Kind = 'MapiBackEnd'; Role = $null; Label = 'MAPI ' + $a.Application.TrimEnd('/').Split('/')[-1]; Folder = $a.Folder
                        Filter = '*.log'; Recurse = $false; PathKey = 'ApplicationLogSources'; Optional = -not $a.Customized })
            }
        }
    }
    if ($src.EasBackEnd) {
        & $add 'EasBackEnd' $null 'EAS back end (IIS)' 'IisBackEndPath' '*.log' $false
        & $custom 'EasBackEnd' 'BackEnd' { $_.Folder -ne $Server.IisBackEndPath -and $_.Vdirs -match '(^|, )Microsoft-Server-ActiveSync(,|$)' }
    }
    if ($src.PopImap) {
        & $add 'Imap4' $null 'IMAP4' 'ImapLogPath' '*.log' $false
        & $add 'Pop3' $null 'POP3' 'PopLogPath' '*.log' $false
    }
    foreach ($role in $src.TransportRoles) {
        if ($src.SmtpReceive) { & $add 'SmtpReceive' $role "SMTP in ($role)" "$($role)ReceivePath" '*.log' $true }
        if ($src.SmtpSend) { & $add 'SmtpSend' $role "SMTP out ($role)" "$($role)SendPath" '*.log' $true }
    }
    if ($src.MessageTracking) { & $add 'Tracking' $null 'Tracking' 'MessageTrackingPath' 'MSGTRK*.log' $false }
    return $list.ToArray()
}

function Test-ExlStaleSource {
    <#
    .SYNOPSIS
        Age of the newest file of a source that Exchange writes all the time (HttpProxy, IIS front and
        back end), when it is older than Collection.StaleSourceHours: logging stopped, or the logs were
        moved and the tool still reads the old folder. Returns $null when the source is not stale.
    #>
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Settings)
    $hours = $Settings.Collection.StaleSourceHours
    if ($hours -le 0 -or $Source.Kind -notin $script:AlwaysActiveKinds -or ($Source.PSObject.Properties['Optional'] -and $Source.Optional)) { return $null }
    if (-not $Plan.Total) { return 'no log file' }
    $age = [DateTime]::UtcNow - $Plan.Newest
    if ($age.TotalHours -lt $hours) { return $null }
    return 'newest file ' + (Format-ExlDuration $age.TotalSeconds) + ' old'
}

function Test-ExlServerAccess {
    <# Checks that the log folders of a server can be read; returns the list of problems. #>
    param([Parameter(Mandatory)]$Server, [Parameter(Mandatory)]$Settings)
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($s in Get-ExlSources $Server $Settings) {
        if (-not (Test-Path -LiteralPath $s.Folder -PathType Container -ErrorAction SilentlyContinue) -and -not $s.Optional) {
            $problems.Add("$($s.Label): folder not found or not readable ($($s.Folder))")
        }
    }
    return $problems.ToArray()
}

function Get-ExlPathOrigin {
    <# One phrase telling where the log paths of a server come from (shown by the access check). #>
    param([Parameter(Mandatory)]$Server)
    $origins = @($Server.Origin.Values)
    $configured = 'Configuration' -in $origins -or 'ConfigurationRoot' -in $origins
    if ('Discover' -in $origins) { return 'paths from -Mode Discover' + $(if ($configured) { ' and the configuration' } else { '' }) }
    if ($configured) { return 'paths set in the configuration' }
    if ('IIS' -in $origins) { return 'IIS folders from applicationHost.config, other default paths: run -Mode Discover to check them' }
    return 'default paths: run -Mode Discover to check them'
}

function Test-ExlEdgeServer {
    <# $true for an Edge Transport server (Role Edge): SMTP protocol logs and message tracking only. #>
    param([Parameter(Mandatory)]$Server)
    return [bool]($Server.PSObject.Properties['Role'] -and $Server.Role -eq 'Edge')
}

function Resolve-ExlServerRole {
    <#
    .SYNOPSIS
        Exchange role of a server for the collection and the report: Mailbox, or Edge (Edge Transport server: no IIS,
        HttpProxy, MAPI, ActiveSync, POP3 or IMAP4, only the SMTP protocol logs and message tracking).
        A Role set in the Servers block or recorded by -Mode Discover is kept. Otherwise it is detected:
          this computer     registry key HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\EdgeTransportRole
          another server    AD LDS folder of the Edge role (<ExchangePath>\TransportRoles\data\Adam)
                            and no client access folder (<ExchangePath>\FrontEnd\HttpProxy)
          -Store (report)   the other servers are not contacted: Edge SMTP logs already collected
                            (role Edge in smtp_transaction, or files of an Edge\ProtocolLog folder)
                            and no client access log collected for the server.
        A folder that cannot be read counts as absent (Mailbox). Sets Role and RoleOrigin (Detected)
        on the server object and returns the role.
    #>
    param([Parameter(Mandatory)]$Server, [switch]$Local, $Store)
    if ($Server.RoleOrigin -in 'Configuration', 'Discover') { return $Server.Role }
    $how = $null
    if ($Local) {
        if (Test-Path -LiteralPath $script:EdgeRoleKey) { $how = "registry key $script:EdgeRoleKey" }
    }
    elseif ($Store) {
        $sql = "SELECT (SELECT COUNT(*) FROM smtp_transaction WHERE server = @s AND role = 'Edge') + " +
               "(SELECT COUNT(*) FROM source_file WHERE server = @s AND kind IN ('SmtpReceive', 'SmtpSend') AND path LIKE '%\Edge\ProtocolLog\%'), " +
               "(SELECT COUNT(*) FROM source_file WHERE server = @s AND kind IN ('HttpProxy', 'Iis', 'MapiBackEnd', 'EasBackEnd', 'Imap4', 'Pop3'))"
        $row = $Store.Query($sql, @{ s = $Server.Name }).Rows[0]
        if ([long]$row[0] -gt 0 -and [long]$row[1] -eq 0) { $how = 'Edge SMTP logs and no client access log in the database' }
    }
    elseif ((Test-Path -LiteralPath (Join-ExlPath $Server.ExchangePath 'TransportRoles\data\Adam') -PathType Container -ErrorAction SilentlyContinue) -and
            -not (Test-Path -LiteralPath (Join-ExlPath $Server.ExchangePath 'FrontEnd\HttpProxy') -PathType Container -ErrorAction SilentlyContinue)) {
        $how = "$($Server.ExchangePath)\TransportRoles\data\Adam without FrontEnd\HttpProxy"
    }
    if ($how) {
        $Server.Role = 'Edge'
        $Server.RoleOrigin = 'Detected'
        Write-ExlLog 'INFO' "$($Server.Name): Edge Transport server detected ($how)."
    }
    return $Server.Role
}

#endregion

#region 6. Collection -----------------------------------------------------------------------------

function New-ExlCollector {
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][long]$RunId)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $o = [ExchangeLogReport.CollectorOptions]::new()
    $o.Zone = $Settings.Zone
    $o.RunId = $RunId
    $o.NowMs = $now
    $o.RetentionCutoffMs = $now - [long]$Settings.Storage.RetentionDays * 86400000
    $o.DetailCutoffMs = $now - [long]$Settings.Storage.DetailRetentionDays * 86400000
    $o.RecoveryWindowMs = [long]$Settings.Collection.RecoveryWindowMinutes * 60000
    $o.SmtpIdleMs = [long]$Settings.Collection.SmtpSessionIdleMinutes * 60000
    $o.StoreAllRequests = $Settings.Collection.StoreAllRequests
    $o.FullDetailUsers = $Settings.Collection.FullDetailUsers
    $o.SystemUserPatterns = $Settings.Noise.SystemUserPatterns
    $o.ProbeUserAgentPatterns = $Settings.Noise.ProbeUserAgentPatterns
    $o.ProbeUrlPatterns = $Settings.Noise.ProbeUrlPatterns
    $o.ProbeSenderPatterns = $Settings.Noise.ProbeSenderPatterns
    $o.ExcludedClientIps = $Settings.Noise.ExcludedClientIps
    $o.IgnoredTrackingEvents = $Settings.Noise.IgnoredTrackingEvents
    $o.SessionIdleMs = [long]$Settings.Collection.SessionIdleMinutes * 60000
    $o.SlowRequestMs = [long]$Settings.Collection.SlowRequestMs
    $o.LongRunningPatterns = $Settings.Collection.LongRunningPatterns
    $o.SessionDetailRequests = $Settings.Collection.SessionDetailRequests
    $o.MaxSegmentSteps = $Settings.Collection.MaxSessionSteps
    $o.Parallelism = $Settings.Collection.Parallelism
    $o.MaxFilesPerServer = $Settings.Collection.MaxFilesPerServer
    $o.DeferRollups = [ExchangeLogReport.DeferRollupsMode]$Settings.Collection.DeferRollups
    return [ExchangeLogReport.Collector]::new($Store, $o)
}

function Invoke-ExlCollection {
    <#
    .SYNOPSIS
        Reads the new part of the log files of every server into the database. The folders of every server are
        listed in parallel, then the files are read by Collection.Parallelism threads at the same time (every
        server and source together) and written by one thread in batched transactions. One table row per server
        and source, printed when its last file is saved; a progress bar for the whole collection. Returns the totals.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][long]$RunId, [object[]]$Servers)
    if (-not $Servers) { $Servers = $Settings.Servers }
    $collector = New-ExlCollector -Store $Store -Settings $Settings -RunId $RunId
    $since = [DateTime]::UtcNow.AddDays(-$Settings.Collection.BackfillDays)
    $totals = [ordered]@{ Files = 0L; Bytes = 0L; Lines = 0L; Kept = 0L; Noise = 0L; Stored = 0L; Errors = 0L; Recovered = 0L; Seconds = 0.0; Threads = 0; Statistics = $null; Unreachable = [Collections.Generic.List[string]]::new(); Stale = [Collections.Generic.List[string]]::new(); NoiseReasons = @{} }
    $clock = [Diagnostics.Stopwatch]::StartNew()

    # ---- plan: the folders of every server, listed in parallel ------------------------------------------------
    $jobs = [Collections.Generic.List[ExchangeLogReport.SourceJob]]::new()
    $sourceOf = @{}
    foreach ($server in $Servers) {
        foreach ($source in Get-ExlSources $server $Settings) {
            $job = [ExchangeLogReport.SourceJob]::new()
            $job.Index = $jobs.Count; $job.Server = $server.Name; $job.Kind = $source.Kind; $job.Role = $source.Role; $job.Label = $source.Label
            $job.Folder = $source.Folder; $job.Filter = $source.Filter; $job.Recurse = [bool]$source.Recurse
            $sourceOf[$job.Index] = [pscustomobject]@{ Server = $server; Source = $source }
            $jobs.Add($job)
        }
    }
    Write-Progress -Id 1 -Activity 'Reading the new log lines' -Status ("Listing {0} log folder(s) of {1} server(s)" -f $jobs.Count, @($Servers).Count)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $collector.Plan($jobs.ToArray(), $since)
    Write-ExlLog 'INFO' ("Listing: {0} folder(s), {1} file(s), {2} to read, in {3:0.0} s" -f $jobs.Count, ($jobs | Measure-Object Total -Sum).Sum, ($jobs | ForEach-Object { $_.Files.Count } | Measure-Object -Sum).Sum, $watch.Elapsed.TotalSeconds)
    Write-Progress -Id 1 -Activity 'Reading the new log lines' -Completed

    Write-ExlTableRow -Header
    $staleOf = @{}
    $toRead = [Collections.Generic.List[ExchangeLogReport.SourceJob]]::new()
    foreach ($job in $jobs) {
        $server = $sourceOf[$job.Index].Server; $source = $sourceOf[$job.Index].Source
        if (-not $job.FolderFound) {
            # SMTP, MAPI, POP and IMAP protocol log folders exist only where protocol logging is enabled (or has been used);
            # IIS creates the folder of a site at its first request.
            if ($source.Optional) {
                Write-ExlLog 'INFO' "$($server.Name) $($source.Label): no folder ($($source.Folder))"
                $disabled = ($source.Kind -eq 'Imap4' -and $server.ImapProtocolLog -eq $false) -or ($source.Kind -eq 'Pop3' -and $server.PopProtocolLog -eq $false)
                if (-not $disabled) { Write-ExlTableRow -Status Skip -Server $server.Name -Source $source.Label -Files '-' -Read '-' -Lines 0 -Kept 0 -Noise '-' -Duration 'no folder' -Rate '' }
                continue
            }
            Write-ExlTableRow -Status Fail -Server $server.Name -Source $source.Label -Files '-' -Read '-' -Lines 0 -Kept 0 -Noise '-' -Duration 'not found' -Rate ''
            $totals.Unreachable.Add("$($server.Name) $($source.Label): $($source.Folder)")
            continue
        }
        if ($job.ListError) { Write-ExlLog 'WARN' "$($server.Name) $($source.Label): $($source.Folder) could not be listed completely: $($job.ListError)" }
        $stale = Test-ExlStaleSource -Source $source -Plan ([pscustomobject]@{ Total = $job.Total; Newest = $job.Newest }) -Settings $Settings
        if ($stale) { $staleOf[$job.Index] = $stale; $totals.Stale.Add("$($server.Name) $($source.Label): $stale ($($source.Folder))") }
        if (-not $job.Files.Count) {
            if ($stale) { Write-ExlTableRow -Status Warn -Server $server.Name -Source $source.Label -Files "0/$($job.Total)" -Read '-' -Lines 0 -Kept 0 -Noise '-' -Duration 'stale' -Rate '' }
            elseif ($job.Total) { Write-ExlTableRow -Status Skip -Server $server.Name -Source $source.Label -Files "0/$($job.Total)" -Read '-' -Lines 0 -Kept 0 -Noise '-' -Duration 'up to date' -Rate '' }
            else { Write-ExlTableRow -Status Skip -Server $server.Name -Source $source.Label -Files '0' -Read '-' -Lines 0 -Kept 0 -Noise '-' -Duration 'no file' -Rate '' }
            continue
        }
        $toRead.Add($job)
    }

    # ---- read: one row per source as soon as its last file is saved -------------------------------------------------
    $row = {
        param($job)
        $stale = $staleOf[$job.Index]
        foreach ($kv in $job.NoiseReasons.GetEnumerator()) { $totals.NoiseReasons[$kv.Key] = [long]$totals.NoiseReasons[$kv.Key] + $kv.Value }
        $totals.Stored += $job.Stored; $totals.Errors += $job.Errors
        if (-not $job.FilesRead -and -not $job.Errors) {
            # Only empty files, or files not grown since the listing (IIS writes its buffer every minute).
            Write-ExlTableRow -Status $(if ($stale) { 'Warn' } else { 'Skip' }) -Server $job.Server -Source $job.Label -Files "0/$($job.Total)" -Read '-' -Lines 0 -Kept 0 -Noise '-' -Duration $(if ($stale) { 'stale' } else { 'up to date' }) -Rate ''
            return
        }
        $noisePercent = if ($job.Lines) { '{0:0}%' -f (100.0 * $job.Noise / $job.Lines) } else { '-' }
        $seconds = $job.Seconds
        $rate = if ($seconds -gt 0) { '{0}/s' -f (Format-ExlBytes ($job.Bytes / $seconds)) } else { '' }
        Write-ExlTableRow -Status $(if ($job.Errors -or $stale) { 'Warn' } else { 'Ok' }) -Server $job.Server -Source $job.Label -Files ("{0}/{1}" -f $job.FilesRead, $job.Total) `
            -Read (Format-ExlBytes $job.Bytes) -Lines $job.Lines -Kept $job.Kept -Noise $noisePercent -Duration (Format-ExlDuration $seconds) -Rate $rate
        if ($job.Errors) { Write-ExlItem Warn ("{0} file(s) could not be read on {1} ({2}); see the log file." -f $job.Errors, $job.Server, $job.Label) }
        $totals.Files += $job.FilesRead; $totals.Bytes += $job.Bytes; $totals.Lines += $job.Lines; $totals.Kept += $job.Kept; $totals.Noise += $job.Noise
    }
    $log = { param($run) foreach ($l in $run.TakeLog()) { $level, $text = $l.Split('|', 2); Write-ExlLog $level $text } }
    if ($toRead.Count) {
        $run = $collector.Start($toRead.ToArray())
        $totals.Threads = $collector.EffectiveParallelism
        Write-ExlLog 'INFO' ("Reading {0} file(s), {1}, with {2} thread(s)" -f ($toRead | ForEach-Object { $_.Files.Count } | Measure-Object -Sum).Sum, (Format-ExlBytes (($toRead | Measure-Object PlannedBytes -Sum).Sum)), $run.Progress().Workers)
        try {
            while (-not $run.Wait(400)) {
                foreach ($job in $run.TakeFinished()) { & $row $job }
                & $log $run
                $p = $run.Progress()
                $percent = if ($p.BytesPlanned -gt 0) { [int][Math]::Min(100, 100.0 * $p.BytesDone / $p.BytesPlanned) } else { 0 }
                $speed = if ($p.Seconds -gt 0) { $p.BytesDone / $p.Seconds } else { 0 }
                $left = if ($speed -gt 0 -and $p.BytesDone -gt 0) { ' ' + [char]0x00B7 + ' ' + (Format-ExlDuration (($p.BytesPlanned - $p.BytesDone) / $speed)) + ' left' } else { '' }
                Write-Progress -Id 1 -Activity ("Reading the new log lines ({0} threads)" -f $p.Workers) -PercentComplete $percent `
                    -Status ("{0} of {1} files {2} {3} of {4} {2} {5}/s{6}" -f (Format-ExlNumber $p.FilesDone), (Format-ExlNumber $p.FilesPlanned), [char]0x00B7, (Format-ExlBytes $p.BytesDone), (Format-ExlBytes $p.BytesPlanned), (Format-ExlBytes $speed), $left) `
                    -CurrentOperation (@($p.Reading | Select-Object -First 3) -join '   ')
            }
        }
        finally {
            # Ctrl+C or an error of this loop: stop the threads before the database is closed.
            if (-not $run.Wait(0)) { $run.Stop(); [void]$run.Wait(-1) }
            Write-Progress -Id 1 -Activity 'Reading the new log lines' -Completed
        }
        foreach ($job in $run.TakeFinished()) { & $row $job }
        & $log $run
        $totals.Statistics = $run.Statistics
        Write-ExlLog 'INFO' ("Collection threads: {0}; WAL {1}" -f $run.Statistics, (Format-ExlBytes $Store.WalBytes))
        if ($run.Error) { throw ("The collection stopped: {0}" -f $run.Error.Message) }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $totals.Recovered = $collector.Complete()
    Write-ExlLog 'INFO' ("Back-end IMAP/POP connections and recoveries ({0}) written in {1:0.0} s; WAL {2}" -f $totals.Recovered, $watch.Elapsed.TotalSeconds, (Format-ExlBytes $Store.WalBytes))
    $totals.Seconds = $clock.Elapsed.TotalSeconds
    return [pscustomobject]$totals
}

#endregion

#region 7. Report ---------------------------------------------------------------------------------

function New-ExlReport {
    <#
    .SYNOPSIS
        Builds the CSV and HTML files of a period into a new sub-folder of Report.OutputPath.
        Edge report when every server of the report (-Server, or the configuration) is an Edge Transport
        server: mail flow only (SMTP clients and destinations, messages), no client access view.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Period,
        [ValidateSet('Usage', 'Detailed')][string]$ReportType = 'Usage', [string[]]$User, [string[]]$Server, [bool]$IncludeRoutingDetails = $true, [bool]$IncludeSessionDetails = $true)
    $zone = $Settings.Zone
    $scope = @($Settings.Servers | Where-Object { -not $Server -or $_.Name -in $Server })
    $edge = $scope.Count -gt 0 -and @($scope | Where-Object { -not (Test-ExlEdgeServer $_) }).Count -eq 0
    $stamp = (Format-ExlLocalTime $Period.StartMs $zone 'yyyyMMdd-HHmm') + '_' + (Format-ExlLocalTime $Period.EndMs $zone 'yyyyMMdd-HHmm')
    $folderName = '{0}_{1}{2}_{3}' -f $Settings.Report.FilePrefix, $(if ($edge) { 'Edge' } else { '' }), $ReportType, $stamp
    if ($User) { $folderName += '_' + (($User | ForEach-Object { ($_ -replace '[^\w@.-]', '_') }) -join '+') }
    $folderName += '_' + (Get-Date -Format 'HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $q = [ExchangeLogReport.ReportRequest]::new()
    $q.StartMs = $Period.StartMs; $q.EndMs = $Period.EndMs
    $q.DetailCutoffMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$Settings.Storage.DetailRetentionDays * 86400000
    $q.Zone = $zone; $q.TimeZoneName = $Settings.Report.TimeZone
    $q.Users = [string[]]@($User | Where-Object { $_ }); $q.Servers = [string[]]@($Server | Where-Object { $_ })
    $q.ConfiguredServers = [string[]]@($Settings.Servers | ForEach-Object Name)
    $q.Detailed = $ReportType -eq 'Detailed'
    $q.IncludeRoutingDetails = $IncludeRoutingDetails
    $q.IncludeSessionDetails = $IncludeSessionDetails
    $q.SlowRequestMs = [long]$Settings.Collection.SlowRequestMs
    $q.WriteCsv = 'Csv' -in $Settings.Report.Formats
    $q.WriteHtml = 'Html' -in $Settings.Report.Formats
    $q.OutputFolder = Join-Path $Settings.Report.OutputPath $folderName
    $q.FilePrefix = $Settings.Report.FilePrefix
    $q.CsvDelimiter = $Settings.Report.CsvDelimiter
    $q.TemplatePath = $Settings.Report.TemplatePath
    $q.Title = $Settings.Report.Title
    $q.Edge = $edge
    $q.EdgeServers = [string[]]@($scope | Where-Object { Test-ExlEdgeServer $_ } | ForEach-Object Name)
    if ($edge -and $q.Title -eq $script:DefaultReportTitle) { $q.Title = 'Edge Transport mail flow' }
    $q.ToolVersion = $script:ToolVersion
    $q.Generated = Format-ExlLocalTime ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) $zone 'yyyy-MM-dd HH:mm'
    $q.RecoveryWindowMs = [long]$Settings.Collection.RecoveryWindowMinutes * 60000
    $q.MaxHtmlRows = $Settings.Report.MaxHtmlRows
    $q.MemoryBudgetMB = $Settings.Report.MemoryBudgetMB
    $q.Parallelism = $Settings.Report.Parallelism
    $q.Progress = [Action[string]]{ param($stage) Write-ExlLog 'INFO' "Report stage: $stage" }
    $result = [ExchangeLogReport.ReportBuilder]::Build($Store, $q)
    # The slowest steps in the execution log: what to look at when a report is slow.
    foreach ($s in @($result.Steps | Select-Object -First 8)) { Write-ExlLog 'INFO' "Report step: $s" }
    Write-ExlLog 'INFO' ("Report buffers: budget {0} MB including SQLite caches (source {4} MB, temporary 8 MB), estimated row/worker peak {1:0.0} MB, {2} CPU worker(s), {3} rows spooled to disk (process RAM includes other allocations)." -f
        $result.MemoryBudgetMB, ($result.PeakBufferBytes / 1MB), $result.Parallelism, $result.SpilledRows, $result.DatabaseCacheMB)
    Write-ExlLog 'INFO' ("Report I/O: {0} transcript value(s) decoded ({1}); scratch peak {2}." -f
        $result.TranscriptReads, (Format-ExlBytes $result.TranscriptBytes), (Format-ExlBytes $result.ScratchPeakBytes))
    return $result
}

#endregion

#region 8. Status and maintenance ------------------------------------------------------------------

function Show-ExlStatus {
    <# Database content per server and source, and the noise set aside by the last collection. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings)
    $zone = $Settings.Zone; $K = $script:C; $dot = [char]0x00B7
    $counts = $Store.Query("SELECT (SELECT COUNT(*) FROM access_usage), (SELECT COUNT(*) FROM access_event), (SELECT COUNT(*) FROM smtp_transaction), (SELECT COUNT(*) FROM message_event), (SELECT COUNT(DISTINCT message_id) FROM message_event), (SELECT COUNT(DISTINCT user) FROM access_usage)", $null).Rows[0]
    Write-ExlItem Info ('{0}  ({1})' -f $Store.FilePath, (Format-ExlBytes $Store.FileBytes)) -Icon Database
    Write-ExlItem Info ('{0} real users {6} {1} daily usage rows {6} {2} failed requests kept {6} {3} SMTP transactions {6} {4} tracking events ({5} messages)' -f
        (Format-ExlNumber $counts[5]), (Format-ExlNumber $counts[0]), (Format-ExlNumber $counts[1]), (Format-ExlNumber $counts[2]), (Format-ExlNumber $counts[3]), (Format-ExlNumber $counts[4]), $dot) -Icon Chart
    $rows = $Store.Query("SELECT server, kind, COUNT(*), SUM(offset), SUM(lines), SUM(kept), SUM(noise), MIN(first_ms), MAX(last_ms), MAX(updated_ms) FROM source_file GROUP BY server, kind ORDER BY server, kind", $null).Rows
    if (-not $rows.Count) { Write-ExlItem Warn 'Nothing has been collected yet. Run: .\Invoke-ExchangeLogReport.ps1 -Mode Collect'; return }
    Write-Host ''
    Write-Host ('      {0}{1}{2,-10} {3,-12} {4,7} {5,10} {6,13} {7,11} {8,6}  {9,-33} {10}{11}' -f $K.Dim, ('  ' + $script:IconPad), 'Server', 'Source', 'Files', 'Read', 'Lines', 'Kept', 'Noise', 'Data from - to', 'Last read', $K.Reset)
    $staleMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$Settings.Collection.StaleSourceHours * 3600000
    $stale = [Collections.Generic.List[string]]::new()
    foreach ($r in $rows) {
        $noise = if ($r[4]) { '{0:0}%' -f (100.0 * $r[6] / $r[4]) } else { '-' }
        $range = if ($r[7]) { '{0} {1} {2}' -f (Format-ExlLocalTime $r[7] $zone 'yyyy-MM-dd HH:mm'), [char]0x2192, (Format-ExlLocalTime $r[8] $zone 'MM-dd HH:mm') } else { '-' }
        $last = if ($r[9]) { Format-ExlLocalTime $r[9] $zone 'yyyy-MM-dd HH:mm' } else { '-' }
        $old = $Settings.Collection.StaleSourceHours -gt 0 -and [string]$r[1] -in $script:AlwaysActiveKinds -and $null -ne $r[8] -and [long]$r[8] -lt $staleMs
        if ($old) { $stale.Add("$($r[0]) $($r[1])") }
        $state = if ($old) { 'Warn' } else { 'Ok' }
        Write-Host ('      {0}{1}{2}{3,-10} {4,-12} {5,7} {6,10} {7,13} {8,11} {9,6}  {10,-33} {11}' -f $(if ($old) { $K.Yellow } else { $K.Green }), (Get-ExlIcon $state), $K.Reset, $r[0], $r[1], (Format-ExlNumber $r[2]), (Format-ExlBytes ([double]$r[3])), (Format-ExlNumber $r[4]), (Format-ExlNumber $r[5]), $noise, $range, $last)
        Write-ExlLog 'INFO' ("Status {0} {1}: {2} files, {3} lines, {4} kept, noise {5}, {6}" -f $r[0], $r[1], $r[2], $r[4], $r[5], $noise, $range)
    }
    if ($stale.Count) { Write-ExlItem Warn ("No log line newer than {0} h for {1}: the scheduled collection stopped, the logging stopped or the logs were moved (run -Mode Discover)." -f $Settings.Collection.StaleSourceHours, ($stale -join ', ')) }
    $configured = @($Settings.Servers | ForEach-Object Name)
    $collected = @($rows | ForEach-Object { [string]$_[0] } | Select-Object -Unique)
    foreach ($n in $configured) { if ($n -notin $collected) { Write-ExlItem Warn "$n is in the configuration but nothing has been collected from it yet." } }
    $last = $Store.Query("SELECT id, started_ms, status FROM run WHERE mode IN ('Collect','Report') AND files > 0 ORDER BY id DESC LIMIT 1", $null).Rows
    if ($last.Count) {
        $noise = $Store.Query("SELECT reason, SUM(lines) FROM noise WHERE run_id = @r GROUP BY reason ORDER BY 2 DESC LIMIT 12", @{ r = $last[0][0] }).Rows
        if ($noise.Count) {
            Write-Host ''
            Write-ExlItem Info ('Noise set aside by the last collection ({0}):' -f (Format-ExlLocalTime $last[0][1] $zone 'yyyy-MM-dd HH:mm')) -Icon Filter
            foreach ($n in $noise) { Write-Host ('          {0}{1,12}{2}  {3}' -f $K.Dim, (Format-ExlNumber $n[1]), $K.Reset, $n[0]) }
        }
    }
}

function Invoke-ExlRetention {
    <# Deletes what is older than Storage.RetentionDays (aggregates, messages) and DetailRetentionDays (request details, transcripts). #>
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$Settings)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $cutoff = $now - [long]$Settings.Storage.RetentionDays * 86400000
    $detail = $now - [long]$Settings.Storage.DetailRetentionDays * 86400000
    $day = Format-ExlLocalTime $cutoff $Settings.Zone 'yyyy-MM-dd'
    $result = $Store.Purge($cutoff, $day, $detail)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $wal = $Store.WalBytes
    $Store.Checkpoint()
    Write-ExlLog 'INFO' ("Retention: deletes {0:0.0} s, vacuum {1:0.0} s, statistics {2:0.0} s, WAL {3} written into the database in {4:0.0} s" -f $result.DeleteSeconds, $result.VacuumSeconds, $result.OptimizeSeconds, (Format-ExlBytes $wal), $watch.Elapsed.TotalSeconds)
    return $result
}

function Enter-ExlLock {
    <# Prevents two executions from collecting at the same time. Release with Exit-ExlLock. -NoWait: $null when the lock is taken. #>
    param([Parameter(Mandatory)][string]$Path, [int]$TimeoutSeconds = 30, [switch]$NoWait)
    [void][IO.Directory]::CreateDirectory((Split-Path $Path -Parent))
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            $stream = [IO.FileStream]::new($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
            $stream.SetLength(0)
            $bytes = [Text.Encoding]::UTF8.GetBytes(("{0} pid {1} since {2:o}" -f [Environment]::MachineName, $PID, (Get-Date)))
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
            return $stream
        } catch [IO.IOException] {
            if ($NoWait) { return $null }
            if ([DateTime]::UtcNow -ge $deadline) {
                $owner = try { [IO.File]::ReadAllText($Path) } catch { 'unknown' }
                throw "Another execution is already collecting ($owner). Wait for it to finish, or build the report without -Collect: it uses the data already collected."
            }
            Start-Sleep -Seconds 2
        }
    }
}

function Exit-ExlLock { param($Lock) if ($Lock) { $Lock.Dispose() } }

#endregion


#region 9. Discovery of the log paths ------------------------------------------------------------

function ConvertTo-ExlRemotePath {
    <#
    .SYNOPSIS
        Folder of a server as seen from the collector: unchanged on the collector itself (a local path is
        faster), administrative share of its drive for the other servers (D:\Logs -> \\EXCH01\D$\Logs).
    #>
    param([Parameter(Mandatory)][string]$Server, [AllowEmptyString()][AllowNull()][string]$Path, [switch]$Local)
    if (-not $Path) { return $null }
    $p = $Path.Trim().TrimEnd('\')
    if ($Local -or $p.StartsWith('\\')) { return $p }
    if ($p -match '^([A-Za-z]):(\\.*)?$') { return '\\{0}\{1}${2}' -f $Server, $Matches[1].ToUpperInvariant(), $Matches[2] }
    return $p
}

function Get-ExlIisLogFolders {
    <#
    .SYNOPSIS
        Log folder (directory\W3SVC<id>), format, target and Exchange role of each IIS site of a server,
        read from its applicationHost.config (through \\<server>\ADMIN$: local administrator rights are
        needed). Returns $null when the file cannot be read.
        A site is an Exchange site when one of its virtual directories points to the Exchange front end
        (...\FrontEnd\HttpProxy\...) or back end (...\ClientAccess\...), or runs in an MSExchange* pool:
        Exchange itself is not queried, so a custom OWA/ECP site is found the same way as the default ones.
    #>
    param([Parameter(Mandatory)][string]$Server, [switch]$Local, [string]$File)
    $drive = 'C:'
    if (-not $File) {
        if ($Local) { $File = Join-ExlPath $env:SystemRoot 'System32\inetsrv\config\applicationHost.config'; $drive = $env:SystemDrive }
        else {
            $File = "\\$Server\ADMIN`$\System32\inetsrv\config\applicationHost.config"
            if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
            foreach ($letter in 'C', 'D', 'E', 'F') { if (Test-Path -LiteralPath "\\$Server\$letter`$\Windows\System32\inetsrv" -PathType Container) { $drive = "$($letter):"; break } }
        }
    }
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    $xml = [xml]::new()
    $stream = [IO.FileStream]::new($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $xml.Load($stream) } finally { $stream.Dispose() }
    $attribute = { param($Node, [string]$Name, [string]$Default) if ($null -ne $Node -and $Node.GetAttribute($Name)) { $Node.GetAttribute($Name) } else { $Default } }
    $expand = { param([string]$Directory) ($Directory -replace '(?i)%SystemDrive%', $drive) -replace '(?i)%(SystemRoot|windir)%', "$drive\Windows" }
    $defaults = $xml.SelectSingleNode('/configuration/system.applicationHost/sites/siteDefaults/logFile')
    $directory = & $attribute $defaults 'directory' '%SystemDrive%\inetpub\logs\LogFiles'
    $format = & $attribute $defaults 'logFormat' 'W3C'
    $target = & $attribute $defaults 'logTargetW3C' 'File'
    $enabled = (& $attribute $defaults 'enabled' 'true') -ne 'false'
    $sites = foreach ($site in @($xml.SelectNodes('/configuration/system.applicationHost/sites/site'))) {
        $node = $site.SelectSingleNode('logFile')
        $id = $site.GetAttribute('id')
        $roles = [Collections.Generic.List[string]]::new()
        $vdirs = [Collections.Generic.List[string]]::new()
        $applications = [Collections.Generic.List[object]]::new()
        foreach ($app in @($site.SelectNodes('application'))) {
            $path = $app.GetAttribute('path')
            $physical = & $attribute $app.SelectSingleNode("virtualDirectory[@path='/']") 'physicalPath' ''
            $role = if ($physical -match '(?i)\\FrontEnd\\HttpProxy(\\|$)') { 'FrontEnd' } elseif ($physical -match '(?i)\\ClientAccess(\\|$)') { 'BackEnd' } elseif ($app.GetAttribute('applicationPool') -like 'MSExchange*') { 'Exchange' }
            $applications.Add([pscustomobject]@{ Site = $site.GetAttribute('name'); Path = $path; PhysicalPath = & $expand $physical; Role = $role })
            if (-not $role) { continue }
            $roles.Add($role)
            $top = $path.Trim('/').Split('/')[0]
            if ($top -and -not $vdirs.Contains($top)) { $vdirs.Add($top) }
        }
        $siteName = $site.GetAttribute('name')
        $exchangeRole = if ($roles -contains 'FrontEnd') { 'FrontEnd' } elseif ($roles -contains 'BackEnd') { 'BackEnd' } elseif ($vdirs.Count) { if ($siteName -eq $script:ExchangeSites.IisBackEndPath) { 'BackEnd' } else { 'FrontEnd' } }
        foreach ($a in $applications) { if ($a.Role -eq 'Exchange') { $a.Role = $exchangeRole } }
        [pscustomobject]@{
            Name    = $siteName
            Id      = $id
            Folder  = Join-ExlPath (& $expand (& $attribute $node 'directory' $directory)) "W3SVC$id"
            Format  = & $attribute $node 'logFormat' $format
            Target  = & $attribute $node 'logTargetW3C' $target
            Enabled = (& $attribute $node 'enabled' $(if ($enabled) { 'true' } else { 'false' })) -ne 'false'
            Role    = $exchangeRole
            Vdirs   = $vdirs -join ', '
            Applications = $applications.ToArray()
        }
    }
    [pscustomobject]@{ Central = & $attribute $xml.SelectSingleNode('/configuration/system.applicationHost/log') 'centralLogFileMode' 'Site'; Sites = @($sites)
        SystemDrive = $drive; File = $File; Xml = $xml }
}

function Get-ExlIisSiteMap {
    <#
    .SYNOPSIS
        Exchange IIS sites of a server, from its applicationHost.config: the folders of Default Web Site
        and Exchange Back End (IisFrontEndPath, IisBackEndPath), the other sites hosting Exchange virtual
        directories (Custom) and the settings that leave holes in the data (Problems).
        Folders are as seen from this computer. $null when applicationHost.config cannot be read.
    #>
    param([Parameter(Mandatory)][string]$Server, [switch]$Local, [string]$File)
    $iis = Get-ExlIisLogFolders -Server $Server -Local:$Local -File $File
    if (-not $iis) { return $null }
    $map = [ordered]@{ Central = $iis.Central; IisFrontEndPath = $null; IisBackEndPath = $null; Custom = [Collections.Generic.List[object]]::new(); Problems = [Collections.Generic.List[string]]::new()
        Applications = @($iis.Sites | Where-Object Role | ForEach-Object { $_.Applications }); SystemDrive = $iis.SystemDrive; File = $iis.File; Xml = $iis.Xml }
    foreach ($site in @($iis.Sites | Where-Object Role)) {
        $folder = ConvertTo-ExlRemotePath -Server $Server -Path $site.Folder -Local:$Local
        $key = @($script:ExchangeSites.Keys | Where-Object { $script:ExchangeSites[$_] -eq $site.Name }) | Select-Object -First 1
        if ($key) { $map[$key] = $folder }
        else { $map.Custom.Add([pscustomobject]@{ Name = $site.Name; Id = $site.Id; Role = $site.Role; Vdirs = $site.Vdirs; Folder = $folder }) }
        $what = "IIS site '$($site.Name)'" + $(if ($key) { '' } else { " ($($site.Vdirs))" })
        if (-not $site.Enabled) { $map.Problems.Add("$what has logging disabled: its traffic is not in the reports.") }
        elseif ($site.Target -notmatch 'File') { $map.Problems.Add("$what logs to $($site.Target) only (no log file): its traffic is not in the reports.") }
        elseif ($site.Format -ne 'W3C') { $map.Problems.Add("$what logs in $($site.Format) format; the tool reads W3C logs only.") }
    }
    if ($map.Central -ne 'Site') { $map.Problems.Add("IIS central logging ($($map.Central)) is not supported: the tool reads one log folder per site.") }
    return [pscustomobject]$map
}

function Test-ExlIisSites {
    <#
    .SYNOPSIS
        Collection check of the IIS log folders of a server against its applicationHost.config (read
        at every collection: the IIS settings are the reference). A folder changed since -Mode Discover,
        a new or removed custom Exchange site: the server object is updated so that the new folders
        are read by this collection, and the change is reported (Drift: run -Mode Discover again).
        A folder set in the Servers block of the configuration is kept.
        Returns the findings as (Status, Text, Drift) entries. -File: an applicationHost.config to check
        instead of the server's own (tests).
    #>
    param([Parameter(Mandatory)]$Server, [switch]$Local, [string]$File, $Sources)
    $notes = [Collections.Generic.List[object]]::new()
    $note = { param($Status, $Text, [bool]$Drift) $notes.Add([pscustomobject]@{ Status = $Status; Text = $Text; Drift = $Drift }) }
    $map = $null
    try { $map = Get-ExlIisSiteMap -Server $Server.Name -Local:$Local -File $File } catch { Write-ExlLog 'WARN' "$($Server.Name): applicationHost.config: $($_.Exception.Message)" }
    if (-not $map) {
        & $note 'Warn' "IIS settings not readable (\\$($Server.Name)\ADMIN`$\System32\inetsrv\config\applicationHost.config): the IIS log folders could not be checked." $false
        return $notes.ToArray()
    }
    $same = { param($A, $B) [string]::Equals((ConvertTo-ExlRemotePath -Server $Server.Name -Path $A), (ConvertTo-ExlRemotePath -Server $Server.Name -Path $B), [StringComparison]::OrdinalIgnoreCase) }
    foreach ($key in $script:ExchangeSites.Keys) {
        $live = $map.$key
        if (-not $live -or (& $same $live $Server.$key)) { continue }
        $site = $script:ExchangeSites[$key]
        switch ($Server.Origin[$key]) {
            { $_ -in 'Configuration', 'ConfigurationRoot' } { & $note 'Info' "IIS site '$site' logs to $live; the configuration sets $($Server.$key) (kept: the configuration wins)." $false }
            'Discover' { & $note 'Warn' "IIS logs of '$site' moved to $live (was $($Server.$key)): read from the new folder. Run -Mode Discover to record it." $true }
            default { Write-ExlLog 'INFO' "$($Server.Name): IIS site '$site' logs to $live (from applicationHost.config)." }
        }
        if ($Server.Origin[$key] -notin 'Configuration', 'ConfigurationRoot') { $Server.$key = $live; $Server.Origin[$key] = 'IIS' }
    }
    $known = @($Server.IisCustomSites | Where-Object { $_ })
    foreach ($c in $map.Custom) {
        $before = @($known | Where-Object Name -eq $c.Name) | Select-Object -First 1
        $what = "custom IIS site '$($c.Name)' ($($c.Vdirs), $(if ($c.Role -eq 'BackEnd') { 'back end' } else { 'front end' }))"
        if (-not $before) {
            if ($Server.Discovered) { & $note 'Warn' "New $what since -Mode Discover: read from now on ($($c.Folder)). Run -Mode Discover to record it." $true }
            else { & $note 'Info' "$what found in applicationHost.config: its logs are read too ($($c.Folder))." $false }
        }
        elseif (-not (& $same $c.Folder $before.Folder)) { & $note 'Warn' "IIS logs of the $what moved to $($c.Folder) (was $($before.Folder)): read from the new folder. Run -Mode Discover to record it." $true }
    }
    foreach ($k in $known) {
        if (-not @($map.Custom | Where-Object Name -eq $k.Name).Count) { & $note 'Warn' "Custom IIS site '$($k.Name)' no longer hosts Exchange virtual directories (or was removed). Run -Mode Discover to record it." $true }
    }
    $Server.IisCustomSites = @($map.Custom)
    foreach ($p in $map.Problems) { & $note 'Warn' $p $false }
    foreach ($n in Update-ExlApplicationLogPaths -Server $Server -Map (Get-ExlApplicationLogMap -Server $Server -IisMap $map -Local:$Local -Sources $Sources)) {
        $notes.Add($n)
    }
    return $notes.ToArray()
}

function Read-ExlConfigurationXml {
    param([Parameter(Mandatory)][string]$Path)
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = $null
    try {
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        $xml = [xml]::new()
        $xml.XmlResolver = $null
        $xml.Load($reader)
        return , $xml
    }
    finally { if ($reader) { $reader.Dispose() }; $stream.Dispose() }
}

function Get-ExlApplicationLogMap {
    <# Only settings of the formats parsed by this tool: not MAPI LogPath / LogFilePath, nor native EWS logs. #>
    param([Parameter(Mandatory)]$Server, [Parameter(Mandatory)]$IisMap, [switch]$Local, $Sources)
    $entries = [Collections.Generic.List[object]]::new()
    $failed = [Collections.Generic.List[object]]::new()
    $problems = [Collections.Generic.List[string]]::new()
    $cache = @{}
    $protocols = @{ autodiscover = 'Autodiscover'; ews = 'Ews'; mapi = 'Mapi'; oab = 'Oab'; owa = 'Owa'; ecp = 'Ecp'
        rpc = 'RpcHttp'; powershell = 'PowerShell'; 'microsoft-server-activesync' = 'Eas'; 'owa/calendar' = 'OwaCalendar' }
    $apps = @(if ($IisMap.PSObject.Properties['Applications']) { $IisMap.Applications })
    $expand = {
        param([string]$Path, [string]$Installation = $Server.ExchangePath)
        $variables = @{ ExchangeInstallPath = $Installation.TrimEnd('\') + '\'; SystemDrive = $IisMap.SystemDrive
            SystemRoot = "$($IisMap.SystemDrive)\Windows"; windir = "$($IisMap.SystemDrive)\Windows" }
        foreach ($m in [regex]::Matches($Path, '%([^%]+)%')) {
            if (-not $variables.ContainsKey($m.Groups[1].Value)) { throw [FormatException]::new("Unresolved path variable $($m.Value).") }
        }
        $text = [regex]::Replace($Path.Trim(), '%([^%]+)%', {
                param($m)
                return $variables[$m.Groups[1].Value]
            })
        if (-not [IO.Path]::IsPathFullyQualified($text)) { throw [FormatException]::new('The configured log path must be absolute.') }
        ConvertTo-ExlRemotePath -Server $Server.Name -Path ([IO.Path]::GetFullPath($text)) -Local:$Local
    }
    $read = {
        param([string]$Path, [bool]$Required)
        if ($cache.ContainsKey($Path)) {
            if ($Required -and $null -eq $cache[$Path]) { throw [IO.FileNotFoundException]::new('Application configuration file not found.', $Path) }
            return , $cache[$Path]
        }
        try { $xml = Read-ExlConfigurationXml -Path $Path }
        catch [IO.FileNotFoundException] { if ($Required) { throw }; $xml = $null }
        catch [IO.DirectoryNotFoundException] { if ($Required) { throw }; $xml = $null }
        $cache[$Path] = $xml
        return , $xml
    }
    $applyElements = {
        param($Node, $Values)
        foreach ($child in $Node.ChildNodes) {
            switch ($child.Name) {
                'clear' { $Values.Clear() }
                'remove' { [void]$Values.Remove($child.GetAttribute('key')) }
                'add' { $Values[$child.GetAttribute('key')] = $child.GetAttribute('value') }
            }
        }
    }
    $apply = {
        param($Node, [string]$File, $Values)
        if (-not $Node) { return }
        if ($Node.GetAttribute('configProtectionProvider')) { throw [IO.InvalidDataException]::new('Encrypted appSettings cannot be read by the collector.') }
        $external = $Node.GetAttribute('configSource')
        if ($external) {
            if ([IO.Path]::IsPathRooted($external)) { throw [IO.InvalidDataException]::new('configSource must be relative to its configuration file.') }
            $otherFile = [IO.Path]::GetFullPath((Join-ExlPath (Split-Path $File -Parent) $external))
            $other = & $read $otherFile $true
            if ($other.DocumentElement.Name -ne 'appSettings') { throw [IO.InvalidDataException]::new('configSource must contain an appSettings element.') }
            $Node = $other.DocumentElement
            $File = $otherFile
        }
        & $applyElements $Node $Values
        $external = $Node.GetAttribute('file')
        if ($external) {
            if ([IO.Path]::IsPathRooted($external)) { throw [IO.InvalidDataException]::new('The appSettings file must be relative to its configuration file.') }
            $otherFile = [IO.Path]::GetFullPath((Join-ExlPath (Split-Path $File -Parent) $external))
            $other = & $read $otherFile $false
            if ($other) {
                if ($other.DocumentElement.Name -ne 'appSettings') { throw [IO.InvalidDataException]::new('The external settings file must contain an appSettings element.') }
                & $applyElements $other.DocumentElement $Values
            }
        }
    }
    foreach ($app in $apps) {
        $kind = $null; $protocol = $null; $setting = $null
        $path = $app.Path.Trim('/').ToLowerInvariant()
        if ($app.Role -eq 'FrontEnd' -and $path) {
            $kind = 'HttpProxy'
            $protocol = if ($protocols.ContainsKey($path)) { $protocols[$path] }
                        elseif ($protocols.ContainsKey($path.Split('/')[0])) { $protocols[$path.Split('/')[0]] }
                        else { [IO.Path]::GetFileName($app.PhysicalPath.TrimEnd('\')) }
            $setting = 'RequestDetailsLogger.HttpProxyProtocolLogFolder'
        }
        elseif ($app.Role -eq 'BackEnd' -and $path -in 'mapi/emsmdb', 'mapi/nspi') {
            $kind = 'MapiBackEnd'; $protocol = 'Mapi'; $setting = 'RequestDetailsLogger.MapiHttpMailboxLogFolder'
        }
        if (-not $kind) { continue }
        if ($Sources -and (($kind -eq 'HttpProxy' -and -not $Sources.HttpProxy) -or ($kind -eq 'MapiBackEnd' -and -not $Sources.MapiBackEnd))) { continue }
        $configFile = $null
        $default = $null
        try {
            $physical = & $expand $app.PhysicalPath
            $configFile = Join-ExlPath $physical 'web.config'
            $install = $Server.ExchangePath
            if ($physical -match '^(.*)\\(?:FrontEnd\\HttpProxy|ClientAccess)(?:\\|$)') { $install = $Matches[1] }
            $default = Join-ExlPath $install $(if ($kind -eq 'HttpProxy') { "Logging\HttpProxy\$protocol" } else { 'Logging\MapiHttp\Mailbox' })
            $values = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
            if ($IisMap.PSObject.Properties['Xml'] -and $IisMap.Xml) {
                & $apply $IisMap.Xml.SelectSingleNode('/configuration/appSettings') $IisMap.File $values
                foreach ($location in $IisMap.Xml.SelectNodes('/configuration/location')) {
                    $target = $app.Site + '/' + $app.Path.Trim('/')
                    $scope = $location.GetAttribute('path').TrimEnd('/')
                    if ($scope -eq $target.TrimEnd('/') -or ($location.GetAttribute('inheritInChildApplications') -ne 'false' -and
                            ($scope -eq '' -or $scope -eq '.' -or $target.StartsWith($scope + '/', [StringComparison]::OrdinalIgnoreCase)))) {
                        & $apply $location.SelectSingleNode('appSettings') $IisMap.File $values
                    }
                }
            }
            # ASP.NET inheritance follows virtual paths, not the physical parent of a relocated application.
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $prefixes = @('/') + @(for ($n = 1; $n -le $path.Split('/').Count; $n++) { '/' + ($path.Split('/')[0..($n - 1)] -join '/') })
            foreach ($prefix in $prefixes) {
                $parent = @($apps | Where-Object { $_.Site -eq $app.Site -and ($_.Path -eq '/' -or
                            $prefix -eq $_.Path -or $prefix.StartsWith($_.Path.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)) } |
                    Sort-Object { $_.Path.Length } -Descending | Select-Object -First 1)
                if (-not $parent.Count) { continue }
                $suffix = $prefix.Substring($parent[0].Path.TrimEnd('/').Length).Trim('/').Replace('/', '\')
                $file = Join-ExlPath (Join-ExlPath (& $expand $parent[0].PhysicalPath) $suffix) 'web.config'
                if (-not $seen.Add($file)) { continue }
                $xml = & $read $file ($file -eq $configFile)
                if ($xml) {
                    & $apply $xml.SelectSingleNode('/configuration/appSettings') $file $values
                    $target = $app.Path.Substring($prefix.TrimEnd('/').Length).Trim('/')
                    foreach ($location in $xml.SelectNodes('/configuration/location')) {
                        $scope = $location.GetAttribute('path').Trim('/')
                        $exact = $scope -eq $target -or (($scope -eq '' -or $scope -eq '.') -and $target -eq '')
                        if ($exact -or ($location.GetAttribute('inheritInChildApplications') -ne 'false' -and
                                ($scope -eq '' -or $scope -eq '.' -or $target.StartsWith($scope + '/', [StringComparison]::OrdinalIgnoreCase)))) {
                            & $apply $location.SelectSingleNode('appSettings') $file $values
                        }
                    }
                }
            }
            if (-not $seen.Contains($configFile)) { $xml = & $read $configFile $true; & $apply $xml.SelectSingleNode('/configuration/appSettings') $configFile $values }
            $customized = $values.ContainsKey($setting) -and -not [string]::IsNullOrWhiteSpace($values[$setting])
            $folder = if ($customized) { & $expand $values[$setting] $install } else { ConvertTo-ExlRemotePath -Server $Server.Name -Path $default -Local:$Local }
            $entries.Add([pscustomobject]@{ Kind = $kind; Protocol = $protocol; Site = $app.Site; Application = $app.Path
                    Folder = $folder.TrimEnd('\'); DefaultFolder = $default.TrimEnd('\'); ConfigFile = $configFile; Setting = $setting; Customized = $customized })
        }
        catch [IO.IOException], [IO.InvalidDataException], [UnauthorizedAccessException], [Xml.XmlException], [FormatException], [ArgumentException] {
            $failed.Add([pscustomobject]@{ Kind = $kind; Protocol = $protocol; Site = $app.Site; Application = $app.Path; ConfigFile = $configFile; DefaultFolder = $default })
            $problems.Add("Application '$($app.Site)$($app.Path)': log settings could not be read ($configFile): $($_.Exception.Message)")
        }
    }
    [pscustomobject]@{ Entries = $entries.ToArray(); Failed = $failed.ToArray(); Problems = $problems.ToArray()
        CheckedKinds = @(
            if ($IisMap.PSObject.Properties['Applications']) {
                if (-not $Sources -or $Sources.HttpProxy) { 'HttpProxy' }
                if (-not $Sources -or $Sources.MapiBackEnd) { 'MapiBackEnd' }
            }
        ) }
}

function Update-ExlApplicationLogPaths {
    param([Parameter(Mandatory)]$Server, [Parameter(Mandatory)]$Map)
    $notes = [Collections.Generic.List[object]]::new()
    $before = @($Server.ApplicationLogSources)
    $next = [Collections.Generic.List[object]]::new()
    $key = { param([string]$Folder) (ConvertTo-ExlRemotePath -Server $Server.Name -Path $Folder).TrimEnd('\') }
    foreach ($p in $Map.Problems) { $notes.Add([pscustomobject]@{ Status = 'Warn'; Text = $p; Drift = $false }) }
    foreach ($a in $Map.Entries) {
        $next.Add($a)
        $pathKey = if ($a.Kind -eq 'HttpProxy') { 'HttpProxyPath' } else { 'MapiHttpPath' }
        $forced = $a.Kind -in $Server.ApplicationLogForcedKinds
        $old = @($before | Where-Object { $_.Kind -eq $a.Kind -and $_.Site -eq $a.Site -and $_.Application -eq $a.Application } | Select-Object -First 1)
        $was = if ($old.Count) { $old[0].Folder } elseif ($a.Kind -eq 'MapiBackEnd') { $Server.MapiHttpPath } else { $a.DefaultFolder }
        if ($forced) {
            if ($a.Customized) { $notes.Add([pscustomobject]@{ Status = 'Info'; Text = "Application '$($a.Site)$($a.Application)' logs to $($a.Folder); $pathKey is forced in the configuration (kept)."; Drift = $false }) }
        }
        elseif ((& $key $was) -ne (& $key $a.Folder)) {
            $drift = $Server.Discovered -or $old.Count -gt 0
            $notes.Add([pscustomobject]@{ Status = $(if ($drift) { 'Warn' } else { 'Info' })
                    Text = "Application logs of '$($a.Site)$($a.Application)' moved to $($a.Folder) (was $was): read from the new folder. Run -Mode Discover to record it."
                    Drift = [bool]$drift })
        }
    }
    foreach ($f in $Map.Failed) {
        $known = @($before | Where-Object { $_.Kind -eq $f.Kind -and $_.Site -eq $f.Site -and $_.Application -eq $f.Application })
        foreach ($a in $known) { $next.Add($a) }
        if (-not $known.Count) {
            $default = if ($f.DefaultFolder) { $f.DefaultFolder } elseif ($f.Kind -eq 'MapiBackEnd') { Join-ExlPath $Server.ExchangePath 'Logging\MapiHttp\Mailbox' } else { Join-ExlPath $Server.HttpProxyPath $f.Protocol }
            $folder = if ($f.Kind -eq 'MapiBackEnd' -and $Server.Origin.MapiHttpPath -in 'Discover', 'WebConfig', 'Configuration') { $Server.MapiHttpPath } else { $default }
            $next.Add([pscustomobject]@{ Kind = $f.Kind; Protocol = $f.Protocol; Site = $f.Site; Application = $f.Application
                    Folder = $folder; DefaultFolder = $default; ConfigFile = $f.ConfigFile; Setting = ''; Customized = ((& $key $folder) -ne (& $key $default)) })
        }
    }
    $checked = @(if ($Map.PSObject.Properties['CheckedKinds']) { $Map.CheckedKinds } else {
            foreach ($a in $Map.Entries) { $a.Kind }
            foreach ($a in $Map.Failed) { $a.Kind }
        }) | Select-Object -Unique
    foreach ($a in $before) {
        if ($a.Kind -notin $checked) { $next.Add($a); continue }
        if (-not @($next | Where-Object { $_.Kind -eq $a.Kind -and $_.Site -eq $a.Site -and $_.Application -eq $a.Application }).Count) {
            $forced = $a.Kind -in $Server.ApplicationLogForcedKinds
            $notes.Add([pscustomobject]@{ Status = $(if ($forced) { 'Info' } else { 'Warn' })
                    Text = "Application '$($a.Site)$($a.Application)' no longer supplies its log folder $($a.Folder). Run -Mode Discover to record it."
                    Drift = -not $forced })
        }
    }
    if ($Map.Entries.Count -or $Map.Failed.Count -or $before.Count) {
        $Server.ApplicationLogSources = $next.ToArray()
        if ('MapiBackEnd' -notin $Server.ApplicationLogForcedKinds) {
            $mapi = @($next | Where-Object Kind -eq 'MapiBackEnd' | Sort-Object { $_.Application -notmatch '/emsmdb$' } | Select-Object -First 1)
            if ($mapi.Count) { $Server.MapiHttpPath = $mapi[0].Folder; $Server.Origin.MapiHttpPath = 'WebConfig' }
            elseif ('MapiBackEnd' -in $checked -and @($before | Where-Object Kind -eq 'MapiBackEnd').Count) {
                $Server.MapiHttpPath = Join-ExlPath $Server.ExchangePath 'Logging\MapiHttp\Mailbox'
                $Server.Origin.MapiHttpPath = 'Default'
            }
        }
        if ('HttpProxy' -notin $Server.ApplicationLogForcedKinds) {
            $roots = @($Map.Entries | Where-Object Kind -eq 'HttpProxy' |
                ForEach-Object { [IO.Path]::GetDirectoryName($_.DefaultFolder) } | Sort-Object -Unique)
            if ($roots.Count -eq 1) { $Server.HttpProxyPath = $roots[0]; $Server.Origin.HttpProxyPath = 'WebConfig' }
        }
    }
    return $notes.ToArray()
}

function Get-ExlExchangeSettings {
    <#
    .SYNOPSIS
        Log settings of the Exchange organisation, read by src\Get-ExlExchangeSettings.ps1 in Windows
        PowerShell 5.1: the Exchange cmdlets are supported in Windows PowerShell only. Exchange
        Management Shell on an Exchange server, Exchange remote PowerShell (Kerberos) elsewhere.
    #>
    param([string[]]$ConnectTo, [pscredential]$Credential)
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) { throw "Windows PowerShell 5.1 is needed for -Mode Discover (the Exchange cmdlets run in Windows PowerShell only): $windowsPowerShell not found." }
    $helper = Join-Path $script:ToolRoot 'src\Get-ExlExchangeSettings.ps1'
    $out = Join-Path ([IO.Path]::GetTempPath()) ("elr-discover-{0}.json" -f [guid]::NewGuid().ToString('N'))
    $credentialFile = $null
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $helper, '-OutFile', $out)
    if ($ConnectTo) { $arguments += @('-ConnectTo', ($ConnectTo -join ',')) }
    try {
        if ($Credential) {
            # DPAPI-protected file: readable only by this account on this computer, deleted right after.
            $credentialFile = Join-Path ([IO.Path]::GetTempPath()) ("elr-discover-{0}.xml" -f [guid]::NewGuid().ToString('N'))
            $Credential | Export-Clixml -LiteralPath $credentialFile
            $arguments += @('-CredentialFile', $credentialFile)
        }
        $output = @(& $windowsPowerShell @arguments 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        $code = $LASTEXITCODE
        foreach ($line in $output) { Write-ExlLog 'INFO' "Windows PowerShell: $line" }
        if ($code -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw ($(if ($output.Count) { $output -join ' ' } else { "Windows PowerShell ended with code $code." })) }
        return (Get-Content -LiteralPath $out -Raw -Encoding utf8 | ConvertFrom-Json)
    }
    finally {
        foreach ($f in $out, $credentialFile) { if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    }
}

function Invoke-ExlDiscovery {
    <#
    .SYNOPSIS
        -Mode Discover. Reads the real log settings of every Exchange mailbox server (Exchange cmdlets in
        Windows PowerShell 5.1, View-Only Organization Management is enough) and the IIS log folders
        (applicationHost.config through \\<server>\ADMIN$), checks every folder from this computer and
        writes config\ExchangeLogReport.paths.psd1. Changes nothing on the servers.
        On an Edge Transport server, reads its own transport settings (local Exchange Management Shell,
        local administrator; SYSTEM is accepted): SMTP protocol logs and message tracking, no IIS.
        From the organisation, a configured server that is a subscribed Edge Transport server is recorded
        with its role only (its log settings are not in Active Directory).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Settings, [string]$ConnectTo, [pscredential]$Credential)
    $dot = [char]0x00B7
    $here = [Environment]::MachineName.ToUpperInvariant()
    $isExchange = [bool]$env:ExchangeInstallPath -or (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup')
    $isEdge = Test-Path -LiteralPath $script:EdgeRoleKey
    $warnings = [Collections.Generic.List[string]]::new()
    $warn = { param([string]$Text) $warnings.Add($Text); Write-ExlItem Warn $Text }
    $prop = { param($Object, [string]$Name) if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { $Object.$Name } }
    $account = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    # An Edge Transport server has no RBAC: its local Exchange Management Shell needs a local administrator, SYSTEM included.
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem -and -not $Credential -and -not ($isEdge -and -not $ConnectTo)) {
        throw 'SYSTEM has no Exchange role: run -Mode Discover with an administrator account that is a member of View-Only Organization Management (or use -Credential). The scheduled collection can keep running as SYSTEM.'
    }
    # Exchange Management Shell on an Exchange server; elsewhere remote PowerShell on the first configured server that answers.
    $targets = if ($ConnectTo) { @($ConnectTo) } elseif ($isExchange -and -not $Credential) { @() } else { @($Settings.Servers | ForEach-Object Name) }

    # ---- 1. Exchange (Windows PowerShell 5.1) --------------------------------------------------------
    Write-ExlStep 1 4 'Reading the Exchange settings (Windows PowerShell 5.1)' -Icon Server
    $exchange = Get-ExlExchangeSettings -ConnectTo $targets -Credential $Credential
    $discovered = @($exchange.Servers)
    $edgeEntries = @($discovered | Where-Object { (& $prop $_ 'Role') -eq 'Edge' })
    if ($edgeEntries.Count) {
        Write-ExlItem Ok ("{0} on {1} {2} {3} {2} Edge Transport server {4}" -f $exchange.Method, $exchange.Via, $dot, $exchange.Account, (($edgeEntries | ForEach-Object Name) -join ', '))
    }
    else {
        Write-ExlItem Ok ("{0} on {1} {2} {3} {2} {4} Exchange server(s), {5} mailbox server(s)" -f $exchange.Method, $exchange.Via, $dot, $exchange.Account, $exchange.ExchangeCount, $discovered.Count)
    }
    if (-not $discovered.Count) { throw 'No Exchange mailbox server found in the organisation.' }

    # ---- 2. log folders of each server -----------------------------------------------------------------
    Write-ExlStep 2 4 $(if ($edgeEntries.Count -eq $discovered.Count) { 'Locating the log folders (Edge Transport)' } else { 'Locating the log folders (Exchange and IIS)' }) -Icon Plan
    $labels = [ordered]@{ HttpProxyPath = 'HttpProxy'; MapiHttpPath = 'MAPI back end'; ImapLogPath = 'IMAP4'; PopLogPath = 'POP3'; IisFrontEndPath = 'IIS front end'; IisBackEndPath = 'IIS back end'
        FrontEndReceivePath = 'SMTP in (FrontEnd)'; FrontEndSendPath = 'SMTP out (FrontEnd)'; HubReceivePath = 'SMTP in (Hub)'; HubSendPath = 'SMTP out (Hub)'
        MailboxReceivePath = 'SMTP in (Mailbox)'; MailboxSendPath = 'SMTP out (Mailbox)'; EdgeReceivePath = 'SMTP in (Edge)'; EdgeSendPath = 'SMTP out (Edge)'; MessageTrackingPath = 'Message tracking' }
    $found = [ordered]@{}
    foreach ($x in $discovered) {
        $name = ([string]$x.Name).ToUpperInvariant()
        $local = $name -eq $here
        $edge = (& $prop $x 'Role') -eq 'Edge'
        foreach ($w in @($x.Warnings)) { if ($w) { & $warn "${name}: $w" } }
        $raw = [ordered]@{}
        $map = $null
        $appServer = $null
        if ($edge) {
            # Edge Transport: no client access, no IIS; SMTP protocol logs of the Edge folder and message tracking.
            if (& $prop $x 'InstallPath') { $raw.ExchangePath = ([string]$x.InstallPath).TrimEnd('\') }
            else { & $warn "${name}: installation folder unknown: default folders kept for what Exchange did not return." }
            foreach ($key in 'EdgeReceivePath', 'EdgeSendPath', 'MessageTrackingPath') { if (& $prop $x $key) { $raw[$key] = [string]$x.$key } }
        }
        else {
            if ($x.DataPath) {
                $install = [IO.Path]::GetDirectoryName(([string]$x.DataPath).TrimEnd('\'))
                $raw.ExchangePath = $install
                $raw.HttpProxyPath = Join-ExlPath $install 'Logging\HttpProxy'
                $raw.MapiHttpPath = Join-ExlPath $install 'Logging\MapiHttp\Mailbox'
            } else { & $warn "${name}: installation folder unknown (empty DataPath): default HttpProxy and MAPI folders kept." }
            foreach ($key in 'ImapLogPath', 'PopLogPath', 'FrontEndReceivePath', 'FrontEndSendPath', 'HubReceivePath', 'HubSendPath', 'MailboxReceivePath', 'MailboxSendPath', 'MessageTrackingPath') {
                if ($x.$key) { $raw[$key] = [string]$x.$key }
            }
            try { $map = Get-ExlIisSiteMap -Server $name -Local:$local } catch { Write-ExlLog 'WARN' "${name}: applicationHost.config: $($_.Exception.Message)" }
            if (-not $map) { & $warn "${name}: IIS settings not readable (\\$name\ADMIN`$, local administrator rights are needed): default IIS folders kept." }
            else {
                foreach ($key in $script:ExchangeSites.Keys) {
                    if ($map.$key) { $raw[$key] = $map.$key } else { & $warn "${name}: IIS site '$($script:ExchangeSites[$key])' not found: default folder kept." }
                }
                foreach ($p in $map.Problems) { & $warn "${name}: $p" }
                $appServer = Resolve-ExlServerPaths -Name $name -Discovered $raw -Sources $Settings.Sources
                $appMap = Get-ExlApplicationLogMap -Server $appServer -IisMap $map -Local:$local -Sources $Settings.Sources
                foreach ($p in $appMap.Problems) { & $warn "${name}: $p" }
                [void]@(Update-ExlApplicationLogPaths -Server $appServer -Map $appMap)
                if ($appServer.ApplicationLogSources.Count) {
                    $raw.HttpProxyPath = $appServer.HttpProxyPath
                    $raw.MapiHttpPath = $appServer.MapiHttpPath
                    foreach ($a in $appServer.ApplicationLogSources | Where-Object Customized) {
                        Write-ExlItem Info "${name}: $($a.Site)$($a.Application), $($a.Setting) = $($a.Folder)" -Icon Folder
                    }
                }
            }
        }
        $e = [ordered]@{ Version = [string]$x.Version; Site = [string]$x.Site; Role = $(if ($edge) { 'Edge' } else { 'Mailbox' }) }
        foreach ($key in $raw.Keys) { $e[$key] = ConvertTo-ExlRemotePath -Server $name -Path $raw[$key] -Local:$local }
        if (-not $edge) {
            $e.ImapProtocolLog = [bool]$x.ImapProtocolLog
            $e.PopProtocolLog = [bool]$x.PopProtocolLog
        }
        if ($map -and $map.Custom.Count) { $e.IisCustomSites = @($map.Custom) }
        if (-not $edge -and $appServer -and $appServer.ApplicationLogSources.Count) { $e.ApplicationLogSources = @($appServer.ApplicationLogSources) }

        # Folders that are not where a default installation puts them (the reason for this mode).
        $default = Resolve-ExlServerPaths -Name $name -Configured @{ ExchangePath = 'C:\Program Files\Microsoft\Exchange Server\V15'; IisLogPath = 'C:\inetpub\logs\LogFiles' } -Sources $Settings.Sources
        $moved = @($labels.Keys | Where-Object { $raw.Contains($_) -and -not [string]::Equals((ConvertTo-ExlRemotePath -Server $name -Path $raw[$_]), (ConvertTo-ExlRemotePath -Server $name -Path $default.$_), [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $labels[$_] })
        $where = if ($moved.Count) { 'not in the default folder: ' + ($moved -join ', ') } else { 'default folders' }
        if ($edge) { Write-ExlItem Ok ("{0} {1} {2} {1} Edge Transport (SMTP and message tracking only) {1} {3}" -f $name, $dot, $e.Version, $where) -Icon Server }
        else { Write-ExlItem Ok ("{0} {1} {2} {1} site {3} {1} {4}" -f $name, $dot, $e.Version, $e.Site, $where) -Icon Server }
        foreach ($c in @($e['IisCustomSites'] | Where-Object { $_ })) {
            $read = if ($c.Role -eq 'FrontEnd') { 'read with the IIS front end' } elseif ($c.Vdirs -match '(^|, )Microsoft-Server-ActiveSync(,|$)') { 'read with the EAS back end' } else { 'not read (back end without ActiveSync)' }
            Write-ExlItem Info ("{0}: custom IIS site '{1}' {2} {3} {2} {4} {2} {5} {2} {6}" -f $name, $c.Name, $dot, $c.Vdirs, $(if ($c.Role -eq 'BackEnd') { 'back end' } else { 'front end' }), $c.Folder, $read) -Icon Folder
        }

        # Settings that leave holes in the data.
        if ($Settings.Sources.MessageTracking -and $x.MessageTrackingEnabled -eq $false) { & $warn "${name}: message tracking is disabled (Set-TransportService $name -MessageTrackingLogEnabled `$true)." }
        if ($Settings.Sources.PopImap -and -not $edge) {
            if (-not $e.ImapProtocolLog) { & $warn "${name}: IMAP4 protocol logging is off (Set-ImapSettings -Server $name -ProtocolLogEnabled `$true, then restart the IMAP4 services)." }
            if (-not $e.PopProtocolLog) { & $warn "${name}: POP3 protocol logging is off (Set-PopSettings -Server $name -ProtocolLogEnabled `$true, then restart the POP3 services)." }
        }
        $off = @($x.LoggingOff | Where-Object { $_ })
        if (($Settings.Sources.SmtpReceive -or $Settings.Sources.SmtpSend) -and $off.Count) { & $warn ("{0}: SMTP protocol logging is off on {1}: this SMTP traffic is not in the reports." -f $name, ($off -join ', ')) }
        $found[$name] = $e
    }
    # Subscribed Edge Transport servers seen from the organisation: their log settings are in their own AD LDS
    # instance, not in Active Directory. A configured one is recorded with its role so that no client access is
    # looked for; its folders are the default ones unless -Mode Discover is run on it.
    foreach ($n in @(& $prop $exchange 'EdgeServers')) {
        $name = ([string]$n).ToUpperInvariant()
        if (-not $name -or $found.Contains($name) -or $name -notin @($Settings.Servers | ForEach-Object Name)) { continue }
        $found[$name] = [ordered]@{ Role = 'Edge' }
        Write-ExlItem Info ("{0} {1} Edge Transport server (Edge subscription): SMTP protocol logs and message tracking only. Its log settings are not in Active Directory: default folders kept; run -Mode Discover on {0} itself if they were moved." -f $name, $dot) -Icon Server
    }

    # ---- 3. folders, as seen by the account running this mode ---------------------------------------
    Write-ExlStep 3 4 "Checking the folders from $here ($account)" -Icon Folder
    $configured = @($Settings.Servers | ForEach-Object Name)
    foreach ($name in $found.Keys) {
        $current = @($Settings.Servers | Where-Object Name -eq $name) | Select-Object -First 1
        $explicit = @{}
        if ($current) {
            foreach ($k in $current.Origin.Keys) { if ($current.Origin[$k] -eq 'Configuration') { $explicit[$k] = $current.$k } }
            if ($current.RoleOrigin -eq 'Configuration') { $explicit['Role'] = $current.Role }
        }
        $server = Resolve-ExlServerPaths -Name $name -Configured $explicit -Discovered $found[$name] -Sources $Settings.Sources
        $missing = [Collections.Generic.List[string]]::new(); $notYet = [Collections.Generic.List[string]]::new(); $ok = 0
        foreach ($s in Get-ExlSources $server $Settings) {
            if (Test-Path -LiteralPath $s.Folder -PathType Container -ErrorAction SilentlyContinue) { $ok++ }
            elseif ($s.Optional) { $notYet.Add($s.Label) }
            else { $missing.Add("$($s.Label) ($($s.Folder))") }
        }
        if ($missing.Count) { & $warn ("{0}: not found or not readable by {1}: {2}" -f $name, $account, ($missing -join ', ')) }
        else { Write-ExlItem Ok ("{0}: {1} folder(s) readable" -f $name, $ok) -Icon Folder }
        if ($notYet.Count) { Write-ExlItem Info ("{0}: no folder yet for {1} (created once the logging is on and used)" -f $name, ($notYet -join ', ')) }
    }

    # ---- 4. paths file ------------------------------------------------------------------------------
    Write-ExlStep 4 4 'Writing the paths file' -Icon File
    $q = { param($Value) if ($Value -is [bool]) { if ($Value) { '$true' } else { '$false' } } else { "'" + ([string]$Value).Replace("'", "''") + "'" } }
    $now = Get-Date
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('#')
    $lines.Add('#  Exchange Log Report - log paths found by -Mode Discover')
    $lines.Add('#  --------------------------------------------------------------------------')
    $lines.Add(("#  Written on {0:yyyy-MM-dd HH:mm} by {1} on {2} ({3} on {4})." -f $now, $account, $here, $exchange.Method, $exchange.Via))
    $lines.Add('#  Do not edit: run -Mode Discover again after a CU or a change of the log paths.')
    $lines.Add('#  A path key set in a Servers block of the configuration wins over this file.')
    $lines.Add("#  Paths are as seen from $here (administrative shares for the other servers).")
    $lines.Add('#')
    $lines.Add('@{')
    $lines.Add(('    Discovered = {0}' -f (& $q $now.ToString('yyyy-MM-ddTHH:mm:sszzz'))))
    $lines.Add(('    By         = {0}' -f (& $q $account)))
    $lines.Add(('    Via        = {0}' -f (& $q "$($exchange.Method) on $($exchange.Via)")))
    $lines.Add(('    Collector  = {0}' -f (& $q $here)))
    $lines.Add('    Servers    = @{')
    foreach ($name in $found.Keys) {
        $lines.Add(('        {0} = @{{' -f (& $q $name)))
        foreach ($key in $found[$name].Keys) {
            $value = $found[$name][$key]
            if ($key -eq 'IisCustomSites') {
                $lines.Add(('            {0,-19} = @(' -f $key))
                foreach ($c in @($value)) { $lines.Add(('                @{{ Name = {0}; Id = {1}; Role = {2}; Vdirs = {3}; Folder = {4} }}' -f (& $q $c.Name), (& $q $c.Id), (& $q $c.Role), (& $q $c.Vdirs), (& $q $c.Folder))) }
                $lines.Add('            )')
            }
            elseif ($key -eq 'ApplicationLogSources') {
                $lines.Add(('            {0,-19} = @(' -f $key))
                foreach ($a in $value) {
                    $parts = foreach ($field in 'Kind', 'Protocol', 'Site', 'Application', 'Folder', 'DefaultFolder', 'ConfigFile', 'Setting', 'Customized') { '{0} = {1}' -f $field, (& $q $a.$field) }
                    $lines.Add('                @{ ' + ($parts -join '; ') + ' }')
                }
                $lines.Add('            )')
            }
            else { $lines.Add(('            {0,-19} = {1}' -f $key, (& $q $value))) }
        }
        $lines.Add('        }')
    }
    $lines.Add('    }')
    $lines.Add('}')
    $temp = $Settings.PathsFile + '.tmp'
    [IO.File]::WriteAllLines($temp, $lines, [Text.UTF8Encoding]::new($true))
    Move-Item -LiteralPath $temp -Destination $Settings.PathsFile -Force
    Write-ExlItem Ok $Settings.PathsFile -Icon File

    [pscustomobject]@{
        Found       = @($found.Keys)
        Edge        = @($found.Keys | Where-Object { $found[$_]['Role'] -eq 'Edge' })
        NotInConfig = @($found.Keys | Where-Object { $_ -notin $configured })
        NotFound    = @($configured | Where-Object { $_ -notin $found.Keys })
        Warnings    = $warnings.ToArray()
        File        = $Settings.PathsFile
        Via         = "$($exchange.Method) on $($exchange.Via)"
    }
}

#endregion

#region 10. E-mail -------------------------------------------------------------------------------------

function Test-ExlMailReady {
    <# Problems that prevent sending (missing server, sender, recipients); empty when the Mail section can be used. #>
    param([Parameter(Mandatory)]$Settings)
    $m = $Settings.Mail
    @(
        if (-not $m.SmtpServer) { 'Mail.SmtpServer is not set.' }
        if (-not $m.From) { 'Mail.From is not set.' }
        if (-not @($m.To).Count) { 'Mail.To has no recipient.' }
    )
}

function Save-ExlMailCredential {
    <#
    .SYNOPSIS
        Writes Mail.CredentialFile: the account and its password protected by DPAPI. Scope User: only this Windows
        account on this computer can read the password (write it with the account of the scheduled task). Scope
        Computer: any account of this computer can read it; the file is then restricted to SYSTEM, Administrators
        and the account that writes it.
    #>
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][pscredential]$Credential)
    $m = $Settings.Mail
    $scope = if ($m.CredentialScope -eq 'Computer') { [Security.Cryptography.DataProtectionScope]::LocalMachine } else { [Security.Cryptography.DataProtectionScope]::CurrentUser }
    $plain = [Text.Encoding]::UTF8.GetBytes($Credential.GetNetworkCredential().Password)
    try { $protected = [Security.Cryptography.ProtectedData]::Protect($plain, $script:MailEntropy, $scope) }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
    $content = [ordered]@{
        Tool = 'Exchange Log Report'; UserName = $Credential.UserName; Scope = [string]$m.CredentialScope; Password = [Convert]::ToBase64String($protected)
        WrittenBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name; Computer = [Environment]::MachineName; Written = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    } | ConvertTo-Json
    [void][IO.Directory]::CreateDirectory((Split-Path $m.CredentialFile -Parent))
    [IO.File]::WriteAllText($m.CredentialFile, $content, [Text.UTF8Encoding]::new($false))
    # Only SYSTEM, the administrators and this account may read the file (the password is protected anyway).
    try {
        $acl = [Security.AccessControl.FileSecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in 'S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow'))
        }
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($m.CredentialFile), $acl)
    } catch { Write-ExlLog 'WARN' "Could not restrict the access to $($m.CredentialFile): $($_.Exception.Message)" }
    Write-ExlLog 'INFO' ("Mail credential written to {0} for {1} (DPAPI scope {2})" -f $m.CredentialFile, $Credential.UserName, $m.CredentialScope)
}

function Read-ExlMailCredential {
    <# The account and password of Mail.CredentialFile ($null when the file does not exist). #>
    param([Parameter(Mandatory)]$Settings)
    $m = $Settings.Mail
    if (-not (Test-Path -LiteralPath $m.CredentialFile -PathType Leaf)) { return $null }
    $data = Get-Content -LiteralPath $m.CredentialFile -Raw -Encoding utf8 | ConvertFrom-Json
    $scope = if ($data.Scope -eq 'Computer') { [Security.Cryptography.DataProtectionScope]::LocalMachine } else { [Security.Cryptography.DataProtectionScope]::CurrentUser }
    try { $plain = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($data.Password), $script:MailEntropy, $scope) }
    catch {
        $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        throw ("The password of {0} cannot be read by {1} on {2}: it was written by {3} on {4} (DPAPI scope {5}). Write it again with -Mode MailTest -Credential, with the account that runs the tool, or set Mail.CredentialScope = 'Computer'." -f $m.CredentialFile, $who, [Environment]::MachineName, $data.WrittenBy, $data.Computer, $data.Scope)
    }
    try { $password = [Text.Encoding]::UTF8.GetString($plain) } finally { [Array]::Clear($plain, 0, $plain.Length) }
    [pscustomobject]@{ UserName = [string]$data.UserName; Password = $password; Scope = [string]$data.Scope; WrittenBy = [string]$data.WrittenBy }
}

function New-ExlMailSettings {
    <# SMTP settings of the engine from the Mail section (and the credential file for Basic, or Kerberos with another account). #>
    param([Parameter(Mandatory)]$Settings)
    $m = $Settings.Mail
    $s = [ExchangeLogReport.MailSettings]::new()
    $s.Server = $m.SmtpServer; $s.Port = $m.Port; $s.Encryption = $m.Encryption; $s.Authentication = $m.Authentication
    $s.From = $m.From; $s.FromName = $m.FromName; $s.To = [string[]]@($m.To); $s.Cc = [string[]]@($m.Cc); $s.Bcc = [string[]]@($m.Bcc)
    $s.TargetName = $m.TargetName; $s.CertificateThumbprint = $m.CertificateThumbprint; $s.TimeoutSeconds = $m.TimeoutSeconds; $s.HeloName = $m.HeloName
    if ($m.Authentication -in 'Basic', 'Kerberos') {
        $credential = Read-ExlMailCredential -Settings $Settings
        if ($credential) { $s.UserName = $credential.UserName; $s.Password = $credential.Password }
        elseif ($m.Authentication -eq 'Basic') { throw "Basic authentication needs Mail.CredentialFile ($($m.CredentialFile)): run once .\Invoke-ExchangeLogReport.ps1 -Mode MailTest -Credential (Get-Credential), with the account of the scheduled task." }
    }
    return $s
}

function Format-ExlMailSubject {
    <# Mail.Subject with its fields: {Title} {Type} {Period} {Range} {Servers} {Computer}. #>
    param([Parameter(Mandatory)][string]$Template, [hashtable]$Values)
    $text = $Template
    foreach ($k in $Values.Keys) { $text = $text.Replace('{' + $k + '}', [string]$Values[$k]) }
    return $text
}

function Send-ExlReportMail {
    <#
    .SYNOPSIS
        Sends a report by e-mail (Mail section): summary of the report in the body, the report attached
        (Mail.Attach). Returns the engine result (Sent, Error, Tls, AuthenticationUsed, Refused, Transcript), plus Attached
        (name and size of each attachment) and OmittedBytes (report too large for Mail.MaxAttachmentMB, not attached).
    #>
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)]$Report, [Parameter(Mandatory)][string]$Period, [Parameter(Mandatory)][string]$ReportType, [Parameter(Mandatory)][string]$Range, [string]$Title)
    $m = $Settings.Mail
    $smtp = New-ExlMailSettings -Settings $Settings
    $subject = Format-ExlMailSubject -Template $m.Subject -Values @{ Title = $Title; Type = $ReportType; Period = $Period; Range = $Range; Servers = (@($Settings.Servers | ForEach-Object Name) -join ', '); Computer = [Environment]::MachineName }
    $content = [ExchangeLogReport.ReportMail]::Build($Report, $subject, $Title, $Period, $ReportType, [Environment]::MachineName, $m.Attach, [long]$m.MaxAttachmentMB * 1MB)
    $result = [ExchangeLogReport.SmtpSender]::Send($smtp, $content)
    foreach ($l in $result.Transcript) { Write-ExlLog 'DEBUG' "SMTP $l" }
    $attached = @($content.Attachments | ForEach-Object { '{0} ({1})' -f $_.Name, (Format-ExlBytes $_.Content.LongLength) })
    $result | Add-Member -NotePropertyName Attached -NotePropertyValue $attached -Force
    $result | Add-Member -NotePropertyName OmittedBytes -NotePropertyValue $content.OmittedBytes -Force
    return $result
}

function Send-ExlTestMail {
    <# -Mode MailTest: a short message with the settings used, to check the Mail section before scheduling reports. #>
    param([Parameter(Mandatory)]$Settings)
    $m = $Settings.Mail
    $smtp = New-ExlMailSettings -Settings $Settings
    $content = [ExchangeLogReport.MailContent]::new()
    $content.Subject = Format-ExlMailSubject -Template 'Exchange Log Report - test message from {Computer}' -Values @{ Computer = [Environment]::MachineName }
    $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $lines = @(
        "This message was sent by Exchange Log Report $script:ToolVersion from $([Environment]::MachineName) ($who) to check its Mail settings."
        "Server: $($m.SmtpServer):$($m.Port), encryption $($m.Encryption), authentication $($m.Authentication)."
        'The reports will be sent the same way.'
    )
    $content.Text = $lines -join "`r`n"
    $content.Html = '<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px">' + (($lines | ForEach-Object { '<p>' + [Net.WebUtility]::HtmlEncode($_) + '</p>' }) -join '') + '</body></html>'
    $result = [ExchangeLogReport.SmtpSender]::Send($smtp, $content)
    foreach ($l in $result.Transcript) { Write-ExlLog 'DEBUG' "SMTP $l" }
    return $result
}

#endregion

# SIG # Begin signature block
# MIIghAYJKoZIhvcNAQcCoIIgdTCCIHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBSKdX8abI7mpPk
# cZ2ncvfLSEkVzJVWQ/jBCoMuGudH+6CCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYISazCCEmcCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCACt6vSQaAi
# Kr4tCY0uqwaYCLCfbW5MaqCg0q+MEeq9MDANBgkqhkiG9w0BAQEFAASCAgBoF47b
# IHBTASjsbhqhZOZ2YYVkvyMO9kye6Rq3JcedHA5/KETbl+E3lIvz1FqQPdgj1lky
# t5zrastahdEx7waqOCmCdegUa5s+T/5l8C1b2jNzlQaW/6i3Re++iSjVUSlMxvQR
# dSc8nOWLH6+21yxiiTo8VSbiTbGF829WhauWiPmVp1wrhCRJuI2rDeMkW/P99gwm
# a7bph82usF5027zVf9y5yAkpWsjm1rzH0AZ1S2HsXMGegUQy+sAqR7hyorrTr/qL
# y6rDAsuDmtzZtz3ZDWSQdCUvpcC+HALfjSTjrV+j+bJga5VT0ZQld25bcXCh9Fuz
# GObNrexyFThnHqW9DhySxfR0GB4FqsX/7Wx5QHIdGwFzoF41XhLr0IYL+PDur/fj
# 92JugbOhFwPlFwwXwQA8+orVk4DSG2oaxMO+7ubqv4tzcVpgH6J73wwF79GdG4uW
# oAestwhtyIvmG3TlquBSI2MzxYRRltKpr7npqvUYxXoOvRgopASeJp0Xh5lQRtXm
# FO6zik8JqrwMcNiZMwQ4F+OEshAqUYHM4GDKtEeO9QUxjPzXammMNM3zP1JTx1iJ
# mKi7crH8DOWGKYRjTgBS1jbLKR5RGcdGviiJTMGzhrxDxMCR4Jtq+byHFeGYXdbS
# tyTopzpz7t9YBrXBtYjQ+wBIQClu5KTjYeHI0aGCDygwgg8kBgorBgEEAYI3AwMB
# MYIPFDCCDxAGCSqGSIb3DQEHAqCCDwEwgg79AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIH1zlA/kPeNMN62r0fr3ah9OXcOXWzT19YMwY1Xr+z75AggA7shjdomZ
# ShgPMjAyNjEwMjgxMTQ2MTFaMAMCAQECEDOkwDaz2cF1dssByMum6pagggwAMIIE
# /DCCAuSgAwIBAgIQH2sWYtIuG2xd8cDBoGAOODANBgkqhkiG9w0BAQsFADBzMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS8wLQYDVQQDDCZTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSBSMTAeFw0yNTAyMTgxNjMyMDJaFw0zNDExMTIxODUwMDVa
# MG4xCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3Rv
# bjERMA8GA1UECgwIU1NMIENvcnAxKjAoBgNVBAMMIVNTTC5jb20gVGltZXN0YW1w
# aW5nIFVuaXQgMjAyNSBFMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBv7UVHH
# b+ZVluxPXlfE3M6tg0Xnq8dic+O3vPOCRpalUM1vO9A+GRzSVVjyygHhYrBw62XL
# Fh1kv7e+yRd/aTajggFaMIIBVjAfBgNVHSMEGDAWgBQMnRAljpqnG5mHQ88IfuG9
# gZD0zzBRBggrBgEFBQcBAQRFMEMwQQYIKwYBBQUHMAKGNWh0dHA6Ly9jZXJ0LnNz
# bC5jb20vU1NMLmNvbS10aW1lU3RhbXBpbmctSS1SU0EtUjEuY2VyMFEGA1UdIARK
# MEgwPAYMKwYBBAGCqTABAwYBMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNz
# bC5jb20vcmVwb3NpdG9yeTAIBgZngQwBBAIwFgYDVR0lAQH/BAwwCgYIKwYBBQUH
# AwgwRgYDVR0fBD8wPTA7oDmgN4Y1aHR0cDovL2NybHMuc3NsLmNvbS9TU0wuY29t
# LXRpbWVTdGFtcGluZy1JLVJTQS1SMS5jcmwwHQYDVR0OBBYEFM582cAEgMUkEGoJ
# 6hyrJT0R/ajSMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAgHN1
# JIW9ZlNip07FfY9r1LJwLKTl1h/y9r1BjDgHMEz7U7J7mAy32JxA1KLyjCCJqNku
# RfhDHGFEfZtjTOru7AQMDSDiUDvCCc3jaz5py9jGvwIe5npkLbXqXhA+SqCzG719
# USigwhHkYr7v8NiXoaY0Xu03p0BiZZreZlpngmGB9+86N94FqIFx2I5Z5iuu7d4j
# 7aAOZBNxfU9jFDIIGDtWfWeCpF0Q8rLE/3DHDlzJKs5Il3i/VoOl7rTU938oSrxM
# www6GDBlKX8rGHxvkjgIb9MXkVglJSDHsNAZDeCS/inaxKHA+ChuB8K4OxIxa6k1
# e+eHBypakAY3wuN7w7PlPmhN6k5IdqZn3HZHs2VjoR841Z9wmVPFdGDdkBZ7XOmb
# 5OZUaKufsvtER0VbY2DkzaqAaItt1kc+I+FUz7PiVz2PUzpegkftRRxvrPyIL08b
# lJTnbMQ0XrqDN0rEfuTLv4XhhnKyJaXhxCUdjO/cRumMzZ35QTUMItBWy1xGp0iy
# oFVnAya2pPsVMuAI+sy1zxlOS9l5iSxvKJ8gpnpOgjqYTa7u1eyZo+4JlcGoiiR1
# 7LthMTrF1q62tO5xOpI8txUZ6gtKGtkJV6wdj+vZLcwKZ2M93GqVpOo6UBlGjx1s
# KsVZ7AIUzJZli4NJ0M2KYcrfNnlebkYKpDnSqWwwggb8MIIE5KADAgECAhBtUhhw
# h+gjTYVgANCAj5NWMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMQ4wDAYD
# VQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBv
# cmF0aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRo
# b3JpdHkgUlNBMB4XDTE5MTExMzE4NTAwNVoXDTM0MTExMjE4NTAwNVowczELMAkG
# A1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYD
# VQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNz
# dWluZyBSU0EgQ0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCu
# URAT0vk8IKAghd7JUBxkyeH9xek0/wp/MUjoclrFXqhh/fGH91Fc+7fm0MHCE7A+
# wmOiqBj9ODrJAYGq3rm33jCnHSsCBNWAQYyoauLq8IjqsS1JlXL29qDNMMdwZ8UN
# zQS7vWZMDJ40JSGNphMGTIA2qn2bohGtgRc4p1395ESypUOaGvJ3t0FNL3BuKmb6
# YctMcQUF2sqooMzd89h0E6ujdvBDo6ZwNnWoxj7YmfWjSXg33A5GuY9ym4QZM5OE
# Vgo8ebz/B+gyhyCLNNhh4Mb/4xvCTCMVmNYrBviGgdPZYrym8Zb84TQCmSuX0JlL
# La6WK1aO6qlwISbb9bVGh866ekKblC/XRP20gAu1CjvcYciUgNTrGFg8f8AJgQPO
# Cc1/CCdaJSYwhJpSdheKOnQgESgNmYZPhFOC6IKaMAUXk5U1tjTcFCgFvvArXtK4
# azAWUOO1Y3fdldIBL6LjkzLUCYJNkFXqhsBVcPMuB0nUDWvLJfPimstjJ8lF4S6E
# CxWnlWi7OElVwTnt1GtRqeY9ydvvGLntU+FecK7DbqHDUd366UreMkSBtzevAc9a
# qoZPnjVMjvFqV1pYOjzmTiVHZtAc80bAfFe5LLfJzPI6DntNyqobpwTevQpHqPDN
# 9qqNO83r3kaw8A9j+HZiSw2AX5cGdQP0kG0vhzfgBwIDAQABo4IBgTCCAX0wEgYD
# VR0TAQH/BAgwBgEB/wIBADAfBgNVHSMEGDAWgBTdBAkHovV6fVJTEpKV7jiAJQ2m
# WTCBgwYIKwYBBQUHAQEEdzB1MFEGCCsGAQUFBzAChkVodHRwOi8vd3d3LnNzbC5j
# b20vcmVwb3NpdG9yeS9TU0xjb21Sb290Q2VydGlmaWNhdGlvbkF1dGhvcml0eVJT
# QS5jcnQwIAYIKwYBBQUHMAGGFGh0dHA6Ly9vY3Nwcy5zc2wuY29tMD8GA1UdIAQ4
# MDYwNAYEVR0gADAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3Jl
# cG9zaXRvcnkwEwYDVR0lBAwwCgYIKwYBBQUHAwgwOwYDVR0fBDQwMjAwoC6gLIYq
# aHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0GA1Ud
# DgQWBBQMnRAljpqnG5mHQ88IfuG9gZD0zzAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZI
# hvcNAQELBQADggIBAJIZdQ2mWkLPGQfZ8vyU+sCb8BXpRJZaL3Ez3VDlE3uZk3cP
# xPtybVfLuqaci0W6SB22JTMttCiQMnIVOsXWnIuAbD/aFTcUkTLBI3xys+wEajzX
# aXJYWACDS47BRjDtYlDW14gLJxf8W6DQoH3jHDGGy8kGJFOlDKG7/YrK7UGfHtBA
# EDVe6lyZ+FtCsrk7dD/IiL/+Q3Q6SFASJLQ2XI89ihFugdYL77CiDNXrI2MFspQG
# swXEAGpHuaQDTHUp/LdR3TyrIsLlnzoLskUGswF/KF8+kpWUiKJNC4rPWtNrxlbX
# YRGgdEdx8SMjUTDClldcrknlFxbqHsVmr9xkT2QtFmG+dEq1v5fsIK0vHaHrWjMM
# maJ9i+4qGJSD0stYfQ6v0PddT7EpGxGd867Ada6FZyHwbuQSadMb0K0P0OC2r7rw
# qBUe0BaMqTa6LWzWItgBjGcObXeMxmbQqlEz2YtAcErkZvh0WABDDE4U8GyV/32F
# daAvJgTfe9MiL2nSBioYe/g5mHUSWAay/Ip1RQmQCvmF9sNfqlhJwkjy/1U1ibUk
# TIUBX3HgymyQvqQTZLLys6pL2tCdWcjI9YuLw30rgZm8+K387L7ycUvqrmQ3ZJlu
# jHl3r1hgV76s3WwMPgKk1bAEFMj+rRXimSC+Ev30hXZdqyMdl/il5Ksd0vhGMYIC
# VzCCAlMCAQEwgYcwczELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYD
# VQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNv
# bSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgUjECEB9rFmLSLhtsXfHAwaBg
# DjgwCwYJYIZIAWUDBAIBoIIBYTAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAyODExNDYxMVowKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIFtKVKh2Uf8/
# do5fWT+ywJp6+WdG/PPKVriNNyXd9slgMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEYwRAIgGyfwwG1aMsP8R6SsXDAX4Z3IC4WNApTzamlM+v2DxYYCICXARtMj98A1
# sc6BLs9AxCzfiaOwbQ9WMXlylpWQmj6h
# SIG # End signature block
