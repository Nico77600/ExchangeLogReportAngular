ExchangeLogReportAngular 0.3.0 - experimental local pilot; public repository preparation
Author: Nicolas Fabert

PURPOSE
The existing ExchangeLogReport 2.0.1 collector and C# report calculations
are preserved in a separate project. Serve uses System.Net.HttpListener and
reads lists/details on demand; it does not pre-generate a Detailed snapshot.
The Usage HTML remains an independent static client deliverable. CSV exports
remain available. The Angular application is compiled under web\ in the ZIP.
The original Exchange-Log-Report development directory is not modified.
The parallel tree keeps its legacy runtime under collector\ (src\, config\,
templates\ and relative data paths are preserved within it), while web\ and
portable dependencies live beside it. It does not rearrange the original
repository's package\ tree or an existing administrator deployment.

CURRENT EXPERIMENTAL LIMITS (24 OCTOBER 2026)
This is not an accepted release. On the existing 100k synthetic-message
selection, hourly Overview processes short selections one UTC hour at a
time within the same snapshot. Two local runs of
20 HTTP samples per case passed the strict all-samples-below-one-second gate:
Overview maxima were 879.6 and 681.4 ms (baseline before that change: 1049.2 ms).
All eight measured list cases also passed in both runs. These are bounded
local observations, not a latency guarantee, browser paint timings,
OS-cache-cold results, or proof at 24 GB. Selections over 31 days use a
single range query to avoid walking large empty intervals.
A 14-day synthetic legacy-versus-Angular comparison (132.5 GB of generated
logs) was run once on one Azure VM; its results are not committed to this
repository and are not a capacity guarantee. The comparison harness imposes
Collection.Parallelism = 1 and MaxFilesPerServer = 1 on both engines, unlike
the production default (one parse thread per processor, 2 to 16). Collection:
legacy 1815.5 s, Angular 1720.9 s (workstation garbage collector). Separate
Angular-only collections of the same logs: workstation garbage collector
1749.3 s, server garbage collector with 4 heaps 1440.0 s, the same plus
GCNoAffinitize (the Run-Collector.cmd setting) 1440.6 s with a 4103 MB peak
working set; files, lines and kept rows were identical. Reports were not
measured with the server garbage collector. Usage and Detailed outputs were
identical for 7 of 8 and 10 of 12 files; ExchangeLogs.html and
ExchangeLogs-ClientSessions.csv differ. Serve started in about 0.5 to 0.9 s.
Browser readiness and full business-value equivalence were not measured.

ADMINISTRATOR QUICK START (PORTABLE WINDOWS X64 PACKAGE)
1. Extract the complete ZIP into a writable, access-restricted local folder.
2. Read SECURITY.md and collector\THIRD-PARTY-NOTICES.md. The five shipped
   PowerShell scripts have owner Authenticode signatures and RFC3161 timestamps.
   The package integrity manifest remains unsigned; those script signatures do
   not authenticate C# sources, compiled Angular assets or native dependencies.
   This pilot has not been qualified for production or on a clean machine.
   Respect your organization's application-control and downloaded-file policies;
   do not bypass them. Only trust a reviewed package from the owner.
3. Edit collector\config\ExchangeLogReport.config.psd1: replace EXCH01/EXCH02
   with the real Exchange server names. Use a test environment first.
4. From a command prompt in the extracted folder:
     Run-Collector.cmd -Mode Discover
     Run-Collector.cmd -Mode Collect
   Existing Exchange permissions, connectivity and discovery prerequisites still
   apply. Discovery uses Windows PowerShell 5.1 and Exchange management commands
   where required by the existing collector; it does not install Exchange tools.
   Run-Collector.cmd starts PowerShell with the server garbage collector, 4 heaps
   not tied to processors (DOTNET_gcServer=1, DOTNET_GCHeapCount=4,
   DOTNET_GCNoAffinitize=1). A scheduled collection should call
     <package folder>\Run-Collector.cmd -Mode Collect
   A task that starts pwsh.exe -File collector\Invoke-ExchangeLogReport.ps1
   directly, and Start-ExchangeLogReportAngular.cmd, use the workstation garbage
   collector unless they set the same variables. A large first collection needs
   several GB of memory: a 1 GB SQLite page cache, up to 384 MB of parsed files
   waiting to be written, and the managed heaps (4103 MB peak working set on
   the synthetic run described above).
