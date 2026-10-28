#Requires -Version 7.4

<#
.SYNOPSIS
    Exchange Log Report - usage and troubleshooting reports from the IIS / HTTP Proxy, SMTP
    protocol and message tracking logs of Exchange Server SE (on-premises).

.DESCRIPTION
    The tool works in two stages:

      1. COLLECT  Log files of every configured server -> local SQLite database.
                  Only the new part of each file is read. System mailboxes, health probes,
                  load balancer checks and other noise are removed BEFORE storage and
                  counted by reason. Schedule it every hour: -Mode Collect. The first
                  collection reads the last Collection.BackfillDays days.
      2. REPORT   SQLite database -> CSV + HTML files in a local folder, in seconds or minutes.
                  The report reads the new log lines first only when the last collection is
                  older than Report.MaxDataAgeMinutes (90 min) and does not cover the period.
                  Usage     : is each server really used, by whom, with which protocols,
                              clients, devices and operations (latency per operation).
                  Detailed  : + one row per client session with its timeline across the front-end
                              and back-end logs (Outlook MAPI, ActiveSync, OWA, EWS, IMAP, POP),
                              failed and slow requests (recovered or not), one row per message
                              with its route, SMTP sessions with their transcript.

    Everything is set in config\ExchangeLogReport.config.psd1. The tool reads Exchange logs
    and settings without changing any Exchange setting. It writes its database, reports and
    execution logs locally. Report e-mail is disabled in the delivered configuration:
    -SendMail or Mail.Enabled enables it, and -SendMail:$false suppresses it for one report.
    -Mode MailTest sends a test message independently of Mail.Enabled.

    Edge Transport servers (detected, or Role = 'Edge' in the Servers block): only their SMTP
    protocol logs and message tracking are read, without IIS, HttpProxy, MAPI, ActiveSync, POP3 or IMAP4.
    Run the tool on the Edge itself (SYSTEM or a local administrator).

.PARAMETER Mode
    Report  (default) Writes the report from the database. When the last collection is older than
                      Report.MaxDataAgeMinutes (90 min) and the period ends after it, the lines written since
                      are read first. No collection yet: the report stops (run -Mode Collect first).
    Collect           Collects what is new (scheduled task). No report.
    Status            Shows what the database contains. Reads no log file.
    Serve             On-demand, loopback-only read-only API and compiled ..\web application.
                      Never collects, generates a report, sends mail or upgrades the source database.
                      Use -Port, -DatabasePath, -WebRoot and -NoBrowser as needed.
    Discover          Reads the real log folders of every Exchange server (Exchange cmdlets in Windows
                      PowerShell 5.1: local Exchange Management Shell or Exchange remote PowerShell,
                      View-Only Organization Management is enough) and the IIS log folder of every
                      Exchange web site, custom OWA/ECP sites included (virtual directories read from
                      applicationHost.config). Writes config\ExchangeLogReport.paths.psd1. Run it once
                      on the collector with an administrator account (SYSTEM has no Exchange role), and
                      again after a CU or a change of the log paths.
                      Every collection checks the IIS sites again and follows a moved IIS log folder.
                      On an Edge Transport server: its local Exchange Management Shell (SYSTEM is
                      accepted), SMTP log folders and message tracking only.
    MailTest          Checks the Mail section of the configuration: connects to the SMTP server, shows the
                      conversation (TLS, certificate, authentication) and sends a test message. With
                      -Credential, first saves the account of the SMTP server to Mail.CredentialFile (Basic
                      authentication, or Kerberos with another account), protected by DPAPI.

.PARAMETER Range
    Period of the report (-Mode Report). Default: Report.DefaultRange.
      Last24Hours, Last7Days, Last30Days : rolling windows ending now
      PreviousMonth                      : the previous calendar month
      Month  -Month 2026-09              : a calendar month
      Day    -Date 2026-09-28            : a calendar day
      Custom -Start '2026-09-01 08:00' -End '2026-09-01 12:00'
    -Month, -Date and -Start / -End select their range on their own: -Range can be left out. They cannot be
    combined with each other (parameter sets) nor with another -Range (error). A collection, -Mode Status and
    -Mode Discover do not use a period: a period given with them is reported as ignored, with the reason.

.PARAMETER Month
    Calendar month of the report, yyyy-MM (-Range Month).

.PARAMETER Date
    Calendar day of the report, yyyy-MM-dd (-Range Day).

.PARAMETER Start
    Start of a custom period, included (-Range Custom, with -End): yyyy-MM-dd or 'yyyy-MM-dd HH:mm' in the
    time zone of the report (Report.TimeZone), or an ISO 8601 value with an offset.

.PARAMETER End
    End of a custom period, excluded (-Range Custom, with -Start). Same formats as -Start; a time later
    than now is replaced by now.

.PARAMETER ReportType
    Usage (default from the configuration) or Detailed. When every server of the report is an Edge
    Transport server, the report is an Edge report: mail flow only (messages, SMTP clients, SMTP destinations).

.PARAMETER User
    One or more users (part of domain\sam, UPN or SMTP address). Filters every view; with
    -ReportType Detailed the successful requests kept for these users are shown as well.

.PARAMETER Server
    One or more servers of the configuration. Filters the report and, with -Mode Collect, the collection.

