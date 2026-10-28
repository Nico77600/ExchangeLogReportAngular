#nullable enable
namespace ExchangeLogReportAngular;

internal enum StorageMode { None, Audit, Copy }

internal sealed record PortalOptions(string Database, string Reports, int Port, bool NoBrowser,
    string? ReadyFile, bool ReadyFileWithToken, bool Edge)
{
    public StorageMode StorageMode { get; init; }
    public string? Destination { get; init; }
    public string? Output { get; init; }
    public string SqliteTool { get; init; } = "";
    public bool Migrate { get; init; }
    public bool Repack { get; init; }
    public bool Vacuum { get; init; }

    public static PortalOptions Parse(string[] args)
    {
        string root = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, ".."));
        string database = Path.Combine(root, "collector", "data", "ExchangeLogReport.sqlite");
        string reports = Path.Combine(root, "reports");
        string? ready = null;
        int port = 0;
        bool noBrowser = false, token = false, edge = false;
        StorageMode mode = StorageMode.None;
        string? destination = null, output = null;
        string sqliteTool = Path.Combine(root, "sqlite-tools", "sqlite3.exe");
        bool confirm = false, migrate = false, repack = false, vacuum = false;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        for (int i = 0; i < args.Length; i++)
        {
            string key = args[i];
            if (!seen.Add(key)) throw new ArgumentException("Duplicate command-line option.");
            string Value()
            {
                if (++i >= args.Length || args[i].StartsWith("--", StringComparison.Ordinal))
                    throw new ArgumentException("Missing command-line option value.");
                return args[i];
            }
            switch (key)
            {
                case "--database": database = Absolute(Value()); break;
                case "--reports": reports = Absolute(Value()); break;
                case "--ready-file": ready = Absolute(Value()); break;
                case "--port":
                    if (!int.TryParse(Value(), out port) || port < 0 || port > 65535)
                        throw new ArgumentException("Port must be between 0 and 65535.");
                    break;
                case "--no-browser": noBrowser = true; break;
                case "--ready-file-with-token": token = true; break;
                case "--edge": edge = true; break;
                case "--sqlite-tool": sqliteTool = Absolute(Value()); break;
                case "--output": output = Absolute(Value()); break;
                case "--destination": destination = Absolute(Value()); break;
                case "--confirm-copy": confirm = true; break;
                case "--migrate": migrate = true; break;
                case "--repack": repack = true; break;
                case "--vacuum": vacuum = true; break;
                case "--storage-audit":
                case "--storage-copy":
                    if (mode != StorageMode.None) throw new ArgumentException("Choose one storage operation.");
                    mode = key == "--storage-audit" ? StorageMode.Audit : StorageMode.Copy;
                    break;
                default: throw new ArgumentException("Unknown command-line option.");
            }
        }
        if (token && ready is null) throw new ArgumentException("--ready-file-with-token requires --ready-file.");
        if (mode != StorageMode.None && !seen.Contains("--database"))
            throw new ArgumentException("Storage operations require an explicit absolute --database.");
        if (mode == StorageMode.Copy && (destination is null || !confirm))
            throw new ArgumentException("--storage-copy requires --destination and --confirm-copy.");
        if (mode == StorageMode.Copy) output ??= destination + ".maintenance.json";
        if (mode != StorageMode.Copy && (destination is not null || confirm || migrate || repack || vacuum))
            throw new ArgumentException("Destination, confirmation and maintenance switches require --storage-copy.");
        if (mode == StorageMode.None && output is not null)
            throw new ArgumentException("--output requires a storage operation.");
        if (mode != StorageMode.None && (ready is not null || seen.Contains("--port") || edge))
            throw new ArgumentException("Storage CLI operations cannot be combined with portal startup options.");
        return new(database, reports, port, noBrowser, ready, token, edge) {
            StorageMode = mode, Destination = destination, Output = output, SqliteTool = sqliteTool,
            Migrate = migrate, Repack = repack, Vacuum = vacuum
        };
    }

    private static string Absolute(string value)
    {
        if (!Path.IsPathFullyQualified(value)) throw new ArgumentException("Paths must be fully qualified.");
        return Path.GetFullPath(value);
    }
}