5. Double-click Start-ExchangeLogReportAngular.cmd.
6. The local listener opens the portal in your default browser. Select a view
   and a period covered by your collection. The portal never initiates
   collection, discovery, retention, mail delivery or an Exchange write.
7. Use Stop portal or Ctrl+C in the host window to stop it.

No Node.js, Angular CLI, IIS, installed .NET runtime or installed PowerShell 7
is required for this Windows x64 portable package. It bundles official portable
PowerShell and the separate storage-maintenance runtime. Windows 10/11 or a compatible Windows
Server with a supported desktop browser is required. Windows PowerShell 5.1 and
the existing Exchange-side discovery prerequisites are not replaced.
Application-control policy can still prohibit unsigned executables or scripts.

CUSTOM DATABASE
Use a COPY of a compatible ExchangeLogReport database:
  Start-ExchangeLogReportAngular.cmd -DatabasePath "D:\Review\ExchangeLogReport.sqlite"
If the source database uses WAL, make a consistent SQLite backup while the
collector is stopped, or use a supported SQLite backup procedure; copying only
the .sqlite file while writes are active can omit committed WAL content.
The portal rejects incompatible schemas rather than migrating the source.
Run-Collector.cmd still uses its configuration database, not this override.
Changing Storage.DatabasePath in the collector configuration also requires
passing the same path to the portal launcher.
Serve never migrates a database. Prepare an explicit copy with the delivered
storage utility before using an older schema in the new portal.

SQLITE: MEASURE FIRST, THEN CHANGE ONLY A NEW COPY
The SQLite storage work is independent from the Angular interface. Do not
replace the client's database or the original ExchangeLogReport installation.
The separate Database-Storage.cmd provides the footprint diagnostic. There is
NO web maintenance endpoint. Stop the collector before measuring or copying.
Unlike maintenance, Serve must allow concurrent collection using short
read-only SQLite requests; do not use maintenance as a live monitoring loop.

1. Diagnose the designated copy without modifying it:
     Database-Storage.cmd --storage-audit --database "D:\Review\Source.sqlite"
   Optionally save the JSON report with --output and an unused absolute path.
   Measurements include actual DBSTAT bytes per table/index, payload, unused
   space inside pages, page size/count, freelist pages, WAL and SHM separately.
   DBSTAT does not include freelist/pointer-map/other non-btree pages; the
   report accounts for this residual instead of claiming its objects are the
   whole file. MiB uses 1048576 bytes; integer-byte totals remain available.
   The original embedded SQLite lacks DBSTAT. The package therefore includes
   the pinned official SQLite CLI solely as a diagnostic dependency; it does
   not replace the collector's e_sqlite3 runtime or load an extension.

2. Test a full VACUUM on a NEW copy, with the original schema:
     Database-Storage.cmd --storage-copy --database "D:\Review\Source.sqlite" --destination "D:\Review\Compacted.sqlite" --output "D:\Review\Compacted.audit.json" --confirm-copy --vacuum
   This repacks partially filled pages, unlike incremental_vacuum. There is
   no promised 10-30 percent saving. Free-list count zero does not imply
   tightly filled btree pages. A full vacuum can take substantial time and
   temporary disk space; budget the source, destination and temporary output,
   not merely the size of the final file. Active writers are refused.
   Neither routine collection nor portal startup automatically runs a full
   VACUUM. An interrupted operation must not replace any existing file.
   Storage operations require ordinary local drive paths, not network paths,
   junctions, symbolic links or alternate data streams. Copy to local disk first.

3. Test the optimized schema on ANOTHER new copy:
     Database-Storage.cmd --storage-copy --database "D:\Review\Source.sqlite" --destination "D:\Review\Optimized.sqlite" --output "D:\Review\Optimized.audit.json" --confirm-copy --migrate
   Message hashes are lookup accelerators, never message identities: original
   text is retained and exact text equality remains mandatory after the hash.
   A hash alone must not establish uniqueness, a route match or a distinct
   message count. The covering flow index must retain the text where needed;
   lookup-index savings must not be extrapolated to every index.

