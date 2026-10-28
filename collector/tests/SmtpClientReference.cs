// Test-only reference for the SMTP clients of Serve: the schema-10 implementation (ClientSelection / ClientGroup / ClientTransactions of 0.3.0, which grouped the
// transaction rows of the selection at every request), transcribed independently of the engine and run against a schema-10 copy of the same data, plus the
// randomized edge-case fixture and the helpers that read the HTTP answers. Schema 11 must give the very same rows, byte for byte once serialized.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

public sealed class RefFilter
{
    public long From, To;
    public int Page = 1, Size = 100;
    public string User, Server, Status;
}

public sealed class RefRow { public long id { get; set; } public object[] cells { get; set; } }

public sealed class RefResult
{
    public List<string> Rows = new List<string>();
    public List<long> Ids = new List<long>();
    public List<object[]> Cells = new List<object[]>();
    public bool HasMore;
    public string Note = "";
    public string Body;
}

public static class SmtpClientReference
{
    // ------------------------------------------------------------------ independent copies of the engine helpers
    static string Host(string endpoint)
    {
        if (string.IsNullOrEmpty(endpoint)) return endpoint;
        string s = endpoint.Trim();
        if (s.StartsWith("[")) { int close = s.IndexOf(']'); return close > 0 ? s.Substring(1, close - 1) : s; }
        int colon = s.LastIndexOf(':');
        return colon > 0 && s.IndexOf(':') == colon ? s.Substring(0, colon) : s;
    }
    static string RemoteHost(string endpoint) { string value = Host(endpoint); return string.IsNullOrEmpty(value) ? null : value.ToLowerInvariant(); }
    public static void Register(SqliteConnection db) { db.CreateFunction<string, string>("exl_remote_host", RemoteHost, isDeterministic: true); }
    public static string Iso(long ms) { return DateTimeOffset.FromUnixTimeMilliseconds(ms).ToString("O", CultureInfo.InvariantCulture); }
    static long Long(object v) { return Convert.ToInt64(v, CultureInfo.InvariantCulture); }
    static string Text(object v) { return v == null || v is DBNull ? null : (string)v; }
    static string Like(string value) { return "%" + value.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_") + "%"; }
    static string Evidence(object source)
    {
        switch (Text(source))
        {
            case "Direct": return "Direct server log";
            case "FrontEndProxy": return "Front end proxy";
            case "Missing": return "Missing";
            case "Overflow": return "Missing";
            case "NotApplicable": return "Not applicable";
            case "Ambiguous": return "Ambiguous";
            default: return "Legacy";
        }
    }

    // ------------------------------------------------------------------ the schema-10 queries
    const string Peer = "exl_remote_host(e.remote_ep)";
    const string Account = "CASE WHEN e.auth_source='Overflow' THEN NULL ELSE e.auth_user END";
    static string SourceFilter(RefFilter f)
    {
        string result = f.Server == null ? "" : " AND e.server=@s COLLATE NOCASE";
        if (f.User != null) result += " AND (e.mail_from LIKE @u ESCAPE '\\' OR e.rcpts LIKE @u ESCAPE '\\' OR e.auth_user LIKE @u ESCAPE '\\')";
        return result;
    }
    static string SmtpWhere(RefFilter f) { return "e.time_ms>=@f AND e.time_ms<@t" + SourceFilter(f) + (f.Status == null ? "" : " AND e.status=@status COLLATE NOCASE"); }
    static string Selection(RefFilter f, string group)
    {
        return "SELECT MIN(e.id) AS id,MIN(e.time_ms),MAX(e.time_ms) AS last_ms,e.server,e.direction,e.role,e.connector," + Peer +
            ",e.helo," + Account + ",COUNT(*)," +
            "SUM(CASE WHEN e.status='Accepted' THEN 1 ELSE 0 END),SUM(CASE WHEN e.status='Rejected' THEN 1 ELSE 0 END)," +
            "SUM(CASE WHEN e.status='Deferred' THEN 1 ELSE 0 END),SUM(CASE WHEN e.status IS NULL OR e.status NOT IN('Accepted','Rejected','Deferred') THEN 1 ELSE 0 END)," +
            "SUM(COALESCE(e.rcpt_count,0)),json_group_array(DISTINCT e.tls)," +
            "json_group_array(DISTINCT CASE WHEN e.auth_source='Overflow' THEN 'Not available' WHEN e.auth_mechanism IS NOT NULL THEN e.auth_mechanism WHEN e.auth_source='NotApplicable' THEN 'None' ELSE 'Not available' END)," +
            "json_group_array(DISTINCT CASE WHEN e.auth_source='Overflow' THEN 'Unknown' ELSE COALESCE(e.auth_result,'Unknown') END)," +
            "json_group_array(DISTINCT CASE WHEN e.auth_source='Overflow' THEN 'Unknown' ELSE COALESCE(e.auth_attempt_result,'Unknown') END)," +
            "json_group_array(DISTINCT e.auth_source),SUM((" + Account + ") IS NULL)" +
            " FROM smtp_transaction e WHERE " + SmtpWhere(f) + (group == null ? "" : " AND " + group) +
            " GROUP BY e.server COLLATE NOCASE,e.direction,e.role,e.connector," + Peer + ",e.helo," + Account +
            ",CASE WHEN " + Peer + " IS NULL THEN e.id END";
    }
    static string[] JsonStrings(object value) { return JsonSerializer.Deserialize<string[]>(Text(value) ?? "[]"); }
    static RefRow ConvertClient(object[] row)
    {
        var cells = row.Skip(1).ToArray();
        cells[0] = Iso(Long(cells[0])); cells[1] = Iso(Long(cells[1]));
        cells[8] = Text(cells[8]) ?? "Not available";
        for (int i = 15; i <= 18; i++) cells[i] = JsonStrings(cells[i]).Where(s => s != null).Distinct(StringComparer.Ordinal).OrderBy(s => s, StringComparer.Ordinal).ToArray();
        cells[19] = JsonStrings(cells[19]).Select(Evidence).Distinct(StringComparer.Ordinal).OrderBy(s => s, StringComparer.Ordinal).ToArray();
        return new RefRow { id = Long(row[0]), cells = cells };
    }
    static string ClientGroup(object[] anchor)
    {
        if (anchor[4] == null) return "e.id=@client";
        return "e.server IS @g0 COLLATE NOCASE AND e.direction IS @g1 AND e.role IS @g2 AND e.connector IS @g3 AND " +
            Peer + " IS @g4 AND e.helo IS @g5 AND (" + Account + ") IS @g6 COLLATE BINARY";
    }
    static SqliteCommand Command(SqliteConnection db, string sql, RefFilter f)
    {
        var c = db.CreateCommand(); c.CommandText = sql; c.CommandTimeout = 0;
        c.Parameters.AddWithValue("@f", f.From); c.Parameters.AddWithValue("@t", f.To);
        if (f.User != null) c.Parameters.AddWithValue("@u", Like(f.User));
        if (f.Server != null) c.Parameters.AddWithValue("@s", f.Server);
        if (f.Status != null) c.Parameters.AddWithValue("@status", f.Status);
        return c;
    }
    static object[] Anchor(SqliteConnection db, long id)
    {
        using (var c = db.CreateCommand())
        {
            c.CommandText = "SELECT e.server,e.direction,e.role,e.connector," + Peer + ",e.helo," + Account + " FROM smtp_transaction e WHERE e.id=@client;";
            c.Parameters.AddWithValue("@client", id);
            using (var r = c.ExecuteReader())
                if (r.Read()) { var row = new object[r.FieldCount]; for (int i = 0; i < row.Length; i++) row[i] = r.IsDBNull(i) ? null : r.GetValue(i); return row; }
        }
        return null;
    }
    static void BindAnchor(SqliteCommand c, object[] anchor, long id)
    {
        if (anchor == null) return;
        c.Parameters.AddWithValue("@client", id);
        for (int i = 0; i < anchor.Length; i++) c.Parameters.AddWithValue("@g" + i, anchor[i] ?? DBNull.Value);
    }

    /// <summary>GET /api/smtp/clients (a page with a look-ahead row), the export (all) or the detail of the client of a transaction (anchorId, all).</summary>
    public static RefResult List(SqliteConnection db, RefFilter f, bool all, long anchorId)
    {
        var res = new RefResult();
        object[] anchor = anchorId > 0 ? Anchor(db, anchorId) : null;
        if (anchorId > 0 && anchor == null) { res.Note = "404 anchor"; return res; }
        using (var c = Command(db, Selection(f, anchor == null ? null : ClientGroup(anchor)) + " ORDER BY last_ms DESC,id DESC" + (all ? ";" : " LIMIT @limit OFFSET @offset;"), f))
        {
            BindAnchor(c, anchor, anchorId);
            if (!all) { c.Parameters.AddWithValue("@limit", f.Size + 1); c.Parameters.AddWithValue("@offset", (f.Page - 1) * f.Size); }
            using (var r = c.ExecuteReader())
                while (r.Read())
                {
                    var row = new object[r.FieldCount];
                    for (int i = 0; i < row.Length; i++) row[i] = r.IsDBNull(i) ? null : r.GetValue(i);
                    var converted = ConvertClient(row);
                    res.Rows.Add(JsonSerializer.Serialize(converted)); res.Ids.Add(converted.id); res.Cells.Add(converted.cells);
                }
        }
        if (!all && res.Rows.Count > f.Size) { res.HasMore = true; res.Rows.RemoveAt(res.Rows.Count - 1); res.Ids.RemoveAt(res.Ids.Count - 1); res.Cells.RemoveAt(res.Cells.Count - 1); }
        if (anchorId > 0 && res.Rows.Count == 0) res.Note = "404 empty";
        return res;
    }

    /// <summary>GET /api/smtp/clients/{id}/transactions: the ids of the page in order (the cells are the unchanged transaction conversion).</summary>
    public static RefResult Transactions(SqliteConnection db, long id, RefFilter f)
    {
        var res = new RefResult();
        var anchor = Anchor(db, id);
        if (anchor == null) { res.Note = "404 anchor"; return res; }
        string where = SmtpWhere(f) + " AND " + ClientGroup(anchor);
        using (var c = Command(db, "SELECT 1 FROM smtp_transaction e WHERE " + where + " LIMIT 1;", f))
        {
            BindAnchor(c, anchor, id);
            if (c.ExecuteScalar() == null) { res.Note = "404 empty"; return res; }
        }
        using (var c = Command(db, "SELECT e.id FROM smtp_transaction e WHERE " + where + " ORDER BY e.time_ms DESC,e.id DESC LIMIT @limit OFFSET @offset;", f))
        {
            BindAnchor(c, anchor, id);
            c.Parameters.AddWithValue("@limit", f.Size + 1); c.Parameters.AddWithValue("@offset", (f.Page - 1) * f.Size);
            using (var r = c.ExecuteReader()) while (r.Read()) res.Ids.Add(r.GetInt64(0));
        }
        if (res.Ids.Count > f.Size) { res.HasMore = true; res.Ids.RemoveAt(res.Ids.Count - 1); }
        return res;
    }

    // ------------------------------------------------------------------ the export, as Serve writes it
    static string CsvCell(object value)
    {
        string text;
        if (value == null) return "";
        if (value is long || value is int || value is double) return Convert.ToString(value, CultureInfo.InvariantCulture);
        if (value is string) text = (string)value;
        else if (value is IEnumerable<string>) text = string.Join("; ", (IEnumerable<string>)value);
        else text = Convert.ToString(value, CultureInfo.InvariantCulture);
        string leading = text.TrimStart();
        if (leading.Length > 0 && ("=+-@".IndexOf(leading[0]) >= 0 || text[0] == '\t' || text[0] == '\r' || text[0] == '\n')) text = "'" + text;
        if (text.Length > 0 && "=+-@\t\r".IndexOf(text[0]) >= 0) text = "'" + text;
        if (text.IndexOf(';') >= 0 || text.IndexOf('"') >= 0 || text.IndexOf('\n') >= 0 || text.IndexOf('\r') >= 0) text = "\"" + text.Replace("\"", "\"\"") + "\"";
        return text;
    }
    /// <summary>The data lines of the CSV export of a result (without the BOM and the header).</summary>
    public static string Csv(RefResult r)
    {
        var sb = new StringBuilder();
        foreach (var cells in r.Cells) sb.Append(string.Join(";", cells.Select(CsvCell))).Append("\r\n");
        return sb.ToString();
    }
    /// <summary>The data lines of an export answer (the header line and the BOM removed).</summary>
    public static string CsvBody(string body)
    {
        int line = body.IndexOf("\r\n", StringComparison.Ordinal);
        return line < 0 ? "" : body.Substring(line + 2);
    }

    // ------------------------------------------------------------------ the HTTP answers
    public static string[] ApiRows(string json, out bool hasMore)
    {
        using (var doc = JsonDocument.Parse(json))
        {
            hasMore = doc.RootElement.GetProperty("hasMore").GetBoolean();
            return doc.RootElement.GetProperty("rows").EnumerateArray().Select(e => e.GetRawText()).ToArray();
        }
    }
    public static long[] ApiRowIds(string json, out bool hasMore)
    {
        using (var doc = JsonDocument.Parse(json))
        {
            hasMore = doc.RootElement.GetProperty("hasMore").GetBoolean();
            return doc.RootElement.GetProperty("rows").EnumerateArray().Select(e => e.GetProperty("id").GetInt64()).ToArray();
        }
    }
    /// <summary>The cells of the detail of a client without its last cell (the transactions link), as the row of the list serializes them.</summary>
    public static string ApiClientRow(string json)
    {
        using (var doc = JsonDocument.Parse(json))
        {
            var cells = doc.RootElement.GetProperty("cells").EnumerateArray().Select(e => e.GetRawText()).ToArray();
            return "[" + string.Join(",", cells.Take(cells.Length - 1)) + "]";
        }
    }
    public static string CellsJson(RefResult r) { return r.Cells.Count == 0 ? null : JsonSerializer.Serialize(r.Cells[0]); }

    // ------------------------------------------------------------------ the randomized fixture (Edge cases of the clients key)
    static T Pick<T>(Random r, T[] values) { return values[r.Next(values.Length)]; }
    public static long Epoch = 1790812800000L;   // 2026-10-01T00:00:00Z

    /// <summary>
    /// Inserts rows into smtp_transaction: empty and NULL endpoints, IPv6 with and without brackets, case, spaces, ports, broken text; NULL and empty HELO/role/connector/TLS;
    /// every evidence source including the retired Overflow; absent and odd statuses; rows on the hour boundaries and many in one millisecond; heavy and light clients.
    /// </summary>
    public static void BuildEdge(SqliteConnection db, int rows, int seed)
    {
        var r = new Random(seed);
        string[] servers = { "EX1", "EX2", "EX3" };
        string[] eps = { "198.51.100.10:2525", "198.51.100.10:41000", "198.51.100.11:25", "10.0.0.5:587", "[2001:db8::1]:25", "[2001:DB8::1]:26", "2001:db8::2", "2001:DB8::2",
            "Relay.Example:25", "relay.example:26", " 10.0.0.7:25 ", "10.0.0.7", "", null, null, "[broken", ":25", "10.0.0.8:25:x" };
        string[] helos = { "mail.example", "MAIL.example", null, "", "relay", "app01.contoso.test" };
        string[] roles = { "FrontEnd", "HubTransport", null };
        string[] connectors = { "EX1\\Default Frontend EX1", "Client Proxy", null, "" };
        string[] tls = { "TLS 1.2", "TLS 1.3", null, "" };
        string[] sources = { "Direct", "FrontEndProxy", "Missing", "Overflow", "NotApplicable", "Ambiguous", null, "Legacy?" };
        string[] users = { "proved@invalid", "other@invalid", "Proved@invalid", null, null, "" };
        string[] mechs = { "LOGIN", "NTLM", null, null };
        string[] results = { "Succeeded", "Failed", "Not attempted", null };
        string[] statuses = { "Accepted", "Rejected", "Deferred", "Incomplete", "Sent", null, "accepted", "Other" };
        string[] froms = { "a.user1@contoso.test", "b_user2@contoso.test", "c%user3@partner.test", "noreply@app.test", null };
        using (var tx = db.BeginTransaction())
        using (var c = db.CreateCommand())
        {
            c.Transaction = tx;
            c.CommandText = "INSERT INTO smtp_transaction(time_ms,end_ms,server,direction,role,connector,session_id,remote_ep,helo,tls,mail_from,rcpt_count,rcpts,status,auth_user,auth_mechanism,auth_result,auth_attempt_result,auth_source,auth_fragment_id) VALUES(@t,@e,@s,@d,@ro,@co,@sid,@ep,@h,@tl,@mf,@rc,@rp,@st,@au,@am,@ar,@aa,@so,@fr);";
            foreach (var n in new[] { "@t", "@e", "@s", "@d", "@ro", "@co", "@sid", "@ep", "@h", "@tl", "@mf", "@rc", "@rp", "@st", "@au", "@am", "@ar", "@aa", "@so", "@fr" }) c.Parameters.Add(new SqliteParameter(n, DBNull.Value));
            for (int i = 0; i < rows; i++)
            {
                long t;
                int mode = r.Next(10);
                long hour = Epoch + 3600000L * r.Next(72);
                if (mode == 0) t = hour;                                  // exactly on an hour boundary
                else if (mode == 1) t = hour - 1;                         // last millisecond of the previous hour
                else if (mode == 2) t = Epoch + 3600000L * 30 + 1234;     // many rows in the same millisecond
                else t = hour + r.Next(3600000);
                bool heavy = r.Next(3) == 0;                              // a few concentrated clients so that groups span several hours, and many light ones
                string ep = heavy ? Pick(r, new[] { "198.51.100.10:" + r.Next(1024, 65535), "[2001:db8::1]:" + r.Next(1, 99) }) : Pick(r, eps);
                string dir = r.Next(2) == 0 ? "Receive" : "Send";
                var p = c.Parameters;
                p["@t"].Value = t; p["@e"].Value = r.Next(4) == 0 ? (object)DBNull.Value : t + r.Next(5000);
                p["@s"].Value = heavy ? servers[0] : Pick(r, servers); p["@d"].Value = dir; p["@ro"].Value = (object)Pick(r, roles) ?? DBNull.Value;
                p["@co"].Value = (object)(heavy ? connectors[0] : Pick(r, connectors)) ?? DBNull.Value; p["@sid"].Value = "S" + i.ToString(CultureInfo.InvariantCulture);
                p["@ep"].Value = (object)ep ?? DBNull.Value; p["@h"].Value = (object)(heavy ? helos[0] : Pick(r, helos)) ?? DBNull.Value;
                p["@tl"].Value = (object)Pick(r, tls) ?? DBNull.Value; p["@mf"].Value = (object)Pick(r, froms) ?? DBNull.Value;
                p["@rc"].Value = r.Next(6) == 0 ? (object)DBNull.Value : (long)r.Next(0, 4);
                p["@rp"].Value = r.Next(5) == 0 ? (object)DBNull.Value : "user" + r.Next(9) + "@contoso.test;x_y@contoso.test";
                p["@st"].Value = (object)Pick(r, statuses) ?? DBNull.Value;
                string so = Pick(r, sources);
                p["@au"].Value = (object)(heavy && r.Next(2) == 0 ? "proved@invalid" : Pick(r, users)) ?? DBNull.Value;
                p["@am"].Value = (object)Pick(r, mechs) ?? DBNull.Value; p["@ar"].Value = (object)Pick(r, results) ?? DBNull.Value; p["@aa"].Value = (object)Pick(r, results) ?? DBNull.Value;
                p["@so"].Value = (object)so ?? DBNull.Value;
                p["@fr"].Value = dir == "Receive" && r.Next(2) == 0 ? (object)(long)(i + 1) : DBNull.Value;
                c.ExecuteNonQuery();
            }
            tx.Commit();
        }
    }

    // ------------------------------------------------------------------ one random scenario
    public sealed class Scenario
    {
        public string Route;       // list, export, client, tx
        public RefFilter Filter;
        public long Id;
        public string Query;       // the query string of the request
    }

    /// <summary>The scenario number n of a seed: the same sequence for the reference and for the HTTP side.</summary>
    public static Scenario[] Scenarios(int seed, int cases, long maxId)
    {
        var r = new Random(seed);
        string[] servers = { null, null, "EX1", "ex2", "EX3", "nope" };
        string[] userFilters = { null, null, null, "user1", "contoso", "%", "_user", "proved", "PROVED@", "c%user" };
        string[] statusFilters = { null, null, "accepted", "Sent", "rejected", "Other", "nope" };
        var routes = new[] { "list", "list", "list", "export", "client", "tx" };
        var result = new List<Scenario>();
        for (int i = 0; i < cases; i++)
        {
            var f = new RefFilter();
            int shape = r.Next(4);
            long a = Epoch + (long)(r.NextDouble() * 75 * 3600000L), b;
            if (shape == 0) { a = Epoch + 3600000L * r.Next(72); b = a + 3600000L * r.Next(1, 40); }      // hour-aligned
            else if (shape == 1) b = a + r.Next(1, 3600000);                                               // inside or across one boundary
            else if (shape == 2) { a = Epoch - 1000; b = Epoch + 80 * 3600000L; }                          // the whole table
            else b = a + (long)(r.NextDouble() * 50 * 3600000L) + 1;
            f.From = a; f.To = b;
            f.Server = servers[r.Next(servers.Length)]; f.User = userFilters[r.Next(userFilters.Length)]; f.Status = statusFilters[r.Next(statusFilters.Length)];
            f.Size = new[] { 1, 2, 5, 100 }[r.Next(4)]; f.Page = r.Next(1, 6);
            string route = routes[r.Next(routes.Length)];
            long id = 1 + (long)(r.NextDouble() * maxId);
            var q = new StringBuilder("from=" + Uri.EscapeDataString(Iso(f.From)) + "&to=" + Uri.EscapeDataString(Iso(f.To)));
            if (route == "list" || route == "tx") q.Append("&page=" + f.Page + "&size=" + f.Size);
            if (f.Server != null) q.Append("&server=" + Uri.EscapeDataString(f.Server));
            if (f.User != null) q.Append("&user=" + Uri.EscapeDataString(f.User));
            if (f.Status != null) q.Append("&status=" + Uri.EscapeDataString(f.Status));
            if (route == "export") q.Append("&view=smtp");
            if (route == "client") { f.Page = 1; f.Size = 100; }
            if (route == "export") { f.Page = 1; f.Size = 100; }
            result.Add(new Scenario { Route = route, Filter = f, Id = id, Query = q.ToString() });
        }
        return result.ToArray();
    }
}
