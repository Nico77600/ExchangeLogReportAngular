# Changelog

## 0.3.0 — Unreleased

Experimental Angular Serve pilot, prepared for a separate public repository.
The following is the implementation
and validation scope, not a published release or a claim that all gates passed.

### Public repository preparation (October 26, 2026)

- On October 27, normalize the remaining 146 development-mirror archive URLs
  with the existing lockfile helper before public source review. All 579 resolved
  archives use the official npm registry; package versions, integrity digests and
  other dependency metadata remain unchanged. Keep this public-origin contract
  in the existing workflow regression suite.
- Follow the owner's revised public-visibility decision for the separate
  `Nico77600/ExchangeLogReportAngular` repository. Align product metadata,
  documentation, exact-repository CI/CodeQL guards and distributed-ZIP
  attestation checks; retain the same validation procedures and action pins.
  Repository creation, baseline/inclusion approval, signing and exact-content
  publication remain separate pending steps. Earlier private-pilot notes below
  describe the original preparation, not the current publication target.

### Pilot implementation target

- Document Angular as a third step-by-step investigation workflow alongside
  static Usage and Detailed, with collection-to-SQLite-to-Serve lifecycle,
  fixed-window refresh semantics, scoped SMTP drill-down, export/privacy bounds
  and operational diagnostics. Deliver both existing synthetic illustrations
  with the HTML guides and freeze them in the package's input inventory. Restore
  their referenced static SMTP illustration from its tracked upstream history.
- Add the owner-requested root README with the approved theme-aware presentation,
  project-specific investigation workflow, exact disclaimer and synthetic-only
  screenshots. Keep the unsigned/unreleased status, absent project licence grant
  and separate live-publication requirements explicit.
- Apply compatible stable dependency updates: Angular CLI 21.2.27, Vitest
  4.1.12 and reviewed parent-scoped MCP SDK/Vite/Undici overrides. Angular runtime
  remains 21.2.25. The October 26 follow-up adds parent-scoped body-parser 2.4.0
  and fast-uri 3.1.9 corrections, using unchanged, integrity-verified official
  npm archives through an authorized acquisition host. The full npm audit now
  reports zero findings; no audit bypass, major/prerelease upgrade, global
  registry/TLS change or vendored/Git-source substitution.

- Correct strict-mode test fixtures: optional hashtable keys and SMTP context
  fields are explicit, workflow steps are selected by property presence, and
  the SMTP reference helper suppresses the asynchronous shutdown result rather
  than emitting a second return value. Exact equality and failure assertions
  are retained; no runtime behavior or validation threshold is changed.
- Deliver the existing `collector/README.md` with the portable package, align
  its runtime documentation sections and remove blanket file-unblocking advice.
  Freeze delivered documentation in the build inputs and declare the actual
  runtime/build/test paths in `.github/ci.json`. No remote policies are changed.

- Add an engine-owned loopback `HttpListener` Serve path under
  `collector/src/Engine.*.cs`, retaining the collector's existing collection
  and report functions.
- Move the compiled Angular application into the standalone package's `web/`
  directory; keep Node/npm as development/build dependencies only. Launch the
  portable PowerShell collector with `-Mode Serve`, not Kestrel; retain the
  self-contained host only for storage CLI operations.
- Require explicit `-DevelopmentMode` for unpackaged source Serve runs; never
  bypass a present package manifest. Compile collector Engine sources in memory
  rather than loading a cached engine DLL.
- Introduce schema version 8 (later superseded by 9, 10 and 11, below) and derived query/rollup improvements, with
  synthetic Serve/API regression and performance validation. Final migration
  behavior and measured results must be confirmed by the implementation tests;
  no 24 GB production-database benchmark is asserted.
- Keep original input databases untouched during development validation and
  preserve explicitly requested copy-based maintenance procedures.
- Inventory delivered runtime files and compiled Angular assets in
  `PackageIntegrity.json` and verify the package before treating it as a usable
  delivery. Local pilot integrity records remain unsigned.
- Restore the original Detailed presentation: full-width hero, overview tiles,
  server cards, daily retained-source activity, horizontal navigation, dense
  virtualized rows and native detail dialogs. Keep retained-source counts
  explicitly distinct from the original static Usage aggregates.