4. Explicitly repack eligible existing text and compact the result:
     Database-Storage.cmd --storage-copy --database "D:\Review\Source.sqlite" --destination "D:\Review\Repacked.sqlite" --output "D:\Review\Repacked.audit.json" --confirm-copy --migrate --repack --vacuum
   Existing Packed/Deflate format remains readable. Short or incompressible
   candidates stay TEXT; a new packed candidate must be at least 200 UTF-8
   bytes and strictly smaller including its header. Fields used by SQL
   filtering, grouping or sorting are not blindly compressed.
   sender/recipients and other searchable identities remain searchable text.
   smtp_auth_fragment.observations remains TEXT: its SQL JSON/replay operations
   require that representation. Safe candidates are URL/errors, session
   actions/statuses and SMTP response; these are not SQL search identities.
   Mixed older TEXT and compressed BLOB rows must produce identical logical
   values. The copy workflow verifies normalized logical content and integrity
   before committing a destination; fingerprints are validation evidence,
   not a replacement for exact business comparisons.

5. Exact-text dictionary tables are used only for the '#Fields' header of
   each log file (source_fields), the message_rollup codes
   (message_rollup_value) and the SMTP client values (smtp_client_value).
   No other column is normalized, and trained Zstd dictionaries are NOT
   enabled. Decide further normalization only after representative
   client-copy measurements of cardinality, repeated-string bytes and query
   costs. It is a broader schema/dependency change, not a generic switch. A
   dictionary trained on customer data can contain private strings and must
   not be redistributed.

Optimized schema copies are for this Angular storage profile, not the older
original collector. Do not point the original tool at an optimized database.
The portal never automatically migrates a source. Retain the source copy and
the before/after audit receipts; always supply a new --output path for a copy
operation, and choose the new --database path explicitly.
Hash indexing trades lookup-index space for hash computation and maintenance;
it is not a promise of faster inserts or reads. Measure both costs against
your workload before choosing the optimized copy as the production collector.
Serve adds covering lookup indexes and rollup tables. Their cost can offset
the smaller hash-only indexes; do not claim that the complete Serve profile
has smaller message indexes without comparing every index in its audit.
No in-place overwrite, NTFS compression, ZIPVFS or sqlite-zstd is configured.
Real client gains remain unknown until an actual client COPY is designated
and measured. Synthetic long-ID/repetitive-text tests are not capacity claims.
These storage measurements concern the selected collector database, not the
whole installation. CSV exports and historical 0.1 snapshot files remain
separate and need their own retention policy. Serve creates no new Detailed
snapshot. Rollup tables add derived data; compare their size as well.

DATA AND NETWORK
The portal listens only on IPv4 loopback (127.0.0.1), on a configurable local port.
It is not a remotely accessible shared portal. A per-process access token is
passed in the browser URL fragment and required for every API request. Do not
share the link. No CORS, public listener, firewall changes or service registration.
This is not protection against an attacker already controlling your Windows
account or process.
Reports, CSV and the collected database contain private account, device,
message and SMTP data. Restrict the package folder and exported downloads.
Exports are independent of collector retention: delete them according to your
policy. Collection and migrations can consume disk space.
The package contains no source database, real report, private log or credential.
No CDN or internet connection is needed to use the packaged portal.

