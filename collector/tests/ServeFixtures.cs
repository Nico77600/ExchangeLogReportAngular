using System;
using System.Reflection;
using Microsoft.Data.Sqlite;

public static class ServeFixtures
{
    public static string RawBaseline(object store)
    {
        var result = new System.Text.StringBuilder();
        var tables = new System.Collections.Generic.List<string>();
        using (var c = Connection(store).CreateCommand())
        {
            // source_fields is the schema-10 storage form of source_file.fields (compared through the logical value below), not a source table; the SMTP client
            // structures (schema 11, with smtp_transaction.client_id) are derived from the transactions, like the rollup.
            c.CommandText = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT IN ('message_rollup','message_rollup_dirty','message_rollup_value','source_fields','smtp_client_value','smtp_client','smtp_client_hour','smtp_client_pending','smtp_client_dirty') ORDER BY name;";
            using (var r = c.ExecuteReader()) while (r.Read()) tables.Add(r.GetString(0));
        }
        foreach (string table in tables)
        {
            var columns = new System.Collections.Generic.List<string>();
            using (var c = Connection(store).CreateCommand())
            {
                c.CommandText = "PRAGMA table_info(\"" + table + "\");";
                using (var r = c.ExecuteReader()) while (r.Read()) if (r.GetString(1) != "msg_hash" && r.GetString(1) != "fields_id" && r.GetString(1) != "client_id") columns.Add("\"" + r.GetString(1).Replace("\"", "\"\"") + "\"");
            }
            // Logical '#Fields' text: the dictionary text of a schema-10 row, else the row's own column (schema 6 to 9).
            bool dictionary = false;
            if (table == "source_file")
                using (var c = Connection(store).CreateCommand())
                {
                    c.CommandText = "SELECT COUNT(*) FROM pragma_table_info('source_file') WHERE name='fields_id';";
                    dictionary = Convert.ToInt64(c.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) != 0;
                }
            var selected = new System.Collections.Generic.List<string>(columns);
            if (dictionary) selected[selected.IndexOf("\"fields\"")] = "COALESCE((SELECT d.text FROM source_fields d WHERE d.id=source_file.fields_id),\"fields\")";
            result.Append(table).Append(':').Append(string.Join(",", columns)).Append('\n');
            using (var c = Connection(store).CreateCommand())
            {
                c.CommandText = "SELECT " + string.Join(",", selected) + " FROM \"" + table + "\"" +
                    (table == "metadata" ? " WHERE key NOT IN ('schema_version','message_hash_algorithm','tool_version')" : "") +
                    " ORDER BY " + string.Join(",", selected) + ";";
                using (var r = c.ExecuteReader()) while (r.Read())
                {
                    for (int i=0; i<r.FieldCount; i++)
                    {
                        object value = r.IsDBNull(i) ? null : r.GetValue(i);
                        string text = value == null ? "" : value is byte[] ? Convert.ToBase64String((byte[])value) :
                            Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
                        result.Append(value == null ? "NULL" : value.GetType().Name).Append(':').Append(text.Length).Append(':').Append(text);
                    }
                    result.Append('\n');
                }
            }
        }
        return result.ToString();
    }

    /// <summary>
    /// The content of message_rollup as the readers see it (codes decoded through message_rollup_value, first_ms/last_ms through COALESCE), typed and length-prefixed.
    /// Dictionary codes are not stable across a migration, so a comparison between two shapes or histories is made on this value.
    /// </summary>
    public static string DecodedRollup(object store)
    {
        var result = new System.Text.StringBuilder();
        using (var c = Connection(store).CreateCommand())
        {
            c.CommandText = "SELECT r.id,CASE r.kind WHEN 0 THEN 'message' WHEN 1 THEN 'smtp' END,r.identity,r.msg_hash,COALESCE(r.first_ms,r.member_first_ms),COALESCE(r.last_ms,r.member_last_ms),r.member_first_ms,r.member_last_ms," +
                "s.text,r.sender,r.recipients,r.recipient_count,r.delivered,r.failed,r.subject,r.size_kb,d.text,v.text,x.text,r.events_count,r.smtp_count FROM message_rollup r " +
                "LEFT JOIN message_rollup_value s ON s.id=r.status LEFT JOIN message_rollup_value d ON d.id=r.direction LEFT JOIN message_rollup_value v ON v.id=r.servers LEFT JOIN message_rollup_value x ON x.id=r.events ORDER BY r.id;";
            using (var r = c.ExecuteReader())
                while (r.Read())
                {
                    for (int i = 0; i < r.FieldCount; i++)
                    {
                        object value = r.IsDBNull(i) ? null : r.GetValue(i);
                        string text = value == null ? "" : Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
                        result.Append(value == null ? "NULL" : value.GetType().Name).Append(':').Append(text.Length).Append(':').Append(text).Append('|');
                    }
                    result.Append('\n');
                }
        }
        return result.ToString();
    }

