#nullable enable
using System.Collections.Concurrent;
using System.Globalization;
using System.Text.RegularExpressions;
using ExchangeLogReport;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReportAngular;

internal sealed class ApiError(int status, string message) : Exception(message)
{
    public int Status { get; } = status;
}

internal sealed record BuildInput(string? Start, string? End, string? ReportType, string? User, string? Server, string? TimeZone);
internal sealed record ValidatedBuild(DateTimeOffset Start, DateTimeOffset End, bool Detailed,
    string? User, string? Server, TimeZoneInfo Zone, string ZoneName);
internal sealed record JobView(string Id, string State, string Stage, string? Error, string? ReportId);

internal sealed class PortalJob(string id)
{
    private JobView current = new(id, "Running", "Queued", null, null);
    public JobView View => Volatile.Read(ref current);
    public void Stage(string stage) => Volatile.Write(ref current, View with { Stage = stage });
    public void Complete() => Volatile.Write(ref current, new(id, "Completed", "Completed", null, id));
    public void Fail(string error) => Volatile.Write(ref current, new(id, "Failed", "Failed", error, null));
}

internal sealed class PortalService(PortalOptions options, ILogger<PortalService> log)
{
    public const string SourceVersion = "2.0.1";
    public const string Version = "0.3.0";
    private readonly ConcurrentDictionary<string, Snapshot> reports = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, PortalJob> jobs = new(StringComparer.Ordinal);
    private readonly object buildGate = new();
    private int building;
    private bool accepting = true;
    private Task? activeBuild;

    public void Initialize()
    {
        Directory.CreateDirectory(options.Reports);
        foreach (string folder in Directory.EnumerateDirectories(options.Reports))
        {
            string id = Path.GetFileName(folder);
            if (!IsId(id) || Snapshot.IsReparse(folder)) continue;
            string path = Path.Combine(folder, Snapshot.FileName);
            if (!File.Exists(path) || Snapshot.IsReparse(path)) continue;
            try { reports[id] = Snapshot.Load(id, path); }
            catch (Exception e) when (e is SqliteException or InvalidDataException or System.Text.Json.JsonException)
            {
                log.LogWarning("Ignoring invalid portal snapshot {ReportId} ({ErrorType}).", id, e.GetType().Name);
            }
        }
    }

    public static bool IsId(string id) => id.Length == 32 && Guid.TryParseExact(id, "N", out _) &&
        string.Equals(id, id.ToLowerInvariant(), StringComparison.Ordinal);

    internal static SqliteConnection OpenReadOnly(string path)
    {
        var db = new SqliteConnection(new SqliteConnectionStringBuilder {
            DataSource = path, Mode = SqliteOpenMode.ReadOnly, Cache = SqliteCacheMode.Private, Pooling = false
        }.ToString());
        try
        {
            db.Open();
            using var command = db.CreateCommand();
            command.CommandText = "PRAGMA query_only=ON; PRAGMA busy_timeout=10000;";
            command.ExecuteNonQuery();
            return db;
        }
        catch { db.Dispose(); throw; }
    }

