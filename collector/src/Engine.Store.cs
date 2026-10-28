// =============================================================================
//  Exchange Log Report - engine, part 2: SQLite store
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 2.0.0
//
//  Tables (all times in Unix ms, UTC)
//    run              one row per execution
//    source_file      read position of every log file (server, kind, file_key) -> offset; file_key is the
//                     identity of the file whatever the path used to reach it (see FileKey); its '#Fields' header
//                     text is stored once per distinct text in source_fields (schema 10, source_file.fields_id)
//    noise            lines set aside per execution, server, kind and reason
//    access_usage     client access, one row per day x server x user x protocol (aggregate)
//    access_action    client access, one row per day x server x protocol x action (latency per operation)
//    access_client    client access, one row per day x user x protocol x address x client (devices, versions)
//    client_session   one row per client session: user, protocol, client and address of one day, cut by inactivity
//    session_step     timeline of a session: one row per session and log file read (JSON steps)
//    access_event     client access requests kept individually: failures, slow requests (and watched users)
//    iis_status       IIS sub-status / Win32 status of failed proxied requests (by request id)
//    smtp_transaction one row per SMTP mail transaction (MAIL FROM ... end of data), with its authenticated user
//    smtp_auth_fragment typed evidence of SMTP sessions (AUTH, identity, proxy), kept with the transactions that use it
//    message_event    message tracking events of real messages
//  Raw log lines are never stored: only the normalised fields above.
// =============================================================================
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    /// <summary>Read position and counters of one log file.</summary>
    public sealed class FileState
    {
        public long Id;
        public string Server, Kind, Path, Fields;
        public long Offset, Size, LastWriteMs, FirstMs, LastMs, Lines, Kept, Noise;

        /// <summary>Copy of a known state for the path used now (its stored path is kept in the database).</summary>
        public FileState CopyFor(string path)
        {
            var c = (FileState)MemberwiseClone();
            c.Path = path;
            return c;
        }
    }

    /// <summary>Generic query result handed to PowerShell (status views).</summary>
    public sealed class TableResult
    {
        public string[] Columns = new string[0];
        public List<object[]> Rows = new List<object[]>();
    }

    public sealed class PurgeResult
    {
        public long Usage, Events, IisStatus, Smtp, Transcripts, AuthFragments, Messages, Runs, Files, Sessions, Actions, Clients;
        public double DeleteSeconds, VacuumSeconds, OptimizeSeconds;
        public long Total { get { return Usage + Events + IisStatus + Smtp + Messages + Sessions + Actions + Clients; } }
    }

    /// <summary>Row of PRAGMA wal_checkpoint: busy, frames in the log, frames copied into the database (-1: unknown).</summary>
    public struct WalCheckpoint
    {
        public long Busy, Log, Checkpointed;
        /// <summary>Not blocked and every frame of the log copied: the next writer starts the log again at its beginning.</summary>
        public bool Complete { get { return Busy == 0 && Log >= 0 && Log == Checkpointed; } }
    }

    public sealed partial class Store : IDisposable
    {
        public const string SchemaVersion = "11";
        public const string MessageHashAlgorithm = "fnv1a64-utf8-v1";
        /// <summary>SQLite page cache of a collection, in KB (set before opening the store; 256 MB by default).</summary>
        public static int CacheKilobytes = 262144;
        /// <summary>Page size of a NEW database (an existing one keeps its own). 16 KB: fewer and larger writes, on a
        /// hard disk the copy of the WAL into the database took 2.6 times less time than with 4 KB pages (lab, 2.0.0).</summary>
        public static int PageSize = 16384;
        readonly SqliteConnection _db;
        SqliteTransaction _reportSnapshot;
        public string FilePath { get; private set; }
        public bool ReadOnly { get; private set; }

        public Store(string path, bool readOnly, string toolVersion)
        {
            FilePath = Path.GetFullPath(path);
            ReadOnly = readOnly;
            if (!readOnly) Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
            var builder = new SqliteConnectionStringBuilder
            {
                DataSource = FilePath,
                Mode = readOnly ? SqliteOpenMode.ReadOnly : SqliteOpenMode.ReadWriteCreate,
                Cache = SqliteCacheMode.Private,
                Pooling = false
            };
            _db = new SqliteConnection(builder.ToString());
            try
            {
            _db.Open();
            RegisterFunctions();
            Exec("PRAGMA busy_timeout=30000;");
            if (StoredSchemaVersion() > int.Parse(SchemaVersion, System.Globalization.CultureInfo.InvariantCulture))
                throw new InvalidOperationException("This database uses a newer schema; no changes were made.");
            if (readOnly)
            {
                // A database of an older version (report without collection after an update): upgrade it
                // once (new tables and columns only), then go on read-only.
                if (StoredSchemaVersion() < int.Parse(SchemaVersion, System.Globalization.CultureInfo.InvariantCulture))
                {
                    _db.Dispose();
                    using (new Store(FilePath, false, toolVersion)) { }
                    _db = new SqliteConnection(builder.ToString());
                    _db.Open();
                    RegisterFunctions();
                    Exec("PRAGMA busy_timeout=30000;");
                }
                // A report reads index pages again and again (messages by id, steps by session) and sorts large sets:
                // the same page cache as a collection; large temporary sorts may spill to disk.
                Exec("PRAGMA cache_size=-" + CacheKilobytes.ToString(System.Globalization.CultureInfo.InvariantCulture) + ";");
                Exec("PRAGMA temp_store=FILE;");
                VerifyHashMetadata();
                return;
            }
            // auto_vacuum and page_size must be chosen before the first table is created (new database only).
            Exec("PRAGMA page_size=" + PageSize.ToString(System.Globalization.CultureInfo.InvariantCulture) + ";");
            Exec("PRAGMA auto_vacuum=INCREMENTAL;");
            Exec("PRAGMA journal_mode=WAL;");
            Exec("PRAGMA synchronous=NORMAL;");
            Exec("PRAGMA temp_store=MEMORY;");
            // A collection writes large batches: a large page cache keeps the indexes in memory (with the SQLite default
            // of 2 MB, every row of a large database waits for the disk), and the WAL is copied to the database every 64 MB
            // rather than at the SQLite default of 4 MB (fewer checkpoints, each one flushed to the disk).
            Exec("PRAGMA cache_size=-" + CacheKilobytes.ToString(System.Globalization.CultureInfo.InvariantCulture) + ";");
            Exec("PRAGMA wal_autocheckpoint=16384;");
            Exec(Schema);
            Migrate();
            using (var c = Command("INSERT INTO metadata(key,value) VALUES('tool_version',@v) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"))
            {
                c.Parameters.AddWithValue("@v", toolVersion ?? "");
                c.ExecuteNonQuery();
            }
            }
            catch { _db.Dispose(); throw; }
        }

        /// <summary>Immutable FNV-1a over UTF-8 bytes; signed INTEGER is the same 64 bits. NULL stays NULL.</summary>
        public static long? MessageHash(string text)
        {
            if (text == null) return null;
            unchecked
            {
                ulong hash = 14695981039346656037UL;
                foreach (byte b in System.Text.Encoding.UTF8.GetBytes(text)) { hash ^= b; hash *= 1099511628211UL; }
                return (long)hash;
            }
        }

        void RegisterFunctions()
        {
            _db.CreateFunction<string, long?>("exl_msg_hash", MessageHash, isDeterministic: true);
            // Schema 11: the SMTP client key (peer) of a transaction, a pure function of its remote_ep. Used by the migration and the verification;
            // the collector computes the same value in C# (Identity.RemoteHost).
            _db.CreateFunction<string, string>("exl_remote_host", Identity.RemoteHost, isDeterministic: true);
        }

        void VerifyHashMetadata()
        {
            using (var c = Command("SELECT value FROM metadata WHERE key='message_hash_algorithm';"))
                if (!string.Equals(c.ExecuteScalar() as string, MessageHashAlgorithm, StringComparison.Ordinal))
                    throw new InvalidOperationException("Unknown or missing message hash algorithm; refusing incompatible lookups.");
        }

        const string Schema = @"
CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS run(
  id INTEGER PRIMARY KEY, mode TEXT, started_ms INTEGER, ended_ms INTEGER, status TEXT, host TEXT, account TEXT, version TEXT,
  files INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0, lines INTEGER NOT NULL DEFAULT 0,
  kept INTEGER NOT NULL DEFAULT 0, noise INTEGER NOT NULL DEFAULT 0, error TEXT);
CREATE TABLE IF NOT EXISTS source_file(
  id INTEGER PRIMARY KEY, server TEXT NOT NULL, kind TEXT NOT NULL, path TEXT NOT NULL,
  offset INTEGER NOT NULL DEFAULT 0, size INTEGER NOT NULL DEFAULT 0, last_write_ms INTEGER, fields TEXT,
  first_ms INTEGER, last_ms INTEGER, lines INTEGER NOT NULL DEFAULT 0, kept INTEGER NOT NULL DEFAULT 0,
  noise INTEGER NOT NULL DEFAULT 0, updated_ms INTEGER, file_key TEXT, UNIQUE(server, kind, path));
CREATE TABLE IF NOT EXISTS noise(
  run_id INTEGER NOT NULL, server TEXT NOT NULL, kind TEXT NOT NULL, reason TEXT NOT NULL, lines INTEGER NOT NULL,
  PRIMARY KEY(run_id, server, kind, reason)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS access_usage(
  day TEXT NOT NULL, server TEXT NOT NULL, user TEXT NOT NULL, protocol TEXT NOT NULL, mailbox TEXT,
  requests INTEGER NOT NULL, successes INTEGER NOT NULL, client_errors INTEGER NOT NULL, server_errors INTEGER NOT NULL,
  bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL, total_ms INTEGER NOT NULL, max_ms INTEGER NOT NULL,
  first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL, last_success_ms INTEGER NOT NULL, last_failure_ms INTEGER NOT NULL,
  client_ip TEXT, user_agent TEXT,
  PRIMARY KEY(day, server, user, protocol)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_usage_user ON access_usage(user, day);
CREATE TABLE IF NOT EXISTS access_event(
  id INTEGER PRIMARY KEY, time_ms INTEGER NOT NULL, server TEXT NOT NULL, source TEXT NOT NULL, protocol TEXT,
  user TEXT, mailbox TEXT, client_ip TEXT, user_agent TEXT, method TEXT, url TEXT, action TEXT,
  status INTEGER, sub_status INTEGER, win32 INTEGER, backend_status INTEGER, error_code TEXT, target_server TEXT,
  auth_type TEXT, routing TEXT, bytes_in INTEGER, bytes_out INTEGER, duration_ms INTEGER, outcome TEXT NOT NULL,
  request_id TEXT, recovered_ms INTEGER, errors TEXT, UNIQUE(server, source, request_id));
CREATE INDEX IF NOT EXISTS ix_event_time ON access_event(time_ms);
CREATE INDEX IF NOT EXISTS ix_event_user ON access_event(user, time_ms);
CREATE TABLE IF NOT EXISTS iis_status(
  server TEXT NOT NULL, request_id TEXT NOT NULL, time_ms INTEGER NOT NULL, status INTEGER, sub_status INTEGER,
  win32 INTEGER, time_taken INTEGER, PRIMARY KEY(server, request_id)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS smtp_transaction(
  id INTEGER PRIMARY KEY, time_ms INTEGER NOT NULL, end_ms INTEGER, server TEXT NOT NULL, direction TEXT NOT NULL,
  role TEXT, connector TEXT, session_id TEXT NOT NULL, local_ep TEXT, remote_ep TEXT, helo TEXT, tls TEXT, auth TEXT,
  mail_from TEXT, rcpt_count INTEGER, rcpts TEXT, message_id TEXT, internal_id TEXT, status TEXT, response TEXT, transcript TEXT, msg_hash INTEGER,
  UNIQUE(server, direction, session_id, time_ms));
-- 2.0.0: covering index of the SMTP aggregates of the reports (replaces ix_smtp_time).
CREATE INDEX IF NOT EXISTS ix_smtp_flow ON smtp_transaction(time_ms, server, direction, status);
-- 2.0.0 (schema 6): typed evidence of the authentication of SMTP sessions. Never holds an AUTH payload, challenge or
-- password: only the observations the resolver needs (see Engine.SmtpAuth.cs). One row per part of a session read in one file.
CREATE TABLE IF NOT EXISTS smtp_auth_fragment(
  id INTEGER PRIMARY KEY, source_file_id INTEGER, source_key TEXT NOT NULL, first_offset INTEGER NOT NULL, part INTEGER NOT NULL DEFAULT 0,
  first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL, server TEXT NOT NULL, direction TEXT NOT NULL, role TEXT NOT NULL DEFAULT '',
  connector TEXT, session_id TEXT NOT NULL, local_ep TEXT, remote_ep TEXT, helo TEXT, first_sequence INTEGER, last_sequence INTEGER,
  complete_start INTEGER NOT NULL DEFAULT 0, complete_end INTEGER NOT NULL DEFAULT 0, coverage TEXT,
  proxy_sid TEXT, proxy_ip TEXT, proxy_port INTEGER, proxy_helo TEXT, observations TEXT NOT NULL, conflicted INTEGER NOT NULL DEFAULT 0,
  origin_first_ms INTEGER, evidence_format INTEGER, conflict_positions TEXT,
  UNIQUE(server, direction, role, source_key, session_id, first_offset, first_ms, part));
CREATE TABLE IF NOT EXISTS message_event(
  id INTEGER PRIMARY KEY, time_ms INTEGER NOT NULL, server TEXT NOT NULL, event_id TEXT, source TEXT,
  message_id TEXT, internal_id TEXT, network_id TEXT, sender TEXT, recipients TEXT, recipient_status TEXT,
  recipient_count INTEGER, total_bytes INTEGER, subject TEXT, client_ip TEXT, client_host TEXT, server_ip TEXT,
  server_host TEXT, connector TEXT, source_context TEXT, related_recipient TEXT, reference TEXT,
  directionality TEXT, message_info TEXT, return_path TEXT, log_id TEXT, msg_hash INTEGER, UNIQUE(server, log_id));
-- 2.0.0: covering index of the mail flow aggregates of the reports (replaces ix_msg_time).
CREATE INDEX IF NOT EXISTS ix_msg_flow ON message_event(time_ms, server, event_id, message_id, internal_id);
CREATE TABLE IF NOT EXISTS access_action(
  day TEXT NOT NULL, server TEXT NOT NULL, protocol TEXT NOT NULL, action TEXT NOT NULL,
  requests INTEGER NOT NULL, failures INTEGER NOT NULL, slow INTEGER NOT NULL, total_ms INTEGER NOT NULL, max_ms INTEGER NOT NULL,
  PRIMARY KEY(day, server, protocol, action)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS access_client(
  day TEXT NOT NULL, user TEXT NOT NULL, protocol TEXT NOT NULL, client_ip TEXT NOT NULL, user_agent TEXT NOT NULL, device_id TEXT NOT NULL,
  device_type TEXT, software TEXT, requests INTEGER NOT NULL, failures INTEGER NOT NULL,
  first_ms INTEGER NOT NULL, last_ms INTEGER NOT NULL, servers TEXT,
  PRIMARY KEY(day, user, protocol, client_ip, user_agent, device_id)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS ix_client_user ON access_client(user, day);
CREATE TABLE IF NOT EXISTS client_session(
  id INTEGER PRIMARY KEY, skey TEXT NOT NULL, day TEXT NOT NULL, start_ms INTEGER NOT NULL, end_ms INTEGER NOT NULL,
  user TEXT NOT NULL, protocol TEXT NOT NULL, mailbox TEXT, client_ip TEXT, user_agent TEXT, device_id TEXT, device_type TEXT,
  software TEXT, client_mode TEXT, front_ends TEXT, back_ends TEXT,
  requests INTEGER NOT NULL, successes INTEGER NOT NULL, failures INTEGER NOT NULL, slow INTEGER NOT NULL,
  first_success_ms INTEGER NOT NULL, last_success_ms INTEGER NOT NULL, first_failure_ms INTEGER NOT NULL, last_failure_ms INTEGER NOT NULL,
  total_ms INTEGER NOT NULL, max_ms INTEGER NOT NULL, bytes_in INTEGER NOT NULL, bytes_out INTEGER NOT NULL,
  actions TEXT, statuses TEXT, first_error TEXT, last_error TEXT, backend TEXT, connections INTEGER NOT NULL DEFAULT 0, updated_ms INTEGER);
CREATE INDEX IF NOT EXISTS ix_session_key ON client_session(skey);
CREATE INDEX IF NOT EXISTS ix_session_time ON client_session(start_ms);
CREATE INDEX IF NOT EXISTS ix_session_user ON client_session(user, start_ms);
CREATE TABLE IF NOT EXISTS session_step(session_id INTEGER NOT NULL, time_ms INTEGER NOT NULL, data TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS ix_step_session ON session_step(session_id, time_ms);
";

        /// <summary>Schema version written in the database (0 when unknown).</summary>
        int StoredSchemaVersion()
        {
            try
            {
                using (var c = Command("SELECT value FROM metadata WHERE key='schema_version';"))
                {
                    int v;
                    return int.TryParse(Convert.ToString(c.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture), out v) ? v : 0;
                }
            }
            catch (SqliteException) { return 0; }
        }

        /// <summary>Upgrades a database created by an older version: new columns only, the data is kept.</summary>
        void Migrate()
        {
            // 2.0.0: ix_msg_flow and ix_smtp_flow (Schema) replace the indexes on the time of the tracking events and of
            // the SMTP transactions.
            Exec("DROP INDEX IF EXISTS ix_msg_time;");
            Exec("DROP INDEX IF EXISTS ix_smtp_time;");
            var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var c = Command("PRAGMA table_info(access_usage);"))
            using (var r = c.ExecuteReader()) while (r.Read()) columns.Add(r.GetString(1));
            if (!columns.Contains("slow")) Exec("ALTER TABLE access_usage ADD COLUMN slow INTEGER NOT NULL DEFAULT 0;");

            // 1.5.1: identity of a log file (file_key). Files read before are keyed from their path; when the same
            // file was read through two paths (administrative share, then local path), the row read last keeps
            // the key and the others are left without key: never matched again, removed by the retention.
            columns.Clear();
            using (var c = Command("PRAGMA table_info(source_file);"))
            using (var r = c.ExecuteReader()) while (r.Read()) columns.Add(r.GetString(1));
            if (!columns.Contains("file_key"))
            {
                Exec("ALTER TABLE source_file ADD COLUMN file_key TEXT;");
                var rows = new List<object[]>();
                using (var c = Command("SELECT id, server, kind, path FROM source_file ORDER BY COALESCE(updated_ms, 0) DESC, id DESC;"))
                using (var r = c.ExecuteReader()) while (r.Read()) rows.Add(new object[] { r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetString(3) });
                var seen = new HashSet<string>(StringComparer.Ordinal);
                using (var tx = Begin())
                using (var c = Command("UPDATE source_file SET file_key=@k WHERE id=@id;", tx))
                {
                    var key = c.Parameters.Add("@k", SqliteType.Text);
                    var id = c.Parameters.Add("@id", SqliteType.Integer);
                    foreach (var row in rows)
                    {
                        string k = FileKey((string)row[1], (string)row[3]);
                        if (!seen.Add((string)row[1] + "|" + (string)row[2] + "|" + k)) continue;
                        key.Value = k; id.Value = row[0];
                        c.ExecuteNonQuery();
                    }
                    tx.Commit();
                }
            }
            Exec("CREATE UNIQUE INDEX IF NOT EXISTS ux_source_file_key ON source_file(server, kind, file_key);");
            MigrateSmtpAuth();
            MigrateMessageHashes();
            MigrateServeRollups();
            MigrateServeSchema10();
            MigrateSchema11();
        }

        static readonly string[][] SmtpAuthColumns = {
            new[] { "auth_user", "TEXT" }, new[] { "auth_mechanism", "TEXT" }, new[] { "auth_result", "TEXT" }, new[] { "auth_attempt_result", "TEXT" },
            new[] { "auth_source", "TEXT" }, new[] { "auth_fragment_id", "INTEGER" }, new[] { "auth_sequence", "INTEGER" }, new[] { "auth_evidence_id", "INTEGER" } };

        static readonly string[][] SmtpAuthFragmentColumns = { new[] { "origin_first_ms", "INTEGER" }, new[] { "evidence_format", "INTEGER" }, new[] { "conflict_positions", "TEXT" } };

        static readonly string[][] SmtpAuthIndexes = {
            new[] { "ix_authfrag_last", "CREATE INDEX IF NOT EXISTS ix_authfrag_last ON smtp_auth_fragment(last_ms);" },
            new[] { "ux_authfrag_origin", "CREATE UNIQUE INDEX IF NOT EXISTS ux_authfrag_origin ON smtp_auth_fragment(server, direction, role, source_key, session_id, first_offset, COALESCE(origin_first_ms, first_ms), COALESCE(evidence_format, 1), part);" },
            new[] { "ix_authfrag_replay", "CREATE INDEX IF NOT EXISTS ix_authfrag_replay ON smtp_auth_fragment(server, role, direction, session_id, COALESCE(origin_first_ms, first_ms), source_key, first_offset, part, id);" },
            new[] { "ix_authfrag_candidates", "CREATE INDEX IF NOT EXISTS ix_authfrag_candidates ON smtp_auth_fragment(session_id, role, direction, first_ms, id);" },
            new[] { "ix_authfrag_proxy_page", "CREATE INDEX IF NOT EXISTS ix_authfrag_proxy_page ON smtp_auth_fragment(proxy_sid, first_ms, id) WHERE proxy_sid IS NOT NULL;" },
            new[] { "ix_authfrag_proxy_replay", "CREATE INDEX IF NOT EXISTS ix_authfrag_proxy_replay ON smtp_auth_fragment(proxy_sid, id, first_ms, last_ms) WHERE proxy_sid IS NOT NULL;" },
            new[] { "ix_authfrag_candidate_scope", "CREATE INDEX IF NOT EXISTS ix_authfrag_candidate_scope ON smtp_auth_fragment(session_id, role, direction, server, first_ms, last_ms);" },
            new[] { "ix_authfrag_origin_page", "CREATE INDEX IF NOT EXISTS ix_authfrag_origin_page ON smtp_auth_fragment(server, role, direction, session_id, COALESCE(origin_first_ms,first_ms), COALESCE(source_key,''), first_offset, id);" },
            new[] { "ix_smtp_auth_fragment", "CREATE INDEX IF NOT EXISTS ix_smtp_auth_fragment ON smtp_transaction(auth_fragment_id, auth_sequence) WHERE auth_fragment_id IS NOT NULL;" },
            new[] { "ix_smtp_auth_evidence", "CREATE INDEX IF NOT EXISTS ix_smtp_auth_evidence ON smtp_transaction(auth_evidence_id) WHERE auth_evidence_id IS NOT NULL;" },
            new[] { "ix_smtp_auth_fragment_page", "CREATE INDEX IF NOT EXISTS ix_smtp_auth_fragment_page ON smtp_transaction(auth_fragment_id, auth_sequence, id) WHERE auth_fragment_id IS NOT NULL;" },
            new[] { "ix_smtp_auth_scope", "CREATE INDEX IF NOT EXISTS ix_smtp_auth_scope ON smtp_transaction(server, role, direction, session_id, auth_fragment_id) WHERE auth_fragment_id IS NOT NULL;" } };

        /// <summary>
        /// Schema 6: the authenticated user of the SMTP transactions. Nullable columns are added in place (the rows already stored keep NULL:
        /// shown as legacy, never rebuilt, no file position changes) and their indexes are created once the columns exist; the columns,
        /// the indexes and the version are written in one transaction, so that an interrupted upgrade starts again from the old schema.
        /// It also completes a schema-6 database written before the typed evidence got its origin columns: the evidence already stored is
        /// kept and read as the first format.
        /// </summary>
        void MigrateSmtpAuth()
        {
            var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var c = Command("PRAGMA table_info(smtp_transaction);"))
            using (var r = c.ExecuteReader()) while (r.Read()) columns.Add(r.GetString(1));
            var fragmentColumns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var c = Command("PRAGMA table_info(smtp_auth_fragment);"))
            using (var r = c.ExecuteReader()) while (r.Read()) fragmentColumns.Add(r.GetString(1));
            var indexes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            using (var c = Command("SELECT name FROM sqlite_master WHERE type='index';"))
            using (var r = c.ExecuteReader()) while (r.Read()) indexes.Add(r.GetString(0));
            bool upgrade = StoredSchemaVersion() < 6;
            if (!upgrade && SmtpAuthColumns.All(d => columns.Contains(d[0])) && SmtpAuthFragmentColumns.All(d => fragmentColumns.Contains(d[0])) && SmtpAuthIndexes.All(d => indexes.Contains(d[0]))) return;
            using (var tx = Begin())
            {
                foreach (var d in SmtpAuthColumns)
                    if (!columns.Contains(d[0])) using (var c = Command("ALTER TABLE smtp_transaction ADD COLUMN " + d[0] + " " + d[1] + ";", tx)) c.ExecuteNonQuery();
                foreach (var d in SmtpAuthFragmentColumns)
                    if (!fragmentColumns.Contains(d[0])) using (var c = Command("ALTER TABLE smtp_auth_fragment ADD COLUMN " + d[0] + " " + d[1] + ";", tx)) c.ExecuteNonQuery();
                foreach (var d in SmtpAuthIndexes) using (var c = Command(d[1], tx)) c.ExecuteNonQuery();
                if (upgrade) using (var c = Command("INSERT INTO metadata(key,value) VALUES('schema_version','6') ON CONFLICT(key) DO UPDATE SET value=excluded.value;", tx)) c.ExecuteNonQuery();
                tx.Commit();
            }
        }

        /// <summary>
        /// Schema 7: one SQL backfill, index replacement and version change in a single transaction.
        /// External writable SQLite clients must register exl_msg_hash with MessageHashAlgorithm semantics;
        /// inserts/message-id updates without it fail rather than silently creating unsearchable rows.
        /// Hashes are nonunique accelerators only: every lookup must also compare the original binary TEXT.
        /// </summary>
        void MigrateMessageHashes()
        {
            if (StoredSchemaVersion() >= 7) { VerifyHashMetadata(); EnsureMessageHashTriggers(); return; }
            using (var c = Command("SELECT value FROM metadata WHERE key='message_hash_algorithm';"))
            {
                object algorithm = c.ExecuteScalar();
                if (algorithm != null && !(algorithm is DBNull) && !string.Equals(algorithm as string, MessageHashAlgorithm, StringComparison.Ordinal))
                    throw new InvalidOperationException("Cannot change an existing message hash algorithm.");
            }
            using (var tx = Begin())
            {
                foreach (string table in new[] { "message_event", "smtp_transaction" })
                {
                    bool exists = false;
                    using (var c = Command("PRAGMA table_info(" + table + ");", tx))
                    using (var r = c.ExecuteReader()) while (r.Read()) if (r.GetString(1) == "msg_hash") exists = true;
                    if (!exists) using (var c = Command("ALTER TABLE " + table + " ADD COLUMN msg_hash INTEGER;", tx)) c.ExecuteNonQuery();
                    using (var c = Command("UPDATE " + table + " SET msg_hash=exl_msg_hash(message_id);", tx)) c.ExecuteNonQuery();
               }
                EnsureMessageHashTriggers(tx);
                using (var c = Command("DROP INDEX IF EXISTS ix_msg_id; DROP INDEX IF EXISTS ix_smtp_message;" +
                    "INSERT INTO metadata(key,value) VALUES('message_hash_algorithm','" + MessageHashAlgorithm + "') ON CONFLICT(key) DO NOTHING;" +
                    "INSERT INTO metadata(key,value) VALUES('schema_version','7') ON CONFLICT(key) DO UPDATE SET value=excluded.value;", tx)) c.ExecuteNonQuery();
                tx.Commit();
            }
        }

        void EnsureMessageHashTriggers(SqliteTransaction transaction = null)
        {
            var changes = new List<string[]>();
            foreach (string table in new[] { "message_event", "smtp_transaction" })
                foreach (bool insert in new[] { true, false })
                {
                    string name = "tr_" + table + (insert ? "_hash_insert" : "_hash_update");
                    // Production inserts bind the hash, so the common path validates it without a second row/index write.
                    // Raw/legacy SQL still repairs missing or incorrect values, including direct edits to msg_hash.
                    string sql = MessageHashTriggerSql(table, insert);
                    using (var c = Command("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=@n;", transaction))
                    {
                        c.Parameters.AddWithValue("@n", name);
                        if (string.Equals((c.ExecuteScalar() as string ?? "").TrimEnd(';'), sql, StringComparison.Ordinal)) continue;
                    }
                    changes.Add(new[] { name, sql });
                }
            if (changes.Count == 0) return;
            SqliteTransaction tx = transaction ?? Begin();
            try
            {
                foreach (var change in changes)
                    using (var c = Command("DROP TRIGGER IF EXISTS " + change[0] + ";" + change[1] + ";", tx)) c.ExecuteNonQuery();
                if (transaction == null) tx.Commit();
            }
            finally { if (transaction == null) tx.Dispose(); }
        }

        internal static string MessageHashTriggerSql(string table, bool insert)
        {
            return "CREATE TRIGGER tr_" + table + (insert ? "_hash_insert" : "_hash_update") +
                " AFTER " + (insert ? "INSERT" : "UPDATE OF message_id,msg_hash") +
                " ON " + table + " WHEN NEW.msg_hash IS NOT exl_msg_hash(NEW.message_id)" +
                " BEGIN UPDATE " + table + " SET msg_hash=exl_msg_hash(NEW.message_id) WHERE id=NEW.id; END";
        }

        /// <summary>
        /// Explicit, lossless maintenance for an operator-selected copy. No VACUUM, retention or automatic call.
        /// Only display text is eligible; SQL-filtered, indexed and identity columns are never packed.
        /// Each transaction retains at most 128 rows / approximately 4 MiB, apart from one oversized row.
        /// Unknown BLOB formats are left byte-for-byte intact.
        /// </summary>
        /// <returns>Number of cells whose stored representation changed.</returns>
        public long RepackSafeText()
        {
            if (ReadOnly) throw new InvalidOperationException("Repacking requires a writable copy.");
            long changed = 0;
            // observations stays TEXT: the existing evidence/replay contract uses SQLite JSON and replace() on it.
            foreach (var fields in new[] {
                new[] { "access_event", "url", "errors" },
                new[] { "client_session", "actions", "statuses" }, new[] { "smtp_transaction", "response" } })
            {
                string table = fields[0], columns = string.Join(",", fields.Skip(1));
                long after = long.MinValue;
                bool first = true;
                while (true)
                {
                    var rows = new List<object[]>();
                    long bytes = 0;
                    using (var tx = Begin())
                    {
                        using (var c = Command("SELECT id," + columns + " FROM " + table + (first ? "" : " WHERE id>@id") + " ORDER BY id LIMIT 128;", tx))
                        {
                            if (!first) c.Parameters.AddWithValue("@id", after);
                            using (var r = c.ExecuteReader())
                                while (r.Read())
                                {
                                    var row = new object[fields.Length];
                                    row[0] = r.GetInt64(0);
                                    for (int i = 1; i < row.Length; i++)
                                    {
                                        object value = r.IsDBNull(i) ? null : r.GetValue(i);
                                        row[i] = value;
                                        bytes += value is string ? ((string)value).Length * 2L : value is byte[] ? ((byte[])value).Length : 0;
                                    }
                                    rows.Add(row);
                                    if (bytes >= 4L * 1048576) break;
                                }
                        }
                        using (var c = Command("UPDATE " + table + " SET " + string.Join(",", fields.Skip(1).Select((f, i) => f + "=@v" + i)) + " WHERE id=@id;", tx))
                        {
                            c.Parameters.Add("@id", SqliteType.Integer);
                            for (int i = 1; i < fields.Length; i++) c.Parameters.Add(new SqliteParameter("@v" + (i - 1), DBNull.Value));
                            foreach (var row in rows)
                            {
                                long cells = 0;
                                for (int i = 1; i < row.Length; i++)
                                {
                                    object before = row[i], decoded = Packed.Unpack(before);
                                    object next = decoded is string ? Packed.Adaptive((string)decoded) : before;
                                    bool same = before is byte[] && next is byte[] ? ((byte[])before).SequenceEqual((byte[])next) : Equals(before, next);
                                    if (!same) cells++;
                                    var p = c.Parameters[i];
                                    p.SqliteType = next is byte[] ? SqliteType.Blob : SqliteType.Text;
                                    p.Value = next ?? DBNull.Value;
                                }
                                if (cells > 0) { c.Parameters[0].Value = row[0]; c.ExecuteNonQuery(); changed += cells; }
                                after = (long)row[0]; first = false;
                            }
                        }
                        tx.Commit();
                    }
                    if (rows.Count == 0) break;
                }
            }
            return changed;
        }

        static readonly System.Text.RegularExpressions.Regex AdminShareRx =
            new System.Text.RegularExpressions.Regex(@"^\\\\([^\\]+)\\([A-Za-z])\$(\\.*)?$", System.Text.RegularExpressions.RegexOptions.Compiled);

        /// <summary>
        /// Identity of a log file whatever the path used to reach it: a path through the administrative share of
        /// its own server (\\EXCH01\D$\Logs\x.log) is the local path on that server (D:\Logs\x.log), and the case
        /// is ignored (Windows paths). The collector reads a file through its share until -Mode Discover writes
        /// its local path, and Exchange may return a folder in another case: the file is not read twice.
        /// </summary>
        public static string FileKey(string server, string path)
        {
            if (string.IsNullOrEmpty(path)) return path;
            string p = path.Trim();
            var m = AdminShareRx.Match(p);
            if (m.Success && string.Equals(m.Groups[1].Value.Split('.')[0], (server ?? "").Split('.')[0], StringComparison.OrdinalIgnoreCase))
                p = m.Groups[2].Value + ":" + (m.Groups[3].Success && m.Groups[3].Length > 0 ? m.Groups[3].Value : "\\");
            return p.ToUpperInvariant();
        }

        internal SqliteConnection Connection { get { return _db; } }

        public SqliteTransaction Begin() { return _db.BeginTransaction(); }

        internal SqliteCommand Command(string sql, SqliteTransaction tx = null)
        {
            var c = _db.CreateCommand();
            c.CommandText = sql;
            c.Transaction = tx ?? _reportSnapshot;
            c.CommandTimeout = 0;
            return c;
        }

        internal void BeginReportSnapshot()
        {
            if (_reportSnapshot != null) throw new InvalidOperationException("A report snapshot is already active.");
            _reportSnapshot = _db.BeginTransaction(deferred: true);
        }

        internal void EndReportSnapshot()
        {
            var snapshot = _reportSnapshot;
            _reportSnapshot = null;
            if (snapshot != null) snapshot.Dispose();
        }

        internal SqliteCommand Command(string sql, IDictionary<string, object> parameters, SqliteTransaction tx = null)
        {
            var c = Command(sql, tx);
            if (parameters != null) foreach (var p in parameters) c.Parameters.AddWithValue(p.Key, p.Value ?? DBNull.Value);
            return c;
        }

        public void Exec(string sql)
        {
            using (var c = Command(sql)) c.ExecuteNonQuery();
        }

        /// <summary>
        /// Enables or disables trigger execution on THIS connection only (SQLITE_DBCONFIG_ENABLE_TRIGGER); the triggers stay defined in the
        /// database and run for every other connection. SQLite decides at prepare time, so statements must be prepared after the change.
        /// Returns the state before the call, or null when the setting could not be read or applied.
        /// </summary>
        internal bool? SetTriggersEnabled(bool enabled)
        {
            int before, after;
            if (SQLitePCL.raw.sqlite3_db_config(_db.Handle, SQLitePCL.raw.SQLITE_DBCONFIG_ENABLE_TRIGGER, -1, out before) != SQLitePCL.raw.SQLITE_OK) return null;
            if (SQLitePCL.raw.sqlite3_db_config(_db.Handle, SQLitePCL.raw.SQLITE_DBCONFIG_ENABLE_TRIGGER, enabled ? 1 : 0, out after) != SQLitePCL.raw.SQLITE_OK || (after != 0) != enabled) return null;
            return before != 0;
        }

        public long Scalar(string sql, Hashtable parameters)
        {
            using (var c = Command(sql, ToDictionary(parameters)))
            {
                object v = c.ExecuteScalar();
                return v == null || v is DBNull ? 0 : Convert.ToInt64(v);
            }
        }

        /// <summary>Runs a query and returns all rows (used by PowerShell for the status views).</summary>
        public TableResult Query(string sql, Hashtable parameters)
        {
            var result = new TableResult();
            using (var c = Command(sql, ToDictionary(parameters)))
            using (var r = c.ExecuteReader())
            {
                result.Columns = new string[r.FieldCount];
                for (int i = 0; i < r.FieldCount; i++) result.Columns[i] = r.GetName(i);
                while (r.Read())
                {
                    var row = new object[r.FieldCount];
                    for (int i = 0; i < r.FieldCount; i++) row[i] = r.IsDBNull(i) ? null : Packed.Unpack(r.GetValue(i));
                    result.Rows.Add(row);
                }
            }
            return result;
        }

        static Dictionary<string, object> ToDictionary(Hashtable h)
        {
            var d = new Dictionary<string, object>();
            if (h != null) foreach (DictionaryEntry e in h) d["@" + e.Key.ToString().TrimStart('@')] = e.Value;
            return d;
        }

        // ---------------------------------------------------------------- executions

        public long StartRun(string mode, string host, string account, string version)
        {
            using (var c = Command("INSERT INTO run(mode,started_ms,status,host,account,version) VALUES(@m,@s,'Running',@h,@a,@v) RETURNING id;"))
            {
                c.Parameters.AddWithValue("@m", mode);
                c.Parameters.AddWithValue("@s", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                c.Parameters.AddWithValue("@h", (object)host ?? DBNull.Value);
                c.Parameters.AddWithValue("@a", (object)account ?? DBNull.Value);
                c.Parameters.AddWithValue("@v", (object)version ?? DBNull.Value);
                return Convert.ToInt64(c.ExecuteScalar());
            }
        }

        public void EndRun(long runId, string status, long files, long bytes, long lines, long kept, long noise, string error)
        {
            using (var c = Command("UPDATE run SET ended_ms=@e,status=@st,files=@f,bytes=@b,lines=@l,kept=@k,noise=@n,error=@err WHERE id=@id;"))
            {
                c.Parameters.AddWithValue("@e", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                c.Parameters.AddWithValue("@st", status);
                c.Parameters.AddWithValue("@f", files); c.Parameters.AddWithValue("@b", bytes); c.Parameters.AddWithValue("@l", lines);
                c.Parameters.AddWithValue("@k", kept); c.Parameters.AddWithValue("@n", noise);
                c.Parameters.AddWithValue("@err", (object)error ?? DBNull.Value);
                c.Parameters.AddWithValue("@id", runId);
                c.ExecuteNonQuery();
            }
        }

        /// <summary>Executions left "Running" by an interrupted process are closed as "Interrupted".</summary>
        public long CloseAbandonedRuns()
        {
            using (var c = Command("UPDATE run SET status='Interrupted', ended_ms=COALESCE(ended_ms,started_ms) WHERE status='Running';"))
                return c.ExecuteNonQuery();
        }

        // ---------------------------------------------------------------- files

        /// <summary>
        /// Read position of every known file, keyed "server|kind|FileKey" (the collection plan skips the files read to
        /// their end). A file whose position is before its end (an SMTP, IMAP or POP session still open when it was
        /// read) is read again even if it did not grow: once the file is idle, the held session is written.
        /// </summary>
        public Dictionary<string, FileState> KnownFiles()
        {
            var d = new Dictionary<string, FileState>(StringComparer.OrdinalIgnoreCase);
            // The header text comes from the dictionary (schema 10); a row without fields_id keeps being read from its own fields column.
            using (var c = Command("SELECT s.id,s.server,s.kind,s.path,s.file_key,s.offset,s.size,s.last_write_ms,COALESCE(d.text,s.fields),s.first_ms,s.last_ms,s.lines,s.kept,s.noise FROM source_file s LEFT JOIN source_fields d ON d.id=s.fields_id WHERE s.file_key IS NOT NULL;"))
            using (var r = c.ExecuteReader())
                while (r.Read())
                {
                    var f = new FileState
                    {
                        Id = r.GetInt64(0), Server = r.GetString(1), Kind = r.GetString(2), Path = r.GetString(3),
                        Offset = r.GetInt64(5), Size = r.GetInt64(6), LastWriteMs = r.IsDBNull(7) ? 0 : r.GetInt64(7),
                        Fields = r.IsDBNull(8) ? null : r.GetString(8), FirstMs = r.IsDBNull(9) ? 0 : r.GetInt64(9),
                        LastMs = r.IsDBNull(10) ? 0 : r.GetInt64(10), Lines = r.GetInt64(11), Kept = r.GetInt64(12), Noise = r.GetInt64(13)
                    };
                    d[f.Server + "|" + f.Kind + "|" + r.GetString(4)] = f;
                }
            return d;
        }

        /// <summary>
        /// Id of the source_file row of a file (created if needed): timeline steps keep it to tell which log
        /// file holds the raw line of a request. The path of a new row is the one used to read it.
        /// </summary>
        public long FileId(FileState f, SqliteTransaction tx)
        {
            if (f.Id > 0) return f.Id;
            using (var c = Command(@"INSERT INTO source_file(server,kind,path,file_key,offset,size,updated_ms) VALUES(@s,@k,@p,@fk,@o,@z,@u) ON CONFLICT DO NOTHING;
UPDATE source_file SET file_key=@fk WHERE server=@s AND kind=@k AND path=@p AND file_key IS NULL
  AND NOT EXISTS (SELECT 1 FROM source_file WHERE server=@s AND kind=@k AND file_key=@fk);
SELECT id FROM source_file WHERE server=@s AND kind=@k AND file_key=@fk;", tx))
            {
                c.Parameters.AddWithValue("@s", f.Server); c.Parameters.AddWithValue("@k", f.Kind); c.Parameters.AddWithValue("@p", f.Path);
                c.Parameters.AddWithValue("@fk", FileKey(f.Server, f.Path));
                c.Parameters.AddWithValue("@o", f.Offset); c.Parameters.AddWithValue("@z", f.Size);
                c.Parameters.AddWithValue("@u", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                f.Id = Convert.ToInt64(c.ExecuteScalar());
                return f.Id;
            }
        }

        /// <summary>Saves the read position of a file (row found by FileId; its stored path is kept).</summary>
        public void SaveFile(FileState f, SqliteTransaction tx)
        {
            FileId(f, tx);
            // The header text is written once in source_fields (exact text, compared as BINARY); the row only keeps its id.
            object fieldsId = DBNull.Value;
            if (f.Fields != null)
                using (var q = Command("INSERT INTO source_fields(text) VALUES(@t) ON CONFLICT(text) DO UPDATE SET text=excluded.text RETURNING id;", tx))
                {
                    q.Parameters.AddWithValue("@t", f.Fields);
                    fieldsId = Convert.ToInt64(q.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture);
                }
            using (var c = Command(@"UPDATE source_file SET offset=@o,size=@z,last_write_ms=@w,fields=NULL,fields_id=@f,first_ms=@fm,last_ms=@lm,lines=@l,kept=@kp,noise=@n,updated_ms=@u WHERE id=@id;", tx))
            {
                c.Parameters.AddWithValue("@id", f.Id);
                c.Parameters.AddWithValue("@o", f.Offset); c.Parameters.AddWithValue("@z", f.Size); c.Parameters.AddWithValue("@w", f.LastWriteMs);
                c.Parameters.AddWithValue("@f", fieldsId);
                c.Parameters.AddWithValue("@fm", f.FirstMs > 0 ? (object)f.FirstMs : DBNull.Value);
                c.Parameters.AddWithValue("@lm", f.LastMs > 0 ? (object)f.LastMs : DBNull.Value);
                c.Parameters.AddWithValue("@l", f.Lines); c.Parameters.AddWithValue("@kp", f.Kept); c.Parameters.AddWithValue("@n", f.Noise);
                c.Parameters.AddWithValue("@u", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                c.ExecuteNonQuery();
            }
        }

        public void AddNoise(long runId, string server, string kind, Dictionary<string, long> reasons, SqliteTransaction tx)
        {
            if (reasons == null || reasons.Count == 0) return;
            using (var c = Command(@"INSERT INTO noise(run_id,server,kind,reason,lines) VALUES(@r,@s,@k,@why,@n)
ON CONFLICT(run_id,server,kind,reason) DO UPDATE SET lines=lines+excluded.lines;", tx))
            {
                var pr = c.Parameters.Add("@r", SqliteType.Integer); var ps = c.Parameters.Add("@s", SqliteType.Text);
                var pk = c.Parameters.Add("@k", SqliteType.Text); var pw = c.Parameters.Add("@why", SqliteType.Text);
                var pn = c.Parameters.Add("@n", SqliteType.Integer);
                foreach (var kv in reasons)
                {
                    pr.Value = runId; ps.Value = server; pk.Value = kind; pw.Value = kv.Key; pn.Value = kv.Value;
                    c.ExecuteNonQuery();
                }
            }
        }

        // ---------------------------------------------------------------- retention

        /// <summary>
        /// Deletes what is older than the retention. Aggregates, SMTP transactions and message tracking
        /// follow RetentionDays; request-level failures and SMTP transcripts follow DetailRetentionDays.
        /// </summary>
        public PurgeResult Purge(long retentionCutoffMs, string retentionCutoffDay, long detailCutoffMs)
        {
            var p = new PurgeResult();
            var clock = System.Diagnostics.Stopwatch.StartNew();
            // The rollup DELETE triggers must run for every row removed here (a collection on this connection turns them off only while it applies).
            if (SetTriggersEnabled(true) == null) throw new InvalidOperationException("The triggers of the database connection could not be enabled; nothing was deleted.");
            using (var tx = Begin())
            {
                p.Usage = Delete("DELETE FROM access_usage WHERE day < @d;", "@d", retentionCutoffDay, tx);
                p.Actions = Delete("DELETE FROM access_action WHERE day < @d;", "@d", retentionCutoffDay, tx);
                p.Clients = Delete("DELETE FROM access_client WHERE day < @d;", "@d", retentionCutoffDay, tx);
                // start_ms <= end_ms: the index on start_ms finds the old sessions without reading all of them.
                Delete("DELETE FROM session_step WHERE session_id IN (SELECT id FROM client_session WHERE start_ms < @t AND end_ms < @t);", "@t", detailCutoffMs, tx);
                p.Sessions = Delete("DELETE FROM client_session WHERE start_ms < @t AND end_ms < @t;", "@t", detailCutoffMs, tx);
                p.Events = Delete("DELETE FROM access_event WHERE time_ms < @t;", "@t", detailCutoffMs, tx);
                p.IisStatus = Delete("DELETE FROM iis_status WHERE time_ms < @t;", "@t", detailCutoffMs, tx);
                p.Transcripts = Delete("UPDATE smtp_transaction SET transcript=NULL WHERE transcript IS NOT NULL AND time_ms < @t;", "@t", detailCutoffMs, tx);
                p.Smtp = Delete("DELETE FROM smtp_transaction WHERE time_ms < @t;", "@t", retentionCutoffMs, tx);
                // The evidence of a retained transaction outlives its transcript: a fragment goes only when nothing retained uses it,
                // neither the transactions of its session nor a back-end session proxied from it.
                p.AuthFragments = Delete(@"DELETE FROM smtp_auth_fragment WHERE last_ms < @t
 AND NOT EXISTS (SELECT 1 FROM smtp_transaction t WHERE t.auth_fragment_id = smtp_auth_fragment.id)
 AND NOT EXISTS (SELECT 1 FROM smtp_transaction t WHERE t.auth_evidence_id = smtp_auth_fragment.id)
 AND NOT EXISTS (SELECT 1 FROM smtp_transaction t WHERE t.server = smtp_auth_fragment.server AND t.direction = smtp_auth_fragment.direction AND t.role = smtp_auth_fragment.role AND t.session_id = smtp_auth_fragment.session_id)
 AND NOT EXISTS (SELECT 1 FROM smtp_auth_fragment b JOIN smtp_transaction bt ON bt.auth_fragment_id = b.id
                 WHERE b.proxy_sid = smtp_auth_fragment.session_id AND b.first_ms BETWEEN smtp_auth_fragment.first_ms - 3600000 AND smtp_auth_fragment.last_ms + 3600000);", "@t", retentionCutoffMs, tx);
                p.Messages = Delete("DELETE FROM message_event WHERE time_ms < @t;", "@t", retentionCutoffMs, tx);
                p.Runs = Delete("DELETE FROM noise WHERE run_id IN (SELECT id FROM run WHERE started_ms < @t);", "@t", retentionCutoffMs, tx);
                p.Runs = Delete("DELETE FROM run WHERE started_ms < @t;", "@t", retentionCutoffMs, tx);
                // Positions of files that Exchange deleted long ago are no longer needed.
                p.Files = Delete("DELETE FROM source_file WHERE COALESCE(last_write_ms,0) < @t;", "@t", retentionCutoffMs, tx);
                // The delete triggers queued the buckets of the removed transactions (a bucket cut by the cutoff is recomputed from what remains).
                ReconcileSmtpClients(tx);
                ReconcileMessageRollups(tx);
                tx.Commit();
            }
            p.DeleteSeconds = clock.Elapsed.TotalSeconds;
            Exec("PRAGMA incremental_vacuum;");
            p.VacuumSeconds = clock.Elapsed.TotalSeconds - p.DeleteSeconds;
            // ANALYZE of the tables that need it, on a sample: a full analysis of a large database reads all of it.
            Exec("PRAGMA analysis_limit=1000;");
            Exec("PRAGMA optimize;");
            p.OptimizeSeconds = clock.Elapsed.TotalSeconds - p.DeleteSeconds - p.VacuumSeconds;
            return p;
        }

        long Delete(string sql, string name, object value, SqliteTransaction tx)
        {
            using (var c = Command(sql, tx)) { c.Parameters.AddWithValue(name, value); return c.ExecuteNonQuery(); }
        }

        /// <summary>Writes the WAL into the database file (smaller files to copy, consistent backups).</summary>
        public void Checkpoint()
        {
            if (ReadOnly) return;
            Exec("PRAGMA wal_checkpoint(TRUNCATE);");
            // A collection copies the WAL itself (Collector.Checkpoints): automatic copies again afterwards.
            Exec("PRAGMA wal_autocheckpoint=16384;");
        }

        /// <summary>
        /// One checkpoint of the given mode (PASSIVE, FULL, RESTART or TRUNCATE) on this connection, outside any transaction, and its row:
        /// busy (0: not blocked), frames in the log, frames copied into the database (-1 when unknown). Unlike Checkpoint() it leaves
        /// wal_autocheckpoint as it is (a collection keeps it off while it runs).
        /// </summary>
        public WalCheckpoint Checkpoint(string mode)
        {
            if (ReadOnly) throw new InvalidOperationException("A checkpoint requires a writable store.");
            string m = (mode ?? "").Trim().ToUpperInvariant();
            if (m != "PASSIVE" && m != "FULL" && m != "RESTART" && m != "TRUNCATE") throw new ArgumentOutOfRangeException(nameof(mode), mode, "PASSIVE, FULL, RESTART or TRUNCATE.");
            using (var c = Command("PRAGMA wal_checkpoint(" + m + ");"))
            using (var r = c.ExecuteReader())
            {
                if (!r.Read()) return new WalCheckpoint { Busy = 1, Log = -1, Checkpointed = -1 };
                return new WalCheckpoint { Busy = r.GetInt64(0), Log = r.GetInt64(1), Checkpointed = r.GetInt64(2) };
            }
        }

        /// <summary>Size of the WAL file (written but not yet copied into the database).</summary>
        public long WalBytes { get { var f = new FileInfo(FilePath + "-wal"); return f.Exists ? f.Length : 0; } }

        public long FileBytes
        {
            get
            {
                long total = 0;
                foreach (var suffix in new[] { "", "-wal", "-shm" })
                {
                    var f = new FileInfo(FilePath + suffix);
                    if (f.Exists) total += f.Length;
                }
                return total;
            }
        }

        public void Dispose() { _db.Dispose(); }
    }
}
