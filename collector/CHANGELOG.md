# Changelog — Exchange Log Report

All notable changes are listed here. Versions follow MAJOR.MINOR.PATCH (see the developer guide, Annex C).
Author: Nicolas Fabert.

## [Unreleased]

Changes of the ExchangeLogReportAngular 0.3.0 pilot (Serve portal, schemas 7 to 11, collection pipeline, server garbage collector) are listed in `..\CHANGELOG.md`.

### Added
- SMTP clients, the SMTP CSV files and the Messages route show the **authenticated user**, shown separately from the authentication mechanism and result and from the envelope sender. The value comes only from explicit successful server evidence (never from `MAIL FROM`, HELO, the client address or a decoded AUTH payload); when it is missing, ambiguous or unproven it shows *Not available*. Front-end submissions are matched to their back-end session by SID. Schema 5 to 6 is additive: no reset or rebuild, existing log read positions are kept, and earlier rows stay *Not available* (*Legacy*) without back-fill. New AUTH payloads, challenges and tokens are redacted before storage; earlier transcripts are redacted when a report or export is written, and stored database content is not rewritten. Verbose protocol logging remains required. Validated with offline synthetic tests only; not yet run on a real lab, deployment or publication.
- SMTP identity correction: an accepted proxy handoff retains its historical principal across later logins and collector restarts; explicit `503 Already authenticated` keeps the account and reports the refused attempt separately. Contradictory historical evidence retracts attribution. Long sessions drain evidence and completed transactions to bounded disk-backed parts, with no lifetime limit; proof updates and file offsets commit or roll back together.

### Fixed
- The delivered `Europe/Paris` time zone now falls back to the native Windows `Romance Standard Time` zone when ICU/IANA lookup is unavailable (for example with NLS). Winter/summer time rules are preserved; unknown IDs still stop configuration loading, and registry/data errors are no longer swallowed as an unknown name.
- Added `Report.MemoryBudgetMB` (default 512, 64 to 16,384 MB) and `Report.Parallelism` (default 0: up to four CPU workers, leaving one processor available). These settings affect reporting only; collection settings are unchanged.
- Report datasets now share an estimated memory budget and spill the largest retained dataset to disk only when needed. The budget partitions the source SQLite cache, temporary cache, retained rows and in-flight CPU work; runtime overhead, identity aggregates and individually oversized sessions/rows remain outside a hard process limit.
- Session JSON parsing, timeline reconstruction and HTML compression run on bounded CPU workers, with byte-based backpressure and ordered results. Database reads and temporary writes remain single-threaded. Old configurations receive the new defaults automatically.
- Message and sampled client/destination transcripts are retained as IDs, not expanded text, until an HTML row is actually emitted. A byte-bounded cache resolves complete text on the caller thread; rows beyond the HTML cap no longer inflate the temporary data or source sort.
- Scratch storage uses independent dataset tables and scoped group indexes. Compact SMTP links preserve Unicode case-insensitive matching in scratch while source reads use the existing binary indexes; no source schema/index or identifier-semantics change is required.
- Sampled row arrays are independent and intermediate datasets are released after use, including their charged group indexes. Message, route and sample chronology uses UTC milliseconds with stable ties, preserving the existing local display.
- Report statements share a read snapshot so SMTP counts and streamed exports cannot observe different collections. Unused Edge sessions are not rebuilt. Worker and cleanup failures remain visible behind the primary error, malformed timeline JSON fails explicitly, and in-flight output files have `.partial` names until closed and renamed.
- CSV-only SMTP transaction details are streamed directly from SQLite to the final CSV, avoiding a potentially much larger uncompressed copy in the temporary database. HTML-only reports do not read those transcripts. Report-stage starts are logged immediately to diagnose an interrupted or slow export.
- Spilled message rows are materialized in chronological order before export instead of performing one random temporary-database lookup per row; messages and their details remain complete.
- Large Detailed reports no longer retain all session timelines, message conversations and report datasets in RAM. Session reconstruction is batched, tracking and SMTP are correlated one message at a time, and large datasets use a report-local temporary SQLite file with an 8 MB page cache.
- HTML chunks are written progressively, bounded by row count and estimated memory size, instead of assembling the entire HTML payload in memory. CSV exports remain complete; `MaxHtmlRows` still limits only the HTML tables.
- SMTP client and Edge destination transaction samples are selected before loading their transcripts. The existing 200-transaction sample and failure priority are preserved, as are the full SMTP CSV and the top-10 e-mail summaries.
- Read-only report sorts can spill to disk instead of retaining their temporary data in RAM. Temporary report rows are removed on completion or a handled error; reports need additional free disk space while building and may take longer on slow storage.
- Discover and every collection now read the Exchange applications' `web.config` settings for moved MAPI HTTP back-end and HttpProxy log folders. Physical application paths come from IIS, including Exchange installed on another drive and relocated virtual directories.
- Both MAPI HTTP applications (`emsmdb` and `nspi`) are covered, even when they use different folders. Shared and overlapping log folders are collected once. The supported settings are `RequestDetailsLogger.MapiHttpMailboxLogFolder` and `RequestDetailsLogger.HttpProxyProtocolLogFolder`; native MAPI `LogPath` / `LogFilePath` and EWS back-end logs are different formats and are not added to the collection.
- Application settings support inherited values, scoped locations, `clear` / `remove`, `configSource` and external `file` settings. Invalid, inaccessible or encrypted settings produce application warnings and keep the previously known paths; other sources continue.
- The paths file records per-application folders. Collections follow changed or removed overrides and report drift; forced `MapiHttpPath`, `HttpProxyPath` or `LoggingPath` still win. An `ExchangePath` is an installation root, not a logging override. `-NoCollect` remains offline.

