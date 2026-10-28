#nullable enable
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ExchangeLogReport;

namespace ExchangeLogReportAngular;

internal sealed record StorageObject(string Name, string Type, string Table, long Bytes, long Pages,
    long PayloadBytes, long UnusedBytes)
{
    public double MiB => Bytes / 1048576.0;
}

internal sealed record StorageAudit(string Name, string Version, bool ReadOnly, string SqliteVersion,
    string? SchemaVersion, string SupportedSchemaVersion, long DatabaseBytes, long WalBytes, long ShmBytes,
    long PageSize, long PageCount, long FreelistCount, long FreelistBytes, long LivePageBytes,
    long ObjectBytes, long ResidualBytes, string JournalMode, StorageObject[] Objects, double DurationMs, string Note)
{
    public bool Success => true;
    public bool DbstatAvailable => true;
    public string? NativeSqliteVersion { get; init; }
    public long FreePageBytes => FreelistBytes;
    public long UnaccountedBytes => ResidualBytes;
    public double ElapsedMilliseconds => DurationMs;
    public string[] Recommendations
    {
        get
        {
            var result = new List<string> {
                "These measurements describe only the selected database; they are not client evidence or a promise of space or performance gains.",
                "Unaccounted bytes cover allocated non-B-tree or otherwise unaccounted pages. WAL and SHM sizes are separate."
            };
            result.Add(FreelistCount > 0
                ? "Freelist pages are reusable. Measure an explicit --storage-copy --vacuum on a new destination before deciding whether full vacuum is worthwhile."
                : "No freelist pages are currently reported. Full vacuum is optional and may not reduce size.");
            if (int.TryParse(SchemaVersion, out int stored) &&
                int.TryParse(SupportedSchemaVersion, out int supported) && stored < supported)
                result.Add("Reports require the supported schema. Use explicit --storage-copy --migrate to upgrade a new copy, never the original.");
            result.Add("Schema migration and adaptive text repacking are separate opt-in copy operations. Do not apply generic file compression to the database.");
            return result.ToArray();
        }
    }
    public double DatabaseMiB => DatabaseBytes / 1048576.0;
    public double WalMiB => WalBytes / 1048576.0;
    public double ShmMiB => ShmBytes / 1048576.0;
    public double FreelistMiB => FreelistBytes / 1048576.0;
    public double LivePageMiB => LivePageBytes / 1048576.0;
    public double ObjectMiB => ObjectBytes / 1048576.0;
    public double ResidualMiB => ResidualBytes / 1048576.0;
}

internal static class StorageAuditTool
{
    private const string ToolSha256 = "1D4DBBC37396C5DE744E1A732540B8BC83CD89888F47E86365B726E5A813C5E7";
    private const string Sql = """
PRAGMA query_only=ON;
PRAGMA temp_store=MEMORY;
WITH stats AS (
 SELECT name,pgsize AS bytes,pageno AS pages,payload,unused
 FROM dbstat WHERE aggregate=1
), objects AS (
 SELECT m.name,m.type,m.tbl_name AS table_name,coalesce(s.bytes,0) AS bytes,coalesce(s.pages,0) AS pages,
 coalesce(s.payload,0) AS payload,coalesce(s.unused,0) AS unused
 FROM sqlite_schema AS m LEFT JOIN stats AS s ON s.name=m.name
 UNION ALL
 SELECT name,'table',name,bytes,pages,payload,unused FROM stats WHERE name='sqlite_schema'
)
SELECT sqlite_version() AS sqliteVersion,
 (SELECT page_size FROM pragma_page_size) AS pageSize,
 (SELECT page_count FROM pragma_page_count) AS pageCount,
 (SELECT freelist_count FROM pragma_freelist_count) AS freelistCount,
 (SELECT journal_mode FROM pragma_journal_mode) AS journalMode,
 (SELECT json_group_array(json_object('name',name,'type',type,'table',table_name,'bytes',bytes,
 'pages',pages,'payloadBytes',payload,'unusedBytes',unused))
 FROM (SELECT * FROM objects ORDER BY bytes DESC,name LIMIT 10001)) AS objects;
""";

