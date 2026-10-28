# ExchangeLogReportAngular - collector and local portal

Usage and troubleshooting reports from Exchange Server SE on-premises logs,
with a local Angular investigation portal and a separate static Usage HTML report.

**Author:** Nicolas Fabert<br>
**Version:** 0.3.0 - experimental and unreleased; public repository preparation. The collector's historical
2.0.1 compatibility label is not the Angular product version or proof of upstream parity.

## Requirements

Use the complete reviewed Windows x64 package in a writable, access-restricted
local folder, with a supported desktop browser. The package supplies portable
PowerShell, compiled Angular assets, SQLite and a self-contained storage utility.
Node.js, IIS and an installed .NET or PowerShell 7 runtime are not required.

Collection still requires the existing Exchange/Windows permissions and log access.
Discovery uses Windows PowerShell 5.1 and the existing Exchange management prerequisites.
The source checkout requires the development tools described in [README.txt](../README.txt).

The five shipped PowerShell scripts carry owner Authenticode signatures and
RFC3161 timestamps; their coverage is described in [PROVENANCE.md](../PROVENANCE.md).
This pilot is not qualified for production. Respect application-control
and downloaded-file policies; do not indiscriminately unblock files or bypass signature
enforcement. A checksum or local manifest alone does not authenticate the publisher.
Read [SECURITY.md](../SECURITY.md) before using a package.

## Quick start

Extract the entire package and edit `collector\config\ExchangeLogReport.config.psd1`
to designate your test servers. From the **package root**:

```bat
Run-Collector.cmd -Mode Status
Run-Collector.cmd -Mode Discover
Run-Collector.cmd -Mode Collect
Start-ExchangeLogReportAngular.cmd
Run-Collector.cmd -Mode Report -ReportType Usage -Range Last7Days -NoCollect
```

Discovery and collection must be deliberate separate operations; the portal never
initiates either. `Status` and `-NoCollect` do not discover log paths or collect data.
For an already prepared schema-11 database copy, use:

```bat
Start-ExchangeLogReportAngular.cmd -DatabasePath "D:\Review\ExchangeLogReport.sqlite"
```

Serve never migrates the selected database. Older databases require an explicit
new-copy migration through `Database-Storage.cmd`; never overwrite the original.
If a source uses WAL, make a consistent SQLite backup instead of copying its main
file while writes are active. See the [Serve guide](docs/Serve-Guide.txt).