- Wire SMTP client groups to their paginated transactions and on-demand
  transcripts, including scoped return navigation. Do not offer a misleading
  whole-selection CSV export from a single-client view.
- Add development-only preparation for fixed-window synthetic legacy-versus-
  Serve comparisons. Record exact source designations and pending metrics;
  this preparation does not itself execute a benchmark (a 14-day 132.5 GB
  synthetic run was later made with it; see the server garbage collector section).
- Bound hourly Overview temporary grouping/distinct work by querying UTC hours
  newest-first within the same read-only snapshot for selections up to 31 days.
  Preserve partial/exclusive bounds, exact text counts, server ordering,
  cancellation and the 10000-bin error. Longer sparse selections retain one
  range query; no schema/index change or source mutation is introduced.
- Add explicit bounded synthetic comparison execution with isolated engines,
  collection/database footprints, both seven-day Usage reports, legacy Detailed
  and Serve startup/first/warm HTTP. Browser readiness and full business equivalence
  remain pending; the representative 14-day run (132.5 GB of synthetic logs) is
  reported in the server garbage collector section.
- Keep tiny comparison defaults and require explicit representative opt-in for
  larger generation and execution budgets. Retain disk/memory reserves, bounded
  generation/children and frozen inputs. Record a legacy disposed-database GiB
  target separately from log bytes; generator scale is not a capacity result.
- Sample mutable comparison output sizes without aborting when SQLite removes a
  WAL/SHM sidecar during close. Record vanished-sidecar samples separately from
  measured zero-byte files; frozen inputs and other file/access errors remain
  strict. Interrupted campaigns are preserved and require fresh run outputs.

### Schema 9 and comparison-harness corrections (unreleased)

- Schema 9 replaces schema 8 for Serve. Existing schema-8 databases are upgraded only by a writable
  collector/Store open or by `Database-Storage.cmd --storage-copy --migrate` on a new copy; Serve still never
  migrates a source. The upgrade is one transaction that changes no source or `message_rollup` row.
  - Drops `ix_msg_hash` and `ix_smtp_hash` (strict prefixes of `ix_msg_identity_time` / `ix_smtp_identity_time`;
    no query filters on the hash alone) and `ix_session_latest` (the session list reads `ix_session_time` backwards).
    The exact binary `message_id` comparison after every hash lookup is unchanged.
  - Recreates `ix_smtp_latest`, `ix_rollup_last` and `ix_rollup_status_last` ascending (the rowid `id` is their implicit
    last key, so `ORDER BY ... DESC, id DESC` is a backward scan without a sorter) so appends in time order fill pages.
  - Narrows the `UPDATE OF` column lists of the rollup triggers to the columns the rollup is derived from.
    Dropped from `message_event`: source, internal_id, recipient_status, client_ip, client_host, server_host,
    connector, source_context, related_recipient, reference. Dropped from `smtp_transaction`: role, connector,
    remote_ep, local_ep, helo, tls, auth, rcpt_count, auth_user.
  - Fresh and schema 6/7/8 databases end with the same index/trigger set; `VerifyServeRollups` and the storage
    maintenance verification require that exact set (schema-8 sources are still verified against their own shape).
- `ReconcileMessageRollups` prepares its statements once per call and reads the SMTP count and time bounds of an
  identity in one query; stored rollup values are unchanged. Collection statistics now report
  `message rollups N s (K keys)`.
- Comparison harness: a `.sqlite-wal`/`.sqlite-shm` sidecar that vanishes during output sampling is also recognised when
  the not-found error is wrapped in an invocation exception; other errors still stop the run. The child receipt keeps the
  engine's per-phase `Statistics` string as `collectionStatistics` (null when an engine does not provide it).
- Serve and the storage tools required/produced schema 9 at this step; schema 10 below supersedes it.

### Schema 10, collection without triggers while applying, SMTP clients memo (unreleased)

