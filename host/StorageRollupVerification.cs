#nullable enable
using System.Globalization;
using System.Text;
using System.Text.Json;
using ExchangeLogReport;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReportAngular;

internal static class StorageRollupVerification
{
    public static readonly string[] Tables = ["message_rollup", "message_rollup_dirty"];
    // Exact canonical derived objects of each supported shape: schemas 8, 9 and 10 (delivered earlier, verified as is) and the current schema 11.
    private static readonly Dictionary<int, Dictionary<string, string?>> Shapes = new() { [8] = ExpectedObjects(8), [9] = ExpectedObjects(9), [10] = ExpectedObjects(10), [11] = ExpectedObjects(11) };
    // Names introduced by schemas 8 to 11, whichever shape: a schema 6/7 source must not already own any of them.
    private static readonly HashSet<string> ReservedNames = new(Shapes[8].Keys.Concat(Shapes[9].Keys).Concat(Shapes[10].Keys).Concat(Shapes[11].Keys), StringComparer.Ordinal);
    // Schema 9 dropped these; a schema-9 or -10 database must not carry them (schema 8 and 7 databases legitimately do and are not inspected for them).
    private static readonly string[] ObsoleteIndexes = ["ix_msg_hash", "ix_smtp_hash", "ix_session_latest"];
    // Schema 11 dropped ix_smtp_latest too (ix_smtp_flow starts with time_ms).
    private static readonly string[] ObsoleteIndexes11 = ["ix_msg_hash", "ix_smtp_hash", "ix_session_latest", "ix_smtp_latest"];
    // Schema 11: the dictionary of message_rollup and the SMTP client structures. They are added by the migration (not derived rollup tables of the source).
    public const string RollupValueTable = "message_rollup_value";
    public static readonly string[] SmtpClientTables = ["smtp_client_value", "smtp_client", "smtp_client_hour", "smtp_client_pending", "smtp_client_dirty"];
    // Every table whose objects a schema-11 database must not carry in any other shape.
    private static readonly string[] DerivedTables11 = ["message_rollup", "message_rollup_dirty", RollupValueTable, "smtp_client_value", "smtp_client", "smtp_client_hour", "smtp_client_pending", "smtp_client_dirty"];
    // Schema 10: the '#Fields' text dictionary of source_file (a table that is added by the migration, not a derived rollup table).
    public const string SourceFieldsTable = "source_fields";