    public static async Task<StorageAudit> RunAsync(string path, string tool)
    {
        var watch = Stopwatch.StartNew();
        StorageSafety.PlainPath(tool);
        if (!File.Exists(tool) || !string.Equals(Path.GetFileName(tool), "sqlite3.exe", StringComparison.OrdinalIgnoreCase))
            throw new StorageFailure("Bundled sqlite3.exe is unavailable. Install the reviewed sqlite-tools package or supply its absolute path with --sqlite-tool; PATH fallback is disabled.");
        using var toolGuard = new FileStream(tool, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (Convert.ToHexString(SHA256.HashData(toolGuard)) != ToolSha256)
            throw new StorageFailure("SQLite tool SHA-256 does not match the reviewed 3.54.0 executable. Restore the pinned package; the tool was not executed.");
        var start = new ProcessStartInfo(tool) {
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true,
            CreateNoWindow = true, StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false)
        };
        foreach (string argument in new[] { "-safe", "-readonly", "-batch", "-json", "-init", "NUL", path, Sql })
            start.ArgumentList.Add(argument);
        using var process = new Process { StartInfo = start };
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(15));
        bool started = false;
        try
        {
            if (!process.Start()) throw new StorageFailure("The bundled SQLite tool could not be started.");
            started = true;
            async Task<string> Read(StreamReader reader, int limit)
            {
                var text = new StringBuilder();
                var buffer = new char[4096];
                while (true)
                {
                    int count = await reader.ReadAsync(buffer.AsMemory(), timeout.Token);
                    if (count == 0) return text.ToString();
                    if (text.Length + count > limit)
                    {
                        process.Kill(entireProcessTree: true);
                        throw new StorageFailure("SQLite audit exceeded its bounded output limit.");
                    }
                    text.Append(buffer, 0, count);
                }
            }
            Task<string> stdout = Read(process.StandardOutput, 8 * 1048576);
            Task<string> stderr = Read(process.StandardError, 65536);
            await Task.WhenAll(stdout, stderr, process.WaitForExitAsync(timeout.Token));
            if (process.ExitCode != 0)
                throw new StorageFailure("Bundled SQLite audit failed (exit " + process.ExitCode +
                    "). Confirm ENABLE_DBSTAT_VTAB support, source integrity and read permissions. No fallback estimate was substituted.");
            using var document = JsonDocument.Parse(await stdout);
            if (document.RootElement.GetArrayLength() != 1) throw new StorageFailure("SQLite audit returned an unsupported result.");
            JsonElement summary = document.RootElement[0];
            using var objectsDocument = JsonDocument.Parse(summary.GetProperty("objects").GetString() ?? "[]");
            if (objectsDocument.RootElement.GetArrayLength() > 10000)
                throw new StorageFailure("Too many schema objects for this audit profile.");
            var objects = new List<StorageObject>();
            foreach (var item in objectsDocument.RootElement.EnumerateArray())
                objects.Add(new(item.GetProperty("name").GetString()!, item.GetProperty("type").GetString()!,
                    item.GetProperty("table").GetString()!, item.GetProperty("bytes").GetInt64(),
                    item.GetProperty("pages").GetInt64(), item.GetProperty("payloadBytes").GetInt64(),
                    item.GetProperty("unusedBytes").GetInt64()));
            using var db = StorageSafety.Open(path, false);
            string? schema = StorageSafety.Metadata(db, "schema_version");
            if (!int.TryParse(schema, out _)) schema = null;
            long size = summary.GetProperty("pageSize").GetInt64();
            long pages = summary.GetProperty("pageCount").GetInt64();
            long free = summary.GetProperty("freelistCount").GetInt64();
            long objectBytes = objects.Sum(o => o.Bytes);
            long freeBytes = checked(free * size);
            return new("ExchangeLogReportAngular", PortalService.Version, true,
                summary.GetProperty("sqliteVersion").GetString()!, schema, Store.SchemaVersion,
                new FileInfo(path).Length, Size(path + "-wal"), Size(path + "-shm"), size, pages, free, freeBytes,
                checked((pages - free) * size), objectBytes, checked(pages * size - freeBytes - objectBytes),
                summary.GetProperty("journalMode").GetString()!, objects.ToArray(), watch.Elapsed.TotalMilliseconds,
                "dbstat measures object B-tree pages, payload and unused bytes. Freelist bytes are separate; residual bytes include pointer-map/other unaccounted pages. WAL/SHM sizes are separate physical sidecars. No expected space saving is promised.") { NativeSqliteVersion = db.ServerVersion };
        }
        catch (OperationCanceledException)
        {
            throw new StorageFailure("SQLite audit exceeded its 15-minute timeout; no success was reported.");
        }
        finally
        {
            if (started && !process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); }
        }
    }
    private static long Size(string path) => File.Exists(path) ? new FileInfo(path).Length : 0;
}