.PARAMETER IncludeRoutingDetails
    Overrides Report.IncludeRoutingDetails: message route and SMTP transcripts in the CSV files.

.PARAMETER IncludeSessionDetails
    Overrides Report.IncludeSessionDetails: timeline of each client session in the CSV files.

.PARAMETER ConfigPath
    Configuration file. Default: config\ExchangeLogReport.config.psd1 next to this script.

.PARAMETER OutputPath
    Report mode: folder of the report files, instead of Report.OutputPath.

.PARAMETER DatabasePath
    Serve mode: absolute path of the SQLite database to read. Default: Storage.DatabasePath of the
    configuration. The database must have the current schema; Serve never migrates it.

.PARAMETER WebRoot
    Serve mode: folder of the compiled web application (index.html). Default: ..\web next to this script.

.PARAMETER Port
    Serve mode: local port of the loopback listener (127.0.0.1). Default: 8765; 0 picks a free port.

.PARAMETER NoBrowser
    Serve mode: does not open the default browser.

.PARAMETER ReadyFile
    Serve mode: new, unused private file in which the listener writes its status ("ready" or "blocked")
    once started. An existing file is never replaced.

.PARAMETER ReadyFileWithToken
    Serve mode: also writes the access token to the ReadyFile (local automation only; never share that file).

.PARAMETER RequestTimeoutSeconds
    Serve mode: time limit of one API request, 1 to 120 seconds. Default: 15.

.PARAMETER MmapMB
    Serve mode: SQLite memory-mapped I/O per read connection, 0 to 256 MB. Default: 0 (none).

.PARAMETER DevelopmentMode
    Serve mode: allows a source checkout without a package manifest. A present PackageIntegrity.json is
    always verified.

.PARAMETER Collect
    Report mode: reads the new log lines first, whatever the age of the data (the first collection reads the last
    Collection.BackfillDays days).

.PARAMETER NoCollect
    Report mode: uses only the data already in the database, whatever its age.

.PARAMETER SendMail
    Report mode: sends the report by e-mail (Mail section of the configuration), or with -SendMail:$false does not,
    whatever Mail.Enabled says.

