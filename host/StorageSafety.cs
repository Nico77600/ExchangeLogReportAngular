#nullable enable
using System.Security.Cryptography;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReportAngular;

internal sealed class StorageFailure(string message) : Exception(message);

internal static class StorageSafety
{
    public static bool Same(string a, string b) => string.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase);
    public static bool Exists(string path)
    {
        try { File.GetAttributes(path); return true; }
        catch (FileNotFoundException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
    }
    public static void PlainPath(string path)
    {
        if (!Path.IsPathFullyQualified(path)) throw new StorageFailure("Storage paths must be absolute.");
        string full = Path.GetFullPath(path);
        string root = Path.GetPathRoot(full)!;
        if (full.Length < 3 || !char.IsAsciiLetter(full[0]) || full[1] != ':' ||
            full.IndexOf(':', root.Length) >= 0)
            throw new StorageFailure("Storage operations require ordinary local drive paths; device paths, network paths and alternate data streams are not accepted.");
        string? current = Path.GetFullPath(path);
        while (current is not null)
        {
            if (Exists(current) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new StorageFailure("Reparse points, junctions and symbolic links are not accepted for storage operations.");
            current = Path.GetDirectoryName(current);
        }
        string webRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "wwwroot"));
        if (Same(path, webRoot) || path.StartsWith(webRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new StorageFailure("Storage paths must be outside wwwroot.");
    }
    public static void NewFile(string path, string source, string? destination = null)
    {
        PlainPath(path);
        if (Same(path, source) || (destination is not null && Same(path, destination)) ||
            new[] { "-wal", "-shm", "-journal" }.Any(s => Same(path, source + s) || (destination is not null && Same(path, destination + s))))
            throw new StorageFailure("Source, destination, sidecars and output report must be distinct files.");
        if (Exists(path)) throw new StorageFailure("Destination and output reports must be brand-new files; existing files are never replaced.");
        string parent = Path.GetDirectoryName(path)!;
        if (!Directory.Exists(parent)) throw new StorageFailure("Create the destination/output parent directory before running maintenance.");
    }
    public static SqliteConnection Open(string path, bool writable)
    {
        var db = new SqliteConnection(new SqliteConnectionStringBuilder {
            DataSource = path, Mode = writable ? SqliteOpenMode.ReadWrite : SqliteOpenMode.ReadOnly,
            Cache = SqliteCacheMode.Private, Pooling = false
        }.ToString());
        try
        {
            db.Open();
            using var command = db.CreateCommand();
            command.CommandText = writable ? "PRAGMA busy_timeout=10000;" : "PRAGMA query_only=ON; PRAGMA busy_timeout=10000;";
            command.ExecuteNonQuery();
            return db;
        }
        catch { db.Dispose(); throw; }
    }
    public static string? Metadata(SqliteConnection db, string key)
    {
        using var command = db.CreateCommand();
        command.CommandText = "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='metadata';";
        if (Convert.ToInt64(command.ExecuteScalar()) == 0) return null;
        command.CommandText = "SELECT value FROM metadata WHERE key=@key;";
        command.Parameters.AddWithValue("@key", key);
        return command.ExecuteScalar() as string;
    }
    public static void Integrity(SqliteConnection db, bool full)
    {
        using var command = db.CreateCommand();
        command.CommandTimeout = 0;
        command.CommandText = full ? "PRAGMA integrity_check;" : "PRAGMA quick_check;";
        using var reader = command.ExecuteReader();
        if (!reader.Read() || reader.GetString(0) != "ok" || reader.Read())
            throw new StorageFailure(full ? "Staged integrity_check failed; no destination was published." : "Source quick_check failed; no maintenance was attempted.");
    }
}

internal sealed class StorageSource : IDisposable
{
    private readonly FileStream main;
    private readonly FileStream? wal;
    private readonly string originalMain;
    private readonly string? originalWal;
    public long Bytes => checked(main.Length + (wal?.Length ?? 0));
    public string MainSha256 => originalMain;
    public string? WalSha256 => originalWal;

    public StorageSource(string path, bool allowVerifiedRename = false)
    {
        StorageSafety.PlainPath(path);
        if (!File.Exists(path)) throw new StorageFailure("The selected source database does not exist.");
        main = new FileStream(path, FileMode.Open, FileAccess.Read,
            allowVerifiedRename ? FileShare.Read | FileShare.Delete : FileShare.Read);
        try
        {
            string walPath = path + "-wal";
            StorageSafety.PlainPath(walPath);
            // SQLite read-only connections can hold a read/write WAL handle.
            // The strict main-file guard already excludes every database writer;
            // retain read access to WAL and verify its complete bytes again.
            if (File.Exists(walPath)) wal = new FileStream(walPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            originalMain = Hash(main);
            originalWal = wal is null ? null : Hash(wal);
        }
        catch { wal?.Dispose(); main.Dispose(); throw; }
    }
    private static string Hash(FileStream stream)
    {
        stream.Position = 0;
        string result = Convert.ToHexString(SHA256.HashData(stream));
        stream.Position = 0;
        return result;
    }
    public void VerifyUnchanged()
    {
        if (Hash(main) != originalMain || (wal is not null && Hash(wal) != originalWal))
            throw new StorageFailure("Source byte verification changed. No destination is authorized for publication.");
    }
    public void Dispose() { wal?.Dispose(); main.Dispose(); }
}