- Schema 10 replaces schema 9 for Serve and the storage tools. Databases of schema 6, 7, 8 and 9 are upgraded only by a
  writable collector/Store open or by `Database-Storage.cmd --storage-copy --migrate` on a new copy; Serve never migrates.
  One transaction, idempotent, rolled back as a whole on any failure; no source row, `message_rollup` row or dirty-queue
  row changes. A fresh database and databases migrated from 6, 7, 8 or 9 end with the same `sqlite_master`
  (index/trigger/derived-table definitions are compared by the tests).
  - `ix_msg_identity_time` / `ix_smtp_identity_time` keep `(msg_hash,time_ms)` only (the rowid `id` is the implicit last
    key, so `ORDER BY time_ms,id` needs no sorter). The hash is still only an accelerator: every lookup keeps
    `msg_hash=@h AND message_id=@m COLLATE BINARY`, the exact compare now being made on the table row.
  - New table `source_fields(id INTEGER PRIMARY KEY, text TEXT NOT NULL UNIQUE)` and column `source_file.fields_id`: the
    `#Fields` header text of a log file is stored once per distinct text. The migration inserts the distinct texts,
    points every row at its text, compares every row byte for byte with its dictionary text, and only then clears the
    old `source_file.fields` (a mismatch aborts the migration). Readers use `COALESCE(dictionary text, fields)`, so a
    row without `fields_id` (a non-text value, or a row written by an external tool) is still read from its own column.
    The collector writes `fields=NULL, fields_id=<id>`; the text round-trips byte for byte (tests include empty text,
    CR/LF, padding, case variants, Unicode and a 5000-character header).
  - `VerifyServeRollups` and the storage maintenance verification require the schema-10 objects (and a `fields_id` that
    points at an existing dictionary row); schema-8 and schema-9 sources are still verified against their own exact
    shape. The verifier groups the exact identities with one sequential table scan and a sorter (`NOT INDEXED`), since the
    narrowed index no longer carries the Message-ID. The copy fingerprint compares the logical `#Fields` text, not its
    storage form; the maintenance receipt lists the added table/column as an exclusion and reports `fieldsDictionary`.
- The collection apply thread no longer runs the rollup/hash triggers on its own write connection
  (`SQLITE_DBCONFIG_ENABLE_TRIGGER`, switched off before its statements are prepared and switched on again in a `finally`,
  also after a failure or a cancellation). With a trigger whose body or WHEN calls a function, SQLite opens a statement
  journal for every INSERT inside the batch transaction. The effects of `tr_message_event_rollup_insert` and
  `tr_smtp_transaction_rollup_insert` are written by the code instead, for every row that was really inserted: the
  `message_rollup_dirty` upsert `('message', Message-ID, hash)` and, for an SMTP row without Message-ID,
  `('smtp', rowid, NULL)`, flushed in the same transaction before the reconciliation. The hash is still bound by the code
  and the exact BINARY Message-ID compare is unchanged.
  - Triggers stay defined and active for every other connection (Serve, verifiers, external writers) and outside the
    apply window; `Store.Purge` enables them again before deleting. Trigger-based protections or audit triggers that
    an administrator added to this database are not run by the collector's own apply thread.
  - Writes audited while the triggers are off: INSERT OR IGNORE into `message_event` / `smtp_transaction` (reproduced),
    `UPDATE smtp_transaction SET auth_user, auth_mechanism, auth_result, auth_attempt_result, auth_source,
    auth_evidence_id` (none of these columns is in the schema-9 `UPDATE OF` lists of the rollup or hash triggers),
    and no DELETE (retention runs in `Purge`, with triggers on).
  - `CollectorOptions.DisableTriggersDuringApply` (default `true`) keeps the old path available; `RollupQueueTrace`
    records the queue just before each reconciliation for the equivalence test.
- SMTP clients: the `exl_remote_host` SQL function is memoized per request connection (bounded, thread-safe); the
  response bytes are unchanged.
- Test expectations changed by the schema bump: schema 9 became 10 in the Serve/rollup/storage tests; the "newer
  schema" fixtures use 11; the failure injections that are SQL triggers on `message_rollup`, `smtp_auth_fragment`,
  `smtp_transaction` or `source_file` run with `DisableTriggersDuringApply = $false`, and a trigger-free injection
  (exhausted rollup sequence) covers the default path.