### Validated
- Full seven-day Detailed reports on an isolated lab database snapshot, with a 512 MiB report budget: 504,470 message-view rows and 1,029,919 SMTP transactions, 5.91 GiB of CSV/HTML output per run. One worker completed in 7 min 56 s at 771 MiB peak working set; two workers in 19 min 29 s at 570 MiB. Complete CSV hashes and decoded HTML rows matched; source and snapshot hashes were unchanged.
- These consecutive HDD runs had different cache/I/O conditions, not a controlled CPU speedup comparison. No parallel acceleration is demonstrated. The earlier 20-minute guard interrupted a progressing, multi-GiB SMTP CSV export; the completed runs retained memory and disk safeguards. No installed runtime was replaced, collection run or mail sent.

## [2.0.1] — 2026-10-12

Local review candidate; not yet published or approved through TRiP.

### Changed
- Applied the existing public README disclaimer unchanged to the runtime README, entry script and module.
- Corrected the entry-script help to describe local writes, optional report e-mail and the test message sent by `-Mode MailTest`.
- Documented the complete PowerShell/C#/SQLite package, sensitive output data and the separate retention of exported reports and e-mail copies.
- Collection, reporting, authentication, installation paths and runtime defaults are unchanged.

## [2.0.0] — 2026-10-07

A new collection engine: every server and every source is read at the same time, and the database is written in large transactions. The first collection of a production environment takes minutes instead of hours. The report can also be sent by e-mail.

### Changed
- **A report reads the database; it no longer collects first by default.** The daily routine is: the hourly scheduled collection reads the logs, and reports read the database.
  - A report reads the new log lines first only when the last collection is older than `Report.MaxDataAgeMinutes` (new, 90 min) **and** the period ends after it.
  - With no collection in the database, a report stops and asks for `-Mode Collect`: it never starts the first collection (14 days of logs) on its own.
  - While a collection is running, a report does not wait: it uses the data already collected.
  - The banner line **Data** gives the time of the last collection and what the report does.
  - New `-Collect` forces the collection first. `-NoCollect` still never collects.
  - Before, `-Range Last30Days` run without a scheduled collection started a collection of several hours before the report.
- **Parallel collection.** One parse thread per file reads every server and every source at the same time (`Collection.Parallelism`, default one per processor, 2 to 16, at below-normal priority). A single write thread uses the database. HttpProxy files are read first because they give the `domain\sam` accounts. SMTP and message tracking keep the threads busy meanwhile, and the back-end logs start once HttpProxy is written. The console shows one row per server and source as soon as that source is done, with a progress bar for the whole collection.
- **One transaction per batch of files** (30 s or 500,000 rows) instead of one per file, with the read positions of its files. An interrupted collection still resumes without duplicates. The client sessions stay in memory for the whole batch instead of being read and rewritten for every file.
- **Faster parsing and writing**:
  - lines are read and split as bytes;
  - field values and noise decisions are cached per thread;
  - the daily aggregates are computed by the parse threads;
  - SQLite statements are prepared once;
  - the page cache is 256 MB;
  - a new database uses 16 KB pages.
