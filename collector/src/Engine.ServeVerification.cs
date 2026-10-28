using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Threading;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    public sealed class ServeRollupVerification
    {
        public bool Verified { get; internal set; }
        public int SchemaVersion { get; internal set; }
        public long RowsVerified { get; internal set; }
        public long TrackingIdentities { get; internal set; }
        public long SmtpOnlyIdentities { get; internal set; }
        public long MissingMessageIdSmtpIdentities { get; internal set; }
        public long SourceHashGroupsVerified { get; internal set; }
        public bool SourceHashesVerified { get; internal set; }
        public bool SchemaObjectsVerified { get; internal set; }
        /// <summary>Schema 11: the SMTP client structures equal a full recomputation from the transactions (see VerifySmtpClientsCore).</summary>
        public bool SmtpClientsVerified { get; internal set; }
        public long SmtpClientRows { get; internal set; }
        public long SmtpClientHourRows { get; internal set; }
        public bool ReadOnlySnapshot { get; internal set; }
        public bool CallerSnapshotUsed { get; internal set; }
        public int CacheKilobytes { get; internal set; }
        public double ElapsedMilliseconds { get; internal set; }
    }

    public sealed partial class Store
    {
        /// <summary>
        /// Explicit maintenance validation of committed schema 11, never called by Serve or collection.
        /// Recompute one identity at a time in a read-only snapshot with a 16 MiB cache and a five-minute deadline.
        /// Memory retains only the current identity's recipient/status summary, not its event history.
        /// This does not replace baseline source fingerprints or schema/trigger inventory comparison.
        /// </summary>
        public ServeRollupVerification VerifyServeRollups()
        {
            return VerifyServeRollupsWithDeadline(300, CancellationToken.None);
        }

        /// <summary>
        /// Explicit maintenance validation of the SMTP client structures alone (also part of VerifyServeRollups): every client_id, the client dimension and the hourly
        /// buckets equal a recomputation from the SMTP transactions, and no work is queued. Committed data in a read-only snapshot, five-minute deadline, never repairs.
        /// </summary>
        public SmtpClientVerification VerifySmtpClients()
        {
            if (_reportSnapshot != null) throw new InvalidOperationException("Verify committed SMTP clients outside an active report snapshot.");
            using (var c = Command("SELECT 1;")) c.ExecuteScalar();
            using (var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(300)))
            {
                try
                {
                    using (var read = new ServeRead(new ServeOptions { DatabasePath = FilePath, MmapMB = 0 }, deadline.Token))
                    {
                        read.Ready();
                        VerifyServeSchema(read);
                        return VerifySmtpClientsCore(sql => read.Command(sql), () => deadline.Token.ThrowIfCancellationRequested());
                    }
                }
                catch (Exception e) when ((e is SqliteException || e is OperationCanceledException) && deadline.IsCancellationRequested)
                {
                    throw new TimeoutException("SMTP client verification exceeded its deadline; no verification result was published and no database changes were made.", e);
                }
            }
        }

        public ServeRollupVerification VerifyServeRollupsWithDeadline(int timeoutSeconds, CancellationToken cancellationToken)
        {
            if (_reportSnapshot != null) throw new InvalidOperationException("Verify committed rollups outside an active report snapshot.");
            // An active caller transaction must not be mistaken for the committed database being verified.
            using (var c = Command("SELECT 1;")) c.ExecuteScalar();
            return VerifyServeRollupsFile(FilePath, timeoutSeconds, cancellationToken);
        }

        /// <summary>
        /// No Store constructor or migration. The supplied connection must have an open read-only main file.
        /// Verification opens its OWN bounded snapshot of that file; caller transactions, cancellation handlers,
        /// PRAGMAs and connection lifetime are untouched. Use an immutable/staged copy for fingerprint binding.
        /// Canonical hash/rollup DDL is checked; the caller still compares all other baseline schema and data.
        /// </summary>
        public static ServeRollupVerification VerifyServeRollups(SqliteConnection db)
        {
            return VerifyServeRollupsWithDeadline(db, 300, CancellationToken.None);
        }

        public static ServeRollupVerification VerifyServeRollupsWithDeadline(SqliteConnection db, int timeoutSeconds, CancellationToken cancellationToken)
        {
            if (db == null) throw new ArgumentNullException(nameof(db));
            if (db.State != System.Data.ConnectionState.Open || SQLitePCL.raw.sqlite3_db_readonly(db.Handle, "main") != 1)
                throw new InvalidOperationException("Supply an open read-only main database connection; the verifier never changes its mode.");
            return VerifyServeRollupsFile(db.DataSource, timeoutSeconds, cancellationToken);
        }

        static ServeRollupVerification VerifyServeRollupsFile(string path, int timeoutSeconds, CancellationToken cancellationToken)
        {
            if (timeoutSeconds < 1 || timeoutSeconds > 3600) throw new ArgumentOutOfRangeException(nameof(timeoutSeconds));
            var clock = Stopwatch.StartNew();
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                deadline.CancelAfter(TimeSpan.FromSeconds(timeoutSeconds));
                try
                {
                    using (var read = new ServeRead(new ServeOptions { DatabasePath = path, MmapMB = 0 }, deadline.Token))
                    {
                        read.Ready();
                        VerifyServeSchema(read);
                        var result = new ServeRollupVerification { SchemaVersion = 11, ReadOnlySnapshot = true, CacheKilobytes = 16384, SchemaObjectsVerified = true };
                        foreach (string table in new[] { "message_event", "smtp_transaction" })
                        {
                            using (var c = read.Command("SELECT 1 FROM " + table + " WHERE message_id IS NULL AND msg_hash IS NOT NULL LIMIT 1;"))
                                if (c.ExecuteScalar() != null) throw new InvalidDataException("InvalidSourceHash: NULL message identity has a non-NULL hash in " + table + ".");
                            // The identity indexes hold (msg_hash,time_ms) only (schema 10): the distinct exact identities come from one sequential scan of the
                            // table grouped by the BINARY Message-ID, with one sorter spilled to temporary files by ServeRead. NOT INDEXED keeps the planner from
                            // walking the hash index instead, which would read one table row at random per index entry.
                            using (var c = read.Command("SELECT msg_hash,message_id FROM " + table + " NOT INDEXED" +
                                " WHERE message_id IS NOT NULL GROUP BY msg_hash,message_id COLLATE BINARY ORDER BY msg_hash,message_id COLLATE BINARY;"))
                            using (var r = c.ExecuteReader())
                            while (r.Read())
                            {
                                deadline.Token.ThrowIfCancellationRequested();
                                object hash = r.GetValue(0), rawIdentity = r.GetValue(1);
                                string identity = rawIdentity as string;
                                if (identity == null || !(hash is long) || (long)hash != MessageHash(identity))
                                    throw new InvalidDataException("InvalidSourceHash: noncanonical message identity/hash in " + table + ".");
                                result.SourceHashGroupsVerified++;
                                if (table == "smtp_transaction")
                                using (var exists = VerificationCommand(read, "SELECT 1 FROM message_event WHERE msg_hash=@h AND message_id=@m COLLATE BINARY LIMIT 1;", "message", identity, hash))
                                    if (exists.ExecuteScalar() != null) continue;
                                VerifyServeRollupIdentity(read, "message", identity, hash);
                                if (table == "message_event") result.TrackingIdentities++;
                                else result.SmtpOnlyIdentities++;
                                result.RowsVerified++;
                            }
                        }
                        using (var c = read.Command("SELECT id FROM smtp_transaction WHERE message_id IS NULL AND direction='Receive' AND (status IS NULL OR status<>'Accepted') ORDER BY id;"))
                        using (var r = c.ExecuteReader())
                        while (r.Read())
                        {
                            deadline.Token.ThrowIfCancellationRequested();
                            VerifyServeRollupIdentity(read, "smtp", r.GetInt64(0).ToString(CultureInfo.InvariantCulture), DBNull.Value);
                            result.MissingMessageIdSmtpIdentities++;
                            result.RowsVerified++;
                        }
                        long rows, maxId;
                        using (var c = read.Command("SELECT COUNT(*),COALESCE(MAX(id),0) FROM message_rollup;"))
                        using (var r = c.ExecuteReader()) { r.Read(); rows = r.GetInt64(0); maxId = r.GetInt64(1); }
                        if (rows != result.RowsVerified) throw new InvalidDataException("InvalidServeRollup: extra or missing derived identities.");
                        // Every code a row references exists in the dictionary (a dangling nullable code would otherwise read back as NULL).
                        using (var c = read.Command("SELECT 1 FROM message_rollup r WHERE NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.status)" +
                            " OR (r.direction IS NOT NULL AND NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.direction))" +
                            " OR (r.servers IS NOT NULL AND NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.servers))" +
                            " OR (r.events IS NOT NULL AND NOT EXISTS(SELECT 1 FROM message_rollup_value v WHERE v.id=r.events)) LIMIT 1;"))
                            if (c.ExecuteScalar() != null) throw new InvalidDataException("InvalidServeRollup: a row references a code that is not in message_rollup_value.");
                        using (var c = read.Command("SELECT seq FROM sqlite_sequence WHERE name='message_rollup';"))
                        using (var r = c.ExecuteReader())
                        {
                            if (!r.Read())
                            {
                                if (rows != 0) throw new InvalidDataException("InvalidServeRollupSequence: missing stable-ID sequence.");
                            }
                            else if (!(r.GetValue(0) is long) || r.GetInt64(0) < maxId || r.Read())
                                throw new InvalidDataException("InvalidServeRollupSequence: invalid or duplicate stable-ID sequence.");
                        }
                        // Schema 11: the SMTP client dimension, the client of every transaction and the hourly buckets, recomputed from the rows.
                        var clients = VerifySmtpClientsCore(sql => read.Command(sql), () => deadline.Token.ThrowIfCancellationRequested());
                        result.SmtpClientsVerified = clients.Verified; result.SmtpClientRows = clients.Clients; result.SmtpClientHourRows = clients.HourRows;
                        deadline.Token.ThrowIfCancellationRequested();
                        result.SourceHashesVerified = true; result.Verified = true;
                        result.ElapsedMilliseconds = clock.Elapsed.TotalMilliseconds;
                        return result;
                    }
                }
                catch (Exception e) when ((e is SqliteException || e is OperationCanceledException) && deadline.IsCancellationRequested)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    throw new TimeoutException("Serve rollup verification exceeded its explicit deadline; no verification result was published and no database changes were made.", e);
                }
            }
        }

        static void VerifyServeSchema(ServeRead read)
        {
            var expected = new Dictionary<string, string[]>(StringComparer.Ordinal)
            {
                { "message_rollup", new[] { "table", "message_rollup", ServeRollupTableSql } },
                { "message_rollup_dirty", new[] { "table", "message_rollup_dirty", ServeRollupDirtyTableSql } },
                { "message_rollup_value", new[] { "table", "message_rollup_value", ServeRollupValueTableSql } },
                { "sqlite_autoindex_message_rollup_value_1", new[] { "index", "message_rollup_value", (string)null } },
                { "sqlite_autoindex_message_rollup_1", new[] { "index", "message_rollup", (string)null } },
                { "sqlite_autoindex_smtp_client_value_1", new[] { "index", "smtp_client_value", (string)null } },
                { "sqlite_sequence", new[] { "table", "sqlite_sequence", "CREATE TABLE sqlite_sequence(name,seq)" } },
                { "source_fields", new[] { "table", "source_fields", SourceFieldsTableSql } },
                { "sqlite_autoindex_source_fields_1", new[] { "index", "source_fields", (string)null } }
            };
            foreach (var index in ServeRollupIndexes) expected.Add(index[0], new[] { "index", index[1], index[2] });
            foreach (var table in SmtpClientTables) expected.Add(table[0], new[] { "table", table[0], table[1] });
            foreach (var index in SmtpClientIndexes) expected.Add(index[0], new[] { "index", index[1], index[2] });
            foreach (var trigger in SmtpClientTriggers) expected.Add(trigger[0], new[] { "trigger", "smtp_transaction", trigger[1] });
            foreach (string table in new[] { "message_event", "smtp_transaction" })
            {
                foreach (string operation in new[] { "INSERT", "UPDATE", "DELETE" })
                    expected.Add("tr_" + table + "_rollup_" + operation.ToLowerInvariant(), new[] { "trigger", table, ServeRollupTriggerSql(table, operation) });
                foreach (bool insert in new[] { true, false })
                    expected.Add("tr_" + table + (insert ? "_hash_insert" : "_hash_update"), new[] { "trigger", table, MessageHashTriggerSql(table, insert) });
            }
            foreach (var entry in expected)
            using (var c = read.Command("SELECT type,tbl_name,sql FROM sqlite_master WHERE name=@name;"))
            {
                c.Parameters.AddWithValue("@name", entry.Key);
                using (var r = c.ExecuteReader())
                {
                    if (!r.Read() || !string.Equals(r.GetString(0), entry.Value[0], StringComparison.Ordinal) ||
                        !string.Equals(r.GetString(1), entry.Value[1], StringComparison.Ordinal) ||
                        !string.Equals(r.IsDBNull(2) ? null : r.GetString(2).Trim().TrimEnd(';'), entry.Value[2], StringComparison.Ordinal) || r.Read())
                        throw new InvalidDataException("InvalidServeSchema: missing or noncanonical object: " + entry.Key + ".");
                }
            }
            bool clientId = false;
            using (var c = read.Command("PRAGMA table_info(smtp_transaction);"))
            using (var r = c.ExecuteReader()) while (r.Read()) if (string.Equals(r.GetString(1), "client_id", StringComparison.Ordinal) && string.Equals(r.GetString(2), "INTEGER", StringComparison.Ordinal)) clientId = true;
            if (!clientId) throw new InvalidDataException("InvalidServeSchema: smtp_transaction.client_id is missing.");
            bool fieldsId = false;
            using (var c = read.Command("PRAGMA table_info(source_file);"))
            using (var r = c.ExecuteReader()) while (r.Read()) if (string.Equals(r.GetString(1), "fields_id", StringComparison.Ordinal)) fieldsId = true;
            if (!fieldsId) throw new InvalidDataException("InvalidServeSchema: source_file.fields_id is missing.");
            using (var c = read.Command("SELECT 1 FROM source_file s WHERE s.fields_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM source_fields d WHERE d.id=s.fields_id) LIMIT 1;"))
                if (c.ExecuteScalar() != null) throw new InvalidDataException("InvalidServeSchema: source_file.fields_id points at a missing source_fields row.");
            // Schema 9 removed these (schema 11 also ix_smtp_latest); a leftover means the database was not migrated (or was altered), not that it is merely larger.
            foreach (string obsolete in ObsoleteServeIndexes)
                using (var c = read.Command("SELECT 1 FROM sqlite_master WHERE name=@name;"))
                {
                    c.Parameters.AddWithValue("@name", obsolete);
                    if (c.ExecuteScalar() != null) throw new InvalidDataException("InvalidServeSchema: obsolete object present: " + obsolete + ".");
                }
            using (var c = read.Command("SELECT name FROM sqlite_master WHERE tbl_name IN('message_rollup','message_rollup_dirty','message_rollup_value','smtp_client_value','smtp_client','smtp_client_hour','smtp_client_pending','smtp_client_dirty');"))
            using (var r = c.ExecuteReader())
                while (r.Read())
                    if (!expected.ContainsKey(r.GetString(0)))
                        throw new InvalidDataException("InvalidServeSchema: unexpected object attached to a derived table.");
        }

        static SqliteCommand VerificationCommand(ServeRead read, string sql, string kind, string identity, object hash)
        {
            var c = read.Command(sql);
            c.Parameters.AddWithValue("@h", hash);
            c.Parameters.AddWithValue("@m", identity);
            c.Parameters.AddWithValue("@sid", kind == "smtp" ? long.Parse(identity, CultureInfo.InvariantCulture) : 0L);
            return c;
        }

        static void VerifyServeRollupIdentity(ServeRead read, string kind, string identity, object hash)
        {
            Func<string, SqliteCommand> command = sql => VerificationCommand(read, sql, kind, identity, hash);
            long count;
            var summary = ReportBuilder.ReadServeMessage(command, kind, identity, false, out count);
            if (summary == null) throw new InvalidDataException("InvalidServeRollup: source identity could not be summarized.");
            long first = Convert.ToInt64(summary[0], CultureInfo.InvariantCulture), last = Convert.ToInt64(summary[1], CultureInfo.InvariantCulture);
            using (var c = command("SELECT MIN(time_ms),MAX(time_ms) FROM smtp_transaction WHERE " +
                (kind == "message" ? "msg_hash=@h AND message_id=@m COLLATE BINARY" : "id=@sid") + ";"))
            using (var r = c.ExecuteReader())
                if (r.Read() && !r.IsDBNull(0)) { first = Math.Min(first, r.GetInt64(0)); last = Math.Max(last, r.GetInt64(1)); }
            // Schema 11: the stored row holds codes. kind is 0/1, status/direction/servers/events are dictionary codes compared through their text, and
            // first_ms/last_ms are NULL exactly when they equal the member bounds (and the value read back is COALESCE(stored, member bound)).
            string[] columns = { "kind", "identity", "msg_hash", "first_ms", "last_ms", "member_first_ms", "member_last_ms",
                "status", "sender", "recipients", "recipient_count", "delivered", "failed", "subject", "size_kb",
                "direction", "servers", "events", "events_count", "smtp_count" };
            long summaryFirst = Convert.ToInt64(summary[0], CultureInfo.InvariantCulture), summaryLast = Convert.ToInt64(summary[1], CultureInfo.InvariantCulture);
            object[] expected = { kind == "smtp" ? (long)MessageKindSmtp : (long)MessageKindMessage, identity, hash, summaryFirst == first ? null : (object)summaryFirst, summaryLast == last ? null : (object)summaryLast, first, last, summary[3], summary[4],
                JsonSerializer.Serialize(summary[5]), summary[6], summary[7], summary[8], summary[9], summary[10],
                summary[11], summary[12], summary[13], count, summary[14] };
            using (var c = command("SELECT r.id,r.kind,r.identity,r.msg_hash,r.first_ms,r.last_ms,r.member_first_ms,r.member_last_ms,s.text,r.sender,r.recipients,r.recipient_count,r.delivered,r.failed,r.subject,r.size_kb,d.text,v.text,x.text,r.events_count,r.smtp_count" +
                " FROM message_rollup r LEFT JOIN message_rollup_value s ON s.id=r.status LEFT JOIN message_rollup_value d ON d.id=r.direction LEFT JOIN message_rollup_value v ON v.id=r.servers LEFT JOIN message_rollup_value x ON x.id=r.events" +
                " WHERE r.kind=@k AND r.identity=@m COLLATE BINARY;"))
            {
                c.Parameters.AddWithValue("@k", kind == "smtp" ? MessageKindSmtp : MessageKindMessage);
                using (var r = c.ExecuteReader())
                {
                    if (!r.Read()) throw new InvalidDataException("InvalidServeRollup: missing derived identity.");
                    if (!(r.GetValue(0) is long) || r.GetInt64(0) < 1) throw new InvalidDataException("InvalidServeRollup: URL identity must be a positive INTEGER.");
                    for (int i = 0; i < expected.Length; i++)
                        if (!object.Equals(expected[i] ?? DBNull.Value, r.GetValue(i + 1)))
                            throw new InvalidDataException("InvalidServeRollup: derived column mismatch: " + columns[i] + ".");
                    if (r.Read()) throw new InvalidDataException("InvalidServeRollup: duplicate exact derived identity.");
                }
            }
        }
    }
}