    private static Dictionary<string, string?> ExpectedObjects(int version)
    {
        var result = new Dictionary<string, string?>(StringComparer.Ordinal) {
            ["message_rollup"] = version >= 11 ? Store.ServeRollupTableSql : """
CREATE TABLE message_rollup(
 id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, identity TEXT COLLATE BINARY NOT NULL,
 msg_hash INTEGER, first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL,
 member_first_ms INTEGER NOT NULL, member_last_ms INTEGER NOT NULL, status TEXT NOT NULL,
 sender TEXT, recipients TEXT NOT NULL, recipient_count INTEGER NOT NULL, delivered INTEGER NOT NULL,
 failed INTEGER NOT NULL, subject TEXT, size_kb INTEGER, direction TEXT, servers TEXT, events TEXT,
 events_count INTEGER NOT NULL, smtp_count INTEGER NOT NULL, UNIQUE(kind,identity))
""",
            ["sqlite_autoindex_message_rollup_1"] = null,
            ["message_rollup_dirty"] = """
CREATE TABLE message_rollup_dirty(kind TEXT NOT NULL,identity TEXT COLLATE BINARY NOT NULL,msg_hash INTEGER,
 PRIMARY KEY(kind,identity)) WITHOUT ROWID
""",
            ["ix_rollup_last"] = version == 8 ? "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms DESC,id DESC)" : "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms)",
            ["ix_rollup_status_last"] = version == 8 ? "CREATE INDEX ix_rollup_status_last ON message_rollup(status COLLATE NOCASE,member_last_ms DESC,id DESC)" :
                version >= 11 ? "CREATE INDEX ix_rollup_status_last ON message_rollup(status,member_last_ms)" : "CREATE INDEX ix_rollup_status_last ON message_rollup(status COLLATE NOCASE,member_last_ms)",
            // Schemas 8 and 9 carry the wide exact-identity indexes; schema 10 keeps the hash and the time only (the exact BINARY compare is on the row).
            ["ix_msg_identity_time"] = version < 10 ? "CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,message_id COLLATE BINARY,time_ms,id)" : "CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,time_ms)",
            ["ix_smtp_identity_time"] = version < 10 ? "CREATE INDEX ix_smtp_identity_time ON smtp_transaction(msg_hash,message_id COLLATE BINARY,time_ms,id)" : "CREATE INDEX ix_smtp_identity_time ON smtp_transaction(msg_hash,time_ms)"
        };
        if (version < 11) result["ix_smtp_latest"] = version == 8 ? "CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms DESC,id DESC)" : "CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms)";
        if (version == 8) result["ix_session_latest"] = "CREATE INDEX ix_session_latest ON client_session(start_ms DESC,id DESC)";
        if (version >= 10)
        {
            result[SourceFieldsTable] = "CREATE TABLE source_fields(id INTEGER PRIMARY KEY, text TEXT NOT NULL UNIQUE)";
            result["sqlite_autoindex_source_fields_1"] = null;
        }
        if (version >= 11)
        {
            // Schema 11: the rollup dictionary and the SMTP client structures (definitions shared with the engine that creates them).
            result[RollupValueTable] = Store.ServeRollupValueTableSql;
            result["sqlite_autoindex_message_rollup_value_1"] = null;
            foreach (var table in Store.SmtpClientTables) result[table[0]] = table[1];
            result["sqlite_autoindex_smtp_client_value_1"] = null;
            foreach (var index in Store.SmtpClientIndexes) result[index[0]] = index[2];
            foreach (var trigger in Store.SmtpClientTriggers) result[trigger[0]] = trigger[1];
        }
        foreach (string table in new[] { "message_event", "smtp_transaction" })
        foreach (string operation in new[] { "INSERT", "UPDATE", "DELETE" })
        {
            string body = "";
            foreach (string row in operation == "UPDATE" ? new[] { "OLD", "NEW" } : new[] { operation == "DELETE" ? "OLD" : "NEW" })
            {
                body += "INSERT INTO message_rollup_dirty SELECT 'message'," + row + ".message_id,exl_msg_hash(" + row + ".message_id) WHERE " + row + ".message_id IS NOT NULL ON CONFLICT(kind,identity) DO UPDATE SET msg_hash=excluded.msg_hash;";
                if (table == "smtp_transaction")
                    body += "INSERT OR IGNORE INTO message_rollup_dirty SELECT 'smtp',CAST(" + row + ".id AS TEXT),NULL WHERE " + row + ".message_id IS NULL;";
            }
            // Schema 9 lists only the columns the rollup is derived from; schema 8 listed every source column.
            string update = operation == "UPDATE" ? (table == "message_event"
                ? (version == 8 ? " OF id,message_id,time_ms,server,event_id,source,internal_id,sender,recipients,recipient_status,recipient_count,total_bytes,subject,client_ip,client_host,server_host,connector,source_context,directionality,related_recipient,reference"
                    : " OF id,message_id,time_ms,server,event_id,sender,recipients,recipient_count,total_bytes,subject,directionality")
                : (version == 8 ? " OF id,message_id,time_ms,end_ms,server,direction,role,connector,remote_ep,local_ep,helo,tls,auth,mail_from,rcpt_count,rcpts,status,auth_user"
                    : " OF id,message_id,time_ms,end_ms,server,direction,mail_from,rcpts,status")) : "";
            string name = "tr_" + table + "_rollup_" + operation.ToLowerInvariant();
            result[name] = "CREATE TRIGGER " + name + " AFTER " + operation + update + " ON " + table + " BEGIN " + body + " END";
        }
        return result;
    }

    // Ignore formatting only outside quoted SQL tokens; literal values remain exact.
    private static string Canonical(string sql)
    {
        var text = new StringBuilder();
        char quote = '\0';
        for (int i = 0; i < sql.Length; i++)
        {
            char c = sql[i];
            if (quote != '\0')
            {
                text.Append(c);
                if (c == quote)
                {
                    if (i + 1 < sql.Length && sql[i + 1] == quote) text.Append(sql[++i]);
                    else quote = '\0';
                }
            }
            else if (c is '\'' or '"' or '`' or '[')
            {
                quote = c == '[' ? ']' : c;
                text.Append(c);
            }
            else if (!char.IsWhiteSpace(c)) text.Append(c);
        }
        return text.ToString().TrimEnd(';');
    }