- Observed on scratch copies of synthetic data only (no 24 GB benchmark; the machine was noisy, results are not a promise):
  - Size, storage copy with `--vacuum`, schema 9 versus `--migrate --vacuum`: 299,500-event copy 649,314,304 to
    622,018,560 bytes (`source_file` 15,663,104 to 4,669,440; the two identity indexes 21,495,808 + 3,031,040 to
    7,176,192 + 1,032,192); 29,955-event copy 88,260,608 to 75,694,080 bytes.
  - Apply thread, 315,714 tracking events: rows 19.2 s with the triggers on versus 3.6 s with them off on a quiet run
    (wall 29.2 s versus 9.5 s); repeated runs on a loaded machine varied widely (rows 17.0 to 36.7 s with the triggers off,
    37.3 to 38.8 s on). With one batch, one parse thread and ids included, message_rollup and both source tables hashed
    identically for the previous engine, the trigger path and the code path (two passes each).
  - `message_rollup` rows of kind `smtp` are identified by the rowid of the transaction, which depends on the order in
    which parsed files reach the apply thread; two runs of the same logs with several parse threads therefore differ in
    those identities with or without triggers. VerifyServeRollups passes in every case.
  - SMTP clients endpoint, 100 rows: median 1275 and 1343 ms without the memo, 1156 and 1260 ms with it, same body hash.
### Schema 11, pre-aggregated SMTP clients, message_rollup dictionary codes (unreleased)

- Schema 11 replaces schema 10 for Serve and the storage tools. Databases of schema 6 to 10 are upgraded only by a writable
  collector/Store open or by `Database-Storage.cmd --storage-copy --migrate` on a new copy; Serve never migrates. A fresh
  database and a migrated one end with the same `sqlite_master` (the tests compare it from every earlier schema).
- **SMTP clients.** The list, the export, the detail and the transactions of an SMTP client no longer group every transaction of the period at
  each request. New tables `smtp_client_value` (dictionary of the text values), `smtp_client` (one row per client: server NOCASE, direction,
  role, connector, peer, HELO, account), `smtp_client_hour` (additive counters per client x UTC hour x status/TLS/mechanism/result/attempt/source)
  and the queues `smtp_client_pending` / `smtp_client_dirty`; new column `smtp_transaction.client_id` (NULL when no endpoint was observed: such a
  transaction stays a group of its own); new indexes `ux_smtp_client`, `ix_smtp_client(client_id,time_ms)`, `ix_smtp_unknown_peer` (partial) and
  `ix_smtp_client_hour(hour_ms,client_id)`; three triggers (`tr_smtp_transaction_client_insert/update/delete`) for every writer that is not the
  collector's apply thread, the retention and a collection that keeps the triggers on.
  - Serve reads whole hours from the buckets and only the partial hours at both ends (and the transactions without client) from the rows. A page is
    found newest hour first (stopping as soon as a whole hour has produced enough clients, which is exact because every older client ranks after
    them) and only those clients are aggregated; a user filter (substring LIKE) reads the matching rows newest first and completes the candidates
    through `ix_smtp_client`; the export aggregates the buckets in SQL. A period of sparse data jumps over empty hours.
  - The answers are unchanged: same ids (`MIN(id)` of the group in the selection), same cells and types, same errors (404 for an unknown or
    out-of-selection client), sets sorted in ordinal order, same order. `tests\Serve.SmtpClients.Tests.ps1` compares the HTTP answers with the
    schema-10 query (kept as a test-only reference, `SmtpClientReference.cs`, run on a schema-10 copy of the same data) on a randomized edge-case
    fixture (empty/NULL/IPv6/odd endpoints, case, NULL and empty HELO/role/connector, every evidence source including the retired Overflow, hour
    boundaries, many rows in one millisecond, LIKE wildcards, pages and sizes), 3 seeds x 600 cases, after the reconciliation of an external writer
    and after the 10 to 11 migration.
  - The collector maintains the structures itself in the batch transaction (`Engine.SmtpClients.cs`, `SmtpClientMaintenance`): the client of a
    transaction is computed before the INSERT, the account resolved by the authentication resolver moves the transaction to the client of its
    account (re-keyed in memory when the batch inserted it, otherwise both buckets are recomputed from the rows), a client left without transaction
    is deleted, and a rolled back batch forgets what it created. Memory is bounded whatever the batch size (small key cache, early write of the
    pending buckets, streamed recomputation). With `DisableTriggersDuringApply = false` the triggers queue the work and the batch commit drains it.
  - `ReconcileMessageRollups` (and `RefreshServeRollups`, and `Purge`) also drain the SMTP client queues. While a queue is not empty Serve answers
    **503 `SmtpClientsPending`** (`RollupPending` when the rollup queue is not empty either) instead of an out-of-date list.
  - `VerifyServeRollups` also proves the structures (`SmtpClientsVerified`, `SmtpClientRows`, `SmtpClientHourRows`; `Store.VerifySmtpClients()` alone):
    every `client_id` equals the key recomputed from its row (NULL if and only if there is no observed endpoint), no duplicate or orphan client, no
    dangling reference, and `smtp_client_hour` equals the grouping of the rows in both directions; the canonical tables, indexes and triggers are part of
    the exact schema check. `ExplainSmtpClients` lists the plan of each statement of the list.
  - `Identity.RemoteHost` (was `ServeRead.RemoteHost`) is shared by the collector, the migration, Serve and the verifier; the `exl_remote_host` SQL
    function is registered on every Store connection.
  - Known limit: `INSERT OR REPLACE` by an external writer deletes the replaced row without running the DELETE trigger (SQLite runs it only with
    `recursive_triggers`); the verification reports the difference. The collector and the retention never use it.