PILOT SCOPE
Serve is a local investigation interface, not a remotely shared application.
Overview, message lists, client sessions and SMTP clients are loaded on demand.
Routes and transcripts are requested only when a record is opened. Existing
collector data and the static Usage report remain available separately.
The portal follows the original Detailed report's header, overview tiles,
server cards, daily activity, horizontal view navigation and detail dialogs.
Its overview deliberately labels retained requests, tracking EVENTS and SMTP
transactions: hourly distinct-message counts must not be added and presented
as a global distinct-message or real-user total. Retention can shorten details.
SMTP clients open a paginated group-scoped transaction list, then the selected
transaction's transcript. CSV export is not offered for a selected client:
the existing transaction CSV endpoint exports the whole filtered selection.
Long queries are bounded and can fail with an explicit timeout rather than
returning a partial success. A CSV export uses the same filters and can run
longer than a list; it is not an assurance of unlimited query duration.
Extra tracking evidence is not silently discarded to improve response times.
Message hashes remain accelerators with exact text verification.
Schema 7 was already assigned to storage changes; rollups use a separate next
schema instead of silently redefining an existing schema-7 database.
Schema 10 narrows the two exact-identity indexes to (msg_hash,time_ms), stores the '#Fields' header
text of each log file once in source_fields and, coming from schema 8, also replaces the derived indexes and
rollup trigger column lists (see CHANGELOG.md).
Schema 11 (current) pre-aggregates the SMTP clients per client x UTC hour (smtp_client, smtp_client_hour,
smtp_client_value, smtp_transaction.client_id) so that the SMTP client list and its detail do not group every
transaction of the period at each request, and stores message_rollup with dictionary codes (message_rollup_value;
status, direction, servers, events and kind as integers; first/last time NULL when equal to the member bounds).
The UNIQUE(kind,identity) constraint is kept; ix_smtp_latest is dropped. Serve requires schema 11 and answers 503
SmtpClientsPending while SMTP rows written by another program wait for the explicit reconciliation.

MIGRATION TO SCHEMA 11. An older database is migrated only by a writable collection open or by
Database-Storage.cmd --storage-copy --migrate on a NEW copy; Serve never migrates. The migration is one
transaction (a failure rolls back everything and the database stays at its previous schema), rewrites
message_rollup and the client_id of every SMTP transaction, and proves its result before it commits (decoded
rollup rows equal the old ones; the SMTP client structures equal a recomputation). For a database of about
20 GB (1.9 million SMTP transactions, 5.5 million rollup rows) plan on the order of 3 to 5 minutes of exclusive
write access: prototypes of the two parts took about 98 s (SMTP clients) and 73 s (message_rollup) on a copy of
such a database, and the proof inside the transaction was estimated, not measured, at about one more minute.
Keep about 6 GB of free space on the volume of the database for the write-ahead log and the transient copy of
message_rollup (the freed pages are returned by the next incremental vacuum). The first migration of a database of
that size has not been run by this implementation; measure it on a copy first. Nothing in the collector or Serve
is usable on that database until it is over.

HttpListener uses Windows HTTP.sys. Application-control or URL registration
permissions can prevent startup even without an installation requirement.
The tool must report that condition; it does not create URL ACLs, alter the
firewall, install a service, or silently choose another server technology.
The operator must resolve any required permission under their normal policy.
Portability is not a bypass of Windows or organizational access controls.

BUILD (DEVELOPMENT MACHINE ONLY)
Prerequisites: Node.js compatible with the pinned Angular LTS, npm, .NET SDK supporting
net8.0, PowerShell 7.4+. The current host targets .NET 8; plan its supported
framework upgrade before the .NET 8 end of support, November 10, 2026.
  cd frontend
  npm ci --no-fund
  cd ..
  pwsh -NoProfile -File .\tools\Build-Standalone.ps1
Build output: artifacts\ExchangeLogReportAngular-0.3.0-win-x64.zip
The build downloads only the pinned official PowerShell archive and verifies
its SHA256. Upstream debug-symbol PDB files are omitted from delivery.
The SQLite diagnostic executable is verified against product.json; its
official archive SHA3-256 was verified when the dependency was introduced.
Other dependency restoration uses npm's lockfile and .NET restore.
CI uses npm ci from the committed lockfile and rejects high/critical npm
audit findings. Angular 21.2.25 is the selected LTS, with CDK only as the
additional runtime UI package. Vitest/jsdom are development-only unit tools.
The delivered collector\README.md follows the common runtime documentation
sections and links to these original runtime paths. README.txt remains the
portable quick-start entrypoint; both are shipped. Packaging freezes the
delivered documentation bytes along with the code inputs.
PackageIntegrity.json inventories immutable runtime source, the compiled web
bundle and dependencies. tools\Test-PackageIntegrity.ps1 verifies these bytes;
the collector configuration remains editable. Launchers run this check.
This local manifest is unsigned and is NOT publisher authentication.
The local builder does not create or modify a GitHub repository, upload source
or publish a release. The reviewed public destination is
Nico77600/ExchangeLogReportAngular. Source publication and release assets require
separate owner approval; never silently change the approved repository registry.