    private static StorageFailure Failure(int version = 11) => new("Schema-" + version + " derived rollup verification failed; no destination was published.");

    public static void CheckSource(SqliteConnection db, int version)
    {
        if (version is 8 or 9 or 10 or 11) { Verify(db, version); return; }
        using var command = db.CreateCommand();
        command.CommandText = "SELECT name,tbl_name FROM sqlite_schema;";
        using (var reader = command.ExecuteReader())
        {
            int objects = 0;
            while (reader.Read())
            {
                if (++objects > 10000) throw Failure();
                if (ReservedNames.Contains(reader.GetString(0)) || Tables.Contains(reader.GetString(1), StringComparer.Ordinal))
                    throw new StorageFailure("A legacy schema already contains reserved schema-8 derived objects; refusing ambiguous migration.");
            }
        }
        command.CommandText = "SELECT count(*) FROM sqlite_schema WHERE type='table' AND name='sqlite_sequence';";
        if (Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) != 0)
        {
            command.CommandText = "SELECT count(*) FROM sqlite_sequence WHERE name='message_rollup';";
            if (Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw Failure();
        }
    }

    /// <param name="version">The exact derived-object shape to require: 8, 9 or 10 (delivered schema sources) or 11 (the current schema).</param>
    public static void Verify(SqliteConnection db, int version = 11)
    {
        var Objects = Shapes[version];
        try
        {
            if (StorageSafety.Metadata(db, "schema_version") != version.ToString(CultureInfo.InvariantCulture) ||
                StorageSafety.Metadata(db, "message_hash_algorithm") != "fnv1a64-utf8-v1") throw Failure(version);
            var found = new HashSet<string>(StringComparer.Ordinal);
            using (var command = db.CreateCommand())
            {
                command.CommandText = "SELECT name,tbl_name,sql FROM sqlite_schema;";
                using var reader = command.ExecuteReader();
                int objects = 0;
                while (reader.Read())
                {
                    if (++objects > 10000) throw Failure(version);
                    string name = reader.GetString(0);
                    if (version >= 9 && (version >= 11 ? ObsoleteIndexes11 : ObsoleteIndexes).Contains(name)) throw Failure(version);
                    if (!Objects.TryGetValue(name, out string? expected))
                    {
                        if ((version >= 11 ? DerivedTables11 : Tables).Contains(reader.GetString(1), StringComparer.Ordinal)) throw Failure(version);
                        continue;
                    }
                    string? sql = reader.IsDBNull(2) ? null : reader.GetString(2);
                    if (expected is null ? sql is not null : sql is null || Canonical(expected) != Canonical(sql)) throw Failure(version);
                    found.Add(name);
                }
            }
            if (found.Count != Objects.Count) throw Failure(version);
            if (version >= 10)
            {
                // The dictionary side of source_file: the column exists and no row points at a missing header text.
                using var columns = db.CreateCommand();
                columns.CommandText = "SELECT count(*) FROM pragma_table_info('source_file') WHERE name='fields_id';";
                if (Convert.ToInt64(columns.ExecuteScalar(), CultureInfo.InvariantCulture) != 1) throw Failure(version);
                columns.CommandText = "SELECT count(*) FROM source_file s WHERE s.fields_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM source_fields d WHERE d.id=s.fields_id);";
                if (Convert.ToInt64(columns.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw Failure(version);
            }
            if (version >= 11)
            {
                using var column = db.CreateCommand();
                column.CommandText = "SELECT count(*) FROM pragma_table_info('smtp_transaction') WHERE name='client_id' AND type='INTEGER';";
                if (Convert.ToInt64(column.ExecuteScalar(), CultureInfo.InvariantCulture) != 1) throw Failure(version);
            }
            db.CreateFunction<string, long?>("exl_msg_hash", Store.MessageHash, isDeterministic: true);
            db.CreateFunction<string, string>("exl_remote_host", Identity.RemoteHost, isDeterministic: true);
            using (var limits = db.CreateCommand())
            {
                limits.CommandText = "PRAGMA temp_store=FILE; PRAGMA cache_size=-8192;";
                limits.ExecuteNonQuery();
            }
            using var tx = db.BeginTransaction(deferred: true);
            SqliteCommand Command(string sql)
            {
                var command = db.CreateCommand();
                command.Transaction = tx;
                command.CommandTimeout = 0;
                command.CommandText = sql;
                return command;
            }
            using (var dirty = Command("SELECT count(*) FROM message_rollup_dirty;"))
                if (Convert.ToInt64(dirty.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw Failure(version);
            using (var sequence = Command("SELECT count(*),coalesce(min(seq),0),count(*) FILTER(WHERE typeof(name)<>'text' OR typeof(seq)<>'integer'),(SELECT coalesce(max(id),0) FROM message_rollup) FROM sqlite_sequence WHERE name='message_rollup';"))
            using (var state = sequence.ExecuteReader())
            {
                if (!state.Read()) throw Failure(version);
                long count = state.GetInt64(0), maximumId = state.GetInt64(3);
                if (count > 1 || state.GetInt64(2) != 0 ||
                    (count == 0 ? maximumId > 0 : state.GetInt64(1) < maximumId)) throw Failure(version);
            }
            foreach (string table in new[] { "message_event", "smtp_transaction" })
            using (var hashes = Command("SELECT count(*) FROM " + table + " WHERE msg_hash IS NOT exl_msg_hash(message_id);"))
                if (Convert.ToInt64(hashes.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw Failure(version);
            using var keys = Command("""
SELECT 'message' AS kind,message_id COLLATE BINARY AS identity,msg_hash FROM message_event WHERE message_id IS NOT NULL
UNION SELECT 'message',message_id COLLATE BINARY,msg_hash FROM smtp_transaction WHERE message_id IS NOT NULL
UNION SELECT 'smtp',CAST(id AS TEXT),NULL FROM smtp_transaction WHERE message_id IS NULL AND direction='Receive' AND (status IS NULL OR status<>'Accepted')
ORDER BY kind COLLATE BINARY,identity COLLATE BINARY;
""");
            // Schema 11 stores codes: the row is read back through the dictionary (a missing code reads as NULL and fails the comparison; the dangling-code
            // check below covers the nullable columns) and first_ms/last_ms must be NULL exactly when they equal the member bounds.
            using var stored = Command(version >= 11
                ? "SELECT r.id,r.kind,r.identity,r.msg_hash,r.first_ms,r.last_ms,r.member_first_ms,r.member_last_ms,s.text,r.sender,r.recipients,r.recipient_count,r.delivered,r.failed,r.subject,r.size_kb,d.text,v.text,x.text,r.events_count,r.smtp_count FROM message_rollup r LEFT JOIN message_rollup_value s ON s.id=r.status LEFT JOIN message_rollup_value d ON d.id=r.direction LEFT JOIN message_rollup_value v ON v.id=r.servers LEFT JOIN message_rollup_value x ON x.id=r.events ORDER BY r.kind,r.identity COLLATE BINARY;"
                : "SELECT id,kind,identity,msg_hash,first_ms,last_ms,member_first_ms,member_last_ms,status,sender,recipients,recipient_count,delivered,failed,subject,size_kb,direction,servers,events,events_count,smtp_count FROM message_rollup ORDER BY kind COLLATE BINARY,identity COLLATE BINARY;");
            using var raw = keys.ExecuteReader();
            using var actual = stored.ExecuteReader();
            while (raw.Read())
            {
                string kind = raw.GetString(0), identity = raw.GetString(1);
                object hash = raw.GetValue(2);
                if (!actual.Read() || actual.GetInt64(0) <= 0) throw Failure(version);
                var row = ReportBuilder.ReadServeMessage(sql => {
                    var command = Command(sql);
                    command.Parameters.AddWithValue("@m", identity);
                    command.Parameters.AddWithValue("@h", hash);
                    command.Parameters.AddWithValue("@sid", kind == "smtp" ? long.Parse(identity, CultureInfo.InvariantCulture) : 0L);
                    return command;
                }, kind, identity, false, out long events);
                if (row is null) throw Failure(version);
                long first = Convert.ToInt64(row[0], CultureInfo.InvariantCulture), last = Convert.ToInt64(row[1], CultureInfo.InvariantCulture);
                using (var bounds = Command("SELECT MIN(time_ms),MAX(time_ms) FROM smtp_transaction WHERE " +
                    (kind == "message" ? "msg_hash=@h AND message_id=@i COLLATE BINARY" : "id=CAST(@i AS INTEGER)") + ";"))
                {
                    bounds.Parameters.AddWithValue("@h", hash);
                    bounds.Parameters.AddWithValue("@i", identity);
                    using var reader = bounds.ExecuteReader();
                    if (reader.Read() && !reader.IsDBNull(0)) { first = Math.Min(first, reader.GetInt64(0)); last = Math.Max(last, reader.GetInt64(1)); }
                }
                long rowFirst = Convert.ToInt64(row[0], CultureInfo.InvariantCulture), rowLast = Convert.ToInt64(row[1], CultureInfo.InvariantCulture);
                object?[] expected = version >= 11
                    ? [kind == "smtp" ? 1L : 0L, identity, hash, rowFirst == first ? null : rowFirst, rowLast == last ? null : rowLast, first, last, row[3], row[4],
                        JsonSerializer.Serialize(row[5]), row[6], row[7], row[8], row[9], row[10], row[11],
                        row[12], row[13], events, row[14]]
                    : [kind, identity, hash, row[0], row[1], first, last, row[3], row[4],
                        JsonSerializer.Serialize(row[5]), row[6], row[7], row[8], row[9], row[10], row[11],
                        row[12], row[13], events, row[14]];
                for (int i = 0; i < expected.Length; i++)
                {
                    object value = actual.GetValue(i + 1);
                    object wanted = expected[i] ?? DBNull.Value;
                    if (wanted is int integer) wanted = (long)integer;
                    if (!Equals(value, wanted)) throw Failure(version);
                }
            }
            if (actual.Read()) throw Failure(version);
            if (version >= 11)
            {
                using var dangling = Command("SELECT 1 FROM message_rollup r WHERE NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.status)" +
                    " OR (r.direction IS NOT NULL AND NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.direction))" +
                    " OR (r.servers IS NOT NULL AND NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.servers))" +
                    " OR (r.events IS NOT NULL AND NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.events)) LIMIT 1;");
                if (dangling.ExecuteScalar() is not null) throw Failure(version);
                // The SMTP client structures equal a full recomputation from the transactions (same proof as VerifyServeRollups).
                Store.VerifySmtpClientsCore(sql => Command(sql), null);
            }
        }
        catch (Exception error) when (error is SqliteException or InvalidOperationException or InvalidDataException or FormatException or OverflowException)
        {
            throw Failure(version);
        }
    }

    public static void VerifyAddedSequence(SqliteConnection db, bool addedTable)
    {
        using var command = db.CreateCommand();
        command.CommandText = "SELECT sql FROM sqlite_schema WHERE type='table' AND name='sqlite_sequence';";
        if (command.ExecuteScalar() is not string sql || Canonical(sql) != Canonical("CREATE TABLE sqlite_sequence(name,seq)")) throw Failure();
        if (addedTable)
        {
            command.CommandText = "SELECT count(*) FROM sqlite_sequence WHERE name IS NOT 'message_rollup';";
            if (Convert.ToInt64(command.ExecuteScalar(), CultureInfo.InvariantCulture) != 0) throw Failure();
        }
        command.CommandText = "SELECT count(*),coalesce(max(seq),0),(SELECT coalesce(max(id),0) FROM message_rollup),count(*) FILTER(WHERE typeof(name)<>'text' OR typeof(seq)<>'integer') FROM sqlite_sequence WHERE name='message_rollup';";
        using var reader = command.ExecuteReader();
        if (!reader.Read() || reader.GetInt64(0) != (reader.GetInt64(2) > 0 ? 1 : 0) ||
            reader.GetInt64(1) != reader.GetInt64(2) || reader.GetInt64(3) != 0) throw Failure();
    }
}