    private static string? Schema(SqliteConnection db)
    {
        using var command = db.CreateCommand();
        command.CommandText = "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='metadata';";
        if (Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) == 0) return null;
        command.CommandText = "SELECT value FROM metadata WHERE key='schema_version';";
        return command.ExecuteScalar() as string;
    }

    public object Status()
    {
        bool available = File.Exists(options.Database);
        string? schema = null;
        if (available)
        {
            using var db = OpenReadOnly(options.Database);
            schema = Schema(db);
        }
        bool requiresMigration = int.TryParse(schema, out int stored) && stored < int.Parse(Store.SchemaVersion, CultureInfo.InvariantCulture);
        return new { name = "ExchangeLogReportAngular", version = Version, databaseAvailable = available,
            databasePath = options.Database, schemaVersion = schema, reportCount = reports.Count,
            sourceVersion = SourceVersion, readOnly = true, supportedSchemaVersion = Store.SchemaVersion, requiresMigration };
    }

    public object[] Reports() => reports.Values.OrderByDescending(x => x.Generated, StringComparer.Ordinal)
        .Select(x => x.Summary()).ToArray();

    public Snapshot Report(string id) => IsId(id) && reports.TryGetValue(id, out var report)
        ? report : throw new ApiError(404, "Report not found.");

    public JobView Job(string id) => IsId(id) && jobs.TryGetValue(id, out var job)
        ? job.View : throw new ApiError(404, "Job not found.");

    public object Start(BuildInput input)
    {
        ValidatedBuild request = Validate(input);
        lock (buildGate)
        {
            if (!accepting) throw new ApiError(503, "The portal is stopping.");
            if (building != 0) throw new ApiError(409, "Another report is already running.");
            building = 1;
            string id = Guid.NewGuid().ToString("N");
            var job = new PortalJob(id);
            jobs[id] = job;
            activeBuild = Task.Run(() => Build(id, request, job));
            return new { id, state = "Running" };
        }
    }

    public void StopAccepting() { lock (buildGate) accepting = false; }

    public async Task DrainAsync()
    {
        Task? task;
        lock (buildGate) task = activeBuild;
        if (task is not null) await task;
    }

    private static ValidatedBuild Validate(BuildInput input)
    {
        static DateTimeOffset Date(string? text)
        {
            if (text is null || text.Length > 64 ||
                !Regex.IsMatch(text, @"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,7})?)?(?:Z|[+-]\d{2}:\d{2})$",
                    RegexOptions.CultureInvariant) ||
                !DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
                throw new ApiError(400, "Start and end must be ISO 8601 timestamps with explicit offsets.");
            return date;
        }
        DateTimeOffset start = Date(input.Start), end = Date(input.End);
        if (end <= start || end - start > TimeSpan.FromDays(366))
            throw new ApiError(400, "The period must be positive and no longer than 366 days.");
        if (input.ReportType is not ("Usage" or "Detailed"))
            throw new ApiError(400, "reportType must be Usage or Detailed.");
        if (input.User?.Length > 256 || input.Server?.Length > 256 ||
            input.User?.Any(char.IsControl) == true || input.Server?.Any(char.IsControl) == true)
            throw new ApiError(400, "User and server must contain at most 256 printable characters.");
        if (string.IsNullOrWhiteSpace(input.TimeZone) || input.TimeZone.Length > 128)
            throw new ApiError(400, "A valid timeZone is required.");
        TimeZoneInfo zone;
        try { zone = TimeZoneInfo.FindSystemTimeZoneById(input.TimeZone); }
        catch (Exception e) when (e is TimeZoneNotFoundException or InvalidTimeZoneException)
        { throw new ApiError(400, "The timeZone is not recognized on this computer."); }
        return new(start, end, input.ReportType == "Detailed", input.User?.Trim(), input.Server?.Trim(), zone, input.TimeZone);
    }

    private void Build(string id, ValidatedBuild input, PortalJob job)
    {
        string staging = Path.Combine(options.Reports, "." + id + ".building");
        string destination = Path.Combine(options.Reports, id);
        try
        {
            job.Stage("Checking read-only source schema");
            if (!File.Exists(options.Database)) throw new ApiError(422, "The configured database does not exist.");
            // On Windows this handle also forbids write/delete opens for the entire build.
            // Even a legacy migration attempted after preflight cannot write the source.
            using var sourceGuard = new FileStream(options.Database, FileMode.Open, FileAccess.Read, FileShare.Read);
            // The legacy Store constructor migrates older schemas even in read-only mode.
            // Never call it until an independent read-only connection has checked the version.
            using var preflight = OpenReadOnly(options.Database);
            string? schema = Schema(preflight);
            if (schema != Store.SchemaVersion)
                throw new ApiError(422, "Unsupported source schema " + (schema is null ? "(missing)" : "(not current)") +
                    "; this portal requires schema " + Store.SchemaVersion + " and never migrates the source.");
            string[] servers;
            using (var command = preflight.CreateCommand())
            {
                command.CommandText = @"SELECT server FROM source_file
UNION SELECT server FROM access_usage UNION SELECT server FROM access_event
UNION SELECT server FROM access_action UNION SELECT server FROM smtp_transaction
UNION SELECT server FROM message_event ORDER BY server;";
                using var reader = command.ExecuteReader();
                var list = new List<string>();
                while (reader.Read()) if (!reader.IsDBNull(0)) list.Add(reader.GetString(0));
                servers = list.ToArray();
            }
            if (!string.IsNullOrWhiteSpace(input.Server) && !servers.Contains(input.Server, StringComparer.OrdinalIgnoreCase))
                throw new ApiError(422, "The requested server is not present in the configured source database.");
            Directory.CreateDirectory(staging);
            var request = new ReportRequest {
                StartMs = input.Start.ToUnixTimeMilliseconds(), EndMs = input.End.ToUnixTimeMilliseconds(),
                DetailCutoffMs = DateTimeOffset.UtcNow.AddDays(-14).ToUnixTimeMilliseconds(),
                Detailed = input.Detailed, Zone = input.Zone, TimeZoneName = input.ZoneName,
                Users = string.IsNullOrWhiteSpace(input.User) ? [] : [input.User],
                Servers = string.IsNullOrWhiteSpace(input.Server) ? [] : [input.Server],
                ConfiguredServers = servers, Edge = options.Edge,
                EdgeServers = options.Edge ? (string.IsNullOrWhiteSpace(input.Server) ? servers : [input.Server]) : [],
                OutputFolder = staging, PortalDatabasePath = Path.Combine(staging, Snapshot.FileName),
                FilePrefix = "ExchangeLogs", WriteCsv = true, WriteHtml = true,
                ToolVersion = SourceVersion, Generated = DateTimeOffset.UtcNow.ToString("o", CultureInfo.InvariantCulture),
                Title = (options.Edge ? "Edge Transport " : "Exchange Server ") + (input.Detailed ? "detailed report" : "usage report"),
                Progress = job.Stage
            };
            using (var store = new Store(options.Database, true, SourceVersion))
                ReportBuilder.Build(store, request);
            job.Stage("Committing report");
            var completed = Snapshot.Load(id, Path.Combine(staging, Snapshot.FileName));
            Directory.Move(staging, destination);
            reports[id] = completed.AtPath(Path.Combine(destination, Snapshot.FileName));
            job.Complete();
        }
        catch (Exception e)
        {
            string stage = job.View.Stage;
            string message = e is ApiError ? e.Message : "Report failed at " + stage + " (" + e.GetType().Name +
                "). Check source integrity and available disk space; no source write was requested.";
            log.LogError("Report {ReportId} failed at {Stage}: {Reason}", id, stage, PortalDiagnostics.Describe(e));
            if (Directory.Exists(staging))
            {
                try { Directory.Delete(staging, true); }
                catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException)
                {
                    log.LogWarning("Could not remove uncommitted report {ReportId} ({ErrorType}).", id, cleanup.GetType().Name);
                    message += " An uncommitted private report folder remains.";
                }
            }
            job.Fail(message);
        }
        finally { lock (buildGate) building = 0; }
    }
}