.PARAMETER ConnectTo
    Discover mode: Exchange server used for remote PowerShell (http://<server>/PowerShell/, Kerberos).
    Default: the Exchange Management Shell of this computer if it is an Exchange server, else the
    first server of the configuration that answers.

.PARAMETER Credential
    Discover mode: account for remote PowerShell, when it is not the account running the tool.
    MailTest mode: account of the SMTP server, saved to Mail.CredentialFile (DPAPI) for the reports sent later.

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Mode Discover -ConnectTo EXCH01
    Finds the real log folders of every Exchange server (moved logs, Exchange on another drive...).

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Mode Collect
    Scheduled collection, every hour. The first one reads the last Collection.BackfillDays days.

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Range Last30Days
    Usage of every server over 30 days (which servers are really used).

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Range Day -Date 2026-09-30 -ReportType Detailed -User alice@contoso.com
    Everything about one user on one day: requests, failures, messages and their route.

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Start '2026-10-01 08:00' -End '2026-10-01 12:00' -ReportType Detailed -NoCollect
    An incident window (custom period, -Range Custom is implied) from the data already collected.

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Mode MailTest
    Checks the Mail section: TLS, authentication and a test message to Mail.To.

.EXAMPLE
    .\Invoke-ExchangeLogReport.ps1 -Range PreviousMonth -SendMail
    Usage report of the previous month, sent by e-mail (monthly scheduled task).

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.1
    Exit codes : 0 = success, 1 = failure, 2 = finished with warnings (a server, a folder or a file could not
                 be read, a source is stale, the IIS log folders changed since -Mode Discover, or the report
                 could not be sent by e-mail).
    Documentation : docs\ExchangeLogReport-UserGuide.html (user guide: prerequisites, everyday commands) and
                    docs\ExchangeLogReport-Guide.html (developer guide); docs\Serve-Guide.txt (Serve)
    Launcher : ..\Run-Collector.cmd starts this script with the server garbage collector (DOTNET_gcServer=1,
               DOTNET_GCHeapCount=4, DOTNET_GCNoAffinitize=1). A direct pwsh.exe -File call keeps the
               workstation garbage collector unless it sets the same variables.

    This Script is a Personal project.
    It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

    As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
#>
[CmdletBinding(DefaultParameterSetName = 'Range')]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Report', 'Collect', 'Status', 'Discover', 'MailTest', 'Serve')]
    [string]$Mode = 'Report',

    # Period of the report: one parameter set per kind of period, so that a period parameter is never ignored.
    [Parameter(ParameterSetName = 'Range', Position = 1)]
    [Parameter(ParameterSetName = 'Month', Position = 1)]
    [Parameter(ParameterSetName = 'Day', Position = 1)]
    [Parameter(ParameterSetName = 'Custom', Position = 1)]
    [ValidateSet('Last24Hours', 'Last7Days', 'Last30Days', 'PreviousMonth', 'Month', 'Day', 'Custom')]
    [string]$Range,
    [Parameter(ParameterSetName = 'Month', Mandatory)]
    [string]$Month,
    [Parameter(ParameterSetName = 'Day', Mandatory)]
    [string]$Date,
    [Parameter(ParameterSetName = 'Custom', Mandatory)]
    [string]$Start,
    [Parameter(ParameterSetName = 'Custom', Mandatory)]
    [string]$End,

    [ValidateSet('Usage', 'Detailed')]
    [string]$ReportType,
    [string[]]$User,
    [string[]]$Server,
    [switch]$IncludeRoutingDetails,
    [switch]$IncludeSessionDetails,

    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\ExchangeLogReport.config.psd1'),
    [string]$OutputPath,
    [string]$DatabasePath,
    [string]$WebRoot = (Join-Path $PSScriptRoot '..\web'),
    [ValidateRange(0, 65535)][int]$Port = 8765,
    [switch]$NoBrowser,
    [string]$ReadyFile,
    [switch]$ReadyFileWithToken,
    [ValidateRange(1, 120)][int]$RequestTimeoutSeconds = 15,
    [ValidateRange(0, 256)][int]$MmapMB = 0,
    [switch]$DevelopmentMode,
    [switch]$Collect,
    [switch]$NoCollect,
    [switch]$SendMail,

    [string]$ConnectTo,
    [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
$clock = [Diagnostics.Stopwatch]::StartNew()
$exitCode = 1
$runStatus = 'Failed'
$store = $null; $lock = $null; $runId = $null; $collection = $null

try {
    do {
        Import-Module (Join-Path $PSScriptRoot 'ExchangeLogReport.psd1') -Force

        if ($Mode -eq 'Serve') {
            # Only the database setting is needed. No log, lock, collection, report or mail path is entered.
            if (-not $DatabasePath) {
                $data = Import-PowerShellDataFile -LiteralPath $ConfigPath
                $DatabasePath = '.\data\ExchangeLogReport.sqlite'
                if ($data.ContainsKey('Storage') -and $data.Storage.ContainsKey('DatabasePath')) { $DatabasePath = [string]$data.Storage.DatabasePath }
                $DatabasePath = [IO.Path]::GetFullPath($DatabasePath, $PSScriptRoot)
            }
            Start-ExlServe -DatabasePath $DatabasePath -WebRoot $WebRoot -Port $Port -NoBrowser:$NoBrowser `
                -ReadyFile $ReadyFile -ReadyFileWithToken:$ReadyFileWithToken -RequestTimeoutSeconds $RequestTimeoutSeconds -MmapMB $MmapMB -DevelopmentMode:$DevelopmentMode
            $exitCode = 0
            $runStatus = 'Completed'
            break
        }

        # ---- configuration, then command-line overrides -------------------------------------------
        $settings = Import-ExlConfiguration -Path $ConfigPath -Root $PSScriptRoot
        # -Start / -End, -Month and -Date select their range on their own; with another -Range they are an error.
        if ($Mode -eq 'Report') { $Range = Resolve-ExlRange -Range $Range -Month $Month -Date $Date -Start $Start -End $End -Default $settings.Report.DefaultRange }
        # Parameters that this mode does not use: shown after the banner with the reason, never ignored silently.
        $ignored = @(Get-ExlIgnoredParameter -Mode $Mode -Name @($PSBoundParameters.Keys))
        if (-not $ReportType) { $ReportType = $settings.Report.DefaultType }
        if ($PSBoundParameters.ContainsKey('IncludeRoutingDetails')) { $settings.Report.IncludeRoutingDetails = [bool]$IncludeRoutingDetails }
        if ($PSBoundParameters.ContainsKey('IncludeSessionDetails')) { $settings.Report.IncludeSessionDetails = [bool]$IncludeSessionDetails }
        if ($OutputPath) { $settings.Report.OutputPath = [IO.Path]::GetFullPath($OutputPath, (Get-Location).Path) }
        $servers = @($settings.Servers)
        if ($Server) {
            $unknown = @($Server | Where-Object { $_ -notin $servers.Name })
            if ($unknown.Count) { throw ("Unknown server(s): {0}. Servers of the configuration: {1}." -f ($unknown -join ', '), ($servers.Name -join ', ')) }
            $servers = @($servers | Where-Object { $_.Name -in $Server })
        }
        $zone = $settings.Zone

        $logPath = Start-ExlLog -Directory $settings.Logging.Path -RetentionDays $settings.Logging.RetentionDays
        $dot = [char]0x00B7

        # ---- test of the e-mail settings (no database, no log file read) ------------------------------
        if ($Mode -eq 'MailTest') {
            $m = $settings.Mail
            $banner = [ordered]@{}
            $banner['Mode'] = @('Info', 'MailTest')
            $banner['Server'] = @('Mail', ("{0}:{1} {2} encryption {3} {2} authentication {4}" -f $m.SmtpServer, $m.Port, $dot, $m.Encryption, $m.Authentication))
            $banner['From'] = @('People', $m.From)
            $banner['To'] = @('People', (@($m.To) + @($m.Cc | ForEach-Object { "$_ (Cc)" }) -join ', '))
            $banner['Log'] = @('Log', $logPath)
            Write-ExlBanner -Title 'Exchange Log Report' -Subtitle "Exchange Server SE $dot test of the e-mail settings" -Details $banner
            foreach ($n in $ignored) { Write-ExlItem Warn $n }
            $problems = @(Test-ExlMailReady -Settings $settings)
            if ($problems.Count) { throw ('The Mail section of the configuration is not complete: ' + ($problems -join ' ')) }
            Initialize-ExlEngine -Root $PSScriptRoot
            $total = if ($Credential) { 2 } else { 1 }
            $step = 0
            if ($Credential) {
                $step++
                Write-ExlStep $step $total 'Saving the account of the SMTP server' -Icon File
                Save-ExlMailCredential -Settings $settings -Credential $Credential
                $who = if ($m.CredentialScope -eq 'Computer') { 'any account of this computer' } else { "$([Environment]::UserDomainName)\$([Environment]::UserName) on this computer only" }
                Write-ExlItem Ok ("{0} {1} {2} {1} password protected by DPAPI, readable by {3}" -f $m.CredentialFile, $dot, $Credential.UserName, $who) -Icon File
                if ($m.Authentication -eq 'Anonymous') { Write-ExlItem Warn "Mail.Authentication is 'Anonymous': the account is saved but not used." }
            }
            $step++
            Write-ExlStep $step $total "Sending a test message through $($m.SmtpServer):$($m.Port)" -Icon Mail
            $mail = Send-ExlTestMail -Settings $settings
            foreach ($l in $mail.Transcript) { Write-ExlDetail $l }
            foreach ($r in $mail.Refused) { Write-ExlItem Warn "Recipient refused: $r" }
            $values = [ordered]@{}
            $values['Server'] = @('Server', ("{0}:{1}" -f $m.SmtpServer, $m.Port))
            $values['TLS'] = @($(if ($mail.Tls) { 'Ok' } else { 'Warn' }), $(if ($mail.Tls) { $mail.Tls } else { 'none: the message travels in clear' }))
            if ($mail.Certificate) { $values['Certificate'] = @('File', $mail.Certificate) }
            if ($mail.AuthenticationUsed) { $values['Account'] = @('People', $mail.AuthenticationUsed) }
            if ($mail.Sent) {
                $values['Message'] = @('Ok', ("{0} {1} {2} bytes {1} {3}" -f $mail.MessageId, $dot, (Format-ExlNumber $mail.MessageBytes), $mail.Response))
                Write-ExlSummary -Title 'Test message sent' -Values $values -Status $(if ($mail.Refused.Count) { 'Warn' } else { 'Ok' })
                $exitCode = if ($mail.Refused.Count) { 2 } else { 0 }
            }
            else {
                $values['Error'] = @('Fail', $mail.Error)
                Write-ExlSummary -Title 'Test message not sent' -Values $values -Status Fail
                $exitCode = 1
            }
            $runStatus = 'Completed'
            break
        }

        # ---- discovery of the log paths (no database, no log file read) ------------------------------
        if ($Mode -eq 'Discover') {
            $banner = [ordered]@{}
            $banner['Mode'] = @('Info', 'Discover')
            $localExchange = [bool]$env:ExchangeInstallPath -or (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup')
            $banner['Exchange'] = @('Server', $(if ($ConnectTo) { "remote PowerShell on $ConnectTo" } elseif ($localExchange -and -not $Credential) { 'Exchange Management Shell of this server (Windows PowerShell 5.1)' } else { "remote PowerShell (Windows PowerShell 5.1) on the first of $($settings.Servers.Name -join ', ') that answers" }))
            $banner['Paths'] = @('File', $settings.PathsFile)
            $banner['Log'] = @('Log', $logPath)
            Write-ExlBanner -Title 'Exchange Log Report' -Subtitle "Exchange Server SE $dot discovery of the log folders" -Details $banner
            foreach ($n in $ignored) { Write-ExlItem Warn $n }
            $found = Invoke-ExlDiscovery -Settings $settings -ConnectTo $ConnectTo -Credential $Credential
            $values = [ordered]@{}
            $mailbox = @($found.Found | Where-Object { $_ -notin $found.Edge })
            $text = @(if ($mailbox.Count) { "{0} mailbox server(s): {1}" -f $mailbox.Count, ($mailbox -join ', ') }
                if ($found.Edge.Count) { "{0} Edge Transport server(s): {1}" -f $found.Edge.Count, ($found.Edge -join ', ') }) -join " $dot "
            $values['Servers'] = @('Server', $text)
            if ($found.NotInConfig.Count) { $values['Add'] = @('Info', ("not in the configuration: " + (($found.NotInConfig | ForEach-Object { "@{ Name = '$_' }" }) -join ' '))) }
            if ($found.NotFound.Count) { $values['Unknown'] = @('Warn', ("in the configuration but not found in Exchange: " + ($found.NotFound -join ', '))) }
            $values['Warnings'] = @($(if ($found.Warnings.Count) { 'Warn' } else { 'Ok' }), $(if ($found.Warnings.Count) { "$($found.Warnings.Count) (see above and the log file)" } else { 'none' }))
            $values['File'] = @('File', $found.File)
            $values['Next'] = @('Info', '.\Invoke-ExchangeLogReport.ps1 -Mode Collect')
            Write-ExlSummary -Title 'Log paths discovered' -Values $values -Status $(if ($found.Warnings.Count -or $found.NotFound.Count) { 'Warn' } else { 'Ok' })
            $exitCode = 0; $runStatus = 'Completed'
            break
        }
        Initialize-ExlEngine -Root $PSScriptRoot

        $period = if ($Mode -eq 'Report') { Resolve-ExlPeriod -Range $Range -Month $Month -Date $Date -Start $Start -End $End -Zone $zone }
        # A report reads the database; it reads the new log lines first only when the data is too old for the period
        # (Report.MaxDataAgeMinutes), or with -Collect. The hourly scheduled collection keeps the data fresh.
        $collecting = $Mode -eq 'Collect'
        $data = $null
        if ($Mode -eq 'Report') {
            $data = Resolve-ExlReportCollection -Settings $settings -Period $period -Collect:$Collect -NoCollect:$NoCollect
            $collecting = $data.Collect
            if ($collecting -and -not $Collect) {
                # Decided by the age of the data: never wait for, nor fail on, a collection that is running.
                $lock = Enter-ExlLock -Path ($settings.Storage.DatabasePath + '.lock') -NoWait
                if (-not $lock) {
                    $collecting = $false
                    $owner = try { [IO.File]::ReadAllText($settings.Storage.DatabasePath + '.lock') } catch { 'another execution' }
                    $data.Text = "$($data.Text -replace ': the new log lines are read first', '') $dot a collection is running ($owner): the report uses the data already collected"
                }
            }
        }
        # The report is sent by e-mail when Mail.Enabled is $true, or when -SendMail says so (-SendMail:$false never sends).
        $mailing = $Mode -eq 'Report' -and $(if ($PSBoundParameters.ContainsKey('SendMail')) { [bool]$SendMail } else { $settings.Mail.Enabled })
        $totalSteps = switch ($Mode) { 'Status' { 2 } 'Collect' { 4 } default { $(if ($collecting) { 5 } else { 2 }) + $(if ($mailing) { 1 } else { 0 }) } }
        $banner = [ordered]@{}
        $banner['Mode'] = @('Info', ($Mode + $(if ($period) { " $dot $ReportType $dot $Range" } else { '' })))
        if ($period) { $banner['Period'] = @('Calendar', "$(Format-ExlRange $period.StartMs $period.EndMs $zone)  ($($settings.Report.TimeZone), end excluded)") }
        $banner['Servers'] = @('Server', ($servers.Name -join ', '))
        if ($User) { $banner['Users'] = @('People', ($User -join ', ')) }
        $banner['Database'] = @('Database', $settings.Storage.DatabasePath)
        if ($data) { $banner['Data'] = @($(if ($data.NoData) { 'Warn' } elseif ($collecting) { 'Download' } else { 'Clock' }), $data.Text) }
        if ($mailing) { $banner['Mail'] = @('Mail', ("to {0} through {1}" -f (@($settings.Mail.To) -join ', '), $settings.Mail.SmtpServer)) }
        $banner['Paths'] = @('Folder', $(if ($settings.Discovery) { "found by -Mode Discover on $($settings.Discovery.When.Substring(0, [Math]::Min(16, $settings.Discovery.When.Length)).Replace('T', ' '))" } else { 'default folders (run -Mode Discover to check them)' }))
        $banner['Log'] = @('Log', $logPath)
        Write-ExlBanner -Title 'Exchange Log Report' -Subtitle "Exchange Server SE $dot usage and troubleshooting from the server logs" -Details $banner
        foreach ($n in $ignored) { Write-ExlItem Warn $n }
        if ($settings.Discovery -and $settings.Discovery.Collector -and $settings.Discovery.Collector -ne [Environment]::MachineName.ToUpperInvariant()) {
            Write-ExlItem Warn "The paths file was written on $($settings.Discovery.Collector): run -Mode Discover on this computer."
        }

        if ($data -and $data.NoData) {
            throw ("No collection in the database yet: run '.\Invoke-ExchangeLogReport.ps1 -Mode Collect' first (it reads the last {0} days of logs; then schedule it every hour), or add -Collect to this command." -f $settings.Collection.BackfillDays)
        }

        # ---- step 1: database ------------------------------------------------------------------------
        $step = 1
        Write-ExlStep $step $totalSteps 'Opening the database' -Icon Database
        if (-not $collecting -and -not (Test-Path -LiteralPath $settings.Storage.DatabasePath)) {
            Write-ExlItem Info 'No database yet: the first collection (-Mode Collect) creates it.'
            Write-ExlSummary -Title 'Ready for the first collection' -Values ([ordered]@{
                    Config  = @('Ok', "valid $dot $($settings.Servers.Count) server(s)")
                    Engine  = @('Ok', 'ready')
                    Next    = @('Info', '.\Invoke-ExchangeLogReport.ps1 -Mode Collect')
                }) -Status Ok
            $exitCode = 0; $runStatus = 'Completed'
            break
        }
        if ($collecting -and -not $lock) { $lock = Enter-ExlLock -Path ($settings.Storage.DatabasePath + '.lock') }
        $store = Open-ExlStore -Settings $settings -ReadOnly:(-not $collecting)
        if ($collecting) {
            $closed = $store.CloseAbandonedRuns()
            if ($closed) { Write-ExlItem Warn "$closed earlier execution(s) had been interrupted; their files resume where they stopped." }
            $runId = $store.StartRun($Mode, [Environment]::MachineName, [Environment]::UserDomainName + '\' + [Environment]::UserName, (Get-Module ExchangeLogReport).Version.ToString(3))
        }
        Write-ExlItem Ok ("{0} {1} {2}" -f $settings.Storage.DatabasePath, $dot, (Format-ExlBytes $store.FileBytes))

        if ($Mode -eq 'Status') {
            Write-ExlStep 2 $totalSteps 'Collected data' -Icon Chart
            Show-ExlStatus -Store $store -Settings $settings
            $exitCode = 0; $runStatus = 'Completed'
            break
        }

        # ---- steps 2-3: access check and collection ---------------------------------------------------------
        $incomplete = $false
        if ($collecting) {
            $step++
            Write-ExlStep $step $totalSteps 'Checking access to the servers and their log folders' -Icon Server
            $here = [Environment]::MachineName.ToUpperInvariant()
            foreach ($s in $servers) {
                $local = $s.Name -eq $here
                if ((Resolve-ExlServerRole -Server $s -Local:$local) -eq 'Edge') {
                    # Edge Transport: no IIS, HttpProxy, MAPI, ActiveSync, POP3 or IMAP4 to check or read.
                    $how = @{ Configuration = 'set in the configuration'; Discover = 'recorded by -Mode Discover'; Detected = 'detected' }[$s.RoleOrigin]
                    Write-ExlItem Info "$($s.Name): Edge Transport server ($how): SMTP protocol logs and message tracking only." -Icon Server
                }
                else {
                    # The IIS settings are read at every collection: a log folder moved since -Mode Discover is followed.
                    $notes = @(Test-ExlIisSites -Server $s -Local:$local -Sources $settings.Sources)
                    foreach ($n in $notes) { Write-ExlItem $n.Status "$($s.Name): $($n.Text)" }
                    if (@($notes | Where-Object { $_.Drift -or $_.Status -eq 'Warn' }).Count) { $incomplete = $true }
                }
                $problems = @(Test-ExlServerAccess -Server $s -Settings $settings)
                if ($problems.Count) { foreach ($p in $problems) { Write-ExlItem Warn "$($s.Name): $p" }; $incomplete = $true }
                else { Write-ExlItem Ok "$($s.Name): log folders readable ($(Get-ExlPathOrigin $s))" }
            }
            $step++
            Write-ExlStep $step $totalSteps 'Reading the new log lines' -Icon Download
            $collection = Invoke-ExlCollection -Store $store -Settings $settings -RunId $runId -Servers $servers
            if ($collection.Errors -or $collection.Unreachable.Count -or $collection.Stale.Count) { $incomplete = $true }
            foreach ($s in $collection.Stale) { Write-ExlItem Warn "$s. Logging stopped, or the logs were moved: run -Mode Discover." }
            $noisePercent = if ($collection.Lines) { 100.0 * $collection.Noise / $collection.Lines } else { 0 }
            Write-ExlItem Ok ("{0} files {5} {1} read {5} {2} lines {5} {3} kept {5} noise removed {4:0.0}%" -f (Format-ExlNumber $collection.Files), (Format-ExlBytes $collection.Bytes),
                (Format-ExlNumber $collection.Lines), (Format-ExlNumber $collection.Kept), $noisePercent, $dot)
            if ($collection.Recovered) { Write-ExlItem Info ("{0} failed request(s) followed by a success of the same user: marked as recovered." -f (Format-ExlNumber $collection.Recovered)) }
            $top = @($collection.NoiseReasons.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)
            if ($top.Count) { Write-ExlItem Info ('Main noise: ' + (($top | ForEach-Object { '{0} ({1})' -f $_.Key, (Format-ExlNumber $_.Value) }) -join ', ')) -Icon Filter }
            $step++
            Write-ExlStep $step $totalSteps 'Retention and maintenance' -Icon Broom
            $purge = Invoke-ExlRetention -Store $store -Settings $settings
            Write-ExlItem Ok ("Retention {0} days (details {1} days): {2} row(s) deleted {4} database {3}" -f $settings.Storage.RetentionDays, $settings.Storage.DetailRetentionDays, (Format-ExlNumber ($purge.Total)), (Format-ExlBytes $store.FileBytes), $dot)
        }

        if ($Mode -eq 'Collect') {
            $store.EndRun($runId, $(if ($incomplete) { 'Incomplete' } else { 'Completed' }), $collection.Files, $collection.Bytes, $collection.Lines, $collection.Kept, $collection.Noise, $null)
            $runId = $null
            Write-ExlSummary -Title $(if ($incomplete) { 'Collection finished with warnings' } else { 'Collection complete' }) -Values ([ordered]@{
                    Servers  = @('Server', ($servers.Name -join ', '))
                    Read     = @('Download', ("{0} in {1} files" -f (Format-ExlBytes $collection.Bytes), (Format-ExlNumber $collection.Files)))
                    Kept     = @('Ok', ("{0} lines of real activity {1} {2} noise lines removed" -f (Format-ExlNumber $collection.Kept), $dot, (Format-ExlNumber $collection.Noise)))
                    Database = @('Database', (Format-ExlBytes $store.FileBytes))
                    Duration = @('Clock', (Format-ExlDuration $clock.Elapsed.TotalSeconds))
                }) -Status $(if ($incomplete) { 'Warn' } else { 'Ok' })
            $exitCode = if ($incomplete) { 2 } else { 0 }
            $runStatus = 'Completed'
            break
        }

        # ---- last step: report ------------------------------------------------------------------------
        $step++
        if (-not $collecting) {
            # Role of each server (an Edge report has its own layout); the collection has already resolved it.
            # Without collection the servers are not contacted: the role comes from the data already collected.
            $here = [Environment]::MachineName.ToUpperInvariant()
            foreach ($s in $servers) { [void](Resolve-ExlServerRole -Server $s -Local:($s.Name -eq $here) -Store $store) }
        }
        Write-ExlStep $step $totalSteps "Building the $($ReportType.ToLowerInvariant()) report" -Icon Report
        $report = New-ExlReport -Store $store -Settings $settings -Period $period -ReportType $ReportType -User $User -Server $Server -IncludeRoutingDetails $settings.Report.IncludeRoutingDetails -IncludeSessionDetails $settings.Report.IncludeSessionDetails
        foreach ($f in $report.Files) { Write-ExlItem Ok ("{0}  {1} rows {2} {3}" -f (Split-Path $f.Path -Leaf), (Format-ExlNumber $f.Rows), $dot, (Format-ExlBytes $f.Bytes)) -Icon File }
        if ($runId) {
            $store.EndRun($runId, $(if ($incomplete) { 'Incomplete' } else { 'Completed' }), $collection.Files, $collection.Bytes, $collection.Lines, $collection.Kept, $collection.Noise, $null)
            $runId = $null
        }
        $c = $report.Counts
        $edgeReport = $c.ContainsKey('smtpdestinations')
        $periodText = Format-ExlRange $period.StartMs $period.EndMs $zone

        # ---- e-mail -------------------------------------------------------------------------------------
        $collectionWarnings = $incomplete
        $mail = $null
        if ($mailing) {
            $step++
            Write-ExlStep $step $totalSteps 'Sending the report by e-mail' -Icon Mail
            $problems = @(Test-ExlMailReady -Settings $settings)
            if ($problems.Count) { Write-ExlItem Warn ('The report is not sent: ' + ($problems -join ' ')); $incomplete = $true }
            else {
                try { $mail = Send-ExlReportMail -Settings $settings -Report $report -Period $periodText -ReportType $ReportType -Range $Range -Title $report.Title }
                catch { $mail = [pscustomobject]@{ Sent = $false; Error = $_.Exception.Message; Refused = @(); Tls = $null; AuthenticationUsed = $null } }
                if ($mail.Sent) {
                    $attached = if (@($mail.Attached).Count) { (@($mail.Attached) -join ', ') + ' attached' } elseif ($mail.OmittedBytes) { 'report not attached' } else { 'no attachment' }
                    Write-ExlItem Ok ("Sent to {0} {1} {2} {1} {3} {1} {4}" -f ((@($settings.Mail.To) + @($settings.Mail.Cc)) -join ', '), $dot, $(if ($mail.Tls) { $mail.Tls } else { 'no TLS' }), $mail.AuthenticationUsed, $attached) -Icon Mail
                    if ($mail.OmittedBytes) { Write-ExlItem Info ("The report ({0}) is larger than Mail.MaxAttachmentMB ({1} MB): not attached, the message gives its folder." -f (Format-ExlBytes $mail.OmittedBytes), $settings.Mail.MaxAttachmentMB) }
                    foreach ($r in $mail.Refused) { Write-ExlItem Warn "Recipient refused: $r"; $incomplete = $true }
                }
                else { Write-ExlItem Warn ("The report was not sent by e-mail: {0} (-Mode MailTest shows the SMTP conversation)." -f $mail.Error); $incomplete = $true }
            }
        }
        $values = [ordered]@{}
        $values['Period'] = @('Calendar', $periodText)
        $values['Servers'] = @('Server', ("{0} in the report{1}" -f (Format-ExlNumber $c['servers']), $(if ($edgeReport) { " $dot Edge Transport (mail flow only)" } else { '' })))
        if ($edgeReport) {
            $values['Clients'] = @('Mail', ("{0} SMTP client(s) {1} {2} SMTP destination(s)" -f (Format-ExlNumber $c['smtpclients']), $dot, (Format-ExlNumber $c['smtpdestinations'])))
            if ($ReportType -eq 'Detailed') { $values['Messages'] = @('Mail', ("{0} message(s) {1} {2} SMTP transaction(s)" -f (Format-ExlNumber $c['messages']), $dot, (Format-ExlNumber $c['smtp']))) }
        }
        else {
            $values['Users'] = @('People', ("{0} real user(s)" -f (Format-ExlNumber $c['users'])))
            if ($ReportType -eq 'Detailed') {
                $values['Sessions'] = @('People', ("{0} client session(s) {1} {2} with failures" -f (Format-ExlNumber $c['sessions']), $dot, (Format-ExlNumber $c['sessionsWithFailures'])))
                $values['Issues'] = @('Warn', ("{0} failed or slow request(s) kept" -f (Format-ExlNumber $c['issues'])))
                $values['Messages'] = @('Mail', ("{0} message(s) {1} {2} SMTP transaction(s) from {3} SMTP client(s)" -f (Format-ExlNumber $c['messages']), $dot, (Format-ExlNumber $c['smtp']), (Format-ExlNumber $c['smtpclients'])))
            }
        }
        $values['Folder'] = @('Folder', $report.Folder)
        if ($report.HtmlPath) { $values['Open'] = @('Report', $report.HtmlPath) }
        if ($mail) { $values['Mail'] = @($(if ($mail.Sent) { 'Mail' } else { 'Warn' }), $(if ($mail.Sent) { 'sent to ' + ((@($settings.Mail.To) + @($settings.Mail.Cc)) -join ', ') } else { 'not sent' })) }
        $values['Duration'] = @('Clock', (Format-ExlDuration $clock.Elapsed.TotalSeconds))
        $mailFailed = $mailing -and -not ($mail -and $mail.Sent -and -not @($mail.Refused).Count)
        $title = if ($collectionWarnings -and $mailFailed) { 'Report ready (collection incomplete, e-mail not sent)' } elseif ($collectionWarnings) { 'Report ready (collection incomplete)' } elseif ($mailFailed) { 'Report ready (e-mail not sent)' } else { 'Report ready' }
        Write-ExlSummary -Title $title -Values $values -Status $(if ($incomplete) { 'Warn' } else { 'Ok' })
        $exitCode = if ($incomplete) { 2 } else { 0 }
        $runStatus = 'Completed'
    } while ($false)
}
catch {
    $message = $_.Exception.Message
    Write-Host ''
    Write-Host ("  ERROR: {0}" -f $message) -ForegroundColor Red
    try { Write-ExlLog 'ERROR' ($message + [Environment]::NewLine + $_.ScriptStackTrace) } catch { }
    if ($runId -and $store) { try { $store.EndRun($runId, 'Failed', 0, 0, 0, 0, 0, $message) } catch { } }
    $exitCode = 1
}
finally {
    if ($store) { $store.Dispose() }
    if ($lock) { Exit-ExlLock $lock }
    try { Write-ExlLog 'INFO' ("End: {0}, exit code {1}, {2:0.0} s" -f $runStatus, $exitCode, $clock.Elapsed.TotalSeconds); Stop-ExlLog } catch { }
    [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
}
exit $exitCode

# SIG # Begin signature block
# MIIghQYJKoZIhvcNAQcCoIIgdjCCIHICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBQP6LIPGy0NH40
# p0NhjIB5vIiHCNLw10QDGDd4Ilg2BaCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# wZislcdCZuS6MYISbDCCEmgCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCA0luAcH+Ml
# YlnTVIDd7aiXKay4pcSvxWpkbKtGSyiW2TANBgkqhkiG9w0BAQEFAASCAgBQ1tj6
# gwIzMUhYNiOPF2Rnbym/pb5o4B265YRnrMlVaerONCCYV2wslXiVG22njNcNocDS
# AiCAra/AZ++1THLzKumoSMjFZHl/XxVQvEOKn7Sq93yvHp2joU9vIzpyr4fmmMOM
# j5BXwDbvIlZDJDICecJjYFemp3v7CKvUOIUwVjRRgiDQ7B/RIi1PFZIG1YMUaf5m
# vzAlSZgnJCm1MBNnJ/Zz9GPrqK/fzSolRDddAeSrDgaWD4gkZB5QO8dciU3i1fEU
# Ya58xpMvALfTyDosmFy8JgHGaw2Vi8om+SCtkxvjb+tDX1ZEfOOp4R4i0woFals+
# Tpiz4lw7xq6pjRS+ShgrrU7cP05ZHDoWp+mEcUv54GlAiOELObewAr5JGOpfnF6A
# wpo32oqfpxcokfH4wLfRq9SbnU2ixl0RX+XmmcbaIZ3xy5XwGGvI/GX+lmGrdEt0
# OreRGplCkfsQLL3x7/H4oOFo4kxCtiEUsraTRl9/8iz69XH79ePniu5PUVrYc3rC
# 8+gXxtVSRVLdPe1syRX70veRg7Dz3i5dtX9XV1uckBwy7fKlYydTA+47UPatBOj6
# KDZeAgB7tp00zQVRcyVT0fEc87SWulB1czQrLXfGUYUeETRC9MFPr5R6iwahViJo
# ASsihFbkM4N55u7SbD06fHLTzKFks0rvTXgyk6GCDykwgg8lBgorBgEEAYI3AwMB
# MYIPFTCCDxEGCSqGSIb3DQEHAqCCDwIwgg7+AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIJqIfdC3y5CVtzpKlmstnS/D+oEJoFOD4KBf4yQZ5NHQAghXEFKQl/Rl
# LhgPMjAyNjEwMjgxMTQ2MjBaMAMCAQECEBlxQvsjvWUs/IvmEbrHPQagggwAMIIE
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
# WDCCAlQCAQEwgYcwczELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYD
# VQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNv
# bSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgUjECEB9rFmLSLhtsXfHAwaBg
# DjgwCwYJYIZIAWUDBAIBoIIBYTAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAyODExNDYyMFowKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIGQOs6uBIXOj
# jWRHpCLg4nC2Eaaza9P22WhlQHLEdoRBMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEcwRQIgMFVU2v8lCttzXjN/UZdNrBvESmsIETCnaIV7mxLZWkMCIQCwLbBZWn/F
# vuuu9rDVhodsiPaysDv8kYawLTJhLmNAug==
# SIG # End signature block
