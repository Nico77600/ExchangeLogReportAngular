// =============================================================================
//  Exchange Log Report - engine, part 6: report views of client sessions,
//  clients (devices, versions) and operations (latency per operation)
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 2.0.0
//
//  sessions    one row per client session; its timeline is rebuilt from the steps written
//              per log file: sorted, back-end details joined to the front-end request with the
//              same RequestId (MAPI), consecutive batches of successes merged.
//  clients     one row per user x protocol x client (user agent or ActiveSync device)
//  operations  one row per protocol x operation (MAPI request type, ActiveSync command,
//              OWA action, IMAP/POP command...), all users, with failures and latency
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;

namespace ExchangeLogReport
{
    public static partial class ReportBuilder
    {
        sealed class Step
        {
            public long T, T2, AvgMs, MaxMs, Count, Failures;
            public int Status;
            public string Front, Back, Action, Detail, RequestId, Source;
            public bool Batch;
            // Where the raw lines are: [role, file id, search text, second search text]
            public List<object[]> Links = new List<object[]>();
        }

        /// <summary>Log files referenced by the timelines: id -> [server, kind, path].</summary>
        static Dictionary<long, string[]> LoadFiles(Store store, IEnumerable<long> ids)
        {
            var map = new Dictionary<long, string[]>();
            var list = ids.Where(x => x > 0).Distinct().ToList();
            for (int i = 0; i < list.Count; i += 500)
            {
                string inList = string.Join(",", list.Skip(i).Take(500).Select(x => x.ToString(CultureInfo.InvariantCulture)));
                foreach (var r in Rows(store, "SELECT id, server, kind, path FROM source_file WHERE id IN (" + inList + ");", null))
                    map[L(r[0])] = new[] { S(r[1]), S(r[2]), S(r[3]) };
            }
            return map;
        }

        static string ServerFilter(string[] servers, Dictionary<string, object> p, string expression)
        {
            var parts = new List<string>();
            int n = 0;
            foreach (var s in servers ?? new string[0])
            {
                if (string.IsNullOrWhiteSpace(s)) continue;
                string name = "@srv" + (n++);
                p[name] = s.Trim().ToUpperInvariant();
                parts.Add("instr(" + expression + ", ','||" + name + "||',') > 0");
            }
            return parts.Count == 0 ? "" : " AND (" + string.Join(" OR ", parts) + ")";
        }

        static string SessionOutcome(long failures, long successes, long slow, long firstSuccess, long lastSuccess, long firstFailure, long lastFailure, long windowMs)
        {
            if (failures == 0) return slow > 0 ? "OK (slow)" : "OK";
            if (successes == 0) return "Failed";
            if (lastFailure >= lastSuccess) return "Failed at end";
            if (failures >= 3 && lastFailure - firstFailure > windowMs && firstFailure > firstSuccess) return "Intermittent errors";
            return "Recovered";
        }

        /// <summary>Successes that say nothing about the health of the session (closing, capability exchange, first logon step).</summary>
        static readonly HashSet<string> Neutral = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "OPTIONS", "LOGOUT", "QUIT", "CAPABILITY", "CAPA", "NOOP", "USER", "GET logoff.owa", "Disconnect", "Unbind"
        };