    public static SqliteConnection Connection(object store)
    {
        return (SqliteConnection)store.GetType().GetProperty("Connection", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(store);
    }

    public static void ForceHashCollision(object store)
    {
        // Test-only deterministic collision, never installed in the production engine.
        Connection(store).CreateFunction<string, long?>("exl_msg_hash", s => s == null ? (long?)null : 17L, isDeterministic: true);
    }

    public static void ForceInvalidNullHash(object store)
    {
        Connection(store).CreateFunction<string, long?>("exl_msg_hash", s => s == null ? 17L : MessageHash(s), isDeterministic: true);
    }

    public static void RefreshServeRollups(object store)
    {
        using (var tx = Connection(store).BeginTransaction())
        {
            store.GetType().GetMethod("ReconcileMessageRollups").Invoke(store, new object[] { tx });
            tx.Commit();
        }
    }

    // Synthetic test fixtures only: production copy/verification must never call this conversion.
    public static void ConvertToLegacySyntheticFixture(object storeOrConnection, int version)
    {
        if (version != 6 && version != 7 && version != 8 && version != 9 && version != 10) throw new ArgumentOutOfRangeException(nameof(version));
        var db = storeOrConnection as SqliteConnection ?? Connection(storeOrConnection);
        using (var tx = db.BeginTransaction())
        using (var c = db.CreateCommand())
        {
            c.Transaction = tx;
            c.CommandText = "SELECT value FROM metadata WHERE key='schema_version';";
            int current = Convert.ToInt32(c.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture);
            if (current < version || current > 11) throw new InvalidOperationException("Only downgrade a known synthetic schema 6/7/8/9/10/11 fixture.");
            if (current == 11)
            {
                // Schema-10 shape of a schema-11 database: no SMTP client structures, message_rollup with text columns (ids and sequence kept), ix_smtp_latest back.
                long? sequence = null;
                c.CommandText = "SELECT seq FROM sqlite_sequence WHERE name='message_rollup';";
                object seq = c.ExecuteScalar();
                if (seq != null && !(seq is DBNull)) sequence = Convert.ToInt64(seq, System.Globalization.CultureInfo.InvariantCulture);
                c.CommandText = "DROP TRIGGER IF EXISTS tr_smtp_transaction_client_insert; DROP TRIGGER IF EXISTS tr_smtp_transaction_client_update; DROP TRIGGER IF EXISTS tr_smtp_transaction_client_delete;" +
                    "DROP INDEX IF EXISTS ix_smtp_client; DROP INDEX IF EXISTS ix_smtp_unknown_peer; ALTER TABLE smtp_transaction DROP COLUMN client_id;" +
                    "DROP TABLE smtp_client_hour; DROP TABLE smtp_client; DROP TABLE smtp_client_value; DROP TABLE smtp_client_pending; DROP TABLE smtp_client_dirty;" +
                    "DROP INDEX IF EXISTS ix_rollup_last; DROP INDEX IF EXISTS ix_rollup_status_last; ALTER TABLE message_rollup RENAME TO message_rollup_11;" +
                    "CREATE TABLE message_rollup(\n id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, identity TEXT COLLATE BINARY NOT NULL,\n msg_hash INTEGER, first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL,\n member_first_ms INTEGER NOT NULL, member_last_ms INTEGER NOT NULL, status TEXT NOT NULL,\n sender TEXT, recipients TEXT NOT NULL, recipient_count INTEGER NOT NULL, delivered INTEGER NOT NULL,\n failed INTEGER NOT NULL, subject TEXT, size_kb INTEGER, direction TEXT, servers TEXT, events TEXT,\n events_count INTEGER NOT NULL, smtp_count INTEGER NOT NULL, UNIQUE(kind,identity));" +
                    "INSERT INTO message_rollup(id,kind,identity,msg_hash,first_ms,last_ms,member_first_ms,member_last_ms,status,sender,recipients,recipient_count,delivered,failed,subject,size_kb,direction,servers,events,events_count,smtp_count) " +
                    "SELECT r.id,CASE r.kind WHEN 0 THEN 'message' ELSE 'smtp' END,r.identity,r.msg_hash,COALESCE(r.first_ms,r.member_first_ms),COALESCE(r.last_ms,r.member_last_ms),r.member_first_ms,r.member_last_ms,s.text,r.sender,r.recipients,r.recipient_count,r.delivered,r.failed,r.subject,r.size_kb,d.text,v.text,x.text,r.events_count,r.smtp_count " +
                    "FROM message_rollup_11 r JOIN message_rollup_value s ON s.id=r.status LEFT JOIN message_rollup_value d ON d.id=r.direction LEFT JOIN message_rollup_value v ON v.id=r.servers LEFT JOIN message_rollup_value x ON x.id=r.events ORDER BY r.id;" +
                    "DROP TABLE message_rollup_11; DROP TABLE message_rollup_value;" +
                    "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms); CREATE INDEX ix_rollup_status_last ON message_rollup(status COLLATE NOCASE,member_last_ms);" +
                    "CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms);";
                c.ExecuteNonQuery();
                if (sequence.HasValue)
                {
                    c.CommandText = "UPDATE sqlite_sequence SET seq=MAX(seq,@s) WHERE name='message_rollup'; INSERT INTO sqlite_sequence(name,seq) SELECT 'message_rollup',@s WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='message_rollup');";
                    c.Parameters.AddWithValue("@s", sequence.Value);
                    c.ExecuteNonQuery();
                    c.Parameters.Clear();
                }
                c.CommandText = "UPDATE metadata SET value='10' WHERE key='schema_version';";
                c.ExecuteNonQuery();
                current = 10;
                if (version == 10) { tx.Commit(); return; }
            }
            if (current == 10)
            {
                // Schema-9 shape of a schema-10 database: the identity indexes carry the exact Message-ID again, the '#Fields' text is back in
                // source_file.fields and the dictionary (with its fields_id column) does not exist.
                c.CommandText = "UPDATE source_file SET fields=(SELECT d.text FROM source_fields d WHERE d.id=source_file.fields_id) WHERE fields_id IS NOT NULL;" +
                    "ALTER TABLE source_file DROP COLUMN fields_id; DROP TABLE source_fields;" +
                    "DROP INDEX IF EXISTS ix_msg_identity_time; DROP INDEX IF EXISTS ix_smtp_identity_time;" +
                    "CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,message_id COLLATE BINARY,time_ms,id);" +
                    "CREATE INDEX ix_smtp_identity_time ON smtp_transaction(msg_hash,message_id COLLATE BINARY,time_ms,id);" +
                    "UPDATE metadata SET value='9' WHERE key='schema_version';";
                c.ExecuteNonQuery();
                if (version == 9) { tx.Commit(); return; }
            }
            if (version == 8)
            {
                // Schema-8 shape of a schema-9 database: hash-only and DESC "latest" indexes, ascending-free rollup indexes, full-column UPDATE triggers.
                c.CommandText = "DROP INDEX IF EXISTS ix_rollup_last; DROP INDEX IF EXISTS ix_rollup_status_last; DROP INDEX IF EXISTS ix_smtp_latest;" +
                    "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms DESC,id DESC);" +
                    "CREATE INDEX ix_rollup_status_last ON message_rollup(status COLLATE NOCASE,member_last_ms DESC,id DESC);" +
                    "CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms DESC,id DESC);" +
                    "CREATE INDEX ix_session_latest ON client_session(start_ms DESC,id DESC);" +
                    "CREATE INDEX ix_msg_hash ON message_event(msg_hash);CREATE INDEX ix_smtp_hash ON smtp_transaction(msg_hash);";
                c.ExecuteNonQuery();
                foreach (var old in new[] {
                    new[] { "message_event", " OF id,message_id,time_ms,server,event_id,sender,recipients,recipient_count,total_bytes,subject,directionality",
                        " OF id,message_id,time_ms,server,event_id,source,internal_id,sender,recipients,recipient_status,recipient_count,total_bytes,subject,client_ip,client_host,server_host,connector,source_context,directionality,related_recipient,reference" },
                    new[] { "smtp_transaction", " OF id,message_id,time_ms,end_ms,server,direction,mail_from,rcpts,status",
                        " OF id,message_id,time_ms,end_ms,server,direction,role,connector,remote_ep,local_ep,helo,tls,auth,mail_from,rcpt_count,rcpts,status,auth_user" } })
                {
                    c.CommandText = "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='tr_" + old[0] + "_rollup_update';";
                    string sql = (string)c.ExecuteScalar();
                    if (sql == null || !sql.Contains(old[1])) throw new InvalidOperationException("Unexpected schema-9 UPDATE trigger.");
                    c.CommandText = "DROP TRIGGER tr_" + old[0] + "_rollup_update;" + sql.Replace(old[1], old[2]) + ";";
                    c.ExecuteNonQuery();
                }
                c.CommandText = "UPDATE metadata SET value='8' WHERE key='schema_version';";
                c.ExecuteNonQuery();
                tx.Commit();
                return;
            }
            foreach (string table in new[] { "message_event", "smtp_transaction" })
            foreach (string operation in new[] { "insert", "update", "delete" })
            {
                c.CommandText = "DROP TRIGGER IF EXISTS tr_" + table + "_rollup_" + operation + ";";
                c.ExecuteNonQuery();
            }
            c.CommandText = "DROP TABLE IF EXISTS message_rollup; DROP TABLE IF EXISTS message_rollup_dirty;" +
                "DROP INDEX IF EXISTS ix_msg_identity_time; DROP INDEX IF EXISTS ix_smtp_identity_time;" +
                "DROP INDEX IF EXISTS ix_smtp_latest; DROP INDEX IF EXISTS ix_session_latest;";
            c.ExecuteNonQuery();
            foreach (string table in new[] { "message_event", "smtp_transaction" })
            {
                c.CommandText = "PRAGMA table_info(" + table + ");";
                bool hasHash = false;
                using (var r = c.ExecuteReader()) while (r.Read()) if (r.GetString(1) == "msg_hash") hasHash = true;
                if (version == 7 && !hasHash) throw new InvalidOperationException("Schema 7 fixtures require an existing hash column.");
                if (version == 7)
                {
                    // A real schema-7 database carries the hash-only index that schema 9 no longer creates.
                    c.CommandText = "CREATE INDEX IF NOT EXISTS " + (table == "message_event" ? "ix_msg_hash ON message_event" : "ix_smtp_hash ON smtp_transaction") + "(msg_hash);";
                    c.ExecuteNonQuery();
                }
                if (version != 6) continue;
                c.CommandText = "DROP TRIGGER IF EXISTS tr_" + table + "_hash_insert; DROP TRIGGER IF EXISTS tr_" + table + "_hash_update;" +
                    "DROP INDEX IF EXISTS " + (table == "message_event" ? "ix_msg_hash" : "ix_smtp_hash") + ";" +
                    (hasHash ? "ALTER TABLE " + table + " DROP COLUMN msg_hash;" : "");
                c.ExecuteNonQuery();
            }
            if (version == 6)
            {
                c.CommandText = "CREATE INDEX IF NOT EXISTS ix_msg_id ON message_event(message_id);" +
                    "CREATE INDEX IF NOT EXISTS ix_smtp_message ON smtp_transaction(message_id);" +
                    "DELETE FROM metadata WHERE key='message_hash_algorithm';";
                c.ExecuteNonQuery();
            }
            c.CommandText = "UPDATE metadata SET value=@version WHERE key='schema_version';";
            c.Parameters.AddWithValue("@version", version.ToString(System.Globalization.CultureInfo.InvariantCulture));
            c.ExecuteNonQuery();
            tx.Commit();
        }
    }

    /// <summary>
    /// A consistent copy of a store (SQLite backup), downgraded to the shape of an earlier schema (6 to 10) and left open on the returned connection
    /// (exl_msg_hash registered): the same data, as that schema stored it. Synthetic test fixtures only.
    /// </summary>
    public static SqliteConnection LegacyCopy(object store, string destination, int version)
    {
        var to = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = destination, Pooling = false }.ToString());
        to.Open();
        Connection(store).BackupDatabase(to);
        to.CreateFunction<string, long?>("exl_msg_hash", MessageHash, isDeterministic: true);
        ConvertToLegacySyntheticFixture(to, version);
        return to;
    }

    public static void Populate(object store, long epoch, int count)
    {
        using (var tx = Connection(store).BeginTransaction())
        using (var c = Connection(store).CreateCommand())
        {
            c.Transaction = tx;
            c.CommandText = @"WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<@n)
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,subject,recipient_count,total_bytes)
SELECT @t+i,'EX1','RECEIVE','<m'||i||'@invalid>','r'||i,'sender'||(i%30)||'@invalid','r@invalid',@subject,1,8192 FROM n;
INSERT INTO message_event(time_ms,server,event_id,message_id,log_id,sender,recipients,subject,recipient_count,total_bytes)
SELECT time_ms+1000,server,'DELIVER',message_id,'d'||id,sender,recipients,subject,1,total_bytes FROM message_event WHERE event_id='RECEIVE';";
            c.Parameters.AddWithValue("@n", count);
            c.Parameters.AddWithValue("@t", epoch);
            c.Parameters.AddWithValue("@subject", new string('s', 240));
            c.ExecuteNonQuery();
            store.GetType().GetMethod("ReconcileMessageRollups").Invoke(store, new object[] { tx });
            tx.Commit();
        }
    }

    public static void Schema7Copy(string source, string destination)
    {
        if (System.IO.File.Exists(destination)) throw new System.IO.IOException("Destination exists.");
        using (var from = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = source, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString()))
        using (var to = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = destination, Pooling = false }.ToString()))
        {
            from.Open(); to.Open(); from.BackupDatabase(to);
            to.CreateFunction<string, long?>("exl_msg_hash", MessageHash, isDeterministic: true);
            using (var tx = to.BeginTransaction())
            using (var c = to.CreateCommand())
            {
                c.Transaction = tx;
                c.CommandText = @"ALTER TABLE message_event ADD COLUMN msg_hash INTEGER;
ALTER TABLE smtp_transaction ADD COLUMN msg_hash INTEGER;
UPDATE message_event SET msg_hash=exl_msg_hash(message_id);
UPDATE smtp_transaction SET msg_hash=exl_msg_hash(message_id);
CREATE INDEX ix_msg_hash ON message_event(msg_hash);
CREATE INDEX ix_smtp_hash ON smtp_transaction(msg_hash);
DROP INDEX IF EXISTS ix_msg_id; DROP INDEX IF EXISTS ix_smtp_message;
INSERT INTO metadata VALUES('message_hash_algorithm','fnv1a64-utf8-v1');
UPDATE metadata SET value='7' WHERE key='schema_version';";
                c.ExecuteNonQuery(); tx.Commit();
            }
        }
    }

    static MethodInfo _messageHash;
    static long? MessageHash(string text)
    {
        if (_messageHash == null)
            foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
            {
                var type = assembly.GetType("ExchangeLogReport.Store", false);
                if (type != null) { _messageHash = type.GetMethod("MessageHash"); break; }
            }
        if (_messageHash == null) throw new InvalidOperationException("Load the in-memory engine before the fixture.");
        return (long?)_messageHash.Invoke(null, new object[] { text });
    }

    public static string RawGet(int port, string target, string host, string token)
    {
        using (var tcp = new System.Net.Sockets.TcpClient())
        {
            tcp.ReceiveTimeout = 10000;
            tcp.SendTimeout = 10000;
            tcp.Connect("127.0.0.1", port);
            using (var stream = tcp.GetStream())
            using (var writer = new System.IO.StreamWriter(stream, new System.Text.UTF8Encoding(false), 1024, true))
            using (var reader = new System.IO.StreamReader(stream))
            {
                writer.NewLine = "\r\n";
                writer.Write("GET " + target + " HTTP/1.1\r\nHost: " + host + "\r\nX-Portal-Token: " + token + "\r\nConnection: close\r\n\r\n");
                writer.Flush();
                return reader.ReadToEnd();
            }
        }
    }
}