- **Recoveries** (a failure followed by a success of the same user) are resolved once, at the end of the collection. The result no longer depends on the order in which the files were read.
- **WAL.** It is copied into the database by a background thread during the collection, and emptied at the end. The execution log gives the time of each step and a statistics line: threads, write thread, commits, WAL copies, GC (developer guide 12.3).
- **Compressed storage.** SMTP transcripts and session timelines are stored compressed (Deflate, about 6 times smaller). Those written by 1.x stay readable. **A database written by 2.0.0 cannot be used by 1.x any more.**
- Retention deletes use the time indexes, and the SQLite statistics (`PRAGMA optimize`) are bounded.
- **Faster reports.**
  - A report now opens the database with the same 256 MB page cache as a collection, and sorts in memory. Before, it kept the 2 MB SQLite default and sorted in temporary files.
  - Messages per server and per hour are counted in one pass over a new covering index of the tracking events (`ix_msg_flow`). The SMTP counts use a covering index too (`ix_smtp_flow`). Both are built at the first opening of a 1.x database. Before, two `COUNT(DISTINCT …)` queries took most of a 30-day Usage report.
  - SMTP transcripts are read only for the transactions shown: none in a Usage report.
  - The execution log gives the slowest steps of every report (`Report step: …`).
- **Faster start of a collection.** The days that have client sessions and the `domain\sam` accounts are found by index seeks. Before, both reads went through whole tables: 24 s at the start of every collection on the lab hard disk, even with nothing new to read.

### Added
- **Report by e-mail.** The new `Mail` section of the configuration:
  - **Anonymous**, **Basic** (`AUTH LOGIN` / `PLAIN`, over TLS only) or **Kerberos** (`AUTH GSSAPI`, RFC 4752, without NTLM fallback);
  - **STARTTLS** (required by default) or implicit **TLS** (465), or no encryption;
  - the certificate is checked, or pinned with `CertificateThumbprint`.

  The body gives the summary of the report: period, real users, sessions, failures, messages and the verdict of every server. The report is attached as HTML (zipped above `MaxAttachmentMB`) or as a zip of every file, or not at all. A refused recipient or a message that is not sent gives exit code 2, and the report is still written.
- **`Collection.MaxFilesPerServer`** (default 4): files of one server read at the same time. The reads spread over the servers, and no server (nor the local disk of a collector that is an Exchange server) serves all the threads. The listing of the folders follows `Parallelism` too.
- **Main problems in the e-mail of a Detailed report**: 10 per kind, worst first — users with unresolved failures, client sessions that failed, SMTP clients with refused or deferred mail, SMTP destinations with failures (Edge). A kind without any problem is named on a *None in this period* line. A daily Detailed report sent by e-mail can be read without opening the attachment.
- **Two ways to use the tool**, documented as such: **recurring reporting** (scheduled tasks: the monthly usage and the daily Detailed report, written in HTML and sent by e-mail as an option; developer guide 7 C) and **troubleshooting on demand**. The user guide is rewritten as **one guided path**: set up once (steps 1 to 4: servers, `-Mode Discover`, the hourly task, `-Mode Status`), then branch **A** (steps 5 to 7: the two scheduled reports, open the report, option: by e-mail) or branch **B** (steps 5 to 7: Detailed report on the user and the period, client session, timeline to the raw log lines). Every step says what to do, gives one exact command on one example (EXCH01 to EXCH04, contoso.com, alice), what you should see and what to do if not; the README shows the same path.
- `-SendMail` (or `-SendMail:$false`) decides for one report run. `Mail.Enabled = $true` sends every report.
- **`-Mode MailTest`** sends a test message and shows the SMTP conversation, with the AUTH data masked. `-Mode MailTest -Credential` saves the account of `Basic` / `Kerberos` in `Mail.CredentialFile`, protected by DPAPI (`CredentialScope` `User` or `Computer`, file restricted to SYSTEM, the administrators and its writer). The credential file is never in the package.
- **Load test tools.** `tools\New-ExlSyntheticLogs.ps1` writes Exchange logs with the volumes of a production server (deterministic; `-Only` generates the logs of each lab server in place; `-Profile Decommission`: a barely used server and an unused one, for a decommissioning review). `tools\Measure-ExlCollection.ps1` measures a collection on them: duration, rate, database, peak memory and statistics (developer guide 12.2).

### Validated
- **The customer capture reproduced.** In the lab, 1.6.1 took 1 h 04 min for HttpProxy and **43 min 58 s for message tracking (273 KB/s)** on one server, the same as the customer (409 KB/s).
- **Load test** (2 servers × 14 days, 14.8 GB, 33.1 million lines, 7.0 million kept):
  - on a PC (8 logical processors, SSD), 1.6.1 took **29 min 45 s** and 2.0.0 takes **3 min 51 s to 4 min 21 s** (7 to 8 times faster);
  - the database is 2,116 MB instead of 2,562 MB;
  - the next collection with nothing new takes under 1 s.