- **message_rollup (dictionary codes, B1/B3/B4).** `message_rollup_value(id,text UNIQUE)` holds the repeated texts; `kind` is 0 (message) or 1 (smtp)
  and `status`, `direction`, `servers`, `events` are integer codes (NULL stays NULL for the three nullable ones). `first_ms`/`last_ms` are NULL when
  equal to `member_first_ms`/`member_last_ms` (readers use COALESCE). `ix_smtp_latest` is dropped (`ix_smtp_flow` starts with `time_ms`) and listed
  among the obsolete indexes; `ix_rollup_status_last` is `(status,member_last_ms)` without collation.
  - The integrity constraint **`UNIQUE(kind,identity)` and the upsert that relies on it are kept** (the replacement of that constraint by code was
    measured but is not part of this schema); `kind` additionally has `CHECK(kind IN(0,1))`. The upsert no longer rewrites `msg_hash`.
  - The status filter is resolved to codes first, with the same case-insensitive text comparison: no code gives an empty page, one code an equality
    on the ordered index, several codes (texts that differ only by case) an `IN` list. `OverviewCounts` decodes the groups and sorts them in ordinal
    order. Dictionary codes are never reused and are stable only within a database: compare two histories through the decoded content.
- **Message counts and lists.** Without a server or user filter the membership test is wrapped in
  `CASE WHEN member_first_ms>=@from AND member_last_ms<@to THEN 1 ELSE <exact test> END`: `member_first_ms` is the time of an existing event or SMTP
  row and never exceeds `member_last_ms`, so a journey entirely inside the period has a member in it. The result is identical (tests compare the counts
  and the first page with the plain predicate on 120+ random periods); the exact source lookups are only done for the journeys that cross a bound.
  The counts statement fixes its access path: the range of `ix_rollup_last` when at most 10 percent of the table ends at or after the period start,
  otherwise one sequential read of the table (`NOT INDEXED`); left alone the planner walked the whole status index.
