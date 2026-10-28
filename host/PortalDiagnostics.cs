#nullable enable
using System.ComponentModel;
using System.Net.Sockets;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReportAngular;

internal static class PortalDiagnostics
{
    public static string Describe(Exception error)
    {
        Exception cause = error.GetBaseException();
        // Never print arbitrary exception messages: browser-launch errors can include
        // the capability URL, and SQLite errors can include private report values.
        string reason = cause switch {
            ApiError problem => problem.Message,
            DllNotFoundException => "A native dependency is missing. Re-extract the complete win-x64 package and check e_sqlite3.dll beside the executable.",
            BadImageFormatException => "A binary is corrupt or has the wrong architecture. Use the complete win-x64 package on 64-bit Windows.",
            FileNotFoundException file => "Required file or assembly is missing" + Dependency(file.FileName) + ". Re-extract the complete package.",
            FileLoadException file => "A required assembly could not be loaded" + Dependency(file.FileName) + ". Check package integrity and Windows file blocking.",
            DirectoryNotFoundException => "A required directory is missing. Check the configured database, reports and ready-file paths.",
            UnauthorizedAccessException => "Access denied. Check read permission for the source and write permission for report and ready-file directories.",
            SocketException socket => "Loopback listener failed: " + socket.SocketErrorCode + " (Windows " + socket.NativeErrorCode + ": " + new Win32Exception(socket.NativeErrorCode).Message + "). Choose a free --port or --port 0.",
            Win32Exception native => "Windows operation failed (" + native.NativeErrorCode + "): " + new Win32Exception(native.NativeErrorCode).Message + ".",
            SqliteException sqlite => SqliteReason(sqlite),
            IOException io => "Local file operation failed (Windows " + (io.HResult & 0xffff) + "): " + new Win32Exception(io.HResult & 0xffff).Message + ". Check paths, free disk space and files held by another process.",
            InvalidDataException => "A report snapshot or package data file is incomplete or unsupported. Verify package and report integrity.",
            _ => "Unexpected local initialization or operation failure. Verify the complete package, chosen paths and free disk space."
        };
        return reason + " [" + cause.GetType().Name + "; HRESULT 0x" + cause.HResult.ToString("X8") + "]";
    }

    private static string Dependency(string? path)
    {
        if (path is null) return "";
        string name = Path.GetFileName(path);
        return name.Length <= 180 && Regex.IsMatch(name, @"^[A-Za-z0-9_.-]+\.(?:dll|exe)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)
            ? " (" + name + ")" : "";
    }

    private static string SqliteReason(SqliteException error)
    {
        string reason = error.SqliteErrorCode switch {
            1 => "The SQLite schema or query is unavailable. Verify the delivered schema-" + ExchangeLogReport.Store.SchemaVersion + " source and committed portal snapshots.",
            3 or 23 => "SQLite access was denied. Check local file permissions.",
            5 or 6 => "SQLite is busy or locked. Close other writers and retry.",
            8 => "SQLite rejected a write on a read-only connection. Source migration is not allowed.",
            11 or 26 => "The selected file is corrupt or is not a SQLite database.",
            13 => "SQLite storage is full. Free space in the report directory.",
            14 => "SQLite could not open the configured file. Check its existence, path and read permissions.",
            _ => "SQLite could not complete the operation. Check source integrity and local storage."
        };
        return reason + " SQLite codes " + error.SqliteErrorCode + "/" + error.SqliteExtendedErrorCode + ".";
    }
}