        static string ClientFamily(string protocol, string agent, string deviceType)
        {
            if (string.Equals(protocol, "Eas", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrEmpty(deviceType)) return deviceType + " (ActiveSync)";
            if (string.IsNullOrEmpty(agent))
            {
                if (string.Equals(protocol, "Imap4", StringComparison.OrdinalIgnoreCase)) return "IMAP4 client";
                if (string.Equals(protocol, "Pop3", StringComparison.OrdinalIgnoreCase)) return "POP3 client";
                if (string.Equals(protocol, "Mapi", StringComparison.OrdinalIgnoreCase)) return "Outlook (MAPI)";
            }
            return Identity.Client(agent);
        }

        static string Top(string counts, int max)
        {
            if (string.IsNullOrEmpty(counts)) return null;
            var parts = counts.Split(';').Where(x => x.Length > 0).ToList();
            var shown = parts.Take(max).Select(x => { int eq = x.LastIndexOf('='); return eq > 0 ? x.Substring(0, eq) + " x" + x.Substring(eq + 1) : x; });
            return string.Join(", ", shown) + (parts.Count > max ? " (+" + (parts.Count - max) + ")" : "");
        }

        // ------------------------------------------------------------------ sessions

        sealed class SessionInput
        {
            public object[] Row;
            public List<string> Data = new List<string>();
            public List<Step> Steps;
            public long Bytes;
        }

        static IEnumerable<SessionInput> SessionInputs(Store store, string sql, Dictionary<string, object> parameters)
        {
            SessionInput current = null;
            foreach (var r in Rows(store, sql, parameters))
            {
                if (current == null || L(current.Row[0]) != L(r[0]))
                {
                    if (current != null) yield return current;
                    current = new SessionInput { Row = r.Take(29).ToArray() };
                    current.Bytes = ReportMemory.Bytes(current.Row);
                }
                string data = S(r[29]);
                if (data != null) { current.Data.Add(data); current.Bytes += ReportMemory.Bytes(data) * 8; }
            }
            if (current != null) yield return current;
        }

        static IEnumerable<List<SessionInput>> SessionBatches(IEnumerable<SessionInput> inputs, long maxBytes)
        {
            var batch = new List<SessionInput>();
            long bytes = 0;
            foreach (var input in inputs)
            {
                if (batch.Count > 0 && input.Bytes > maxBytes - bytes) { yield return batch; batch = new List<SessionInput>(); bytes = 0; }
                batch.Add(input); bytes += input.Bytes;
                if (batch.Count == 128 || bytes >= maxBytes) { yield return batch; batch = new List<SessionInput>(); bytes = 0; }
            }
            if (batch.Count > 0) yield return batch;
        }

        static Dataset BuildSessions(Store store, ReportRequest q, Func<long, object> local)
        {
            var set = new Dataset("sessions", "ClientSessions", q.Scratch);
            foreach (var n in new[] { "Start:time", "End:time", "Duration:text", "Outcome:text", "User:text", "Protocol:text", "Client:text", "Client IP:text",
                "Front ends:text", "Back ends:text", "Requests:num", "Failures:num", "Slow:num", "Average (ms):num", "Max (ms):num", "Operations:text",
                "Last error:text", "Software:text", "Client mode:text", "Device ID:text", "Mailbox:text", "Connections:num", "First error:text", "User agent:text",
                "Session ID:num", "Timeline:steps" })
            { var x = n.Split(':'); set.Add(x[0], x[1]); }
            set.Columns[set.Columns.Count - 1].Grid = false;
            set.Columns[set.Columns.Count - 1].Csv = q.IncludeSessionDetails;
            var f = new Sql(); f.P["@t0"] = q.StartMs; f.P["@t1"] = q.EndMs;
            string where = " FROM client_session c LEFT JOIN session_step s ON s.session_id=c.id WHERE c.end_ms >= @t0 AND c.start_ms < @t1" + f.Users(q.Users, "c.user", "c.mailbox")
                + ServerFilter(q.Servers, f.P, "','||COALESCE(c.front_ends,'')||','||COALESCE(c.back_ends,'')||','");
            var sessions = SessionInputs(store, "SELECT c.id,c.start_ms,c.end_ms,c.user,c.protocol,c.mailbox,c.client_ip,c.user_agent,c.device_id,c.device_type,c.software,c.client_mode,c.front_ends,c.back_ends," +
                "c.requests,c.successes,c.failures,c.slow,c.first_success_ms,c.last_success_ms,c.first_failure_ms,c.last_failure_ms,c.total_ms,c.max_ms,c.actions,c.first_error,c.last_error,c.backend,c.connections,s.data" +
                where + " ORDER BY c.start_ms,c.id,s.time_ms,s.rowid;", f.P);
            foreach (var batch in SessionBatches(sessions, q.WorkingBudgetBytes / 2))
            {
                long inputBytes = batch.Sum(x => x.Bytes);
                var parsed = OrderedWork(batch, q, input => input.Bytes, input =>
                {
                    input.Steps = new List<Step>();
                    foreach (var data in input.Data) ParseSteps(data, input.Steps);
                    input.Data.Clear();
                    return input;
                }, inputBytes).ToList();
                var files = LoadFiles(store, parsed.SelectMany(x => x.Steps).SelectMany(x => x.Links).Select(x => (long)x[1]));
                foreach (var output in OrderedWork(parsed, q, input => input.Bytes, input => new { Row = SessionRow(input, q, local, files), Utc = L(input.Row[1]) }, inputBytes))
                {
                    var row = output.Row;
                    set.Rows.Add(row, output.Utc, 0);
                    string outcome = S(row[3]);
                    if (outcome != "OK" && outcome != "OK (slow)") set.SessionsWithFailures++;
                    if (SessionSeverity(outcome) < 9)
                    {
                        set.FailedSessionCount++;
                        var summary = (object[])row.Clone();
                        summary[25] = null;
                        KeepTopRow(set.FailureSample, summary, (a, b) =>
                        {
                            int c = SessionSeverity(S(a[3])).CompareTo(SessionSeverity(S(b[3])));
                            return c != 0 ? c : L(b[11]).CompareTo(L(a[11]));
                        });
                    }
                }
            }
            return set;
        }

        static object[] SessionRow(SessionInput input, ReportRequest q, Func<long, object> local, Dictionary<long, string[]> files, bool milliseconds = false)
        {
            var r = input.Row;
            long id = L(r[0]), start = L(r[1]), end = L(r[2]), requests = L(r[14]), successes = L(r[15]), failures = L(r[16]), slow = L(r[17]);
            long backEndErrors = 0;
            string backend = S(r[27]);
            if (backend != null) { int bar = backend.IndexOf('|'); long.TryParse(bar > 0 ? backend.Substring(0, bar) : backend, NumberStyles.Integer, CultureInfo.InvariantCulture, out backEndErrors); }
            string protocol = S(r[4]), agent = S(r[7]);
            var tl = Timeline(input.Steps, local, protocol, files, milliseconds);
            long shownFailures = failures + backEndErrors;
            string outcome;
            if (tl.Rows.Count > 0)
            {
                shownFailures = Math.Max(tl.Failed, failures);
                outcome = SessionOutcome(tl.Failed, tl.Successes, slow, tl.FirstSuccess, tl.LastSuccess, tl.FirstFailure, tl.LastFailure, q.RecoveryWindowMs);
            }
            else outcome = SessionOutcome(failures + backEndErrors, successes, slow, L(r[18]), L(r[19]), L(r[20]), L(r[21]), q.RecoveryWindowMs);
            return new object[] {
                local(start), local(end), TimeUtil.Duration((end - start) / 1000.0), outcome, S(r[3]), protocol, ClientFamily(protocol, agent, S(r[9])),
                (S(r[6]) ?? "").Replace(",", ", "), (S(r[12]) ?? "").Replace(",", ", "), (S(r[13]) ?? "").Replace(",", ", "),
                requests, shownFailures, slow, requests > 0 ? (object)(L(r[22]) / requests) : null, L(r[23]), Top(S(r[24]), 4),
                S(r[26]), S(r[10]), S(r[11]) == "0" ? null : S(r[11]), S(r[8]), S(r[5]), L(r[28]) > 0 ? (object)L(r[28]) : null, S(r[25]), agent, id, tl.Rows };
        }

        static void ParseSteps(string json, List<Step> list)
        {
            if (string.IsNullOrEmpty(json)) return;
            try
            {
                using (var doc = JsonDocument.Parse(json))
                {
                    foreach (var e in doc.RootElement.EnumerateArray())
                    {
                        Func<int, string> s = i => e.GetArrayLength() > i && e[i].ValueKind == JsonValueKind.String ? e[i].GetString() : null;
                        Func<int, long> n = i => e.GetArrayLength() > i && e[i].ValueKind == JsonValueKind.Number ? e[i].GetInt64() : 0;
                        var step = new Step
                        {
                            T = n(0), T2 = n(1), Front = s(2), Back = s(3), Action = s(4), Status = (int)n(5), Count = n(6), AvgMs = n(7), MaxMs = n(8),
                            Failures = n(9), Detail = s(10), RequestId = s(11), Source = s(12),
                            Batch = e.GetArrayLength() > 13 && e[13].ValueKind == JsonValueKind.True
                        };
                        // Log file of the step (older steps have none).
                        if (n(14) > 0) step.Links.Add(new object[] { step.Source == "BE" ? "Back end" : "Front end", n(14), s(15), s(16) });
                        list.Add(step);
                    }
                }
            }
            catch (Exception error) when (error is JsonException || error is FormatException || error is InvalidOperationException || error is OverflowException)
            { throw new System.IO.InvalidDataException("Malformed client session timeline JSON.", error); }
        }

        sealed class TimelineResult
        {
            public List<object[]> Rows = new List<object[]>();
            public long Failed, Successes, FirstFailure, LastFailure, FirstSuccess, LastSuccess;
        }

        /// <summary>
        /// Timeline rows [time, path, action, status, count, average ms, max ms, detail, kind, until, request id, logs]
        /// and the outcome counters of the session. logs = [[role, server, kind, path, search text, second search text]].
        /// A back-end line completes its front-end request: same RequestId (MAPI), or same action within 5 seconds
        /// (ActiveSync, whose back-end log has no RequestId). An HTTP 200 whose back end reports an error is then a failure.
        /// </summary>
        static TimelineResult Timeline(List<Step> raw, Func<long, object> local, string protocol, Dictionary<long, string[]> files, bool milliseconds = false)
        {
            var result = new TimelineResult();
            if (raw == null || raw.Count == 0) return result;
            bool imap = string.Equals(protocol, "Imap4", StringComparison.OrdinalIgnoreCase), pop = string.Equals(protocol, "Pop3", StringComparison.OrdinalIgnoreCase);
            raw = raw.OrderBy(x => x.T).ThenBy(x => x.Source ?? "", StringComparer.Ordinal).ToList();
            var byRequest = new Dictionary<string, Step>(StringComparer.OrdinalIgnoreCase);
            var frontEnd = new List<Step>();
            foreach (var s in raw)
                if (!s.Batch && s.Source != "BE")
                {
                    frontEnd.Add(s);
                    if (s.RequestId != null) byRequest[s.RequestId] = s;
                }
            var matched = new HashSet<Step>();
            var merged = new List<Step>();
            foreach (var s in raw)
            {
                Step fe = null;
                if (s.Source == "BE")
                {
                    if (s.RequestId != null) byRequest.TryGetValue(s.RequestId, out fe);
                    else fe = frontEnd.Where(x => !matched.Contains(x) && string.Equals(x.Action, s.Action, StringComparison.OrdinalIgnoreCase) && Math.Abs(x.T - s.T) <= 5000)
                                      .OrderBy(x => Math.Abs(x.T - s.T)).FirstOrDefault();
                }
                if (fe != null)
                {
                    matched.Add(fe);
                    fe.Detail = string.IsNullOrEmpty(fe.Detail) ? "Back end: " + s.Detail : fe.Detail + " | Back end: " + s.Detail;
                    if (fe.Back == null) fe.Back = s.Back;
                    fe.Failures = Math.Max(fe.Failures, s.Failures);
                    foreach (var link in s.Links) fe.Links.Add(new object[] { "Back end", link[1], link[2], link[3] });
                    continue;
                }
                var last = merged.Count > 0 ? merged[merged.Count - 1] : null;
                if (s.Batch && last != null && last.Batch && last.Front == s.Front && last.Back == s.Back)
                {
                    long total = last.AvgMs * last.Count + s.AvgMs * s.Count;
                    last.Count += s.Count; last.AvgMs = last.Count > 0 ? total / last.Count : 0; last.MaxMs = Math.Max(last.MaxMs, s.MaxMs);
                    last.T2 = Math.Max(last.T2, s.T2); last.Failures += s.Failures;
                    last.Action = MergeActions(last.Action, s.Action);
                    foreach (var link in s.Links) if (!last.Links.Any(x => (long)x[1] == (long)link[1])) last.Links.Add(link);
                    continue;
                }
                merged.Add(s);
            }
            foreach (var s in merged)
            {
                if (s.Failures > 0)
                {
                    result.Failed += s.Failures;
                    if (result.FirstFailure == 0 || s.T < result.FirstFailure) result.FirstFailure = s.T;
                    result.LastFailure = Math.Max(result.LastFailure, s.T);
                }
                else if (s.Batch || !Neutral.Contains(s.Action ?? ""))
                {
                    result.Successes += s.Count;
                    if (result.FirstSuccess == 0 || s.T < result.FirstSuccess) result.FirstSuccess = s.T;
                    result.LastSuccess = Math.Max(result.LastSuccess, Math.Max(s.T, s.T2));
                }
                string path = s.Front != null && s.Back != null && !string.Equals(s.Front, s.Back, StringComparison.OrdinalIgnoreCase) ? s.Front + " > " + s.Back : s.Front ?? s.Back ?? "";
                string kind = s.Failures > 0 ? "fail" : s.Batch ? "batch" : s.Source == "BE" ? "backend" : "ok";
                string action = s.Batch ? s.Count + " successful requests: " + s.Action : s.Action;
                object until = null;
                if (s.Batch && s.T2 > s.T) { object t2 = local(s.T2); if (t2 != null) until = (milliseconds ? DateTimeOffset.FromUnixTimeMilliseconds(L(t2)) : DateTimeOffset.FromUnixTimeSeconds(L(t2))).UtcDateTime.ToString("HH:mm:ss", CultureInfo.InvariantCulture); }
                object status = s.Status > 0 ? (object)(long)s.Status : null;
                // IMAP and POP have no HTTP status: show their own result.
                if (imap || pop) status = s.Batch ? null : (object)(s.Failures > 0 ? (imap ? "NO" : "-ERR") : (imap ? "OK" : "+OK"));
                var logs = new List<object[]>();
                foreach (var link in s.Links)
                {
                    string[] file;
                    if (!files.TryGetValue((long)link[1], out file)) continue;
                    logs.Add(new object[] { link[0], file[0], file[1], file[2], link[2], link[3] });
                }
                result.Rows.Add(new object[] { local(s.T), path, action, status, s.Count, s.AvgMs, s.MaxMs, s.Detail, kind, until, s.Batch ? null : s.RequestId, logs });
            }
            return result;
        }

        static string MergeActions(string a, string b)
        {
            var counts = new Dictionary<string, long>(StringComparer.Ordinal);
            foreach (var text in new[] { a, b })
                foreach (var part in (text ?? "").Split(new[] { ", " }, StringSplitOptions.RemoveEmptyEntries))
                {
                    int x = part.LastIndexOf(" x", StringComparison.Ordinal);
                    long n;
                    if (x > 0 && long.TryParse(part.Substring(x + 2), NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) { long v; counts.TryGetValue(part.Substring(0, x), out v); counts[part.Substring(0, x)] = v + n; }
                }
            return string.Join(", ", counts.OrderByDescending(k => k.Value).Select(k => k.Key + " x" + k.Value.ToString(CultureInfo.InvariantCulture)));
        }

        // ------------------------------------------------------------------ clients and devices

        static Dataset BuildClients(Store store, ReportRequest q, string d0, string d1, Func<long, object> local)
        {
            var set = new Dataset("clients", "Clients", q.Scratch);
            foreach (var n in new[] { "User:text", "Protocol:text", "Client:text", "Device type:text", "Device ID:text", "Client IPs:text", "Servers:text",
                "Requests:num", "Failures:num", "Active days:num", "First seen:time", "Last seen:time", "User agent:text" })
            { var x = n.Split(':'); set.Add(x[0], x[1]); }
            var f = new Sql(); f.P["@d0"] = d0; f.P["@d1"] = d1;
            string where = " FROM access_client WHERE day >= @d0 AND day <= @d1" + f.Users(q.Users, "user") + ServerFilter(q.Servers, f.P, "','||COALESCE(servers,'')||','");
            foreach (var r in Rows(store, "SELECT user, protocol, user_agent, device_id, MAX(device_type), group_concat(DISTINCT client_ip), group_concat(DISTINCT servers), SUM(requests), SUM(failures), COUNT(DISTINCT day), MIN(first_ms), MAX(last_ms)" +
                where + " GROUP BY user, protocol, user_agent, device_id ORDER BY user, SUM(requests) DESC;", f.P))
            {
                string protocol = S(r[1]), agent = S(r[2]), device = S(r[3]);
                var ips = (S(r[5]) ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).Where(x => x.Length > 0).Distinct().ToList();
                var servers = (S(r[6]) ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(x => x).ToList();
                set.Rows.Add(new object[] { S(r[0]), protocol, ClientFamily(protocol, agent, S(r[4])), S(r[4]), string.IsNullOrEmpty(device) ? null : device,
                    ips.Count > 6 ? string.Join(", ", ips.Take(6)) + " (+" + (ips.Count - 6) + ")" : string.Join(", ", ips), string.Join(", ", servers),
                    L(r[7]), L(r[8]), L(r[9]), local(L(r[10])), local(L(r[11])), string.IsNullOrEmpty(agent) ? null : agent });
            }
            return set;
        }

        // ------------------------------------------------------------------ operations

        static Dataset BuildOperations(Store store, ReportRequest q, string d0, string d1)
        {
            var set = new Dataset("operations", "Operations");
            foreach (var n in new[] { "Protocol:text", "Operation:text", "Requests:num", "Share of protocol (%):num", "Failures:num", "Failure rate (%):num",
                "Slow:num", "Average (ms):num", "Max (ms):num", "Servers:text" })
            { var x = n.Split(':'); set.Add(x[0], x[1]); }
            var f = new Sql(); f.P["@d0"] = d0; f.P["@d1"] = d1;
            string where = " FROM access_action WHERE day >= @d0 AND day <= @d1" + f.Servers(q.Servers, "server");
            var perProtocol = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
            foreach (var r in Rows(store, "SELECT protocol, SUM(requests)" + where + " GROUP BY protocol;", f.P)) perProtocol[S(r[0]) ?? ""] = L(r[1]);
            foreach (var r in Rows(store, "SELECT protocol, action, SUM(requests), SUM(failures), SUM(slow), SUM(total_ms), MAX(max_ms), group_concat(DISTINCT server)" + where +
                " GROUP BY protocol, action ORDER BY protocol, SUM(requests) DESC;", f.P))
            {
                long requests = L(r[2]), failures = L(r[3]), all;
                perProtocol.TryGetValue(S(r[0]) ?? "", out all);
                set.Rows.Add(new object[] { S(r[0]), S(r[1]), requests, all > 0 ? (object)Math.Round(100.0 * requests / all, 1) : null, failures,
                    requests > 0 ? (object)Math.Round(100.0 * failures / requests, 1) : null, L(r[4]), requests > 0 ? (object)(L(r[5]) / requests) : null, L(r[6]),
                    string.Join(", ", (S(r[7]) ?? "").Split(',').OrderBy(x => x)) });
            }
            return set;
        }
    }
}