- **Migration 10 to 11** (`MigrateSchema11`): one transaction, any failure rolls back everything (tests inject a failure at the version write and at the
  client assignment). The rollup keeps its ids and its AUTOINCREMENT sequence (read before the old table is dropped, re-applied as `MAX(seq, old)`), the
  old rows are compared with the new ones, decoded, before the old table is dropped, the client structures are derived with one scan and proved by the
  verification recomputation, and `ix_smtp_latest` is dropped. Databases of schema 6 and 7 go straight to schema 11 in their own transaction.
  `Database-Storage.cmd --storage-copy --migrate` accepts schemas 6 to 11 and verifies the copy: an existing `message_rollup` (schema 8 to 10) is compared
  through its decoded logical rows, the added tables and `client_id` are explicit exclusions, and the exact schema-11 objects and the client structures are
  verified. The migration rewrites `message_rollup` and `smtp_transaction.client_id`: it needs free disk space for the write-ahead log (about 6 GB for the
  prototype database of 20 GB) and keeps the database unavailable while it runs (estimated 3 to 5 minutes at that size from prototypes; not yet run by
  this implementation on such a database).
- Test expectations changed by the schema bump: schema 10 became 11 in the Serve/rollup/storage tests, the "newer schema" fixtures use 12, the
  fixtures that built a schema-10 shape (`ConvertToLegacySyntheticFixture`, `Storage.Fixtures.ps1`) first remove the SMTP client structures and decode
  the rollup, comparisons of `message_rollup` use the decoded content (`ServeFixtures.DecodedRollup`), tests that cited `ix_smtp_latest` use another
  index, the plans of the SMTP clients are asserted per statement, and the failure injected on the schema version is on `'11'`.
- Observed on synthetic data only. The prototype figures that motivated the schema (copy of a 20 GB database, list of 7 days about 8 to 21 s before and 13 to
  65 ms after, +199 MB for the client structures, about -530 MB for the rollup codes, the NULL bounds and the dropped index; the further -225 MB of the prototype that replaced UNIQUE(kind,identity) is not taken) were measured outside this repository and are not re-measured here; no full
  collection of that database was run with the final code (the expected +50 s for the client maintenance on 1.9 million SMTP transactions is unconfirmed).

### Collection pipeline (unreleased)

- Unchanged structure: `Collection.Parallelism` parse threads (0 = one per processor, 2 to 16; explicit 1 to 64) read one file each and feed one
  apply thread, the single writer of the database; `Collection.MaxFilesPerServer` (default 4) still spreads the reads over the servers.
- Queue between the parse threads and the apply thread: FIFO, bounded by the bytes read of the queued files (384 MiB, `QueueBytes`; at least 2 files
  whatever their size) and by a file count (`QueueMaxFiles` 256, or twice the parse threads when larger). A parse thread waits for room instead of
  holding more parsed records in memory. Engine constants, not configuration keys.
- `LogReader.Lines` (`Engine.Text.cs`) reads the next 512 KiB of a file ahead on the thread pool while the current buffer is split; a small file that a
  first read does not fill is never read ahead. Bytes and lines are the same as without the read ahead.
- Record lists of applied files (HttpProxy/IIS requests, tracking rows) are pooled and handed to the next files (bounded per kind and capacity, dropped
  at the end of every collection); the emptied batch of the last commit is reused by the next one.
- Commits unchanged: one transaction per batch of files, every `BatchSeconds` (30) or `BatchRows` (500,000 rows).
- WAL: a background thread copies the WAL into the database every `CheckpointSeconds` (10), and back to back while the WAL is above half of
  `WalRestartBytes`; above `WalRestartBytes` (4 GiB; 0 = no bound) the apply thread copies and truncates it between two transactions. With nothing
  queued and a WAL above half the bound, the apply thread commits before it waits.
- Page cache of the apply connection during a collection: `CacheKilobytes` 1 GiB (1048576; 0 = keep the store cache), set back to the store's 256 MiB at
  the end. Reports keep the 256 MiB cache.
- GC latency mode `SustainedLowLatency` while the apply thread runs (background full collections only), restored at the end, also after a failure.
- `CollectorOptions` fields above (`BatchSeconds`, `BatchRows`, `CheckpointSeconds`, `WalRestartBytes`, `CacheKilobytes`, `DisableTriggersDuringApply`,
  `DeferRollupsAboveBytes`) are engine options, not keys of the configuration file.
