using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    public sealed partial class Store
    {
        /// <summary>
        /// Schema 11: kind is a code (0 message, 1 smtp), status/direction/servers/events are codes of message_rollup_value (NULL stays NULL for the three
        /// nullable ones), and first_ms/last_ms are NULL when they equal member_first_ms/member_last_ms (readers use COALESCE). The integrity constraint
        /// UNIQUE(kind,identity) of schema 10 is kept, and so is the UPSERT that relies on it.
        /// </summary>
        internal const string ServeRollupTableSql = @"CREATE TABLE message_rollup(
 id INTEGER PRIMARY KEY AUTOINCREMENT, kind INTEGER NOT NULL CHECK(kind IN(0,1)), identity TEXT COLLATE BINARY NOT NULL,
 msg_hash INTEGER, first_ms INTEGER, last_ms INTEGER,
 member_first_ms INTEGER NOT NULL, member_last_ms INTEGER NOT NULL, status INTEGER NOT NULL,
 sender TEXT, recipients TEXT NOT NULL, recipient_count INTEGER NOT NULL, delivered INTEGER NOT NULL,
 failed INTEGER NOT NULL, subject TEXT, size_kb INTEGER, direction INTEGER, servers INTEGER, events INTEGER,
 events_count INTEGER NOT NULL, smtp_count INTEGER NOT NULL, UNIQUE(kind,identity))";
        /// <summary>Schema 11: dictionary of the repeated text values of message_rollup (status, direction, servers, events). Codes are never reused.</summary>
        internal const string ServeRollupValueTableSql = "CREATE TABLE message_rollup_value(id INTEGER PRIMARY KEY, text TEXT NOT NULL UNIQUE)";
        /// <summary>The schema 8 to 10 shape (text columns), only used to move an older database forward.</summary>
        internal const string ServeRollupTableSql10 = @"CREATE TABLE message_rollup(
 id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, identity TEXT COLLATE BINARY NOT NULL,
 msg_hash INTEGER, first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL,
 member_first_ms INTEGER NOT NULL, member_last_ms INTEGER NOT NULL, status TEXT NOT NULL,
 sender TEXT, recipients TEXT NOT NULL, recipient_count INTEGER NOT NULL, delivered INTEGER NOT NULL,
 failed INTEGER NOT NULL, subject TEXT, size_kb INTEGER, direction TEXT, servers TEXT, events TEXT,
 events_count INTEGER NOT NULL, smtp_count INTEGER NOT NULL, UNIQUE(kind,identity))";
        internal const string ServeRollupDirtyTableSql = @"CREATE TABLE message_rollup_dirty(kind TEXT NOT NULL,identity TEXT COLLATE BINARY NOT NULL,msg_hash INTEGER,
 PRIMARY KEY(kind,identity)) WITHOUT ROWID";
        internal static readonly string[][] ServeRollupIndexes = {
            // Schema 9: "latest" lists read an ASCENDING index backwards (the rowid id is its implicit last key, so ORDER BY x DESC,id DESC
            // needs no sorter); inserts in time order then append to the right-most page instead of splitting half-empty pages of a DESC index.
            new[] { "ix_rollup_last", "message_rollup", "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms)" },
            // Schema 11: status is a code, compared by equality (the filter is resolved to codes first): no collation.
            new[] { "ix_rollup_status_last", "message_rollup", "CREATE INDEX ix_rollup_status_last ON message_rollup(status,member_last_ms)" },
            // Schema 10: the identity indexes hold the hash and the time only (the rowid id is the implicit last key, so ORDER BY time_ms,id needs no sorter).
            // The hash is a lookup accelerator, never an identity: every lookup compares message_id COLLATE BINARY on the table row.
            new[] { "ix_msg_identity_time", "message_event", "CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,time_ms)" },
            new[] { "ix_smtp_identity_time", "smtp_transaction", "CREATE INDEX ix_smtp_identity_time ON smtp_transaction(msg_hash,time_ms)" }
            // Schema 11 no longer has ix_smtp_latest: ix_smtp_flow starts with time_ms and serves the same ordered reads.
        };
        /// <summary>The schema 8 to 10 index set (status with NOCASE, ix_smtp_latest), only used to move an older database forward.</summary>
        internal static readonly string[][] ServeRollupIndexes10 = {
            new[] { "ix_rollup_last", "message_rollup", "CREATE INDEX ix_rollup_last ON message_rollup(member_last_ms)" },
            new[] { "ix_rollup_status_last", "message_rollup", "CREATE INDEX ix_rollup_status_last ON message_rollup(status COLLATE NOCASE,member_last_ms)" },
            new[] { "ix_msg_identity_time", "message_event", "CREATE INDEX ix_msg_identity_time ON message_event(msg_hash,time_ms)" },
            new[] { "ix_smtp_identity_time", "smtp_transaction", "CREATE INDEX ix_smtp_identity_time ON smtp_transaction(msg_hash,time_ms)" },
            new[] { "ix_smtp_latest", "smtp_transaction", "CREATE INDEX ix_smtp_latest ON smtp_transaction(time_ms)" }
        };
        /// <summary>Schema 10: one row per distinct '#Fields' header text of the log files; source_file.fields_id points at it.</summary>
        internal const string SourceFieldsTableSql = "CREATE TABLE source_fields(id INTEGER PRIMARY KEY, text TEXT NOT NULL UNIQUE)";
        /// <summary>Objects dropped by schema 9 (strict prefixes of the identity_time indexes, the DESC session index) and by schema 11 (ix_smtp_latest, served by ix_smtp_flow).</summary>
        static readonly string[] ObsoleteServeIndexes = { "ix_msg_hash", "ix_smtp_hash", "ix_session_latest", "ix_smtp_latest" };
        static readonly string[] ObsoleteServeIndexes10 = { "ix_msg_hash", "ix_smtp_hash", "ix_session_latest" };
        internal const int MessageKindMessage = 0, MessageKindSmtp = 1;

        internal static string ServeRollupTriggerSql(string table, string operation)
        {
            string body = "";
            foreach (string row in operation == "UPDATE" ? new[] { "OLD", "NEW" } : new[] { operation == "DELETE" ? "OLD" : "NEW" })
            {
                body += "INSERT INTO message_rollup_dirty SELECT 'message'," + row + ".message_id,exl_msg_hash(" + row + ".message_id) WHERE " + row + ".message_id IS NOT NULL ON CONFLICT(kind,identity) DO UPDATE SET msg_hash=excluded.msg_hash;";
                if (table == "smtp_transaction")
                    body += "INSERT OR IGNORE INTO message_rollup_dirty SELECT 'smtp',CAST(" + row + ".id AS TEXT),NULL WHERE " + row + ".message_id IS NULL;";
            }
            string update = operation == "UPDATE" ? (table == "message_event"
                ? " OF id,message_id,time_ms,server,event_id,sender,recipients,recipient_count,total_bytes,subject,directionality"
                : " OF id,message_id,time_ms,end_ms,server,direction,mail_from,rcpts,status") : "";
            return "CREATE TRIGGER tr_" + table + "_rollup_" + operation.ToLowerInvariant() +
                " AFTER " + operation + update + " ON " + table + " BEGIN " + body + " END";
        }

        /// <summary>
        /// Schema 6/7 to the current schema in one transaction: the derived tables are created directly in the schema-11 shape (codes, dictionary),
        /// filled by the reconciliation, and the SMTP client structures are built from the stored transactions. Same objects as a fresh database.
        /// </summary>
        void MigrateServeRollups()
        {
            if (StoredSchemaVersion() >= 8) return;
            Exec("PRAGMA temp_store=FILE;");
            try
            {
                using (var tx = Begin())
                {
                    using (var c = Command(ServeRollupTableSql + ";" + ServeRollupValueTableSql + ";" + ServeRollupDirtyTableSql + ";", tx)) c.ExecuteNonQuery();
                    foreach (string name in ObsoleteServeIndexes)   // a schema-7 database still has its hash-only indexes
                        using (var c = Command("DROP INDEX IF EXISTS " + name + ";", tx)) c.ExecuteNonQuery();
                    foreach (var index in ServeRollupIndexes)
                        using (var c = Command(index[2] + ";", tx)) c.ExecuteNonQuery();
                    using (var c = Command(@"
INSERT OR IGNORE INTO message_rollup_dirty SELECT 'message',message_id,msg_hash FROM message_event WHERE message_id IS NOT NULL;
INSERT OR IGNORE INTO message_rollup_dirty SELECT 'message',message_id,msg_hash FROM smtp_transaction WHERE message_id IS NOT NULL;
INSERT OR IGNORE INTO message_rollup_dirty SELECT 'smtp',CAST(id AS TEXT),NULL FROM smtp_transaction WHERE message_id IS NULL;", tx))
                        c.ExecuteNonQuery();
                    foreach (string table in new[] { "message_event", "smtp_transaction" })
                    foreach (string operation in new[] { "INSERT", "UPDATE", "DELETE" })
                    {
                        using (var c = Command(ServeRollupTriggerSql(table, operation) + ";", tx)) c.ExecuteNonQuery();
                    }
                    ReconcileMessageRollupsCore(tx);
                    // These objects already have the current shape (ServeRollupIndexes / ServeRollupTriggerSql), so a schema 6/7 database ends directly at 11.
                    MigrateSourceFields(tx);
                    BuildSmtpClients(tx);
                    using (var c = Command("INSERT INTO metadata VALUES('schema_version','" + SchemaVersion + "') ON CONFLICT(key) DO UPDATE SET value=excluded.value;", tx)) c.ExecuteNonQuery();
                    tx.Commit();
                }
            }
            finally { Exec("PRAGMA temp_store=MEMORY;"); }
        }

        /// <summary>
        /// Schema 10 (from a committed schema 8 or 9), one transaction (an interrupted upgrade restarts from the old schema):
        ///  - schema 9 changes, when coming from 8: drop the redundant hash-only indexes and ix_session_latest, rebuild the DESC "latest" indexes
        ///    ascending and narrow the rollup UPDATE triggers;
        ///  - schema 10 changes: ix_msg_identity_time / ix_smtp_identity_time keep (msg_hash,time_ms) only, and the '#Fields' header text of
        ///    source_file moves into the source_fields dictionary (MigrateSourceFields).
        /// No source row, no message_rollup row and no dirty-queue row changes, so no reconciliation runs. Each index/trigger is replaced only
        /// when its stored definition differs from the canonical one (a database that already has the shape is not rebuilt).
        /// The shape is the schema-10 one (text columns, ix_smtp_latest); MigrateSchema11 then moves it to the current shape.
        /// </summary>
        void MigrateServeSchema10()
        {
            if (StoredSchemaVersion() >= 10) return;
            using (var tx = Begin())
            {
                foreach (string name in ObsoleteServeIndexes10)
                    using (var c = Command("DROP INDEX IF EXISTS " + name + ";", tx)) c.ExecuteNonQuery();
                foreach (var index in ServeRollupIndexes10)
                    if (!SchemaObjectIs("index", index[0], index[2], tx))
                        using (var c = Command("DROP INDEX IF EXISTS " + index[0] + ";" + index[2] + ";", tx)) c.ExecuteNonQuery();
                foreach (string table in new[] { "message_event", "smtp_transaction" })
                foreach (string operation in new[] { "INSERT", "UPDATE", "DELETE" })
                {
                    string name = "tr_" + table + "_rollup_" + operation.ToLowerInvariant(), sql = ServeRollupTriggerSql(table, operation);
                    if (!SchemaObjectIs("trigger", name, sql, tx))
                        using (var c = Command("DROP TRIGGER IF EXISTS " + name + ";" + sql + ";", tx)) c.ExecuteNonQuery();
                }
                MigrateSourceFields(tx);
                using (var c = Command("INSERT INTO metadata VALUES('schema_version','10') ON CONFLICT(key) DO UPDATE SET value=excluded.value;", tx)) c.ExecuteNonQuery();
                tx.Commit();
            }
        }

        /// <summary>
        /// Schema 11 (from a committed schema 10), ONE transaction for both parts; any failure rolls back everything and the database stays at schema 10:
        ///  - message_rollup moves to codes (kind, status, direction, servers, events), first_ms/last_ms become NULL when equal to member_first_ms/member_last_ms,
        ///    ids and the AUTOINCREMENT sequence are preserved, and the new rows are compared with the old ones (decoded) before the old table is dropped;
        ///  - the SMTP client structures (BuildSmtpClients) are derived from the stored transactions and proved by a recomputation;
        ///  - ix_smtp_latest is dropped (ix_smtp_flow starts with time_ms).
        /// UNIQUE(kind,identity) is kept. The migration rewrites message_rollup and the client_id of every SMTP transaction: free disk space for the write-ahead log
        /// (about the size of those tables, several GB on a very large database) is required, and the database is unusable by Serve until it is over.
        /// </summary>
        void MigrateSchema11()
        {
            if (StoredSchemaVersion() >= 11) return;
            Exec("PRAGMA temp_store=FILE;");
            try
            {
                using (var tx = Begin())
                {
                    MigrateRollupToCodes(tx);
                    BuildSmtpClients(tx);
                    using (var c = Command("DROP INDEX IF EXISTS ix_smtp_latest;", tx)) c.ExecuteNonQuery();
                    using (var c = Command("INSERT INTO metadata VALUES('schema_version','" + SchemaVersion + "') ON CONFLICT(key) DO UPDATE SET value=excluded.value;", tx)) c.ExecuteNonQuery();
                    tx.Commit();
                }
            }
            finally { Exec("PRAGMA temp_store=MEMORY;"); }
        }

        void MigrateRollupToCodes(SqliteTransaction tx)
        {
            // The AUTOINCREMENT sequence is read BEFORE the old table is dropped (dropping it deletes its sqlite_sequence row): URL ids are never reused.
            long? oldSequence = null;
            using (var c = Command("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';", tx))
            { object v = c.ExecuteScalar(); if (v != null && !(v is DBNull)) oldSequence = Convert.ToInt64(v, CultureInfo.InvariantCulture); }
            long oldRows;
            using (var c = Command("SELECT COUNT(*) FROM message_rollup;", tx)) oldRows = Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture);
            Exec(tx, ServeRollupValueTableSql + ";");
            // One scan for the distinct combinations, then the dictionary in text order.
            Exec(tx, "CREATE TEMP TABLE message_rollup_distinct AS SELECT DISTINCT status,direction,servers,events FROM message_rollup;" +
                "INSERT INTO message_rollup_value(text) SELECT v FROM (SELECT status v FROM message_rollup_distinct UNION SELECT direction FROM message_rollup_distinct " +
                "UNION SELECT servers FROM message_rollup_distinct UNION SELECT events FROM message_rollup_distinct) WHERE v IS NOT NULL ORDER BY v;" +
                "DROP TABLE temp.message_rollup_distinct;");
            Exec(tx, "DROP INDEX IF EXISTS ix_rollup_last; DROP INDEX IF EXISTS ix_rollup_status_last; ALTER TABLE message_rollup RENAME TO message_rollup_10;");
            // The canonical definition is created under its own name (a RENAME would store a quoted name that no longer matches it).
            Exec(tx, ServeRollupTableSql + ";");
            Exec(tx, @"INSERT INTO message_rollup(id,kind,identity,msg_hash,first_ms,last_ms,member_first_ms,member_last_ms,status,sender,recipients,recipient_count,delivered,failed,subject,size_kb,direction,servers,events,events_count,smtp_count)
SELECT r.id,CASE r.kind WHEN 'message' THEN 0 WHEN 'smtp' THEN 1 END,r.identity,r.msg_hash,NULLIF(r.first_ms,r.member_first_ms),NULLIF(r.last_ms,r.member_last_ms),r.member_first_ms,r.member_last_ms,
 s.id,r.sender,r.recipients,r.recipient_count,r.delivered,r.failed,r.subject,r.size_kb,d.id,v.id,x.id,r.events_count,r.smtp_count
FROM message_rollup_10 r JOIN message_rollup_value s ON s.text=r.status LEFT JOIN message_rollup_value d ON d.text=r.direction LEFT JOIN message_rollup_value v ON v.text=r.servers LEFT JOIN message_rollup_value x ON x.text=r.events ORDER BY r.id;");
            long newRows;
            using (var c = Command("SELECT COUNT(*) FROM message_rollup;", tx)) newRows = Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture);
            if (newRows != oldRows) throw new InvalidOperationException("The schema 11 migration copied " + newRows.ToString(CultureInfo.InvariantCulture) + " of " + oldRows.ToString(CultureInfo.InvariantCulture) + " message_rollup rows; it was rolled back.");
            using (var c = Command(@"SELECT COUNT(*) FROM message_rollup_10 p LEFT JOIN message_rollup n ON n.id=p.id
 LEFT JOIN message_rollup_value s ON s.id=n.status LEFT JOIN message_rollup_value d ON d.id=n.direction LEFT JOIN message_rollup_value v ON v.id=n.servers LEFT JOIN message_rollup_value x ON x.id=n.events
WHERE n.id IS NULL OR NOT (p.kind IS CASE n.kind WHEN 0 THEN 'message' WHEN 1 THEN 'smtp' END AND p.identity IS n.identity AND p.msg_hash IS n.msg_hash
 AND p.first_ms IS COALESCE(n.first_ms,n.member_first_ms) AND p.last_ms IS COALESCE(n.last_ms,n.member_last_ms) AND (n.first_ms IS NULL)=(p.first_ms IS p.member_first_ms) AND (n.last_ms IS NULL)=(p.last_ms IS p.member_last_ms)
 AND p.member_first_ms IS n.member_first_ms AND p.member_last_ms IS n.member_last_ms AND p.status IS s.text AND p.sender IS n.sender AND p.recipients IS n.recipients
 AND p.recipient_count IS n.recipient_count AND p.delivered IS n.delivered AND p.failed IS n.failed AND p.subject IS n.subject AND p.size_kb IS n.size_kb
 AND p.direction IS d.text AND p.servers IS v.text AND p.events IS x.text AND p.events_count IS n.events_count AND p.smtp_count IS n.smtp_count);", tx))
                if (Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture) != 0)
                    throw new InvalidOperationException("A message_rollup row does not decode to its schema 10 value; the schema 11 migration was rolled back.");
            Exec(tx, "DROP TABLE message_rollup_10;");
            if (oldSequence.HasValue)
            {
                // The new table's sequence follows the largest inserted id; it must never be lower than the old one (an id that was used is never reused).
                using (var c = Command("UPDATE sqlite_sequence SET seq=MAX(seq,@s) WHERE name='message_rollup';", tx)) { c.Parameters.AddWithValue("@s", oldSequence.Value); c.ExecuteNonQuery(); }
                using (var c = Command("INSERT INTO sqlite_sequence(name,seq) SELECT 'message_rollup',@s WHERE NOT EXISTS(SELECT 1 FROM sqlite_sequence WHERE name='message_rollup');", tx)) { c.Parameters.AddWithValue("@s", oldSequence.Value); c.ExecuteNonQuery(); }
            }
            foreach (var index in ServeRollupIndexes)
                if (index[1] == "message_rollup") Exec(tx, index[2] + ";");
        }

        /// <summary>
        /// Schema 10, inside the caller's migration transaction: the distinct '#Fields' texts of source_file go to source_fields (ids in text order),
        /// source_file.fields_id points at them, and ONLY AFTER every row has been compared byte for byte with its dictionary text is the old
        /// source_file.fields cleared. A mismatch aborts (and rolls back) the whole migration. Readers use COALESCE(dictionary text, fields), so a
        /// row without fields_id (a non-text value, or a row written by an external tool) keeps being read from its own column.
        /// </summary>
        void MigrateSourceFields(SqliteTransaction tx)
        {
            bool column = false;
            using (var c = Command("PRAGMA table_info(source_file);", tx))
            using (var r = c.ExecuteReader()) while (r.Read()) if (string.Equals(r.GetString(1), "fields_id", StringComparison.OrdinalIgnoreCase)) column = true;
            using (var c = Command("CREATE TABLE IF NOT EXISTS " + SourceFieldsTableSql.Substring("CREATE TABLE ".Length) + ";" + (column ? "" : "ALTER TABLE source_file ADD COLUMN fields_id INTEGER;"), tx)) c.ExecuteNonQuery();
            using (var c = Command(@"INSERT OR IGNORE INTO source_fields(text) SELECT fields FROM source_file WHERE fields IS NOT NULL AND typeof(fields)='text' GROUP BY fields ORDER BY fields;
UPDATE source_file SET fields_id=(SELECT d.id FROM source_fields d WHERE d.text=source_file.fields) WHERE fields_id IS NULL AND fields IS NOT NULL AND typeof(fields)='text';", tx)) c.ExecuteNonQuery();
            using (var c = Command(@"SELECT COUNT(*) FROM source_file s WHERE s.fields IS NOT NULL AND typeof(s.fields)='text'
 AND NOT EXISTS(SELECT 1 FROM source_fields d WHERE d.id=s.fields_id AND d.text=s.fields);", tx))
                if (Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture) != 0)
                    throw new InvalidOperationException("A source_file header text does not match its source_fields dictionary entry; the schema 10 migration was rolled back.");
            using (var c = Command("UPDATE source_file SET fields=NULL WHERE fields_id IS NOT NULL AND fields IS NOT NULL;", tx)) c.ExecuteNonQuery();
            using (var c = Command("SELECT COUNT(*) FROM source_file s WHERE s.fields_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM source_fields d WHERE d.id=s.fields_id);", tx))
                if (Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture) != 0)
                    throw new InvalidOperationException("A source_file row points at a missing source_fields entry; the schema 10 migration was rolled back.");
        }

        bool SchemaObjectIs(string type, string name, string sql, SqliteTransaction tx)
        {
            using (var c = Command("SELECT sql FROM sqlite_master WHERE type=@t AND name=@n;", tx))
            {
                c.Parameters.AddWithValue("@t", type); c.Parameters.AddWithValue("@n", name);
                return string.Equals((c.ExecuteScalar() as string ?? "").Trim().TrimEnd(';'), sql, StringComparison.Ordinal);
            }
        }

        /// <summary>Explicitly reconcile committed writable changes. Never called by verification or Serve.</summary>
        public void RefreshServeRollups()
        {
            if (ReadOnly) throw new InvalidOperationException("Explicit rollup refresh requires a writable store.");
            using (var tx = Begin()) { ReconcileMessageRollups(tx); tx.Commit(); }
        }


        /// <summary>Rollup identities drained by the latest ReconcileMessageRollups call (collection statistics only).</summary>
        internal long LastReconciledKeys { get; private set; }

        /// <summary>
        /// Drain durable invalidations before the collector publishes its transaction. Never called by Serve. The SMTP client work queued by the
        /// triggers (schema 11) is drained first, so one call leaves every derived structure consistent.
        /// </summary>
        public void ReconcileMessageRollups(SqliteTransaction transaction)
        {
            if (ReadOnly) throw new InvalidOperationException("Rollup reconciliation requires a writable collection transaction.");
            if (transaction == null) throw new ArgumentNullException(nameof(transaction));
            ReconcileSmtpClients(transaction);
            ReconcileMessageRollupsCore(transaction);
        }

        /// <summary>The message_rollup part of the reconciliation (also used by the migration, before the SMTP client structures exist).</summary>
        void ReconcileMessageRollupsCore(SqliteTransaction transaction)
        {
            LastReconciledKeys = 0;
            SqliteCommand select = null;
            try
            {
                using (var reconciler = new RollupReconciler(this, transaction))
                while (true)
                {
                    var batch = new List<object[]>();
                    if (select == null) select = Command("SELECT kind,identity,msg_hash FROM message_rollup_dirty ORDER BY kind,identity LIMIT 128;", transaction);
                    using (var r = select.ExecuteReader()) while (r.Read()) batch.Add(new object[] { r.GetString(0), r.GetString(1), r.IsDBNull(2) ? (object)DBNull.Value : r.GetInt64(2) });
                    if (batch.Count == 0) break;
                    LastReconciledKeys += batch.Count;
                    foreach (var key in batch) reconciler.Key(key, true);
                }
            }
            finally { if (select != null) select.Dispose(); }
        }

        /// <summary>
        /// Reconciles keys the caller still holds in memory (a collection that writes the invalidations itself, queue empty): same result as queueing them in
        /// message_rollup_dirty and calling ReconcileMessageRollups, without writing and deleting the queue rows. The keys are those the queue would hold
        /// ('message', Message-ID, msg_hash from hashes) and ('smtp', rowid as text, NULL); the caller sorts them as the queue would be read (ORDER BY
        /// kind,identity: messages by CompareUtf8Binary, then rowids by CompareDecimalText), because message_rollup ids follow that order.
        /// </summary>
        internal void ReconcileMessageRollupKeys(SqliteTransaction transaction, string[] messages, Dictionary<string, long?> hashes, long[] smtp)
        {
            if (ReadOnly) throw new InvalidOperationException("Rollup reconciliation requires a writable collection transaction.");
            if (transaction == null) throw new ArgumentNullException(nameof(transaction));
            LastReconciledKeys = 0;
            if (messages.Length == 0 && smtp.Length == 0) return;
            using (var reconciler = new RollupReconciler(this, transaction))
            {
                foreach (var id in messages) reconciler.Key("message", id, hashes[id]);
                foreach (long id in smtp) reconciler.Key("smtp", id.ToString(CultureInfo.InvariantCulture), null);
            }
            LastReconciledKeys = messages.Length + smtp.Length;
        }

        static readonly long[] Pow10 = { 1L, 10L, 100L, 1000L, 10000L, 100000L, 1000000L, 10000000L, 100000000L, 1000000000L, 10000000000L, 100000000000L,
            1000000000000L, 10000000000000L, 100000000000000L, 1000000000000000L, 10000000000000000L, 100000000000000000L, 1000000000000000000L };

        static int DecimalDigits(long v)   // v >= 0
        {
            int n = 1;
            while (n < Pow10.Length && v >= Pow10[n]) n++;
            return n;
        }

        /// <summary>
        /// Order of the decimal texts of two integers (string.CompareOrdinal of their ToString, the BINARY order of the ASCII digits), without the texts:
        /// with as many digits, the order of the numbers; otherwise the shorter one against the same number of leading digits of the longer one, the
        /// shorter first when they are equal (a prefix). Negative numbers (never a rowid of the collection) are compared through their texts.
        /// </summary>
        internal static int CompareDecimalText(long a, long b)
        {
            if (a == b) return 0;
            if (a < 0 || b < 0) return string.CompareOrdinal(a.ToString(CultureInfo.InvariantCulture), b.ToString(CultureInfo.InvariantCulture));
            int da = DecimalDigits(a), db = DecimalDigits(b);
            if (da == db) return a < b ? -1 : 1;
            if (da < db) { long head = b / Pow10[db - da]; return a <= head ? -1 : 1; }
            long lead = a / Pow10[da - db];
            return lead < b ? -1 : 1;
        }

        /// <summary>
        /// Stopwatch ticks spent by the rollup reconciliations of this store (cumulative, apply thread): reading the rows of the keys, and writing their
        /// rollup rows (dictionary codes, recipients JSON, upsert or delete, queue row). The collection statistics show the difference over a run.
        /// </summary>
        internal long RollupReadTicks, RollupWriteTicks;

        /// <summary>
        /// Order of SQLite's BINARY collation (memcmp of the UTF-8 bytes), which is the order of the code points. string.CompareOrdinal compares UTF-16
        /// units and would put a surrogate pair (U+10000 and above) before U+E000..U+FFFF.
        /// </summary>
        public static int CompareUtf8Binary(string a, string b)
        {
            int n = Math.Min(a.Length, b.Length);
            for (int i = 0; i < n; i++)
            {
                int x = a[i], y = b[i];
                if (x == y) continue;
                // Surrogates (D800..DFFF) move above E000..FFFF, the way their code points sort.
                if (x >= 0xD800 && y >= 0xD800) { x = x >= 0xE000 ? x - 0x800 : x + 0x2000; y = y >= 0xE000 ? y - 0x800 : y + 0x2000; }
                return x < y ? -1 : 1;
            }
            return a.Length == b.Length ? 0 : a.Length < b.Length ? -1 : 1;
        }

        /// <summary>
        /// Reconciles the message_rollup_dirty queue in transactions of at most chunkKeys keys (the end of a collection that deferred the rollups): each chunk
        /// is committed, so an interruption leaves the rest queued (Serve answers 503 until it is drained). Stops between chunks when cancel is set.
        /// afterChunk (optional) runs after each commit, outside any transaction (the collection bounds the WAL there). Returns the keys drained.
        /// </summary>
        public long DrainMessageRollups(int chunkKeys, System.Threading.CancellationToken cancel) { return DrainMessageRollups(chunkKeys, cancel, null); }

        public long DrainMessageRollups(int chunkKeys, System.Threading.CancellationToken cancel, Action afterChunk)
        {
            if (ReadOnly) throw new InvalidOperationException("Rollup reconciliation requires a writable store.");
            if (chunkKeys < 1) throw new ArgumentOutOfRangeException(nameof(chunkKeys));
            long drained = 0;
            Exec("PRAGMA temp_store=FILE;");
            try
            {
                while (!cancel.IsCancellationRequested)
                {
                    using (var tx = Begin())
                    {
                        var keys = new List<object[]>();
                        using (var c = Command("SELECT kind,identity,msg_hash FROM message_rollup_dirty ORDER BY kind,identity LIMIT @n;", tx))
                        {
                            c.Parameters.AddWithValue("@n", chunkKeys);
                            using (var r = c.ExecuteReader()) while (r.Read()) keys.Add(new object[] { r.GetString(0), r.GetString(1), r.IsDBNull(2) ? (object)DBNull.Value : r.GetInt64(2) });
                        }
                        if (keys.Count == 0) break;
                        ReconcileSmtpClients(tx);
                        using (var reconciler = new RollupReconciler(this, tx))
                            foreach (var key in keys) reconciler.Key(key, true);
                        tx.Commit();
                        drained += keys.Count;
                    }
                    if (afterChunk != null) afterChunk();
                }
            }
            finally { Exec("PRAGMA temp_store=MEMORY;"); }
            LastReconciledKeys = drained;
            return drained;
        }

        /// <summary>
        /// State of one reconciliation, shared by the queue drain and the in-memory key path: the dictionary of the repeated texts (loaded once, new texts are
        /// appended, codes are never reused), the statements prepared once and bound by index, and the cached source readers.
        /// </summary>
        sealed class RollupReconciler : IDisposable
        {
            sealed class Source { public SqliteCommand Command; public SqliteParameter M, H, Sid; public long Key; }

            readonly Store _store;
            readonly SqliteTransaction _tx;
            readonly Dictionary<string, long> _codes = new Dictionary<string, long>(StringComparer.Ordinal);
            // The source readers hand back the same cached command for the same SQL; its parameters are bound once per key.
            readonly Dictionary<string, Source> _sources = new Dictionary<string, Source>(StringComparer.Ordinal);
            SqliteCommand _addValue;
            Prepared _delete, _upsert, _clear;
            ReportBuilder.RollupReads _reads;   // the two reads of every message key, as raw statements (null: RawRollupReads off)
            object[] _current;
            long _currentKey;
            // The recipients JSON of every key, through one writer: the same text as JsonSerializer.Serialize (same writer, default encoder).
            readonly System.Buffers.ArrayBufferWriter<byte> _jsonBuffer = new System.Buffers.ArrayBufferWriter<byte>(1024);
            Utf8JsonWriter _json;

            public RollupReconciler(Store store, SqliteTransaction tx)
            {
                _store = store; _tx = tx;
                using (var c = store.Command("SELECT id,text FROM message_rollup_value;", tx))
                using (var r = c.ExecuteReader()) while (r.Read()) _codes[r.GetString(1)] = r.GetInt64(0);
            }

            object Code(object text)
            {
                if (text == null || text is DBNull) return DBNull.Value;
                string value = text as string ?? Convert.ToString(text, CultureInfo.InvariantCulture);
                long id;
                if (_codes.TryGetValue(value, out id)) return id;
                if (_addValue == null) { _addValue = _store.Command("INSERT INTO message_rollup_value(text) VALUES(@t) RETURNING id;", _tx); _addValue.Parameters.Add("@t", SqliteType.Text); }
                _addValue.Parameters["@t"].Value = value;
                id = Convert.ToInt64(_addValue.ExecuteScalar(), CultureInfo.InvariantCulture);
                _codes[value] = id;
                return id;
            }

            /// <summary>
            /// Binds the recipients JSON as the UTF-8 bytes the writer produced: the bytes the text of those bytes would be encoded to (the writer
            /// escapes every non-ASCII character), without the string and its encoding again.
            /// </summary>
            void BindJson(Prepared statement, int index, object value)
            {
                var list = value as string[];
                if (list == null) { statement.Set(index, JsonSerializer.Serialize(value)); return; }
                _jsonBuffer.Clear();
                if (_json == null) _json = new Utf8JsonWriter(_jsonBuffer); else _json.Reset(_jsonBuffer);
                _json.WriteStartArray();
                foreach (var x in list) _json.WriteStringValue(x);
                _json.WriteEndArray();
                _json.Flush();
                statement.SetUtf8(index, _jsonBuffer.WrittenSpan);
            }

            SqliteCommand SourceFor(string sql)
            {
                Source s;
                if (!_sources.TryGetValue(sql, out s))
                {
                    s = new Source { Command = _store.Command(sql, _tx), Key = -1 };
                    s.M = s.Command.Parameters.Add("@m", SqliteType.Text); s.H = s.Command.Parameters.Add("@h", SqliteType.Integer); s.Sid = s.Command.Parameters.Add("@sid", SqliteType.Integer);
                    _sources.Add(sql, s);
                }
                if (s.Key != _currentKey)
                {
                    s.M.Value = _current[1]; s.H.Value = _current[2];
                    s.Sid.Value = (string)_current[0] == "smtp" ? long.Parse((string)_current[1], CultureInfo.InvariantCulture) : 0L;
                    s.Key = _currentKey;
                }
                return s.Command;
            }

            readonly object[] _memoryKey = new object[3];

            /// <summary>A key held in memory, through the array Key(object[]) reads (filled again for every key; nothing keeps it after the call).</summary>
            public void Key(string kind, string identity, long? hash)
            {
                _memoryKey[0] = kind; _memoryKey[1] = identity; _memoryKey[2] = hash.HasValue ? (object)hash.Value : DBNull.Value;
                Key(_memoryKey, false);
            }

            /// <summary>Recomputes the rollup row of one key ({ kind, identity, msg_hash or DBNull }); with clearQueue also deletes the key from message_rollup_dirty.</summary>
            public void Key(object[] key, bool clearQueue)
            {
                if (_upsert == null)
                {
                    _delete = new Prepared(_store, "DELETE FROM message_rollup WHERE kind=@p0 AND identity=@p1;", 2);
                    _clear = new Prepared(_store, "DELETE FROM message_rollup_dirty WHERE kind=@p0 AND identity=@p1;", 2);
                    _upsert = new Prepared(_store, @"INSERT INTO message_rollup(kind,identity,msg_hash,first_ms,last_ms,member_first_ms,member_last_ms,status,sender,recipients,recipient_count,delivered,failed,subject,size_kb,direction,servers,events,events_count,smtp_count)
VALUES(@p0,@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,@p9,@p10,@p11,@p12,@p13,@p14,@p15,@p16,@p17,@p18,@p19)
ON CONFLICT(kind,identity) DO UPDATE SET first_ms=excluded.first_ms,last_ms=excluded.last_ms,member_first_ms=excluded.member_first_ms,member_last_ms=excluded.member_last_ms,status=excluded.status,sender=excluded.sender,
recipients=excluded.recipients,recipient_count=excluded.recipient_count,delivered=excluded.delivered,failed=excluded.failed,subject=excluded.subject,size_kb=excluded.size_kb,
direction=excluded.direction,servers=excluded.servers,events=excluded.events,events_count=excluded.events_count,smtp_count=excluded.smtp_count;", 20);
                    if (RawRollupReads) _reads = new ReportBuilder.RollupReads(_store);
                }
                _current = key; _currentKey++;
                string kind = (string)key[0], identity = (string)key[1];
                long events;
                long? smtpFirst, smtpLast;
                if (_reads != null) _reads.Hash = key[2];
                long mark = System.Diagnostics.Stopwatch.GetTimestamp();
                var row = ReportBuilder.ReadServeRollupBounds(SourceFor, kind, identity, true, out events, out smtpFirst, out smtpLast, _reads);
                long read = System.Diagnostics.Stopwatch.GetTimestamp();
                _store.RollupReadTicks += read - mark;
                // The queue keeps the text kind; the table keeps its code.
                long kindCode = kind == "smtp" ? MessageKindSmtp : MessageKindMessage;
                if (row == null)
                {
                    _delete.Set(0, kindCode); _delete.Set(1, identity);
                    _delete.Run();
                }
                else
                {
                    var u = _upsert;
                    u.Set(0, kindCode); u.Set(1, identity); u.Set(2, key[2]);
                    long firstMs = Convert.ToInt64(row[0], CultureInfo.InvariantCulture), lastMs = Convert.ToInt64(row[1], CultureInfo.InvariantCulture);
                    long memberFirst = firstMs, memberLast = lastMs;
                    // The SMTP bounds come from the same rows as smtp_count (one query in ReadServeRollupBounds).
                    if (smtpFirst.HasValue) { memberFirst = Math.Min(memberFirst, smtpFirst.Value); memberLast = Math.Max(memberLast, smtpLast.Value); }
                    // first_ms / last_ms are stored only when they differ from the member bounds (readers COALESCE them).
                    u.Set(3, firstMs == memberFirst ? DBNull.Value : (object)firstMs);
                    u.Set(4, lastMs == memberLast ? DBNull.Value : (object)lastMs);
                    u.Set(5, memberFirst); u.Set(6, memberLast);
                    // status, direction, servers and events are dictionary codes.
                    u.Set(7, Code(row[3])); u.Set(8, row[4] ?? DBNull.Value); BindJson(u, 9, row[5]);
                    u.Set(10, row[6] ?? DBNull.Value); u.Set(11, row[7] ?? DBNull.Value); u.Set(12, row[8] ?? DBNull.Value);
                    u.Set(13, row[9] ?? DBNull.Value); u.Set(14, row[10] ?? DBNull.Value);
                    u.Set(15, Code(row[11])); u.Set(16, Code(row[12])); u.Set(17, Code(row[13]));
                    u.Set(18, events); u.Set(19, row[14] ?? DBNull.Value);
                    u.Run();
                }
                if (clearQueue)
                {
                    _clear.Set(0, kind); _clear.Set(1, identity);   // the dirty queue keeps the text kind
                    _clear.Run();
                }
                _store.RollupWriteTicks += System.Diagnostics.Stopwatch.GetTimestamp() - read;
            }

            public void Dispose()
            {
                foreach (var s in _sources.Values) s.Command.Dispose();
                if (_addValue != null) _addValue.Dispose();
                foreach (var p in new[] { _delete, _upsert, _clear }) if (p != null) p.Dispose();
                if (_reads != null) _reads.Dispose();
                if (_json != null) _json.Dispose();
            }
        }

        /// <summary>
        /// The reconciliation reads the rows of a message key through raw statements (RollupReads); false: through Microsoft.Data.Sqlite, the
        /// reference path that Serve and the verification use (tests compare both).
        /// </summary>
        internal static bool RawRollupReads = true;
    }

    public static partial class ReportBuilder
    {
        internal static readonly string[] ServeMessageColumns = {
            "First event:time", "Last event:time", "Duration:text", "Status:text", "Sender:text", "Recipients:list",
            "Recipient count:num", "Delivered:num", "Failed:num", "Subject:text", "Size (KB):num", "Direction:text",
            "Servers:text", "Events:text", "SMTP sessions:num", "Message ID:text", "Route:steps", "SMTP transcripts:steps"
        };

        /// <param name="dispose">false when the supplied command is a cached, reusable prepared statement owned by the caller.</param>
        internal static IEnumerable<object[]> ServeRows(Func<string, SqliteCommand> command, string sql, bool dispose = true)
        {
            var c = command(sql);
            try
            {
                using (var r = c.ExecuteReader())
                    while (r.Read())
                    {
                        var row = new object[r.FieldCount];
                        for (int n = 0; n < row.Length; n++) { object v = r.GetValue(n); row[n] = v is DBNull ? null : v; }
                        yield return row;
                    }
            }
            finally { if (dispose) c.Dispose(); }
        }

        internal static object[] ReadServeMessage(Func<string, SqliteCommand> command, string kind, string identity, bool details, out long eventCount)
        {
            if (!details) return ReadServeRollup(command, kind, identity, out eventCount);
            eventCount = 0;
            Journey journey = null;
            if (kind == "message")
            foreach (var r in ServeRows(command, "SELECT message_id,time_ms,server,event_id,source,internal_id,sender,recipients,recipient_status,recipient_count,total_bytes,subject,client_ip,client_host,server_host,connector,source_context,directionality,related_recipient,reference FROM message_event WHERE msg_hash=@h AND message_id=@m COLLATE BINARY ORDER BY time_ms,id;"))
            {
                if (journey == null) journey = new Journey { MessageId = identity, First = L(r[1]) };
                journey.Last = L(r[1]); eventCount++;
                if (journey.Sender == null) journey.Sender = S(r[6]);
                if (journey.Subject == null) journey.Subject = S(r[11]);
                if (journey.Direction == null) journey.Direction = S(r[17]);
                journey.Size = Math.Max(journey.Size, L(r[10]));
                journey.MaxCount = Math.Max(journey.MaxCount, L(r[9]));
                journey.Events.Add(r);
            }
            var smtp = ServeRows(command, "SELECT message_id,time_ms,end_ms,server,direction,role,connector,remote_ep,local_ep,helo,tls,auth,mail_from,rcpt_count,status," + (details ? "response" : "NULL") + "," +
                (details ? "transcript" : "NULL") + ",session_id," + SmtpAuthView.Columns + ",rcpts FROM smtp_transaction WHERE " +
                (kind == "message" ? "msg_hash=@h AND message_id=@m COLLATE BINARY" : "id=@sid AND message_id IS NULL AND direction='Receive' AND (status IS NULL OR status<>'Accepted')") +
                " ORDER BY time_ms,id;").ToList();
            if (journey == null && smtp.Count == 0) return null;
            object[] output;
            Func<long, object> time = t => t;
            if (journey != null)
                output = JourneyRow(journey, smtp.Select(s => { var row = (object[])s.Clone(); row[16] = null; return row; }).ToList(),
                    new ReportRequest { IncludeRoutingDetails = details }, time);
            else
            {
                var first = smtp[0]; var last = smtp[smtp.Count - 1];
                string status = S(last[14]) == "Deferred" ? "Deferred (SMTP)" : S(last[14]) == "Rejected" ? "Rejected (SMTP)" :
                    S(last[14]) == "Accepted" ? "Accepted (SMTP)" : "Not completed (SMTP)";
                var recipients = (S(first[first.Length - 1]) ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries);
                long start = L(first[1]), end = last[2] == null ? L(last[1]) : L(last[2]);
                output = new object[] { start, end, TimeUtil.Duration((end-start)/1000.0), status, S(first[12]),
                    kind == "smtp" ? recipients.Select(r => r + " (" + S(last[14]) + ")").ToArray() : recipients,
                    (long)recipients.Length, 0L, status == "Rejected (SMTP)" ? (long)recipients.Length : 0L, null, null,
                    S(first[4]) == "Send" ? "Outgoing (SMTP)" : "Incoming (SMTP)",
                    string.Join(" > ", smtp.Select(s => S(s[3])).Distinct(StringComparer.OrdinalIgnoreCase)), "SMTP " + S(last[14]),
                    (long)smtp.Count, kind == "message" ? identity : null, new List<object[]>(), new List<object[]>() };
                if (details)
                    output[16] = smtp.Select(s => {
                        var parts = new List<string>();
                        if (S(s[7]) != null) parts.Add("remote " + S(s[7]));
                        if (S(s[6]) != null) parts.Add(S(s[6]));
                        if (S(s[9]) != null) parts.Add("HELO " + S(s[9]));
                        if (S(s[10]) != null) parts.Add(S(s[10]));
                        if (S(s[11]) != null) parts.Add("auth " + S(s[11]));
                        if (S(s[4]) == "Receive") AddAuthentication(parts, SmtpAuthView.Fields(s,18), S(s[12]));
                        if (S(s[15]) != null) parts.Add(S(s[15]));
                        return new object[] { L(s[1]), S(s[3]), "SMTP " + S(s[4]) + (S(s[5]) == null ? "" : " ("+S(s[5])+")"), S(s[14]), string.Join(" | ",parts) };
                    }).ToList();
            }
            if (details)
                output[17] = smtp.Where(s => s[16] != null).Select(s => new object[] { L(s[1]), S(s[3]), S(s[4]) + " " + S(s[17]), SmtpAuth.RedactTranscript(S(s[16])) }).ToList();
            return output;
        }

        static object[] ReadServeRollup(Func<string, SqliteCommand> command, string kind, string identity, out long eventCount)
        {
            long? first, last;
            return ReadServeRollupBounds(command, kind, identity, false, out eventCount, out first, out last);
        }

        /// <summary>
        /// The two reads of every message key of a reconciliation (its tracking events; the COUNT/MIN/MAX of its SMTP rows) as raw statements bound
        /// by index, with typed column reads: the values ReadServeRollupBounds computes are those of the Microsoft.Data.Sqlite path (S and L of
        /// GetValue): INTEGER and TEXT columns are read directly, NULL gives null / 0, any other storage class goes through GetValue's object and S / L.
        /// </summary>
        internal sealed class RollupReads : IDisposable
        {
            internal readonly Prepared Events, Counter, Smtp;
            internal object Hash;   // msg_hash of the key (long or DBNull), bound with its Message-ID
            // Used again for every key: the reconciliation stores neither the route nor the transcripts of the row (always empty lists here).
            internal readonly JourneySummary Summary = new JourneySummary(compact: true);
            internal readonly List<object[]> NoSteps = new List<object[]>(), NoTranscripts = new List<object[]>();
            // The row of an 'smtp' key (the projection of ReadServeRollupBounds), filled again for every key: nothing keeps it after the call.
            internal readonly object[] SmtpRow = new object[7];

            internal RollupReads(Store store)
            {
                Events = new Prepared(store, "SELECT time_ms,server,event_id,sender,recipients,recipient_count,total_bytes,subject,directionality FROM message_event WHERE msg_hash=@p0 AND message_id=@p1 COLLATE BINARY ORDER BY time_ms,id;", 2);
                Counter = new Prepared(store, "SELECT COUNT(*),MIN(time_ms),MAX(time_ms) FROM smtp_transaction WHERE msg_hash=@p0 AND message_id=@p1 COLLATE BINARY;", 2);
                Smtp = new Prepared(store, "SELECT time_ms,end_ms,server,mail_from,rcpts,status,direction FROM smtp_transaction WHERE id=@p0 AND message_id IS NULL AND direction='Receive' AND (status IS NULL OR status<>'Accepted');", 1);
            }

            internal Prepared Bind(Prepared q, string identity) { q.Set(0, Hash); q.Set(1, identity); return q; }

            public void Dispose() { Events.Dispose(); Counter.Dispose(); Smtp.Dispose(); }
        }

        /// <summary>L(GetValue) of a column of a raw statement.</summary>
        static long L(Prepared q, int column)
        {
            int type = q.Type(column);
            if (type == SQLitePCL.raw.SQLITE_INTEGER) return q.Int64(column);
            if (type == SQLitePCL.raw.SQLITE_NULL) return 0;
            return L(q.Value(column));
        }

        /// <summary>S(GetValue) of a column of a raw statement (a packed BLOB is unpacked).</summary>
        static string S(Prepared q, int column)
        {
            int type = q.Type(column);
            if (type == SQLitePCL.raw.SQLITE_TEXT) return q.Text(column);
            if (type == SQLitePCL.raw.SQLITE_NULL) return null;
            return S(q.Value(column));
        }

        /// <summary>
        /// Same result as ReadServeMessage(details: false), plus MIN/MAX(time_ms) of the SMTP rows counted in the row (one query with the COUNT; null when none).
        /// With reuse the commands come from a caller-owned cache and are not disposed here. reads (reconciliation): the two reads of a message key
        /// through its raw statements, the rare other reads through command; the row then has no Duration (null, the reconciliation does not store it)
        /// and the empty route and transcript lists of reads.
        /// </summary>
        internal static object[] ReadServeRollupBounds(Func<string, SqliteCommand> command, string kind, string identity, bool reuse, out long eventCount, out long? smtpFirstMs, out long? smtpLastMs, RollupReads reads = null)
        {
            // Retain recipient summary state, not the event history or SMTP conversation arrays.
            eventCount = 0; smtpFirstMs = null; smtpLastMs = null;
            Journey journey = null;
            var summary = reads != null ? reads.Summary.Reset() : new JourneySummary(compact: true);
            if (kind == "message" && reads != null)
            {
                // The same values, in the same order, as the ServeRows loop below.
                var q = reads.Bind(reads.Events, identity);
                try
                {
                    while (q.Step())
                    {
                        long time = L(q, 0);
                        if (journey == null) journey = new Journey { MessageId = identity, First = time };
                        journey.Last = time; eventCount++;
                        if (journey.Sender == null) journey.Sender = S(q, 3);
                        if (journey.Subject == null) journey.Subject = S(q, 7);
                        if (journey.Direction == null) journey.Direction = S(q, 8);
                        journey.Size = Math.Max(journey.Size, L(q, 6));
                        journey.MaxCount = Math.Max(journey.MaxCount, L(q, 5));
                        summary.Add(S(q, 1), S(q, 2), S(q, 4));
                    }
                }
                finally { q.Reset(); }
            }
            else if (kind == "message")
            foreach (var row in ServeRows(command, "SELECT time_ms,server,event_id,sender,recipients,recipient_count,total_bytes,subject,directionality FROM message_event WHERE msg_hash=@h AND message_id=@m COLLATE BINARY ORDER BY time_ms,id;", !reuse))
            {
                if (journey == null) journey = new Journey { MessageId = identity, First = L(row[0]) };
                journey.Last = L(row[0]); eventCount++;
                if (journey.Sender == null) journey.Sender = S(row[3]);
                if (journey.Subject == null) journey.Subject = S(row[7]);
                if (journey.Direction == null) journey.Direction = S(row[8]);
                journey.Size = Math.Max(journey.Size, L(row[6]));
                journey.MaxCount = Math.Max(journey.MaxCount, L(row[5]));
                summary.Add(S(row[1]), S(row[2]), S(row[4]));
            }
            string where = " FROM smtp_transaction WHERE " + (kind == "message" ? "msg_hash=@h AND message_id=@m COLLATE BINARY" :
                "id=@sid AND message_id IS NULL AND direction='Receive' AND (status IS NULL OR status<>'Accepted')");
            string projection = "SELECT time_ms,end_ms,server,mail_from,rcpts,status,direction";
            long count;
            object[] first, last;
            string[] servers;
            if (kind == "smtp" && reads != null)
            {
                // The same row as the ServeRows read below, as a raw statement: each column is the value of GetValue (Prepared.Value; NULL gives null).
                var q = reads.Smtp;
                q.Set(0, long.Parse(identity, CultureInfo.InvariantCulture));
                var row = reads.SmtpRow;
                try
                {
                    if (!q.Step()) return null;
                    for (int n = 0; n < row.Length; n++) row[n] = q.Value(n);
                    if (q.Step()) throw new InvalidOperationException("More than one SMTP row for one rowid.");
                }
                finally { q.Reset(); }
                first = last = row;
                count = 1;
                if (first[0] != null) { smtpFirstMs = Convert.ToInt64(first[0], CultureInfo.InvariantCulture); smtpLastMs = smtpFirstMs; }
                servers = new[] { S(first[2]) };
            }
            else if (kind == "smtp")
            {
                // id is the key: at most one row, which is the first and the last row, its server the only one; COUNT, MIN and MAX come from it.
                var only = ServeRows(command, projection + where + ";", !reuse).ToList();
                if (only.Count > 1) throw new InvalidOperationException("More than one SMTP row for one rowid.");
                if (only.Count == 0) return null;
                first = last = only[0];
                count = 1;
                if (first[0] != null) { smtpFirstMs = Convert.ToInt64(first[0], CultureInfo.InvariantCulture); smtpLastMs = smtpFirstMs; }
                servers = new[] { S(first[2]) };
            }
            else if (reads != null)
            {
                // The COUNT/MIN/MAX below, as a raw statement (GetInt64 and IsDBNull are sqlite3_column_int64 and the NULL storage class).
                var q = reads.Bind(reads.Counter, identity);
                try
                {
                    if (!q.Step()) throw new InvalidOperationException("The SMTP count of a rollup key returned no row.");
                    count = q.Int64(0);
                    if (q.Type(1) != SQLitePCL.raw.SQLITE_NULL) { smtpFirstMs = q.Int64(1); smtpLastMs = q.Int64(2); }
                }
                finally { q.Reset(); }
                if (journey != null) return summary.Row(journey, count, t => t, reads.NoSteps, reads.NoTranscripts, duration: false);
                if (count == 0) return null;
                first = ServeRows(command, projection + where + " ORDER BY time_ms,id LIMIT 1;", !reuse).Single();
                last = ServeRows(command, projection + where + " ORDER BY time_ms DESC,id DESC LIMIT 1;", !reuse).Single();
                servers = ServeRows(command, "SELECT DISTINCT server" + where + " ORDER BY server;", !reuse).Select(r => S(r[0])).ToArray();
            }
            else
            {
                // One scan of the same WHERE gives the SMTP row count and the time bounds the rollup stores as member_first_ms/member_last_ms.
                var counter = command("SELECT COUNT(*),MIN(time_ms),MAX(time_ms)" + where + ";");
                try
                {
                    using (var r = counter.ExecuteReader())
                    {
                        r.Read();
                        count = r.GetInt64(0);
                        if (!r.IsDBNull(1)) { smtpFirstMs = r.GetInt64(1); smtpLastMs = r.GetInt64(2); }
                    }
                }
                finally { if (!reuse) counter.Dispose(); }
                if (journey != null) return summary.Row(journey, count, t => t, new List<object[]>(), new List<object[]>());
                if (count == 0) return null;
                first = ServeRows(command, projection + where + " ORDER BY time_ms,id LIMIT 1;", !reuse).Single();
                last = ServeRows(command, projection + where + " ORDER BY time_ms DESC,id DESC LIMIT 1;", !reuse).Single();
                servers = ServeRows(command, "SELECT DISTINCT server" + where + " ORDER BY server;", !reuse).Select(r => S(r[0])).ToArray();
            }
            string status = S(last[5]) == "Deferred" ? "Deferred (SMTP)" : S(last[5]) == "Rejected" ? "Rejected (SMTP)" :
                S(last[5]) == "Accepted" ? "Accepted (SMTP)" : "Not completed (SMTP)";
            var recipients = (S(first[4]) ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries);
            long from = L(first[0]), to = last[1] == null ? L(last[0]) : L(last[1]);
            return new object[] { from, to, reads != null ? null : TimeUtil.Duration((to-from)/1000.0), status, S(first[3]),
                kind == "smtp" ? recipients.Select(r => r + " (" + S(last[5]) + ")").ToArray() : recipients,
                (long)recipients.Length, 0L, status == "Rejected (SMTP)" ? (long)recipients.Length : 0L, null, null,
                S(first[6]) == "Send" ? "Outgoing (SMTP)" : "Incoming (SMTP)", string.Join(" > ", servers),
                "SMTP " + S(last[5]), count, kind == "message" ? identity : null,
                reads != null ? reads.NoSteps : new List<object[]>(), reads != null ? reads.NoTranscripts : new List<object[]>() };
        }
    }
}
