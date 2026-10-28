// =============================================================================
//  Exchange Log Report - engine: SMTP clients (schema 11)
// -----------------------------------------------------------------------------
//  Serve groups the SMTP transactions of a selection by client: (server NOCASE, direction, role, connector, peer, HELO, account), where the
//  peer is the lower-case address of remote_ep and the account is the authenticated user (retired 'Overflow' evidence counts as none). A
//  transaction without an observed endpoint is a group of its own. Schema 11 keeps that grouping in the database so a list does not have to
//  read and group every transaction of the period:
//
//    smtp_client_value   dictionary of the text values of the aggregates (code 0 = NULL, never stored)
//    smtp_client         one row per group (the dimension); smtp_transaction.client_id points at it (NULL = no observed endpoint)
//    smtp_client_hour    one additive row per client x UTC hour x (status, tls, mechanism, result, attempt, source) with the counters
//    smtp_client_pending transactions written by a connection that did not maintain the structures (triggers), to be re-keyed
//    smtp_client_dirty   client x hour buckets to be recomputed from the transaction rows (updates, deletes, retention)
//
//  The collector maintains the structures itself (SmtpClientMaintenance) while it applies a batch, in the batch transaction; every other
//  writer (external SQL, retention, a collection that keeps the triggers on) is covered by the triggers, which only queue work for
//  ReconcileSmtpClients. Serve never reconciles: while the queues are not empty it answers 503 SmtpClientsPending.
//  The structures are derived data: VerifySmtpClients recomputes them from the transactions and compares.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    public sealed class SmtpClientVerification
    {
        public bool Verified { get; internal set; }
        public long Clients { get; internal set; }
        public long HourRows { get; internal set; }
        public long Values { get; internal set; }
    }

    public sealed partial class Store
    {
        internal const long HourMs = 3600000L;
        internal static long FloorHour(long t) { return t - ((t % HourMs + HourMs) % HourMs); }
        internal static long CeilHour(long t) { long h = FloorHour(t); return h == t ? t : h + HourMs; }

        // ---------------------------------------------------------------- schema 11 objects (canonical definitions)
        internal const string SmtpClientValueTableSql = "CREATE TABLE smtp_client_value(id INTEGER PRIMARY KEY, text TEXT NOT NULL UNIQUE)";
        internal const string SmtpClientTableSql = "CREATE TABLE smtp_client(id INTEGER PRIMARY KEY, server TEXT NOT NULL, direction TEXT NOT NULL, role TEXT, connector TEXT, remote_host TEXT NOT NULL, helo TEXT, account TEXT)";
        internal const string SmtpClientHourTableSql = "CREATE TABLE smtp_client_hour(client_id INTEGER NOT NULL, hour_ms INTEGER NOT NULL, status INTEGER NOT NULL, tls INTEGER NOT NULL, mechanism INTEGER NOT NULL, result INTEGER NOT NULL, attempt INTEGER NOT NULL, source INTEGER NOT NULL, n INTEGER NOT NULL, rcpts INTEGER NOT NULL, min_id INTEGER NOT NULL, min_ms INTEGER NOT NULL, max_ms INTEGER NOT NULL, PRIMARY KEY(client_id,hour_ms,status,tls,mechanism,result,attempt,source)) WITHOUT ROWID";
        internal const string SmtpClientPendingTableSql = "CREATE TABLE smtp_client_pending(tx_id INTEGER PRIMARY KEY)";
        internal const string SmtpClientDirtyTableSql = "CREATE TABLE smtp_client_dirty(client_id INTEGER NOT NULL, hour_ms INTEGER NOT NULL, PRIMARY KEY(client_id,hour_ms)) WITHOUT ROWID";
        internal static readonly string[][] SmtpClientTables = {
            new[] { "smtp_client_value", SmtpClientValueTableSql }, new[] { "smtp_client", SmtpClientTableSql }, new[] { "smtp_client_hour", SmtpClientHourTableSql },
            new[] { "smtp_client_pending", SmtpClientPendingTableSql }, new[] { "smtp_client_dirty", SmtpClientDirtyTableSql } };
        // NULL and '' must stay distinct (Serve groups with IS): a NULL is indexed as an empty BLOB, which never equals a TEXT value.
        internal static readonly string[][] SmtpClientIndexes = {
            new[] { "ux_smtp_client", "smtp_client", "CREATE UNIQUE INDEX ux_smtp_client ON smtp_client(remote_host, ifnull(helo,x''), server COLLATE NOCASE, direction, ifnull(role,x''), ifnull(connector,x''), ifnull(account,x''))" },
            new[] { "ix_smtp_client", "smtp_transaction", "CREATE INDEX ix_smtp_client ON smtp_transaction(client_id, time_ms)" },
            new[] { "ix_smtp_unknown_peer", "smtp_transaction", "CREATE INDEX ix_smtp_unknown_peer ON smtp_transaction(time_ms) WHERE client_id IS NULL" },
            new[] { "ix_smtp_client_hour", "smtp_client_hour", "CREATE INDEX ix_smtp_client_hour ON smtp_client_hour(hour_ms, client_id)" } };
        /// <summary>Columns whose change moves a transaction between buckets (client_id itself is deliberately absent: the reconciliation writes it, with no loop).</summary>
        const string SmtpClientTriggerColumns = "id,time_ms,server,direction,role,connector,remote_ep,helo,tls,rcpt_count,status,auth_user,auth_mechanism,auth_result,auth_attempt_result,auth_source";
        const string SmtpClientOldBucket = "INSERT OR IGNORE INTO smtp_client_dirty SELECT OLD.client_id,OLD.time_ms-((OLD.time_ms%3600000+3600000)%3600000) WHERE OLD.client_id IS NOT NULL;";
        internal static readonly string[][] SmtpClientTriggers = {
            new[] { "tr_smtp_transaction_client_insert", "CREATE TRIGGER tr_smtp_transaction_client_insert AFTER INSERT ON smtp_transaction BEGIN INSERT OR IGNORE INTO smtp_client_pending VALUES(NEW.id); END" },
            new[] { "tr_smtp_transaction_client_update", "CREATE TRIGGER tr_smtp_transaction_client_update AFTER UPDATE OF " + SmtpClientTriggerColumns + " ON smtp_transaction BEGIN " + SmtpClientOldBucket + " INSERT OR IGNORE INTO smtp_client_pending VALUES(NEW.id); END" },
            new[] { "tr_smtp_transaction_client_delete", "CREATE TRIGGER tr_smtp_transaction_client_delete AFTER DELETE ON smtp_transaction BEGIN " + SmtpClientOldBucket + " END" } };

        // The display values of ClientSelection, as SQL (the same expressions as the schema-10 query).
        const string TxAccount = "CASE WHEN e.auth_source='Overflow' THEN NULL ELSE e.auth_user END";
        internal const string TxMechanism = "CASE WHEN e.auth_source='Overflow' THEN 'Not available' WHEN e.auth_mechanism IS NOT NULL THEN e.auth_mechanism WHEN e.auth_source='NotApplicable' THEN 'None' ELSE 'Not available' END";
        internal const string TxResult = "CASE WHEN e.auth_source='Overflow' THEN 'Unknown' ELSE COALESCE(e.auth_result,'Unknown') END";
        internal const string TxAttempt = "CASE WHEN e.auth_source='Overflow' THEN 'Unknown' ELSE COALESCE(e.auth_attempt_result,'Unknown') END";
        const string TxHour = "(e.time_ms-((e.time_ms%3600000+3600000)%3600000))";

        /// <summary>Creates the tables, indexes and triggers of the SMTP client structures (empty), inside the caller's transaction. The column smtp_transaction.client_id must exist.</summary>
        void CreateSmtpClientObjects(SqliteTransaction tx, bool triggers)
        {
            foreach (var table in SmtpClientTables) using (var c = Command(table[1] + ";", tx)) c.ExecuteNonQuery();
            if (triggers)
                foreach (var trigger in SmtpClientTriggers) using (var c = Command(trigger[1] + ";", tx)) c.ExecuteNonQuery();
        }

        /// <summary>
        /// Schema 11 (inside the caller's migration transaction): adds smtp_transaction.client_id, derives the dimension, the client of every
        /// transaction, the value dictionary and the hourly aggregates from the stored transactions with one sequential scan, then proves the
        /// result with the same recomputation VerifySmtpClients uses. Any difference throws, which rolls back the whole migration.
        /// The triggers are created last, so that none of the statements above queue work.
        /// </summary>
        void BuildSmtpClients(SqliteTransaction tx)
        {
            bool column = false;
            using (var c = Command("PRAGMA table_info(smtp_transaction);", tx))
            using (var r = c.ExecuteReader()) while (r.Read()) if (string.Equals(r.GetString(1), "client_id", StringComparison.OrdinalIgnoreCase)) column = true;
            if (!column) using (var c = Command("ALTER TABLE smtp_transaction ADD COLUMN client_id INTEGER;", tx)) c.ExecuteNonQuery();
            CreateSmtpClientObjects(tx, false);
            using (var c = Command(SmtpClientIndexes[0][2] + ";", tx)) c.ExecuteNonQuery();
            // One scan: every group key x hour x display values, with its counters, in a temporary table. Unknown peers are never grouped.
            Exec(tx, "CREATE TEMP TABLE smtp_client_scan AS SELECT MIN(e.id) AS mi,e.server AS server,e.direction AS direction,e.role AS role,e.connector AS connector,exl_remote_host(e.remote_ep) AS h,e.helo AS helo," +
                TxAccount + " AS a," + TxHour + " AS hour,e.status AS st,e.tls AS tl," + TxMechanism + " AS me," + TxResult + " AS re," + TxAttempt + " AS att,e.auth_source AS so," +
                "COUNT(*) AS n,SUM(COALESCE(e.rcpt_count,0)) AS rc,MIN(e.time_ms) AS fm,MAX(e.time_ms) AS lm FROM smtp_transaction e NOT INDEXED WHERE exl_remote_host(e.remote_ep) IS NOT NULL " +
                "GROUP BY e.server COLLATE NOCASE,e.direction,e.role,e.connector,h,e.helo,a,hour,st,tl,me,re,att,so;");
            // One dimension row per group (the server keeps the spelling of its first transaction: a single MIN() makes the bare columns come from that row).
            Exec(tx, "INSERT INTO smtp_client(server,direction,role,connector,remote_host,helo,account) SELECT server,direction,role,connector,h,helo,a FROM (" +
                "SELECT MIN(mi) AS first,server,direction,role,connector,h,helo,a FROM smtp_client_scan GROUP BY server COLLATE NOCASE,direction,role,connector,h,helo,a) ORDER BY first;");
            Exec(tx, "UPDATE smtp_transaction SET client_id=(SELECT c.id FROM smtp_client c WHERE c.remote_host=exl_remote_host(smtp_transaction.remote_ep) AND ifnull(c.helo,x'')=ifnull(smtp_transaction.helo,x'') " +
                "AND c.server=smtp_transaction.server COLLATE NOCASE AND c.direction=smtp_transaction.direction AND ifnull(c.role,x'')=ifnull(smtp_transaction.role,x'') " +
                "AND ifnull(c.connector,x'')=ifnull(smtp_transaction.connector,x'') AND ifnull(c.account,x'')=ifnull(CASE WHEN smtp_transaction.auth_source='Overflow' THEN NULL ELSE smtp_transaction.auth_user END,x'')) " +
                "WHERE exl_remote_host(remote_ep) IS NOT NULL;");
            Exec(tx, SmtpClientIndexes[1][2] + ";" + SmtpClientIndexes[2][2] + ";");
            Exec(tx, "INSERT INTO smtp_client_value(text) SELECT v FROM (SELECT st v FROM smtp_client_scan UNION SELECT tl FROM smtp_client_scan UNION SELECT me FROM smtp_client_scan UNION SELECT re FROM smtp_client_scan " +
                "UNION SELECT att FROM smtp_client_scan UNION SELECT so FROM smtp_client_scan) WHERE v IS NOT NULL ORDER BY v;");
            Exec(tx, "INSERT INTO smtp_client_hour SELECT c.id,g.hour,COALESCE(s.id,0),COALESCE(t.id,0),m.id,r.id,x.id,COALESCE(o.id,0),g.n,g.rc,g.mi,g.fm,g.lm " +
                "FROM smtp_client_scan g JOIN smtp_client c ON c.remote_host=g.h AND ifnull(c.helo,x'')=ifnull(g.helo,x'') AND c.server=g.server COLLATE NOCASE AND c.direction=g.direction AND ifnull(c.role,x'')=ifnull(g.role,x'') " +
                "AND ifnull(c.connector,x'')=ifnull(g.connector,x'') AND ifnull(c.account,x'')=ifnull(g.a,x'') " +
                "LEFT JOIN smtp_client_value s ON s.text=g.st LEFT JOIN smtp_client_value t ON t.text=g.tl JOIN smtp_client_value m ON m.text=g.me JOIN smtp_client_value r ON r.text=g.re " +
                "JOIN smtp_client_value x ON x.text=g.att LEFT JOIN smtp_client_value o ON o.text=g.so ORDER BY 1,2,3,4,5,6,7,8;");
            Exec(tx, "DROP TABLE temp.smtp_client_scan;");
            Exec(tx, SmtpClientIndexes[3][2] + ";");
            // The proof, inside the same transaction: the structures equal a recomputation from the rows.
            VerifySmtpClientsCore(sql => Command(sql, tx), null);
            foreach (var trigger in SmtpClientTriggers) using (var c = Command(trigger[1] + ";", tx)) c.ExecuteNonQuery();
        }

        void Exec(SqliteTransaction tx, string sql) { using (var c = Command(sql, tx)) c.ExecuteNonQuery(); }

        // ---------------------------------------------------------------- verification

        static long Count(Func<string, SqliteCommand> command, string sql, string failure)
        {
            using (var c = command(sql)) return Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture);
        }

        /// <summary>
        /// Exact check that the stored structures equal a full recomputation from the transactions: every client_id is the key recomputed from the row
        /// (NULL if and only if there is no observed endpoint), the dimension has no duplicate and no orphan, and smtp_client_hour equals the grouping of the rows
        /// in both directions. Throws InvalidDataException at the first difference. Runs on any connection with exl_remote_host registered.
        /// </summary>
        internal static SmtpClientVerification VerifySmtpClientsCore(Func<string, SqliteCommand> command, Action tick)
        {
            Action step = () => { if (tick != null) tick(); };
            var result = new SmtpClientVerification();
            if (Count(command, "SELECT COUNT(*) FROM smtp_client_pending;", null) != 0 || Count(command, "SELECT COUNT(*) FROM smtp_client_dirty;", null) != 0)
                throw new InvalidDataException("InvalidSmtpClients: unreconciled SMTP client work is queued.");
            if (Count(command, "SELECT COUNT(*) FROM smtp_transaction WHERE client_id IS NULL AND exl_remote_host(remote_ep) IS NOT NULL;", null) != 0)
                throw new InvalidDataException("InvalidSmtpClients: a transaction with an observed endpoint has no client.");
            step();
            if (Count(command, "SELECT COUNT(*) FROM smtp_transaction e WHERE e.client_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM smtp_client c WHERE c.id=e.client_id);", null) != 0)
                throw new InvalidDataException("InvalidSmtpClients: a transaction points at a missing client.");
            step();
            if (Count(command, "SELECT COUNT(*) FROM smtp_transaction e JOIN smtp_client c ON c.id=e.client_id WHERE NOT (c.remote_host IS exl_remote_host(e.remote_ep) AND c.helo IS e.helo AND c.server=e.server COLLATE NOCASE " +
                "AND c.direction IS e.direction AND c.role IS e.role AND c.connector IS e.connector AND c.account IS (" + TxAccount + "));", null) != 0)
                throw new InvalidDataException("InvalidSmtpClients: a transaction belongs to a client that is not its own key.");
            step();
            if (Count(command, "SELECT COUNT(*) FROM (SELECT 1 FROM smtp_client GROUP BY remote_host,helo,server COLLATE NOCASE,direction,role,connector,account HAVING COUNT(*)>1);", null) != 0)
                throw new InvalidDataException("InvalidSmtpClients: duplicate client.");
            if (Count(command, "SELECT COUNT(*) FROM smtp_client c WHERE NOT EXISTS(SELECT 1 FROM smtp_transaction e INDEXED BY ix_smtp_client WHERE e.client_id=c.id);", null) != 0)
                throw new InvalidDataException("InvalidSmtpClients: client without transaction.");
            step();
            // -1 never equals a stored code: a value missing from the dictionary shows up as a difference instead of silently dropping the group.
            string recompute = "SELECT e.client_id c," + TxHour + " h,COALESCE(s.id,CASE WHEN e.status IS NULL THEN 0 ELSE -1 END) st,COALESCE(t.id,CASE WHEN e.tls IS NULL THEN 0 ELSE -1 END) tl,COALESCE(m.id,-1) me,COALESCE(r.id,-1) re,COALESCE(a.id,-1) at," +
                "COALESCE(o.id,CASE WHEN e.auth_source IS NULL THEN 0 ELSE -1 END) so,COUNT(*) n,SUM(COALESCE(e.rcpt_count,0)) rc,MIN(e.id) mi,MIN(e.time_ms) fm,MAX(e.time_ms) lm " +
                "FROM smtp_transaction e LEFT JOIN smtp_client_value s ON s.text=e.status LEFT JOIN smtp_client_value t ON t.text=e.tls LEFT JOIN smtp_client_value m ON m.text=" + TxMechanism +
                " LEFT JOIN smtp_client_value r ON r.text=" + TxResult + " LEFT JOIN smtp_client_value a ON a.text=" + TxAttempt + " LEFT JOIN smtp_client_value o ON o.text=e.auth_source WHERE e.client_id IS NOT NULL GROUP BY 1,2,3,4,5,6,7,8";
            if (Count(command, "SELECT COUNT(*) FROM (SELECT * FROM (" + recompute + ") EXCEPT SELECT * FROM smtp_client_hour);", null) != 0)
                throw new InvalidDataException("InvalidSmtpClients: smtp_client_hour misses or differs from the transactions.");
            step();
            if (Count(command, "SELECT COUNT(*) FROM (SELECT * FROM smtp_client_hour EXCEPT SELECT * FROM (" + recompute + "));", null) != 0)
                throw new InvalidDataException("InvalidSmtpClients: smtp_client_hour holds a bucket the transactions do not justify.");
            step();
            result.Clients = Count(command, "SELECT COUNT(*) FROM smtp_client;", null);
            result.HourRows = Count(command, "SELECT COUNT(*) FROM smtp_client_hour;", null);
            result.Values = Count(command, "SELECT COUNT(*) FROM smtp_client_value;", null);
            result.Verified = true;
            return result;
        }

        // ---------------------------------------------------------------- reconciliation of work queued by triggers

        /// <summary>
        /// Drains smtp_client_pending (transactions written or changed by a connection that did not maintain the structures: they get their client_id)
        /// and smtp_client_dirty (buckets to recompute from the rows), then removes the clients left without transaction. Never called by Serve.
        /// </summary>
        public void ReconcileSmtpClients(SqliteTransaction transaction)
        {
            if (ReadOnly) throw new InvalidOperationException("SMTP client reconciliation requires a writable collection transaction.");
            if (transaction == null) throw new ArgumentNullException(nameof(transaction));
            bool work;
            using (var c = Command("SELECT EXISTS(SELECT 1 FROM smtp_client_pending) OR EXISTS(SELECT 1 FROM smtp_client_dirty);", transaction)) work = Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture) != 0;
            if (!work) return;
            using (var m = new SmtpClientMaintenance(this))
            {
                m.Use(transaction);
                m.DrainQueues();
            }
        }
    }

    /// <summary>
    /// The writer side of the SMTP client structures, used by the collection apply thread (inside the batch transaction) and by the reconciliation.
    /// Cache keys are exact: each part length-prefixed, NULL distinct from '', the server folded to upper case ASCII like COLLATE NOCASE.
    /// </summary>
    internal sealed class SmtpClientMaintenance : IDisposable
    {
        sealed class Delta { public long N, Rcpts, MinId = long.MaxValue, MinMs = long.MaxValue, MaxMs = long.MinValue; }
        // A transaction inserted by this batch whose authentication may still be resolved by it: its bucket is not written until Flush.
        sealed class Fresh { public long Time, Rcpts; public object Client; public long St, Tl, Me, Re, At, So; }

        readonly Store _store;
        SqliteTransaction _tx;
        bool _loaded;
        readonly Dictionary<string, long> _clients = new Dictionary<string, long>(StringComparer.Ordinal);
        readonly Dictionary<long, string> _keyOf = new Dictionary<long, string>();
        readonly Dictionary<string, long> _codes = new Dictionary<string, long>(StringComparer.Ordinal);
        readonly Dictionary<(long, long, long, long, long, long, long, long), Delta> _deltas = new Dictionary<(long, long, long, long, long, long, long, long), Delta>();
        readonly HashSet<(long, long)> _dirty = new HashSet<(long, long)>();
        readonly Dictionary<long, Fresh> _fresh = new Dictionary<long, Fresh>();
        readonly HashSet<long> _orphanCandidates = new HashSet<long>();
        SqliteCommand _boundary, _find, _addClient, _addValue, _upsert, _read, _delete, _insert, _orphan, _pending, _lookup, _setClient, _clearPending, _markDirty, _pageDirty, _clearDirty, _pageDelete;
        public long ClientsCreated, Upserts, Recomputed, Rekeyed, OrphansDeleted;
        // Memory stays bounded whatever the size of the batch: the key cache is a small recency cache (consecutive transactions mostly belong to the same
        // clients), and the work held for the batch is written (in the batch transaction, exactly) as soon as it reaches this many entries.
        const int ClientCacheLimit = 16384, AutoFlushLimit = 16384, RecomputeWindow = 8192;

        public SmtpClientMaintenance(Store store) { _store = store; }

        SqliteCommand Cmd(string sql) { return _store.Command(sql, _tx); }
        static void Types(SqliteCommand c, SqliteType type, params string[] names) { foreach (var n in names) c.Parameters.Add(n, type); }

        /// <summary>Binds the statements to the transaction of the batch (the first call prepares them).</summary>
        public void Use(SqliteTransaction tx)
        {
            _tx = tx;
            if (!_loaded)
            {
                _codes.Clear(); _codesValid = false;
                using (var c = Cmd("SELECT id,text FROM smtp_client_value;")) using (var r = c.ExecuteReader()) while (r.Read()) _codes[r.GetString(1)] = r.GetInt64(0);
                _loaded = true;
            }
            if (_find == null)
            {
                _find = Cmd("SELECT id FROM smtp_client WHERE remote_host=@h AND ifnull(helo,x'')=ifnull(@helo,x'') AND server=@s COLLATE NOCASE AND direction=@d AND ifnull(role,x'')=ifnull(@r,x'') AND ifnull(connector,x'')=ifnull(@c,x'') AND ifnull(account,x'')=ifnull(@a,x'');");
                _addClient = Cmd("INSERT INTO smtp_client(server,direction,role,connector,remote_host,helo,account) VALUES(@s,@d,@r,@c,@h,@helo,@a) RETURNING id;");
                foreach (var c in new[] { _find, _addClient }) Types(c, SqliteType.Text, "@h", "@helo", "@s", "@d", "@r", "@c", "@a");
                _addValue = Cmd("INSERT INTO smtp_client_value(text) VALUES(@t) RETURNING id;"); Types(_addValue, SqliteType.Text, "@t");
                _upsert = Cmd("INSERT INTO smtp_client_hour VALUES(@c,@h,@s,@t,@m,@r,@a,@o,@n,@rc,@mi,@fm,@lm) ON CONFLICT DO UPDATE SET n=n+excluded.n,rcpts=rcpts+excluded.rcpts,min_id=MIN(min_id,excluded.min_id),min_ms=MIN(min_ms,excluded.min_ms),max_ms=MAX(max_ms,excluded.max_ms);");
                Types(_upsert, SqliteType.Integer, "@c", "@h", "@s", "@t", "@m", "@r", "@a", "@o", "@n", "@rc", "@mi", "@fm", "@lm");
                // The buckets of one client x hour, grouped by SQLite in slices of at most RecomputeWindow transactions (a long session can hold a very large number: the
                // grouping sorter and the managed memory stay small), the slices being merged here. A slice is the transactions after (@lt,@li) up to and including (@bt,@bi).
                _read = Cmd("SELECT e.status,e.tls," + Store.TxMechanism + "," + Store.TxResult + "," + Store.TxAttempt + ",e.auth_source,COUNT(*),SUM(COALESCE(e.rcpt_count,0)),MIN(e.id),MIN(e.time_ms),MAX(e.time_ms) FROM smtp_transaction e INDEXED BY ix_smtp_client " +
                    "WHERE e.client_id=@c AND e.time_ms>=@lt AND e.time_ms<@h2 AND (e.time_ms>@lt OR e.id>@li) AND (e.time_ms<@bt OR (e.time_ms=@bt AND e.id<=@bi)) GROUP BY e.status,e.tls," + Store.TxMechanism + "," + Store.TxResult + "," + Store.TxAttempt + ",e.auth_source;");
                Types(_read, SqliteType.Integer, "@c", "@lt", "@li", "@bt", "@bi", "@h2");
                _boundary = Cmd("SELECT e.time_ms,e.id FROM smtp_transaction e INDEXED BY ix_smtp_client WHERE e.client_id=@c AND e.time_ms>=@lt AND e.time_ms<@h2 AND (e.time_ms>@lt OR e.id>@li) ORDER BY e.time_ms,e.id LIMIT 1 OFFSET " +
                    (RecomputeWindow - 1).ToString(CultureInfo.InvariantCulture) + ";");
                Types(_boundary, SqliteType.Integer, "@c", "@lt", "@li", "@h2");
                _delete = Cmd("DELETE FROM smtp_client_hour WHERE client_id=@c AND hour_ms=@h;"); Types(_delete, SqliteType.Integer, "@c", "@h");
                _insert = Cmd("INSERT INTO smtp_client_hour VALUES(@c,@h,@s,@t,@m,@r,@a,@o,@n,@rc,@mi,@fm,@lm);");
                Types(_insert, SqliteType.Integer, "@c", "@h", "@s", "@t", "@m", "@r", "@a", "@o", "@n", "@rc", "@mi", "@fm", "@lm");
                _orphan = Cmd("DELETE FROM smtp_client WHERE id=@c AND NOT EXISTS(SELECT 1 FROM smtp_transaction e INDEXED BY ix_smtp_client WHERE e.client_id=@c);"); Types(_orphan, SqliteType.Integer, "@c");
                _pageDelete = Cmd("DELETE FROM smtp_client_hour WHERE client_id=@c;"); Types(_pageDelete, SqliteType.Integer, "@c");
                _pending = Cmd("SELECT tx_id FROM smtp_client_pending ORDER BY tx_id LIMIT 512;");
                _lookup = Cmd("SELECT time_ms,client_id,server,direction,role,connector,remote_ep,helo,auth_user,auth_source FROM smtp_transaction WHERE id=@i;"); Types(_lookup, SqliteType.Integer, "@i");
                _setClient = Cmd("UPDATE smtp_transaction SET client_id=@c WHERE id=@i;"); Types(_setClient, SqliteType.Integer, "@c", "@i");
                _clearPending = Cmd("DELETE FROM smtp_client_pending WHERE tx_id=@i;"); Types(_clearPending, SqliteType.Integer, "@i");
                _markDirty = Cmd("INSERT OR IGNORE INTO smtp_client_dirty VALUES(@c,@h);"); Types(_markDirty, SqliteType.Integer, "@c", "@h");
                _pageDirty = Cmd("SELECT client_id,hour_ms FROM smtp_client_dirty ORDER BY client_id,hour_ms LIMIT 4096;");
                _clearDirty = Cmd("DELETE FROM smtp_client_dirty WHERE client_id=@c AND hour_ms=@h;"); Types(_clearDirty, SqliteType.Integer, "@c", "@h");
            }
            foreach (var c in All()) c.Transaction = tx;
        }

        IEnumerable<SqliteCommand> All()
        {
            return new[] { _boundary, _find, _addClient, _addValue, _upsert, _read, _delete, _insert, _orphan, _pending, _lookup, _setClient, _clearPending, _markDirty, _pageDirty, _clearDirty, _pageDelete }.Where(c => c != null);
        }

        /// <summary>The batch was rolled back: clients and values it created no longer exist, and nothing it queued must be written.</summary>
        public void Reset()
        {
            foreach (var c in All()) c.Transaction = null;
            _tx = null; _loaded = false;
            _clients.Clear(); _keyOf.Clear(); _codes.Clear(); _deltas.Clear(); _dirty.Clear(); _fresh.Clear(); _left.Clear(); _orphanCandidates.Clear();
            _lastClient = null; _lastEndpoint = null; _lastHost = null; _codesValid = false;
        }

        static string AsciiUpper(string s)
        {
            var chars = s.ToCharArray();
            for (int i = 0; i < chars.Length; i++) if (chars[i] >= 'a' && chars[i] <= 'z') chars[i] = (char)(chars[i] - 32);
            return new string(chars);
        }

        static string Key(object server, object direction, object role, object connector, string host, object helo, object account)
        {
            var sb = new StringBuilder();
            foreach (object o in new[] { (object)AsciiUpper(Convert.ToString(server, CultureInfo.InvariantCulture)), direction, role, connector, host, helo, account })
            {
                if (o == null || o is DBNull) sb.Append("-|"); else { string v = Convert.ToString(o, CultureInfo.InvariantCulture); sb.Append(v.Length.ToString(CultureInfo.InvariantCulture)).Append(':').Append(v).Append('|'); }
            }
            return sb.ToString();
        }

        long Code(object text)
        {
            if (text == null || text is DBNull) return 0;
            string value = text as string ?? Convert.ToString(text, CultureInfo.InvariantCulture);
            long id;
            if (_codes.TryGetValue(value, out id)) return id;
            _addValue.Parameters["@t"].Value = value;
            id = Convert.ToInt64(_addValue.ExecuteScalar(), CultureInfo.InvariantCulture);
            _codes[value] = id;
            return id;
        }

        // The previous answer: transactions of one session follow each other with the same values, so the key is only built when something changed.
        string _lastEndpoint, _lastHost;
        string _lastClientHost;
        object _lastServer, _lastDirection, _lastRole, _lastConnector, _lastHelo, _lastAccount, _lastClient;

        /// <summary>client_id of a transaction (null: no observed endpoint). Creates the dimension row when the group is new.</summary>
        public object Client(object server, object direction, object role, object connector, object remoteEp, object helo, object authUser, object authSource)
        {
            string endpoint = remoteEp as string, host;
            if (endpoint != null && string.Equals(endpoint, _lastEndpoint, StringComparison.Ordinal)) host = _lastHost;
            else { host = Identity.RemoteHost(endpoint); _lastEndpoint = endpoint; _lastHost = host; }
            if (host == null) return null;
            object account = (authSource as string) == "Overflow" ? null : authUser;
            if (_lastClient != null && string.Equals(host, _lastClientHost, StringComparison.Ordinal) && Same(server, _lastServer) && Same(direction, _lastDirection) && Same(role, _lastRole) && Same(connector, _lastConnector) &&
                Same(helo, _lastHelo) && Same(account, _lastAccount) && _keyOf.ContainsKey((long)_lastClient)) return _lastClient;
            object client = ClientOf(server, direction, role, connector, host, helo, account);
            _lastClientHost = host; _lastServer = server; _lastDirection = direction; _lastRole = role; _lastConnector = connector; _lastHelo = helo; _lastAccount = account; _lastClient = client;
            return client;
        }

        static bool Same(object a, object b)
        {
            if (a == null || a is DBNull) return b == null || b is DBNull;
            return a is string && b is string && string.Equals((string)a, (string)b, StringComparison.Ordinal);
        }

        object ClientOf(object server, object direction, object role, object connector, string host, object helo, object account)
        {
            string key = Key(server, direction, role, connector, host, helo, account);
            long id;
            if (_clients.TryGetValue(key, out id)) return id;
            var p = _find.Parameters;
            p["@h"].Value = host; p["@helo"].Value = helo ?? DBNull.Value; p["@s"].Value = server; p["@d"].Value = direction; p["@r"].Value = role ?? DBNull.Value;
            p["@c"].Value = connector ?? DBNull.Value; p["@a"].Value = account ?? DBNull.Value;
            object found = _find.ExecuteScalar();
            if (found == null)
            {
                var q = _addClient.Parameters;
                q["@h"].Value = host; q["@helo"].Value = helo ?? DBNull.Value; q["@s"].Value = server; q["@d"].Value = direction; q["@r"].Value = role ?? DBNull.Value;
                q["@c"].Value = connector ?? DBNull.Value; q["@a"].Value = account ?? DBNull.Value;
                found = _addClient.ExecuteScalar(); ClientsCreated++;
                // The caller may not insert the row that asked for it (INSERT OR IGNORE): a client nobody uses is removed by Flush.
                _orphanCandidates.Add(Convert.ToInt64(found, CultureInfo.InvariantCulture));
            }
            id = Convert.ToInt64(found, CultureInfo.InvariantCulture);
            if (_clients.Count >= ClientCacheLimit) { _clients.Clear(); _keyOf.Clear(); }
            _clients[key] = id; _keyOf[id] = key;
            return id;
        }

        static string MechOf(object src, object mech) { string s = src as string; if (s == "Overflow") return "Not available"; if (mech != null && !(mech is DBNull)) return Convert.ToString(mech, CultureInfo.InvariantCulture); return s == "NotApplicable" ? "None" : "Not available"; }
        static string ResOf(object src, object v) { return (src as string) == "Overflow" ? "Unknown" : ((v == null || v is DBNull) ? "Unknown" : Convert.ToString(v, CultureInfo.InvariantCulture)); }

        // The codes of the previous Inserted and the values they came from: the transactions of one session follow each other with the same status,
        // TLS and authentication, so the six codes are looked up again only when one of them changed (false: none yet, or the codes were read again).
        bool _codesValid;
        object _codeStatus, _codeTls, _codeMech, _codeResult, _codeAttempt, _codeSource;
        long _st, _tl, _me, _re, _at, _so;

        /// <summary>
        /// A transaction that WAS inserted (Run() changed a row). One whose authentication can still be resolved by this batch (updatable: it has evidence)
        /// is kept in memory until Flush; any other is added to its bucket at once.
        /// </summary>
        public void Inserted(long id, long timeMs, object clientId, object status, object rcpt, object tls, object authMech, object authResult, object authAttempt, object authSource, bool updatable)
        {
            if (!_codesValid || !Same(status, _codeStatus) || !Same(tls, _codeTls) || !Same(authMech, _codeMech) || !Same(authResult, _codeResult) ||
                !Same(authAttempt, _codeAttempt) || !Same(authSource, _codeSource))
            {
                _codesValid = false;   // until all six are known
                _st = Code(status); _tl = Code(tls); _me = Code(MechOf(authSource, authMech)); _re = Code(ResOf(authSource, authResult)); _at = Code(ResOf(authSource, authAttempt)); _so = Code(authSource);
                _codeStatus = status; _codeTls = tls; _codeMech = authMech; _codeResult = authResult; _codeAttempt = authAttempt; _codeSource = authSource;
                _codesValid = true;
            }
            var f = new Fresh { Time = timeMs, Rcpts = rcpt == null || rcpt is DBNull ? 0 : Convert.ToInt64(rcpt, CultureInfo.InvariantCulture), Client = clientId, St = _st, Tl = _tl,
                Me = _me, Re = _re, At = _at, So = _so };
            if (updatable) _fresh[id] = f; else Add(id, f);
            // Written early, a row stops being "fresh": a later resolution of its account then recomputes its two buckets from the rows (same result).
            if (_fresh.Count + _deltas.Count + _orphanCandidates.Count >= AutoFlushLimit) Flush();
        }

        void Add(long id, Fresh f)
        {
            if (f.Client == null || f.Client is DBNull) return;
            var k = (Convert.ToInt64(f.Client, CultureInfo.InvariantCulture), Store.FloorHour(f.Time), f.St, f.Tl, f.Me, f.Re, f.At, f.So);
            Delta d;
            if (!_deltas.TryGetValue(k, out d)) _deltas[k] = d = new Delta();
            d.N++; d.Rcpts += f.Rcpts;
            if (id < d.MinId) d.MinId = id; if (f.Time < d.MinMs) d.MinMs = f.Time; if (f.Time > d.MaxMs) d.MaxMs = f.Time;
        }

        /// <summary>UpdateAuth of a transaction: re-keyed in memory when this batch inserted it, otherwise both buckets are recomputed from the rows.</summary>
        public void Updated(long id, long timeMs, object oldClient, object newClient, object authMech, object authResult, object authAttempt, object authSource)
        {
            Fresh f;
            if (_fresh.TryGetValue(id, out f))
            {
                f.Client = newClient; f.Me = Code(MechOf(authSource, authMech)); f.Re = Code(ResOf(authSource, authResult)); f.At = Code(ResOf(authSource, authAttempt)); f.So = Code(authSource);
                Rekeyed++; return;
            }
            Dirty(oldClient, timeMs); Dirty(newClient, timeMs);
        }

        readonly HashSet<long> _left = new HashSet<long>();
        /// <summary>The transaction moved from a client to another: the old one is deleted at Flush when that was its last transaction.</summary>
        public void Left(object oldClient, object newClient)
        {
            if (oldClient != null && !(oldClient is DBNull) && !Equals(oldClient, newClient)) _left.Add(Convert.ToInt64(oldClient, CultureInfo.InvariantCulture));
        }

        public void Dirty(object clientId, long timeMs)
        {
            if (clientId != null && !(clientId is DBNull)) _dirty.Add((Convert.ToInt64(clientId, CultureInfo.InvariantCulture), Store.FloorHour(timeMs)));
        }

        /// <summary>Writes the work of the batch in its transaction: additive buckets, recomputed buckets, then the clients left without transaction.</summary>
        public void Flush()
        {
            foreach (var kv in _fresh) Add(kv.Key, kv.Value);
            _fresh.Clear();
            var p = _upsert.Parameters;
            foreach (var kv in _deltas)
            {
                var k = kv.Key;
                if (_dirty.Contains((k.Item1, k.Item2))) continue;   // recomputed from the rows below (they already include this batch)
                p[0].Value = k.Item1; p[1].Value = k.Item2; p[2].Value = k.Item3; p[3].Value = k.Item4; p[4].Value = k.Item5; p[5].Value = k.Item6; p[6].Value = k.Item7; p[7].Value = k.Item8;
                p[8].Value = kv.Value.N; p[9].Value = kv.Value.Rcpts; p[10].Value = kv.Value.MinId; p[11].Value = kv.Value.MinMs; p[12].Value = kv.Value.MaxMs;
                _upsert.ExecuteNonQuery(); Upserts++;
            }
            _deltas.Clear();
            foreach (var b in _dirty) { Recompute(b.Item1, b.Item2); _orphanCandidates.Add(b.Item1); }
            _dirty.Clear();
            foreach (long c in _left) _orphanCandidates.Add(c);
            _left.Clear();
            RemoveOrphans();
        }

        /// <summary>Rebuilds the buckets of one client x hour from the transaction rows.</summary>
        void Recompute(long client, long hour)
        {
            var acc = new Dictionary<(long, long, long, long, long, long), Delta>();
            long end = hour + Store.HourMs, after = hour, afterId = long.MinValue;
            var row = new object[11];
            while (true)
            {
                // The end of the next slice: the RecomputeWindow-th transaction after the cursor (none: the slice runs to the end of the hour).
                _boundary.Parameters[0].Value = client; _boundary.Parameters[1].Value = after; _boundary.Parameters[2].Value = afterId; _boundary.Parameters[3].Value = end;
                long boundTime = long.MaxValue, boundId = long.MaxValue; bool more = false;
                using (var b = _boundary.ExecuteReader()) if (b.Read()) { boundTime = b.GetInt64(0); boundId = b.GetInt64(1); more = true; }
                var p = _read.Parameters;
                p[0].Value = client; p[1].Value = after; p[2].Value = afterId; p[3].Value = boundTime; p[4].Value = boundId; p[5].Value = end;
                // One row per distinct combination of values (one-to-one with the code tuple: distinct texts have distinct codes, NULL is code 0).
                // A new value is inserted in smtp_client_value while the groups are read (another table).
                using (var r = _read.ExecuteReader())
                    while (r.Read())
                    {
                        r.GetValues(row);
                        var k = (Code(row[0]), Code(row[1]), Code(row[2]), Code(row[3]), Code(row[4]), Code(row[5]));
                        Delta d;
                        if (!acc.TryGetValue(k, out d)) acc[k] = d = new Delta();
                        d.N += Convert.ToInt64(row[6], CultureInfo.InvariantCulture); d.Rcpts += Convert.ToInt64(row[7], CultureInfo.InvariantCulture);
                        long id = Convert.ToInt64(row[8], CultureInfo.InvariantCulture), first = Convert.ToInt64(row[9], CultureInfo.InvariantCulture), last = Convert.ToInt64(row[10], CultureInfo.InvariantCulture);
                        if (id < d.MinId) d.MinId = id; if (first < d.MinMs) d.MinMs = first; if (last > d.MaxMs) d.MaxMs = last;
                    }
                if (!more) break;
                after = boundTime; afterId = boundId;
            }            _delete.Parameters[0].Value = client; _delete.Parameters[1].Value = hour; _delete.ExecuteNonQuery();
            var q = _insert.Parameters;
            foreach (var kv in acc)
            {
                q[0].Value = client; q[1].Value = hour; q[2].Value = kv.Key.Item1; q[3].Value = kv.Key.Item2; q[4].Value = kv.Key.Item3; q[5].Value = kv.Key.Item4; q[6].Value = kv.Key.Item5; q[7].Value = kv.Key.Item6;
                q[8].Value = kv.Value.N; q[9].Value = kv.Value.Rcpts; q[10].Value = kv.Value.MinId; q[11].Value = kv.Value.MinMs; q[12].Value = kv.Value.MaxMs;
                _insert.ExecuteNonQuery();
            }
            Recomputed++;
        }

        /// <summary>Deletes the candidate clients that no transaction uses any more (and any bucket row they still have); the key cache forgets them.</summary>
        void RemoveOrphans()
        {
            foreach (long c in _orphanCandidates)
            {
                _orphan.Parameters[0].Value = c;
                if (_orphan.ExecuteNonQuery() > 0)
                {
                    OrphansDeleted++;
                    _pageDelete.Parameters[0].Value = c; _pageDelete.ExecuteNonQuery();
                    string key;
                    if (_keyOf.TryGetValue(c, out key)) { _clients.Remove(key); _keyOf.Remove(c); }
                }
            }
            _orphanCandidates.Clear();
        }

        /// <summary>Reconciliation: gives their client to the queued transactions, recomputes the queued buckets, removes the orphans.</summary>
        public void DrainQueues()
        {
            while (true)
            {
                var ids = new List<long>();
                using (var r = _pending.ExecuteReader()) while (r.Read()) ids.Add(r.GetInt64(0));
                if (ids.Count == 0) break;
                foreach (long id in ids)
                {
                    _lookup.Parameters[0].Value = id;
                    object[] row = null;
                    using (var r = _lookup.ExecuteReader())
                        if (r.Read()) { row = new object[10]; for (int i = 0; i < row.Length; i++) row[i] = r.IsDBNull(i) ? null : r.GetValue(i); }
                    if (row != null)
                    {
                        long time = Convert.ToInt64(row[0], CultureInfo.InvariantCulture);
                        object old = row[1];
                        object client = Client(row[2], row[3], row[4], row[5], row[6], row[7], row[8], row[9]);
                        if (!Equals(old, client))
                        {
                            _setClient.Parameters[0].Value = client ?? DBNull.Value; _setClient.Parameters[1].Value = id; _setClient.ExecuteNonQuery();
                            MarkDirty(old, time);
                            Left(old, client);
                        }
                        MarkDirty(client, time);
                    }
                    _clearPending.Parameters[0].Value = id; _clearPending.ExecuteNonQuery();
                }
            }
            while (true)
            {
                var page = new List<(long, long)>();
                using (var r = _pageDirty.ExecuteReader()) while (r.Read()) page.Add((r.GetInt64(0), r.GetInt64(1)));
                if (page.Count == 0) break;
                foreach (var b in page)
                {
                    Recompute(b.Item1, b.Item2);
                    _orphanCandidates.Add(b.Item1);
                    _clearDirty.Parameters[0].Value = b.Item1; _clearDirty.Parameters[1].Value = b.Item2; _clearDirty.ExecuteNonQuery();
                }
            }
            foreach (long c in _left) _orphanCandidates.Add(c);
            _left.Clear();
            RemoveOrphans();
        }

        void MarkDirty(object client, long timeMs)
        {
            if (client == null || client is DBNull) return;
            _markDirty.Parameters[0].Value = Convert.ToInt64(client, CultureInfo.InvariantCulture); _markDirty.Parameters[1].Value = Store.FloorHour(timeMs); _markDirty.ExecuteNonQuery();
        }

        public void Dispose() { foreach (var c in All()) c.Dispose(); }
    }
}
