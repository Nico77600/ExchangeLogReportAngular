// =============================================================================
//  Exchange Log Report - engine, part 5: client sessions and back-end correlation
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 2.0.0
//
//  A client session is what one client did for one user on one day, until it
//  stays idle longer than SessionIdleMinutes. Its key depends on the protocol:
//    Mapi       user | client address | mailbox GUID | client instance (X-ClientInfo of Outlook)
//    Eas        user | user agent (device model and build; mobile devices change address all the time)
//    Imap4/Pop3 user | client address
//    others     user | client address | user agent
//  The same key is computed from the front-end logs (HttpProxy, IIS) and from the
//  back-end logs, which is how one session gathers several log files:
//    MapiBackEnd  Logging\MapiHttp\Mailbox: Outlook version, cached mode, MAPI status codes
//                 (an HTTP 200 can carry a MAPI failure), same RequestId as HttpProxy
//    EasBackEnd   W3SVC2 (Exchange Back End): ActiveSync errors hidden behind HTTP 200
//                 (DeviceNotProvisioned, UserDisabledForSync...), access state, EAS version
//    Imap4/Pop3   front end (client address, logon, proxy target) and back end (every
//                 command and its result). Back-end connections only know the front-end
//                 server: they are attached to the matching session at the end of the run.
//  Sessions keep their counters, plus a timeline ("steps") per log file: every
//  failure, slow request and milestone (Connect, Provision, logon...) and the first
//  requests of the session are kept one by one; the other successes are folded into
//  "batch" steps. Long healthy sessions stay small, problems keep their detail.
//  The back-end logs are parsed by the parse threads (records only); the sessions
//  are only touched by the apply thread, and written once per batch of files.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    /// <summary>One step of a session timeline (one request, or a batch of successful requests).</summary>
    sealed class SessionStep
    {
        public long T, T2, TotalMs, MaxMs, FileId;
        public string Front, Back, Action, Detail, RequestId, Source = "FE", Needle, Needle2;
        public int Status, Count = 1, Failures;
        public bool Batch;
        public Dictionary<string, int> BatchActions;
    }

    /// <summary>Steps of one session written for one log file (MaxSessionSteps applies per file).</summary>
    sealed class FileSteps { public int Count; public SessionStep Last; }

    sealed class ClientSession
    {
        public long Id;
        public string Key, Day, User, Protocol, Mailbox, UserAgent, DeviceId, DeviceType, Software, Mode, FirstError, LastError, BackEndNote;
        public long Start = long.MaxValue, End, Requests, Successes, Failures, Slow, FirstSuccess, LastSuccess, FirstFailure, LastFailure;
        public long TotalMs, MaxMs, BytesIn, BytesOut, Connections, BackEndErrors;
        public SortedSet<string> Fronts = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        public SortedSet<string> Backs = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        public List<string> Ips = new List<string>();
        public Dictionary<string, long> Actions = new Dictionary<string, long>(StringComparer.Ordinal);
        public Dictionary<string, long> Statuses = new Dictionary<string, long>(StringComparer.Ordinal);
        public List<SessionStep> Steps = new List<SessionStep>();
        public Dictionary<long, FileSteps> PerFile = new Dictionary<long, FileSteps>();
        public List<long> Absorbed = new List<long>();
        public bool LastWasFailure, Dead;
    }

    /// <summary>A MAPI or ActiveSync back-end line of a real user, as read by a parse thread.</summary>
    sealed class BackEndLine
    {
        public long T, Ms;
        public int Status;
        public bool Failed;
        public string User, Ip, MailboxGuid, Instance, Type, Cafe, Software, Version, Mode, Text, RequestId;
        public string Agent, Device, Error, Access, Needle, Needle2, HasCmd;
    }

    public sealed partial class Collector
    {
        readonly Dictionary<string, List<ClientSession>> _sessions = new Dictionary<string, List<ClientSession>>(StringComparer.Ordinal);
        readonly Dictionary<string, List<ClientSession>> _byUser = new Dictionary<string, List<ClientSession>>(StringComparer.Ordinal);
        readonly Dictionary<string, string> _accounts = new Dictionary<string, string>(StringComparer.Ordinal);
        readonly List<DeferredBackEnd> _deferred = new List<DeferredBackEnd>();
        SqliteTransaction _tx;   // transaction in progress (session lookups must run inside it)

        static readonly HashSet<string> Milestones = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "Connect", "Disconnect", "Bind", "Unbind", "Provision", "FolderSync", "OPTIONS", "login", "authenticate", "logout",
            "user", "pass", "quit", "POST auth.owa", "GET logoff.owa", "CreateItem", "SendMail", "SmartReply", "SmartForward", "Logon"
        };
        static readonly Regex EasLogToken = new Regex(@"(?:^|_)(Error|As|Ver1|PrxFrom):([^_&]*)", RegexOptions.Compiled);
        static readonly Regex ProxyTargetRx = new Regex(@"Proxy:([^:;""]+)", RegexOptions.Compiled);
        static readonly Regex TaggedResultRx = new Regex(@"^[A-Za-z]*\d+\s+(.*)$", RegexOptions.Compiled);

        // ================================================================ identities

        /// <summary>Accounts already known as "domain\sam": IMAP, POP and back-end logs often give "sam" or the UPN only.</summary>
        void LoadAccounts()
        {
            // One seek per user in ix_usage_user (user, day): DISTINCT read the whole index, one entry per user, server,
            // protocol and day of the retention.
            using (var c = _store.Command("SELECT user FROM access_usage WHERE user > @after ORDER BY user LIMIT 1;"))
            {
                var after = c.Parameters.Add("@after", SqliteType.Text);
                after.Value = "";
                while (true)
                {
                    var user = c.ExecuteScalar() as string;
                    if (user == null) break;
                    if (user.IndexOf('\\') > 0) LearnAccount(user);
                    after.Value = user;
                }
            }
        }

        void LearnAccount(string user)
        {
            string bare = Identity.Bare(user), known;
            if (string.IsNullOrEmpty(bare)) return;
            if (!_accounts.TryGetValue(bare, out known)) _accounts[bare] = user;
            else if (known != null && !string.Equals(known, user, StringComparison.Ordinal)) _accounts[bare] = null;   // two domains: ambiguous
        }

        /// <summary>"sam" or "sam@upn-suffix" becomes "domain\sam" when that account is known (and not ambiguous).</summary>
        string Canonical(string user)
        {
            if (user == null) return null;
            if (user.IndexOf('\\') >= 0) { LearnAccount(user); return user; }
            string canon;
            return _accounts.TryGetValue(Identity.Bare(user), out canon) && canon != null ? canon : user;
        }

        // ================================================================ request enrichment (parse threads)

        /// <summary>Protocol action of a request: ActiveSync command, MAPI request type, OWA/EWS action, else method and last URL segment.</summary>
        void Enrich(AccessRecord r, string query, string clientRequestId, string anchor)
        {
            string protocol = r.Protocol ?? "";
            if (protocol.Equals("Eas", StringComparison.OrdinalIgnoreCase) || (r.Url != null && r.Url.StartsWith("/Microsoft-Server-ActiveSync", StringComparison.OrdinalIgnoreCase)))
            {
                string cmd = Identity.QueryValue(query, "Cmd");
                if (cmd != null) r.Action = cmd;
                else if (string.Equals(r.Method, "OPTIONS", StringComparison.OrdinalIgnoreCase)) r.Action = "OPTIONS";
                r.DeviceId = Identity.QueryValue(query, "DeviceId");
                r.DeviceType = Identity.QueryValue(query, "DeviceType");
            }
            else if (protocol.Equals("Mapi", StringComparison.OrdinalIgnoreCase))
            {
                string rt = Identity.Token(clientRequestId, "RT");
                if (rt != null) r.Action = rt;
                r.ClientInstance = Identity.ClientInstance(Identity.Token(clientRequestId, "CI"));
                r.MailboxGuid = Identity.MailboxGuid(anchor) ?? Identity.MailboxGuid(Identity.QueryValue(query, "MailboxId"));
            }
            if (string.IsNullOrEmpty(r.Action))
            {
                string url = (r.Url ?? "").TrimEnd('/');
                int slash = url.LastIndexOf('/');
                string last = slash >= 0 ? url.Substring(slash + 1) : url;
                r.Action = ((r.Method ?? "") + " " + (last.Length == 0 ? "/" : last)).Trim();
            }
            r.Action = Identity.Cap(r.Action, 80);
        }

        static string Describe(AccessRecord r)
        {
            var parts = new List<string>();
            string status = r.Status.ToString(CultureInfo.InvariantCulture);
            if (r.SubStatus.HasValue && r.SubStatus.Value > 0) status += "." + r.SubStatus.Value.ToString(CultureInfo.InvariantCulture);
            if (r.Status > 0 && r.Source != "Imap4" && r.Source != "Pop3") parts.Add("HTTP " + status);
            if (!string.IsNullOrEmpty(r.ErrorCode)) parts.Add(r.ErrorCode);
            if (r.Win32.HasValue && r.Win32.Value > 0 && (r.ErrorCode == null || r.ErrorCode.IndexOf(r.Win32.Value.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal) < 0))
                parts.Add("Win32 " + r.Win32.Value.ToString(CultureInfo.InvariantCulture));
            if (r.BackEndStatus.HasValue && r.BackEndStatus.Value != r.Status) parts.Add("back end " + r.BackEndStatus.Value.ToString(CultureInfo.InvariantCulture));
            return Identity.Cap(string.Join(", ", parts), 300);
        }

        // ================================================================ sessions in memory (apply thread)

        static string SessionKey(string day, string user, string protocol, string ip, string agent, string device, string mailboxGuid, string instance)
        {
            return day + "|" + user + "|" + SessionKeyRest(protocol, ip, agent, device, mailboxGuid, instance);
        }

        /// <summary>Session key after "day|user|" (computed by the parse threads; the account is made canonical by the apply thread).</summary>
        static string SessionKeyRest(string protocol, string ip, string agent, string device, string mailboxGuid, string instance)
        {
            string p = protocol ?? "Other";
            switch (p.ToLowerInvariant())
            {
                // ActiveSync: the user agent identifies the device model and OS build; OPTIONS requests carry no DeviceId.
                case "eas": return "Eas|ua:" + Identity.Cap(agent, 120);
                case "mapi": return "Mapi|" + ip + "|" + mailboxGuid + "|" + instance;
                case "imap4":
                case "pop3": return p + "|" + ip;
                default: return p + "|" + ip + "|" + Identity.Cap(agent, 120);
            }
        }

        void ResetSessions()
        {
            _sessions.Clear();
            _byUser.Clear();
            // The database is the reference again: the sessions committed by this run are found there.
            _storedDays.Clear();
            try { LoadStoredDays(); } catch (SqliteException) { }
        }

        ClientSession NewSession(string key, string day, string user, string protocol)
        {
            var s = new ClientSession { Key = key, Day = day, User = user, Protocol = protocol };
            Index(s);
            return s;
        }

        void Index(ClientSession s)
        {
            string k = s.Day + "|" + s.User + "|" + s.Protocol;
            List<ClientSession> list;
            if (!_byUser.TryGetValue(k, out list)) { list = new List<ClientSession>(); _byUser[k] = list; }
            list.Add(s);
        }

        void Unindex(ClientSession s)
        {
            List<ClientSession> list;
            string k = s.Day + "|" + s.User + "|" + s.Protocol;
            if (!_byUser.TryGetValue(k, out list)) return;
            list.Remove(s);
            if (list.Count == 0) _byUser.Remove(k);
        }

        /// <summary>Session of a key that contains the time t (with the idle gap); bridging sessions are merged; a new one otherwise.</summary>
        ClientSession FindSession(string key, long t, Func<ClientSession> create)
        {
            List<ClientSession> list;
            if (!_sessions.TryGetValue(key, out list))
            {
                // Only the days that have sessions in the database are looked up there (a first collection, or a new day,
                // creates its sessions without one query per key).
                int bar = key.IndexOf('|');
                list = bar > 0 && _storedDays.Contains(key.Substring(0, bar)) ? LoadSessions(key) : new List<ClientSession>();
                _sessions[key] = list;
            }
            long idle = _o.SessionIdleMs;
            ClientSession keep = null;
            int hits = 0;
            foreach (var s in list)
            {
                if (t < s.Start - idle || t > s.End + idle) continue;
                hits++;
                // The oldest stored session survives a merge.
                if (keep == null || Older(s, keep)) keep = s;
            }
            if (keep == null) { var created = create(); list.Add(created); return created; }
            if (hits > 1)
            {
                // t fills the gap between sessions: they become one.
                foreach (var drop in list.Where(s => !ReferenceEquals(s, keep) && t >= s.Start - idle && t <= s.End + idle).ToList())
                {
                    Merge(keep, drop);
                    list.Remove(drop);
                    Unindex(drop);
                }
            }
            return keep;
        }

        static bool Older(ClientSession a, ClientSession b)
        {
            int ra = a.Id > 0 ? 0 : 1, rb = b.Id > 0 ? 0 : 1;
            return ra != rb ? ra < rb : a.Id < b.Id;
        }

        void Merge(ClientSession into, ClientSession from)
        {
            if (ReferenceEquals(into, from)) return;
            from.Dead = true;
            if (from.Id > 0) into.Absorbed.Add(from.Id);
            into.Absorbed.AddRange(from.Absorbed);
            into.Start = Math.Min(into.Start, from.Start); into.End = Math.Max(into.End, from.End);
            into.Requests += from.Requests; into.Successes += from.Successes; into.Failures += from.Failures; into.Slow += from.Slow;
            into.TotalMs += from.TotalMs; into.MaxMs = Math.Max(into.MaxMs, from.MaxMs); into.BytesIn += from.BytesIn; into.BytesOut += from.BytesOut;
            into.Connections += from.Connections; into.BackEndErrors += from.BackEndErrors;
            into.FirstSuccess = MinPositive(into.FirstSuccess, from.FirstSuccess); into.LastSuccess = Math.Max(into.LastSuccess, from.LastSuccess);
            if (from.FirstFailure > 0 && (into.FirstFailure == 0 || from.FirstFailure < into.FirstFailure)) { into.FirstFailure = from.FirstFailure; into.FirstError = from.FirstError ?? into.FirstError; }
            if (from.LastFailure > into.LastFailure) { into.LastFailure = from.LastFailure; into.LastError = from.LastError ?? into.LastError; }
            foreach (var x in from.Fronts) into.Fronts.Add(x);
            foreach (var x in from.Backs) into.Backs.Add(x);
            foreach (var x in from.Ips) if (!into.Ips.Contains(x)) into.Ips.Add(x);
            foreach (var kv in from.Actions) Inc(into.Actions, kv.Key, kv.Value);
            foreach (var kv in from.Statuses) Inc(into.Statuses, kv.Key, kv.Value);
            into.Mailbox = into.Mailbox ?? from.Mailbox; into.UserAgent = into.UserAgent ?? from.UserAgent; into.DeviceId = into.DeviceId ?? from.DeviceId;
            into.DeviceType = into.DeviceType ?? from.DeviceType; into.Software = into.Software ?? from.Software; into.Mode = into.Mode ?? from.Mode;
            into.BackEndNote = into.BackEndNote ?? from.BackEndNote;
            into.Steps.AddRange(from.Steps);
            from.Steps.Clear();
            if (_batch != null) { _batch.Touched.Remove(from); _batch.Touched.Add(into); }
        }

        static long MinPositive(long a, long b) { return a <= 0 ? b : b <= 0 ? a : Math.Min(a, b); }

        static void Inc(Dictionary<string, long> d, string key, long n)
        {
            if (string.IsNullOrEmpty(key)) return;
            long v; d.TryGetValue(key, out v); d[key] = v + n;
        }

        struct JoinEntry { public string Key; public long Value; public int Index; }

        // Count descending, then key (ordinal), then the dictionary order: the order of a stable sort on count and key.
        static readonly Comparison<JoinEntry> JoinOrder = (a, b) =>
        {
            int c = b.Value.CompareTo(a.Value);
            if (c == 0) c = string.CompareOrdinal(a.Key, b.Key);
            return c != 0 ? c : a.Index.CompareTo(b.Index);
        };

        // Join (apply thread): the entries and the text, reused from one session to the next.
        readonly List<JoinEntry> _joinEntries = new List<JoinEntry>();
        readonly StringBuilder _joinText = new StringBuilder();

        /// <summary>"key=count;..." by count descending then key (ordinal); null when empty.</summary>
        string Join(Dictionary<string, long> d)
        {
            if (d.Count == 0) return null;
            var entries = _joinEntries;
            entries.Clear();
            foreach (var kv in d) entries.Add(new JoinEntry { Key = kv.Key, Value = kv.Value, Index = entries.Count });
            entries.Sort(JoinOrder);
            var text = _joinText.Clear();
            for (int i = 0; i < entries.Count; i++)
            {
                if (i > 0) text.Append(';');
                text.Append(entries[i].Key.Replace(";", ",").Replace("=", ":")).Append('=').Append(entries[i].Value.ToString(CultureInfo.InvariantCulture));
            }
            entries.Clear();
            return text.ToString();
        }

        static void Split(string text, Dictionary<string, long> d)
        {
            if (string.IsNullOrEmpty(text)) return;
            foreach (var part in text.Split(';'))
            {
                int eq = part.LastIndexOf('=');
                long n;
                if (eq > 0 && long.TryParse(part.Substring(eq + 1), NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) Inc(d, part.Substring(0, eq), n);
            }
        }

        SqliteCommand _loadSessions;

        List<ClientSession> LoadSessions(string key)
        {
            var list = new List<ClientSession>();
            if (_loadSessions == null || _loadSessions.Connection == null)
            {
                _loadSessions = _store.Command(@"SELECT id,day,start_ms,end_ms,user,protocol,mailbox,client_ip,user_agent,device_id,device_type,software,client_mode,front_ends,back_ends,
requests,successes,failures,slow,first_success_ms,last_success_ms,first_failure_ms,last_failure_ms,total_ms,max_ms,bytes_in,bytes_out,actions,statuses,
first_error,last_error,backend,connections FROM client_session WHERE skey=@k;");
                _loadSessions.Parameters.Add("@k", SqliteType.Text);
            }
            var c = _loadSessions;
            c.Transaction = _tx;
            c.Parameters[0].Value = key;
            using (var r = c.ExecuteReader())
            {
                Func<int, string> s = i => Packed.Text(r.GetValue(i));
                while (r.Read())
                {
                    var x = new ClientSession
                    {
                        Id = r.GetInt64(0), Key = key, Day = s(1), Start = r.GetInt64(2), End = r.GetInt64(3), User = s(4), Protocol = s(5), Mailbox = s(6),
                        UserAgent = s(8), DeviceId = s(9), DeviceType = s(10), Software = s(11), Mode = s(12),
                        Requests = r.GetInt64(15), Successes = r.GetInt64(16), Failures = r.GetInt64(17), Slow = r.GetInt64(18),
                        FirstSuccess = r.GetInt64(19), LastSuccess = r.GetInt64(20), FirstFailure = r.GetInt64(21), LastFailure = r.GetInt64(22),
                        TotalMs = r.GetInt64(23), MaxMs = r.GetInt64(24), BytesIn = r.GetInt64(25), BytesOut = r.GetInt64(26),
                        FirstError = s(29), LastError = s(30), Connections = r.GetInt64(32)
                    };
                    foreach (var ip in (s(7) ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)) x.Ips.Add(ip.Trim());
                    foreach (var f in (s(13) ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)) x.Fronts.Add(f.Trim());
                    foreach (var b in (s(14) ?? "").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)) x.Backs.Add(b.Trim());
                    Split(s(27), x.Actions); Split(s(28), x.Statuses);
                    string be = s(31);
                    if (be != null)
                    {
                        int bar = be.IndexOf('|');
                        long n;
                        if (bar > 0 && long.TryParse(be.Substring(0, bar), NumberStyles.Integer, CultureInfo.InvariantCulture, out n)) { x.BackEndErrors = n; x.BackEndNote = bar + 1 < be.Length ? be.Substring(bar + 1) : null; }
                    }
                    list.Add(x);
                    Index(x);
                }
            }
            return list;
        }

        /// <summary>
        /// Sessions already written and not touched by the files still to come are dropped from memory once the
        /// collection has moved on by more than two days (a long backfill stays small in memory). A session needed
        /// again is read back from the database.
        /// </summary>
        /// <summary>Session keys kept in memory before the old ones are evicted (lowered by the tests).</summary>
        public static int EvictAboveKeys = 20000;

        void EvictSessions(List<ParsedFile> files)
        {
            if (_sessions.Count < EvictAboveKeys || files.Count == 0) return;
            // Only the files that feed the sessions: the SMTP and message tracking files are read beside them (ParseSchedule) and may be
            // ahead in time; they would evict sessions that the next files still extend (read back from the database: same result, slower).
            long newest = 0;
            foreach (var p in files) if (p.Work.Group != 1 && p.Result.LastMs > newest) newest = p.Result.LastMs;
            if (newest == 0) return;
            // A request extends a session only within SessionIdleMinutes of its end, and the files are read in the order
            // of their last write: a session that ended hours before the newest line read no longer grows. An evicted
            // session is read again from the database if a later line needs it (back-end logs, late files).
            long limit = newest - Math.Max(6 * 3600000L, 4 * _o.SessionIdleMs);
            var drop = new List<string>();
            foreach (var kv in _sessions)
            {
                bool old = true;
                foreach (var s in kv.Value) if (s.Id == 0 || s.End >= limit || s.Steps.Count > 0 || s.Absorbed.Count > 0) { old = false; break; }
                if (old) drop.Add(kv.Key);
            }
            foreach (var k in drop)
            {
                foreach (var s in _sessions[k]) { Unindex(s); _storedDays.Add(s.Day); }
                _sessions.Remove(k);
            }
        }

        /// <summary>Days that have client sessions in the database and not only in memory.</summary>
        readonly HashSet<string> _storedDays = new HashSet<string>(StringComparer.Ordinal);

        void LoadStoredDays()
        {
            // A session key starts with its day: one seek per stored day in ix_session_key. SELECT DISTINCT day read
            // every session (24 s at the start of each collection on a hard disk of the lab).
            using (var c = _store.Command("SELECT skey FROM client_session WHERE skey > @after ORDER BY skey LIMIT 1;"))
            {
                var after = c.Parameters.Add("@after", SqliteType.Text);
                after.Value = "";
                for (int guard = 0; guard < 100000; guard++)
                {
                    var key = c.ExecuteScalar() as string;
                    if (key == null) break;
                    int bar = key.IndexOf('|');
                    string day = bar > 0 ? key.Substring(0, bar) : key;
                    _storedDays.Add(day);
                    after.Value = day + "}";   // '}' sorts right after '|': past every key of this day
                }
            }
        }

        static void Extend(ClientSession s, long t)
        {
            if (t < s.Start) s.Start = t;
            if (t > s.End) s.End = t;
        }

        void Touch(ClientSession s) { _batch.Touched.Add(s); }

        void AddToSession(ApplyFile f, AccessRecord r, bool failure, bool slow)
        {
            if (r.FromBackEnd && r.Session == null) return;
            var s = r.Session;
            if (s == null)
            {
                string day = r.Day;
                string key = day + "|" + r.User + "|" + r.KeyRest;
                s = FindSession(key, r.TimeMs, () => NewSession(key, day, r.User, r.Protocol));
            }
            Touch(s);
            Extend(s, r.TimeMs);
            s.Requests++;
            if (failure)
            {
                s.Failures++;
                string why = r.Why;
                if (s.FirstFailure == 0 || r.TimeMs < s.FirstFailure) { s.FirstFailure = r.TimeMs; s.FirstError = (r.Action + ": " + why).Trim(' ', ':'); }
                if (r.TimeMs >= s.LastFailure) { s.LastFailure = r.TimeMs; s.LastError = (r.Action + ": " + why).Trim(' ', ':'); }
            }
            else
            {
                s.Successes++;
                s.FirstSuccess = MinPositive(s.FirstSuccess, r.TimeMs);
                if (r.TimeMs > s.LastSuccess) s.LastSuccess = r.TimeMs;
            }
            if (slow) s.Slow++;
            s.TotalMs += r.DurationMs; s.MaxMs = Math.Max(s.MaxMs, r.DurationMs); s.BytesIn += r.BytesIn; s.BytesOut += r.BytesOut;
            string front = r.FromBackEnd ? null : f.Server;
            string back = r.Back;
            if (front != null) s.Fronts.Add(front);
            if (back != null) s.Backs.Add(back);
            if (!r.FromBackEnd && r.ClientIp != null && s.Ips.Count < 20 && !s.Ips.Contains(r.ClientIp)) s.Ips.Add(r.ClientIp);
            if (s.UserAgent == null && r.UserAgent != null) s.UserAgent = r.Agent;
            if (s.DeviceId == null && r.DeviceId != null) s.DeviceId = r.DeviceId;
            if (s.DeviceType == null && r.DeviceType != null) s.DeviceType = r.DeviceType;
            if (s.Mailbox == null && r.Mailbox != null) s.Mailbox = r.Mailbox;
            Inc(s.Actions, r.Action ?? "?", 1);
            Inc(s.Statuses, StatusLabel(r), 1);
            string action = r.Action ?? "?";
            bool notable = failure || slow || s.Requests <= _o.SessionDetailRequests || Milestones.Contains(action) || s.LastWasFailure || r.Detail != null;
            // Most requests of a long session are folded into the last batch step: the step object is created only when it is kept.
            if (!FoldStep(s, f.FileId, r.TimeMs, front, back, action, failure ? 1 : 0, r.DurationMs, notable))
            {
                var step = new SessionStep
                {
                    T = r.TimeMs, T2 = r.TimeMs, Front = front, Back = back, Action = action, Status = r.Status, TotalMs = r.DurationMs, MaxMs = r.DurationMs,
                    Failures = failure ? 1 : 0, Detail = failure ? r.Why : slow ? "Slow request" : r.Detail, RequestId = r.RequestId, Source = r.FromBackEnd ? "BE" : "FE",
                    FileId = f.FileId, Needle = r.Needle ?? r.RequestId, Needle2 = r.Needle2
                };
                AddStep(s, step, notable);
            }
            s.LastWasFailure = failure;
        }

        /// <summary>
        /// The folding of AddStep for a step of one request (count 1) that is not created yet: true when the request was added to the last
        /// batch step of its file, false when AddStep must be called with the step (same rules, same order).
        /// </summary>
        bool FoldStep(ClientSession s, long fileId, long t, string front, string back, string action, int failures, long ms, bool notable)
        {
            FileSteps fs;
            if (!s.PerFile.TryGetValue(fileId, out fs)) return false;
            var last = fs.Last;
            bool full = fs.Count >= _o.MaxSegmentSteps && !(failures > 0 && fs.Count < 2 * _o.MaxSegmentSteps);
            if (notable && !full) return false;
            if (last == null || !last.Batch || last.Front != front || last.Back != back || t < last.T || !(full || t - last.T2 <= 900000)) return false;
            if (t > last.T2) last.T2 = t;
            last.Count += 1; last.Failures += failures; last.TotalMs += ms; last.MaxMs = Math.Max(last.MaxMs, ms);
            int n; last.BatchActions.TryGetValue(action, out n); last.BatchActions[action] = n + 1;
            return true;
        }

        // The texts of the HTTP statuses 100 to 599, as ToString gives them: no new string for every request.
        static readonly string[] StatusTexts = Enumerable.Range(100, 500).Select(n => n.ToString(CultureInfo.InvariantCulture)).ToArray();

        static string StatusLabel(AccessRecord r)
        {
            if (r.Source == "Imap4" || r.Source == "Pop3") return r.Status >= 400 ? "NO" : "OK";
            int status = r.Status;
            return status >= 100 && status < 600 ? StatusTexts[status - 100] : status.ToString(CultureInfo.InvariantCulture);
        }

        /// <summary>
        /// Adds a step to the timeline written for its log file: up to MaxSessionSteps steps per session and file
        /// (twice as many for failures), the other successes folded into the last batch step of that file.
        /// </summary>
        void AddStep(ClientSession s, SessionStep step, bool notable)
        {
            FileSteps fs;
            if (!s.PerFile.TryGetValue(step.FileId, out fs)) { fs = new FileSteps(); s.PerFile[step.FileId] = fs; }
            var last = fs.Last;
            bool full = fs.Count >= _o.MaxSegmentSteps && !(step.Failures > 0 && fs.Count < 2 * _o.MaxSegmentSteps);
            if (!notable || full)
            {
                if (last != null && last.Batch && last.Front == step.Front && last.Back == step.Back && step.T >= last.T && (full || step.T - last.T2 <= 900000))
                {
                    if (step.T > last.T2) last.T2 = step.T;
                    last.Count += step.Count; last.Failures += step.Failures; last.TotalMs += step.TotalMs; last.MaxMs = Math.Max(last.MaxMs, step.MaxMs);
                    int n; last.BatchActions.TryGetValue(step.Action, out n); last.BatchActions[step.Action] = n + step.Count;
                    return;
                }
                step.Batch = true;
                step.BatchActions = new Dictionary<string, int>(StringComparer.Ordinal) { { step.Action, step.Count } };
                step.Detail = null; step.RequestId = null; step.Needle = null; step.Needle2 = null;
            }
            s.Steps.Add(step);
            fs.Count++;
            fs.Last = step;
        }

        // ================================================================ sessions in the database

        void FlushSessions(SqliteTransaction tx, HashSet<ClientSession> touched)
        {
            if (touched.Count == 0) return;
            long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            foreach (var s in touched)
            {
                if (s.Dead) continue;
                var cmd = s.Id == 0 ? _writer.SessionInsert : _writer.SessionUpdate;
                cmd.Set(0, s.Key); cmd.Set(1, s.Day); cmd.Set(2, s.Start); cmd.Set(3, s.End); cmd.Set(4, s.User); cmd.Set(5, s.Protocol); cmd.Set(6, s.Mailbox);
                cmd.Set(7, s.Ips.Count == 0 ? null : string.Join(",", s.Ips.Take(10)));
                cmd.Set(8, s.UserAgent); cmd.Set(9, s.DeviceId); cmd.Set(10, s.DeviceType); cmd.Set(11, s.Software); cmd.Set(12, s.Mode);
                cmd.Set(13, s.Fronts.Count == 0 ? null : string.Join(",", s.Fronts));
                cmd.Set(14, s.Backs.Count == 0 ? null : string.Join(",", s.Backs));
                cmd.Set(15, s.Requests); cmd.Set(16, s.Successes); cmd.Set(17, s.Failures); cmd.Set(18, s.Slow);
                cmd.Set(19, s.FirstSuccess); cmd.Set(20, s.LastSuccess); cmd.Set(21, s.FirstFailure); cmd.Set(22, s.LastFailure);
                cmd.Set(23, s.TotalMs); cmd.Set(24, s.MaxMs); cmd.Set(25, s.BytesIn); cmd.Set(26, s.BytesOut);
                cmd.Set(27, Adaptive(Join(s.Actions))); cmd.Set(28, Adaptive(Join(s.Statuses)));
                cmd.Set(29, Identity.Cap(s.FirstError, 400)); cmd.Set(30, Identity.Cap(s.LastError, 400));
                cmd.Set(31, s.BackEndErrors > 0 || s.BackEndNote != null ? (object)(s.BackEndErrors.ToString(CultureInfo.InvariantCulture) + "|" + (s.BackEndNote ?? "")) : null);
                cmd.Set(32, s.Connections); cmd.Set(33, now);
                if (s.Id == 0) s.Id = Convert.ToInt64(cmd.Scalar(), CultureInfo.InvariantCulture);
                else { cmd.Set(34, s.Id); cmd.Run(); }
                foreach (var old in s.Absorbed)
                {
                    _writer.SessionRepoint.Set(0, s.Id); _writer.SessionRepoint.Set(1, old); _writer.SessionRepoint.Run();
                    _writer.SessionDelete.Set(0, old); _writer.SessionDelete.Run();
                }
                s.Absorbed.Clear();
                if (s.Steps.Count > 0)
                {
                    long first = long.MaxValue;
                    foreach (var x in s.Steps) if (x.T < first) first = x.T;
                    _writer.SessionStep.Set(0, s.Id); _writer.SessionStep.Set(1, first); _writer.SessionStep.Set(2, PackSteps(s.Steps));
                    _writer.SessionStep.Run();
                    s.Steps.Clear();
                }
                s.PerFile.Clear();
            }
            touched.Clear();
        }

        // Apply thread: the JSON of the steps of a session is written into this buffer (kept from one session to the next) and packed from it.
        readonly System.Buffers.ArrayBufferWriter<byte> _stepsBuffer = new System.Buffers.ArrayBufferWriter<byte>(4096);
        Utf8JsonWriter _stepsWriter;

        /// <summary>
        /// The stored steps: the same bytes as Pack(StepsJson(steps)). The writer fills the reused buffer and the UTF-8 it wrote is packed in one
        /// piece (the JSON is ASCII, the default encoder escapes the rest: decoding it to a string and encoding it again gives the same bytes).
        /// </summary>
        byte[] PackSteps(List<SessionStep> steps)
        {
            _stepsBuffer.Clear();
            if (_stepsWriter == null) _stepsWriter = new Utf8JsonWriter(_stepsBuffer); else _stepsWriter.Reset(_stepsBuffer);
            WriteSteps(_stepsWriter, steps);
            _stepsWriter.Flush();
            return PackUtf8(_stepsBuffer.WrittenSpan);
        }

        /// <summary>Steps as compact JSON: [t, t2, front, back, action, status, count, avgMs, maxMs, failures, detail, requestId, source, batch, fileId, needle, needle2].</summary>
        static string StepsJson(List<SessionStep> steps)
        {
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms)) WriteSteps(w, steps);
                return Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
            }
        }

        static void WriteSteps(Utf8JsonWriter w, List<SessionStep> steps)
        {
            w.WriteStartArray();
            foreach (var s in steps)
            {
                w.WriteStartArray();
                w.WriteNumberValue(s.T); w.WriteNumberValue(s.T2);
                Str(w, s.Front); Str(w, s.Back);
                Str(w, s.Batch ? string.Join(", ", s.BatchActions.OrderByDescending(x => x.Value).Select(x => x.Key + " x" + x.Value.ToString(CultureInfo.InvariantCulture))) : s.Action);
                w.WriteNumberValue(s.Status); w.WriteNumberValue(s.Count); w.WriteNumberValue(s.Count > 0 ? s.TotalMs / s.Count : 0); w.WriteNumberValue(s.MaxMs);
                w.WriteNumberValue(s.Failures); Str(w, s.Detail); Str(w, s.RequestId); Str(w, s.Source); w.WriteBooleanValue(s.Batch);
                w.WriteNumberValue(s.FileId); Str(w, s.Needle); Str(w, s.Needle2);
                w.WriteEndArray();
            }
            w.WriteEndArray();
        }

        static void Str(Utf8JsonWriter w, string s) { if (s == null) w.WriteNullValue(); else w.WriteStringValue(s); }

        // ================================================================ operations and clients (usage aggregates)

        sealed class ActionAcc { public string Day, Server, Protocol, Action; public long Requests, Failures, Slow, TotalMs, MaxMs; }

        sealed class ClientAcc
        {
            public string Day, Server, User, Protocol, Ip, Agent, DeviceId, DeviceType;
            public long Requests, Failures, First = long.MaxValue, Last;
        }

        void FlushActions()
        {
            var w = _writer.Action;
            foreach (var a in _batch.Actions.Values)
            {
                w.Set(0, a.Day); w.Set(1, a.Server); w.Set(2, a.Protocol); w.Set(3, a.Action); w.Set(4, a.Requests);
                w.Set(5, a.Failures); w.Set(6, a.Slow); w.Set(7, a.TotalMs); w.Set(8, a.MaxMs);
                w.Run();
            }
            _batch.Actions.Clear();
        }

        void FlushClients()
        {
            var w = _writer.Client;
            foreach (var a in _batch.Clients.Values)
            {
                w.Set(0, a.Day); w.Set(1, a.User); w.Set(2, a.Protocol); w.Set(3, a.Ip); w.Set(4, a.Agent); w.Set(5, a.DeviceId);
                w.Set(6, a.DeviceType); w.Set(7, a.Requests); w.Set(8, a.Failures); w.Set(9, a.First); w.Set(10, a.Last); w.Set(11, a.Server);
                w.Run();
            }
            _batch.Clients.Clear();
        }

        // ================================================================ MAPI over HTTP back end

        /// <summary>
        /// Logging\MapiHttp\Mailbox on the mailbox server. Requests are already counted from the front
        /// end; the back end adds the Outlook version and mode, the MAPI status of each request and the
        /// milestones (Connect, Disconnect, address book Bind / Unbind) with their back-end detail.
        /// </summary>
        long ParseMapiBackEnd(ParseContext c)
        {
            long offset = c.StartOffset;
            int iTime = -1, iReq = -1, iType = -1, iHttp = -1, iResp = -1, iStat = -1, iRet = -1, iLat = -1, iEmail = -1, iUser = -1, iMbx = -1, iIp = -1,
                iCafe = -1, iInfo = -1, iSoft = -1, iVer = -1, iMode = -1, iOps = -1, iErr = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iTime = m.Index("DateTime"); iReq = m.Index("RequestId"); iType = m.Index("RequestType"); iHttp = m.Index("HttpStatusCode");
                iResp = m.Index("ResponseCode"); iStat = m.Index("StatusCode"); iRet = m.Index("ReturnCode"); iLat = m.Index("TotalRequestLatency");
                iEmail = m.Index("AuthenticatedUserEmail"); iUser = m.Index("AuthenticatedUser"); iMbx = m.Index("MailboxId"); iIp = m.Index("ClientIP");
                iCafe = m.Index("SourceCafeServer"); iInfo = m.Index("MapiClientInfo"); iSoft = m.Index("ClientSoftware");
                iVer = m.Index("ClientSoftwareVersion"); iMode = m.Index("ClientMode"); iOps = m.Index("OperationSpecific"); iErr = m.Index("GenericErrors");
            };
            if (c.Map.Load(c.Fields)) bind();
            foreach (var line in LogReader.Lines(c.Path, offset, c.Memo != null ? c.Memo.Read : null))
            {
                offset = line.NextOffset;
                c.Result.Lines++;
                if (line.Length == 0) { Noise(c, "Empty line", 1); continue; }
                if (line.First == '#')
                {
                    if (line.StartsWith("#Fields:")) { string text = line.Text(); c.Map.Load(text); c.Fields = text; bind(); }
                    Noise(c, "Header", 1);
                    continue;
                }
                if (line.StartsWith("DateTime,")) { Noise(c, "Header", 1); continue; }
                if (iTime < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ',');
                long t;
                if (!c.Split.TryTime(iTime, out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t < _o.DetailCutoffMs) { Noise(c, "Older than detail retention (back end)", 1); continue; }
                var memo = c.Memo;
                string software = c.Split.GetCached(iSoft);
                if (_probeAgents != null && software != null && Remember(memo.ProbeAgents, software, x => _probeAgents.IsMatch(x))) { Noise(c, "Monitoring probe (client software)", 1); continue; }
                string raw = c.Split.GetCached(iEmail);
                string other = c.Split.GetCached(iUser);
                if (raw == null && other != null && !other.Equals("Anonymous", StringComparison.OrdinalIgnoreCase)) raw = other;
                string user = UserOf(memo, raw), ip = c.Split.GetCached(iIp);
                string why = ClientNoise(memo, user, null, null, ip, null, 200);
                if (why != null) { Noise(c, why, 1); continue; }
                c.Result.Kept++;
                string version = c.Split.Get(iVer);
                string mode = c.Split.Get(iMode);
                if (mode == "0") mode = null;   // unknown
                int http = c.Split.GetInt(iHttp, 200);
                long resp = c.Split.GetLong(iResp, 0), stat = c.Split.GetLong(iStat, 0), ret = c.Split.GetLong(iRet, 0);
                bool failed = http >= 400 || resp != 0 || stat != 0;
                var detail = new List<string>();
                detail.Add("MAPI " + (failed ? "failed" : "OK") + " (ResponseCode " + resp + ", StatusCode " + stat + (ret != 0 ? ", ReturnCode " + ret : "") + ")");
                string ops = c.Split.Get(iOps);
                if (ops != null) detail.Add(ops.Trim().TrimEnd(';'));
                if (software != null) detail.Add(software + (version != null ? " " + version : ""));
                if (mode != null) detail.Add("mode " + mode);
                string err = c.Split.Get(iErr);
                if (failed && err != null) detail.Add(Identity.Cap(err, 200));
                c.BackEnd.Add(new BackEndLine
                {
                    T = t, User = user, Ip = ip, MailboxGuid = Identity.MailboxGuid(c.Split.Get(iMbx)), Instance = Identity.ClientInstance(c.Split.Get(iInfo)),
                    Type = c.Split.Get(iType) ?? "?", Cafe = Identity.ServerName(c.Split.Get(iCafe)), Software = software, Version = version, Mode = mode,
                    Status = http, Failed = failed, Text = string.Join("; ", detail), Ms = c.Split.GetLong(iLat, 0), RequestId = c.Split.Get(iReq)
                });
            }
            return offset;
        }

        void ApplyMapiBackEnd(ApplyFile f, BackEndLine b)
        {
            string user = Canonical(b.User);
            string day = _days.Day(b.T);
            string key = SessionKey(day, user, "Mapi", b.Ip, null, null, b.MailboxGuid, b.Instance);
            var s = FindSession(key, b.T, () => NewSession(key, day, user, "Mapi"));
            Touch(s);
            Extend(s, b.T);
            s.Backs.Add(f.Server);
            if (b.Ip != null && s.Ips.Count < 20 && !s.Ips.Contains(b.Ip)) s.Ips.Add(b.Ip);
            if (b.Software != null && s.Software == null) s.Software = b.Software + (b.Version != null ? " " + b.Version : "");
            if (b.Mode != null) s.Mode = b.Mode;
            if (b.Failed)
            {
                s.BackEndErrors++;
                string e = "MAPI " + b.Type + ": " + b.Text;
                if (s.FirstError == null) s.FirstError = e;
                s.LastError = e;
                if (s.FirstFailure == 0 || b.T < s.FirstFailure) s.FirstFailure = b.T;
                if (b.T > s.LastFailure) s.LastFailure = b.T;
            }
            if (b.Failed || Milestones.Contains(b.Type))
            {
                AddStep(s, new SessionStep
                {
                    T = b.T, T2 = b.T, Front = b.Cafe, Back = f.Server, Action = b.Type, Status = b.Status, TotalMs = b.Ms, MaxMs = b.Ms, Failures = b.Failed ? 1 : 0,
                    Detail = Identity.Cap(b.Text, 400), RequestId = b.RequestId, Source = "BE", FileId = f.FileId, Needle = b.RequestId
                }, true);
            }
        }

        // ================================================================ ActiveSync back end (IIS W3SVC2)

        /// <summary>
        /// Exchange Back End web site. Only ActiveSync lines are read: their "Log=" parameter holds the
        /// ActiveSync result that the HTTP status hides (an HTTP 200 can be DeviceNotProvisioned or
        /// UserDisabledForSync), the access state of the device and the protocol version.
        /// </summary>
        long ParseEasBackEnd(ParseContext c)
        {
            long offset = c.StartOffset;
            int iDate = -1, iTime = -1, iMethod = -1, iStem = -1, iQuery = -1, iUser = -1, iAgent = -1, iStatus = -1, iTaken = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iDate = m.Index("date"); iTime = m.Index("time"); iMethod = m.Index("cs-method"); iStem = m.Index("cs-uri-stem"); iQuery = m.Index("cs-uri-query");
                iUser = m.Index("cs-username"); iAgent = m.Index("cs(User-Agent)"); iStatus = m.Index("sc-status"); iTaken = m.Index("time-taken");
            };
            if (c.Map.Load(c.Fields)) bind();
            foreach (var line in LogReader.Lines(c.Path, offset, c.Memo != null ? c.Memo.Read : null))
            {
                offset = line.NextOffset;
                c.Result.Lines++;
                if (line.Length == 0) { Noise(c, "Empty line", 1); continue; }
                if (line.First == '#')
                {
                    if (line.StartsWith("#Fields:")) { string text = line.Text(); c.Map.Load(text); c.Fields = text; bind(); }
                    Noise(c, "Header", 1);
                    continue;
                }
                if (!line.Contains("/Microsoft-Server-ActiveSync")) { Noise(c, "Back-end traffic other than ActiveSync", 1); continue; }
                if (iDate < 0 || iTime < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ' ');
                long t;
                if (!c.Split.TryTime(iDate, iTime, out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t < _o.DetailCutoffMs) { Noise(c, "Older than detail retention (back end)", 1); continue; }
                var memo = c.Memo;
                string user = UserOf(memo, c.Split.GetCached(iUser)), agent = PlusAgent(memo, c.Split.GetCached(iAgent));
                int status = c.Split.GetInt(iStatus, 0);
                string why = ClientNoise(memo, user, null, agent, null, c.Split.GetCached(iStem), status);
                if (why != null) { Noise(c, why, 1); continue; }
                c.Result.Kept++;
                string query = c.Split.Get(iQuery) ?? "";
                string queryCmd = Identity.QueryValue(query, "Cmd");
                string cmd = queryCmd ?? c.Split.Get(iMethod) ?? "?";
                string error = null, access = null, version = null;
                int logAt = query.IndexOf("Log=", StringComparison.OrdinalIgnoreCase);
                if (logAt >= 0)
                    foreach (Match m in EasLogToken.Matches(query.Substring(logAt + 4)))
                    {
                        string v = Uri.UnescapeDataString(m.Groups[2].Value);
                        switch (m.Groups[1].Value)
                        {
                            case "Error": error = v; break;
                            case "As": access = v; break;
                            case "Ver1": version = v.Length >= 2 ? v.Substring(0, v.Length - 1) + "." + v.Substring(v.Length - 1) : v; break;
                        }
                    }
                c.BackEnd.Add(new BackEndLine
                {
                    T = t, User = user, Agent = agent, Device = Identity.QueryValue(query, "DeviceId"), Type = cmd, Error = error, Access = access, Version = version,
                    Status = status, Ms = c.Split.GetLong(iTaken, 0), Needle = c.Split.Get(iDate) + " " + c.Split.Get(iTime) + " ",
                    Needle2 = queryCmd != null ? "Cmd=" + cmd : c.Split.Get(iStem)
                });
            }
            return offset;
        }

        void ApplyEasBackEnd(ApplyFile f, BackEndLine b)
        {
            string user = Canonical(b.User);
            string day = _days.Day(b.T);
            string key = SessionKey(day, user, "Eas", null, b.Agent, b.Device, null, null);
            var s = FindSession(key, b.T, () => NewSession(key, day, user, "Eas"));
            Touch(s);
            Extend(s, b.T);
            s.Backs.Add(f.Server);
            if (b.Version != null) s.Software = "ActiveSync " + b.Version;
            if (b.Access != null) s.Mode = "Access " + b.Access;
            if (s.DeviceId == null && b.Device != null) s.DeviceId = b.Device;
            if (b.Error != null || b.Status >= 400)
            {
                s.BackEndErrors++;
                string text = (b.Error != null ? "ActiveSync error " + b.Error : "HTTP " + b.Status) + (b.Access != null ? " (device access " + b.Access + ")" : "");
                string e = b.Type + ": " + text;
                if (s.FirstError == null) s.FirstError = e;
                s.LastError = e;
                if (s.FirstFailure == 0 || b.T < s.FirstFailure) s.FirstFailure = b.T;
                if (b.T > s.LastFailure) s.LastFailure = b.T;
                AddStep(s, new SessionStep
                {
                    T = b.T, T2 = b.T, Back = f.Server, Action = b.Type, Status = b.Status, TotalMs = b.Ms, MaxMs = b.Ms, Failures = 1, Detail = text, Source = "BE",
                    FileId = f.FileId, Needle = b.Needle, Needle2 = b.Needle2
                }, true);
            }
        }

        // ================================================================ POP3 / IMAP4 (optional)

        sealed class PiLine { public long T, Ms, In, Out; public string Command, Params, Result, Needle; }

        sealed class PiConnection
        {
            public string Id, ClientIp, User, BackEnd;
            public long Start, Last, StartOffset, EndOffset;
            public int Lines;
            public bool Closed;   // LOGOUT / QUIT seen: complete even if CloseSession is not written yet
            public List<PiLine> Commands = new List<PiLine>();
        }

        sealed class DeferredBackEnd
        {
            public string Day, User, Protocol, Server, FrontIp;
            public long Start, End, Requests, Successes, Failures, Slow, TotalMs, MaxMs, BytesIn, BytesOut, FirstFailure, LastFailure, FirstSuccess, LastSuccess;
            public string FirstError, LastError;
            public Dictionary<string, long> Actions = new Dictionary<string, long>(StringComparer.Ordinal);
            public List<SessionStep> Steps = new List<SessionStep>();
        }

        /// <summary>
        /// Logging\Imap4 and Logging\Pop3: IMAP4*/POP3* files are the front end (client address, logon,
        /// back-end server), IMAP4BE*/POP3BE* files the back end (each command with its result).
        /// Connections are read whole and emitted once: while the file is active, the read position stops
        /// at the first line of the oldest connection still open, and every connection that has a line
        /// after that position is kept for the next collection (it is read again complete).
        /// </summary>
        long ParsePopImap(ParseContext c, string protocol)
        {
            bool backEnd = Path.GetFileName(c.Path).StartsWith(protocol.ToUpperInvariant() + "BE", StringComparison.OrdinalIgnoreCase);
            c.PopImapBackEnd = backEnd;
            var open = new Dictionary<string, PiConnection>(StringComparer.Ordinal);
            var done = new List<PiConnection>();
            long offset = c.StartOffset, lineStart = offset, fileLastMs = 0;
            int iTime = -1, iSess = -1, iClient = -1, iUser = -1, iDur = -1, iIn = -1, iOut = -1, iCmd = -1, iParams = -1, iCtx = -1;
            Action bind = () =>
            {
                var m = c.Map;
                iTime = m.Index("dateTime"); iSess = m.Index("sessionId"); iClient = m.Index("cIp"); iUser = m.Index("user"); iDur = m.Index("duration");
                iIn = m.Index("rqsize"); iOut = m.Index("rpsize"); iCmd = m.Index("command"); iParams = m.Index("parameters"); iCtx = m.Index("context");
            };
            if (c.Map.Load(c.Fields)) bind();
            foreach (var line in LogReader.Lines(c.Path, offset, c.Memo != null ? c.Memo.Read : null))
            {
                long start = lineStart;
                lineStart = line.NextOffset;
                offset = line.NextOffset;
                c.Result.Lines++;
                if (line.Length == 0) { Noise(c, "Empty line", 1); continue; }
                if (line.First == '#')
                {
                    if (line.StartsWith("#Fields:")) { string text = line.Text(); c.Map.Load(text); c.Fields = text; bind(); }
                    Noise(c, "Header", 1);
                    continue;
                }
                if (iTime < 0 || iSess < 0) { Noise(c, "No #Fields header", 1); continue; }
                c.Split.Split(line, ',');
                long t;
                if (!c.Split.TryTime(iTime, out t)) { Noise(c, "Unreadable line", 1); continue; }
                Seen(c, t);
                if (t > fileLastMs) fileLastMs = t;
                string sid = c.Split.Get(iSess) ?? "", cmd = c.Split.Get(iCmd) ?? "";
                PiConnection x;
                if (cmd.Equals("OpenSession", StringComparison.OrdinalIgnoreCase) || !open.TryGetValue(sid, out x))
                {
                    // Session ids restart with the service: a new OpenSession closes the previous connection of that id.
                    if (open.TryGetValue(sid, out x)) { x.Closed = true; done.Add(x); }
                    x = new PiConnection { Id = sid, Start = t, StartOffset = start, ClientIp = Identity.Host(c.Split.Get(iClient)) };
                    open[sid] = x;
                }
                x.Lines++;
                x.Last = t;
                x.EndOffset = line.NextOffset;
                string user = c.Split.Get(iUser);
                if (user != null && (x.User == null || x.User.IndexOf('@') > 0)) x.User = user;
                string ctx = c.Split.Get(iCtx);
                if (ctx != null && x.BackEnd == null)
                {
                    var proxy = ProxyTargetRx.Match(ctx);
                    if (proxy.Success) x.BackEnd = Identity.ServerName(proxy.Groups[1].Value);
                }
                if (cmd.Equals("CloseSession", StringComparison.OrdinalIgnoreCase))
                {
                    x.Commands.Add(new PiLine { T = t, Command = cmd, In = c.Split.GetLong(iIn, 0), Out = c.Split.GetLong(iOut, 0) });
                    x.Closed = true;
                    done.Add(x);
                    open.Remove(sid);
                    continue;
                }
                if (!cmd.Equals("OpenSession", StringComparison.OrdinalIgnoreCase))
                    x.Commands.Add(new PiLine
                    {
                        T = t, Command = cmd, Params = c.Split.Get(iParams), Result = ResultOf(ctx), Ms = c.Split.GetLong(iDur, 0),
                        In = c.Split.GetLong(iIn, 0), Out = c.Split.GetLong(iOut, 0), Needle = c.Split.Get(iTime) + "," + sid + ","
                    });
                if (cmd.Equals("logout", StringComparison.OrdinalIgnoreCase) || cmd.Equals("quit", StringComparison.OrdinalIgnoreCase)) x.Closed = true;
            }
            bool active = _o.NowMs - c.LastWriteMs < _o.SmtpIdleMs;
            long safe = offset;
            foreach (var x in open.Values)
            {
                // Still open and recently active: it can receive lines after the end of the file.
                if (active && !x.Closed && fileLastMs - x.Last < _o.SmtpIdleMs) safe = Math.Min(safe, x.StartOffset);
                else done.Add(x);
            }
            // A finished connection that has lines after the read position would be read again in part:
            // move the position back to its first line, until no connection crosses it.
            bool moved = true;
            while (moved)
            {
                moved = false;
                foreach (var x in done)
                    if (x.StartOffset < safe && x.EndOffset > safe) { safe = x.StartOffset; moved = true; }
            }
            foreach (var x in done)
            {
                if (x.EndOffset > safe) continue;
                // Noise is decided here (no shared state needed): connections without logon and probes.
                string user = Identity.User(x.User);
                if (user == null)
                {
                    bool logonFailed = x.Commands.Any(l => PiFailed(l.Result) && (l.Command.Equals("login", StringComparison.OrdinalIgnoreCase) || l.Command.Equals("authenticate", StringComparison.OrdinalIgnoreCase) || l.Command.Equals("pass", StringComparison.OrdinalIgnoreCase) || l.Command.Equals("user", StringComparison.OrdinalIgnoreCase)));
                    Noise(c, logonFailed ? protocol + " logon failed (the account is not logged)" : protocol + " connection without logon", x.Lines);
                    continue;
                }
                string why = ClientNoise(c.Memo, user, null, null, backEnd ? null : x.ClientIp, null, 200);
                if (why != null) { Noise(c, why, x.Lines); continue; }
                c.Result.Kept += x.Lines;
                c.PopImap.Add(x);
            }
            return safe;
        }

        /// <summary>"R=OK;Msg=..." gives "OK"; "R=""a2 NO LOGIN failed.""" gives "NO LOGIN failed.".</summary>
        static string ResultOf(string context)
        {
            if (string.IsNullOrEmpty(context)) return null;
            int r = context.IndexOf("R=", StringComparison.Ordinal);
            if (r < 0) return null;
            string v;
            if (r + 2 < context.Length && context[r + 2] == '"')
            {
                int end = context.IndexOf('"', r + 3);
                v = end > r ? context.Substring(r + 3, end - r - 3) : context.Substring(r + 3);
            }
            else
            {
                int end = context.IndexOf(';', r);
                v = end > r ? context.Substring(r + 2, end - r - 2) : context.Substring(r + 2);
            }
            var tagged = TaggedResultRx.Match(v);
            return (tagged.Success ? tagged.Groups[1].Value : v).Trim();
        }

        static bool PiFailed(string result)
        {
            if (string.IsNullOrEmpty(result)) return false;
            return result.StartsWith("NO", StringComparison.OrdinalIgnoreCase) || result.StartsWith("BAD", StringComparison.OrdinalIgnoreCase) || result.StartsWith("-ERR", StringComparison.OrdinalIgnoreCase);
        }

        /// <summary>Apply stage of one POP or IMAP connection of a real user (noise already removed by the parse stage).</summary>
        void EmitPopImap(ApplyFile f, PiConnection x, string protocol, bool backEnd)
        {
            string user = Canonical(Identity.User(x.User));
            DeferredBackEnd deferred = null;
            if (backEnd && x.Start >= _o.DetailCutoffMs)
            {
                deferred = new DeferredBackEnd { Day = _days.Day(x.Start), User = user, Protocol = protocol, Server = f.Server, FrontIp = x.ClientIp, Start = x.Start, End = x.Last };
                _deferred.Add(deferred);
            }
            bool first = true;
            int index = 0;
            foreach (var l in x.Commands)
            {
                index++;
                string cmd = l.Command;
                if (cmd.Equals("CloseSession", StringComparison.OrdinalIgnoreCase)) continue;
                // The back end repeats the logon of the front end (IMAP authenticate, POP AUTH) and the capability exchange.
                if (backEnd && (cmd.Equals("authenticate", StringComparison.OrdinalIgnoreCase) || cmd.Equals("auth", StringComparison.OrdinalIgnoreCase)
                    || cmd.Equals("capability", StringComparison.OrdinalIgnoreCase) || cmd.Equals("capa", StringComparison.OrdinalIgnoreCase))) continue;
                bool failed = PiFailed(l.Result);
                bool logon = cmd.Equals("login", StringComparison.OrdinalIgnoreCase) || cmd.Equals("pass", StringComparison.OrdinalIgnoreCase) || cmd.Equals("user", StringComparison.OrdinalIgnoreCase);
                var r = new AccessRecord
                {
                    TimeMs = l.T, Source = protocol, Protocol = protocol, User = user, ClientIp = backEnd ? null : x.ClientIp, Action = cmd.ToUpperInvariant(),
                    Status = failed ? (logon ? 401 : 400) : 200, ErrorCode = failed ? Identity.Cap(l.Result, 300) : null, DurationMs = l.Ms, BytesIn = l.In, BytesOut = l.Out,
                    TargetServer = backEnd ? null : x.BackEnd, FromBackEnd = backEnd,
                    // One id per command (access_event is unique per server, source and request id); session ids restart with the service.
                    RequestId = protocol + " " + f.Server + " #" + x.Id + "/" + index.ToString(CultureInfo.InvariantCulture) + "@" + l.T.ToString(CultureInfo.InvariantCulture),
                    Needle = l.Needle,
                    Detail = first && !backEnd ? "Connection " + x.Id + " from " + x.ClientIp + (x.BackEnd != null ? ", proxied to " + x.BackEnd : "") : null
                };
                HandleAccess(f, r);
                if (!backEnd && first)
                {
                    // One connection more for the session of this client.
                    string day = _days.Day(l.T);
                    string key = SessionKey(day, user, protocol, x.ClientIp, null, null, null, null);
                    var s = FindSession(key, l.T, () => NewSession(key, day, user, protocol));
                    if (l.T >= _o.DetailCutoffMs) { s.Connections++; Touch(s); }
                }
                first = false;
                if (deferred != null)
                {
                    bool slow = !failed && _o.SlowRequestMs > 0 && l.Ms >= _o.SlowRequestMs && !LongRunning(r);
                    deferred.Requests++;
                    if (failed)
                    {
                        deferred.Failures++;
                        string e = r.Action + ": " + l.Result;
                        if (deferred.FirstFailure == 0) { deferred.FirstFailure = l.T; deferred.FirstError = e; }
                        deferred.LastFailure = l.T; deferred.LastError = e;
                    }
                    else { deferred.Successes++; deferred.FirstSuccess = MinPositive(deferred.FirstSuccess, l.T); deferred.LastSuccess = Math.Max(deferred.LastSuccess, l.T); }
                    if (slow) deferred.Slow++;
                    deferred.TotalMs += l.Ms; deferred.MaxMs = Math.Max(deferred.MaxMs, l.Ms); deferred.BytesIn += l.In; deferred.BytesOut += l.Out;
                    Inc(deferred.Actions, r.Action, 1);
                    deferred.Steps.Add(new SessionStep
                    {
                        T = l.T, T2 = l.T, Back = f.Server, Action = r.Action, Status = r.Status, TotalMs = l.Ms, MaxMs = l.Ms, Failures = failed ? 1 : 0,
                        Detail = Identity.Cap((l.Params != null && !l.Params.Contains("*****") ? l.Params + " -> " : "") + (l.Result ?? ""), 300), Source = "BE",
                        RequestId = r.RequestId, FileId = f.FileId, Needle = l.Needle
                    });
                }
            }
        }

        /// <summary>
        /// Attaches the back-end IMAP/POP connections of this run to the session of their client: same
        /// user and protocol, the back-end server among the proxy targets, overlapping times. Without a
        /// match (front end not collected), the connection gets its own session "via" the front end.
        /// </summary>
        void CompleteBackEnd()
        {
            if (_deferred.Count == 0) return;
            using (var writer = new Writer(_store))
            using (var tx = _store.Begin())
            {
                _writer = writer;
                _writer.Use(tx);
                _tx = tx;
                var touched = new HashSet<ClientSession>();
                try
                {
                    foreach (var d in _deferred)
                    {
                        ClientSession s = null;
                        List<ClientSession> list;
                        if (_byUser.TryGetValue(d.Day + "|" + d.User + "|" + d.Protocol, out list))
                            s = list.Where(x => !x.Dead && x.Backs.Contains(d.Server) && x.Start - 120000 <= d.End && x.End + 120000 >= d.Start)
                                    .OrderBy(x => Math.Abs(x.Start - d.Start)).FirstOrDefault();
                        if (s == null)
                        {
                            string key = null;
                            using (var q = _store.Command(@"SELECT skey FROM client_session WHERE user=@u AND protocol=@p AND day=@d AND start_ms <= @e AND end_ms >= @s
     AND instr(','||COALESCE(back_ends,'')||',', ','||@srv||',') > 0 ORDER BY abs(start_ms-@s0) LIMIT 1;", tx))
                            {
                                q.Parameters.AddWithValue("@u", d.User); q.Parameters.AddWithValue("@p", d.Protocol); q.Parameters.AddWithValue("@d", d.Day);
                                q.Parameters.AddWithValue("@e", d.End + 120000); q.Parameters.AddWithValue("@s", d.Start - 120000); q.Parameters.AddWithValue("@srv", d.Server);
                                q.Parameters.AddWithValue("@s0", d.Start);
                                key = q.ExecuteScalar() as string;
                            }
                            if (key != null) s = FindSession(key, d.Start, () => NewSession(key, d.Day, d.User, d.Protocol));
                        }
                        if (s == null)
                        {
                            string key = d.Day + "|" + d.User + "|" + d.Protocol + "|via:" + d.FrontIp;
                            s = FindSession(key, d.Start, () => NewSession(key, d.Day, d.User, d.Protocol));
                            if (s.Ips.Count == 0 && d.FrontIp != null) s.Ips.Add(d.FrontIp + " (front end)");
                        }
                        touched.Add(s);
                        Extend(s, d.Start); Extend(s, d.End);
                        s.Backs.Add(d.Server);
                        s.Requests += d.Requests; s.Successes += d.Successes; s.Failures += d.Failures; s.Slow += d.Slow;
                        s.TotalMs += d.TotalMs; s.MaxMs = Math.Max(s.MaxMs, d.MaxMs); s.BytesIn += d.BytesIn; s.BytesOut += d.BytesOut;
                        s.FirstSuccess = MinPositive(s.FirstSuccess, d.FirstSuccess); s.LastSuccess = Math.Max(s.LastSuccess, d.LastSuccess);
                        if (d.FirstFailure > 0 && (s.FirstFailure == 0 || d.FirstFailure < s.FirstFailure)) { s.FirstFailure = d.FirstFailure; s.FirstError = d.FirstError; }
                        if (d.LastFailure > s.LastFailure) { s.LastFailure = d.LastFailure; s.LastError = d.LastError; }
                        foreach (var kv in d.Actions) Inc(s.Actions, kv.Key, kv.Value);
                        foreach (var step in d.Steps) AddStep(s, step, true);
                    }
                    FlushSessions(tx, touched);
                    tx.Commit();
                }
                finally { _tx = null; _writer = null; }
            }
            _deferred.Clear();
        }
    }
}
