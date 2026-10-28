#nullable enable
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using ExchangeLogReport;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReportAngular;

internal sealed class StorageMaintenance(PortalOptions options)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    private sealed record Phase(string Stage, double DurationMs);
    private sealed record VacuumCapacity(string TempStore, string DestinationVolume, string TemporaryVolume,
        bool SharedVolumeBudget, long StagedBytes, long DestinationRequiredFreeBytes,
        long DestinationAvailableFreeBytes, long TemporaryRequiredFreeBytes, long TemporaryAvailableFreeBytes);

    public async Task<StorageAudit> AuditAsync()
    {
        try
        {
            using var source = new StorageSource(options.Database);
            StorageAudit result = await StorageAuditTool.RunAsync(options.Database, options.SqliteTool);
            source.VerifyUnchanged();
            return result;
        }
        catch (StorageFailure error) { throw new ApiError(422, error.Message); }
        catch (IOException) { throw new ApiError(409, "Source is unavailable or held by a writer. Close writers and retry the read-only audit."); }
    }

    public static async Task<int> RunCliAsync(PortalOptions options)
    {
        try
        {
            var storage = new StorageMaintenance(options);
            object report;
            if (options.StorageMode == StorageMode.Audit)
            {
                if (options.Output is not null) StorageSafety.NewFile(options.Output, options.Database);
                report = await storage.AuditAsync();
                if (options.Output is not null) await WriteNewReport(options.Output, report);
            }
            else report = await storage.CopyAsync();
            Console.WriteLine(JsonSerializer.Serialize(report, JsonOptions));
            return 0;
        }
        catch (Exception error)
        {
            string message = error is StorageFailure or ApiError ? error.Message : PortalDiagnostics.Describe(error);
            Console.Error.WriteLine("Storage operation failed: " + message);
            Console.WriteLine(JsonSerializer.Serialize(new { success = false, operation = options.StorageMode.ToString().ToLowerInvariant(), error = message }, JsonOptions));
            return 2;
        }
    }

    private async Task<object> CopyAsync()
    {
        string destination = options.Destination!;
        string output = options.Output!;
        StorageSafety.NewFile(destination, options.Database);
        StorageSafety.NewFile(output, options.Database, destination);
        using var source = new StorageSource(options.Database);
        using var sourceDb = StorageSafety.Open(options.Database, false);
        string? schema = StorageSafety.Metadata(sourceDb, "schema_version");
        if (Store.SchemaVersion != "11" || schema is not ("6" or "7" or "8" or "9" or "10" or "11") ||
            !int.TryParse(schema, NumberStyles.None, CultureInfo.InvariantCulture, out int sourceVersion) ||
            sourceVersion is < 6 or > 11)
            throw new StorageFailure("This copy maintenance profile supports delivered schemas 6 through 11 only; future or unknown schemas are rejected before destination writes.");
        // upgrade: any schema change of the copy (6/7/8/9/10 -> 11). rollupUpgrade: the derived tables are new (6/7 -> 11); a schema-8, -9 or -10 source already
        // owns them and only gets other indexes and triggers. fieldsUpgrade (< 10): the source_fields dictionary is new, the logical '#Fields' text of source_file
        // is compared, not its storage form. clientsUpgrade (< 11): the SMTP client structures, the rollup dictionary and smtp_transaction.client_id are new, and
        // an existing message_rollup (8 to 10) is compared through its decoded logical rows (codes, COALESCE of the member bounds) with ids and sequence unchanged.
        bool upgrade = options.Migrate && sourceVersion < 11;
        bool rollupUpgrade = options.Migrate && sourceVersion < 8;
        bool fieldsUpgrade = options.Migrate && sourceVersion < 10;
        bool hashUpgrade = upgrade && sourceVersion == 6;
        string[] excludedMetadata = hashUpgrade ? ["schema_version", "message_hash_algorithm"] :
            upgrade ? ["schema_version"] : [];
        var sourceComparison = new LogicalComparison(hashUpgrade, excludedMetadata, [], rollupUpgrade);
        var targetComparison = sourceComparison with {
            AddedTables = (rollupUpgrade ? StorageRollupVerification.Tables : []).Concat(fieldsUpgrade ? [StorageRollupVerification.SourceFieldsTable] : [])
                .Concat(upgrade ? [StorageRollupVerification.RollupValueTable, .. StorageRollupVerification.SmtpClientTables] : []).ToArray(),
            FieldsDictionary = fieldsUpgrade, ClientId = upgrade, RollupCodes = upgrade && sourceVersion >= 8
        };
        if (options.Repack && !options.Migrate && schema != Store.SchemaVersion)
            throw new StorageFailure("--repack requires the current schema or explicit --migrate on the new copy.");
        string? toolVersion = StorageSafety.Metadata(sourceDb, "tool_version");
        if ((options.Migrate || options.Repack) && toolVersion is null)
            throw new StorageFailure("Source tool_version metadata is missing; refusing to introduce or overwrite unrelated metadata.");
        long required = checked(Math.Max(source.Bytes, 1048576) * 3 + 16 * 1048576);
        var drive = new DriveInfo(Path.GetPathRoot(destination)!);
        if (drive.AvailableFreeSpace < required)
            throw new StorageFailure("Insufficient destination free space. This operation conservatively requires at least three times source plus WAL bytes, with an additional safety margin. No copy was started.");
        var phases = new List<Phase>();
        var clock = Stopwatch.StartNew();
        void Phase(string stage) { phases.Add(new(stage, clock.Elapsed.TotalMilliseconds)); clock.Restart(); }
        StorageSafety.Integrity(sourceDb, false);
        Phase("sourceQuickCheck");
        StorageAudit beforeAudit = await StorageAuditTool.RunAsync(options.Database, options.SqliteTool);
        Phase("sourceAudit");
        var measurements = new List<object> { new { stage = "source", audit = beforeAudit } };
        List<LogicalTable> baseline = StorageFingerprint.Inventory(sourceDb);
        string[] addedBookkeepingTables = rollupUpgrade && !baseline.Any(table => table.Name == "sqlite_sequence")
            ? ["sqlite_sequence"] : [];
        targetComparison = targetComparison with {
            AddedTables = targetComparison.AddedTables.Concat(addedBookkeepingTables).ToArray()
        };
        StorageRollupVerification.CheckSource(sourceDb, sourceVersion);
        List<LogicalDigest> before = StorageFingerprint.Compute(sourceDb, baseline, sourceComparison);
        Phase("sourceFingerprint");
        var owned = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        string stage = Path.Combine(Path.GetDirectoryName(destination)!, "." + Path.GetFileName(destination) + "." + Guid.NewGuid().ToString("N") + ".stage.sqlite");
        string? vacuum = null;
        VacuumCapacity? vacuumCapacity = null;
        bool published = false;
        try
        {
            Reserve(stage, owned);
            using (var target = StorageSafety.Open(stage, true)) sourceDb.BackupDatabase(target);
            Phase("sqliteBackup");
            long repacked = 0;
            if (options.Migrate)
            {
                if (upgrade) { using (new Store(stage, false, toolVersion)) { } }
                Phase("migration");
                measurements.Add(new { stage = "afterMigration", audit = await StorageAuditTool.RunAsync(stage, options.SqliteTool) });
                Phase("migrationAudit");
            }
            if (options.Repack)
            {
                using (var store = new Store(stage, false, toolVersion)) repacked = store.RepackSafeText();
                Phase("repack");
                measurements.Add(new { stage = "afterRepack", audit = await StorageAuditTool.RunAsync(stage, options.SqliteTool) });
                Phase("repackAudit");
            }
            using (var target = StorageSafety.Open(stage, true))
            {
                using var checkpoint = target.CreateCommand();
                checkpoint.CommandTimeout = 0;
                checkpoint.CommandText = "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE; PRAGMA temp_store=FILE;";
                checkpoint.ExecuteNonQuery();
                if (options.Vacuum)
                {
                    long stageBytes = new FileInfo(stage).Length + (File.Exists(stage + "-wal") ? new FileInfo(stage + "-wal").Length : 0);
                    long vacuumRequired = checked(stageBytes * 2 + 16 * 1048576);
                    string temporaryDirectory = Path.GetTempPath();
                    StorageSafety.PlainPath(temporaryDirectory);
                    var temporaryDrive = new DriveInfo(Path.GetPathRoot(temporaryDirectory)!);
                    long destinationAvailable = drive.AvailableFreeSpace;
                    long temporaryAvailable = temporaryDrive.AvailableFreeSpace;
                    bool shared = StorageSafety.Same(drive.RootDirectory.FullName, temporaryDrive.RootDirectory.FullName);
                    vacuumCapacity = new("FILE", drive.RootDirectory.FullName, temporaryDrive.RootDirectory.FullName,
                        shared, stageBytes, vacuumRequired, destinationAvailable, vacuumRequired, temporaryAvailable);
                    if (destinationAvailable < vacuumRequired)
                        throw new StorageFailure("Insufficient remaining destination space for the full staged VACUUM. Free at least twice the staged database size plus the safety margin; no destination was published.");
                    if (!shared && temporaryAvailable < vacuumRequired)
                        throw new StorageFailure("Insufficient system temporary-drive space for FILE-backed VACUUM sorting. Free at least twice the staged database size plus the safety margin on the existing temp drive; no TEMP or global SQLite directory was changed.");
                    vacuum = Path.Combine(Path.GetDirectoryName(destination)!, "." + Path.GetFileName(destination) + "." + Guid.NewGuid().ToString("N") + ".vacuum.sqlite");
                    Reserve(vacuum, owned);
                    using var command = target.CreateCommand();
                    command.CommandTimeout = 0;
                    command.CommandText = "VACUUM INTO @file;";
                    command.Parameters.AddWithValue("@file", vacuum);
                    command.ExecuteNonQuery();
                }
            }
            Phase(options.Vacuum ? "vacuumIntoSibling" : "checkpointWithoutVacuum");
            string finalStage = vacuum ?? stage;
            using (var stagedGuard = new StorageSource(finalStage, allowVerifiedRename: true))
            using (var staged = StorageSafety.Open(finalStage, false))
            {
                StorageSafety.Integrity(staged, true);
                Phase("stagedIntegrityCheck");
                var after = StorageFingerprint.Compute(staged, baseline, targetComparison);
                StorageFingerprint.Compare(before, after, sourceComparison);
                if (upgrade && StorageSafety.Metadata(staged, "schema_version") != "11")
                    throw new StorageFailure("Schema migration did not produce schema 11; no destination was published.");
                bool verifyRollups = sourceVersion >= 8 || upgrade;
                int targetVersion = upgrade ? 11 : sourceVersion;
                if (verifyRollups) StorageRollupVerification.Verify(staged, targetVersion);
                if (rollupUpgrade) StorageRollupVerification.VerifyAddedSequence(staged, addedBookkeepingTables.Length != 0);
                if (options.Migrate)
                {
                    if (StorageSafety.Metadata(staged, "message_hash_algorithm") != "fnv1a64-utf8-v1")
                        throw new StorageFailure("Hash algorithm metadata verification failed; no destination was published.");
                    staged.CreateFunction<string, long?>("exl_msg_hash", Store.MessageHash, isDeterministic: true);
                    foreach (string table in new[] { "message_event", "smtp_transaction" })
                    {
                        using var check = staged.CreateCommand();
                        check.CommandText = "SELECT count(*) FROM " + table + " WHERE msg_hash IS NOT exl_msg_hash(message_id);";
                        if (Convert.ToInt64(check.ExecuteScalar(), CultureInfo.InvariantCulture) != 0)
                            throw new StorageFailure("Hash backfill verification failed; no destination was published.");
                    }
                }
                Phase("logicalVerification");
                StorageAudit afterAudit = await StorageAuditTool.RunAsync(finalStage, options.SqliteTool);
                if (afterAudit.WalBytes != 0) throw new StorageFailure("Staged WAL is not empty; refusing to publish an incomplete standalone database.");
                Phase("stagedAudit");
                var sourceAfter = StorageFingerprint.Compute(sourceDb, baseline, sourceComparison);
                StorageFingerprint.Compare(before, sourceAfter, sourceComparison);
                source.VerifyUnchanged();
                stagedGuard.VerifyUnchanged();
                Phase("sourceUnchangedVerification");
                if (vacuum is not null)
                {
                    foreach (string suffix in new[] { "", "-wal", "-shm", "-journal" })
                    {
                        string oldStage = stage + suffix;
                        if (StorageSafety.Exists(oldStage)) File.Delete(oldStage);
                        owned.Remove(oldStage);
                    }
                }
                var report = new {
                    success = true, version = PortalService.Version, operation = "copy",
                    actions = new { migrate = options.Migrate, repack = options.Repack, vacuum = options.Vacuum },
                    sourceUnchanged = true, repackedCells = repacked, requiredFreeBytes = required, vacuumCapacity,
                    verification = new {
                        algorithm = "SHA-256 typed length-prefixed normalized logical rows v1",
                        exclusions = (hashUpgrade ? new[] { "added msg_hash only" } : Array.Empty<string>())
                            .Concat(excludedMetadata.Select(key => "metadata." + key))
                            .Concat(rollupUpgrade ? new[] { "added sqlite_sequence row for message_rollup only (validated against MAX(id))" } : Array.Empty<string>())
                            .Concat(fieldsUpgrade ? new[] { "added source_fields table and source_file.fields_id column only (source_file.fields is compared as its logical dictionary text)" } : Array.Empty<string>())
                            .Concat(upgrade ? new[] { "added message_rollup_value, smtp_client_value, smtp_client, smtp_client_hour, smtp_client_pending and smtp_client_dirty tables and smtp_transaction.client_id column only",
                                "ix_smtp_latest dropped (not data); an existing message_rollup is compared through its decoded rows (kind, status, direction, servers and events dictionary codes decoded, first_ms/last_ms through COALESCE of the member bounds)" } : Array.Empty<string>()).ToArray(),
                        fieldsDictionary = new {
                            applicable = fieldsUpgrade, table = StorageRollupVerification.SourceFieldsTable, column = "fields_id",
                            contract = fieldsUpgrade ? "The '#Fields' text of every source_file row is compared byte for byte through the dictionary (COALESCE(source_fields.text, fields)); no row of any other table changes." : "No dictionary change."
                        },
                        smtpClients = new {
                            applicable = upgrade, tables = StorageRollupVerification.SmtpClientTables, column = "client_id",
                            contract = upgrade ? "client_id, the client dimension, the value dictionary and the hourly aggregates are derived from the copied SMTP transactions and verified equal to a full recomputation; no source row changes." : "No SMTP client change."
                        },
                        derivedRollups = new {
                            applicable = verifyRollups, schemaVersion = verifyRollups ? targetVersion.ToString(CultureInfo.InvariantCulture) : null,
                            tables = verifyRollups ? StorageRollupVerification.Tables : [],
                            newlyAddedTables = rollupUpgrade ? StorageRollupVerification.Tables : [],
                            newlyAddedBookkeepingTables = addedBookkeepingTables, validated = verifyRollups,
                            dirtyQueueEmpty = verifyRollups, baselineTablesPreserved = sourceVersion >= 8,
                            contract = "Exact schema-" + targetVersion.ToString(CultureInfo.InvariantCulture) + " derived objects, empty dirty queue and exact raw-message-ID rollup consistency; read-only verification. Every pre-existing derived table remains in the baseline logical fingerprint."
                        },
                        sourceMainSha256 = source.MainSha256, sourceWalSha256 = source.WalSha256,
                        destinationSha256 = stagedGuard.MainSha256, before, after,
                        note = "Cryptographic verification is strong evidence, not mathematical proof. All baseline columns, explicit keys and offsets are compared with strict SQLite types. Packed normalization is limited to approved transcript, step and display-text slots; other BLOBs stay typed bytes. Hidden rowid is ordering only; a changed normalized order fails closed."
                    },
                    before = beforeAudit, after = afterAudit, measurements, phases
                };
                // Both publications are no-overwrite moves. A race on the evidence path
                // after copy publication remains an explicit failure, never a success.
                string reportStage = output + "." + Guid.NewGuid().ToString("N") + ".building";
                Reserve(reportStage, owned);
                await SerializeFile(reportStage, report);
                staged.Dispose();
                StorageSafety.NewFile(destination, options.Database);
                StorageSafety.NewFile(output, options.Database, destination);
                File.Move(finalStage, destination);
                owned.Remove(finalStage);
                published = true;
                File.Move(reportStage, output);
                owned.Remove(reportStage);
                return report;
            }
        }
        catch (Exception error)
        {
            string reason = error is StorageFailure ? error.Message : PortalDiagnostics.Describe(error);
            if (published) reason += " A verified private copy was retained at the requested destination, but its report could not be committed; treat this run as failed.";
            throw new StorageFailure(reason);
        }
        finally
        {
            var failures = new List<string>();
            foreach (string file in owned.Reverse())
            {
                try { if (StorageSafety.Exists(file)) File.Delete(file); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { failures.Add(Path.GetFileName(file)); }
            }
            if (failures.Count > 0)
                throw new StorageFailure("Private maintenance partials could not be removed. Inspect the selected destination/output folders; this run failed cleanup even if a verified copy/report was already published.");
        }
    }

    private static void Reserve(string path, HashSet<string> owned)
    {
        foreach (string suffix in new[] { "", "-wal", "-shm", "-journal" })
            if (StorageSafety.Exists(path + suffix)) throw new StorageFailure("A generated private staging path already exists; no existing file was replaced.");
        using (new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
        owned.Add(path);
        foreach (string suffix in new[] { "-wal", "-shm", "-journal" }) owned.Add(path + suffix);
    }
    private static async Task SerializeFile(string path, object value)
    {
        await using var stream = new FileStream(path, FileMode.Truncate, FileAccess.Write, FileShare.None);
        await JsonSerializer.SerializeAsync(stream, value, JsonOptions);
        await stream.FlushAsync();
        stream.Flush(flushToDisk: true);
    }
    private static async Task WriteNewReport(string output, object value)
    {
        string partial = output + "." + Guid.NewGuid().ToString("N") + ".building";
        bool created = false;
        try
        {
            using (new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
            created = true;
            await SerializeFile(partial, value);
            File.Move(partial, output);
            created = false;
        }
        finally { if (created) File.Delete(partial); }
    }
}
