// =============================================================================
//  Exchange Log Report - engine, part 6: collection pipeline
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 2.0.0
//
//  1. Plan    the folders of every server and source are listed in parallel; a file
//             is read when it is new (modified within BackfillDays) or has grown.
//  2. Parse   N threads (Collection.Parallelism) read and parse one file each, every
//             server and source at the same time. Files are taken oldest first, from
//             two streams merged in proportion to their planned bytes (ParseSchedule):
//               main     HttpProxy first: it teaches the "domain\sam" form of the
//                        accounts; then IIS, MAPI and ActiveSync back end, IMAP, POP:
//                        they use the accounts learnt from HttpProxy, so they start
//                        once every HttpProxy file is applied
//               filler   SMTP and message tracking: no link with the other files. Cheap
//                        to parse and long to write, they keep the apply thread busy
//                        while the main stream is parsed (and the threads busy while
//                        the main stream waits for the last HttpProxy file)
//  3. Apply   one thread writes the database: one transaction per batch of files
//             (Collection.BatchSeconds / BatchRows), the read position of every file
//             saved with its rows. A file that cannot be read is reported and left
//             for the next collection; a database error stops the collection.
//  PowerShell polls the run (progress, sources finished) every few hundred ms.
// =============================================================================
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    /// <summary>One log folder of one server (one row of the console table).</summary>
    public sealed class SourceJob
    {
        public int Index;
        public string Server, Kind, Role, Label, Folder, Filter = "*.log";
        public bool Recurse;
        // ---- plan
        public bool FolderFound;
        public int Total;
        public DateTime Newest = DateTime.MinValue;
        public string ListError;
        public List<FileWork> Files = new List<FileWork>();
        public long PlannedBytes;
        // ---- progress (written by the apply thread under the lock of the run)
        public int FilesRead, FilesApplied, Errors, Resets;
        public long Bytes, Lines, Kept, Noise, Stored;
        public double FirstStart = -1, LastEnd;       // seconds since the start of the run
        public double WorkSeconds;                    // time spent by the threads on its files (read, parse, write)
        public bool Done;
        public List<string> Warnings = new List<string>();
        public Dictionary<string, long> NoiseReasons = new Dictionary<string, long>(StringComparer.Ordinal);
        public double Seconds { get { return WorkSeconds; } }
        public double Span { get { return FirstStart < 0 ? 0 : Math.Max(0, LastEnd - FirstStart); } }
    }

    /// <summary>One file to read: where to resume, and the result once parsed.</summary>
    public sealed class FileWork
    {
        public SourceJob Job;
        public string Path, Name;
        public long Length;
        public DateTime LastWriteUtc;
        public FileState State;
        internal int Group;
    }

    /// <summary>
    /// Order in which the parse threads take the planned files. Two streams, each oldest first (last write, then the larger file):
    /// the main stream (HttpProxy, then IIS, MAPI and ActiveSync back end, IMAP, POP once every HttpProxy file is applied) and the
    /// filler (SMTP and message tracking). The filler is taken while its share of the bytes taken is below its share of the planned
    /// bytes, or when the main stream has nothing to give: a function of the plan and of the gate only, so a run is reproducible.
    /// With one parse thread the files are applied in this order.
    /// </summary>
    public sealed class ParseSchedule
    {
        static readonly HashSet<string> FirstKinds = new HashSet<string>(StringComparer.Ordinal) { "HttpProxy" };
        static readonly HashSet<string> FillerKinds = new HashSet<string>(StringComparer.Ordinal) { "SmtpReceive", "SmtpSend", "Tracking" };

        // 0: HttpProxy, 1: filler, 2: the files that wait for every HttpProxy file (FileWork.Group)
        readonly LinkedList<FileWork>[] _queues;
        readonly decimal _mainBytes, _fillerBytes;
        decimal _mainTaken, _fillerTaken;

        public ParseSchedule(IEnumerable<FileWork> plan)
        {
            var all = plan.ToList();
            foreach (var w in all) w.Group = FirstKinds.Contains(w.Job.Kind) ? 0 : FillerKinds.Contains(w.Job.Kind) ? 1 : 2;
            Comparison<FileWork> byTime = (a, b) => a.LastWriteUtc != b.LastWriteUtc ? a.LastWriteUtc.CompareTo(b.LastWriteUtc) : b.Length.CompareTo(a.Length);
            var first = all.Where(w => w.Group == 0).ToList(); first.Sort(byTime);
            var filler = all.Where(w => w.Group == 1).ToList(); filler.Sort(byTime);
            var then = all.Where(w => w.Group == 2).ToList(); then.Sort(byTime);
            _queues = new[] { new LinkedList<FileWork>(first), new LinkedList<FileWork>(filler), new LinkedList<FileWork>(then) };
            FirstCount = first.Count;
            _mainBytes = first.Concat(then).Sum(w => (decimal)PlannedBytes(w));
            _fillerBytes = filler.Sum(w => (decimal)PlannedBytes(w));
        }

        /// <summary>HttpProxy files planned (the gate of the files that use their accounts).</summary>
        public int FirstCount { get; private set; }

        /// <summary>Files not taken yet.</summary>
        public int Count { get { return _queues[0].Count + _queues[1].Count + _queues[2].Count; } }

        /// <summary>Bytes to read in a file (the count of SourceJob.PlannedBytes).</summary>
        public static long PlannedBytes(FileWork w)
        {
            long offset = w.State == null ? 0 : w.State.Offset;
            return Math.Max(0, w.Length - (offset <= w.Length ? offset : 0));
        }

        /// <summary>
        /// The next file, removed from the schedule; null when no file can be taken now. firstApplied: every HttpProxy file is applied
        /// (the back-end files may start). canRead: false for a file that cannot be read now (its server already reads MaxFilesPerServer
        /// files): the next file of the same stream is taken instead.
        /// </summary>
        public FileWork Take(bool firstApplied, Func<FileWork, bool> canRead)
        {
            bool fillerTurn = _queues[1].Count > 0 && _fillerTaken * _mainBytes < _mainTaken * _fillerBytes;
            FileWork w = fillerTurn ? From(1, canRead) : null;
            if (w == null)
            {
                w = From(0, canRead);
                if (w == null && firstApplied) w = From(2, canRead);
            }
            if (w == null && !fillerTurn) w = From(1, canRead);
            return w;
        }

        FileWork From(int group, Func<FileWork, bool> canRead)
        {
            var q = _queues[group];
            for (var node = q.First; node != null; node = node.Next)
            {
                if (canRead != null && !canRead(node.Value)) continue;
                q.Remove(node);
                if (group == 1) _fillerTaken += PlannedBytes(node.Value); else _mainTaken += PlannedBytes(node.Value);
                return node.Value;
            }
            return null;
        }

        /// <summary>
        /// The order of one parse thread without limit per server, every HttpProxy file being applied as soon as it is taken (tests and
        /// diagnostics: in a collection the gate opens when the apply thread has written the last HttpProxy file).
        /// </summary>
        public static FileWork[] Order(IEnumerable<FileWork> plan)
        {
            var schedule = new ParseSchedule(plan);
            var order = new List<FileWork>();
            int firstLeft = schedule.FirstCount;
            FileWork w;
            while ((w = schedule.Take(firstLeft == 0, null)) != null)
            {
                order.Add(w);
                if (w.Group == 0) firstLeft--;
            }
            return order.ToArray();
        }
    }

    public sealed class RunProgress
    {
        public int FilesPlanned, FilesDone, Errors, Workers;
        public long BytesPlanned, BytesDone, Lines, Kept;
        public double Seconds;
        public string[] Reading = new string[0];
    }

    /// <summary>
    /// A statement prepared once for the whole collection and run directly on the SQLite handle: binding by index,
    /// without the per-row parameter lookups of Microsoft.Data.Sqlite (a third of the write time on large collections).
    /// It runs in the transaction open on the connection.
    /// </summary>
    sealed class Prepared : IDisposable
    {
        readonly SQLitePCL.sqlite3 _db;
        readonly SQLitePCL.sqlite3_stmt _stmt;
        readonly int[] _index;

        public Prepared(Store store, string sql, int parameters)
        {
            _db = store.Connection.Handle;
            int rc = SQLitePCL.raw.sqlite3_prepare_v2(_db, sql, out _stmt);
            if (rc != SQLitePCL.raw.SQLITE_OK) throw new SqliteException("SQLite: " + SQLitePCL.raw.sqlite3_errmsg(_db).utf8_to_string() + " (" + sql + ")", rc);
            _index = new int[parameters];
            for (int i = 0; i < parameters; i++) _index[i] = SQLitePCL.raw.sqlite3_bind_parameter_index(_stmt, "@p" + i.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }

        public void Use(SqliteTransaction tx) { }

        /// <summary>Rowid of the row the last successful INSERT of the connection created (read right after Run() returned a change).</summary>
        public long LastRowId { get { return SQLitePCL.raw.sqlite3_last_insert_rowid(_db); } }

        byte[] _utf8 = new byte[4096];

        public void Set(int i, object value)
        {
            int k = _index[i];
            if (value == null || value is DBNull) SQLitePCL.raw.sqlite3_bind_null(_stmt, k);
            else if (value is string) BindText(k, (string)value);
            else if (value is byte[]) SQLitePCL.raw.sqlite3_bind_blob(_stmt, k, (byte[])value);
            else if (value is long) SQLitePCL.raw.sqlite3_bind_int64(_stmt, k, (long)value);
            else if (value is int) SQLitePCL.raw.sqlite3_bind_int64(_stmt, k, (int)value);
            else if (value is double) SQLitePCL.raw.sqlite3_bind_double(_stmt, k, (double)value);
            else if (value is bool) SQLitePCL.raw.sqlite3_bind_int64(_stmt, k, (bool)value ? 1 : 0);
            else BindText(k, Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture));
        }

        /// <summary>Text through a reused UTF-8 buffer (SQLite copies it): no array per value.</summary>
        void BindText(int k, string s)
        {
            int max = System.Text.Encoding.UTF8.GetMaxByteCount(s.Length);
            if (max > _utf8.Length) _utf8 = new byte[Math.Max(max, _utf8.Length * 2)];
            int n = System.Text.Encoding.UTF8.GetBytes(s, 0, s.Length, _utf8, 0);
            SQLitePCL.raw.sqlite3_bind_text(_stmt, k, new ReadOnlySpan<byte>(_utf8, 0, n));
        }

        public void Set(int i, long value) { SQLitePCL.raw.sqlite3_bind_int64(_stmt, _index[i], value); }

        /// <summary>Text already encoded in UTF-8 (SQLite copies it): the same binding as BindText of the string those bytes decode to.</summary>
        public void SetUtf8(int i, ReadOnlySpan<byte> utf8) { SQLitePCL.raw.sqlite3_bind_text(_stmt, _index[i], utf8); }

        void Check(int rc)
        {
            if (rc == SQLitePCL.raw.SQLITE_ROW || rc == SQLitePCL.raw.SQLITE_DONE) return;
            string message = SQLitePCL.raw.sqlite3_errmsg(_db).utf8_to_string();
            SQLitePCL.raw.sqlite3_reset(_stmt);
            throw new SqliteException("SQLite: " + message, rc);
        }

        /// <summary>Runs the statement; returns the number of rows changed.</summary>
        public int Run()
        {
            int rc = SQLitePCL.raw.sqlite3_step(_stmt);
            while (rc == SQLitePCL.raw.SQLITE_ROW) rc = SQLitePCL.raw.sqlite3_step(_stmt);
            Check(rc);
            int changes = SQLitePCL.raw.sqlite3_changes(_db);
            SQLitePCL.raw.sqlite3_reset(_stmt);
            return changes;
        }

        /// <summary>Runs the statement and returns the integer of the first row (RETURNING id), null without row.</summary>
        public object Scalar()
        {
            int rc = SQLitePCL.raw.sqlite3_step(_stmt);
            object value = null;
            if (rc == SQLitePCL.raw.SQLITE_ROW)
            {
                if (SQLitePCL.raw.sqlite3_column_type(_stmt, 0) != SQLitePCL.raw.SQLITE_NULL) value = SQLitePCL.raw.sqlite3_column_int64(_stmt, 0);
                while (rc == SQLitePCL.raw.SQLITE_ROW) rc = SQLitePCL.raw.sqlite3_step(_stmt);
            }
            Check(rc);
            SQLitePCL.raw.sqlite3_reset(_stmt);
            return value;
        }

        /// <summary>Steps a query: true with a row to read (Type, Int64, Text, Value), false after the last row (the statement is then reset).</summary>
        public bool Step()
        {
            int rc = SQLitePCL.raw.sqlite3_step(_stmt);
            if (rc == SQLitePCL.raw.SQLITE_ROW) return true;
            Check(rc);
            SQLitePCL.raw.sqlite3_reset(_stmt);
            return false;
        }

        /// <summary>Ends a query before its last row (or after a failure while reading it).</summary>
        public void Reset() { SQLitePCL.raw.sqlite3_reset(_stmt); }

        public int Type(int column) { return SQLitePCL.raw.sqlite3_column_type(_stmt, column); }
        public long Int64(int column) { return SQLitePCL.raw.sqlite3_column_int64(_stmt, column); }
        /// <summary>A TEXT column, decoded as Microsoft.Data.Sqlite's GetString does.</summary>
        public string Text(int column) { return SQLitePCL.raw.sqlite3_column_text(_stmt, column).utf8_to_string(); }

        /// <summary>The value as Microsoft.Data.Sqlite's GetValue gives it, by storage class: long, double, string, byte[], or null for NULL.</summary>
        public object Value(int column)
        {
            switch (Type(column))
            {
                case SQLitePCL.raw.SQLITE_INTEGER: return Int64(column);
                case SQLitePCL.raw.SQLITE_FLOAT: return SQLitePCL.raw.sqlite3_column_double(_stmt, column);
                case SQLitePCL.raw.SQLITE_TEXT: return Text(column);
                case SQLitePCL.raw.SQLITE_BLOB: return SQLitePCL.raw.sqlite3_column_blob(_stmt, column).ToArray();
                default: return null;
            }
        }

        public void Dispose() { _stmt.Dispose(); }
    }

    /// <summary>Every statement written by a collection, prepared once.</summary>
    sealed class Writer : IDisposable
    {
        public Prepared InsertEvent, InsertIis, InsertSmtp, InsertFragment, LookupFragment, UpdateAuth, InsertMessage, Usage, Action, Client, SaveFile, Noise;
        public Prepared DirtyMessage, DirtySmtp, LookupFields, InsertFields;
        public Prepared SessionInsert, SessionUpdate, SessionStep, SessionRepoint, SessionDelete;
        public const string SessionColumns = "skey,day,start_ms,end_ms,user,protocol,mailbox,client_ip,user_agent,device_id,device_type,software,client_mode,front_ends,back_ends," +
            "requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,actions,statuses," +
            "first_error,last_error,backend,connections,updated_ms";
        readonly List<Prepared> _all = new List<Prepared>();

        static string Values(int n) { return string.Join(",", Enumerable.Range(0, n).Select(i => "@p" + i.ToString(System.Globalization.CultureInfo.InvariantCulture))); }

        Prepared Add(Store store, string sql, int n) { var p = new Prepared(store, sql, n); _all.Add(p); return p; }

        public Writer(Store store)
        {
            InsertEvent = Add(store, "INSERT OR IGNORE INTO access_event(time_ms,server,source,protocol,user,mailbox,client_ip,user_agent,method,url,action,status,sub_status,win32,backend_status,error_code,target_server,auth_type,routing,bytes_in,bytes_out,duration_ms,outcome,request_id,errors) VALUES(" + Values(25) + ") RETURNING id;", 25);
            InsertIis = Add(store, "INSERT OR REPLACE INTO iis_status(server,request_id,time_ms,status,sub_status,win32,time_taken) VALUES(" + Values(7) + ");", 7);
            InsertSmtp = Add(store, "INSERT OR IGNORE INTO smtp_transaction(time_ms,end_ms,server,direction,role,connector,session_id,local_ep,remote_ep,helo,tls,auth,mail_from,rcpt_count,rcpts,message_id,internal_id,status,response,transcript,auth_fragment_id,auth_sequence,auth_source,auth_result,msg_hash,client_id) VALUES(" + Values(26) + ");", 26);
            InsertFragment = Add(store, "INSERT INTO smtp_auth_fragment(source_file_id,source_key,first_offset,part,first_ms,last_ms,server,direction,role,connector,session_id,local_ep,remote_ep,helo,first_sequence,last_sequence,complete_start,complete_end,coverage,proxy_sid,proxy_ip,proxy_port,proxy_helo,observations,conflicted,origin_first_ms,evidence_format,conflict_positions) VALUES(" + Values(28) + ") ON CONFLICT DO NOTHING RETURNING id;", 28);
            LookupFragment = Add(store, "SELECT id FROM smtp_auth_fragment WHERE server=@p0 AND direction=@p1 AND role=@p2 AND source_key=@p3 AND session_id=@p4 AND first_offset=@p5 AND COALESCE(origin_first_ms,first_ms)=@p6 AND COALESCE(evidence_format,1)=@p7 AND part=@p8;", 9);
            // Schema 11: client_id is the SMTP client of the transaction (it follows the resolved account); a collection that keeps the triggers on passes the value it read.
            UpdateAuth = Add(store, "UPDATE smtp_transaction SET auth_user=@p0,auth_mechanism=@p1,auth_result=@p2,auth_attempt_result=@p3,auth_source=@p4,auth_evidence_id=@p5,client_id=@p7 WHERE id=@p6;", 8);
            InsertMessage = Add(store, "INSERT OR IGNORE INTO message_event(time_ms,server,event_id,source,message_id,internal_id,network_id,sender,recipients,recipient_status,recipient_count,total_bytes,subject,client_ip,client_host,server_ip,server_host,connector,source_context,related_recipient,reference,directionality,message_info,return_path,log_id,msg_hash) VALUES(" + Values(26) + ");", 26);
            // The rollup invalidations the tr_*_rollup_insert triggers write (same SQL as Store.ServeRollupTriggerSql), for a collection that
            // runs with triggers disabled (see Collector.DisableTriggersDuringApply).
            DirtyMessage = Add(store, "INSERT INTO message_rollup_dirty(kind,identity,msg_hash) VALUES('message',@p0,@p1) ON CONFLICT(kind,identity) DO UPDATE SET msg_hash=excluded.msg_hash;", 2);
            DirtySmtp = Add(store, "INSERT OR IGNORE INTO message_rollup_dirty(kind,identity,msg_hash) VALUES('smtp',CAST(@p0 AS TEXT),NULL);", 1);
            Usage = Add(store, @"INSERT INTO access_usage(day,server,user,protocol,mailbox,requests,successes,client_errors,server_errors,bytes_in,bytes_out,total_ms,max_ms,first_ms,last_ms,last_success_ms,last_failure_ms,client_ip,user_agent,slow)
VALUES(" + Values(20) + @")
ON CONFLICT(day,server,user,protocol) DO UPDATE SET
 mailbox=COALESCE(excluded.mailbox,mailbox), requests=requests+excluded.requests, successes=successes+excluded.successes,
 client_errors=client_errors+excluded.client_errors, server_errors=server_errors+excluded.server_errors, slow=slow+excluded.slow,
 bytes_in=bytes_in+excluded.bytes_in, bytes_out=bytes_out+excluded.bytes_out, total_ms=total_ms+excluded.total_ms,
 max_ms=MAX(max_ms,excluded.max_ms), first_ms=MIN(first_ms,excluded.first_ms),
 client_ip=CASE WHEN excluded.client_ip IS NULL THEN client_ip WHEN client_ip IS NULL OR excluded.last_ms>=last_ms THEN excluded.client_ip ELSE client_ip END,
 user_agent=CASE WHEN excluded.user_agent IS NULL THEN user_agent WHEN user_agent IS NULL OR excluded.last_ms>=last_ms THEN excluded.user_agent ELSE user_agent END,
 last_ms=MAX(last_ms,excluded.last_ms), last_success_ms=MAX(last_success_ms,excluded.last_success_ms),
 last_failure_ms=MAX(last_failure_ms,excluded.last_failure_ms);", 20);
            Action = Add(store, @"INSERT INTO access_action(day,server,protocol,action,requests,failures,slow,total_ms,max_ms) VALUES(" + Values(9) + @")
ON CONFLICT(day,server,protocol,action) DO UPDATE SET requests=requests+excluded.requests, failures=failures+excluded.failures, slow=slow+excluded.slow,
 total_ms=total_ms+excluded.total_ms, max_ms=MAX(max_ms,excluded.max_ms);", 9);
            Client = Add(store, @"INSERT INTO access_client(day,user,protocol,client_ip,user_agent,device_id,device_type,requests,failures,first_ms,last_ms,servers) VALUES(" + Values(12) + @")
ON CONFLICT(day,user,protocol,client_ip,user_agent,device_id) DO UPDATE SET requests=requests+excluded.requests, failures=failures+excluded.failures,
 device_type=COALESCE(excluded.device_type,device_type), first_ms=MIN(first_ms,excluded.first_ms), last_ms=MAX(last_ms,excluded.last_ms),
 servers=CASE WHEN servers IS NULL THEN excluded.servers WHEN instr(','||servers||',', ','||excluded.servers||',') > 0 THEN servers ELSE servers||','||excluded.servers END;", 12);
            // Schema 10: the '#Fields' text lives once in source_fields; the row keeps its id (the old fields column stays NULL).
            LookupFields = Add(store, "SELECT id FROM source_fields WHERE text=@p0;", 1);
            InsertFields = Add(store, "INSERT INTO source_fields(text) VALUES(@p0) ON CONFLICT(text) DO UPDATE SET text=excluded.text RETURNING id;", 1);
            SaveFile = Add(store, "UPDATE source_file SET offset=@p1,size=@p2,last_write_ms=@p3,fields=NULL,fields_id=@p4,first_ms=@p5,last_ms=@p6,lines=@p7,kept=@p8,noise=@p9,updated_ms=@p10 WHERE id=@p0;", 11);
            Noise = Add(store, "INSERT INTO noise(run_id,server,kind,reason,lines) VALUES(@p0,@p1,@p2,@p3,@p4) ON CONFLICT(run_id,server,kind,reason) DO UPDATE SET lines=lines+excluded.lines;", 5);
            int n = SessionColumns.Split(',').Length;
            SessionInsert = Add(store, "INSERT INTO client_session(" + SessionColumns + ") VALUES(" + Values(n) + ") RETURNING id;", n);
            SessionUpdate = Add(store, "UPDATE client_session SET " + string.Join(",", SessionColumns.Split(',').Select((c, i) => c + "=@p" + i.ToString(System.Globalization.CultureInfo.InvariantCulture))) + " WHERE id=@p" + n.ToString(System.Globalization.CultureInfo.InvariantCulture) + ";", n + 1);
            SessionStep = Add(store, "INSERT INTO session_step(session_id,time_ms,data) VALUES(@p0,@p1,@p2);", 3);
            SessionRepoint = Add(store, "UPDATE session_step SET session_id=@p0 WHERE session_id=@p1;", 2);
            SessionDelete = Add(store, "DELETE FROM client_session WHERE id=@p0;", 1);
        }

        public void Use(SqliteTransaction tx) { foreach (var p in _all) p.Use(tx); }
        public void Dispose() { foreach (var p in _all) p.Dispose(); }
    }

    /// <summary>A parsed file waiting for the apply thread. It owns the SMTP spool of the file, deleted when the file is applied or abandoned.</summary>
    sealed class ParsedFile : IDisposable
    {
        public FileWork Work;
        public FileResult Result;
        public object Context;          // Collector.ParseContext
        public SmtpSpool Spool;
        public long StartOffset, NewOffset;
        public string Fields;
        public double Started, Ended;   // seconds since the start of the run
        public double ApplySeconds;     // time spent by the apply thread on its records
        public long QueuedBytes;        // bytes read, counted in the budget of the queue of parsed files

        public void Dispose()
        {
            var spool = Spool;
            Spool = null;
            if (spool != null) spool.Dispose();
        }
    }

    /// <summary>A collection running in the background. PowerShell polls it: Wait, Progress, TakeFinished.</summary>
    public sealed class CollectionRun
    {
        internal readonly object Lock = new object();
        internal readonly Stopwatch Clock = Stopwatch.StartNew();
        internal readonly CancellationTokenSource Cancel = new CancellationTokenSource();
        internal readonly ManualResetEventSlim Finished = new ManualResetEventSlim(false);
        internal readonly List<SourceJob> FinishedJobs = new List<SourceJob>();
        internal readonly List<string> LogLines = new List<string>();
        internal readonly Dictionary<int, string> Reading = new Dictionary<int, string>();
        internal int FilesPlanned, FilesDone, ErrorCount, WorkerCount;
        /// <summary>Most files of one server read at the same time (Collection.MaxFilesPerServer).</summary>
        public int PeakFilesPerServer { get; internal set; }
        internal long BytesPlanned, BytesDone, LinesDone, KeptDone;
        public SourceJob[] Jobs { get; internal set; }
        public Exception Error { get; internal set; }
        public bool Cancelled { get { return Cancel.IsCancellationRequested; } }
        public double Seconds { get; internal set; }
        /// <summary>Where the time went (execution log): parse threads busy, apply thread by task, waits, GC pauses.</summary>
        public string Statistics { get; internal set; }
        // access, back end, rows, sessions, aggregates, commit, wait, other, rollups, SMTP clients (part of rows and commit),
        // SMTP rows and message tracking rows (the two parts of rows), compression of the long texts (part of the task that writes them)
        internal readonly double[] ApplyTimes = new double[13];
        internal double ParseBusy;
        internal double ParseGateWait;       // parse threads: time spent choosing the next file (waiting for a file a thread may read)
        internal double ParseQueueBlocked;   // parse threads: time spent waiting for room in the queue of parsed files (the apply thread is behind)
        internal long RollupKeys;   // rollup identities reconciled in this run
        internal string RollupMode = "reconciled with every commit";   // CollectorOptions.DeferRollups decision (statistics)
        internal long DrainKeys;    // rollup identities reconciled after the last batch (deferred rollups)
        internal double DrainSeconds;
        internal int Batches;
        internal int WalRestarts;            // TRUNCATE checkpoints of the apply thread (CollectorOptions.WalRestartBytes) that emptied the WAL
        internal double WalRestartSeconds;   // their time (and that of the attempts that did not complete)
        internal double WalRestartGateWait;  // part of it spent waiting for a background copy in progress
        internal long MaxWalBytes;           // largest WAL file seen during the run (apply and checkpoint threads)
        internal double AuthFlushSeconds;    // AuthResolver.Flush (part of rows and commits): time, calls with sessions queued, sessions queued
        internal int AuthFlushCalls;
        internal long AuthFlushSessions;
        internal double ParsePackSeconds;    // compression of the stored texts on the parse threads (part of their busy time)
        // Parse threads: Stopwatch ticks spent in FileStream.Read (part of their busy time), for the files of the main streams (ParseSchedule groups
        // 0 and 2: HttpProxy, IIS, back end, POP/IMAP) and for the filler (group 1: SMTP and message tracking).
        internal long ReadTicksMain, ReadTicksFiller;
        // Parse threads: Stopwatch ticks they waited for the bytes of their files (their own reads and the reads ahead not done yet), same groups.
        internal long ReadWaitTicksMain, ReadWaitTicksFiller;
        // Distinct rollup keys invalidated by the rows of this run (RollupKeys counts reconciliations: a key of several batches counts once per batch).
        internal readonly DistinctCounter RollupMessages = new DistinctCounter();
        internal long RollupSmtpRows;
        internal bool RollupKeysCounted;     // the keys are noted by the code (triggers off), so they can be counted

        /// <summary>True when the collection is over (completed, failed or cancelled).</summary>
        public bool Wait(int milliseconds) { return Finished.Wait(milliseconds); }

        /// <summary>Stops the collection: the files already applied are kept, the batch in progress is rolled back.</summary>
        public void Stop() { Cancel.Cancel(); }

        public RunProgress Progress()
        {
            lock (Lock)
            {
                return new RunProgress
                {
                    FilesPlanned = FilesPlanned, FilesDone = FilesDone, Errors = ErrorCount, Workers = WorkerCount, BytesPlanned = BytesPlanned, BytesDone = BytesDone,
                    Lines = LinesDone, Kept = KeptDone, Seconds = Clock.Elapsed.TotalSeconds, Reading = Reading.Values.OrderBy(x => x, StringComparer.Ordinal).ToArray()
                };
            }
        }

        /// <summary>Sources whose files are all read and saved since the last call (one console row each).</summary>
        public SourceJob[] TakeFinished()
        {
            lock (Lock) { var a = FinishedJobs.ToArray(); FinishedJobs.Clear(); return a; }
        }

        /// <summary>Lines for the execution log (file errors, files read again from the beginning).</summary>
        public string[] TakeLog()
        {
            lock (Lock) { var a = LogLines.ToArray(); LogLines.Clear(); return a; }
        }
    }

    /// <summary>
    /// Number of distinct texts (statistics only): exact up to ExactLimit texts, then estimated by HyperLogLog over a 64-bit hash of each text
    /// (2^14 registers: about 1% error, 16 KB whatever the number of texts).
    /// </summary>
    sealed class DistinctCounter
    {
        const int ExactLimit = 65536, Bits = 14;
        HashSet<string> _exact = new HashSet<string>(StringComparer.Ordinal);
        byte[] _registers;

        /// <summary>hash: Store.MessageHash(text) (only used once the count is estimated).</summary>
        public void Add(string text, long hash)
        {
            if (_exact == null) { Register(hash); return; }
            if (!_exact.Add(text) || _exact.Count <= ExactLimit) return;
            _registers = new byte[1 << Bits];
            foreach (var x in _exact) Register(Store.MessageHash(x).Value);
            _exact = null;
        }

        void Register(long hash)
        {
            // FNV-1a spreads its high bits poorly: the splitmix64 finalizer first.
            ulong z = (ulong)hash;
            z ^= z >> 30; z *= 0xbf58476d1ce4e5b9UL; z ^= z >> 27; z *= 0x94d049bb133111ebUL; z ^= z >> 31;
            int index = (int)(z >> (64 - Bits));
            ulong rest = z << Bits;
            byte rank = (byte)(rest == 0 ? 64 - Bits + 1 : System.Numerics.BitOperations.LeadingZeroCount(rest) + 1);
            if (rank > _registers[index]) _registers[index] = rank;
        }

        public bool Exact { get { return _exact != null; } }

        public long Count
        {
            get
            {
                if (_exact != null) return _exact.Count;
                int m = 1 << Bits, zeros = 0;
                double sum = 0;
                foreach (byte r in _registers) { sum += Math.Pow(2, -r); if (r == 0) zeros++; }
                double estimate = 0.7213 / (1 + 1.079 / m) * m * m / sum;
                if (estimate <= 2.5 * m && zeros > 0) estimate = m * Math.Log((double)m / zeros);
                return (long)Math.Round(estimate);
            }
        }
    }

    public sealed partial class Collector
    {
        // ================================================================ plan

        /// <summary>
        /// Lists the files of every source in parallel. A file is read when it is not known yet and was modified
        /// since sinceUtc (first collection: BackfillDays), or when its read position is not its size (new lines, or
        /// an SMTP, IMAP or POP session held back). Known files are found by their identity (FileKey), so a file read
        /// through the administrative share before -Mode Discover and through its local path after is known.
        /// </summary>
        public void Plan(SourceJob[] jobs, DateTime sinceUtc)
        {
            var known = _store.KnownFiles();
            // Listing a folder is a few network round trips: twice the read threads, at most 16 folders at the same time.
            var options = new ParallelOptions { MaxDegreeOfParallelism = Math.Max(2, Math.Min(16, EffectiveParallelism * 2)) };
            Parallel.ForEach(jobs, options, job =>
            {
                job.Files.Clear(); job.Total = 0; job.Newest = DateTime.MinValue; job.PlannedBytes = 0; job.ListError = null;
                try
                {
                    job.FolderFound = Directory.Exists(job.Folder);
                    if (!job.FolderFound) return;
                    var dir = new DirectoryInfo(job.Folder);
                    var enumeration = new EnumerationOptions { RecurseSubdirectories = job.Recurse, IgnoreInaccessible = true, MatchCasing = MatchCasing.CaseInsensitive };
                    foreach (var f in dir.EnumerateFiles(job.Filter ?? "*.log", enumeration))
                    {
                        job.Total++;
                        var write = f.LastWriteTimeUtc;
                        if (write > job.Newest) job.Newest = write;
                        FileState state;
                        bool isKnown = known.TryGetValue(job.Server + "|" + job.Kind + "|" + Store.FileKey(job.Server, f.FullName), out state);
                        if (!isKnown && write < sinceUtc) continue;
                        if (isKnown && state.Offset == f.Length) continue;
                        var copy = isKnown ? state.CopyFor(f.FullName) : new FileState { Server = job.Server, Kind = job.Kind, Path = f.FullName };
                        job.Files.Add(new FileWork { Job = job, Path = f.FullName, Name = f.Name, Length = f.Length, LastWriteUtc = write, State = copy });
                    }
                    job.Files.Sort((a, b) => a.LastWriteUtc != b.LastWriteUtc ? a.LastWriteUtc.CompareTo(b.LastWriteUtc) : string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
                    job.PlannedBytes = job.Files.Sum(x => Math.Max(0, x.Length - (x.State.Offset <= x.Length ? x.State.Offset : 0)));
                }
                catch (Exception ex) { job.ListError = ex.GetType().Name + ": " + ex.Message; }
            });
        }

        // ================================================================ run

        // Queue of the parsed files: bytes read held at most (at least QueueMinFiles files whatever their size), and a bound of files.
        // 384 MB read: the parsed records of a file take about as much managed memory as its bytes (HttpProxy) to three times as much (message
        // tracking), so the queue stays a bounded part of the working set (managed heap and the page cache of the collection together).
        const long QueueBytes = 384L * 1024 * 1024;
        const int QueueMinFiles = 2, QueueMaxFiles = 256;

        public int EffectiveParallelism
        {
            get { return _o.Parallelism > 0 ? _o.Parallelism : Math.Max(2, Math.Min(16, Environment.ProcessorCount)); }
        }

        /// <summary>Starts the collection of the planned files in the background. Call Complete() once it is over.</summary>
        public CollectionRun Start(SourceJob[] jobs)
        {
            var run = new CollectionRun { Jobs = jobs };
            var all = jobs.SelectMany(j => j.Files).ToList();
            var schedule = new ParseSchedule(all);
            run.FilesPlanned = all.Count;
            run.BytesPlanned = jobs.Sum(j => j.PlannedBytes);
            int workers = Math.Max(1, Math.Min(EffectiveParallelism, Math.Max(1, all.Count)));
            run.WorkerCount = workers;
            foreach (var j in jobs) if (j.Files.Count == 0) j.Done = true;

            var gate = new object();
            int firstLeft = schedule.FirstCount;   // HttpProxy files not applied yet: the last group waits for them
            // Parsed files waiting for the apply thread: at most QueueBytes read (at least QueueMinFiles files), so that the parse
            // threads keep going during a run of files that are slow to write.
            var output = new BlockingCollection<ParsedFile>(Math.Max(QueueMaxFiles, workers * 2));
            var room = new object();
            long queuedBytes = 0;
            int queuedFiles = 0;
            var token = run.Cancel.Token;
            int running = workers;
            // Files of each server being read: at most MaxFilesPerServer, so that the threads spread over the servers
            // and no server (or the local disk of the collector) serves all of them.
            var reading = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            int perServer = _o.MaxFilesPerServer;
            Func<FileWork, bool> canRead = w =>
            {
                int n; reading.TryGetValue(w.Job.Server, out n);
                return perServer <= 0 || n < perServer;
            };

            Func<FileWork> next = () =>
            {
                lock (gate)
                {
                    while (true)
                    {
                        if (token.IsCancellationRequested) return null;
                        var w = schedule.Take(firstLeft == 0, canRead);
                        if (w != null)
                        {
                            int n; reading.TryGetValue(w.Job.Server, out n);
                            reading[w.Job.Server] = n + 1;
                            if (n + 1 > run.PeakFilesPerServer) run.PeakFilesPerServer = n + 1;
                            return w;
                        }
                        if (schedule.Count == 0) return null;
                        Monitor.Wait(gate, 500);
                    }
                }
            };
            Action<FileWork> done = w =>
            {
                lock (gate) { reading[w.Job.Server]--; Monitor.PulseAll(gate); }
            };

            for (int i = 0; i < workers; i++)
            {
                int slot = i;
                var thread = new Thread(() =>
                {
                    var memo = new Memo { Days = new DayCache(_o.Zone) };
                    try
                    {
                        while (true)
                        {
                            long gateMark = Stopwatch.GetTimestamp();
                            FileWork w = next();
                            double gateSeconds = Stopwatch.GetElapsedTime(gateMark).TotalSeconds;
                            lock (run.Lock) run.ParseGateWait += gateSeconds;
                            if (w == null) break;
                            lock (run.Lock) run.Reading[slot] = w.Job.Server + " " + w.Job.Label + " " + w.Name;
                            ParsedFile parsed;
                            try { parsed = ParseFile(w, run, memo); }
                            finally { done(w); }
                            memo.Trim();
                            lock (run.Lock) run.Reading.Remove(slot);
                            long queueMark = Stopwatch.GetTimestamp();
                            try
                            {
                                parsed.QueuedBytes = parsed.Result.BytesRead;
                                lock (room)
                                {
                                    while (queuedFiles >= QueueMinFiles && queuedBytes + parsed.QueuedBytes > QueueBytes)
                                    {
                                        token.ThrowIfCancellationRequested();
                                        Monitor.Wait(room, 200);
                                    }
                                    queuedFiles++; queuedBytes += parsed.QueuedBytes;
                                }
                                output.Add(parsed, token);
                            }
                            catch (Exception) { parsed.Dispose(); throw; }
                            finally { double blocked = Stopwatch.GetElapsedTime(queueMark).TotalSeconds; lock (run.Lock) run.ParseQueueBlocked += blocked; }
                        }
                    }
                    catch (OperationCanceledException) { }
                    catch (Exception ex) { lock (run.Lock) { if (run.Error == null) run.Error = ex; } run.Cancel.Cancel(); }
                    finally { if (Interlocked.Decrement(ref running) == 0) output.CompleteAdding(); }
                }) { IsBackground = true, Name = "ELR parse " + slot.ToString(System.Globalization.CultureInfo.InvariantCulture), Priority = ThreadPriority.BelowNormal };
                thread.Start();
            }

            var apply = new Thread(() =>
            {
                var gcPause = GC.GetTotalPauseDuration();
                int gcCount = GC.CollectionCount(0), gc1Count = GC.CollectionCount(1), gc2Count = GC.CollectionCount(2);
                long rollupReadTicks = _store.RollupReadTicks, rollupWriteTicks = _store.RollupWriteTicks;   // the part of the message rollups of this run (statistics)
                long gcIndex = GcIndex();
                Thread checkpointer = null;
                var stopCheckpoints = new ManualResetEventSlim(false);
                bool? triggersBefore = null;
                bool cacheChanged = false;
                // Process-wide setting: the collection avoids the blocking full collections (background ones only) while it runs, and gives the
                // previous mode back at the end.
                var latencyBefore = System.Runtime.GCSettings.LatencyMode;
                try
                {
                    System.Runtime.GCSettings.LatencyMode = System.Runtime.GCLatencyMode.SustainedLowLatency;
                    // Triggers off for this connection, BEFORE any statement is prepared (SQLite compiles trigger programs at prepare time):
                    // the rollup invalidations of the rows inserted below are then written by NoteRollup/FlushRollupDirty. When the setting
                    // cannot be applied, the triggers keep running and nothing is written twice.
                    _rollupInCode = false;
                    if (_o.DisableTriggersDuringApply)
                    {
                        triggersBefore = _store.SetTriggersEnabled(false);
                        _rollupInCode = triggersBefore.HasValue;
                    }
                    _run = run;
                    run.RollupKeysCounted = _rollupInCode;
                    _writer = new Writer(_store);
                    // The SMTP client structures are written by the code, in the batch transaction, only while the triggers are off (otherwise the triggers queue the work).
                    _clients = _rollupInCode ? new SmtpClientMaintenance(_store) : null;
                    _auth = new AuthResolver(_store, _writer, _o.SmtpIdleMs, _clients);
                    _times = run.ApplyTimes;
                    // The WAL is copied into the database by a thread of its own (another connection): the commits of the
                    // apply thread only append to the WAL, the copy and its flush to the disk run at the same time.
                    _store.Exec("PRAGMA wal_autocheckpoint=0;");
                    if (_o.CacheKilobytes > 0) { _store.Exec("PRAGMA cache_size=-" + _o.CacheKilobytes.ToString(System.Globalization.CultureInfo.InvariantCulture) + ";"); cacheChanged = true; }
                    // Initial bulk import (DeferRollups Auto or Always): the rollups are reconciled once after the last batch instead of with every commit.
                    string deferReason = DeferRollupsReason(run);
                    _deferRollups = deferReason != null;
                    run.RollupMode = _deferRollups ? "deferred to the end of the collection (" + deferReason + ")" : "reconciled with every commit";
                    checkpointer = new Thread(() => Checkpoints(stopCheckpoints, run)) { IsBackground = true, Name = "ELR checkpoint" };
                    checkpointer.Start();
                    // The leftover of an interrupted bulk run is drained first, in chunks of their own transactions: the first commit does not carry it.
                    if (!_deferRollups && LargeRollupLeftover())
                    {
                        long leftoverMark = Stopwatch.GetTimestamp();
                        long leftover = _store.DrainMessageRollups(DrainChunkKeys, token, () => RestartWalIfLarge(run));
                        double leftoverSeconds = Stopwatch.GetElapsedTime(leftoverMark).TotalSeconds;
                        run.RollupKeys += leftover;
                        _times[8] += leftoverSeconds;
                        run.RollupMode = string.Format(System.Globalization.CultureInfo.InvariantCulture, "reconciled with every commit, after a drain of {0} keys left in the queue ({1:0.0} s)", leftover, leftoverSeconds);
                    }
                    var batchClock = Stopwatch.StartNew();
                    while (true)
                    {
                        ParsedFile p;
                        bool got = output.TryTake(out p, 0, token);
                        long waitStart = Stopwatch.GetTimestamp();
                        if (!got)
                        {
                            // Nothing queued and a large WAL: commit before waiting, so that the writer is idle during the wait and the background
                            // copy can let SQLite start the log again (it does when a writer begins after every frame was copied). Same rows.
                            if (_batch != null && _o.WalRestartBytes > 0 && _store.WalBytes > _o.WalRestartBytes / 2) CommitBatch(run);
                            waitStart = Stopwatch.GetTimestamp();
                            got = output.TryTake(out p, Timeout.Infinite, token);
                        }
                        _times[6] += Stopwatch.GetElapsedTime(waitStart).TotalSeconds;
                        if (!got) break;
                        lock (room) { queuedFiles--; queuedBytes -= p.QueuedBytes; Monitor.PulseAll(room); }
                        if (_batch == null) { BeginBatch(); batchClock.Restart(); }
                        Apply(p, run);
                        if (p.Work.Group == 0)
                            lock (gate) { firstLeft--; if (firstLeft == 0) Monitor.PulseAll(gate); }
                        if (_batch.Rows >= _o.BatchRows || batchClock.Elapsed.TotalSeconds >= _o.BatchSeconds || (p.Work.Group == 0 && firstLeft == 0)) CommitBatch(run);
                    }
                    if (_batch != null) CommitBatch(run);
                    if (token.IsCancellationRequested && run.Error == null) throw new OperationCanceledException();
                    // The rollups deferred by the batches, reconciled in chunks of their own transactions (a failure or a stop leaves the rest queued).
                    if (_deferRollups)
                    {
                        long drainMark = Stopwatch.GetTimestamp();
                        run.DrainKeys = _store.DrainMessageRollups(DrainChunkKeys, token, () => RestartWalIfLarge(run));
                        run.RollupKeys += run.DrainKeys;
                        run.DrainSeconds = Stopwatch.GetElapsedTime(drainMark).TotalSeconds;
                        _times[8] += run.DrainSeconds;
                    }
                }
                catch (OperationCanceledException) { RollbackBatch(); }
                catch (Exception ex)
                {
                    RollbackBatch();
                    lock (run.Lock) { if (run.Error == null) run.Error = ex; }
                    run.Cancel.Cancel();
                }
                finally
                {
                    System.Runtime.GCSettings.LatencyMode = latencyBefore;
                    lock (gate) Monitor.PulseAll(gate);
                    // Let the parse threads finish (they stop at the cancellation) before the database is used again.
                    try { foreach (var left in output.GetConsumingEnumerable()) { try { left.Dispose(); } catch (Exception) { /* the run already failed or was cancelled: that failure is the one reported */ } } } catch (Exception) { }
                    // Files that were taken from the queue before the failure have been disposed by Apply; the resolver's work file goes with it.
                    if (_auth != null) { try { _auth.Dispose(); } catch (Exception ex) { lock (run.Lock) { if (run.Error == null) run.Error = ex; } } _auth = null; }
                    if (_clients != null) { try { _clients.Dispose(); } catch (Exception ex) { lock (run.Lock) { if (run.Error == null) run.Error = ex; } } _clients = null; }
                    if (_writer != null) { _writer.Dispose(); _writer = null; }
                    // The statements are finalized: give the connection its trigger setting back (also after a failure or a cancellation).
                    if (_rollupInCode)
                    {
                        _rollupInCode = false;
                        bool? restored = null;
                        try { restored = _store.SetTriggersEnabled(triggersBefore ?? true); } catch (Exception ex) { lock (run.Lock) { if (run.Error == null) run.Error = ex; } }
                        if (restored == null) lock (run.Lock) { if (run.Error == null) run.Error = new InvalidOperationException("The triggers of the collection connection could not be enabled again."); }
                    }
                    stopCheckpoints.Set();
                    if (checkpointer != null) checkpointer.Join();
                    if (cacheChanged)
                    {
                        try { _store.Exec("PRAGMA cache_size=-" + Store.CacheKilobytes.ToString(System.Globalization.CultureInfo.InvariantCulture) + ";"); }
                        catch (Exception ex) { lock (run.Lock) { if (run.Error == null) run.Error = ex; } }
                    }
                    _deferRollups = false;
                    _times = null;
                    _run = null;
                    // The arrays kept from one batch to the next are not kept from one collection to the next.
                    _spareBatch = null;
                    _lists.Clear();
                    run.Seconds = run.Clock.Elapsed.TotalSeconds;
                    NoteWalBytes(run, _store.WalBytes);
                    var t = run.ApplyTimes;
                    double busy = t.Take(6).Sum() + t[7] + t[8] + run.WalRestartSeconds;
                    // Distinct keys of the rows of this run against the reconciliations ({19}): a key of several batches is reconciled with each of them.
                    string distinct = !run.RollupKeysCounted ? "distinct keys not counted (rollup triggers on)" :
                        string.Format(System.Globalization.CultureInfo.InvariantCulture, "{0}{1} distinct keys from the rows of this run",
                            run.RollupMessages.Exact ? "" : "about ", run.RollupMessages.Count + run.RollupSmtpRows);
                    run.Statistics = string.Format(System.Globalization.CultureInfo.InvariantCulture,
                        "{0:0.0} s, {1} parse thread(s) busy {2:0}% ({3:0.0} s), waiting for a file to read {31:0.0} s, waiting for room in the queue {32:0.0} s, at most {17} file(s) of one server at the same time, apply thread busy {4:0}%: client access {5:0.0} s, back end {6:0.0} s, rows {7:0.0} s (SMTP {33:0.0} s, message tracking {34:0.0} s), sessions {8:0.0} s, aggregates {9:0.0} s, commits {10:0.0} s ({11} batches), SMTP clients {20:0.0} s (included in rows and commits), SMTP authentication {38:0.0} s ({39} flushes, {40} sessions; included in rows and commits), compression {35:0.0} s (included in access, rows and sessions; on the parse threads {37:0.0} s), message rollups {18:0.0} s ({19} keys), {36}, rollup reads {43:0.0} s, rollup writes {44:0.0} s, waiting for files {12:0.0} s; WAL copied into the database in the background {15} time(s) ({41} at short intervals, the WAL above half its restart bound), {16:0.0} s, {21} frames; GC {13} collections (gen1+ {25}, gen2 {26}), pauses {14:0.0} s{27}; message rollups {22}, final rollup drain {23:0.0} s, {24} keys; {28} WAL restart(s) ({29:0.0} s), max WAL {30:0.0} MB, restarts waiting for a background copy {42:0.0} s, file reads {45:0.0} s (main {46:0.0} s, filler {47:0.0} s), parse threads waiting for the reads {48:0.0} s (main {49:0.0} s, filler {50:0.0} s)",
                        run.Seconds, workers, 100 * run.ParseBusy / Math.Max(0.001, workers * run.Seconds), run.ParseBusy, 100 * busy / Math.Max(0.001, run.Seconds),
                        t[0], t[1], t[2], t[3], t[4], t[5], run.Batches, t[6], GC.CollectionCount(0) - gcCount, (GC.GetTotalPauseDuration() - gcPause).TotalSeconds, CheckpointCount, CheckpointSeconds, run.PeakFilesPerServer, t[8], run.RollupKeys, t[9], CheckpointFrames, run.RollupMode, run.DrainSeconds, run.DrainKeys,
                        GC.CollectionCount(1) - gc1Count, GC.CollectionCount(2) - gc2Count, GcPauseDetail(gcIndex), run.WalRestarts, run.WalRestartSeconds, Interlocked.Read(ref run.MaxWalBytes) / 1048576.0,
                        run.ParseGateWait, run.ParseQueueBlocked, t[10], t[11], t[12], distinct, run.ParsePackSeconds, run.AuthFlushSeconds, run.AuthFlushCalls, run.AuthFlushSessions,
                        CheckpointFastCount, run.WalRestartGateWait,
                        (_store.RollupReadTicks - rollupReadTicks) / (double)Stopwatch.Frequency, (_store.RollupWriteTicks - rollupWriteTicks) / (double)Stopwatch.Frequency,
                        (run.ReadTicksMain + run.ReadTicksFiller) / (double)Stopwatch.Frequency, run.ReadTicksMain / (double)Stopwatch.Frequency, run.ReadTicksFiller / (double)Stopwatch.Frequency,
                        (run.ReadWaitTicksMain + run.ReadWaitTicksFiller) / (double)Stopwatch.Frequency, run.ReadWaitTicksMain / (double)Stopwatch.Frequency, run.ReadWaitTicksFiller / (double)Stopwatch.Frequency);
                    run.Finished.Set();
                }
            }) { IsBackground = true, Name = "ELR apply" };
            apply.Start();
            return run;
        }

        /// <summary>
        /// Copies the WAL into the database with its own connection (PASSIVE: never waits for the writer) every
        /// CollectorOptions.CheckpointSeconds, while the apply thread only appends to the WAL: the copy and its flush to the disk run at the same
        /// time as the parsing and the writing. Time spent in CheckpointSeconds (execution log). It shares _checkpointGate with the WAL restarts
        /// of the apply thread: a copy that finds the gate taken is skipped (the WAL is being emptied). While the WAL file is larger than half of
        /// CollectorOptions.WalRestartBytes the copies follow each other (CheckpointWaitMs), so that the restart finds almost every frame copied.
        /// </summary>
        void Checkpoints(ManualResetEventSlim stop, CollectionRun run)
        {
            try
            {
                var builder = new SqliteConnectionStringBuilder { DataSource = _store.FilePath, Mode = SqliteOpenMode.ReadWrite, Pooling = false };
                using (var db = new SqliteConnection(builder.ToString()))
                {
                    db.Open();
                    using (var c = db.CreateCommand()) { c.CommandText = "PRAGMA busy_timeout=5000;"; c.ExecuteNonQuery(); }
                    using (var c = db.CreateCommand())
                    {
                        c.CommandText = "PRAGMA wal_checkpoint(PASSIVE);";
                        var since = Stopwatch.StartNew();   // since the last copy
                        int wait = CheckpointWaitMs(_store.WalBytes, _o.WalRestartBytes, _o.CheckpointSeconds, false);
                        while (!stop.Wait(wait))
                        {
                            long walBytes = _store.WalBytes;
                            wait = CheckpointWaitMs(walBytes, _o.WalRestartBytes, _o.CheckpointSeconds, false);
                            if (!CheckpointDue(walBytes, _o.WalRestartBytes, _o.CheckpointSeconds, since.ElapsedMilliseconds)) continue;
                            bool fast = since.ElapsedMilliseconds < Math.Max(1, _o.CheckpointSeconds) * 1000L;
                            if (!Monitor.TryEnter(_checkpointGate)) continue;
                            bool advanced = false;
                            try
                            {
                                var watch = Stopwatch.StartNew();
                                try
                                {
                                    // Row: busy, frames in the WAL, frames copied into the database since the log started (cumulative: counted as a difference).
                                    using (var r = c.ExecuteReader())
                                    {
                                        if (r.Read())
                                        {
                                            long log = r.GetInt64(1), backfill = r.GetInt64(2);
                                            long copied = FrameDelta(_ckLog, _ckBackfill, log, backfill);
                                            CheckpointFrames += copied;
                                            advanced = copied > 0;
                                            if (log >= 0 && backfill >= 0) { _ckLog = log; _ckBackfill = backfill; }
                                        }
                                    }
                                    CheckpointCount++;
                                    if (fast) CheckpointFastCount++;
                                }
                                catch (SqliteException) { }
                                CheckpointSeconds += watch.Elapsed.TotalSeconds;
                                NoteWalBytes(run, _store.WalBytes);
                            }
                            finally { Monitor.Exit(_checkpointGate); }
                            since.Restart();
                            wait = CheckpointWaitMs(_store.WalBytes, _o.WalRestartBytes, _o.CheckpointSeconds, advanced);
                        }
                    }
                }
            }
            catch (Exception) { }
        }

        // Above half the restart bound: the pause after a background copy that copied frames (the gate is free for the apply thread in between),
        // and after a copy that copied nothing or could not run (no busy loop while the writer is idle or the WAL is being emptied). Below it, the
        // size of the WAL file is looked at every CheckpointPollMs (at most CheckpointSeconds) between two timed copies.
        internal const int CheckpointPauseMs = 10, CheckpointIdleMs = 200, CheckpointPollMs = 1000;
        // How long a WAL restart waits for a background copy in progress (it copies what the restart would copy) before it is put off to the next commit.
        const int RestartGateWaitMs = 2000;

        static bool WalAboveHalf(long walBytes, long restartBytes) { return restartBytes > 0 && walBytes > restartBytes / 2; }

        /// <summary>
        /// Milliseconds before the checkpoint thread looks again: above half of WalRestartBytes, CheckpointPauseMs after a copy that copied frames
        /// and CheckpointIdleMs after one that copied nothing; below (or without bound), CheckpointPollMs, at most CheckpointSeconds.
        /// </summary>
        internal static int CheckpointWaitMs(long walBytes, long restartBytes, int checkpointSeconds, bool advanced)
        {
            int interval = Math.Max(1, checkpointSeconds) * 1000;
            if (!WalAboveHalf(walBytes, restartBytes)) return Math.Min(interval, CheckpointPollMs);
            return advanced ? CheckpointPauseMs : CheckpointIdleMs;
        }

        /// <summary>A background copy is due: CheckpointSeconds since the last one, or at once while the WAL file is above half of WalRestartBytes.</summary>
        internal static bool CheckpointDue(long walBytes, long restartBytes, int checkpointSeconds, long sinceMs)
        {
            return WalAboveHalf(walBytes, restartBytes) || sinceMs >= Math.Max(1, checkpointSeconds) * 1000L;
        }

        /// <summary>
        /// Frames copied since the previous checkpoint call, from two rows of PRAGMA wal_checkpoint (log = mxFrame, backfill = nBackfill, both
        /// counted from the start of the log). A log that started again (smaller log or backfill) counts its backfill from zero; -1 counts nothing.
        /// </summary>
        internal static long FrameDelta(long lastLog, long lastBackfill, long log, long backfill)
        {
            if (log < 0 || backfill < 0) return 0;
            if (log < lastLog || backfill < lastBackfill) return backfill;
            return backfill - lastBackfill;
        }

        /// <summary>Records the largest WAL file of the run (apply and checkpoint threads).</summary>
        static void NoteWalBytes(CollectionRun run, long bytes)
        {
            long seen = Interlocked.Read(ref run.MaxWalBytes);
            while (bytes > seen)
            {
                long was = Interlocked.CompareExchange(ref run.MaxWalBytes, bytes, seen);
                if (was == seen) break;
                seen = was;
            }
        }

        /// <summary>
        /// Apply thread, between two transactions (after a commit, or a chunk of a rollup drain): a WAL file larger than
        /// CollectorOptions.WalRestartBytes is copied into the database and emptied (TRUNCATE, durable like any checkpoint). A background copy
        /// in progress holds the gate: the restart waits for it up to RestartGateWaitMs (that copy does part of its work), else it is skipped
        /// (tried again after the next commit); a checkpoint that cannot complete (a reader holds an old snapshot) is reported and leaves the WAL as it is.
        /// </summary>
        void RestartWalIfLarge(CollectionRun run)
        {
            long wal = _store.WalBytes;
            NoteWalBytes(run, wal);
            if (_o.WalRestartBytes <= 0 || wal <= Math.Max(_o.WalRestartBytes, _walRetryBytes) || _batch != null) return;
            long mark = Stopwatch.GetTimestamp();
            bool entered = Monitor.TryEnter(_checkpointGate, RestartGateWaitMs);
            double gateWait = Stopwatch.GetElapsedTime(mark).TotalSeconds;
            run.WalRestartGateWait += gateWait;
            if (!entered) { run.WalRestartSeconds += gateWait; return; }
            string failure = null;
            try
            {
                var r = _store.Checkpoint("TRUNCATE");
                if (r.Complete)
                {
                    run.WalRestarts++; _ckLog = 0; _ckBackfill = 0; _walRetryBytes = 0;
                    double seconds = Stopwatch.GetElapsedTime(mark).TotalSeconds;
                    lock (run.Lock) run.LogLines.Add(string.Format(System.Globalization.CultureInfo.InvariantCulture, "INFO|WAL restart: {0:0} MB copied into the database and emptied in {1:0.0} s (log {2} frame(s), {3} copied).", wal / 1048576.0, seconds, r.Log, r.Checkpointed));
                }
                else failure = string.Format(System.Globalization.CultureInfo.InvariantCulture, "busy {0}, {1} frame(s) in the log, {2} copied", r.Busy, r.Log, r.Checkpointed);
            }
            catch (SqliteException ex) { failure = ex.Message; }
            finally { Monitor.Exit(_checkpointGate); }
            run.WalRestartSeconds += Stopwatch.GetElapsedTime(mark).TotalSeconds;
            if (failure == null) return;
            // A reader that keeps the checkpoint waiting (busy_timeout) would hold every commit: the next attempt waits for a quarter more WAL.
            _walRetryBytes = wal + Math.Max(1, _o.WalRestartBytes / 4);
            lock (run.Lock) run.LogLines.Add(string.Format(System.Globalization.CultureInfo.InvariantCulture, "WARN|The WAL ({0:0} MB) could not be emptied ({1}): tried again above {2:0} MB.", wal / 1048576.0, failure, _walRetryBytes / 1048576.0));
        }

        /// <summary>Index of the latest garbage collection of the process (0 when the runtime does not report it).</summary>
        static long GcIndex()
        {
            try { return GC.GetGCMemoryInfo(GCKind.Any).Index; } catch (Exception) { return 0; }
        }

        /// <summary>
        /// Pause breakdown for the statistics (GC.GetGCMemoryInfo): share of the process time in pauses, then the latest ephemeral, full
        /// blocking and background collection of the run (generation, pause, heap after it). Empty when the runtime does not report it.
        /// </summary>
        static string GcPauseDetail(long sinceIndex)
        {
            try
            {
                var text = new System.Text.StringBuilder();
                var any = GC.GetGCMemoryInfo(GCKind.Any);
                text.AppendFormat(System.Globalization.CultureInfo.InvariantCulture, " ({0:0.0}% of the process time since it started", any.PauseTimePercentage);
                foreach (var kind in new[] { GCKind.Ephemeral, GCKind.FullBlocking, GCKind.Background })
                {
                    var info = GC.GetGCMemoryInfo(kind);
                    if (info.Index <= sinceIndex) continue;
                    double ms = 0;
                    foreach (var d in info.PauseDurations) ms += d.TotalMilliseconds;
                    text.AppendFormat(System.Globalization.CultureInfo.InvariantCulture, "; last {0}: gen{1}, pause {2:0.0} ms, heap {3:0} MB, fragmented {4:0} MB, promoted {5:0} MB",
                        kind == GCKind.Ephemeral ? "ephemeral" : kind == GCKind.FullBlocking ? "full blocking" : "background", info.Generation, ms,
                        info.HeapSizeBytes / 1048576.0, info.FragmentedBytes / 1048576.0, info.PromotedBytes / 1048576.0);
                }
                return text.Append(')').ToString();
            }
            catch (Exception) { return ""; }
        }

        /// <summary>Background copies of the WAL into the database during the collection, and their time.</summary>
        public int CheckpointCount { get; private set; }
        /// <summary>Those of the background copies that followed the previous one at a short interval (the WAL above half of WalRestartBytes).</summary>
        public int CheckpointFastCount { get; private set; }
        public double CheckpointSeconds { get; private set; }
        /// <summary>WAL frames copied into the database by those background copies (the differences of the cumulative counts they reported).</summary>
        public long CheckpointFrames { get; private set; }
        // The background copies and the WAL restarts of the apply thread take turns; the last row of the background copy (frames of the log, copied).
        readonly object _checkpointGate = new object();
        long _ckLog, _ckBackfill;
        long _walRetryBytes;   // apply thread: after a WAL restart that did not complete, the size of the next attempt (0: WalRestartBytes)

        /// <summary>Parse stage of one file (parse thread).</summary>
        ParsedFile ParseFile(FileWork w, CollectionRun run, Memo memo)
        {
            var result = new FileResult { Server = w.Job.Server, Kind = w.Job.Kind, Path = w.Path };
            var parsed = new ParsedFile { Work = w, Result = result, Started = run.Clock.Elapsed.TotalSeconds };
            var clock = Stopwatch.StartNew();
            long readTicks = memo.Read.ReadTicks, waitTicks = memo.Read.WaitTicks;
            ParseContext c = null;
            try
            {
                var info = new FileInfo(w.Path);
                if (!info.Exists) { result.Error = "File not found"; return parsed; }
                long length = info.Length, start = w.State.Offset;
                string fields = w.State.Fields;
                if (length < start) { start = 0; fields = null; result.Reset = true; }
                parsed.StartOffset = start;
                if (length == start) { result.Unchanged = true; parsed.NewOffset = start; parsed.Fields = fields; return parsed; }
                c = new ParseContext(w.Job.Kind, length - start, _lists)
                {
                    Work = w, Result = result, Server = w.Job.Server, Role = w.Job.Role, Path = w.Path, Fields = fields, StartOffset = start,
                    LastWriteMs = new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeMilliseconds(), Split = memo.Split, Memo = memo, Days = memo.Days,
                    SpoolFolder = System.IO.Path.GetDirectoryName(_store.FilePath)
                };
                parsed.NewOffset = Parse(c, w.Job.Kind);
                parsed.Fields = c.Fields;
                parsed.Context = c;
                parsed.Spool = c.Spool;
                c.Spool = null;
                w.Length = length;
                w.LastWriteUtc = info.LastWriteTimeUtc;
                result.BytesRead = parsed.NewOffset - start;
            }
            catch (Exception ex)
            {
                result.Error = ex.GetType().Name + ": " + ex.Message;
                parsed.Context = null;
                // The spool of a file that failed is deleted at once; a failure of that deletion is added to the error of the file, never hides it.
                try { if (c != null && c.Spool != null) c.Spool.Dispose(); parsed.Dispose(); }
                catch (Exception cleanup) { result.Error += " (the SMTP work file could not be deleted: " + cleanup.Message + ")"; }
            }
            finally
            {
                result.Seconds = clock.Elapsed.TotalSeconds;
                parsed.Ended = run.Clock.Elapsed.TotalSeconds;
                readTicks = memo.Read.ReadTicks - readTicks; waitTicks = memo.Read.WaitTicks - waitTicks;
                lock (run.Lock)
                {
                    run.ParseBusy += result.Seconds; if (c != null) run.ParsePackSeconds += c.PackSeconds;
                    if (w.Group == 1) { run.ReadTicksFiller += readTicks; run.ReadWaitTicksFiller += waitTicks; } else { run.ReadTicksMain += readTicks; run.ReadWaitTicksMain += waitTicks; }
                }
            }
            return parsed;
        }

        // ================================================================ apply (one thread)

        sealed class Batch
        {
            public SqliteTransaction Tx;
            public long Rows;
            public readonly Dictionary<string, UsageAcc> Usage = new Dictionary<string, UsageAcc>(StringComparer.Ordinal);
            public readonly Dictionary<string, ActionAcc> Actions = new Dictionary<string, ActionAcc>(StringComparer.Ordinal);
            public readonly Dictionary<string, ClientAcc> Clients = new Dictionary<string, ClientAcc>(StringComparer.Ordinal);
            public readonly HashSet<ClientSession> Touched = new HashSet<ClientSession>();
            public readonly Dictionary<string, long> Noise = new Dictionary<string, long>(StringComparer.Ordinal);
            public readonly List<ParsedFile> Files = new List<ParsedFile>();
            public readonly Dictionary<FileState, FileState> PendingFiles = new Dictionary<FileState, FileState>();
            // Rollup invalidations of the rows inserted by this batch while the triggers are off (message identity -> hash; SMTP rowids without Message-ID).
            public readonly Dictionary<string, long?> DirtyMessages = new Dictionary<string, long?>(StringComparer.Ordinal);
            public readonly RowidList DirtySmtp = new RowidList();

            /// <summary>
            /// Empties the batch so that the next one uses it again: the collections keep their capacity (no new large arrays for every batch),
            /// except DirtySmtp, whose chunks go. An emptied dictionary or set enumerates in insertion order, as a new one does.
            /// </summary>
            public void Clear()
            {
                Tx = null; Rows = 0;
                Usage.Clear(); Actions.Clear(); Clients.Clear(); Touched.Clear(); Noise.Clear(); Files.Clear(); PendingFiles.Clear();
                DirtyMessages.Clear(); DirtySmtp.Clear();
            }
        }

        /// <summary>
        /// The SMTP rowids inserted by a batch, in the order they were added, in chunks of 8192 (64 KB, under the large object heap threshold): no set
        /// or array that doubles in the large object heap, which only a full collection empties (a batch can insert hundreds of thousands of rows).
        /// A rowid is inserted once; the reconciliation drops a repeat anyway after sorting (SortedRollupKeys), as the set did.
        /// </summary>
        internal sealed class RowidList
        {
            const int ChunkSize = 8192;
            readonly List<long[]> _chunks = new List<long[]>();
            int _count;

            public int Count { get { return _count; } }

            public void Add(long id)
            {
                int chunk = _count / ChunkSize;
                if (chunk == _chunks.Count) _chunks.Add(new long[ChunkSize]);
                _chunks[chunk][_count % ChunkSize] = id;
                _count++;
            }

            public long this[int i] { get { return _chunks[i / ChunkSize][i % ChunkSize]; } }

            /// <summary>Empty again; the chunks go (a large batch does not keep its memory for the next one).</summary>
            public void Clear() { _chunks.Clear(); _count = 0; }

            public void CopyTo(long[] target)
            {
                for (int c = 0, at = 0; at < _count; c++)
                {
                    int n = Math.Min(ChunkSize, _count - at);
                    Array.Copy(_chunks[c], 0, target, at, n);
                    at += n;
                }
            }
        }

        Batch _batch;
        Batch _spareBatch;   // apply thread: the last committed batch, emptied, used again by the next one (null: none yet, or after a rollback)
        readonly ListPool _lists = new ListPool();   // the record lists of the applied files, given to the next files (parse and apply threads)
        bool _deferRollups;   // apply thread: the rollups are reconciled after the last batch (CollectorOptions.DeferRollups), not with every commit
        const int DrainChunkKeys = 100000;       // keys per transaction of the final drain
        const int BulkLeftoverKeys = 100000;     // a queue of more keys than this at the start is the leftover of an interrupted bulk run (drained first)
        const int FlushRollupKeys = 400000;      // keys held in memory by a batch before they are written to the queue
        bool _rollupInCode;   // apply thread: the triggers of the connection are off and the code writes the rollup invalidations
        SmtpClientMaintenance _clients;   // apply thread: schema 11 SMTP client structures, maintained by the code while the triggers are off (else null)
        Writer _writer;
        AuthResolver _auth;
        double[] _times;   // apply thread: seconds per task (CollectionRun.ApplyTimes)
        CollectionRun _run;   // apply thread: the run being applied (its counters)

        void Time(int slot, long since) { if (_times != null) _times[slot] += Stopwatch.GetElapsedTime(since).TotalSeconds; }

        /// <summary>The same time in a task and in one of its parts (detail &lt; 0: none).</summary>
        void Time(int slot, int detail, long since)
        {
            if (_times == null) return;
            double seconds = Stopwatch.GetElapsedTime(since).TotalSeconds;
            _times[slot] += seconds;
            if (detail >= 0) _times[detail] += seconds;
        }

        /// <summary>Packed.Adaptive on the apply thread, its time in slot 12 (compression; also part of the task that writes the value).</summary>
        object Adaptive(string text)
        {
            if (text == null) return null;
            long mark = Stopwatch.GetTimestamp();
            object value = Packed.Adaptive(text);
            Time(12, mark);
            return value;
        }

        /// <summary>Packed.Pack of UTF-8 text on the apply thread, its time in slot 12 (see Adaptive).</summary>
        byte[] PackUtf8(ReadOnlySpan<byte> utf8)
        {
            long mark = Stopwatch.GetTimestamp();
            byte[] value = Packed.PackUtf8(utf8);
            Time(12, mark);
            return value;
        }

        /// <summary>AuthResolver.Flush; its time (which stays in the task that calls it), the calls with sessions queued and those sessions in the statistics.</summary>
        void FlushAuth()
        {
            int queued = _auth.Count;
            if (queued == 0) return;   // Flush has nothing to do
            long mark = Stopwatch.GetTimestamp();
            _auth.Flush(_batch.Tx);
            if (_run == null) return;
            _run.AuthFlushSeconds += Stopwatch.GetElapsedTime(mark).TotalSeconds;
            _run.AuthFlushCalls++;
            _run.AuthFlushSessions += queued;
        }

        void BeginBatch()
        {
            var b = _spareBatch ?? new Batch();
            _spareBatch = null;
            b.Tx = _store.Begin();
            _batch = b;
            _tx = _batch.Tx;
            _writer.Use(_batch.Tx);
            if (_clients != null) _clients.Use(_batch.Tx);
        }

        void RollbackBatch()
        {
            if (_batch == null) return;
            try { _batch.Tx.Rollback(); } catch (Exception) { }
            try { _batch.Tx.Dispose(); } catch (Exception) { }
            _batch = null;
            _tx = null;
            // Sessions in memory may hold requests that were not saved.
            ResetSessions();
            if (_auth != null) _auth.Clear();
            // Clients and values the batch created no longer exist; nothing it queued in memory may be written.
            if (_clients != null) _clients.Reset();
        }

        /// <summary>
        /// What tr_message_event_rollup_insert / tr_smtp_transaction_rollup_insert write for a row that WAS inserted (the caller checked that
        /// Run() changed a row): ('message', Message-ID, hash) when the Message-ID is not NULL, else for an SMTP row ('smtp', rowid, NULL).
        /// Queued per batch and written by FlushRollupDirty in the same transaction, before the reconciliation drains the queue. hash is the
        /// msg_hash bound in the row (Store.MessageHash of the Message-ID, computed by the parse thread). The distinct keys are counted for the statistics.
        /// </summary>
        void NoteRollup(string messageId, long? hash, Prepared insert, bool smtp)
        {
            if (!_rollupInCode) return;
            if (messageId != null)
            {
                _batch.DirtyMessages[messageId] = hash;
                if (_run != null) _run.RollupMessages.Add(messageId, hash.Value);
            }
            else if (smtp)
            {
                // A rowid is inserted once: every SMTP key is distinct.
                _batch.DirtySmtp.Add(insert.LastRowId);
                if (_run != null) _run.RollupSmtpRows++;
            }
        }

        /// <summary>
        /// Why this collection defers the message rollups to the end (null: it does not). Auto: an initial import (message_rollup empty, more than
        /// DeferRollupsAboveBytes planned).
        /// </summary>
        string DeferRollupsReason(CollectionRun run)
        {
            if (_o.DeferRollups == DeferRollupsMode.Never) return null;
            if (_o.DeferRollups == DeferRollupsMode.Always) return "DeferRollups Always";
            if (run.BytesPlanned <= _o.DeferRollupsAboveBytes) return null;
            using (var c = _store.Command("SELECT 1 FROM message_rollup LIMIT 1;"))
                if (c.ExecuteScalar() != null) return null;
            return "Auto: initial import of " + run.BytesPlanned.ToString(System.Globalization.CultureInfo.InvariantCulture) + " bytes";
        }

        /// <summary>More than BulkLeftoverKeys keys already queued at the start (the leftover of an interrupted bulk run): drained before the first batch.</summary>
        bool LargeRollupLeftover()
        {
            using (var c = _store.Command("SELECT COUNT(*) FROM (SELECT 1 FROM message_rollup_dirty LIMIT " + (BulkLeftoverKeys + 1).ToString(System.Globalization.CultureInfo.InvariantCulture) + ");"))
                return Convert.ToInt64(c.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) > BulkLeftoverKeys;
        }

        bool RollupQueueHasRows(SqliteTransaction tx)
        {
            using (var c = _store.Command("SELECT 1 FROM message_rollup_dirty LIMIT 1;", tx)) return c.ExecuteScalar() != null;
        }

        /// <summary>
        /// The keys of the batch as the reconciliation reads the queue (ORDER BY kind, identity; 'message' before 'smtp'): the Message-IDs in the BINARY
        /// order of their UTF-8 text, then the SMTP rowids in the order of their decimal text. Two arrays of the exact size, made for this reconciliation
        /// only: no object, text or box per key, and no list that doubles (a batch can hold hundreds of thousands of keys; large arrays live in the large
        /// object heap, which only a full collection empties). The text of a rowid is written when its key is reconciled.
        /// </summary>
        static void SortedRollupKeys(Batch b, out string[] messages, out long[] smtp)
        {
            messages = new string[b.DirtyMessages.Count];
            b.DirtyMessages.Keys.CopyTo(messages, 0);
            Array.Sort(messages, CompareUtf8);
            smtp = new long[b.DirtySmtp.Count];
            b.DirtySmtp.CopyTo(smtp);
            Array.Sort(smtp, CompareRowidText);
            // Each key once, as the set of the queue holds it (a rowid is inserted once: nothing to drop in practice).
            int kept = 0;
            for (int i = 0; i < smtp.Length; i++) if (kept == 0 || smtp[i] != smtp[kept - 1]) smtp[kept++] = smtp[i];
            if (kept < smtp.Length) Array.Resize(ref smtp, kept);
        }

        static readonly Comparison<string> CompareUtf8 = Store.CompareUtf8Binary;
        static readonly Comparison<long> CompareRowidText = Store.CompareDecimalText;

        /// <summary>The same lines as DirtyQueueDump, from keys held in memory.</summary>
        static string RollupKeysDump(string[] messages, Dictionary<string, long?> hashes, long[] smtp)
        {
            var text = new System.Text.StringBuilder();
            foreach (var id in messages)
            {
                long? hash = hashes[id];
                text.Append("message|").Append(id).Append('|').Append(hash.HasValue ? hash.Value.ToString(System.Globalization.CultureInfo.InvariantCulture) : "NULL").Append('\n');
            }
            foreach (long id in smtp) text.Append("smtp|").Append(id.ToString(System.Globalization.CultureInfo.InvariantCulture)).Append("|NULL\n");
            return text.ToString();
        }

        void FlushRollupDirty()
        {
            var b = _batch;
            if (b == null || (b.DirtyMessages.Count == 0 && b.DirtySmtp.Count == 0)) return;
            var message = _writer.DirtyMessage;
            foreach (var kv in b.DirtyMessages) { message.Set(0, kv.Key); message.Set(1, kv.Value); message.Run(); }
            b.DirtyMessages.Clear();
            var smtp = _writer.DirtySmtp;
            for (int i = 0; i < b.DirtySmtp.Count; i++) { smtp.Set(0, b.DirtySmtp[i]); smtp.Run(); }
            b.DirtySmtp.Clear();
        }

        /// <summary>Content of message_rollup_dirty, one line per key (tests and diagnostics, see CollectorOptions.RollupQueueTrace).</summary>
        string DirtyQueueDump(SqliteTransaction tx)
        {
            var text = new System.Text.StringBuilder();
            using (var c = _store.Command("SELECT kind,identity,msg_hash FROM message_rollup_dirty ORDER BY kind,identity;", tx))
            using (var r = c.ExecuteReader())
                while (r.Read())
                    text.Append(r.GetString(0)).Append('|').Append(r.GetString(1)).Append('|').Append(r.IsDBNull(2) ? "NULL" : r.GetInt64(2).ToString(System.Globalization.CultureInfo.InvariantCulture)).Append('\n');
            return text.ToString();
        }

        /// <summary>
        /// Stores one part of the authentication evidence of a session and returns its id. The same part read again is ignored; a part
        /// that differs from the stored one marks the session conflicted (its transactions then show no user: never first or last).
        /// </summary>
        long StoreFragment(AuthFragment f, long fileId)
        {
            var ins = _writer.InsertFragment;
            ins.Set(0, fileId); ins.Set(1, f.SourceKey); ins.Set(2, f.FirstOffset); ins.Set(3, f.StoredPart); ins.Set(4, f.FirstMs); ins.Set(5, f.LastMs);
            ins.Set(6, f.Server); ins.Set(7, f.Direction); ins.Set(8, f.Role); ins.Set(9, f.Connector); ins.Set(10, f.SessionId); ins.Set(11, f.LocalEp);
            ins.Set(12, f.RemoteEp); ins.Set(13, f.Helo); ins.Set(14, f.FirstSeq >= 0 ? (object)f.FirstSeq : null); ins.Set(15, f.LastSeq >= 0 ? (object)f.LastSeq : null);
            ins.Set(16, f.CompleteStart ? 1L : 0L); ins.Set(17, f.CompleteEnd ? 1L : 0L); ins.Set(18, f.Coverage); ins.Set(19, f.ProxySid); ins.Set(20, f.ProxyIp);
            ins.Set(21, f.ProxyPort > 0 ? (object)f.ProxyPort : null); ins.Set(22, f.ProxyHelo); ins.Set(23, f.Observations); ins.Set(24, 0L);
            ins.Set(25, f.OriginMs); ins.Set(26, (long)f.Format); ins.Set(27, null);
            object id = ins.Scalar();
            _batch.Rows++;
            if (id != null) { _auth.Touch(f.Server, f.Direction, f.Role, f.SessionId); return (long)id; }
            long existing, lastMs;
            bool complete, conflicted;
            string coverage, observations, previousConflicts;
            using (var c = _store.Command(@"SELECT id, complete_end, last_ms, COALESCE(coverage,''), observations, conflicted, conflict_positions FROM smtp_auth_fragment
WHERE server=@srv AND direction=@d AND role=@role AND source_key=@k AND session_id=@sid AND first_offset=@off AND COALESCE(origin_first_ms,first_ms)=@origin AND COALESCE(evidence_format,1)=@fmt AND part=@part;", _batch.Tx))
            {
                c.Parameters.AddWithValue("@srv", f.Server); c.Parameters.AddWithValue("@d", f.Direction); c.Parameters.AddWithValue("@role", f.Role); c.Parameters.AddWithValue("@k", f.SourceKey);
                c.Parameters.AddWithValue("@sid", f.SessionId); c.Parameters.AddWithValue("@off", f.FirstOffset); c.Parameters.AddWithValue("@origin", f.OriginMs);
                c.Parameters.AddWithValue("@fmt", (long)f.Format); c.Parameters.AddWithValue("@part", f.StoredPart);
                using (var r = c.ExecuteReader())
                {
                    if (!r.Read()) throw new InvalidOperationException("SMTP authentication evidence was neither inserted nor found.");
                    existing = r.GetInt64(0); complete = r.GetInt64(1) != 0; lastMs = r.GetInt64(2); coverage = r.GetString(3); observations = Packed.Text(r.GetValue(4)); conflicted = r.GetInt64(5) != 0;
                    previousConflicts = r.IsDBNull(6) ? null : r.GetString(6);
                }
            }
            if (observations == f.Observations && coverage == (f.Coverage ?? "") && complete == f.CompleteEnd) return existing;
            // The same session read again by a later collection: the part grew (a session that was cut at the end of an active file) or it
            // is an older cut of what is stored. Neither is a conflict; only a different content at the same position is.
            if (!complete && f.LastMs >= lastMs && Extends(observations, f.Observations) && CoverageExtends(coverage, f.Coverage))
            {
                using (var c = _store.Command("UPDATE smtp_auth_fragment SET observations=@o, coverage=@c, last_ms=@m, last_sequence=@s, complete_end=@e, proxy_sid=COALESCE(@ps,proxy_sid), proxy_ip=COALESCE(@pi,proxy_ip), proxy_port=COALESCE(@pp,proxy_port), proxy_helo=COALESCE(@ph,proxy_helo) WHERE id=@id;", _batch.Tx))
                {
                    c.Parameters.AddWithValue("@o", f.Observations); c.Parameters.AddWithValue("@c", (object)f.Coverage ?? DBNull.Value); c.Parameters.AddWithValue("@m", f.LastMs);
                    c.Parameters.AddWithValue("@s", f.LastSeq >= 0 ? (object)f.LastSeq : DBNull.Value); c.Parameters.AddWithValue("@e", f.CompleteEnd ? 1L : 0L);
                    c.Parameters.AddWithValue("@ps", (object)f.ProxySid ?? DBNull.Value); c.Parameters.AddWithValue("@pi", (object)f.ProxyIp ?? DBNull.Value);
                    c.Parameters.AddWithValue("@pp", f.ProxyPort > 0 ? (object)f.ProxyPort : DBNull.Value); c.Parameters.AddWithValue("@ph", (object)f.ProxyHelo ?? DBNull.Value);
                    c.Parameters.AddWithValue("@id", existing);
                    c.ExecuteNonQuery();
                }
                _auth.Touch(f.Server, f.Direction, f.Role, f.SessionId);
                return existing;
            }
            if (Extends(f.Observations, observations) && CoverageExtends(f.Coverage, coverage)) return existing;
            string positions = ConflictingPositions(observations, f.Observations, f.Part);
            if (conflicted && previousConflicts == null) positions = null;
            else if (previousConflicts != null) positions = string.Join(",", previousConflicts.Split(',').Concat((positions ?? "").Split(',')).Where(x => x.Length > 0).Distinct().OrderBy(x => x, StringComparer.Ordinal));
            if (!conflicted || positions != previousConflicts)
            {
                using (var c = _store.Command("UPDATE smtp_auth_fragment SET conflicted=1, conflict_positions=@p WHERE id=@id;", _batch.Tx))
                {
                    c.Parameters.AddWithValue("@id", existing); c.Parameters.AddWithValue("@p", (object)positions ?? DBNull.Value); c.ExecuteNonQuery();
                }
                _auth.Touch(f.Server, f.Direction, f.Role, f.SessionId);
            }
            return existing;
        }

        /// <summary>The observations (JSON array) of a part begin with those of an earlier cut of the same part.</summary>
        static bool Extends(string older, string newer)
        {
            if (older == null || newer == null || older.Length < 2 || newer.Length < 2) return false;
            if (older == "[]") return true;
            string head = older.Substring(0, older.Length - 1);
            return newer.Length > head.Length && newer.StartsWith(head, StringComparison.Ordinal) && (newer[head.Length] == ',' || newer[head.Length] == ']');
        }

        static string ConflictingPositions(string older, string newer, long part)
        {
            var a = SmtpAuthStore.Read(older, 0, part);
            var b = SmtpAuthStore.Read(newer, 0, part);
            var positions = new HashSet<long>();
            foreach (var x in a)
                foreach (var y in b)
                    if (x.Pos == y.Pos && x.Sub == y.Sub && (x.K != y.K || x.Ms != y.Ms || x.A != y.A || x.B != y.B || x.Code != y.Code))
                        positions.Add(x.Pos);
            return positions.Count == 0 ? null : string.Join(",", positions.OrderBy(x => x));
        }

        /// <summary>The ranges of sequence numbers of a part contain those of an earlier cut of it, the last one being possibly longer.</summary>
        static bool CoverageExtends(string older, string newer)
        {
            var a = SmtpAuthStore.ReadCoverage(older);
            var b = SmtpAuthStore.ReadCoverage(newer);
            if (b.Count < a.Count) return false;
            for (int i = 0; i < a.Count; i++)
            {
                if (a[i][0] != b[i][0]) return false;
                if (i < a.Count - 1 ? a[i][1] != b[i][1] : b[i][1] < a[i][1]) return false;
            }
            return true;
        }

        const int SpoolSessionPage = 32, SpoolTxPage = 32, FragmentIdCache = 64;

        /// <summary>
        /// Writes what the parse stage spooled for an SMTP file: for each finished session, its evidence parts first (the transactions point at
        /// them), then its transactions, page by page. Only a page of sessions, of transactions and a few part ids are in memory.
        /// </summary>
        void ApplySmtp(ParsedFile p, ApplyFile f, FileResult r, string server, string role, string direction)
        {
            var spool = p.Spool;
            if (spool == null) return;
            long after = 0;
            var ids = new Dictionary<long, long>();
            while (true)
            {
                var sessions = spool.ReadSessions(after, SpoolSessionPage);
                foreach (var s in sessions)
                {
                    after = s.Ord;
                    AuthFragment head = null;
                    for (long part = 0; part < s.Parts; part++)
                    {
                        var evidence = spool.ReadPart(s.Id, part);
                        if (head == null) head = evidence;
                        StoreFragment(evidence, f.FileId);
                    }
                    ids.Clear();
                    int first = 0;
                    while (first < s.Txns)
                    {
                        var page = spool.ReadTx(s.Id, first, SpoolTxPage);
                        if (page.Count == 0) throw new InvalidOperationException("A transaction of the SMTP spool is missing.");
                        foreach (var kv in page)
                        {
                            var x = kv.Value;
                            long? fragment = null;
                            if (direction == "Receive" && x.Part >= 0)
                            {
                                if (head == null) throw new InvalidOperationException("A transaction of the SMTP spool points at evidence that was not spooled.");
                                long id;
                                if (!ids.TryGetValue(x.Part, out id))
                                {
                                    if (ids.Count >= FragmentIdCache) ids.Clear();
                                    id = FragmentId(s, head, x.Part);
                                    ids[x.Part] = id;
                                }
                                fragment = id;
                            }
                            var row = SmtpRow(server, role, direction, s, x, fragment);
                            var ins = _writer.InsertSmtp;
                            for (int i = 0; i < row.Length; i++) ins.Set(i, row[i]);
                            long? hash = x.MessageHash;   // Store.MessageHash(row[15]), computed by the parse thread
                            ins.Set(24, hash);
                            // SMTP client of the row: its account is not resolved yet (auth_user is written later by the resolver), so it starts in the group
                            // without account; the resolver moves it. NULL = no observed endpoint (and, with the triggers on, the trigger queues the row).
                            object client = null;
                            if (_clients != null) { long cm = Stopwatch.GetTimestamp(); client = _clients.Client(row[2], row[3], row[4], row[5], row[8], row[9], null, row[22]); Time(9, cm); }
                            ins.Set(25, client);
                            if (ins.Run() > 0)
                            {
                                r.Stored++;
                                NoteRollup(row[15] as string, hash, ins, true);
                                if (_clients != null)
                                {
                                    long cm = Stopwatch.GetTimestamp();
                                    _clients.Inserted(ins.LastRowId, Convert.ToInt64(row[0], System.Globalization.CultureInfo.InvariantCulture), client, row[17], row[13], row[10], null, row[23], null, row[22], fragment.HasValue);
                                    Time(9, cm);
                                }
                                if (fragment.HasValue) _auth.Touch(server, direction, role ?? "", s.SessionId);
                            }
                            _batch.Rows++;
                        }
                        first = page[page.Count - 1].Key + 1;
                    }
                    if (_auth.Count >= AuthResolver.Limit) FlushAuth();
                }
                if (sessions.Count < SpoolSessionPage) break;
            }
        }

        /// <summary>Id of the evidence part of a session in the database (it was stored before the transactions that point at it).</summary>
        long FragmentId(SmtpSpoolSession s, AuthFragment head, long part)
        {
            var q = _writer.LookupFragment;
            q.Set(0, head.Server); q.Set(1, head.Direction); q.Set(2, head.Role); q.Set(3, head.SourceKey); q.Set(4, s.SessionId); q.Set(5, head.FirstOffset);
            q.Set(6, head.OriginMs); q.Set(7, (long)head.Format); q.Set(8, -1L - part);
            object id = q.Scalar();
            if (id == null) throw new InvalidOperationException("SMTP authentication evidence of a transaction was not stored.");
            return (long)id;
        }

        void Apply(ParsedFile p, CollectionRun run)
        {
            var watch = Stopwatch.StartNew();
            Exception failure = null;
            try { ApplyFileRecords(p, run); }
            catch (Exception ex) { failure = ex; throw; }
            finally
            {
                p.ApplySeconds = watch.Elapsed.TotalSeconds;
                // The work file of the file is deleted now; when the apply already failed, its failure is the one that is reported.
                try { p.Dispose(); }
                catch (Exception) when (failure != null) { }
            }
        }

        void ApplyFileRecords(ParsedFile p, CollectionRun run)
        {
            var w = p.Work;
            var job = w.Job;
            var r = p.Result;
            if (r.Error != null || r.Unchanged)
            {
                lock (run.Lock)
                {
                    if (r.Error != null) { job.Errors++; run.ErrorCount++; run.LogLines.Add("WARN|" + job.Server + " " + w.Path + ": " + r.Error); }
                    run.FilesDone++;
                    job.FilesApplied++;
                    run.BytesDone += Math.Max(0, w.Length - w.State.Offset);
                }
                _batch.Files.Add(p);
                return;
            }
            var c = (ParseContext)p.Context;
            var state = w.State.CopyFor(w.State.Path);
            _batch.PendingFiles[w.State] = state;
            long mark = Stopwatch.GetTimestamp();
            var f = new ApplyFile { Server = job.Server, Role = job.Role, Kind = job.Kind, Path = w.Path, Result = r };
            f.FileId = _store.FileId(state, _batch.Tx);
            int slot = 2, detail = -1;   // detail: the part of rows (SMTP or message tracking) the time also goes to
            switch (job.Kind)
            {
                case "HttpProxy":
                case "Iis":
                    slot = 0;
                    foreach (var a in c.Access) HandleAccess(f, a);
                    MergeAggregates(c);
                    foreach (var row in c.IisStatus)
                    {
                        var ins = _writer.InsertIis;
                        for (int i = 0; i < row.Length; i++) ins.Set(i, row[i]);
                        if (ins.Run() > 0) r.Stored++;
                        _batch.Rows++;
                    }
                    break;
                case "MapiBackEnd": slot = 1; foreach (var b in c.BackEnd) ApplyMapiBackEnd(f, b); break;
                case "EasBackEnd": slot = 1; foreach (var b in c.BackEnd) ApplyEasBackEnd(f, b); break;
                case "Imap4":
                case "Pop3": slot = 1; foreach (var x in c.PopImap) EmitPopImap(f, x, job.Kind, c.PopImapBackEnd); break;
                case "SmtpReceive":
                case "SmtpSend":
                    detail = 10;
                    ApplySmtp(p, f, r, job.Server, job.Role, job.Kind == "SmtpReceive" ? "Receive" : "Send");
                    break;
                case "Tracking":
                    detail = 11;
                    foreach (var row in c.Messages)
                    {
                        // The row carries its msg_hash (column 25, Store.MessageHash of column 4, computed by the parse thread).
                        var ins = _writer.InsertMessage;
                        for (int i = 0; i < row.Length; i++) ins.Set(i, row[i]);
                        if (ins.Run() > 0) { r.Stored++; NoteRollup(row[4] as string, row[25] as long?, ins, false); }
                        _batch.Rows++;
                    }
                    break;
            }
            Time(slot, detail, mark);
            mark = Stopwatch.GetTimestamp();
            state.Offset = p.NewOffset;
            state.Fields = p.Fields;
            state.Size = w.Length;
            state.LastWriteMs = new DateTimeOffset(w.LastWriteUtc).ToUnixTimeMilliseconds();
            state.Lines += r.Lines; state.Kept += r.Kept; state.Noise += r.Noise;
            if (r.FirstMs > 0 && (state.FirstMs == 0 || r.FirstMs < state.FirstMs)) state.FirstMs = r.FirstMs;
            if (r.LastMs > state.LastMs) state.LastMs = r.LastMs;
            var save = _writer.SaveFile;
            save.Set(0, state.Id); save.Set(1, state.Offset); save.Set(2, state.Size); save.Set(3, state.LastWriteMs); save.Set(4, FieldsId(state.Fields));
            save.Set(5, state.FirstMs > 0 ? (object)state.FirstMs : null); save.Set(6, state.LastMs > 0 ? (object)state.LastMs : null);
            save.Set(7, state.Lines); save.Set(8, state.Kept); save.Set(9, state.Noise); save.Set(10, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            save.Run();
            foreach (var kv in r.NoiseReasons)
            {
                string key = job.Server + "\u0001" + job.Kind + "\u0001" + kv.Key;
                long n; _batch.Noise.TryGetValue(key, out n); _batch.Noise[key] = n + kv.Value;
            }
            _batch.Rows++;
            _batch.Files.Add(p);
            p.Context = null;
            // Every record was applied and nothing keeps the lists: the next files fill them again.
            _lists.Return(c);
            Time(7, mark);
            // A file can hold many identities: write them when the queue gets large instead of keeping a whole batch in memory.
            if (_batch.DirtyMessages.Count + _batch.DirtySmtp.Count >= FlushRollupKeys) { mark = Stopwatch.GetTimestamp(); FlushRollupDirty(); Time(8, mark); }
            lock (run.Lock)
            {
                run.FilesDone++;
                run.BytesDone += Math.Max(0, w.Length - p.StartOffset);
                run.LinesDone += r.Lines;
                run.KeptDone += r.Kept;
                job.FilesApplied++;
                if (r.Reset) { job.Resets++; run.LogLines.Add("WARN|" + w.Path + " was shorter than the position already read: read again from the beginning."); }
            }
        }

        /// <summary>Dictionary id of a '#Fields' header text (the row is created by the first file that has the text); null for no header.</summary>
        object FieldsId(string text)
        {
            if (text == null) return null;
            var find = _writer.LookupFields;
            find.Set(0, text);
            object id = find.Scalar();
            if (id != null) return id;
            var add = _writer.InsertFields;
            add.Set(0, text);
            return add.Scalar();
        }

        void CommitBatch(CollectionRun run)
        {
            if (_batch == null) return;
            long mark = Stopwatch.GetTimestamp();
            FlushUsage();
            FlushActions();
            FlushClients();
            Time(4, mark); mark = Stopwatch.GetTimestamp();
            FlushSessions(_batch.Tx, _batch.Touched);
            Time(3, mark); mark = Stopwatch.GetTimestamp();
            FlushAuth();
            var noise = _writer.Noise;
            foreach (var kv in _batch.Noise)
            {
                var parts = kv.Key.Split('\u0001');
                noise.Set(0, _o.RunId); noise.Set(1, parts[0]); noise.Set(2, parts[1]); noise.Set(3, parts[2]); noise.Set(4, kv.Value);
                noise.Run();
            }
            Time(5, mark); mark = Stopwatch.GetTimestamp();
            // After the resolver (it moves transactions between clients): the buckets of the batch, then any work queued by the triggers.
            if (_clients != null) { _clients.Flush(); Time(9, mark); }
            long clientMark = Stopwatch.GetTimestamp();
            _store.ReconcileSmtpClients(_batch.Tx);
            Time(9, clientMark);
            mark = Stopwatch.GetTimestamp();
            if (_rollupInCode && !_deferRollups && !RollupQueueHasRows(_batch.Tx))
            {
                // Nothing queued (no mid-batch flush, no leftover): the keys of the batch go straight to the reconciliation, in the order the queue would be read.
                string[] messages; long[] smtp;
                SortedRollupKeys(_batch, out messages, out smtp);
                if (_o.RollupQueueTrace != null) { var dump = RollupKeysDump(messages, _batch.DirtyMessages, smtp); lock (_o.RollupQueueTrace) _o.RollupQueueTrace.Add(dump); }
                _store.ReconcileMessageRollupKeys(_batch.Tx, messages, _batch.DirtyMessages, smtp); run.RollupKeys += _store.LastReconciledKeys;
            }
            else
            {
                FlushRollupDirty();
                if (_o.RollupQueueTrace != null) { var dump = DirtyQueueDump(_batch.Tx); lock (_o.RollupQueueTrace) _o.RollupQueueTrace.Add(dump); }
                // Deferred rollups stay queued (durably, with the batch) until the drain after the last batch.
                if (!_deferRollups) { _store.ReconcileMessageRollups(_batch.Tx); run.RollupKeys += _store.LastReconciledKeys; }
            }
            Time(8, mark); mark = Stopwatch.GetTimestamp();
            _batch.Tx.Commit();
            _batch.Tx.Dispose();
            foreach (var pair in _batch.PendingFiles)
            {
                var state = pair.Key; var saved = pair.Value;
                state.Id = saved.Id; state.Offset = saved.Offset; state.Size = saved.Size; state.Fields = saved.Fields;
                state.LastWriteMs = saved.LastWriteMs; state.FirstMs = saved.FirstMs; state.LastMs = saved.LastMs;
                state.Lines = saved.Lines; state.Kept = saved.Kept; state.Noise = saved.Noise;
            }
            Time(5, mark);
            run.Batches++;
            var committed = _batch;
            var files = committed.Files;
            _batch = null;
            _tx = null;
            lock (run.Lock)
            {
                foreach (var p in files)
                {
                    var job = p.Work.Job;
                    var r = p.Result;
                    if (r.Error == null && !r.Unchanged)
                    {
                        job.FilesRead++; job.Bytes += r.BytesRead; job.Lines += r.Lines; job.Kept += r.Kept; job.Noise += r.Noise; job.Stored += r.Stored;
                        foreach (var kv in r.NoiseReasons) { long n; job.NoiseReasons.TryGetValue(kv.Key, out n); job.NoiseReasons[kv.Key] = n + kv.Value; }
                    }
                    job.WorkSeconds += r.Seconds + p.ApplySeconds;
                    if (job.FirstStart < 0 || p.Started < job.FirstStart) job.FirstStart = p.Started;
                    if (p.Ended > job.LastEnd) job.LastEnd = p.Ended;
                    if (!job.Done && job.FilesApplied >= job.Files.Count) { job.Done = true; run.FinishedJobs.Add(job); }
                }
            }
            EvictSessions(files);
            // Nothing refers to the committed batch any more: emptied now (its files and sessions are not kept alive), used again by the next one.
            committed.Clear();
            _spareBatch = committed;
            // Between two transactions: the only moment the WAL can be emptied.
            RestartWalIfLarge(run);
        }
    }
}