- New configuration key `Collection.DeferRollups` (`Never` default, `Auto`, `Always`): `Never` reconciles the message rollups with every commit;
  `Always` reconciles them once after the last batch, in chunks of 100,000 keys; `Auto` does so only for an initial import into an empty `message_rollup`
  of more than `DeferRollupsAboveBytes` (5 GiB) planned. Deferred rollups of a stopped run leave Serve answering 503 until the next collection, `Purge`
  or `RefreshServeRollups` drains them; except with `Always`, a leftover queue of more than 100,000 keys is drained before the first batch.
- Statistics line extended: parse threads waiting for a file to read and for room in the queue, rows split into SMTP and message tracking, SMTP clients,
  SMTP authentication flushes, compression (apply and parse threads), message rollup mode and keys, `rollup reads` / `rollup writes`, WAL copies at
  short intervals, WAL restarts and their wait, max WAL, gen1+/gen2 collections, `file reads` (main / filler streams) and
  `parse threads waiting for the reads` (main / filler).

### Server garbage collector for Run-Collector.cmd (unreleased)

- `Run-Collector.cmd` starts the bundled PowerShell with the server garbage collector, 4 heaps not tied to processors (`DOTNET_gcServer=1`,
  `DOTNET_GCHeapCount=4`, `DOTNET_GCNoAffinitize=1`). The setting is per process, so it applies to every mode of this launcher; the portal launcher and
  a scheduled task that starts `pwsh.exe -File Invoke-ExchangeLogReport.ps1` directly keep the workstation collector unless they set the same variables.
- Measured once on one Azure VM, synthetic 14 days (132.5 GB, 12829 files), with `Collection.Parallelism = 1` and `MaxFilesPerServer = 1` (imposed by the
  comparison harness; not the production default). Results are not committed to this repository.
  - Comparison harness, workstation garbage collector: legacy collection 1815.5 s, Angular collection 1720.9 s. Usage/Detailed outputs identical for
    7 of 8 and 10 of 12 files (`ExchangeLogs.html` and `ExchangeLogs-ClientSessions.csv` differ); Serve startup about 0.5 to 0.9 s.
  - Separate Angular-only collection runs of the same logs: workstation 1749.3 s (pauses 161.3 s, peak working set 3808 MB); server garbage collector,
    4 heaps 1440.0 s (-17.7%; pauses 38.5 s, peak 4178 MB); the same plus `GCNoAffinitize` (the launcher setting) 1440.6 s (pauses 30.0 s, peak 4103 MB).
    Same files, lines and kept rows in every run. The two workstation baselines (1720.9 s and 1749.3 s) are different runs.
  - The reports were not measured with the server garbage collector.

### Local CI/provenance proposals

- Add a least-privilege Windows CI workflow for the exact intended private
  repository, using only previously reviewed full action SHAs.
- Require matching `package.json`/committed-lockfile intent, compatible installed
  Node engines, `npm ci --no-fund`, a non-bypassed high/critical npm audit,
  Angular build and one-shot unit tests.
- Compile the host with linked collector Engine C# sources, run existing
  collector tests and new Serve/package-integrity/workflow tests with Pester
  `6.1.0` under the configured portable PowerShell from the freshly built and
  integrity-verified package, rather than assuming the runner's PowerShell/.NET
  proves the shipped runtime.
- Add manual, default-branch-only advisory CodeQL for C#, Angular
  JavaScript/TypeScript and workflows. Private-plan availability is unverified;
  no new required check is configured.
- Propose attestation of actual published release ZIP bytes, after complete
  inventory/hash verification of the compiled Angular bundle inside each ZIP.
  Missing ZIPs fail; no source archive or arbitrary build artifact is substituted.
- Document dependency hashes, unsigned-local limits, private CodeQL/attestation
  capability checks, and outstanding owner/publication/backup gates in
  `PROVENANCE.md`.

### Remaining gates

Complete implementation and the applicable local regression/performance/package
checks before accepting this pilot. Hosted CI, dependency audit, CodeQL,
repository-specific action authorization, signing (if configured), exact owner
consent, publication security/documentation checks, release asset verification,
distributed-ZIP attestation and versioned/off-machine backups remain separate
pending work. No Git/GitHub write, commit, tag, release or original-database
mutation is performed by this CI/provenance preparation.