- **The volume of a second customer capture** (4 servers × 14 days, 33.3 GB, 76.2 million lines; in production 1.6.1 took 6 h 36 min for 31.6 GB): 2.0.0 collects it in **13 min 18 s** on the PC, database 4.6 GB.
- **Lab, 1.6.1 against 2.0.0 on the same collector** (EXMBX1: 4 vCPU, 16 GB, Standard HDD; logs of 2 servers × 14 days through `E$`, 14.6 GB, 33.1 million lines; file cache emptied before each cold measure):
  - first collection: **4 h 55 min 49 s → 6 min 02 s** (× 49), database 2,522 → 2,212 MB;
  - next collection with nothing new: 7 min 17 s → 2.6 s;
  - Usage report, 30 days: **14 min 57 s → 2 min 30 s** cold, 27 s → 18 s warm;
  - Detailed report, 7 days: 15 min 36 s → 6 min 58 s cold, 52 s → 45 s warm;
  - 1.6.1 reproduced the customer capture: message tracking at 273 KB/s (44 min per server).
- **Lab, one server** (4 vCPU, Standard HDD), 7.2 GB:
  - read in about 2 min, 2 min 28 s with the end-of-run WAL copy;
  - with 16 KB pages, that copy took 22 s instead of 58 s with 4 KB pages.
- **E-mail on Exchange Server SE** (lab):
  - anonymous on 25, in clear and with STARTTLS (pinned certificate);
  - an untrusted certificate is refused;
  - Basic on 587; a wrong password gives `535`;
  - Kerberos on 587 with a saved account, including the security layer;
  - Kerberos as SYSTEM is refused by Exchange (`535 5.7.3 Unable to proxy authenticated session`, the computer account has no mailbox), and the tool explains why;
  - reports sent with `-SendMail` (Basic, Usage, 7 days, HTML 1.2 MB attached) and with `Mail.Enabled` (Kerberos, Detailed, 24 hours, HTML 3.3 MB attached);
  - a 7-day Detailed report whose zip (73 MB) is larger than `MaxAttachmentMB` is sent without attachment, and the console and the message say so.
## [1.6.1] — 2026-10-05

### Fixed
- **`-Start` / `-End` were ignored silently** without `-Range Custom`: `.\Invoke-ExchangeLogReport.ps1 -Start '2026-10-01 08:00' -End '2026-10-01 12:00'` built a report of the default range (`Report.DefaultRange`). The period parameters now select their range on their own: `-Start` / `-End` Custom, `-Month` Month, `-Date` Day (`-Range` can be left out, `-Range Custom -Start … -End …` still works).
- **No parameter is ignored silently any more.** The kinds of period are separate parameter sets: `-Start` requires `-End`, and `-Month`, `-Date` and `-Start` / `-End` cannot be combined (refused by PowerShell before the script runs). A period that contradicts `-Range` (`-Range Last7Days -Start …`) stops with an error. A parameter that the mode does not use is shown in yellow under the banner with the reason, for example *-Start, -End ignored with -Mode Collect: a collection reads every new log line, whatever its date* (period and report parameters with `-Mode Collect`, `Status` or `Discover`; `-Server` with `Status` or `Discover`; `-ConnectTo` / `-Credential` outside `Discover`).
- The *Mode* line of the banner showed only the mode: it shows the report type and the range again (`Report · Detailed · Custom`).
- `Get-Help .\Invoke-ExchangeLogReport.ps1` showed only the syntax: the `#Requires` line placed just before the help block hid it. The help now documents `-Month`, `-Date`, `-Start` and `-End` too.
- A report without collection (`-NoCollect`) checked the folders of every server to know its role: the role now comes from the data already collected (Edge SMTP logs and no client access log), and the servers are not contacted.
- A log folder that cannot be read (access denied: account that is not administrator of the server) stopped the access check, the collection or `-Mode Discover` with an error: it is now reported as *folder not found or not readable*, and a server whose folders cannot be read is treated as a mailbox server.

### Added
- **User guide** (`docs\ExchangeLogReport-UserGuide.md` and `.html`): prerequisites and everyday commands only — one command per question (unused server, user problem, missing message, incident, monthly review, Edge, collection check), period and filters, results, exit codes and usual warnings. The existing guide becomes the **developer guide**; the README points to both.
- `tools\Build-Documentation.ps1` without parameter builds both HTML guides; a link to the other guide (GitHub anchor) points to its HTML file. The package contains both HTML guides.