For the illustrated, step-by-step Angular workflow, open
[chapter C of the user guide](docs/ExchangeLogReport-UserGuide.html#c-angular-investigation).
Collection writes SQLite independently of the portal. After later collection,
extend **To, exclusive** if necessary and click **Apply selection**; opening or
refreshing a view never collects logs.

`Run-Collector.cmd` starts the collector with the server garbage collector
(`DOTNET_gcServer=1`, `DOTNET_GCHeapCount=4`, `DOTNET_GCNoAffinitize=1`); schedule
`Run-Collector.cmd -Mode Collect` for the hourly collection. A direct `pwsh.exe -File` call keeps the
workstation garbage collector unless it sets the same variables. Large first
collections need several GB of memory; the GC setting is not a process-memory cap.

## Content

The portable layout keeps collector paths under `collector\`, Angular assets under
`web\`, and dependencies beside them. Launchers verify `PackageIntegrity.json`
before starting the delivered runtime. The manifest is unsigned local integrity
evidence, not publisher authentication.

Paths below are relative to the package root:

- `Start-ExchangeLogReportAngular.cmd`: Start the authenticated, read-only loopback portal.
- `Run-Collector.cmd`: Existing discovery, collection, status and static report commands.
- `Database-Storage.cmd`: Read-only footprint audit and explicit new-copy maintenance.
- `collector\config\ExchangeLogReport.config.psd1`: Deliberately mutable operator configuration.
- `collector\src\` and `collector\lib\sqlite\`: Collector source compiled in memory and SQLite dependencies.
- `collector\docs\` and `collector\templates\`: Existing guides and static report template.
- `web\`, `powershell\`, `host\`, `sqlite-tools\`: Portable application and dependencies.

- **Usage** report: servers (verdict *In use* / *No real usage*), real users with their clients and
  devices (Outlook builds, mobile devices), operations with their failure rate and latency, SMTP clients
  (applications and devices that send mail, with their authenticated user when Exchange logged one), mail flow.
- **Angular Detailed/Serve**: Overview, Client sessions, Messages and SMTP clients.
  A session opens its cross-server timeline; a message opens its route and SMTP evidence;
  an SMTP client opens its scoped transactions and one transcript at a time.
  Pages are bounded and virtualized; detail bodies are not downloaded with a list.
- **Legacy Detailed export**: retained for compatibility, with client sessions,
  failed/slow requests, users, operations, messages and SMTP clients. It is not
  generated automatically by Serve. CSV exports and HTML row caps are different:
  a capped HTML table must not be presented as the complete dataset.

SMTP proxy identity is bound at the original accepted handoff: a later login cannot replace an earlier
transaction's user. Explicit `503 Already authenticated` preserves the established account; contradictory
evidence still withdraws it. Long connections continue in bounded, disk-backed evidence parts without a lifetime cap.

Retention: 60 days in the database, 14 days for request-level details, client sessions, SMTP transcripts
and log files.
On an **Edge Transport server** (detected, or `Role = 'Edge'`), only the SMTP protocol logs and message
tracking are read: no IIS, HttpProxy, MAPI, ActiveSync, POP or IMAP (developer guide, chapter 4.2), and the report is an
**Edge report**: messages, SMTP clients and SMTP destinations only (developer guide, chapter 9.6).
The tool is read-only for Exchange.

Log discovery also reads the relevant applications' `web.config` settings: moved MAPI HTTP
(`emsmdb` / `nspi`) and HttpProxy folders are followed at every collection, separately from IIS
W3C log folders. Forced log paths still win; `-NoCollect` remains offline. See developer guide 6.1.

Collection parses files concurrently and applies database writes in transactions.
Schema 11 uses derived rollups and SMTP client buckets: faster list reads can add
collection work and storage. The historical guides describe earlier measurements;
they are not current performance or capacity guarantees. Current limitations and
measurement boundaries are recorded in [README.txt](../README.txt) and the
[changelog](../CHANGELOG.md).

### Data handling

The package includes PowerShell scripts, C# source compiled in memory at each start (no engine
assembly is written or loaded from `bin\`), and third-party SQLite binaries; it is not a plain-text
PowerShell-only tool. It is read-only for Exchange, but writes its database, reports and execution
logs locally.

Report e-mail is disabled in the delivered configuration. `-SendMail` or `Mail.Enabled` enables it;
`-SendMail:$false` suppresses it for one report. `-Mode MailTest` sends a test message independently
of `Mail.Enabled`.

Noise removal is not anonymisation. The database and reports can contain account names, e-mail and
IP addresses, device identifiers, message subjects and SMTP transcripts. Restrict access to the
output folders and review the recipients before enabling e-mail. Database retention does not delete
exported HTML/CSV reports or copies sent by e-mail; their protection and deletion remain the
operator's responsibility.

SMTP AUTH payloads, challenges and tokens are removed before the database stores them. Transcripts
stored by an earlier version are redacted in reports and CSV exports; the existing database content is
not rewritten.

Serve binds only to `127.0.0.1` with a per-process token. It is not a remotely shared
portal and does not change firewall rules, URL ACLs or services. Never share launch
tokens or readiness files. Filters in copied URLs may contain private identities.
Stop the listener using Stop portal or Ctrl+C.

Third-party components retain their own licences; see
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and the Angular third-party notices
in the package.

## Documentation

| Guide | Scope |
|---|---|
| [Runtime README](../README.txt) | Portable launchers, storage-copy procedure and experimental limits |
| [Serve guide](docs/Serve-Guide.txt) | Current Angular portal, schema migration, bounds and automation |
| [User guide](docs/ExchangeLogReport-UserGuide.html) | Existing collector prerequisites and everyday operations |
| [Developer guide](docs/ExchangeLogReport-Guide.html) | Collector correlation, source formats, reports and troubleshooting |
| [Provenance](../PROVENANCE.md) | Build inputs, manifest limits and separate publication controls |

The HTML guides are self-contained and packaged. Older collector references are
not instructions to replace this package's launchers, build procedure or schema.
Build the Angular package with `tools\Build-Standalone.ps1` from the source root;
development tests and synthetic fixtures are never bundled.

## Disclaimer

This Script is a Personal project.
It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
