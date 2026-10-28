// =============================================================================
//  Exchange Log Report - budgeted report rows and per-dataset scratch tables
//  Author: Nicolas Fabert
// =============================================================================
using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    internal sealed class TranscriptRef
    {
        public readonly long Id;
        public TranscriptRef(long id) { Id = id; }
    }

    internal sealed class StoredReportRow
    {
        public object[] Values;
        public long Sort, Group;
        public int Ordinal, Priority;
    }

    internal sealed class ExactMessageCounts : IDisposable
    {
        readonly ReportScratch _scratch;
        readonly string _server;
        readonly SqliteCommand _addServer;
        // Server names compare case-insensitively and keep the first spelling; identities stay exact (ordinal) strings.
        readonly Dictionary<string, int> _ids = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        readonly List<string> _names = new List<string>();
        readonly Dictionary<int, HashSet<string>> _current = new Dictionary<int, HashSet<string>>();
        readonly List<long[]> _hours = new List<long[]>();
        long _hour = long.MinValue;

        public ExactMessageCounts(ReportScratch scratch)
        {
            _scratch = scratch;
            _server = "message_server_" + scratch.NewId().ToString(System.Globalization.CultureInfo.InvariantCulture);
            // The server is an integer id, so the primary key needs no managed collation callback.
            using (var c = scratch.Command("CREATE TABLE " + _server +
                "(server_id INTEGER, identity TEXT COLLATE BINARY, PRIMARY KEY(server_id,identity)) WITHOUT ROWID;"))
                c.ExecuteNonQuery();
            _addServer = scratch.Own(scratch.Command("INSERT OR IGNORE INTO " + _server + " VALUES(@s,@i);"));
            _addServer.Parameters.Add("@s", SqliteType.Integer); _addServer.Parameters.Add("@i", SqliteType.Text);
            _addServer.Prepare();
        }

        // Rows arrive in time order: only the current hour is held in memory, then its distinct identities are flushed.
        public void Add(string server, long hour, string identity)
        {
            if (hour != _hour)
            {
                if (hour < _hour) throw new InvalidDataException("Message events must be read in time order.");
                Flush();
                _hour = hour;
            }
            int id;
            if (!_ids.TryGetValue(server, out id)) { id = _names.Count; _ids[server] = id; _names.Add(server); }
            HashSet<string> set;
            if (!_current.TryGetValue(id, out set)) _current[id] = set = new HashSet<string>(StringComparer.Ordinal);
            set.Add(identity);
        }

        void Flush()
        {
            foreach (var kv in _current)
            {
                if (kv.Value.Count == 0) continue;
                _hours.Add(new[] { kv.Key, _hour, kv.Value.Count });
                // Sorted identities keep the scratch index inserts local.
                var sorted = new string[kv.Value.Count];
                kv.Value.CopyTo(sorted);
                Array.Sort(sorted, StringComparer.Ordinal);
                _addServer.Parameters["@s"].Value = kv.Key;
                foreach (var identity in sorted)
                {
                    _addServer.Parameters["@i"].Value = identity;
                    _addServer.ExecuteNonQuery();
                }
                kv.Value.Clear();
            }
        }

        public void Read(Action<string, long> server, Action<string, long, long> hour)
        {
            Flush();
            _hour = long.MaxValue;
            var totals = new Dictionary<int, long>();
            using (var c = _scratch.Command("SELECT server_id,COUNT(*) FROM " + _server + " GROUP BY server_id;"))
            using (var r = c.ExecuteReader()) while (r.Read()) totals[r.GetInt32(0)] = r.GetInt64(1);
            foreach (var id in totals.Keys.OrderBy(x => _names[x], StringComparer.OrdinalIgnoreCase)) server(_names[id], totals[id]);
            foreach (var h in _hours.OrderBy(x => _names[(int)x[0]], StringComparer.OrdinalIgnoreCase).ThenBy(x => x[1])) hour(_names[(int)h[0]], h[1], h[2]);
        }

        public void Dispose()
        {
            _addServer.Dispose();
            _scratch.Forget(_addServer);
            using (var c = _scratch.Command("DROP TABLE " + _server + ";")) c.ExecuteNonQuery();
        }
    }

    internal sealed class ReportScratch : IDisposable
    {
        sealed class DiskTable
        {
            public string Name;
            public SqliteCommand Insert;
            public bool Indexed;
        }

        readonly string _path;
        SqliteConnection _db;
        SqliteTransaction _transaction;
        int _nextDataset;
        readonly Dictionary<int, DiskTable> _tables = new Dictionary<int, DiskTable>();
        readonly List<ReportRows> _datasets = new List<ReportRows>();
        readonly List<SqliteCommand> _auxiliary = new List<SqliteCommand>();
        readonly long _retainedLimit;
        readonly int _cacheKb;
        long _retained, _working;
        public long PeakBufferBytes { get; private set; }
        public long SpilledRows { get; private set; }
        public long StagedRows { get; private set; }
        public long PeakFileBytes { get; private set; }
        public readonly List<Exception> WorkerFailures = new List<Exception>();

        public ReportScratch(string folder, long budgetBytes)
        {
            _path = Path.Combine(folder, ".report-" + Guid.NewGuid().ToString("N") + ".tmp");
            _retainedLimit = budgetBytes / 2 - 8L * 1048576;
            // Same share of the budget as the report database cache (budget / 4, at most 256 MB); 8 MB when no budget is given.
            _cacheKb = (int)Math.Max(8192L, Math.Min(256L * 1024, budgetBytes / 4096));
        }

        public int Register(ReportRows rows) { _datasets.Add(rows); return ++_nextDataset; }
        public void Unregister(ReportRows rows) { _datasets.Remove(rows); }
        internal SqliteCommand Own(SqliteCommand command) { _auxiliary.Add(command); return command; }
        internal void Forget(SqliteCommand command) { _auxiliary.Remove(command); }

        public bool Retain(long bytes, ReportRows owner)
        {
            while (_retained + bytes > _retainedLimit)
            {
                var largest = _datasets.Where(x => x.MemoryBytes > 0).OrderByDescending(x => x.MemoryBytes).FirstOrDefault();
                if (largest == null) { owner.Spill(); return false; }
                largest.Spill();
                if (owner.OnDisk) return false;
            }
            _retained += bytes;
            Track();
            return true;
        }

        public void Release(long bytes) { _retained -= bytes; }
        public void Working(long bytes) { _working = bytes; Track(); }
        void Track() { PeakBufferBytes = Math.Max(PeakBufferBytes, _retained + _working); }

        void Open()
        {
            if (_db != null) return;
            _db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = _path, Pooling = false }.ToString());
            _db.Open();
            _db.CreateCollation("EXL_REPORT_ID", (x, y) => StringComparer.OrdinalIgnoreCase.Compare(x, y));
            using (var c = _db.CreateCommand())
            {
                c.CommandText = "PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=FILE; PRAGMA cache_size=-" + _cacheKb.ToString(System.Globalization.CultureInfo.InvariantCulture) + ";";
                c.ExecuteNonQuery();
            }
            _transaction = _db.BeginTransaction();
        }

        internal SqliteCommand Command(string sql)
        {
            Open();
            var c = _db.CreateCommand();
            c.Transaction = _transaction;
            c.CommandTimeout = 0;
            c.CommandText = sql;
            return c;
        }

        internal int NewId() { return ++_nextDataset; }

        DiskTable Table(int dataset)
        {
            DiskTable table;
            if (_tables.TryGetValue(dataset, out table)) return table;
            string name = "d" + dataset;
            using (var c = Command("CREATE TABLE " + name + "(ordinal INTEGER PRIMARY KEY, sort_key INTEGER, group_id INTEGER, priority INTEGER, data BLOB);"))
                c.ExecuteNonQuery();
            table = new DiskTable { Name = name, Insert = Command("INSERT INTO " + name + " VALUES(@n,@s,@g,@p,@v);") };
            foreach (var n in new[] { "@n", "@s", "@g", "@p" }) table.Insert.Parameters.Add(n, SqliteType.Integer);
            table.Insert.Parameters.Add("@v", SqliteType.Blob);
            table.Insert.Prepare();
            _tables[dataset] = table;
            return table;
        }

        public void Add(int dataset, StoredReportRow row, bool staged)
        {
            var table = Table(dataset);
            using (var ms = new MemoryStream())
            {
                using (var w = new BinaryWriter(ms, Encoding.UTF8, true)) Write(w, row.Values);
                table.Insert.Parameters["@n"].Value = row.Ordinal;
                table.Insert.Parameters["@s"].Value = row.Sort;
                table.Insert.Parameters["@g"].Value = row.Group;
                table.Insert.Parameters["@p"].Value = row.Priority;
                table.Insert.Parameters["@v"].Value = ms.ToArray();
                table.Insert.ExecuteNonQuery();
                table.Insert.Parameters["@v"].Value = DBNull.Value;
                if (staged) StagedRows++; else SpilledRows++;
            }
        }

        void Index(int dataset)
        {
            var table = Table(dataset);
            if (table.Indexed) return;
            using (var c = Command("CREATE INDEX g" + dataset + " ON " + table.Name + "(group_id,priority,sort_key,ordinal);"))
                c.ExecuteNonQuery();
            table.Indexed = true;
        }

        public int Sort(int dataset)
        {
            var old = Table(dataset);
            int sorted = NewId();
            var next = Table(sorted);
            // The destination is a different table: no self-insert copy or window function.
            using (var c = Command("INSERT INTO " + next.Name + "(sort_key,group_id,priority,data) SELECT sort_key,group_id,priority,data FROM " +
                old.Name + " ORDER BY sort_key,ordinal;"))
                c.ExecuteNonQuery();
            Drop(dataset);
            return sorted;
        }

        public IEnumerable<StoredReportRow> Read(int dataset, long? group = null, int? priority = null, int limit = int.MaxValue, bool reverse = false)
        {
            DiskTable table;
            if (!_tables.TryGetValue(dataset, out table)) yield break;
            if (group.HasValue) Index(dataset);
            string direction = reverse ? " DESC" : "";
            using (var c = Command("SELECT ordinal,sort_key,group_id,priority,data FROM " + table.Name +
                (group.HasValue ? " WHERE group_id=@g" : "") + (priority.HasValue ? " AND priority=@p" : "") +
                " ORDER BY " + (group.HasValue ? "sort_key" + direction + "," : "") + "ordinal" + direction + " LIMIT @limit;"))
            {
                if (group.HasValue) c.Parameters.AddWithValue("@g", group.Value);
                if (priority.HasValue) c.Parameters.AddWithValue("@p", priority.Value);
                c.Parameters.AddWithValue("@limit", limit);
                using (var r = c.ExecuteReader())
                    while (r.Read())
                        using (var ms = new MemoryStream((byte[])r.GetValue(4), false))
                        using (var reader = new BinaryReader(ms, Encoding.UTF8))
                            yield return new StoredReportRow { Ordinal = r.GetInt32(0), Sort = r.GetInt64(1), Group = r.GetInt64(2),
                                Priority = r.GetInt32(3), Values = (object[])ReadValue(reader) };
            }
        }

        public void Drop(int dataset)
        {
            DiskTable table;
            if (!_tables.TryGetValue(dataset, out table)) return;
            table.Insert.Dispose();
            using (var c = Command("DROP TABLE " + table.Name + ";")) c.ExecuteNonQuery();
            _tables.Remove(dataset);
            PeakFileBytes = Math.Max(PeakFileBytes, new FileInfo(_path).Length);
        }

        static void Write(BinaryWriter w, object value)
        {
            if (value == null || value is DBNull) { w.Write((byte)0); return; }
            if (value is string) { w.Write((byte)1); w.Write((string)value); return; }
            if (value is long) { w.Write((byte)2); w.Write((long)value); return; }
            if (value is int) { w.Write((byte)3); w.Write((int)value); return; }
            if (value is double) { w.Write((byte)4); w.Write((double)value); return; }
            if (value is bool) { w.Write((byte)5); w.Write((bool)value); return; }
            var strings = value as string[];
            if (strings != null) { w.Write((byte)6); w.Write(strings.Length); foreach (var s in strings) Write(w, s); return; }
            var array = value as object[];
            if (array != null) { w.Write((byte)7); w.Write(array.Length); foreach (var x in array) Write(w, x); return; }
            var rows = value as IEnumerable<object[]>;
            if (rows != null)
            {
                var list = rows as List<object[]> ?? rows.ToList();
                w.Write((byte)8); w.Write(list.Count); foreach (var row in list) Write(w, row);
                return;
            }
            var reference = value as TranscriptRef;
            if (reference != null) { w.Write((byte)9); w.Write(reference.Id); return; }
            throw new InvalidDataException("Unsupported report value: " + value.GetType().FullName);
        }

        static object ReadValue(BinaryReader r)
        {
            switch (r.ReadByte())
            {
                case 0: return null;
                case 1: return r.ReadString();
                case 2: return r.ReadInt64();
                case 3: return r.ReadInt32();
                case 4: return r.ReadDouble();
                case 5: return r.ReadBoolean();
                case 6:
                    var strings = new string[r.ReadInt32()];
                    for (int i = 0; i < strings.Length; i++) strings[i] = (string)ReadValue(r);
                    return strings;
                case 7:
                    var array = new object[r.ReadInt32()];
                    for (int i = 0; i < array.Length; i++) array[i] = ReadValue(r);
                    return array;
                case 8:
                    int count = r.ReadInt32();
                    var rows = new List<object[]>(count);
                    for (int i = 0; i < count; i++) rows.Add((object[])ReadValue(r));
                    return rows;
                case 9: return new TranscriptRef(r.ReadInt64());
                default: throw new InvalidDataException("Invalid temporary report value.");
            }
        }

        public void Dispose()
        {
            var errors = new ReportErrors();
            if (File.Exists(_path)) errors.Run(() => PeakFileBytes = Math.Max(PeakFileBytes, new FileInfo(_path).Length));
            foreach (var table in _tables.Values) errors.Run(table.Insert.Dispose);
            foreach (var command in _auxiliary) errors.Run(command.Dispose);
            if (_transaction != null) errors.Run(_transaction.Dispose);
            if (_db != null) errors.Run(_db.Dispose);
            if (File.Exists(_path))
            {
                PeakFileBytes = Math.Max(PeakFileBytes, new FileInfo(_path).Length);
                errors.Run(() => File.Delete(_path));
            }
            _datasets.Clear();
            errors.ThrowIfAny();
        }
    }

    public sealed class ReportRows : IEnumerable<object[]>, IDisposable
    {
        readonly List<StoredReportRow> _memory = new List<StoredReportRow>();
        readonly ReportScratch _scratch;
        int _dataset;
        readonly Func<IEnumerable<object[]>> _source;
        readonly bool _staged;
        bool _sorted, _discarded;
        Dictionary<long, List<StoredReportRow>> _groups;
        long _groupBytes;
        internal bool OnDisk { get; private set; }
        internal long MemoryBytes { get; private set; }
        public int Count { get; private set; }

        public ReportRows() { }
        internal ReportRows(ReportScratch scratch, bool staged = false)
        {
            _scratch = scratch; _dataset = scratch.Register(this);
            _staged = staged; OnDisk = staged;
        }
        internal ReportRows(Func<IEnumerable<object[]>> source, int count) { _source = source; Count = count; }
        public void Add(object[] row) { Add(row, 0, 0); }

        internal void Add(object[] row, long utcMs, long group, int priority = 0)
        {
            EnsureActive();
            ForgetGroups();
            var entry = new StoredReportRow { Values = row, Sort = utcMs, Group = group, Priority = priority, Ordinal = Count };
            long bytes = ReportMemory.Bytes(row) + 96;
            if (_scratch == null || (!OnDisk && _scratch.Retain(bytes, this))) { _memory.Add(entry); MemoryBytes += bytes; }
            else _scratch.Add(_dataset, entry, _staged);
            Count++;
        }

        public object[] this[int index]
        {
            get { EnsureActive(); if (OnDisk || _source != null) throw new InvalidOperationException("Indexed access requires in-memory report rows."); return _memory[index].Values; }
            set
            {
                EnsureActive();
                if (_scratch != null || _source != null) throw new InvalidOperationException("Budgeted report rows cannot be mutated by index.");
                _memory[index].Values = value;
            }
        }

        void EnsureActive() { if (_discarded) throw new ObjectDisposedException("ReportRows"); }
        void ForgetGroups()
        {
            if (_groupBytes > 0) { _scratch.Release(_groupBytes); MemoryBytes -= _groupBytes; }
            _groups = null; _groupBytes = 0;
        }

        internal void Spill()
        {
            EnsureActive();
            if (OnDisk) return;
            OnDisk = true;
            int ordinal = 0;
            foreach (var entry in _memory)
            {
                if (_sorted) entry.Ordinal = ordinal++;
                _scratch.Add(_dataset, entry, _staged);
            }
            _sorted = false;
            _scratch.Release(MemoryBytes);
            MemoryBytes = 0; _groupBytes = 0; _groups = null;
            _memory.Clear(); _memory.TrimExcess();
        }

        internal void SortByTime()
        {
            EnsureActive();
            if (OnDisk) { _dataset = _scratch.Sort(_dataset); return; }
            _memory.Sort((a, b) => a.Sort != b.Sort ? a.Sort.CompareTo(b.Sort) : a.Ordinal.CompareTo(b.Ordinal));
            _sorted = true;
        }

        internal List<object[]> ReadGroup(long group)
        {
            EnsureActive();
            if (OnDisk) return _scratch.Read(_dataset, group, 0).Select(x => x.Values).ToList();
            return _memory.Where(x => x.Group == group).OrderBy(x => x.Sort).ThenBy(x => x.Ordinal).Select(x => x.Values).ToList();
        }

        internal List<object[]> Sample(long group, long count)
        {
            EnsureActive();
            if (!OnDisk && _groups == null)
            {
                long bytes = Count * 136L;
                if (_scratch.Retain(bytes, this))
                {
                    MemoryBytes += bytes; _groupBytes = bytes;
                    _groups = _memory.GroupBy(x => x.Group).ToDictionary(x => x.Key, x => x.ToList());
                }
            }
            IEnumerable<StoredReportRow> kept;
            if (!OnDisk)
            {
                List<StoredReportRow> rows;
                if (!_groups.TryGetValue(group, out rows)) throw new InvalidDataException("Missing SMTP sample group.");
                var latest = rows.OrderByDescending(x => x.Sort).ThenByDescending(x => x.Ordinal);
                var failed = latest.Where(x => x.Priority == 0).Take(150).ToList();
                kept = count <= 200 ? rows : failed.Concat(latest.Where(x => x.Priority == 1).Take(200 - failed.Count));
            }
            else
            {
                var failed = count > 200 ? _scratch.Read(_dataset, group, 0, 150, true).ToList() : null;
                kept = count <= 200 ? _scratch.Read(_dataset, group, limit: (int)count) :
                    failed.Concat(_scratch.Read(_dataset, group, 1, 200 - failed.Count, true));
            }
            return kept.OrderBy(x => x.Sort).ThenBy(x => x.Ordinal).Select(x => (object[])x.Values.Clone()).ToList();
        }

        public IEnumerator<object[]> GetEnumerator()
        {
            EnsureActive();
            return (_source != null ? SourceRows() : OnDisk ? _scratch.Read(_dataset).Select(x => x.Values) : _memory.Select(x => x.Values)).GetEnumerator();
        }
        IEnumerable<object[]> SourceRows()
        {
            int count = 0;
            foreach (var row in _source()) { count++; yield return row; }
            Count = count;
        }
        IEnumerator IEnumerable.GetEnumerator() { return GetEnumerator(); }

        public void Dispose()
        {
            if (_discarded) return;
            _discarded = true;
            if (_scratch != null)
            {
                _scratch.Release(MemoryBytes); _scratch.Unregister(this);
                if (OnDisk) _scratch.Drop(_dataset);
            }
            MemoryBytes = 0; _groupBytes = 0; _groups = null;
            _memory.Clear(); _memory.TrimExcess();
        }
    }
}