### Changed
- Only `-Mode` and `-Range` remain positional (`.\Invoke-ExchangeLogReport.ps1 Report Last30Days`); the other parameters are named.

### Validated
- Lab: on EDGE1 (Edge, SYSTEM) and, in parallel, the four mailbox servers from an administration server (scheduled tasks with the domain account, copy of the database): `-Mode Discover`, `-Mode Collect`, report `-NoCollect`, `-Start` / `-End` without `-Range` (Custom, end replaced by now), `-Range Last7Days -Start …` (error, exit 1), `-Mode Status` with `-Start` / `-End` (shown as ignored), report with a collection by an account that cannot read the folders (warnings, exit 2, report written).

## [1.6.0] — 2026-10-05

### Added
- **Edge report**: when every server of the report is an Edge Transport server, the report shows the mail flow only — title *Edge Transport mail flow*, tiles *Inbound SMTP* / *Outbound SMTP* / *Messages*, server cards and daily chart in SMTP received and sent, tabs *Messages*, *SMTP clients* and the new **SMTP destinations**. No client access view or file (`Users`, `Clients`, `Operations`, `ClientSessions`, `ClientAccess-*`), and no client access column in `Servers` / `Daily`. Folder `<FilePrefix>_Edge<Type>_…`.
- **SMTP destinations** (`SmtpDestinations.csv`, Edge report): one row per destination of the Edge (remote address + send connector) — Exchange Online, internet MX, the mailbox servers of the organization — with the remote host of its 220 banner, sent, deferred, failed, recipients, senders, TLS and last error; transactions and SMTP transcripts behind a click (failures first).
- The role of the servers is resolved for a report without collection too (`-NoCollect`).

### Fixed
- A message handed over by an Edge Transport server (tracking event `SENDEXTERNAL`) stayed *In transit*: it is now *Relayed*, like `SEND`.
- A server without client access (Edge, or a mailbox server with mail flow only) showed *No real activity in the period* and 0 active days: its first and last activity and its active days now come from its mail flow.
- The null sender (`MAIL FROM:<>`, NDRs) was shown empty in the SMTP clients: shown as `<>`.

### Validated
- Lab: Edge report of EDGE1 with generated internet and outbound traffic (guide 14.3); it showed a routing loop of the lab (tenant `onmicrosoft.com` domain accepted as *InternalRelay* without send connector).

## [1.5.1] — 2026-10-05

### Fixed
- **A log file reached through another path was read again.** The read position of a file was kept per path: when `-Mode Discover` replaced the administrative share of the collector itself (`\\EXCH01\C$\…`) by its local path (`C:\…`), or returned a folder in another case, every file was read again from the beginning. SMTP transactions and tracking events were not duplicated (unique keys), but the **client access counters** (daily usage, operations, clients) of the files read twice were counted twice. Files are now identified by their path on their own server, case ignored (`\\EXCH01\D$\Logs\x.log` = `D:\Logs\x.log`).

### Changed
- Database schema 3: `source_file.file_key` (identity of the file), upgraded at the next opening. A file already read through two paths keeps one read position (the one read last); the counters already doubled before the upgrade are not corrected (they leave the database with the retention).

## [1.5.0] — 2026-10-05

### Added
- **Edge Transport servers**: only their **SMTP protocol logs** (`TransportRoles\Logs\Edge\ProtocolLog\SmtpReceive|SmtpSend`, new sources *SMTP in (Edge)* / *SMTP out (Edge)*, role `Edge` in the SMTP data) and their **message tracking** are read. No IIS, HttpProxy, MAPI, ActiveSync, POP3 or IMAP4 source, and no IIS check (`applicationHost.config`) on them.
- **Role detection** at every collection: registry key `EdgeTransportRole` when the tool runs on the Edge itself; on another server, the AD LDS folder of the Edge role (`TransportRoles\data\Adam`) without the client access folder (`FrontEnd\HttpProxy`). The console says *Edge Transport server (detected)*. `Role = 'Edge'` or `'Mailbox'` in a `Servers` block forces the role; `EdgeReceivePath` / `EdgeSendPath` force the folders.
- **`-Mode Discover` on an Edge Transport server**: local Exchange Management Shell of the Edge (snap-in, no remote PowerShell, no RBAC: SYSTEM is accepted); SMTP log folders and message tracking of the Edge, receive and send connectors whose logging is off; `Role = 'Edge'` in the paths file. From a mailbox server, a subscribed Edge listed in the configuration is recorded with its role (no longer reported as *not found in Exchange*).

