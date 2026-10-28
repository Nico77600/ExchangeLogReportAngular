using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    internal sealed partial class ServeRead
    {
        const string Account = "CASE WHEN e.auth_source='Overflow' THEN NULL ELSE e.auth_user END";
        static string RemoteHost(string endpoint) { return Identity.RemoteHost(endpoint); }

        internal static readonly ServeColumn[] SmtpClientColumns = ServeColumn.Parse(new[] {
            "First seen:time","Last seen:time","Server:text","Direction:text","Role:text","Connector:text","Remote IP:text","HELO:text",
            "Authenticated user:text","Transactions:num","Accepted:num","Rejected:num","Deferred:num","Not completed:num","Recipients:num",
            "TLS:list","Authentication mechanisms:list","Authentication results:list","AUTH attempt outcomes:list","Identity evidence:list",
            "Transactions without authenticated user:num"
        });

        // =================================================================================================================================
        // SMTP clients (schema 11). A client is (server NOCASE, direction, role, connector, peer, HELO, account); the transactions without an
        // observed endpoint are clients of one transaction each. The groups of a selection are read from three sources that never overlap:
        //   - smtp_client_hour for the whole UTC hours inside the period (no user filter: a substring LIKE needs the rows);
        //   - the transaction rows of the partial hours at both ends (and of the whole period when the user filter or a short period forbids hours);
        //   - the transactions without client (ix_smtp_unknown_peer), which are never aggregated.
        // The result is exactly the grouping of the transactions of the selection (same ids = MIN(id) of the group in the selection, same
        // counters, same sorted sets, same order), see Engine.SmtpClients.cs for how the structures are kept exact.
        // =================================================================================================================================

        /// <summary>Set of value codes: a 64-bit mask for codes 0..63, a HashSet beyond or below (any dictionary size stays exact).</summary>
        struct CodeSet
        {
            ulong _bits; HashSet<long> _extra;
            public void Add(long code) { if (code >= 0 && code < 64) _bits |= 1UL << (int)code; else (_extra ?? (_extra = new HashSet<long>())).Add(code); }
            public void AddMask(long mask) { for (int i = 0; i < 63; i++) if ((mask & (1L << i)) != 0) _bits |= 1UL << i; }
            public IEnumerable<long> All
            {
                get
                {
                    for (int i = 0; i < 64; i++) if ((_bits & (1UL << i)) != 0) yield return i;
                    if (_extra != null) foreach (long c in _extra) yield return c;
                }
            }
        }

        sealed class ClientAcc
        {
            public long Client;      // > 0: smtp_client id; < 0: -(transaction id) of a transaction without observed endpoint
            public long N, Accepted, Rejected, Deferred, Other, Rcpts, MinId = long.MaxValue, MinMs = long.MaxValue, MaxMs = long.MinValue;
            public CodeSet Tls, Mech, Res, Att, Src;
        }

        /// <summary>The value dictionary of the SMTP aggregates. A text that is not in it (a row the dictionary does not know) gets a request-local negative code, so a read never fails on it.</summary>
        sealed class ClientValues
        {
            public readonly Dictionary<long, string> Text = new Dictionary<long, string>();
            public readonly Dictionary<string, long> Code = new Dictionary<string, long>(StringComparer.Ordinal);
            readonly List<string> _local = new List<string>();
            public long Max;
            public long Of(object text)
            {
                if (text == null || text is DBNull) return 0;
                string value = text as string ?? Convert.ToString(text, CultureInfo.InvariantCulture);
                long code;
                if (Code.TryGetValue(value, out code)) return code;
                int at = _local.IndexOf(value);
                if (at < 0) { _local.Add(value); at = _local.Count - 1; }
                return -(at + 1L);
            }
            public string Decode(long code)
            {
                if (code == 0) return null;
                if (code < 0) return _local[(int)(-code - 1)];
                string value;
                if (!Text.TryGetValue(code, out value)) throw new System.IO.InvalidDataException("InvalidSmtpClients: smtp_client_hour uses a value code that is not in smtp_client_value.");
                return value;
            }
        }

        ClientValues _clientValues;
        ClientValues Values()
        {
            if (_clientValues != null) return _clientValues;
            var d = new ClientValues();
            using (var c = Command("SELECT id,text FROM smtp_client_value;"))
            using (var r = c.ExecuteReader())
                while (r.Read()) { long id = r.GetInt64(0); string text = r.GetString(1); d.Text[id] = text; d.Code[text] = id; if (id > d.Max) d.Max = id; }
            return _clientValues = d;
        }

        // The display values of a transaction as ClientSelection computed them (the same expressions as the collector's buckets).
        const string ClientRawCols = "e.id,e.time_ms,e.client_id,e.status,COALESCE(e.rcpt_count,0),e.tls," +
            "CASE WHEN e.auth_source='Overflow' THEN 'Not available' WHEN e.auth_mechanism IS NOT NULL THEN e.auth_mechanism WHEN e.auth_source='NotApplicable' THEN 'None' ELSE 'Not available' END," +
            "CASE WHEN e.auth_source='Overflow' THEN 'Unknown' ELSE COALESCE(e.auth_result,'Unknown') END," +
            "CASE WHEN e.auth_source='Overflow' THEN 'Unknown' ELSE COALESCE(e.auth_attempt_result,'Unknown') END,e.auth_source";
        const string ClientHourCols = "h.client_id,h.status,h.tls,h.mechanism,h.result,h.attempt,h.source,h.n,h.rcpts,h.min_id,h.min_ms,h.max_ms";

        static void AddStatus(ClientAcc a, string status, long n)
        {
            a.N += n;
            // Binary comparisons, as before: "Sent" and any other text count as not completed.
            if (status == "Accepted") a.Accepted += n; else if (status == "Rejected") a.Rejected += n; else if (status == "Deferred") a.Deferred += n; else a.Other += n;
        }

        static ClientAcc AccOf(Dictionary<long, ClientAcc> accs, long key)
        {
            ClientAcc a;
            if (!accs.TryGetValue(key, out a)) accs[key] = a = new ClientAcc { Client = key };
            return a;
        }

        void AddRaw(Dictionary<long, ClientAcc> accs, ClientValues d, SqliteDataReader r)
        {
            long id = r.GetInt64(0), ms = r.GetInt64(1);
            var a = AccOf(accs, r.IsDBNull(2) ? -id : r.GetInt64(2));
            AddStatus(a, r.IsDBNull(3) ? null : Text(r.GetValue(3)), 1);
            a.Rcpts += r.GetInt64(4);
            if (id < a.MinId) a.MinId = id;
            if (ms < a.MinMs) a.MinMs = ms;
            if (ms > a.MaxMs) a.MaxMs = ms;
            a.Tls.Add(d.Of(r.GetValue(5))); a.Mech.Add(d.Of(r.GetValue(6))); a.Res.Add(d.Of(r.GetValue(7))); a.Att.Add(d.Of(r.GetValue(8))); a.Src.Add(d.Of(r.GetValue(9)));
        }

        void AddHour(Dictionary<long, ClientAcc> accs, ClientValues d, SqliteDataReader r)
        {
            // client_id,status,tls,mechanism,result,attempt,source,n,rcpts,min_id,min_ms,max_ms
            var a = AccOf(accs, r.GetInt64(0));
            AddStatus(a, d.Decode(r.GetInt64(1)), r.GetInt64(7));
            a.Rcpts += r.GetInt64(8);
            long minId = r.GetInt64(9), minMs = r.GetInt64(10), maxMs = r.GetInt64(11);
            if (minId < a.MinId) a.MinId = minId;
            if (minMs < a.MinMs) a.MinMs = minMs;
            if (maxMs > a.MaxMs) a.MaxMs = maxMs;
            a.Tls.Add(r.GetInt64(2)); a.Mech.Add(r.GetInt64(3)); a.Res.Add(r.GetInt64(4)); a.Att.Add(r.GetInt64(5)); a.Src.Add(r.GetInt64(6));
        }

        static string ServerFilterRaw(ServeFilter f) { return f.Server == null ? "" : " AND e.server=@s COLLATE NOCASE"; }
        static string StatusFilterRaw(ServeFilter f) { return f.Status == null ? "" : " AND e.status=@status COLLATE NOCASE"; }
        static string HourFilters(ServeFilter f)
        {
            return (f.Status == null ? "" : " AND h.status IN (SELECT v.id FROM smtp_client_value v WHERE v.text=@status COLLATE NOCASE)") +
                   (f.Server == null ? "" : " AND c.server=@s COLLATE NOCASE");
        }
        // The server of a client is a dimension column: joined per aggregate row (an IN (SELECT ...) would materialise every client of the server per statement).
        static string HourFrom(ServeFilter f, string hint = "") { return " FROM smtp_client_hour h" + hint + (f.Server == null ? "" : " JOIN smtp_client c ON c.id=h.client_id"); }
        const string PartialHours = "((e.time_ms>=@f AND e.time_ms<@hA) OR (e.time_ms>=@hB AND e.time_ms<@t))";

        SqliteCommand ClientCommand(string sql, ServeFilter f)
        {
            var c = FilterCommand(sql, f);
            return c;
        }

        // ---- the SQL of the reads (shared by the reads and by ExplainSmtpClients)
        string ClientRawSql(ServeFilter f, string window, string scan, bool user) { return "SELECT " + ClientRawCols + " FROM smtp_transaction e" + scan + " WHERE " + window + (user ? SourceFilter(f, "e", true) : ServerFilterRaw(f)) + StatusFilterRaw(f) + ";"; }
        static string DiscoverHourSql(ServeFilter f) { return "SELECT DISTINCT h.client_id" + HourFrom(f, " INDEXED BY ix_smtp_client_hour") + " WHERE h.hour_ms=@h" + HourFilters(f) + ";"; }
        static string DiscoverEdgeSql(ServeFilter f) { return "SELECT e.id,e.client_id FROM smtp_transaction e WHERE e.time_ms>=@lo AND e.time_ms<@hi" + ServerFilterRaw(f) + StatusFilterRaw(f) + ";"; }
        static string DiscoverUnknownSql(ServeFilter f) { return "SELECT e.id FROM smtp_transaction e INDEXED BY ix_smtp_unknown_peer WHERE e.client_id IS NULL AND e.time_ms>=@lo AND e.time_ms<@hi" + ServerFilterRaw(f) + StatusFilterRaw(f) + ";"; }
        static string AggregateHourSql(ServeFilter f) { return "SELECT " + ClientHourCols + " FROM smtp_client_hour h WHERE h.client_id=@c AND h.hour_ms>=@hA AND h.hour_ms<@hB" + (f.Status == null ? "" : " AND h.status IN (SELECT v.id FROM smtp_client_value v WHERE v.text=@status COLLATE NOCASE)") + ";"; }
        static string AggregateEdgeSql(ServeFilter f) { return "SELECT " + ClientRawCols + " FROM smtp_transaction e INDEXED BY ix_smtp_client WHERE e.client_id=@c AND " + PartialHours + StatusFilterRaw(f) + ";"; }
        // The detail of one client under every filter of the selection (the server is a dimension: joined, so another server selects nothing).
        static string ClientHourSql(ServeFilter f) { return "SELECT " + ClientHourCols + HourFrom(f) + " WHERE h.client_id=@c AND h.hour_ms>=@hA AND h.hour_ms<@hB" + HourFilters(f) + ";"; }
        static string LatestBelowSql() { return "SELECT MAX(e.time_ms) FROM smtp_transaction e WHERE e.time_ms>=@f AND e.time_ms<@hi;"; }
        string UserNewestSql(ServeFilter f) { return "SELECT " + ClientRawCols + " FROM smtp_transaction e WHERE e.time_ms>=@f AND e.time_ms<@t" + SourceFilter(f, "e", true) + StatusFilterRaw(f) + " ORDER BY e.time_ms DESC,e.id DESC;"; }
        static string UserCompleteSql(ServeFilter f) { return "SELECT " + ClientRawCols + " FROM smtp_transaction e INDEXED BY ix_smtp_client WHERE e.client_id=@c AND e.time_ms>=@f AND e.time_ms<@stop" + SourceFilter(f, "e", true) + StatusFilterRaw(f) + ";"; }

        /// <summary>Accumulates the bucket rows of whole hours in SQL, one row per client (the export reads them all).</summary>
        string BulkHourSql(ServeFilter f, ClientValues d)
        {
            bool mask = d.Max < 63;
            Func<string, string> set = col => mask ? "SUM(DISTINCT (1<<h." + col + "))" : "json_group_array(DISTINCT h." + col + ")";
            return "SELECT h.client_id,SUM(h.n),SUM(h.rcpts),MIN(h.min_id),MIN(h.min_ms),MAX(h.max_ms)," +
                "SUM(CASE WHEN h.status=@acc THEN h.n ELSE 0 END),SUM(CASE WHEN h.status=@rej THEN h.n ELSE 0 END),SUM(CASE WHEN h.status=@def THEN h.n ELSE 0 END)," +
                set("tls") + "," + set("mechanism") + "," + set("result") + "," + set("attempt") + "," + set("source") +
                HourFrom(f) + " WHERE h.hour_ms>=@hA AND h.hour_ms<@hB" + HourFilters(f) + " GROUP BY h.client_id;";
        }

        static void AddSet(ref CodeSet set, SqliteDataReader r, int i, bool mask)
        {
            if (mask) { set.AddMask(r.GetInt64(i)); return; }
            foreach (long code in JsonSerializer.Deserialize<long[]>(r.GetString(i))) set.Add(code);
        }

        /// <summary>Every group of the selection (export, or a short page): partial hours and unknown peers from the rows, whole hours from the buckets in SQL.</summary>
        Dictionary<long, ClientAcc> ClientBulk(ServeFilter f, ClientValues d)
        {
            var accs = new Dictionary<long, ClientAcc>();
            long hA = Store.CeilHour(f.From), hB = Store.FloorHour(f.To);
            bool hours = f.User == null && hA < hB;
            // rows: the whole selection when hours cannot be used (user filter, no whole hour), otherwise only the partial hours at both ends
            string window = hours ? PartialHours : "e.time_ms>=@f AND e.time_ms<@t";
            string scan = !hours && f.Server == null && WholeSourcePeriod("smtp_transaction", f) ? " NOT INDEXED" : "";
            using (var c = ClientCommand(ClientRawSql(f, window, scan, true), f))
            {
                c.Parameters.AddWithValue("@hA", hA); c.Parameters.AddWithValue("@hB", hB);
                using (var r = c.ExecuteReader()) while (r.Read()) { _cancel.ThrowIfCancellationRequested(); AddRaw(accs, d, r); }
            }
            if (!hours) return accs;
            bool mask = d.Max < 63;
            using (var c = ClientCommand(BulkHourSql(f, d), f))
            {
                c.Parameters.AddWithValue("@hA", hA); c.Parameters.AddWithValue("@hB", hB);
                long code;
                c.Parameters.AddWithValue("@acc", d.Code.TryGetValue("Accepted", out code) ? code : -1L);
                c.Parameters.AddWithValue("@rej", d.Code.TryGetValue("Rejected", out code) ? code : -1L);
                c.Parameters.AddWithValue("@def", d.Code.TryGetValue("Deferred", out code) ? code : -1L);
                using (var r = c.ExecuteReader())
                    while (r.Read())
                    {
                        _cancel.ThrowIfCancellationRequested();
                        var a = AccOf(accs, r.GetInt64(0));
                        long n = r.GetInt64(1), accepted = r.GetInt64(6), rejected = r.GetInt64(7), deferred = r.GetInt64(8);
                        a.N += n; a.Accepted += accepted; a.Rejected += rejected; a.Deferred += deferred; a.Other += n - accepted - rejected - deferred;
                        a.Rcpts += r.GetInt64(2);
                        long minId = r.GetInt64(3), minMs = r.GetInt64(4), maxMs = r.GetInt64(5);
                        if (minId < a.MinId) a.MinId = minId;
                        if (minMs < a.MinMs) a.MinMs = minMs;
                        if (maxMs > a.MaxMs) a.MaxMs = maxMs;
                        AddSet(ref a.Tls, r, 9, mask); AddSet(ref a.Mech, r, 10, mask); AddSet(ref a.Res, r, 11, mask); AddSet(ref a.Att, r, 12, mask); AddSet(ref a.Src, r, 13, mask);
                    }
            }
            // a transaction without client is never aggregated: each one is read from its partial index
            using (var c = ClientCommand("SELECT " + ClientRawCols + " FROM smtp_transaction e INDEXED BY ix_smtp_unknown_peer WHERE e.client_id IS NULL AND e.time_ms>=@hA AND e.time_ms<@hB" + ServerFilterRaw(f) + StatusFilterRaw(f) + ";", f))
            {
                c.Parameters.AddWithValue("@hA", hA); c.Parameters.AddWithValue("@hB", hB);
                using (var r = c.ExecuteReader()) while (r.Read()) { _cancel.ThrowIfCancellationRequested(); AddRaw(accs, d, r); }
            }
            return accs;
        }

        /// <summary>
        /// Top-K path (paged list, no user filter): discovers the K most recent groups hour by hour from the end of the period, then aggregates only those.
        /// A group that was not seen when K groups are known has all its transactions before the last hour read, so it ranks after every group seen.
        /// </summary>
        Dictionary<long, ClientAcc> ClientTopK(ServeFilter f, ClientValues d, int k)
        {
            long hA = Store.CeilHour(f.From), hB = Store.FloorHour(f.To);
            var seen = new HashSet<long>();
            long hi = f.To;
            using (var raw = ClientCommand(DiscoverEdgeSql(f), f))
            using (var hour = ClientCommand(DiscoverHourSql(f), f))
            using (var unknown = ClientCommand(DiscoverUnknownSql(f), f))
            using (var latest = ClientCommand(LatestBelowSql(), f))
            {
                var lo = raw.Parameters.Add("@lo", SqliteType.Integer); var hip = raw.Parameters.Add("@hi", SqliteType.Integer);
                var h = hour.Parameters.Add("@h", SqliteType.Integer);
                var ulo = unknown.Parameters.Add("@lo", SqliteType.Integer); var uhi = unknown.Parameters.Add("@hi", SqliteType.Integer);
                var lhi = latest.Parameters.Add("@hi", SqliteType.Integer);
                bool skip = false;
                while (hi > f.From && seen.Count < k)
                {
                    _cancel.ThrowIfCancellationRequested();
                    if (skip)
                    {
                        // The last hour held nothing: jump to the hour of the latest transaction below it (a sparse or very long period costs one query per gap, not one per hour).
                        lhi.Value = hi;
                        object newest = latest.ExecuteScalar();
                        if (newest == null || newest is DBNull) break;
                        long top = Store.FloorHour(Long(newest)) + Store.HourMs;
                        if (top < hi) hi = top;
                        skip = false;
                    }
                    long start = Math.Max(f.From, Store.FloorHour(hi - 1));
                    bool full = start >= hA && start + Store.HourMs <= hB && start + Store.HourMs == hi;
                    int read = 0;
                    if (full)
                    {
                        h.Value = start;
                        using (var r = hour.ExecuteReader()) while (r.Read()) { seen.Add(r.GetInt64(0)); read++; }
                        ulo.Value = start; uhi.Value = hi;
                        using (var r = unknown.ExecuteReader()) while (r.Read()) { seen.Add(-r.GetInt64(0)); read++; }
                    }
                    else
                    {
                        lo.Value = start; hip.Value = hi;
                        using (var r = raw.ExecuteReader()) while (r.Read()) { seen.Add(r.IsDBNull(1) ? -r.GetInt64(0) : r.GetInt64(1)); read++; }
                    }
                    skip = read == 0;
                    hi = start;
                }
            }
            // exact aggregates of the candidates only
            var accs = new Dictionary<long, ClientAcc>();
            using (var hourRows = ClientCommand(AggregateHourSql(f), f))
            using (var edgeRows = ClientCommand(AggregateEdgeSql(f), f))
            using (var single = ClientCommand("SELECT " + ClientRawCols + " FROM smtp_transaction e WHERE e.id=@id;", f))
            {
                var hc = hourRows.Parameters.Add("@c", SqliteType.Integer);
                hourRows.Parameters.AddWithValue("@hA", Math.Min(hA, hB)); hourRows.Parameters.AddWithValue("@hB", hB);
                var rc = edgeRows.Parameters.Add("@c", SqliteType.Integer);
                // without a whole hour, the edge rows are the whole period
                edgeRows.Parameters.AddWithValue("@hA", hA < hB ? hA : f.To); edgeRows.Parameters.AddWithValue("@hB", hA < hB ? hB : f.To);
                var sid = single.Parameters.Add("@id", SqliteType.Integer);
                foreach (long key in seen)
                {
                    _cancel.ThrowIfCancellationRequested();
                    if (key < 0)
                    {
                        sid.Value = -key;
                        using (var r = single.ExecuteReader()) while (r.Read()) AddRaw(accs, d, r);
                        continue;
                    }
                    if (hA < hB) { hc.Value = key; using (var r = hourRows.ExecuteReader()) while (r.Read()) AddHour(accs, d, r); }
                    rc.Value = key;
                    using (var r = edgeRows.ExecuteReader()) while (r.Read()) AddRaw(accs, d, r);
                }
            }
            return accs;
        }

        /// <summary>
        /// Top-K with a user filter (a substring LIKE cannot use the hourly buckets): the matching transactions newest first, accumulating every group seen;
        /// once K groups are seen, the rows of the same millisecond are finished; the candidates are then completed with their older rows only.
        /// </summary>
        Dictionary<long, ClientAcc> ClientTopKUser(ServeFilter f, ClientValues d, int k)
        {
            var accs = new Dictionary<long, ClientAcc>();
            long stop = long.MinValue; bool exhausted = true;
            using (var c = ClientCommand(UserNewestSql(f), f))
            {
                using (var r = c.ExecuteReader())
                    while (r.Read())
                    {
                        _cancel.ThrowIfCancellationRequested();
                        long ms = r.GetInt64(1);
                        if (stop != long.MinValue && ms < stop) { exhausted = false; break; }
                        AddRaw(accs, d, r);
                        if (stop == long.MinValue && accs.Count >= k) stop = ms;
                    }
            }
            if (!exhausted)
                using (var c = ClientCommand(UserCompleteSql(f), f))
                {
                    var p = c.Parameters.Add("@c", SqliteType.Integer); c.Parameters.AddWithValue("@stop", stop);
                    foreach (long key in accs.Keys.ToList())
                    {
                        if (key < 0) continue;   // a transaction without client is a group of its own, already read
                        _cancel.ThrowIfCancellationRequested();
                        p.Value = key;
                        using (var r = c.ExecuteReader()) while (r.Read()) AddRaw(accs, d, r);
                    }
                }
            return accs;
        }

        ServeRow ClientRow(ClientAcc a, object[] dim, ClientValues d)
        {
            // dim: server,direction,role,connector,remote_host,helo,account
            var cells = new object[21];
            cells[0] = Iso(a.MinMs); cells[1] = Iso(a.MaxMs);
            for (int i = 0; i < 6; i++) cells[2 + i] = dim[i];
            cells[8] = SmtpAuthView.User(dim[6]);
            cells[9] = a.N; cells[10] = a.Accepted; cells[11] = a.Rejected; cells[12] = a.Deferred; cells[13] = a.Other; cells[14] = a.Rcpts;
            Func<CodeSet, string[]> set = s => s.All.Select(d.Decode).Where(x => x != null).Distinct(StringComparer.Ordinal).OrderBy(x => x, StringComparer.Ordinal).ToArray();
            cells[15] = set(a.Tls); cells[16] = set(a.Mech); cells[17] = set(a.Res); cells[18] = set(a.Att);
            cells[19] = a.Src.All.Select(d.Decode).Select(SmtpAuthView.Evidence).Distinct(StringComparer.Ordinal).OrderBy(x => x, StringComparer.Ordinal).ToArray();
            // the group has one account: either every transaction has none or none has none
            cells[20] = dim[6] == null ? a.N : 0L;
            return new ServeRow { id = a.MinId, cells = cells };
        }

        /// <summary>Dimension values of the groups: the client row, or for a transaction without endpoint its own values (the group is that transaction alone).</summary>
        Dictionary<long, object[]> ClientDimensions(IList<long> keys)
        {
            var dims = new Dictionary<long, object[]>();
            Func<SqliteDataReader, int, object[]> read = (r, from) => { var row = new object[7]; for (int i = 0; i < 7; i++) row[i] = r.IsDBNull(from + i) ? null : r.GetValue(from + i); return row; };
            var known = keys.Where(x => x > 0).ToList();
            var unknown = keys.Where(x => x < 0).Select(x => -x).ToList();
            for (int i = 0; i < known.Count; i += 1000)
                using (var c = Command("SELECT c.id,c.server,c.direction,c.role,c.connector,c.remote_host,c.helo,c.account FROM json_each(@ids) j JOIN smtp_client c ON c.id=j.value;"))
                {
                    c.Parameters.AddWithValue("@ids", "[" + string.Join(",", known.Skip(i).Take(1000).Select(x => x.ToString(CultureInfo.InvariantCulture))) + "]");
                    using (var r = c.ExecuteReader()) while (r.Read()) dims[r.GetInt64(0)] = read(r, 1);
                }
            for (int i = 0; i < unknown.Count; i += 1000)
                using (var c = Command("SELECT e.id,e.server,e.direction,e.role,e.connector,NULL,e.helo," + Account + " FROM json_each(@ids) j JOIN smtp_transaction e ON e.id=j.value;"))
                {
                    c.Parameters.AddWithValue("@ids", "[" + string.Join(",", unknown.Skip(i).Take(1000).Select(x => x.ToString(CultureInfo.InvariantCulture))) + "]");
                    using (var r = c.ExecuteReader()) while (r.Read()) dims[-r.GetInt64(0)] = read(r, 1);
                }
            return dims;
        }

        /// <summary>
        /// The groups of the selection, most recent first (last_ms DESC, id DESC): a page (all=false, with a look-ahead row) or the whole selection (export, streamed).
        /// </summary>
        internal IEnumerable<ServeRow> ClientRows(ServeFilter f, bool all)
        {
            var d = Values();
            int k = (f.Page - 1) * f.Size + f.Size + 1;
            Dictionary<long, ClientAcc> accs = all ? ClientBulk(f, d) : f.User == null ? ClientTopK(f, d, k) : ClientTopKUser(f, d, k);
            var ordered = accs.Values.OrderByDescending(a => a.MaxMs).ThenByDescending(a => a.MinId);
            var page = (all ? ordered : ordered.Skip((f.Page - 1) * f.Size).Take(f.Size + 1)).ToList();
            accs = null;
            for (int i = 0; i < page.Count; i += 1000)
            {
                var chunk = page.Skip(i).Take(1000).ToList();
                var dims = ClientDimensions(chunk.Select(a => a.Client).ToList());
                foreach (var a in chunk)
                {
                    _cancel.ThrowIfCancellationRequested();
                    object[] dim;
                    if (!dims.TryGetValue(a.Client, out dim)) throw new System.IO.InvalidDataException("InvalidSmtpClients: a transaction points at a missing client.");
                    yield return ClientRow(a, dim, d);
                }
            }
        }

        /// <summary>Transaction id given in a URL: its client (0/NULL = no observed endpoint, a group of its own); throws the 404 of an unknown id.</summary>
        long ClientKeyOf(long id)
        {
            using (var c = Command("SELECT client_id FROM smtp_transaction WHERE id=@id;"))
            {
                c.Parameters.AddWithValue("@id", id);
                using (var r = c.ExecuteReader())
                {
                    if (!r.Read()) throw new ServeError(404, "NotFound", "SMTP client anchor not found.");
                    return r.IsDBNull(0) ? -id : r.GetInt64(0);
                }
            }
        }

        internal object Client(long id, ServeFilter f)
        {
            long key = ClientKeyOf(id);
            var d = Values();
            var accs = new Dictionary<long, ClientAcc>();
            long hA = Store.CeilHour(f.From), hB = Store.FloorHour(f.To);
            bool hours = f.User == null && hA < hB && key > 0;
            if (key < 0)
                using (var c = ClientCommand("SELECT " + ClientRawCols + " FROM smtp_transaction e WHERE e.id=@id AND " + SmtpWhere(f) + ";", f))
                {
                    c.Parameters.AddWithValue("@id", -key);
                    using (var r = c.ExecuteReader()) while (r.Read()) AddRaw(accs, d, r);
                }
            else
            {
                string window = hours ? PartialHours : "e.time_ms>=@f AND e.time_ms<@t";
                using (var c = ClientCommand("SELECT " + ClientRawCols + " FROM smtp_transaction e INDEXED BY ix_smtp_client WHERE e.client_id=@c AND " + window + SourceFilter(f, "e", true) + StatusFilterRaw(f) + ";", f))
                {
                    c.Parameters.AddWithValue("@c", key); c.Parameters.AddWithValue("@hA", hA); c.Parameters.AddWithValue("@hB", hB);
                    using (var r = c.ExecuteReader()) while (r.Read()) { _cancel.ThrowIfCancellationRequested(); AddRaw(accs, d, r); }
                }
                if (hours)
                    using (var c = ClientCommand(ClientHourSql(f), f))
                    {
                        c.Parameters.AddWithValue("@c", key); c.Parameters.AddWithValue("@hA", hA); c.Parameters.AddWithValue("@hB", hB);
                        using (var r = c.ExecuteReader()) while (r.Read()) { _cancel.ThrowIfCancellationRequested(); AddHour(accs, d, r); }
                    }
            }
            if (accs.Count == 0) throw new ServeError(404, "NotFound", "No SMTP client in this selection.");
            var dims = ClientDimensions(accs.Keys.ToList());
            var row = ClientRow(accs.Values.Single(), dims[key], d);
            string link = "/api/smtp/clients/" + id.ToString(CultureInfo.InvariantCulture) + "/transactions?from=" +
                Uri.EscapeDataString(Iso(f.From)) + "&to=" + Uri.EscapeDataString(Iso(f.To));
            foreach (var pair in new[] { new[] { "server", f.Server }, new[] { "user", f.User }, new[] { "status", f.Status } })
                if (pair[1] != null) link += "&" + pair[0] + "=" + Uri.EscapeDataString(pair[1]);
            return new { id, title = "SMTP client", columns = SmtpClientColumns.Concat(ServeColumn.Parse(new[] { "Transactions URL:text" })).ToArray(),
                cells = row.cells.Concat(new object[] { link }).ToArray() };
        }

        internal ServePage ClientTransactions(long id, ServeFilter f)
        {
            long key = ClientKeyOf(id);
            string group = key < 0 ? "e.id=@client" : "e.client_id=@client";
            string where = SmtpWhere(f) + " AND " + group;
            string hint = key < 0 ? "" : " INDEXED BY ix_smtp_client";
            using (var c = ClientCommand("SELECT 1 FROM smtp_transaction e" + hint + " WHERE " + where + " LIMIT 1;", f))
            {
                c.Parameters.AddWithValue("@client", key < 0 ? -key : key);
                if (c.ExecuteScalar() == null) throw new ServeError(404, "NotFound", "No SMTP client in this selection.");
            }
            var rows = new List<ServeRow>();
            using (var c = ClientCommand(SmtpSelect.Replace("FROM smtp_transaction e WHERE ", "FROM smtp_transaction e" + hint + " WHERE ") + where + Order("smtp") + " LIMIT @limit OFFSET @offset;", f))
            {
                c.Parameters.AddWithValue("@client", key < 0 ? -key : key);
                c.Parameters.AddWithValue("@limit", f.Size + 1); c.Parameters.AddWithValue("@offset", (f.Page - 1) * f.Size);
                using (var r = c.ExecuteReader())
                    while (r.Read())
                    {
                        _cancel.ThrowIfCancellationRequested();
                        var row = new object[r.FieldCount];
                        for (int i = 0; i < row.Length; i++) row[i] = r.IsDBNull(i) ? null : r.GetValue(i);
                        rows.Add(ConvertRow("smtp", row));
                    }
            }
            bool more = rows.Count > f.Size;
            if (more) rows.RemoveAt(rows.Count - 1);
            return new ServePage { columns = SmtpColumns, rows = rows, page = f.Page, size = f.Size, hasMore = more, total = null };
        }

        /// <summary>
        /// Plans of the statements the SMTP clients list uses for a selection (diagnostics, nothing is executed but EXPLAIN QUERY PLAN): the discovery and the
        /// exact aggregates of a page, the user path, and the whole-selection reads of the export.
        /// </summary>
        internal List<string> ExplainClients(ServeFilter f)
        {
            var plan = new List<string>();
            var d = Values();
            long hA = Store.CeilHour(f.From), hB = Store.FloorHour(f.To);
            bool hours = f.User == null && hA < hB;
            Action<string, string> explain = (name, sql) => {
                using (var c = FilterCommand(sql, f))
                {
                    foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(sql, "@[A-Za-z0-9_]+"))
                        if (!c.Parameters.Contains(m.Value)) c.Parameters.AddWithValue(m.Value, 0L);
                    var lines = new List<string>();
                    using (var e = Command("EXPLAIN QUERY PLAN " + sql))
                    {
                        foreach (SqliteParameter p in c.Parameters) e.Parameters.AddWithValue(p.ParameterName, p.Value);
                        using (var r = e.ExecuteReader()) while (r.Read()) lines.Add(r.GetString(3));
                    }
                    plan.Add("[" + name + "] " + string.Join(" | ", lines));
                }
            };
            if (f.User == null)
            {
                explain("discover hour", DiscoverHourSql(f));
                explain("discover edge", DiscoverEdgeSql(f));
                explain("discover unknown", DiscoverUnknownSql(f));
                explain("aggregate hours", AggregateHourSql(f));
                explain("aggregate edges", AggregateEdgeSql(f));
            }
            else
            {
                explain("newest", UserNewestSql(f));
                explain("complete", UserCompleteSql(f));
            }
            explain("rows", ClientRawSql(f, hours ? PartialHours : "e.time_ms>=@f AND e.time_ms<@t",
                !hours && f.Server == null && WholeSourcePeriod("smtp_transaction", f) ? " NOT INDEXED" : "", true));
            if (hours) explain("hours", BulkHourSql(f, d));
            return plan;
        }
        internal string OverviewSelection(ServeFilter f)
        {
            const string hour = "e.time_ms-((e.time_ms%3600000+3600000)%3600000)";
            const string period = "e.time_ms>=@f AND e.time_ms<@t";
            string access = (f.Server == null ? "" : " AND e.server=@s COLLATE NOCASE") +
                (f.User == null ? "" : " AND (e.user LIKE @u ESCAPE '\\' OR e.mailbox LIKE @u ESCAPE '\\')");
            return "SELECT hour,server,SUM(tracking),SUM(messages),SUM(smtp),SUM(accepted),SUM(rejected),SUM(deferred),SUM(incomplete),SUM(access) FROM(" +
                "SELECT " + hour + " hour,e.server server,COUNT(*) tracking,COUNT(DISTINCT e.message_id COLLATE BINARY) messages,0 smtp,0 accepted,0 rejected,0 deferred,0 incomplete,0 access " +
                "FROM message_event e INDEXED BY ix_msg_flow WHERE " + period + SourceFilter(f, "e", false) + " GROUP BY hour,e.server COLLATE NOCASE" +
                " UNION ALL SELECT " + hour + ",e.server,0,0,COUNT(*),SUM(CASE WHEN e.status='Accepted' THEN 1 ELSE 0 END)," +
                "SUM(CASE WHEN e.status='Rejected' THEN 1 ELSE 0 END),SUM(CASE WHEN e.status='Deferred' THEN 1 ELSE 0 END)," +
                "SUM(CASE WHEN e.status IS NULL OR e.status NOT IN('Accepted','Rejected','Deferred') THEN 1 ELSE 0 END),0 " +
                "FROM smtp_transaction e INDEXED BY ix_smtp_flow WHERE " + period + SourceFilter(f, "e", true) + " GROUP BY 1,e.server COLLATE NOCASE" +
                " UNION ALL SELECT " + hour + ",e.server,0,0,0,0,0,0,0,COUNT(*) FROM access_event e WHERE " + period + access +
                " GROUP BY 1,e.server COLLATE NOCASE) GROUP BY hour,server COLLATE NOCASE ORDER BY hour DESC,server COLLATE NOCASE LIMIT 10001;";
        }

        internal object Overview(ServeFilter f)
        {
            var rows = new List<ServeRow>();
            // Bound temporary DISTINCT/GROUP BY work without changing the snapshot or adding stored aggregates.
            // Keep one range query for long, potentially sparse periods rather than walking every empty hour.
            bool partitioned = f.To - f.From <= 31L * 86400000;
            using (var c = FilterCommand(OverviewSelection(f), f))
            {
                long end = f.To;
                do
                {
                    _cancel.ThrowIfCancellationRequested();
                    long start = partitioned ? Math.Max(f.From, end - 1 - ((end - 1) % 3600000 + 3600000) % 3600000) : f.From;
                    c.Parameters["@f"].Value = start;
                    c.Parameters["@t"].Value = end;
                    using (var r = c.ExecuteReader())
                        while (r.Read())
                        {
                            _cancel.ThrowIfCancellationRequested();
                            if (rows.Count == 10000) throw new ServeError(422, "OverviewTooLarge", "More than 10000 hour/server bins; narrow the period or server.");
                            var cells = new object[r.FieldCount];
                            for (int i = 0; i < cells.Length; i++) cells[i] = r.IsDBNull(i) ? null : r.GetValue(i);
                            cells[0] = Iso(Long(cells[0]));
                            rows.Add(new ServeRow { id = rows.Count + 1L, cells = cells });
                        }
                    end = start;
                } while (end > f.From);
            }
            return new { columns = ServeColumn.Parse(new[] { "Hour:time", "Server:text", "Tracking events:num", "Tracked messages:num", "SMTP transactions:num",
                "Accepted:num", "Rejected:num", "Deferred:num", "Not completed:num", "Retained access requests:num" }), rows,
                from = Iso(f.From), to = Iso(f.To),
                basis = "UTC hourly/server aggregates of retained source rows. Tracked messages are exact BINARY Message-IDs distinct within each bin, not globally distinct. Retained access requests follow the existing event-retention policy, not all requests. Daily access_usage cannot establish hourly full-usage totals. Usage HTML remains unchanged." };
        }
    }
}
