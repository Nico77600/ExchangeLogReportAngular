#
#  Exchange Log Report - configuration file
#  --------------------------------------------------------------------------
#  Author  : Nicolas Fabert
#  Version : 2.0.1
#
#  This file is read by Invoke-ExchangeLogReport.ps1. It is a PowerShell data
#  file: text between quotes, $true / $false, numbers, and @( ) for lists.
#  Lines starting with # are comments. Relative paths are relative to the tool folder.
#
@{
    # ---------------------------------------------------------------------
    # Exchange servers. One block per server; their data is consolidated in
    # one database and one report. Usually only Name is needed:
    #   1. run -Mode Discover once on the collector: it reads the real log folders of
    #      every server (moved logs, Exchange on another drive...) and writes them to
    #      ExchangeLogReport.paths.psd1 next to this file;
    #   2. without that file, the default installation folders on C: are used
    #      (\\<Name>\c$\Program Files\Microsoft\Exchange Server\V15, \\<Name>\c$\inetpub\logs\LogFiles).
    # A folder can also be forced here; it wins over Discover:
    #   HttpProxyPath, MapiHttpPath, ImapLogPath, PopLogPath, IisFrontEndPath, IisBackEndPath (W3SVCn folder),
    #   FrontEndReceivePath, FrontEndSendPath, HubReceivePath, HubSendPath, MailboxReceivePath,
    #   MailboxSendPath, EdgeReceivePath, EdgeSendPath, MessageTrackingPath; or a root: ExchangePath,
    #   IisLogPath, LoggingPath, TransportLogPath.
    # HttpProxy and MAPI HTTP log folders customized in application web.config are detected at Discover
    # and checked at every collection. Forced HttpProxyPath / MapiHttpPath / LoggingPath still win;
    # ExchangePath locates the installation and does not override an application's logging setting.
    # Edge Transport servers are detected (registry on the server itself, Edge folders through C$, or
    # -Mode Discover run on the Edge): only their SMTP protocol logs and message tracking are read, no
    # IIS, HttpProxy, MAPI, ActiveSync, POP3 or IMAP4. Role = 'Edge' (or 'Mailbox') forces the role.
    # Account: SYSTEM on an Exchange server, or a domain account that is local administrator of
    # every Exchange server, plus View-Only Organization Management for -Mode Discover (user guide, chapter 1).
    # ---------------------------------------------------------------------
    Servers = @(
        @{ Name = 'EXCH01' }
        @{ Name = 'EXCH02' }
    )

    # ---------------------------------------------------------------------
    # Logs to read on each server.
    # ---------------------------------------------------------------------
    Sources = @{
        HttpProxy       = $true    # Logging\HttpProxy\<protocol>: main source of client access (one line per request)
        IisFrontEnd     = $true    # inetpub\logs\LogFiles\<IisSite>: IIS sub-status/Win32 status of failures, requests rejected before the proxy
        IisSite         = 'W3SVC1' # Default Web Site (front end) when -Mode Discover has not been run. W3SVC2 (Exchange Back End) is server-to-server traffic
        SmtpReceive     = $true    # TransportRoles\Logs\<role>\ProtocolLog\SmtpReceive (protocol logging must be enabled on the connectors)
        SmtpSend        = $true    # TransportRoles\Logs\<role>\ProtocolLog\SmtpSend
        MessageTracking = $true    # TransportRoles\Logs\MessageTracking\MSGTRK*.log
        TransportRoles  = @('FrontEnd', 'Hub', 'Mailbox') # mailbox servers; an Edge Transport server is read from its Edge folder
        MapiBackEnd     = $true    # Logging\MapiHttp\Mailbox or web.config override: Outlook version/mode and MAPI status behind HTTP 200
        EasBackEnd      = $true    # inetpub\logs\LogFiles\<IisBackEndSite>: ActiveSync results hidden behind HTTP 200 (only ActiveSync lines are kept)
        IisBackEndSite  = 'W3SVC2' # Exchange Back End web site when -Mode Discover has not been run
        PopImap         = $false   # Logging\Imap4 and Logging\Pop3 (optional). Needs Set-ImapSettings / Set-PopSettings -ProtocolLogEnabled $true
    }

    # ---------------------------------------------------------------------
    # Noise: lines removed BEFORE anything is written to the database. Each removed
    # line is counted by reason (see -Mode Status). Patterns are regular expressions,
    # case-insensitive, tested on the account name with and without domain.
    # Defaults below were checked against the logs of an Exchange SE lab.
    # ---------------------------------------------------------------------
    Noise = @{
        # Accounts that are not people: health mailboxes, system/arbitration mailboxes, computer accounts.
        SystemUserPatterns = @(
            '^HealthMailbox', '^SystemMailbox\{', '^SM_[0-9a-f]{10,}', '^FederatedEmail\.', '^Migration\.', '^DiscoverySearchMailbox',
            '^extest_', '^MSExchApproval', '^Exchange Online-ApplicationAccount', '\$$', '^nt authority\\', '^system$', '^S-1-5-18$'
        )
        # Managed Availability probes and Exchange internal clients.
        ProbeUserAgentPatterns = @(
            'AMProbe', 'ActiveMonitoring', 'MSExchangeHM', 'HealthManager', 'MapiHttpClient', 'ExchangeInternalEwsClient', 'ExchangeWebServicesProxy',
            'RpcClientAccess\.Monitoring'
        )
        # Load balancer health checks.
        ProbeUrlPatterns = @('healthcheck\.htm', '/owa/auth/x\.gif$')
        # Probe and system messages (message tracking, SMTP).
        ProbeSenderPatterns = @('^HealthMailbox', '^MicrosoftExchange329e71ec88ae4615bbc36ab6ce41109e@', '^inboundproxy@', '^SystemMailbox\{')
        # Client addresses to ignore entirely (prefix match), e.g. a monitoring server. Never put the
        # load balancer here if it hides the client addresses (SNAT): all traffic would be removed.
        ExcludedClientIps = @()
        # Shadow redundancy events (copies kept by another server until delivery): internal, not a route step.
        IgnoredTrackingEvents = @('HARECEIVE', 'HADISCARD', 'HAREDIRECT', 'HAREDIRECTFAIL')
    }

    # ---------------------------------------------------------------------
    # Collection (scheduled task, -Mode Collect). Only the new part of each file is read.
    # ---------------------------------------------------------------------
    Collection = @{
        BackfillDays           = 14     # first collection: files modified in the last N days
        RecoveryWindowMinutes  = 30     # a failure followed by a success (same user, same protocol) within N minutes is "Recovered"
        SmtpSessionIdleMinutes = 10     # an SMTP session open at the end of the current file is read again next time, unless idle this long
        FullDetailUsers        = @()    # users (domain\sam, UPN or SMTP address) whose successful requests are also kept, e.g. during an incident
        StoreAllRequests       = $false # $true keeps every real-user request (large databases: test environments only)
        # Client sessions (Detailed report): what one client did for one user on one day, until idle this long.
        SessionIdleMinutes     = 30
        SessionDetailRequests  = 40     # the first N requests of a session are always kept one by one in its timeline
        MaxSessionSteps        = 80     # timeline steps written per session and log file; the other successes are folded into batches
        # Successful requests slower than this (ms) are kept as "Slow" (0 = never). Long-polling requests are excluded:
        # pattern tested on "Protocol|Action|Url" (Outlook NotificationWait, ActiveSync Ping, RPC/HTTP channels...).
        SlowRequestMs          = 5000
        LongRunningPatterns    = @('^Mapi\|NotificationWait\|', '^Eas\|Ping\|', '^RpcHttp\|', '^Owa\|.*(notificationchannel|/ev\.owa)', '^PowerShell\|', '^Imap4\|IDLE\|')
        # HttpProxy and the IIS front and back end are written all the time by Exchange (health probes): a newest
        # file older than N hours means that logging stopped or that the logs were moved (0 = no check).
        # SMTP and message tracking are not checked: a server without mail flow writes nothing there.
        StaleSourceHours       = 24
        # Log files read at the same time, every server and source together (one thread each); one more thread writes
        # the database. 0 = one per processor (2 to 16). They run at below-normal priority: on an Exchange server,
        # Exchange keeps the processors it needs.
        Parallelism            = 0
        # Files of one server read at the same time (0 = no limit): the threads spread over the servers, and no
        # server - nor the local disk when the tool runs on an Exchange server - serves all of them.
        MaxFilesPerServer      = 4
        # Message rollups (the Serve message list) of a collection. Never = reconciled with every batch (default: the work runs
        # while the next files are read). Auto = the same, except for an initial import of more than 5 GB into an empty database,
        # which reconciles them once at the end. Always = once at the end. Deferred rollups of a stopped import leave Serve
        # answering 503 until the next collection drains them (with Never or Auto, before its first batch).
        DeferRollups           = 'Never'
    }

    # ---------------------------------------------------------------------
    # Local database (SQLite). Raw log lines are never stored.
    #   RetentionDays       : daily usage, operations, clients, SMTP transactions and message tracking
    #   DetailRetentionDays : request-level failures, client sessions and SMTP session transcripts
    # ---------------------------------------------------------------------
    Storage = @{
        DatabasePath        = '.\data\ExchangeLogReport.sqlite'
        RetentionDays       = 60
        DetailRetentionDays = 14
    }

    # ---------------------------------------------------------------------
    # Report files (CSV and HTML), written to local disk. Mail can also send them.
    # ---------------------------------------------------------------------
    Report = @{
        DefaultRange          = 'Last7Days'      # Last24Hours | Last7Days | Last30Days | PreviousMonth
        DefaultType           = 'Usage'          # Usage (who uses which server) | Detailed (+ failures, messages, SMTP sessions)
        TimeZone              = 'Europe/Paris'
        OutputPath            = '.\reports'      # one sub-folder per execution
        FilePrefix            = 'ExchangeLogs'
        Formats               = @('Csv', 'Html')
        IncludeRoutingDetails = $true            # message route and SMTP transcripts in the CSV files (always behind a click in HTML)
        IncludeSessionDetails = $true            # timeline of each client session in the CSV files (always behind a click in HTML)
        CsvDelimiter          = ';'              # ';' opens directly in Excel with French regional settings
        MaxHtmlRows           = 200000           # per table in the HTML file; the CSV files are always complete
        MemoryBudgetMB        = 512              # SQLite caches + estimated row/worker buffers; not a process RAM ceiling
        Parallelism           = 0                # report CPU workers: 0 = up to 4, leaving one processor; 1 = sequential
        # A report reads the database. It reads the new log lines first only when the last collection is older
        # than this and the period ends after it (-Collect / -NoCollect decide for one run). With the hourly
        # scheduled collection, a report never waits for a collection. 0 = never on its own.
        MaxDataAgeMinutes     = 90
        Title                 = 'Exchange Server usage and troubleshooting'
    }

    # ---------------------------------------------------------------------
    # Execution log files (one per day).
    # ---------------------------------------------------------------------
    Logging = @{
        Path          = '.\logs'
        RetentionDays = 14
    }

    # ---------------------------------------------------------------------
    # Sending the report by e-mail (SMTP). Every -Mode Report sends it when Enabled
    # is $true; -SendMail / -SendMail:$false decide for one execution.
    # Check the settings first: .\Invoke-ExchangeLogReport.ps1 -Mode MailTest
    #   Encryption      None      plain SMTP (trusted network only)
    #                   StartTls  STARTTLS required: never sent in clear (ports 25, 587)
    #                   Tls       TLS from the first byte (SMTPS, port 465)
    #   Authentication  Anonymous no account (receive connector open to the collector)
    #                   Basic     AUTH LOGIN / PLAIN with the account of CredentialFile,
    #                             over TLS only. Write the file once, with the account
    #                             that runs the tool: -Mode MailTest -Credential (Get-Credential)
    #                   Kerberos  AUTH GSSAPI, Kerberos only: the account that runs the tool
    #                             (the computer account for SYSTEM), or the account of
    #                             CredentialFile when it exists. SmtpServer must be a name
    #                             (SPN SMTPSVC/<SmtpServer>, or TargetName behind a load balancer).
    # The certificate of the server is checked (trusted chain, name = SmtpServer), unless
    # its thumbprint is set in CertificateThumbprint (self-signed Exchange certificate).
    # ---------------------------------------------------------------------
    Mail = @{
        Enabled               = $false
        SmtpServer            = ''                 # e.g. 'smtp.contoso.com' (a name, not an address, for TLS and Kerberos)
        Port                  = 0                  # 0: 25, or 465 with Encryption 'Tls'
        Encryption            = 'StartTls'         # None | StartTls | Tls
        Authentication        = 'Anonymous'        # Anonymous | Basic | Kerberos
        CredentialFile        = '.\config\ExchangeLogReport.mail.credential'
        CredentialScope       = 'User'             # User: readable by the account that wrote it only | Computer: by any account of this computer
        TargetName            = ''                 # Kerberos SPN when it is not SMTPSVC/<SmtpServer> (load balancer)
        CertificateThumbprint = ''                 # pin the certificate of the server instead of checking its chain
        HeloName              = ''                 # EHLO name; empty: the computer name
        From                  = ''                 # e.g. 'exchange-log-report@contoso.com'
        FromName              = 'Exchange Log Report'
        To                    = @()                # e.g. @('messaging-team@contoso.com')
        Cc                    = @()
        Subject               = '{Title} - {Type} report - {Period}'   # also {Range}, {Servers}, {Computer}
        Attach                = 'Html'             # Html (zipped when too large) | Zip (every file) | None
        MaxAttachmentMB       = 7                  # larger: not attached, the body gives the folder of the report
        TimeoutSeconds        = 60
    }
}
