using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    public static class ServeDiagnostics
    {
        public static string ExplainSmtpClients(string path, long from, long to, string server, string user)
        {
            return ExplainAggregate(path, from, to, server, user, true);
        }
        public static string ExplainOverview(string path, long from, long to, string server, string user)
        {
            return ExplainAggregate(path, from, to, server, user, false);
        }
        static string ExplainAggregate(string path, long from, long to, string server, string user, bool clients)
        {
            using (var db = new ServeRead(new ServeOptions { DatabasePath = path }, System.Threading.CancellationToken.None))
            {
                db.Ready();
                var f = new ServeFilter { From = from, To = to, Server = string.IsNullOrEmpty(server) ? null : server,
                    User = string.IsNullOrEmpty(user) ? null : user };
                // The SMTP clients list is read from smtp_client_hour / smtp_client / smtp_transaction in several statements (schema 11): their plans are listed one by one.
                if (clients) return JsonSerializer.Serialize(db.ExplainClients(f));
                var plan = new List<string>();
                string sql = db.OverviewSelection(f);
                using (var c = db.FilterCommand("EXPLAIN QUERY PLAN " + sql, f))
                using (var r = c.ExecuteReader()) while (r.Read()) plan.Add(r.GetString(3));
                return JsonSerializer.Serialize(plan);
            }
        }

        public static string ExplainMessageList(string path, long from, long to, string server, string user, string status)
        {
            using (var db = new ServeRead(new ServeOptions { DatabasePath = path }, System.Threading.CancellationToken.None))
            {
                db.Ready();
                var f = new ServeFilter { From = from, To = to, Server = string.IsNullOrEmpty(server) ? null : server,
                    User = string.IsNullOrEmpty(user) ? null : user, Status = string.IsNullOrEmpty(status) ? null : status };
                var plan = new List<string>();
                foreach (bool probe in ServeRead.ScopedMessages(f) ? new[] { true, false } : new[] { false })
                {
                    if (ServeRead.ScopedMessages(f)) plan.Add(probe ? "Bounded latest-candidate probe: " + ServeRead.ProbeRows(f) : "Exact source-membership set when the bounded probe is insufficient");
                    using (var c = db.FilterCommand("EXPLAIN QUERY PLAN " + (probe ? db.ProbeSelection(f) : db.Selection("messages", f)) + ServeRead.Order("messages") + " LIMIT 101;", f))
                    {
                        if (probe) c.Parameters.AddWithValue("@probe", ServeRead.ProbeRows(f));
                        using (var r = c.ExecuteReader()) while(r.Read()) plan.Add(r.GetString(3));
                    }
                }
                return JsonSerializer.Serialize(plan);
            }
        }

        // No Store constructor: diagnostics never migrate the inspected file.
        public static string MeasureLegacySelection(string path, long from, long to, int repetitions)
        {
            if (repetitions < 1 || repetitions > 20) throw new ArgumentOutOfRangeException(nameof(repetitions));
            var results = new List<object>();
            foreach (int mmap in new[] { 0, 256 })
            using (var db = new SqliteConnection(new SqliteConnectionStringBuilder {
                DataSource = Path.GetFullPath(path), Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString()))
            {
                db.Open();
                using (var setup = db.CreateCommand())
                {
                    setup.CommandText = "PRAGMA query_only=ON; PRAGMA busy_timeout=250; PRAGMA cache_size=-16384; PRAGMA temp_store=FILE; PRAGMA mmap_size=" +
                        (mmap * 1048576L).ToString(CultureInfo.InvariantCulture) + ";";
                    setup.ExecuteNonQuery();
                }
                long actualMmap;
                using (var c = db.CreateCommand())
                {
                    c.CommandText = "PRAGMA mmap_size;";
                    actualMmap = Convert.ToInt64(c.ExecuteScalar(), CultureInfo.InvariantCulture);
                }
                bool hash = false;
                using (var c = db.CreateCommand())
                {
                    c.CommandText = "PRAGMA table_info(message_event);";
                    using (var r = c.ExecuteReader()) while (r.Read()) if (r.GetString(1) == "msg_hash") hash = true;
                }
                string identity = hash ? "(msg_hash,message_id)" : "message_id";
                string sql = "SELECT message_id,time_ms,server,event_id,source,internal_id,sender,recipients,recipient_status,recipient_count,total_bytes,subject,client_ip,client_host,server_host,connector,source_context,directionality,related_recipient,reference FROM message_event WHERE " +
                    identity + " IN (SELECT " + (hash ? "msg_hash,message_id" : "message_id") +
                    " FROM message_event WHERE time_ms>=@f AND time_ms<@t AND message_id IS NOT NULL) ORDER BY message_id,time_ms,id;";
                var plan = new List<string>();
                var samples = new List<object>();
                for (int n = -1; n < repetitions; n++)
                using (var c = db.CreateCommand())
                {
                    c.CommandTimeout = 60;
                    c.CommandText = (n < 0 ? "EXPLAIN QUERY PLAN " : "") + sql;
                    c.Parameters.AddWithValue("@f", from); c.Parameters.AddWithValue("@t", to);
                    long count = 0;
                    var clock = Stopwatch.StartNew();
                    SQLitePCL.raw.sqlite3_progress_handler(db.Handle, 1000, _ => clock.Elapsed.TotalSeconds >= 60 ? 1 : 0, null);
                    try { using (var r = c.ExecuteReader()) while (r.Read()) { if (n < 0) plan.Add(r.GetString(3)); else count++; } }
                    finally { SQLitePCL.raw.sqlite3_progress_handler(db.Handle, 0, null, null); }
                    if (n >= 0) samples.Add(new { milliseconds = clock.Elapsed.TotalMilliseconds, rows = count, connectionCold = n == 0 });
                }
                results.Add(new { mmapMB = mmap, actualMmapBytes = actualMmap, queryDeadlineSeconds = 60, hashTuple = hash, plan, samples });
            }
            return JsonSerializer.Serialize(new { fixture = Path.GetFullPath(path), databaseBytes = new FileInfo(path).Length,
                from, to, cacheMB = 16, osCacheCold = false, scale24GBProven = false, results });
        }
    }
}
