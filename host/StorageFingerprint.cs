#nullable enable
using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using ExchangeLogReport;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReportAngular;

internal sealed record LogicalTable(string Name, string[] Columns, string[] Key, bool WithoutRowId);
internal sealed record LogicalDigest(string Name, long Rows, long ComparedRows, string Sha256);
// RollupCodes: the table is a schema-11 message_rollup (kind/status/direction/servers/events as dictionary codes, first_ms/last_ms NULL when equal to the member
// bounds) compared to a schema 8 to 10 source through its decoded logical rows. ClientId: smtp_transaction.client_id (schema 11) is an allowed added column.
internal sealed record LogicalComparison(bool AllowAddedHash, string[] ExcludedMetadata, string[] AddedTables,
    bool AllowAddedRollupSequence = false, bool FieldsDictionary = false, bool RollupCodes = false, bool ClientId = false)
{
    public static readonly LogicalComparison Strict = new(false, [], []);
}

internal static class StorageFingerprint
{
    private static readonly HashSet<string> PackedSlots = new(StringComparer.OrdinalIgnoreCase) {
        "smtp_transaction.transcript", "smtp_transaction.response", "session_step.data",
        "access_event.url", "access_event.errors", "client_session.actions", "client_session.statuses"
    };

    private static string Quote(string name) => "\"" + name.Replace("\"", "\"\"") + "\"";