### Changed
- The paths file records the role of every server (`Role`).
- Collection step 2 is now *Checking access to the servers and their log folders*.
- Guide: new chapter 4.2 (Edge Transport servers), chapters 6.1, 6.2 and 7, lab validation 14.3, troubleshooting.

### Fixed
- On an Edge Transport server the collection warned about IIS settings not readable and client access folders *not found* (HttpProxy, IIS front end, ActiveSync back end), ended with exit code 2, and never read the SMTP logs of the Edge (it looked for the `FrontEnd`, `Hub` and `Mailbox` folders only).

## [1.4.0] — 2026-10-01

### Added
- **`-Mode Discover`**: finds where every Exchange server really writes its logs — installation folder, SMTP protocol logs per role and direction, message tracking, POP3/IMAP4 — with the Exchange cmdlets run in **Windows PowerShell 5.1** (`src\Get-ExlExchangeSettings.ps1`: Exchange Management Shell on an Exchange server, Exchange remote PowerShell with Kerberos elsewhere, `-ConnectTo`, `-Credential`). *View-Only Organization Management* is enough. Folders on another drive are read through the administrative share of that drive. Every folder is checked from the collector; disabled message tracking, POP/IMAP and SMTP connector logging are reported. Result in `config\ExchangeLogReport.paths.psd1`.
- **IIS sites from `applicationHost.config`** (`\\<server>\ADMIN$`): log folder, format and target of Default Web Site, Exchange Back End and of every **custom site hosting Exchange virtual directories** (a second OWA/ECP site), recognised from its virtual directories alone. Custom front-end sites are read with the IIS front end, custom back-end sites with ActiveSync with the ActiveSync back end.
- **Checks at every collection**: `applicationHost.config` is read again, so a moved IIS log folder or a new/removed custom Exchange site is followed at once and reported until `-Mode Discover` records it; an optional folder that does not exist (SMTP, MAPI, POP/IMAP, custom site) is shown as *no folder*; **stale source** warning when HttpProxy or IIS has no file newer than `Collection.StaleSourceHours` (new setting, 24 h). `-Mode Status` flags stale sources too.
- Per-server path settings for each source (`FrontEndReceivePath`, `HubSendPath`, `IisFrontEndPath`, `MapiHttpPath`...), which win over the paths file; unknown keys in a `Servers` block are rejected.

### Changed
- Guide chapter 4: where to run the tool and with which account — **SYSTEM on an Exchange server**, or a **domain account local administrator of every Exchange server** (+ View-Only Organization Management for `-Mode Discover`, *Log on as a batch job* on the administration server); why a local account does not work; network flows. Chapter 6.1 rewritten around `-Mode Discover`, chapter 7 with the task of both options, new troubleshooting entries, lab validation 14.2.
- Exit code 2 now also means a stale source or IIS folders changed since `-Mode Discover`.
- The console shows where the paths of each server come from (Discover, configuration, defaults).

## [1.3.1] — 2026-10-01

### Added
- `tools\New-DocumentationImages.ps1`: renders the graphics of the GitHub README (banner, why, how it works, noise, sessions and messages) in a light and a dark version, from the cards and flow blocks of the guide, with its CSS and icons.
- **HTML guide** `docs\ExchangeLogReport-Guide.html`, same format as the other tools (Purview DLP Report): self-contained (images inline), sidebar with parts and chapters, light/dark theme, copy buttons, print layout. Built from the Markdown guide by the new `tools\Build-Documentation.ps1`.

### Changed
- Guide: what is removed before storage (chapter 3) and the client session and message correlation (chapter 11) are now shown as cards and flows.
- Guide reorganised in four parts (Understand, Set up, Use, Maintain) and annexes, with a quick start, cards, steps and callouts; content updated to 1.3 (six tabs, SMTP clients, refusals in Messages).
- The package ships the HTML guide only (rebuilt by `tools\New-ExchangeLogReportPackage.ps1` before copying); the Markdown source and the images stay in the development folder.
- Screenshots of the guide taken from the lab report with generated traffic, anonymised (Contoso names), and a capture of the console of a detailed report.

### Fixed
- Detail dialogs: in the small tables (transactions of an SMTP client, client sessions of a user, clients and devices), times, servers, statuses and counters no longer wrap in the middle of a word.
- Console banner: the subtitle is shorter and can no longer push the right border of the frame.

## [1.3.0] — 2026-10-01