VALIDATION (DEVELOPMENT MACHINE)
  Invoke-Pester -Path .\collector\tests\ExchangeLogReport.Tests.ps1
  Invoke-Pester -Path .\collector\tests\SqliteOptimization.Tests.ps1
  Invoke-Pester -Path .\collector\tests\Serve.Backend.Tests.ps1,.\collector\tests\Serve.Performance.Tests.ps1
  Invoke-Pester -Path .\collector\tests\Serve.SmtpClients.Tests.ps1,.\collector\tests\Serve.RollupVerification.Tests.ps1
  Invoke-Pester -Path .\collector\tests\Serve.Initialization.Tests.ps1,.\collector\tests\Serve.MeasurementGate.Tests.ps1
  cd frontend
  npm test -- --watch=false
  pwsh -NoProfile -File .\tests\New-DemoDatabase.ps1 -Destination <empty-folder>
Synthetic data stays outside the distributable and never enters a tenant.
The portal/packaging integration tests document their own parameters.
tests\New-StorageBenchmark.ps1 accepts a frozen schema-6 synthetic seed for
repeatable before/after measurement; it refuses a generic/client database.
tests\Measure-LegacyComparison.ps1 defaults to PREPARATION ONLY. It pins a clean,
explicitly designated public checkout and records independent synthetic
configurations, exact UTC intervals, source hashes and pending measurements.
It never collects Exchange data or opens an existing/customer database.
For example, -Days 14 -FixtureEnd 2026-10-15T00:00:00Z describes October 1-15
of synthetic logs and October 8-15 of reports (end-exclusive). Supply the exact
-LegacyRoot, cached -LegacyCommit and a new absolute -OutputRoot.
The inspected public checkout declares module 2.1.1; the pilot's compatibility
source label is 2.0.1. Do not silently treat them as identical baselines.
With -GenerateLogs -Execute and an explicit compiled -WebRoot, the runner can
collect newly generated bounded synthetic logs in isolated child processes,
measure both database footprints and seven-day Usage reports, legacy Detailed,
and Serve startup/first/warm HTTP. Defaults remain a small functional run.
Larger runs require the explicit -Representative switch: generated logs, total
output, elapsed time, sampled working set and free disk/memory reserves remain
bounded. -TargetLegacyDatabaseGiB records the measured legacy main-file target
after disposal (1 GiB = 1073741824 bytes, tolerance 5 percent), not input-log
bytes or a generator-scale extrapolation. Calibrate with smaller synthetic
collections first; no SQL padding or existing/customer input is supported.
Use -DevelopmentMode only with unpackaged
source; a present integrity manifest is still mandatory and cannot be bypassed.
Timings are labelled FunctionalConcurrent, not exclusive or OS-cache-cold.
The runner imposes Collection.Parallelism = 1 and MaxFilesPerServer = 1 on
both engines. Browser readiness and full business-value equivalence are not
measured by the runner; matching row counts alone does not establish
equivalence. The representative run quoted under CURRENT EXPERIMENTAL LIMITS
was made with these settings.

SERVE COMMANDS
  Start-ExchangeLogReportAngular.cmd -Port 8765
  Start-ExchangeLogReportAngular.cmd -DatabasePath "D:\Review\Optimized.sqlite" -Port 8765
  Run-Collector.cmd -Mode Report -ReportType Usage -Range Last7Days -NoCollect
The first two use the compiled portal without Detailed generation. The last
command keeps the original static Usage HTML workflow.
For a developer source checkout without a distribution manifest:
  pwsh -NoProfile -File .\collector\Invoke-ExchangeLogReport.ps1 -Mode Serve -DatabasePath <absolute-db> -WebRoot .\frontend\dist\portal\browser -DevelopmentMode
A present distribution manifest is always verified; DevelopmentMode is not
a bypass. The engine compiles authenticated source in memory, never a planted
collector\bin cache assembly. Read collector\docs\Serve-Guide.txt for limits.

DISCLAIMER
This Script is a Personal project.
It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.