    public static List<LogicalTable> Inventory(SqliteConnection db)
    {
        var names = new List<(string Name, string Sql)>();
        using (var command = db.CreateCommand())
        {
            command.CommandText = "SELECT name,sql FROM sqlite_schema WHERE type='table' ORDER BY name COLLATE BINARY;";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                if (names.Count >= 10000) throw new StorageFailure("Schema has too many objects for this maintenance profile.");
                names.Add((reader.GetString(0), reader.IsDBNull(1) ? "" : reader.GetString(1)));
            }
        }
        var result = new List<LogicalTable>();
        foreach (var item in names)
        {
            if (item.Sql.Contains("CREATE VIRTUAL", StringComparison.OrdinalIgnoreCase))
                throw new StorageFailure("Virtual tables are not supported by copy verification.");
            using var command = db.CreateCommand();
            command.CommandText = "PRAGMA table_xinfo(" + Quote(item.Name) + ");";
            using var reader = command.ExecuteReader();
            var columns = new List<string>();
            var keys = new SortedDictionary<int, string>();
            while (reader.Read())
            {
                if (reader.GetInt64(6) != 0) throw new StorageFailure("Generated/hidden columns are not supported by copy verification.");
                string name = reader.GetString(1);
                columns.Add(name);
                int pk = reader.GetInt32(5);
                if (pk > 0) keys.Add(pk, name);
            }
            result.Add(new(item.Name, columns.ToArray(), keys.Values.ToArray(),
                item.Sql.Contains("WITHOUT ROWID", StringComparison.OrdinalIgnoreCase)));
        }
        return result;
    }

    public static List<LogicalDigest> Compute(SqliteConnection db, List<LogicalTable> baseline, LogicalComparison comparison)
    {
        var inventory = Inventory(db);
        var expected = baseline.Select(t => t.Name).Concat(comparison.AddedTables).OrderBy(n => n, StringComparer.Ordinal);
        if (!expected.SequenceEqual(inventory.Select(t => t.Name), StringComparer.Ordinal))
            throw new StorageFailure("Table inventory changed; copy verification failed.");
        var results = new List<LogicalDigest>();
        using var tx = db.BeginTransaction(deferred: true);
        foreach (var table in baseline)
        {
            var actual = inventory.Single(x => x.Name == table.Name);
            if (table.WithoutRowId != actual.WithoutRowId || !table.Key.SequenceEqual(actual.Key, StringComparer.Ordinal))
                throw new StorageFailure("Primary-key layout changed; copy verification failed.");
            string[] additional = actual.Columns.Except(table.Columns, StringComparer.Ordinal).ToArray();
            // Schema 10 moved the '#Fields' text of source_file into the source_fields dictionary (source_file.fields_id): the added column is allowed
            // and the logical fields value below is the dictionary text, so a copy compares equal to its source whatever the storage form.
            bool dictionary = comparison.FieldsDictionary && table.Name == "source_file" && actual.Columns.Contains("fields_id", StringComparer.Ordinal);
            if (table.Columns.Except(actual.Columns, StringComparer.Ordinal).Any() ||
                additional.Any(c => !(comparison.AllowAddedHash && c == "msg_hash" && table.Name is "message_event" or "smtp_transaction") &&
                    !(dictionary && c == "fields_id") && !(comparison.ClientId && c == "client_id" && table.Name == "smtp_transaction")))
                throw new StorageFailure("Unexpected column changes; copy verification failed.");
            using var count = db.CreateCommand();
            count.Transaction = tx;
            count.CommandText = "SELECT count(*) FROM " + Quote(table.Name) + ";";
            long total = Convert.ToInt64(count.ExecuteScalar(), CultureInfo.InvariantCulture);
            using var command = db.CreateCommand();
            command.Transaction = tx;
            command.CommandTimeout = 0;
            bool rollupCodes = comparison.RollupCodes && table.Name == "message_rollup";
            command.CommandText = "SELECT " + string.Join(",", table.Columns.Select(column => dictionary && column == "fields"
                ? "COALESCE((SELECT d.\"text\" FROM \"source_fields\" d WHERE d.\"id\"=" + Quote(table.Name) + ".\"fields_id\")," + Quote(column) + ")"
                : rollupCodes ? RollupColumn(column)
                : Quote(column))) + " FROM " + Quote(table.Name);
            if (comparison.ExcludedMetadata.Length > 0 && table.Name == "metadata")
            {
                command.CommandText += " WHERE key NOT IN (" +
                    string.Join(",", comparison.ExcludedMetadata.Select((_, i) => "@excluded" + i)) + ")";
                for (int i = 0; i < comparison.ExcludedMetadata.Length; i++)
                    command.Parameters.AddWithValue("@excluded" + i, comparison.ExcludedMetadata[i]);
            }
            if (comparison.AllowAddedRollupSequence && table.Name == "sqlite_sequence")
                command.CommandText += " WHERE name IS NOT 'message_rollup'";
            var order = table.Key.Select(c => Quote(c) + " COLLATE BINARY").ToList();
            if (!table.WithoutRowId)
            {
                string? rowid = new[] { "rowid", "_rowid_", "oid" }.FirstOrDefault(n => !table.Columns.Contains(n, StringComparer.OrdinalIgnoreCase));
                if (rowid is null) throw new StorageFailure("No unambiguous row ordering is available for copy verification.");
                order.Add(rowid);
            }
            if (order.Count == 0) throw new StorageFailure("No stable row ordering is available for copy verification.");
            command.CommandText += " ORDER BY " + string.Join(",", order) + ";";
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            Field(hash, table.Name);
            foreach (string column in table.Columns) Field(hash, column);
            long rows = 0;
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                hash.AppendData(new byte[] { 0x52 });
                for (int i = 0; i < reader.FieldCount; i++)
                    Field(hash, Normalize(table.Name, table.Columns[i], reader.GetValue(i)));
                rows++;
            }
            results.Add(new(table.Name, total, rows, Convert.ToHexString(hash.GetHashAndReset())));
        }
        return results;
    }

    public static void Compare(List<LogicalDigest> before, List<LogicalDigest> after, LogicalComparison comparison)
    {
        foreach (var first in before)
        {
            var second = after.Single(t => t.Name == first.Name);
            if (first.Sha256 != second.Sha256 || first.ComparedRows != second.ComparedRows ||
                (!(comparison.ExcludedMetadata.Length > 0 && first.Name == "metadata") &&
                 !(comparison.AllowAddedRollupSequence && first.Name == "sqlite_sequence") && first.Rows != second.Rows))
                throw new StorageFailure("Normalized logical contents or row counts changed; no destination was published.");
        }
    }

    /// <summary>The schema 8 to 10 logical value of a column of a schema-11 message_rollup row (the dictionary text, the textual kind, COALESCE of the member bounds).</summary>
    private static string RollupColumn(string column) => column switch
    {
        "kind" => "CASE \"message_rollup\".\"kind\" WHEN 0 THEN 'message' WHEN 1 THEN 'smtp' END",
        "first_ms" => "COALESCE(\"message_rollup\".\"first_ms\",\"message_rollup\".\"member_first_ms\")",
        "last_ms" => "COALESCE(\"message_rollup\".\"last_ms\",\"message_rollup\".\"member_last_ms\")",
        "status" or "direction" or "servers" or "events" =>
            "(SELECT v.\"text\" FROM \"message_rollup_value\" v WHERE v.\"id\"=\"message_rollup\"." + Quote(column) + ")",
        _ => Quote(column)
    };

    private static object Normalize(string tableName, string columnName, object value)
    {
        if (!PackedSlots.Contains(tableName + "." + columnName) || value is not (string or byte[])) return value;
        try { return Packed.Unpack(value); }
        // A marker byte alone does not make arbitrary binary a valid Packed value.
        // Preserve unrecognized binary as bytes/type, not a lossy string conversion.
        catch (InvalidDataException) when (value is byte[]) { return value; }
    }

    private static void Field(IncrementalHash hash, object? value)
    {
        byte type;
        byte[] bytes;
        switch (value)
        {
            case null or DBNull: type = 0; bytes = []; break;
            case long number:
                type = 1; bytes = new byte[8]; BinaryPrimitives.WriteInt64BigEndian(bytes, number); break;
            case double number:
                type = 2; bytes = new byte[8]; BinaryPrimitives.WriteInt64BigEndian(bytes, BitConverter.DoubleToInt64Bits(number)); break;
            case string text: type = 3; bytes = Encoding.UTF8.GetBytes(text); break;
            case byte[] binary: type = 4; bytes = binary; break;
            default: throw new StorageFailure("An unsupported SQLite value type prevents logical verification.");
        }
        Span<byte> header = stackalloc byte[9];
        header[0] = type;
        BinaryPrimitives.WriteInt64BigEndian(header[1..], bytes.LongLength);
        hash.AppendData(header);
        hash.AppendData(bytes);
    }
}