### Changed
- **Simpler HTML report: six tabs** — Client sessions, Failed and slow requests, Users, Operations, Messages, SMTP clients. Every CSV file is still written.
  - *Clients and devices* is now in the detail of each user, with the client sessions of that user (click one to open it).
  - *SMTP sessions* is replaced by **SMTP clients**: one row per SMTP client (address + HELO) with servers, connectors, volume, refusals, recipients, senders, TLS, authentication and last error; the detail lists its transactions (up to 200, refusals first) with their SMTP transcript. Hops between the collected Exchange servers are left out. Also in the Usage report.
  - *Messages* also lists the mail refused during the SMTP conversation (no Message-ID): *Rejected (SMTP)*, *Deferred (SMTP)*, *Not completed (SMTP)*.
  - *Servers* and *Daily* tabs removed: the server cards and the activity chart show them (and their CSV files remain).

### Fixed
- Deliveries to the mailbox servers (port 475, response `250 2.0.0 OK <message-id>`) are now attached to their message: their SMTP session is in the route.
- **Authenticated submissions (port 587)** were lost: the front end hands the session over to a mailbox server right after AUTH, so the front-end session had no `MAIL FROM` and was counted as a connection without message, and the mailbox server logged the front end as the client. The real client is now read from the `XPROXY` command (address, port, HELO) and the front-end part is counted as *Client submission proxied to a mailbox server*.
## [1.2.0] — 2026-10-01

### Added
- **Clickable timeline steps** (Client sessions): every field kept for the request (all the fields of a failed or slow request, or of a `FullDetailUsers` request; time, servers, status and duration otherwise) and **where its raw lines are**: the front-end and back-end log files (server, folder, hourly file) with a ready-to-copy `Select-String` command — RequestId for HttpProxy, IIS and MAPI, time and command for the ActiveSync back end, time and session for IMAP/POP. Raw lines are still never stored.
- Each timeline step keeps the id of its log file (`source_file`) and the text that finds its line; the CSV timeline lists the log files of each step.

### Validated
- Lab: the commands of an Outlook `Execute` (HttpProxy on EXCH02) and of a blocked ActiveSync `FolderSync` (`W3SVC2` on EXCH01, `Error:UserDisabledForSync`) return exactly the raw lines.

## [1.1.0] — 2026-10-01

### Added
- **Client sessions** (Detailed report, tab *Client sessions*, `ClientSessions.csv`): one row per session — what one client did for one user on one day until idle for `SessionIdleMinutes` — with outcome (*OK*, *Recovered*, *Intermittent errors*, *Failed at end*, *Failed*), client, addresses, front-end and back-end servers, requests, failures, slow requests, latency, operations, Outlook version and mode or mobile device, first and last error, and a **timeline** behind a click (every failure, slow request and milestone, the other successes folded into batches). `IncludeSessionDetails` / `-IncludeSessionDetails` adds the timeline to the CSV.
- **Correlation of front-end and back-end logs**: MAPI over HTTP (`Logging\MapiHttp\Mailbox`: Outlook version, cached mode, MAPI status codes behind HTTP 200, same `RequestId` as HttpProxy), ActiveSync (`W3SVC2`, Exchange Back End: `DeviceNotProvisioned`, `UserDisabledForSync`… behind HTTP 200, device access state, protocol version), POP3/IMAP4 (front end and back end).
- MAPI request type (`RT:`) and Outlook client instance (`CI:`) read from `ClientRequestId`; ActiveSync command, device ID and device type from `UrlQuery`.
- **Rejected Basic logons** attributed to their account from IIS (`401.1`, Win32 `1326` wrong password, `1909` locked, `1330` expired…), where HttpProxy only logs an anonymous 401.
- **Slow requests**: successes slower than `SlowRequestMs` (5,000 ms) are kept with outcome *Slow*; long-polling requests are excluded (`LongRunningPatterns`: Outlook NotificationWait, ActiveSync Ping, RPC/HTTP, OWA notifications, PowerShell, IMAP IDLE).
- Usage views **Clients and devices** (user × protocol × user agent or device: versions, addresses, servers) and **Operations** (protocol × operation: share, failure rate, slow, average and maximum latency).
- Optional **POP3 / IMAP4** source (`Sources.PopImap`): connections without logon and failed logons whose account is not logged are noise; back-end commands (with `NO` / `BAD` / `-ERR` results) are attached to the session of the client.
- Identities: `sam` or `sam@upn-suffix` (IMAP, POP, back-end logs) become `domain\sam` when the account is known.
- Database schema 2: tables `access_action`, `access_client`, `client_session`, `session_step`, column `access_usage.slow`; an existing database is upgraded at the next collection.

### Changed
- `ClientAccess-Issues.csv` is now `ClientAccess-Requests.csv` (failed and slow requests, and the requests of `FullDetailUsers`); HTML tab *Failed and slow requests*.
- Retention: client sessions and their timeline follow `DetailRetentionDays`; operations and clients follow `RetentionDays`.
- A log file whose read position is before its end (SMTP, IMAP or POP session still open) is read again at the next collection even if it did not grow, so that the held session is written once the file is idle (log rollover).
- Pester tests: 34 (MAPI front/back end, ActiveSync back end, IMAP front/back end, rejected Basic logon, slow requests, session merge across collections, IMAP connection held back, upgrade of a version 1.0 database).

### Validated
- Lab with generated traffic (Outlook MAPI over HTTP, iPhone ActiveSync with provisioning, OWA forms logon across sites, EWS, Outlook for Mac, IMAP/POP/SMTP client, application SMTP relay, wrong passwords, blocked ActiveSync, malformed EWS requests): see the guide, chapter 14.
## [1.0.0] — 2026-10-01

### Added
- Single entry point `Invoke-ExchangeLogReport.ps1` with three modes: `Report` (default), `Collect` (scheduled task), `Status`.
- Configuration file `config\ExchangeLogReport.config.psd1`, checked at start (all errors listed at once): servers (default administrative-share paths, per-server overrides), sources, noise rules, collection, storage, report, logging.
- Compiled C# engine (`src\Engine.*.cs`, compiled automatically on first use, like Purview DLP Report): incremental reading by byte offset (lines still being written are read at the next run), CSV/W3C parsing without per-field allocation, SQLite storage, CSV and HTML writing.
- Sources: HttpProxy (all protocols), IIS front end (`W3SVC1`), SMTP receive/send protocol logs (FrontEnd, Hub, Mailbox), message tracking (`MSGTRK*.log`). Columns found by name in `#Fields:`.
- Noise removed before storage and counted by reason: health/system mailboxes, computer accounts, Managed Availability probes (AMProbe, MapiHttpClient…), Exchange internal clients, load balancer health checks, anonymous 401 authentication challenges, SMTP sessions without `MAIL FROM` (by remote address), probe messages, shadow redundancy tracking events.
- Client access: daily usage per server × user × protocol; failed requests kept individually with IIS sub-status / Win32 status (`cafeReqId` ↔ HttpProxy `RequestId`); **recovery**: a failure followed by a success of the same user and protocol within `RecoveryWindowMinutes` (any server) is *Recovered*, later the same day *Recovered later*, otherwise *Unresolved*. `FullDetailUsers` keeps the successes of selected users.
- SMTP: one row per mail transaction with HELO, TLS, authentication, recipients, final response, Message-ID and InternalId, session transcript; open sessions at the end of the active file are read again complete at the next run.
- Messages: **one row per Message-ID** consolidated over all servers, with per-recipient status (Delivered, Relayed, Failed, Deferred, Dropped…), overall status, servers and events path, and the full **route** (tracking events + SMTP sessions in order) behind a click; `IncludeRoutingDetails` / `-IncludeRoutingDetails` adds the route and transcripts to the CSV files.
- Reports: *Usage* and *Detailed*, filters `-User` and `-Server`, periods Last24Hours, Last7Days, Last30Days, PreviousMonth, Month, Day, Custom. Every configured server appears with a verdict (*In use*, *Client access only*, *Mail flow only*, *No real usage*).
- Self-contained HTML dashboard (same design as Purview DLP Report): tiles, server cards with protocol bars and daily trend, activity chart, tabs with search, filters, sortable columns, virtual scrolling, detail dialog, export of the view.
- Retention: 60 days (usage, SMTP transactions, message tracking), 14 days (request-level failures, SMTP transcripts, execution logs); incremental vacuum.
- Modern console output (title card, numbered steps, collection table per server and source, noise summary, final card); daily log file; lock against simultaneous collections; exit codes 0 / 1 / 2.
- Pester tests (20) with log files generated in the exact Exchange formats; package tool `tools\New-ExchangeLogReportPackage.ps1`.

### Validated
- Lab EXCH01 to EXCH04, collector on EXCH01 as SYSTEM (PowerShell 7.6.6): 1.00 GB / 2,966,989 lines in 2 min 59 s, 99.9 % noise removed, database 16.4 MB; detailed 30-day report in 0.5 s.

### Known limitations
- Client access usage is aggregated per day: partial first/last days count as whole days (request-level failures are exact).
- An SMTP transaction rejected before the data has no Message-ID and appears only in the SMTP sessions view.
- Noise rules apply to new lines only; data already stored is not reclassified.
