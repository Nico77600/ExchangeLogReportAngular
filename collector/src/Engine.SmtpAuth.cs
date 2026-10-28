// =============================================================================
//  Exchange Log Report - engine, part 12: authenticated user of SMTP sessions
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 2.0.0
//
//  The authenticated user of an SMTP transaction is the account that Exchange itself wrote in its protocol log
//  ("* data=<account> context=authenticated"), tied to a successful AUTH of the same session. It is never decoded from
//  the AUTH payload and never derived from MAIL FROM, HELO or the client address.
//
//  1. Parse   (many threads) the session is followed line by line: typed observations (AUTH attempt, result, identity,
//             XPROXY, STARTTLS, EHLO, MAIL) are cut in parts of at most 256 observations, 64 ranges of sequence numbers and
//             128 KiB and drained at once into a file-local spool together with the finished transactions; nothing grows with
//             the length of a connection. AUTH payloads, challenges and unknown mechanisms are removed before anything is stored.
//  2. Apply   (one thread, same transaction as the rows) the spool is written in pages; then every session touched by the
//             batch is replayed again from the evidence stored in the database: one scope at a time, in pages, one state
//             machine per connection epoch, and for a back-end session proxied by a front end the strict correlation with
//             the front-end interval that was effective at the XPROXY. The result does not depend on the order of the
//             files, nor on the collection that read them, and a later AUTH never changes what was proved earlier.
//  3. Report  the five values (mechanism, result, last attempt, user, evidence) are formatted by SmtpAuthView.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    internal enum IdKind { Invalid, User, Technical }

    /// <summary>Validated parameters of an XPROXY command (structure only: nothing else of the command is kept).</summary>
    internal sealed class XProxyInfo
    {
        public string Sid, Ip, Helo;
        public int Port;
        public bool Valid;
        public string Text { get { return "XPROXY SID=" + Sid + " IP=" + Ip + (Port > 0 ? " PORT=" + Port.ToString(CultureInfo.InvariantCulture) : "") + (Helo != null ? " DOMAIN=" + Helo : ""); } }
    }

    /// <summary>Kind of a client line. p payload of an AUTH exchange, c cancel (*), q QUIT, r RSET, A AUTH, X XPROXY, T STARTTLS, E EHLO/HELO, M MAIL, o other.</summary>
    internal struct SmtpCommand
    {
        public char Kind;
        public string Mech;
        public XProxyInfo Proxy;
        public bool Interrupted;
    }

    /// <summary>Grammar, identity rules and redaction shared by the parser, the resolver and the reports.</summary>
    internal static class SmtpAuth
    {
        public const string Redacted = "[redacted]";
        public const string TechnicalText = "[technical]", InvalidText = "[invalid]";
        // Results and last attempts.
        public const string NotAttempted = "Not attempted", InProgress = "In progress", Succeeded = "Succeeded", Failed = "Failed", Abandoned = "Abandoned", Unknown = "Unknown";
        // Evidence of the identity.
        public const string Direct = "Direct", FrontEndProxy = "FrontEndProxy", Missing = "Missing", NotApplicable = "NotApplicable", Ambiguous = "Ambiguous";

        static readonly Regex Base64Rx = new Regex(@"^[A-Za-z0-9+/=]*$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        static readonly Regex OpaqueRx = new Regex(@"[A-Za-z0-9+/=]{24,}", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        static readonly Regex OpaqueEventRx = new Regex(@"[A-Za-z0-9+/=]{16,}", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        static readonly Regex ProxyRx = new Regex(@"^\s*Proxy session was successfully set up\.\s*Session for\s*(?<a>\S+)\s+will now be proxied\s*$", RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        static readonly Regex UpnRx = new Regex(@"^[^@\\\s]+@[^@\\\s]+$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        static readonly Regex DownLevelRx = new Regex(@"^[^@\\\s]+\\[^@\\\s]+$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        static readonly Regex SidRx = new Regex(@"^s-1-\d+(-\d+)+$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        static readonly Regex SimpleRx = new Regex(@"^[^@\\\s<>""/|:;,=*?\[\]]+$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        static readonly Regex SessionIdRx = new Regex(@"^[0-9A-Za-z]{1,64}$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        static readonly Regex HostRx = new Regex(@"^[A-Za-z0-9._\-]{1,255}$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        static readonly HashSet<string> TechnicalSids = new HashSet<string>(StringComparer.Ordinal) { "s-1-5-7", "s-1-5-18", "s-1-5-19", "s-1-5-20", "s-1-1-0" };
        static readonly HashSet<string> NotAnAccount = new HashSet<string>(StringComparer.Ordinal) { "unrecognized", "unknown", "none", "null", "n/a" };
        static readonly HashSet<string> KnownVerbs = new HashSet<string>(StringComparer.Ordinal) {
            "EHLO", "HELO", "MAIL", "RCPT", "DATA", "BDAT", "RSET", "QUIT", "STARTTLS", "NOOP", "VRFY", "EXPN", "HELP", "AUTH", "XPROXY", "X-EXPS", "XEXCH50", "XSHADOW", "XQDISCARD", "XORAR", "X-ANONYMOUSTLS", "X-SHADOWREDUNDANCY" };

        // ---------------------------------------------------------------- identity

        /// <summary>
        /// Normalised account of an identity written by Exchange: UPN, DOMAIN\sam, SID or simple name, lower case, 512 characters at most, no
        /// control character. Machine and anonymous identities are technical, anything else (bracketed placeholders such as
        /// "[unrecognized]", empty values, phrases) is invalid.
        /// </summary>
        public static IdKind ParseIdentity(string raw, out string account)
        {
            account = null;
            if (raw == null) return IdKind.Invalid;
            string t = raw.Trim().Trim('"');
            if (t == TechnicalText) return IdKind.Technical;
            if (t.Length == 0 || t.Length > 512 || t[0] == '[') return IdKind.Invalid;
            foreach (char ch in t) if (ch < ' ' || ch == (char)0x7f) return IdKind.Invalid;
            string u = Identity.User(t);
            if (u == null || NotAnAccount.Contains(u)) return IdKind.Invalid;
            if (u == "anonymous" || u == "anonymous logon" || u.StartsWith("nt authority\\", StringComparison.Ordinal) || u.StartsWith("nt service\\", StringComparison.Ordinal)) return IdKind.Technical;
            if (SidRx.IsMatch(u))
            {
                if (TechnicalSids.Contains(u) || u.StartsWith("s-1-5-80-", StringComparison.Ordinal)) return IdKind.Technical;
                account = u;
                return IdKind.User;
            }
            if (!UpnRx.IsMatch(u) && !DownLevelRx.IsMatch(u) && !SimpleRx.IsMatch(u)) return IdKind.Invalid;
            if (Identity.Bare(u).EndsWith("$", StringComparison.Ordinal)) return IdKind.Technical;
            account = u;
            return IdKind.User;
        }

        static string IdentityText(IdKind kind, string account) { return kind == IdKind.User ? account : kind == IdKind.Technical ? TechnicalText : InvalidText; }

        // ---------------------------------------------------------------- mechanisms and commands

        static string FirstToken(string text)
        {
            if (string.IsNullOrEmpty(text)) return "";
            string t = text.TrimStart();
            int sp = t.IndexOf(' ');
            return sp < 0 ? t : t.Substring(0, sp);
        }

        static int Tokens(string text) { return string.IsNullOrWhiteSpace(text) ? 0 : text.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries).Length; }

        /// <summary>Canonical mechanism of an AUTH or X-EXPS command; an unknown mechanism is never kept ("Unknown").</summary>
        public static string Mechanism(string args, bool exps)
        {
            string token = FirstToken(args).ToUpperInvariant();
            if (exps)
            {
                if (token == "EXCHANGEAUTH" || token == "GSSAPI" || token == "NTLM") return "X-EXPS " + token;
                return "Unknown";
            }
            if (token == "LOGIN" || token == "PLAIN" || token == "NTLM" || token == "GSSAPI" || token == "NEGOTIATE") return token;
            return "Unknown";
        }

        public static bool IsTechnicalMechanism(string mechanism) { return mechanism != null && mechanism.StartsWith("X-EXPS", StringComparison.Ordinal); }

        /// <summary>Structure of an XPROXY command: SID, IP, optional PORT and DOMAIN. Duplicated or malformed parameters invalidate it.</summary>
        public static XProxyInfo ParseXProxy(string args)
        {
            var x = new XProxyInfo();
            bool bad = false, haveSid = false, haveIp = false, havePort = false, haveDomain = false;
            if (args != null)
            {
                foreach (var part in args.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    int eq = part.IndexOf('=');
                    if (eq <= 0) continue;
                    string k = part.Substring(0, eq).ToUpperInvariant(), v = part.Substring(eq + 1);
                    if (k == "SID")
                    {
                        if (haveSid || !SessionIdRx.IsMatch(v)) bad = true; else { x.Sid = v; haveSid = true; }
                    }
                    else if (k == "IP")
                    {
                        IPAddress ip;
                        if (haveIp || !IPAddress.TryParse(v, out ip) || v.IndexOf('%') >= 0) bad = true; else { x.Ip = Canonical(ip); haveIp = true; }
                    }
                    else if (k == "PORT")
                    {
                        int p;
                        if (havePort || !int.TryParse(v, NumberStyles.None, CultureInfo.InvariantCulture, out p) || p < 1 || p > 65535) bad = true; else { x.Port = p; havePort = true; }
                    }
                    else if (k == "DOMAIN")
                    {
                        if (haveDomain || !HostRx.IsMatch(v)) bad = true; else { x.Helo = v; haveDomain = true; }
                    }
                }
            }
            x.Valid = !bad && haveSid && haveIp;
            return x;
        }

        public static string Canonical(IPAddress ip) { return (ip.IsIPv4MappedToIPv6 ? ip.MapToIPv4() : ip).ToString(); }

        public static bool SameIp(string endpointA, string endpointB)
        {
            IPAddress a, b;
            if (string.IsNullOrEmpty(endpointA) || string.IsNullOrEmpty(endpointB)) return false;
            if (!IPAddress.TryParse(Identity.Host(endpointA), out a) || !IPAddress.TryParse(Identity.Host(endpointB), out b)) return false;
            return Canonical(a) == Canonical(b);
        }

        public static bool SameIpText(string ip, string endpoint)
        {
            IPAddress a, b;
            if (string.IsNullOrEmpty(ip) || string.IsNullOrEmpty(endpoint)) return false;
            if (!IPAddress.TryParse(ip, out a) || !IPAddress.TryParse(Identity.Host(endpoint), out b)) return false;
            return Canonical(a) == Canonical(b);
        }

        public static int Port(string endpoint)
        {
            if (string.IsNullOrEmpty(endpoint)) return 0;
            string s = endpoint.Trim();
            if (s.StartsWith("[", StringComparison.Ordinal))
            {
                int close = s.IndexOf(']');
                if (close < 0 || close + 1 >= s.Length || s[close + 1] != ':') return 0;
                s = s.Substring(close + 2);
            }
            else
            {
                int colon = s.LastIndexOf(':');
                if (colon < 0 || s.IndexOf(':') != colon) return 0;
                s = s.Substring(colon + 1);
            }
            int p;
            return int.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out p) && p > 0 && p <= 65535 ? p : 0;
        }

        public static bool TryEndpointAddress(string endpoint, out IPAddress address)
        {
            address = null;
            return Port(endpoint) > 0 && IPAddress.TryParse(Identity.Host(endpoint), out address);
        }

        public static int Code(string data)
        {
            if (data == null || data.Length < 3) return 0;
            int v = 0;
            for (int i = 0; i < 3; i++) { int d = data[i] - '0'; if (d < 0 || d > 9) return 0; v = v * 10 + d; }
            return data.Length == 3 || data[3] == ' ' || data[3] == '-' ? v : 0;
        }

        public static bool IsAuthCode(int code)
        {
            return code == 235 || code == 454 || code == 501 || code == 503 || code == 504 || code == 530 || code == 534 || code == 535 || code == 538;
        }

        public static bool AlreadyAuthenticated(int code, string data)
        {
            return code == 503 && data != null && data.IndexOf("already authenticated", StringComparison.OrdinalIgnoreCase) >= 0;
        }

        /// <summary>
        /// Classifies a client line and returns the text that may be stored. During an AUTH exchange every line made only of base64
        /// characters is a payload (a user name, a password, a token): it is removed. "*", QUIT and RSET end the exchange; any other
        /// line is a command and ends it too.
        /// </summary>
        public static SmtpCommand Command(string data, ref bool inAuth, out string clean)
        {
            clean = data ?? "";
            var cmd = new SmtpCommand { Kind = 'o' };
            string t = clean.Trim();
            if (inAuth)
            {
                string up = t.ToUpperInvariant();
                if (t == "*") { inAuth = false; cmd.Kind = 'c'; return cmd; }
                if (up == "QUIT") { inAuth = false; cmd.Kind = 'q'; return cmd; }
                if (up == "RSET") { inAuth = false; cmd.Kind = 'r'; return cmd; }
                if (t.Length == 0) { cmd.Kind = 'p'; return cmd; }
                if (Base64Rx.IsMatch(t)) { clean = Redacted; cmd.Kind = 'p'; return cmd; }
                inAuth = false;
                cmd.Interrupted = true;
            }
            int sp = t.IndexOf(' ');
            string verb = (sp < 0 ? t : t.Substring(0, sp)).ToUpperInvariant();
            string rest = sp < 0 ? "" : t.Substring(sp + 1).Trim();
            switch (verb)
            {
                case "AUTH":
                case "X-EXPS":
                    cmd.Kind = 'A';
                    cmd.Mech = Mechanism(rest, verb == "X-EXPS");
                    inAuth = true;
                    clean = verb + " " + (cmd.Mech == "Unknown" ? "[unknown]" : verb == "X-EXPS" ? cmd.Mech.Substring(7) : cmd.Mech) + (Tokens(rest) > 1 ? " " + Redacted : "");
                    return cmd;
                case "XPROXY":
                    cmd.Kind = 'X';
                    cmd.Proxy = ParseXProxy(rest);
                    clean = cmd.Proxy.Valid ? cmd.Proxy.Text : "XPROXY [invalid]";
                    return cmd;
                case "EHLO":
                case "HELO":
                    cmd.Kind = 'E';
                    cmd.Mech = HostRx.IsMatch(rest) ? rest : null;
                    return cmd;
                case "STARTTLS": cmd.Kind = 'T'; return cmd;
                case "MAIL": cmd.Kind = 'M'; return cmd;
                case "QUIT": cmd.Kind = 'q'; return cmd;
                case "RSET": cmd.Kind = 'r'; return cmd;
            }
            if (!KnownVerbs.Contains(verb) && t.Length >= 8 && Base64Rx.IsMatch(t)) { clean = Redacted; cmd.Kind = 'p'; }
            return cmd;
        }

        /// <summary>Text that may be stored for a server response; updates the AUTH exchange state (334 opens or continues it, 235 or a final reply closes it).</summary>
        public static string CleanResponse(string data, ref bool inAuth)
        {
            data = data ?? "";
            int code = Code(data);
            bool continuation = data.Length > 3 && data[3] == '-';
            if (code == 334) { inAuth = true; return "334 " + Redacted; }
            if (code == 235) { inAuth = false; return "235 2.7.0 Authentication successful"; }
            if (inAuth)
            {
                string clean = data;
                if (OpaqueRx.IsMatch(data)) clean = code > 0 ? code.ToString(CultureInfo.InvariantCulture) + (continuation ? "-" : " ") + Redacted : Redacted;
                if (code > 0 && !continuation) inAuth = false;
                return clean;
            }
            return data;
        }

        /// <summary>
        /// Classifies a "*" event of the protocol log: 1 identity written by Exchange ("data=<account> context=authenticated"),
        /// 2 proxy set-up ("Proxy session was successfully set up. Session for <account> will now be proxied"), 0 anything else.
        /// Returns the text that may be stored. During an AUTH exchange an event with an opaque token is removed.
        /// </summary>
        public static int ClassifyEvent(string data, string ctx, bool inAuth, out string cleanData, out string cleanCtx, out IdKind kind, out string account)
        {
            cleanData = data ?? ""; cleanCtx = ctx ?? ""; kind = IdKind.Invalid; account = null;
            if (!string.IsNullOrEmpty(data) && string.Equals((ctx ?? "").Trim(), "authenticated", StringComparison.OrdinalIgnoreCase))
            {
                kind = ParseIdentity(data, out account);
                cleanData = IdentityText(kind, account);
                cleanCtx = "authenticated";
                return 1;
            }
            Match m;
            bool inContext = !string.IsNullOrEmpty(ctx);
            m = ProxyRx.Match(inContext ? ctx : data ?? "");
            if (m.Success)
            {
                kind = ParseIdentity(m.Groups["a"].Value, out account);
                string phrase = "Proxy session was successfully set up. Session for " + IdentityText(kind, account) + " will now be proxied";
                if (inContext) cleanCtx = phrase; else cleanData = phrase;
                return 2;
            }
            if (inAuth && ((!string.IsNullOrEmpty(data) && OpaqueEventRx.IsMatch(data)) || (!string.IsNullOrEmpty(ctx) && OpaqueEventRx.IsMatch(ctx))))
            {
                cleanData = string.IsNullOrEmpty(data) ? "" : Redacted;
                cleanCtx = string.IsNullOrEmpty(ctx) ? "" : Redacted;
            }
            return 0;
        }

        // ---------------------------------------------------------------- redaction of stored transcripts

        /// <summary>
        /// Removes what must never be shown from a stored SMTP transcript: AUTH payloads and challenges, the text of an authentication
        /// success, the mechanism arguments and the parameters of XPROXY other than SID, IP, PORT and DOMAIN. Applying it twice gives
        /// the same text (transcripts written before the redaction was done at collection).
        /// </summary>
        public static string RedactTranscript(string text)
        {
            if (string.IsNullOrEmpty(text)) return text;
            if (text.IndexOf("AUTH", StringComparison.OrdinalIgnoreCase) < 0 && text.IndexOf("X-EXPS", StringComparison.OrdinalIgnoreCase) < 0 && text.IndexOf("334", StringComparison.Ordinal) < 0
                && text.IndexOf("235", StringComparison.Ordinal) < 0 && text.IndexOf("XPROXY", StringComparison.OrdinalIgnoreCase) < 0 && text.IndexOf("Proxy session", StringComparison.OrdinalIgnoreCase) < 0)
                return text;
            var sb = new StringBuilder(text.Length);
            bool inAuth = false;
            int pos = 0;
            while (pos < text.Length)
            {
                int end = text.IndexOf('\n', pos);
                bool last = end < 0;
                string line = last ? text.Substring(pos) : text.Substring(pos, end - pos);
                sb.Append(RedactLine(line, ref inAuth));
                if (!last) sb.Append('\n');
                pos = last ? text.Length : end + 1;
            }
            return sb.ToString();
        }

        static string RedactLine(string line, ref bool inAuth)
        {
            // "HH:mm:ss.fff TAG DATA  [CONTEXT]"
            if (line.Length < 15 || line[2] != ':' || line[5] != ':' || line[8] != '.' || line[12] != ' ') return line;
            int tagEnd = line.IndexOf(' ', 13);
            string tag = tagEnd < 0 ? line.Substring(13) : line.Substring(13, tagEnd - 13);
            string rest = tagEnd < 0 ? "" : line.Substring(tagEnd + 1);
            string data = rest, ctx = "";
            if (rest.EndsWith("]", StringComparison.Ordinal))
            {
                int open = rest.LastIndexOf("  [", StringComparison.Ordinal);
                if (open >= 0) { data = rest.Substring(0, open); ctx = rest.Substring(open + 3, rest.Length - open - 4); }
            }
            string cd = data, cc = ctx;
            if (tag == "C:") { string clean; SmtpCommand cmd = Command(data, ref inAuth, out clean); cd = clean; }
            else if (tag == "S:") cd = CleanResponse(data, ref inAuth);
            else if (tag == "*") { IdKind k; string a; ClassifyEvent(data, ctx, inAuth, out cd, out cc, out k, out a); }
            else return line;
            if (cd == data && cc == ctx) return line;
            return line.Substring(0, 13) + tag + " " + cd + (cc.Length > 0 ? "  [" + cc + "]" : "");
        }
    }

    /// <summary>Presentation of the authentication values of a transaction (HTML, CSV and message routes).</summary>
    internal static class SmtpAuthView
    {
        public const string NotAvailable = "Not available";
        public const string Columns = "auth_mechanism, auth_result, auth_attempt_result, auth_user, auth_source";
        public static readonly string[] Names = { "Authentication mechanism", "Authentication result", "Last AUTH attempt", "Authenticated user", "Identity evidence" };
        // Written by a development build that stopped collecting evidence at a size limit; it is never a result any more: shown as Missing.
        const string RetiredSource = "Overflow";

        static string Text(object v) { return v == null || v is DBNull ? null : Convert.ToString(v, CultureInfo.InvariantCulture); }

        static bool Retired(object source) { return Text(source) == RetiredSource; }

        public static string Mechanism(object mechanism, object source)
        {
            if (Retired(source)) return NotAvailable;
            string m = Text(mechanism);
            if (m != null) return m;
            return Text(source) == SmtpAuth.NotApplicable ? "None" : NotAvailable;
        }

        public static string Result(object v) { return Text(v) ?? SmtpAuth.Unknown; }
        public static string Attempt(object v) { return Text(v) ?? SmtpAuth.Unknown; }
        public static string User(object v) { return Text(v) ?? NotAvailable; }

        public static string Evidence(object source)
        {
            switch (Text(source))
            {
                case SmtpAuth.Direct: return "Direct server log";
                case SmtpAuth.FrontEndProxy: return "Front end proxy";
                case SmtpAuth.Missing: return "Missing";
                case RetiredSource: return "Missing";
                case SmtpAuth.NotApplicable: return "Not applicable";
                case SmtpAuth.Ambiguous: return "Ambiguous";
                default: return "Legacy";
            }
        }

        /// <summary>The five display values of the columns auth_mechanism, auth_result, auth_attempt_result, auth_user, auth_source read at the offset of a row.</summary>
        public static string[] Fields(object[] row, int offset)
        {
            if (Retired(row[offset + 4])) return new[] { NotAvailable, SmtpAuth.Unknown, SmtpAuth.Unknown, NotAvailable, "Missing" };
            return new[] { Mechanism(row[offset], row[offset + 4]), Result(row[offset + 1]), Attempt(row[offset + 2]), User(row[offset + 3]), Evidence(row[offset + 4]) };
        }
    }

    /// <summary>
    /// Distinct authenticated users of each SMTP client for the report: kept in the private scratch database (never in memory, a shared
    /// relay can have thousands of accounts) and read one client at a time. Accounts are compared as the report compares identifiers.
    /// </summary>
    internal sealed class SmtpAuthAccounts : IDisposable
    {
        readonly ReportScratch _scratch;
        readonly string _table;
        readonly SqliteCommand _insert, _list;
        long _lastClient = -1;
        string _lastAccount;

        public SmtpAuthAccounts(ReportScratch scratch)
        {
            _scratch = scratch;
            _table = "a" + scratch.NewId();
            using (var c = scratch.Command("CREATE TABLE " + _table + "(client INTEGER NOT NULL, account TEXT NOT NULL COLLATE EXL_REPORT_ID, PRIMARY KEY(client, account)) WITHOUT ROWID;"))
                c.ExecuteNonQuery();
            _insert = scratch.Own(scratch.Command("INSERT OR IGNORE INTO " + _table + "(client,account) VALUES(@c,@a);"));
            _insert.Parameters.Add("@c", SqliteType.Integer); _insert.Parameters.Add("@a", SqliteType.Text);
            _insert.Prepare();
            _list = scratch.Own(scratch.Command("SELECT account FROM " + _table + " WHERE client=@c ORDER BY account;"));
            _list.Parameters.Add("@c", SqliteType.Integer);
            _list.Prepare();
        }

        public void Add(long client, string account)
        {
            if (client == _lastClient && string.Equals(account, _lastAccount, StringComparison.OrdinalIgnoreCase)) return;
            _insert.Parameters["@c"].Value = client; _insert.Parameters["@a"].Value = account;
            _insert.ExecuteNonQuery();
            _lastClient = client; _lastAccount = account;
        }

        /// <summary>Complete list of the accounts of a client, or the display text when there is none.</summary>
        public string List(long client)
        {
            var names = new List<string>();
            _list.Parameters["@c"].Value = client;
            using (var r = _list.ExecuteReader())
                while (r.Read()) names.Add(r.GetString(0));
            return names.Count == 0 ? SmtpAuthView.NotAvailable : string.Join(", ", names);
        }

        public void Dispose()
        {
            _insert.Dispose(); _list.Dispose();
            _scratch.Forget(_insert); _scratch.Forget(_list);
            using (var c = _scratch.Command("DROP TABLE " + _table + ";")) c.ExecuteNonQuery();
        }
    }

    // ===================================================================== evidence of a session

    /// <summary>
    /// One typed observation of an SMTP session. K: C connect, D disconnect, B AUTH begin, H challenge, R AUTH result, I identity, P proxy set-up,
    /// X XPROXY, Y XPROXY reply, T STARTTLS done, U STARTTLS refused, E EHLO/HELO host name, K command barrier, M MAIL.
    /// Pos orders the observations of an epoch: the sequence number, or the physical offset of the line in a log without sequence numbers;
    /// Sub orders the observations of one line.
    /// </summary>
    internal sealed class AuthObs
    {
        public char K;
        public long Ms, Seq = -1, Off = -1, Pos;
        public int Sub, Code;
        public bool Conflict;
        public string A, B;
        public long Frag;   // fragment that holds it (resolver)
    }

    /// <summary>A bounded piece of the evidence of one session, as written in smtp_auth_fragment. Part is the logical number in the session.</summary>
    internal sealed class AuthFragment
    {
        public const int CurrentFormat = 2;
        public string Server, Direction, Role, Connector, SessionId, LocalEp, RemoteEp, Helo, SourceKey, Coverage, ProxySid, ProxyIp, ProxyHelo, Observations;
        public long FirstOffset, FirstMs, LastMs, FirstSeq = -1, LastSeq = -1, ProxyPort, OriginMs;
        public long Part;
        public int Format = CurrentFormat;
        public bool CompleteStart, CompleteEnd, HasMail;

        /// <summary>The number of the part in the database: format 2 stores -1-part, so that it never meets a part of the first format.</summary>
        public long StoredPart { get { return Format >= 2 ? -1L - Part : Part; } }
    }

    /// <summary>The place of a MAIL in the evidence: the part that really holds it and its position (sequence number, or -(offset+2) without sequence numbers).</summary>
    internal struct MailRef
    {
        public bool Valid;
        public long Part;
        public long Position;
    }

    /// <summary>Receives the parts of a session as soon as they are sealed.</summary>
    internal interface ISmtpSink
    {
        void AddPart(long session, AuthFragment part);
    }

    /// <summary>
    /// Follows one SMTP session during the parse: redacts what must not be stored and records the observations the resolver needs.
    /// It decides nothing: whether a MAIL was authenticated, and as whom, is evaluated afterwards from the whole epoch. A part is sealed and
    /// drained to the sink when it reaches 256 observations, 64 ranges of sequence numbers or 128 KiB; the session continues in the next one.
    /// </summary>
    internal sealed class SmtpAuthTracker
    {
        public const int PartObservations = 256, PartRanges = 64, PartBytes = 131072, MaxPending = 8;
        readonly bool _observe;
        readonly AuthFragment _head;
        readonly ISmtpSink _sink;
        readonly long _session;
        readonly List<char> _pending = new List<char>();
        readonly List<long[]> _coverage = new List<long[]>();
        readonly List<AuthObs> _obs = new List<AuthObs>();
        bool _inAuth, _first = true, _sawCommand, _afterAuth, _unknownOwner, _partMail;
        int _bytes, _sub;
        long _logical;
        long _partFirstMs = -1, _partLastMs, _curMs, _curSeq = -1, _curOff = -1;
        string _proxySid, _proxyIp, _proxyHelo;
        long _proxyPort;
        public bool SawConnect, SawDisconnect, HasMail, HasProxy, HasAuth;
        public long Total;
        public string LastMechanism;

        public SmtpAuthTracker(bool observe, AuthFragment head, ISmtpSink sink, long session)
        {
            _observe = observe; _head = head; _sink = sink; _session = session;
        }

        /// <summary>Observations waiting in the part being built (never more than PartObservations).</summary>
        public int Live { get { return _obs.Count; } }

        void Add(char kind, long ms, long seq, long off, string a, string b, int code)
        {
            int cost = 128 + (a == null ? 0 : JsonEncodedText.Encode(a).EncodedUtf8Bytes.Length)
                + (b == null ? 0 : JsonEncodedText.Encode(b).EncodedUtf8Bytes.Length);
            if (_obs.Count >= PartObservations || (_obs.Count > 0 && _bytes + cost > PartBytes)) Seal(false);
            _obs.Add(new AuthObs { K = kind, Ms = ms, Seq = seq, Off = off, Sub = _sub++, A = a, B = b, Code = code });
            _bytes += cost;
            Total++;
            if (kind == 'M') _partMail = true;
            if (kind == 'X' && a != null && _proxySid == null)
            {
                var p = b.Split('|');
                int port;
                _proxySid = a; _proxyIp = p[0];
                _proxyPort = int.TryParse(p[1], NumberStyles.None, CultureInfo.InvariantCulture, out port) ? port : 0;
                _proxyHelo = p.Length > 2 && p[2].Length > 0 ? p[2] : null;
            }
        }

        void Cover(long seq)
        {
            if (seq < 0) return;
            if (_coverage.Count > 0)
            {
                var last = _coverage[_coverage.Count - 1];
                if (seq == last[1] + 1) { last[1] = seq; return; }
                if (seq <= last[1]) return;
                if (_coverage.Count >= PartRanges) Seal(false);
            }
            _coverage.Add(new[] { seq, seq });
        }

        /// <summary>Writes the part being built to the sink and starts the next one; the state of the session is not touched.</summary>
        void Seal(bool last)
        {
            if (_obs.Count == 0 && _coverage.Count == 0 && !last) return;
            var f = new AuthFragment
            {
                Server = _head.Server, Direction = _head.Direction, Role = _head.Role, Connector = _head.Connector, SessionId = _head.SessionId, LocalEp = _head.LocalEp,
                RemoteEp = _head.RemoteEp, Helo = _head.Helo, SourceKey = _head.SourceKey, FirstOffset = _head.FirstOffset, OriginMs = _head.FirstMs,
                FirstMs = _partFirstMs >= 0 ? _partFirstMs : _head.FirstMs, LastMs = _partLastMs > 0 ? _partLastMs : _head.FirstMs,
                Part = _logical, CompleteStart = _logical == 0 && SawConnect, CompleteEnd = last && SawDisconnect, HasMail = _partMail,
                ProxySid = _proxySid, ProxyIp = _proxyIp, ProxyPort = _proxyPort, ProxyHelo = _proxyHelo,
                Coverage = string.Join(",", _coverage.Select(i => i[0].ToString(CultureInfo.InvariantCulture) + "-" + i[1].ToString(CultureInfo.InvariantCulture))),
                Observations = SmtpAuthStore.Write(_obs, 0, _obs.Count)
            };
            if (_coverage.Count > 0) { f.FirstSeq = _coverage[0][0]; f.LastSeq = _coverage[_coverage.Count - 1][1]; }
            _sink.AddPart(_session, f);
            _logical++;
            _obs.Clear(); _coverage.Clear(); _bytes = 0; _partMail = false; _partFirstMs = last ? -1 : _curMs;
        }

        void Push(char verb)
        {
            if (_unknownOwner) return;
            if (_pending.Count >= MaxPending)
            {
                // Too many commands without a reply: which command a later reply answers is not known any more. It is recorded, never guessed.
                _pending.Clear();
                _unknownOwner = true;
                Add('K', _curMs, _curSeq, _curOff, "u", null, 0);
                return;
            }
            _pending.Add(verb);
        }

        char Pop()
        {
            if (_pending.Count == 0) return '\0';
            char v = _pending[0];
            _pending.RemoveAt(0);
            return v;
        }

        void DropAuthPending() { int i = _pending.IndexOf('A'); if (i >= 0) _pending.RemoveAt(i); }

        /// <summary>Processes one line; returns the text that may be stored. payload: the line is the opaque payload of an AUTH exchange.</summary>
        public void Line(string evt, bool command, bool response, long ms, long seq, long off, string data, string ctx, out string cleanData, out string cleanCtx, out bool payload)
        {
            cleanData = data; cleanCtx = ctx; payload = false;
            _sub = 0;
            _curMs = ms; _curSeq = seq; _curOff = off;
            if (_observe)
            {
                Cover(seq);
                if (_partFirstMs < 0) _partFirstMs = ms;
                _partLastMs = ms;
            }
            if (evt == "+")
            {
                if (_observe) Add('C', ms, seq, off, null, null, 0);
                _pending.Clear(); _inAuth = false; _first = false; _afterAuth = false; _unknownOwner = false; SawConnect = true;
                return;
            }
            if (evt == "-")
            {
                if (_observe) { Add('D', ms, seq, off, null, null, 0); SawDisconnect = true; }
                _inAuth = false; _first = false;
                return;
            }
            if (evt == "*")
            {
                _first = false;
                IdKind kind; string account;
                int type = SmtpAuth.ClassifyEvent(data, ctx, _inAuth, out cleanData, out cleanCtx, out kind, out account);
                if (_observe && type != 0)
                {
                    Add(type == 1 ? 'I' : 'P', ms, seq, off, account, kind == IdKind.User ? "u" : kind == IdKind.Technical ? "t" : "x", 0);
                    if (type == 2) HasProxy = true;
                    HasAuth = true;
                }
                return;
            }
            if (command) Command(ms, seq, off, data, out cleanData, out payload);
            else if (response) Response(ms, seq, off, data, out cleanData);
        }

        void Command(long ms, long seq, long off, string data, out string clean, out bool payload)
        {
            bool wasAuth = _inAuth;
            SmtpCommand cmd = SmtpAuth.Command(data, ref _inAuth, out clean);
            payload = cmd.Kind == 'p';
            if (cmd.Kind == 'A') LastMechanism = cmd.Mech;
            if (payload) { _first = false; return; }
            _sawCommand = true;
            if (!_observe) { _first = false; return; }
            bool barrier = false;
            if (wasAuth && (cmd.Kind == 'c' || cmd.Kind == 'q' || cmd.Kind == 'r' || cmd.Interrupted))
            {
                Add('K', ms, seq, off, cmd.Kind == 'c' || cmd.Kind == 'q' || cmd.Kind == 'r' ? cmd.Kind.ToString() : "o", null, 0);
                DropAuthPending();
                barrier = true;
            }
            else if (_first && cmd.Kind != 'A') { Add('K', ms, seq, off, "o", null, 0); barrier = true; }
            // Whatever command follows a successful AUTH ends the place where the server may still complete it with an identity, even when
            // that command leaves no observation of its own (NOOP...). The window is the reply line of the 235 and its annotations.
            if (_afterAuth && !barrier && cmd.Kind != 'A' && cmd.Kind != 'X') Add('K', ms, seq, off, "o", null, 0);
            _afterAuth = false;
            _first = false;
            switch (cmd.Kind)
            {
                case 'A':
                    Add('B', ms, seq, off, cmd.Mech, SmtpAuth.IsTechnicalMechanism(cmd.Mech) ? "T" : null, 0);
                    HasAuth = true;
                    Push('A');
                    break;
                case 'X':
                    Add('X', ms, seq, off, cmd.Proxy.Valid ? cmd.Proxy.Sid : null, cmd.Proxy.Valid ? cmd.Proxy.Ip + "|" + cmd.Proxy.Port.ToString(CultureInfo.InvariantCulture) + "|" + cmd.Proxy.Helo : "!", 0);
                    HasProxy = true;
                    Push('P');
                    break;
                case 'E':
                    Add('E', ms, seq, off, cmd.Mech, null, 0);
                    Push('o');
                    break;
                case 'T': Push('T'); break;
                case 'c': case 'q': case 'r': break;
                default: Push('o'); break;
            }
        }

        void Response(long ms, long seq, long off, string data, out string clean)
        {
            bool inAuthBefore = _inAuth;
            clean = SmtpAuth.CleanResponse(data, ref _inAuth);
            _first = false;
            if (!_observe) return;
            int code = SmtpAuth.Code(data);
            bool continuation = data != null && data.Length > 3 && data[3] == '-';
            bool ownsAuth = !_unknownOwner && _pending.Count > 0 && _pending[0] == 'A';
            if (code == 334) { if (ownsAuth) Add('H', ms, seq, off, null, null, code); return; }
            if (code == 0 || continuation) return;
            if (inAuthBefore && ownsAuth)
            {
                DropAuthPending();
                // Only the answer to an AUTH exchange can be the success of that exchange: 235.
                string result = code == 235 ? "ok" : SmtpAuth.AlreadyAuthenticated(code, data) ? "already" : "fail";
                Add('R', ms, seq, off, result, null, code);
                _afterAuth = code == 235;
                return;
            }
            if (_unknownOwner) return;
            if (_pending.Count > 0)
            {
                char v = Pop();
                if (v == 'P') Add('Y', ms, seq, off, null, null, code);
                else if (v == 'T') Add(code < 300 ? 'T' : 'U', ms, seq, off, null, null, code);
            }
            else if (!_sawCommand && SmtpAuth.IsAuthCode(code))
                Add('R', ms, seq, off, "?", null, code);
        }

        /// <summary>MAIL FROM of a transaction that will be stored: its position is where the state of the authentication is read.</summary>
        public MailRef Mail(long ms, long seq, long off, bool kept)
        {
            if (!_observe || !kept) return default(MailRef);
            long position = seq >= 0 ? seq : -(off + 2);
            Add('M', ms, seq, off, position.ToString(CultureInfo.InvariantCulture), null, 0);
            HasMail = true;
            return new MailRef { Valid = true, Part = _logical, Position = position };
        }

        /// <summary>
        /// Seals the last part. Returns the number of parts of the session, or 0 when it carries nothing the resolver could use (a plain probe
        /// stays noise, and so does a complete session without any AUTH, mail or proxy that cannot be continued): the caller then drops the
        /// parts already drained.
        /// </summary>
        public long Finish(long retentionCutoffMs)
        {
            if (!_observe || (Total == 0 && _coverage.Count == 0 && _logical == 0)) return 0;
            bool complete = SawConnect && SawDisconnect;
            if (!(HasMail || HasProxy || HasAuth) && complete) return 0;
            if (_partLastMs < retentionCutoffMs) return 0;
            Seal(true);
            return _logical;
        }
    }

    /// <summary>Compact JSON of the observations: [kind, ms, seq, a, b, code, offset, subordinal]. Six-cell arrays (first format) are still read.</summary>
    internal static class SmtpAuthStore
    {
        public static string Write(List<AuthObs> list, int from, int count)
        {
            using (var ms = new MemoryStream())
            {
                using (var w = new Utf8JsonWriter(ms))
                {
                    w.WriteStartArray();
                    for (int i = from; i < from + count; i++)
                    {
                        var o = list[i];
                        w.WriteStartArray();
                        w.WriteStringValue(o.K.ToString());
                        w.WriteNumberValue(o.Ms);
                        w.WriteNumberValue(o.Seq);
                        if (o.A == null) w.WriteNullValue(); else w.WriteStringValue(o.A);
                        if (o.B == null) w.WriteNullValue(); else w.WriteStringValue(o.B);
                        w.WriteNumberValue(o.Code);
                        w.WriteNumberValue(o.Off);
                        w.WriteNumberValue(o.Sub);
                        w.WriteEndArray();
                    }
                    w.WriteEndArray();
                }
                return Encoding.UTF8.GetString(ms.ToArray());
            }
        }

        /// <summary>Reads a part. part: its logical number (positions of the first format without sequence numbers derive from it).</summary>
        public static List<AuthObs> Read(string json, long fragmentId, long part)
        {
            var list = new List<AuthObs>();
            if (string.IsNullOrEmpty(json)) return list;
            using (var doc = JsonDocument.Parse(json))
            {
                int index = 0;
                long previousPos = long.MinValue;
                int sub = 0;
                foreach (var e in doc.RootElement.EnumerateArray())
                {
                    var o = new AuthObs
                    {
                        K = e[0].GetString()[0], Ms = e[1].GetInt64(), Seq = e[2].GetInt64(),
                        A = e[3].ValueKind == JsonValueKind.Null ? null : e[3].GetString(),
                        B = e[4].ValueKind == JsonValueKind.Null ? null : e[4].GetString(),
                        Code = e[5].GetInt32(), Frag = fragmentId
                    };
                    if (e.GetArrayLength() >= 8)
                    {
                        o.Off = e[6].GetInt64(); o.Sub = e[7].GetInt32();
                        o.Pos = o.Seq >= 0 ? o.Seq : o.Off;
                    }
                    else
                    {
                        // First format: no offset, the subordinal is the order inside the array.
                        o.Pos = o.Seq >= 0 ? o.Seq : (long)part * 256 + index;
                        sub = o.Pos == previousPos ? sub + 1 : 0;
                        o.Sub = sub;
                        long ordinal;
                        if (o.K == 'M' && o.Seq < 0 && long.TryParse(o.A, NumberStyles.None, CultureInfo.InvariantCulture, out ordinal)) o.A = (-(ordinal + 2)).ToString(CultureInfo.InvariantCulture);
                        else if (o.K == 'M') o.A = o.Seq.ToString(CultureInfo.InvariantCulture);
                    }
                    previousPos = o.Pos;
                    list.Add(o);
                    index++;
                }
            }
            return list;
        }

        public static List<long[]> ReadCoverage(string text)
        {
            var list = new List<long[]>();
            if (string.IsNullOrEmpty(text)) return list;
            foreach (var part in text.Split(','))
            {
                int dash = part.IndexOf('-');
                long lo, hi;
                if (dash > 0 && long.TryParse(part.Substring(0, dash), NumberStyles.None, CultureInfo.InvariantCulture, out lo) && long.TryParse(part.Substring(dash + 1), NumberStyles.None, CultureInfo.InvariantCulture, out hi))
                    list.Add(new[] { lo, hi });
            }
            return list;
        }
    }

    // ===================================================================== parse spool

    /// <summary>
    /// A finished transaction of a session, with the scalars that are stored (Body: preamble excluded, Response: as logged; neither is spooled).
    /// The parse thread computes the stored values, the apply thread only binds them: PackedTranscript is Pack(Cap(preamble + Body, 12000))
    /// (null without transcript), PackedResponse is Packed.Adaptive(Response), MessageHash is Store.MessageHash(MessageId).
    /// </summary>
    internal sealed class SmtpSpoolTx
    {
        public long StartMs, EndMs, Rcpts, Position;
        public long Part = -1;
        public string MailFrom, RcptText, MessageId, InternalId, Status, Response, Body;
        public byte[] PackedTranscript;
        public object PackedResponse;
        public long? MessageHash;
    }

    /// <summary>The final metadata of a finished session and the number of its parts and transactions.</summary>
    internal sealed class SmtpSpoolSession
    {
        public long Ord, Id;
        public long Parts;
        public int Txns;
        public string SessionId, Connector, Local, Remote, Helo, Tls, Auth, ProxyIp, ProxyPort, ProxyHelo;
    }

    /// <summary>
    /// What a file produced for the SMTP tables, kept on disk while the file is being parsed: the evidence parts and the finished
    /// transactions of the sessions, which are written to the database page by page by the apply thread. It is a private work file
    /// (ReportScratch), never read by anything else, and deleted when the file is done, failed or abandoned.
    /// </summary>
    internal sealed class SmtpSpool : IDisposable, ISmtpSink
    {
        readonly ReportScratch _scratch;
        SqliteCommand _addPart, _addTx, _addSession, _dropParts, _sessions, _part, _txs, _rawBodies, _packBody;
        long _nextId;
        bool _open, _disposed;
        public long Parts, Transactions, Sessions;

        public SmtpSpool(string folder) { _scratch = new ReportScratch(folder, 0); }

        SqliteCommand Prepare(string sql, string types)
        {
            var c = _scratch.Own(_scratch.Command(sql));
            for (int i = 0; i < types.Length; i++) c.Parameters.Add("@p" + i.ToString(CultureInfo.InvariantCulture), types[i] == 'b' ? SqliteType.Blob : SqliteType.Integer);
            c.Prepare();
            return c;
        }

        void Open()
        {
            if (_open) return;
            // Several parsed files can await APPLY simultaneously; each spool owns a small, fixed cache.
            using (var c = _scratch.Command("PRAGMA cache_size=-2048;")) c.ExecuteNonQuery();
            foreach (var sql in new[] {
                "CREATE TABLE sp_part(sid INTEGER NOT NULL, part INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(sid, part)) WITHOUT ROWID;",
                // transcript: the packed transcript (raw 0), or the UTF-8 body of a transaction written before the end of its session (raw 1, packed by PackTranscripts).
                "CREATE TABLE sp_tx(sid INTEGER NOT NULL, ord INTEGER NOT NULL, data BLOB NOT NULL, transcript BLOB, raw INTEGER NOT NULL, PRIMARY KEY(sid, ord)) WITHOUT ROWID;",
                "CREATE TABLE sp_session(ord INTEGER PRIMARY KEY AUTOINCREMENT, sid INTEGER NOT NULL, data BLOB NOT NULL);" })
                using (var c = _scratch.Command(sql)) c.ExecuteNonQuery();
            _addPart = Prepare("INSERT INTO sp_part(sid,part,data) VALUES(@p0,@p1,@p2);", "iib");
            _addTx = Prepare("INSERT INTO sp_tx(sid,ord,data,transcript,raw) VALUES(@p0,@p1,@p2,@p3,@p4);", "iibbi");
            _rawBodies = Prepare("SELECT ord, transcript FROM sp_tx WHERE sid=@p0 AND raw=1 AND ord>=@p1 ORDER BY ord LIMIT @p2;", "iii");
            _packBody = Prepare("UPDATE sp_tx SET transcript=@p2, raw=0 WHERE sid=@p0 AND ord=@p1;", "iib");
            _addSession = Prepare("INSERT INTO sp_session(sid,data) VALUES(@p0,@p1);", "ib");
            _dropParts = Prepare("DELETE FROM sp_part WHERE sid=@p0;", "i");
            _sessions = Prepare("SELECT ord, sid, data FROM sp_session WHERE ord>@p0 ORDER BY ord LIMIT @p1;", "ii");
            _part = Prepare("SELECT data FROM sp_part WHERE sid=@p0 AND part=@p1;", "ii");
            _txs = Prepare("SELECT ord, data, transcript, raw FROM sp_tx WHERE sid=@p0 AND ord>=@p1 ORDER BY ord LIMIT @p2;", "iii");
            _open = true;
        }

        /// <summary>A number for a session that starts; its parts and transactions are written under it.</summary>
        public long NewSession() { return ++_nextId; }

        static void Put(BinaryWriter w, string s) { if (s == null) w.Write(false); else { w.Write(true); w.Write(s); } }
        static string Get(BinaryReader r) { return r.ReadBoolean() ? r.ReadString() : null; }

        public void AddPart(long session, AuthFragment f)
        {
            Open();
            byte[] data;
            using (var ms = new MemoryStream())
            {
                using (var w = new BinaryWriter(ms, Encoding.UTF8, true))
                {
                    foreach (var s in new[] { f.Server, f.Direction, f.Role, f.Connector, f.SessionId, f.LocalEp, f.RemoteEp, f.Helo, f.SourceKey, f.Coverage, f.ProxySid, f.ProxyIp, f.ProxyHelo, f.Observations }) Put(w, s);
                    foreach (long n in new[] { f.FirstOffset, f.FirstMs, f.LastMs, f.FirstSeq, f.LastSeq, f.ProxyPort, f.OriginMs, (long)f.Part, (long)f.Format }) w.Write(n);
                    w.Write(f.CompleteStart); w.Write(f.CompleteEnd); w.Write(f.HasMail);
                }
                data = ms.ToArray();
            }
            _addPart.Parameters[0].Value = session; _addPart.Parameters[1].Value = (long)f.Part; _addPart.Parameters[2].Value = data;
            try { _addPart.ExecuteNonQuery(); }
            finally { foreach (SqliteParameter p in _addPart.Parameters) p.Value = DBNull.Value; }
            Parts++;
        }

        public AuthFragment ReadPart(long session, long part)
        {
            Open();
            _part.Parameters[0].Value = session; _part.Parameters[1].Value = (long)part;
            byte[] data;
            using (var r = _part.ExecuteReader())
            {
                if (!r.Read()) throw new InvalidOperationException("An evidence part of the SMTP spool is missing.");
                data = (byte[])r.GetValue(0);
            }
            using (var ms = new MemoryStream(data, false))
            using (var rd = new BinaryReader(ms, Encoding.UTF8))
            {
                var f = new AuthFragment();
                f.Server = Get(rd); f.Direction = Get(rd); f.Role = Get(rd); f.Connector = Get(rd); f.SessionId = Get(rd); f.LocalEp = Get(rd); f.RemoteEp = Get(rd);
                f.Helo = Get(rd); f.SourceKey = Get(rd); f.Coverage = Get(rd); f.ProxySid = Get(rd); f.ProxyIp = Get(rd); f.ProxyHelo = Get(rd); f.Observations = Get(rd);
                f.FirstOffset = rd.ReadInt64(); f.FirstMs = rd.ReadInt64(); f.LastMs = rd.ReadInt64(); f.FirstSeq = rd.ReadInt64(); f.LastSeq = rd.ReadInt64();
                f.ProxyPort = rd.ReadInt64(); f.OriginMs = rd.ReadInt64(); f.Part = rd.ReadInt64(); f.Format = (int)rd.ReadInt64();
                f.CompleteStart = rd.ReadBoolean(); f.CompleteEnd = rd.ReadBoolean(); f.HasMail = rd.ReadBoolean();
                return f;
            }
        }

        /// <summary>
        /// Writes a finished transaction: its stored values (PackedResponse, MessageHash) and its packed transcript, or, when the session is not
        /// finished yet (the preamble of the transcript may still grow), the UTF-8 bytes of its Body, packed by PackTranscripts at the end of the session.
        /// </summary>
        public void AddTx(long session, int ord, SmtpSpoolTx x)
        {
            Open();
            byte[] data;
            using (var ms = new MemoryStream())
            {
                using (var w = new BinaryWriter(ms, Encoding.UTF8, true))
                {
                    foreach (var s in new[] { x.MailFrom, x.RcptText, x.MessageId, x.InternalId, x.Status }) Put(w, s);
                    // Packed.Adaptive keeps a short or incompressible response as TEXT, else a packed BLOB.
                    if (x.PackedResponse == null) w.Write((byte)0);
                    else if (x.PackedResponse is byte[]) { var b = (byte[])x.PackedResponse; w.Write((byte)2); w.Write(b.Length); w.Write(b); }
                    else { w.Write((byte)1); w.Write((string)x.PackedResponse); }
                    foreach (long n in new[] { x.StartMs, x.EndMs, x.Rcpts, x.Position, (long)x.Part }) w.Write(n);
                    w.Write(x.MessageHash.HasValue); w.Write(x.MessageHash ?? 0L);
                }
                data = ms.ToArray();
            }
            // The same UTF-8 encoder as the BinaryWriter of the strings: what PackTranscripts reads back is what a spooled string gives back.
            object transcript = x.PackedTranscript != null ? x.PackedTranscript : x.Body != null ? (object)Encoding.UTF8.GetBytes(x.Body) : DBNull.Value;
            _addTx.Parameters[0].Value = session; _addTx.Parameters[1].Value = (long)ord; _addTx.Parameters[2].Value = data;
            _addTx.Parameters[3].Value = transcript; _addTx.Parameters[4].Value = x.PackedTranscript == null && x.Body != null ? 1L : 0L;
            try { _addTx.ExecuteNonQuery(); }
            finally { foreach (SqliteParameter p in _addTx.Parameters) p.Value = DBNull.Value; }
            Transactions++;
        }

        /// <summary>
        /// End of a session (parse thread): the transcripts of its transactions written before the end (raw bodies) are replaced by
        /// pack(body), page by page. Returns the number of transcripts packed.
        /// </summary>
        public int PackTranscripts(long session, Func<string, byte[]> pack)
        {
            if (!_open) return 0;
            int packed = 0;
            long first = 0;
            var page = new List<KeyValuePair<long, string>>();
            while (true)
            {
                page.Clear();
                _rawBodies.Parameters[0].Value = session; _rawBodies.Parameters[1].Value = first; _rawBodies.Parameters[2].Value = 32L;
                using (var r = _rawBodies.ExecuteReader())
                    while (r.Read()) page.Add(new KeyValuePair<long, string>(r.GetInt64(0), Encoding.UTF8.GetString((byte[])r.GetValue(1))));
                foreach (var kv in page)
                {
                    _packBody.Parameters[0].Value = session; _packBody.Parameters[1].Value = kv.Key; _packBody.Parameters[2].Value = pack(kv.Value);
                    try { _packBody.ExecuteNonQuery(); }
                    finally { foreach (SqliteParameter p in _packBody.Parameters) p.Value = DBNull.Value; }
                    packed++;
                }
                if (page.Count < 32) break;
                first = page[page.Count - 1].Key + 1;
            }
            return packed;
        }

        /// <summary>Up to limit transactions of a session starting at ordinal first (a finished session: every transcript is packed).</summary>
        public List<KeyValuePair<int, SmtpSpoolTx>> ReadTx(long session, int first, int limit)
        {
            Open();
            var list = new List<KeyValuePair<int, SmtpSpoolTx>>();
            _txs.Parameters[0].Value = session; _txs.Parameters[1].Value = (long)first; _txs.Parameters[2].Value = (long)limit;
            using (var r = _txs.ExecuteReader())
                while (r.Read())
                    using (var ms = new MemoryStream((byte[])r.GetValue(1), false))
                    using (var rd = new BinaryReader(ms, Encoding.UTF8))
                    {
                        if (r.GetInt64(3) != 0) throw new InvalidOperationException("A transcript of the SMTP spool was not packed at the end of its session.");
                        var x = new SmtpSpoolTx();
                        x.MailFrom = Get(rd); x.RcptText = Get(rd); x.MessageId = Get(rd); x.InternalId = Get(rd); x.Status = Get(rd);
                        byte kind = rd.ReadByte();
                        if (kind == 2) x.PackedResponse = rd.ReadBytes(rd.ReadInt32());
                        else if (kind == 1) x.PackedResponse = rd.ReadString();
                        x.StartMs = rd.ReadInt64(); x.EndMs = rd.ReadInt64(); x.Rcpts = rd.ReadInt64(); x.Position = rd.ReadInt64(); x.Part = rd.ReadInt64();
                        bool hashed = rd.ReadBoolean(); long hash = rd.ReadInt64();
                        if (hashed) x.MessageHash = hash;
                        if (!r.IsDBNull(2)) x.PackedTranscript = (byte[])r.GetValue(2);
                        list.Add(new KeyValuePair<int, SmtpSpoolTx>((int)r.GetInt64(0), x));
                    }
            return list;
        }

        /// <summary>The session is finished: from now on it is applied. A session without part nor transaction is not written.</summary>
        public void Finish(long session, SmtpSpoolSession s)
        {
            if (s.Parts == 0 && s.Txns == 0) return;
            Open();
            byte[] data;
            using (var ms = new MemoryStream())
            {
                using (var w = new BinaryWriter(ms, Encoding.UTF8, true))
                {
                    foreach (var t in new[] { s.SessionId, s.Connector, s.Local, s.Remote, s.Helo, s.Tls, s.Auth, s.ProxyIp, s.ProxyPort, s.ProxyHelo }) Put(w, t);
                    w.Write(s.Parts); w.Write(s.Txns);
                }
                data = ms.ToArray();
            }
            _addSession.Parameters[0].Value = session; _addSession.Parameters[1].Value = data;
            try { _addSession.ExecuteNonQuery(); }
            finally { foreach (SqliteParameter p in _addSession.Parameters) p.Value = DBNull.Value; }
            Sessions++;
        }

        /// <summary>The evidence parts already written for a session that carries nothing to keep are removed (its transactions stay).</summary>
        public void Drop(long session)
        {
            if (!_open) return;
            _dropParts.Parameters[0].Value = session; _dropParts.ExecuteNonQuery();
        }

        /// <summary>Up to limit finished sessions after the ordinal after.</summary>
        public List<SmtpSpoolSession> ReadSessions(long after, int limit)
        {
            var list = new List<SmtpSpoolSession>();
            if (!_open) return list;
            _sessions.Parameters[0].Value = after; _sessions.Parameters[1].Value = (long)limit;
            using (var r = _sessions.ExecuteReader())
                while (r.Read())
                    using (var ms = new MemoryStream((byte[])r.GetValue(2), false))
                    using (var rd = new BinaryReader(ms, Encoding.UTF8))
                    {
                        var s = new SmtpSpoolSession { Ord = r.GetInt64(0), Id = r.GetInt64(1) };
                        s.SessionId = Get(rd); s.Connector = Get(rd); s.Local = Get(rd); s.Remote = Get(rd); s.Helo = Get(rd); s.Tls = Get(rd); s.Auth = Get(rd);
                        s.ProxyIp = Get(rd); s.ProxyPort = Get(rd); s.ProxyHelo = Get(rd);
                        s.Parts = rd.ReadInt64(); s.Txns = rd.ReadInt32();
                        list.Add(s);
                    }
            return list;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _scratch.Dispose();
        }
    }

    // ===================================================================== resolver

    /// <summary>The evidence of one connection ('+' to '-'), possibly read in several parts, files and collections.</summary>
    internal sealed class AuthEpoch
    {
        public int Index;
        public string Server, Direction, Role, Connector, SessionId, LocalEp, RemoteEp, Helo;
        public long FirstMs, LastMs, FirstSeq = -1, LastSeq = -1;
        public bool CompleteStart, CompleteEnd, SeqLess, SeqLessOk, Legacy;
        public int Origins;
    }

    /// <summary>The five values of a transaction and, for a back end handed over by a front end, the handshake that must still be resolved.</summary>
    internal sealed class AuthSnap
    {
        public string Mechanism, Result, Attempt, User, Source;
        public long Evidence;
        public AuthBind Bind;
    }

    /// <summary>The XPROXY handshake of a back-end connection. Ms: the command, AcceptMs: its positive reply.</summary>
    internal sealed class AuthBind
    {
        public string Sid, Ip, Helo, PeerHelo;
        public int Port;
        public long Ms, AcceptMs;
        public bool Valid, Accepted, Broken;
        public AuthToken Token;
    }

    /// <summary>What the front end proved for one handshake, resolved once per handshake.</summary>
    internal sealed class AuthToken
    {
        public const string Ok = "Ok";
        public string Status = SmtpAuth.Missing, User, Mechanism, Attempt;
        public long Evidence, ReadyMs;
    }

    /// <summary>
    /// Evaluates again, inside the transaction of the batch, every session whose evidence changed. The evidence is read back from the
    /// database and replayed one connection at a time, in order, with scalar state only: what a transaction was authenticated as is
    /// decided from what happened before it, whatever the order of the files (several threads), the size of the batches or the collection
    /// that read each part of a session. All working sets live in a private scratch file; nothing grows with the number of sessions,
    /// parts or transactions. Only the queue of the sessions to evaluate is in memory: at most Limit touched sessions (the collection
    /// flushes at Limit) and the back-end sessions that depend on them.
    /// </summary>
    internal sealed class AuthResolver : IDisposable
    {
        public const int Limit = 4096;
        const int OriginPage = 32, PartPage = 32, EventPage = 256, DependentPage = 128;

        sealed class Origin
        {
            public string SourceKey;
            public long FirstOffset, OriginMs, FirstMs, LastMs, FirstSeq, LastSeq, Distinct, MaxLogical;
            public bool CompleteStart, CompleteEnd;
            public int MaxFormat, MinFormat;
        }

        sealed class Attempt
        {
            public string Mech, User;
            public bool Technical, StartUnknown, Reauth, HasProxy, TechId, Multi, Broken, Conflict;
            public long BeginPos, BeginMs, MaxPos, MaxMs, ProxyMs;
        }

        sealed class Principal
        {
            public string Mech, User, HeloAtSuccess, EndReason;
            public bool Technical, TechId, Ambiguous, Unattributable, StartUnknown, HasProxy, Broken, Conflict, Retired;
            public long BeginPos, BeginMs, EndPos, SuccessMs, ProxyMs, ReadyMs, EndMs = long.MaxValue, Evidence;
        }

        readonly Store _store;
        readonly Writer _writer;
        readonly SmtpClientMaintenance _clients;   // schema 11: set while the collection maintains the SMTP client structures itself (else the triggers queue the work)
        readonly long _idleMs;
        readonly Dictionary<string, SqliteCommand> _scratchCommands = new Dictionary<string, SqliteCommand>(StringComparer.Ordinal);
        readonly Dictionary<string, SqliteCommand> _mainCommands = new Dictionary<string, SqliteCommand>(StringComparer.Ordinal);
        ReportScratch _scratch;
        int _pending;
        SqliteTransaction _tx;
        public long Evaluated, Updated, Replayed;

        public AuthResolver(Store store, Writer writer, long idleMs) : this(store, writer, idleMs, null) { }
        public AuthResolver(Store store, Writer writer, long idleMs, SmtpClientMaintenance clients) { _store = store; _writer = writer; _idleMs = idleMs; _clients = clients; }

        public int Count { get { return _pending; } }

        static string Key(string server, string direction, string role, string sid) { return server + "\u0001" + direction + "\u0001" + role + "\u0001" + sid; }

        // The session queued by the last Touch: it is still waiting (not done) until Flush, so touching it again changes nothing (null after Flush and Clear).
        string _lastKey;

        // The sessions to evaluate, in the order they were first queued, each once per Flush: what the scratch table
        // queue(seq INTEGER PRIMARY KEY AUTOINCREMENT, k TEXT UNIQUE, server, direction, role, sid, done) held, with the same statements
        // (Touch: INSERT ... ON CONFLICT(k) DO UPDATE SET done=0 WHERE done=1; Enqueue: INSERT OR IGNORE; Flush: the first not done in seq order).
        sealed class Queued { public string Server, Direction, Role, Sid; public bool Done; }
        readonly List<Queued> _queue = new List<Queued>();
        readonly Dictionary<string, int> _queued = new Dictionary<string, int>(StringComparer.Ordinal);   // k -> place in _queue
        int _next;   // every session before it in _queue is done

        public void Touch(string server, string direction, string role, string sid)
        {
            string key = Key(server, direction, role ?? "", sid);
            if (key == _lastKey) return;
            if (Queue(key, server, direction, role ?? "", sid, true)) _pending++;
            _lastKey = key;
        }

        /// <summary>
        /// Queues a session (key: Key of the four texts); false when the statement of the former table changed no row (already queued: still
        /// waiting, or done and not a Touch). The texts are those the table gave back (UTF-8: a lone surrogate became U+FFFD), k compared as it did.
        /// </summary>
        bool Queue(string key, string server, string direction, string role, string sid, bool touch)
        {
            if (AsStored(key) != key) { server = AsStored(server); direction = AsStored(direction); role = AsStored(role); sid = AsStored(sid); key = Key(server, direction, role, sid); }
            int at;
            if (_queued.TryGetValue(key, out at))
            {
                var q = _queue[at];
                if (!touch || !q.Done) return false;
                q.Done = false;   // keeps its place (its seq)
                if (at < _next) _next = at;
                return true;
            }
            _queued[key] = _queue.Count;
            _queue.Add(new Queued { Server = server, Direction = direction, Role = role, Sid = sid });
            return true;
        }

        /// <summary>The text as a TEXT column gives it back: the same string, unless it holds a lone surrogate (U+FFFD in UTF-8).</summary>
        static string AsStored(string v)
        {
            if (v.AsSpan().IndexOfAnyInRange('\uD800', '\uDFFF') < 0) return v;
            return Encoding.UTF8.GetString(Encoding.UTF8.GetBytes(v));
        }

        void ClearQueue()
        {
            _queue.Clear();
            _queued.Clear();
            _next = 0;
        }

        /// <summary>Forgets the sessions waiting (the batch is rolled back) and what was left in the scratch file.</summary>
        public void Clear()
        {
            _pending = 0;
            _lastKey = null;
            ClearQueue();
            CloseScratch();
        }

        public void Dispose()
        {
            foreach (var c in _mainCommands.Values) c.Dispose();
            _mainCommands.Clear();
            ClearQueue();
            CloseScratch();
        }

        void CloseScratch()
        {
            _scratchCommands.Clear();
            if (_scratch != null) { _scratch.Dispose(); _scratch = null; }
        }

        // ---------------------------------------------------------------- scratch and statements

        void Open()
        {
            if (_scratch != null) return;
            string folder = Path.GetDirectoryName(Path.GetFullPath(_store.FilePath));
            _scratch = new ReportScratch(folder, 0);
            foreach (var sql in new[] {
                "CREATE TABLE ev(scope INTEGER NOT NULL, epoch INTEGER NOT NULL, pos INTEGER NOT NULL, sub INTEGER NOT NULL, k TEXT NOT NULL, ms INTEGER NOT NULL, seq INTEGER NOT NULL, a TEXT, b TEXT, code INTEGER NOT NULL, frag INTEGER NOT NULL, conflict INTEGER NOT NULL, PRIMARY KEY(scope, epoch, pos, sub)) WITHOUT ROWID;",
                "CREATE TABLE covraw(scope INTEGER NOT NULL, epoch INTEGER NOT NULL, lo INTEGER NOT NULL, hi INTEGER NOT NULL, PRIMARY KEY(scope, epoch, lo, hi)) WITHOUT ROWID;",
                "CREATE TABLE cov(scope INTEGER NOT NULL, epoch INTEGER NOT NULL, lo INTEGER NOT NULL, hi INTEGER NOT NULL, PRIMARY KEY(scope, epoch, lo)) WITHOUT ROWID;",
                "CREATE TABLE mref(scope INTEGER NOT NULL, epoch INTEGER NOT NULL, pos INTEGER NOT NULL, sub INTEGER NOT NULL, frag INTEGER NOT NULL, position INTEGER NOT NULL, PRIMARY KEY(scope, epoch, pos, sub, frag)) WITHOUT ROWID;",
                "CREATE TABLE principal(scope INTEGER NOT NULL, epoch INTEGER NOT NULL, begin INTEGER NOT NULL, user TEXT, ambiguous INTEGER NOT NULL, conflict INTEGER NOT NULL, ready INTEGER NOT NULL, evidence_end INTEGER NOT NULL, has_proxy INTEGER NOT NULL, proxy_ms INTEGER NOT NULL, PRIMARY KEY(scope,epoch,begin)) WITHOUT ROWID;" })
                Exec(sql);
        }

        void Exec(string sql) { using (var c = _scratch.Command(sql)) c.ExecuteNonQuery(); }

        static SqliteCommand Typed(SqliteCommand c, string types)
        {
            for (int i = 0; i < types.Length; i++) c.Parameters.Add("@p" + i.ToString(CultureInfo.InvariantCulture), types[i] == 'i' ? SqliteType.Integer : SqliteType.Text);
            c.Prepare();
            return c;
        }

        SqliteCommand S(string name, string sql, string types)
        {
            SqliteCommand c;
            if (_scratchCommands.TryGetValue(name, out c)) return c;
            Open();
            c = Typed(_scratch.Own(_scratch.Command(sql)), types);
            _scratchCommands[name] = c;
            return c;
        }

        SqliteCommand M(string name, string sql, string types)
        {
            SqliteCommand c;
            if (!_mainCommands.TryGetValue(name, out c))
            {
                c = Typed(_store.Command(sql, _tx), types);
                _mainCommands[name] = c;
            }
            c.Transaction = _tx;
            return c;
        }

        static SqliteCommand With(SqliteCommand c, params object[] values)
        {
            for (int i = 0; i < values.Length; i++) c.Parameters[i].Value = values[i] ?? DBNull.Value;
            return c;
        }

        static string Str(SqliteDataReader r, int i) { return Packed.Text(r.GetValue(i)); }
        static long Num(SqliteDataReader r, int i, long fallback) { return r.IsDBNull(i) ? fallback : r.GetInt64(i); }

        void ClearScope(int scope)
        {
            foreach (var t in new[] { "ev", "covraw", "cov", "mref", "principal" })
                With(S("clear_" + t, "DELETE FROM " + t + " WHERE scope=@p0;", "i"), (long)scope).ExecuteNonQuery();
        }

        // ---------------------------------------------------------------- queue

        /// <summary>Evaluates the touched sessions (and the back-end sessions that depend on a touched front-end one) and writes the result.</summary>
        public void Flush(SqliteTransaction tx)
        {
            _lastKey = null;   // the sessions are evaluated (done=1): a later Touch queues them again
            if (_pending == 0) return;
            _tx = tx;
            Open();
            bool evaluated = false;
            try
            {
                while (true)
                {
                    while (_next < _queue.Count && _queue[_next].Done) _next++;
                    if (_next >= _queue.Count) break;
                    var q = _queue[_next];
                    q.Done = true;
                    Evaluate(q.Server, q.Direction, q.Role, q.Sid);
                }
                evaluated = true;
            }
            finally
            {
                ClearScope(0); ClearScope(1);
                ClearQueue();
                _pending = 0;
                // Every scratch table is empty again (scopes 0 and 1 are the only ones; all WITHOUT ROWID, read in key order): the next Flush
                // reads what a new scratch file would give, so the file and its prepared statements are kept. After a failure they are not.
                if (!evaluated) CloseScratch();
            }
        }

        void Enqueue(string server, string direction, string role, string sid)
        {
            Queue(Key(server, direction, role, sid), server, direction, role, sid, false);
        }

        void Evaluate(string server, string direction, string role, string sid)
        {
            var epochs = Walk(0, server, direction, role, sid);
            foreach (var e in epochs)
            {
                if (e.Role == "FrontEnd" && e.Direction == "Receive") Dependents(e);
                Run(0, e, new Replay(this, e, 0, null, true));
                Run(0, e, new Replay(this, e, 0, null));
                Evaluated++;
            }
        }

        /// <summary>Back-end sessions that name the front-end session of the epoch: they are evaluated again, one page at a time.</summary>
        void Dependents(AuthEpoch fe)
        {
            long after = 0;
            while (true)
            {
                var rows = new List<string[]>();
                long last = after;
                using (var r = With(M("dependents", "SELECT server, direction, role, session_id, id FROM smtp_auth_fragment WHERE proxy_sid=@p0 AND first_ms<=@p1 AND last_ms>=@p2 AND id>@p3 ORDER BY id LIMIT " + DependentPage.ToString(CultureInfo.InvariantCulture) + ";", "tiii"), fe.SessionId, fe.LastMs + _idleMs, fe.FirstMs - _idleMs, after).ExecuteReader())
                    while (r.Read()) { rows.Add(new[] { r.GetString(0), r.GetString(1), r.GetString(2), r.GetString(3) }); last = r.GetInt64(4); }
                foreach (var s in rows) Enqueue(s[0], s[1], s[2], s[3]);
                if (rows.Count < DependentPage) break;
                after = last;
            }
        }

        // ---------------------------------------------------------------- loading one session

        const string PartOrder = "CASE WHEN COALESCE(evidence_format,1)>=2 THEN -1-part ELSE part END";

        List<Origin> ReadOrigins(string server, string direction, string role, string sid, long om, string key, long offset)
        {
            var list = new List<Origin>();
            string sql = "SELECT COALESCE(source_key,''), first_offset, COALESCE(origin_first_ms,first_ms), MIN(first_ms), MAX(last_ms), MIN(first_sequence), MAX(last_sequence), MAX(complete_start), MAX(complete_end), MAX(COALESCE(evidence_format,1)), MIN(COALESCE(evidence_format,1)), " +
                "CASE WHEN MAX(COALESCE(evidence_format,1))>=2 THEN SUM(CASE WHEN COALESCE(evidence_format,1)>=2 THEN 1 ELSE 0 END) ELSE COUNT(*) END, " +
                "CASE WHEN MAX(COALESCE(evidence_format,1))>=2 THEN MAX(CASE WHEN COALESCE(evidence_format,1)>=2 THEN -1-part END) ELSE MAX(part) END " +
                "FROM smtp_auth_fragment WHERE server=@p0 AND role=@p1 AND direction=@p2 AND session_id=@p3 AND (COALESCE(origin_first_ms,first_ms), COALESCE(source_key,''), first_offset) > (@p4,@p5,@p6) " +
                "GROUP BY COALESCE(origin_first_ms,first_ms), COALESCE(source_key,''), first_offset ORDER BY 3, 1, 2 LIMIT " + OriginPage.ToString(CultureInfo.InvariantCulture) + ";";
            using (var r = With(M("origins", sql, "ttttiti"), server, role, direction, sid, om, key, offset).ExecuteReader())
                while (r.Read())
                    list.Add(new Origin
                    {
                        SourceKey = r.GetString(0), FirstOffset = r.GetInt64(1), OriginMs = r.GetInt64(2), FirstMs = r.GetInt64(3), LastMs = r.GetInt64(4), FirstSeq = Num(r, 5, -1), LastSeq = Num(r, 6, -1),
                        CompleteStart = r.GetInt64(7) != 0, CompleteEnd = r.GetInt64(8) != 0, MaxFormat = (int)r.GetInt64(9), MinFormat = (int)r.GetInt64(10), Distinct = r.GetInt64(11), MaxLogical = r.GetInt64(12)
                    });
            return list;
        }

        /// <summary>Reads every origin (one connection as one file saw it) of a session, assigns it to a connection epoch and copies its typed evidence to the scratch file in order.</summary>
        IEnumerable<AuthEpoch> Walk(int scope, string server, string direction, string role, string sid)
        {
            ClearScope(scope);
            int index = 0;
            AuthEpoch e = null;
            long om = long.MinValue, offset = long.MinValue;
            string key = "";
            while (true)
            {
                var origins = ReadOrigins(server, direction, role, sid, om, key, offset);
                if (origins.Count == 0) break;
                foreach (var o in origins)
                {
                    om = o.OriginMs; key = o.SourceKey; offset = o.FirstOffset;
                    string connector = null, local = null, remote = null, helo = null;
                    var ec = With(M("endpoints", "SELECT connector, local_ep, remote_ep, helo FROM smtp_auth_fragment WHERE server=@p0 AND role=@p1 AND direction=@p2 AND session_id=@p3 AND COALESCE(source_key,'')=@p4 AND first_offset=@p5 AND COALESCE(origin_first_ms,first_ms)=@p6 ORDER BY id LIMIT 1;", "tttttii"),
                        server, role, direction, sid, key, offset, om);
                    using (var r = ec.ExecuteReader())
                        if (r.Read()) { connector = Str(r, 0); local = Str(r, 1); remote = Str(r, 2); helo = Str(r, 3); }
                    bool append = e != null && !o.CompleteStart && !e.SeqLess && o.FirstSeq >= 0 && e.LastSeq >= 0 && o.FirstSeq <= e.LastSeq + 1 && o.OriginMs >= e.FirstMs
                        && string.Equals(connector, e.Connector, StringComparison.Ordinal) && string.Equals(local, e.LocalEp, StringComparison.Ordinal) && string.Equals(remote, e.RemoteEp, StringComparison.Ordinal) && !e.CompleteEnd;
                    if (!append)
                    {
                        if (e != null) { MergeCoverage(scope, e.Index); yield return e; ClearScope(scope); }
                        e = new AuthEpoch { Index = index++, Server = server, Direction = direction, Role = role, SessionId = sid, Connector = connector, LocalEp = local, RemoteEp = remote, Helo = helo, FirstMs = o.OriginMs, CompleteStart = o.CompleteStart, SeqLess = o.FirstSeq < 0 };
                    }
                    e.Origins++;
                    if (e.Helo == null) e.Helo = helo;
                    if (e.Connector == null) e.Connector = connector;
                    e.LastMs = Math.Max(e.LastMs, o.LastMs);
                    e.CompleteEnd = o.CompleteEnd;
                    if (o.MinFormat < 2) e.Legacy = true;
                    if (o.FirstSeq >= 0 && (e.FirstSeq < 0 || o.FirstSeq < e.FirstSeq)) e.FirstSeq = o.FirstSeq;
                    if (o.LastSeq > e.LastSeq) e.LastSeq = o.LastSeq;
                    // Without sequence numbers the order is the position in the file: complete only when read as one connection from its first line.
                    e.SeqLessOk = e.SeqLess && e.Origins == 1 && o.CompleteStart && o.Distinct == o.MaxLogical + 1;
                    ReadParts(scope, e, o, server, direction, role, sid);
                }
            }
            if (e != null) { MergeCoverage(scope, e.Index); yield return e; }
            ClearScope(scope);
        }

        void ReadParts(int scope, AuthEpoch e, Origin o, string server, string direction, string role, string sid)
        {
            long after = 0;
            string sql = "SELECT id, part, COALESCE(evidence_format,1), coverage, conflicted, conflict_positions, observations FROM smtp_auth_fragment WHERE server=@p0 AND role=@p1 AND direction=@p2 AND session_id=@p3 AND COALESCE(source_key,'')=@p4 AND first_offset=@p5 AND COALESCE(origin_first_ms,first_ms)=@p6 AND id>@p7 ORDER BY id LIMIT " + PartPage.ToString(CultureInfo.InvariantCulture) + ";";
            while (true)
            {
                var rows = new List<object[]>();
                using (var r = With(M("parts", sql, "tttttiii"), server, role, direction, sid, o.SourceKey, o.FirstOffset, o.OriginMs, after).ExecuteReader())
                    while (r.Read()) rows.Add(new object[] { r.GetInt64(0), r.GetInt64(1), r.GetInt64(2), Str(r, 3), r.GetInt64(4) != 0, Str(r, 5), Str(r, 6) });
                foreach (var row in rows)
                {
                    long id = (long)row[0];
                    int format = (int)(long)row[2];
                    long logical = format >= 2 ? -1L - (long)row[1] : (long)row[1];
                    after = id;
                    if (e.SeqLess && format < 2 && o.MaxFormat >= 2) continue;
                    foreach (var iv in SmtpAuthStore.ReadCoverage((string)row[3]))
                        With(S("covraw", "INSERT OR IGNORE INTO covraw(scope, epoch, lo, hi) VALUES(@p0,@p1,@p2,@p3);", "iiii"), (long)scope, (long)e.Index, iv[0], iv[1]).ExecuteNonQuery();
                    HashSet<long> positions = null;
                    bool partConflict = (bool)row[4];
                    if (partConflict && row[5] != null)
                    {
                        positions = new HashSet<long>();
                        foreach (var t in ((string)row[5]).Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)) { long v; if (long.TryParse(t, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out v)) positions.Add(v); }
                    }
                    foreach (var ob in SmtpAuthStore.Read((string)row[6] ?? "[]", id, logical))
                        Insert(scope, e, ob, partConflict && (positions == null || positions.Contains(ob.Pos)));
                }
                if (rows.Count < PartPage) break;
            }
        }

        void Insert(int scope, AuthEpoch e, AuthObs o, bool conflict)
        {
            object[] values = { (long)scope, (long)e.Index, o.Pos, (long)o.Sub, o.K.ToString(), o.Ms, o.Seq, o.A, o.B, (long)o.Code, o.Frag, conflict ? 1L : 0L };
            if (o.K == 'M')
            {
                long position;
                if (long.TryParse(o.A, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out position))
                    With(S("mref", "INSERT OR IGNORE INTO mref(scope, epoch, pos, sub, frag, position) VALUES(@p0,@p1,@p2,@p3,@p4,@p5);", "iiiiii"), (long)scope, (long)e.Index, o.Pos, (long)o.Sub, o.Frag, position).ExecuteNonQuery();
            }
            if (conflict)
            {
                With(S("evconflict", "INSERT INTO ev(scope,epoch,pos,sub,k,ms,seq,a,b,code,frag,conflict) VALUES(@p0,@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,@p9,@p10,@p11) ON CONFLICT(scope,epoch,pos,sub) DO UPDATE SET conflict=1;", "iiiitiittiii"), values).ExecuteNonQuery();
                return;
            }
            if (With(S("evinsert", "INSERT OR IGNORE INTO ev(scope,epoch,pos,sub,k,ms,seq,a,b,code,frag,conflict) VALUES(@p0,@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,@p9,@p10,@p11);", "iiiitiittiii"), values).ExecuteNonQuery() > 0) return;
            // The same position was already read (the part was read again by another file or collection): only a different content is a conflict.
            bool same = false;
            using (var r = With(S("evsame", "SELECT k, ms, a, b, code FROM ev WHERE scope=@p0 AND epoch=@p1 AND pos=@p2 AND sub=@p3;", "iiii"), (long)scope, (long)e.Index, o.Pos, (long)o.Sub).ExecuteReader())
                if (r.Read()) same = r.GetString(0) == o.K.ToString() && r.GetInt64(1) == o.Ms && Str(r, 2) == o.A && Str(r, 3) == o.B && r.GetInt64(4) == o.Code;
            if (!same) With(S("evmark", "UPDATE ev SET conflict=1 WHERE scope=@p0 AND epoch=@p1 AND pos=@p2 AND sub=@p3;", "iiii"), (long)scope, (long)e.Index, o.Pos, (long)o.Sub).ExecuteNonQuery();
        }

        void MergeCoverage(int scope, int epoch)
        {
            long lo = 0, hi = -1;
            bool have = false;
            var insert = S("covinsert", "INSERT OR REPLACE INTO cov(scope, epoch, lo, hi) VALUES(@p0,@p1,@p2,@p3);", "iiii");
            using (var r = With(S("covread", "SELECT lo, hi FROM covraw WHERE scope=@p0 AND epoch=@p1 ORDER BY lo, hi;", "ii"), (long)scope, (long)epoch).ExecuteReader())
                while (r.Read())
                {
                    long a = r.GetInt64(0), b = r.GetInt64(1);
                    if (have && a <= hi + 1) { hi = Math.Max(hi, b); continue; }
                    if (have) With(insert, (long)scope, (long)epoch, lo, hi).ExecuteNonQuery();
                    lo = a; hi = b; have = true;
                }
            if (have) With(insert, (long)scope, (long)epoch, lo, hi).ExecuteNonQuery();
        }

        /// <summary>Feeds the ordered events of an epoch to a replay, one page at a time.</summary>
        void Run(int scope, AuthEpoch e, Replay replay)
        {
            long pos = long.MinValue;
            long sub = long.MinValue;
            var page = new List<AuthObs>(EventPage);
            while (true)
            {
                page.Clear();
                using (var r = With(S("events", "SELECT pos, sub, k, ms, seq, a, b, code, frag, conflict FROM ev WHERE scope=@p0 AND epoch=@p1 AND (pos, sub) > (@p2, @p3) ORDER BY pos, sub LIMIT " + EventPage.ToString(CultureInfo.InvariantCulture) + ";", "iiii"), (long)scope, (long)e.Index, pos, sub).ExecuteReader())
                    while (r.Read())
                        page.Add(new AuthObs { Pos = r.GetInt64(0), Sub = (int)r.GetInt64(1), K = r.GetString(2)[0], Ms = r.GetInt64(3), Seq = r.GetInt64(4), A = Str(r, 5), B = Str(r, 6), Code = (int)r.GetInt64(7), Frag = r.GetInt64(8), Conflict = r.GetInt64(9) != 0 });
                if (page.Count == 0) break;
                foreach (var o in page) replay.Feed(o);
                pos = page[page.Count - 1].Pos; sub = page[page.Count - 1].Sub;
                if (page.Count < EventPage) break;
            }
            replay.Finish();
            Replayed++;
        }

        long[] NextRange(int scope, int epoch, long after)
        {
            using (var r = With(S("covnext", "SELECT lo, hi FROM cov WHERE scope=@p0 AND epoch=@p1 AND lo>@p2 ORDER BY lo LIMIT 1;", "iii"), (long)scope, (long)epoch, after).ExecuteReader())
                return r.Read() ? new[] { r.GetInt64(0), r.GetInt64(1) } : null;
        }

        // ---------------------------------------------------------------- writing the result

        /// <summary>The five values of the transactions that recorded the MAIL at an event of the epoch (the parts it was read from may differ).</summary>
        void WriteMail(int scope, AuthEpoch e, AuthObs mail, AuthSnap s)
        {
            long afterRef = 0;
            while (true)
            {
                var refs = new List<long[]>();
                using (var r = With(S("mailrefs", "SELECT frag, position FROM mref WHERE scope=@p0 AND epoch=@p1 AND pos=@p2 AND sub=@p3 AND frag>@p4 ORDER BY frag LIMIT 256;", "iiiii"),
                    (long)scope, (long)e.Index, mail.Pos, (long)mail.Sub, afterRef).ExecuteReader())
                    while (r.Read()) refs.Add(new[] { r.GetInt64(0), r.GetInt64(1) });
                if (refs.Count == 0) break;
                foreach (var f in refs)
                {
                    long after = 0;
                    while (true)
                    {
                        var rows = new List<object[]>();
                        using (var r = With(M("txlookup", "SELECT id, auth_user, auth_mechanism, auth_result, auth_attempt_result, auth_source, auth_evidence_id, time_ms, client_id, server, direction, role, connector, remote_ep, helo FROM smtp_transaction WHERE auth_fragment_id=@p0 AND auth_sequence=@p1 AND id>@p2 ORDER BY id LIMIT 256;", "iii"), f[0], f[1], after).ExecuteReader())
                            while (r.Read()) rows.Add(new object[] { r.GetInt64(0), Str(r, 1), Str(r, 2), Str(r, 3), Str(r, 4), Str(r, 5), r.IsDBNull(6) ? (object)null : r.GetInt64(6),
                                r.GetInt64(7), r.IsDBNull(8) ? (object)null : r.GetInt64(8), Str(r, 9), Str(r, 10), Str(r, 11), Str(r, 12), Str(r, 13), Str(r, 14) });
                        foreach (var row in rows)
                        {
                            after = (long)row[0];
                            object evidence = s.Evidence > 0 ? (object)s.Evidence : null;
                            if (Equals(row[1], s.User) && Equals(row[2], s.Mechanism) && Equals(row[3], s.Result) && Equals(row[4], s.Attempt) && Equals(row[5], s.Source) && Equals(row[6], evidence)) continue;
                            var u = _writer.UpdateAuth;
                            // The resolved account is part of the SMTP client key: the transaction moves to the client of its account. Without the code-side
                            // maintenance the client_id stays as read and the update trigger queues the transaction (ReconcileSmtpClients re-keys it).
                            object client = row[8];
                            if (_clients != null) client = _clients.Client(row[9], row[10], row[11], row[12], row[13], row[14], s.User, s.Source);
                            u.Set(0, s.User); u.Set(1, s.Mechanism); u.Set(2, s.Result); u.Set(3, s.Attempt); u.Set(4, s.Source); u.Set(5, evidence); u.Set(6, after); u.Set(7, client);
                            u.Run();
                            if (_clients != null)
                            {
                                _clients.Updated(after, (long)row[7], row[8], client, s.Mechanism, s.Result, s.Attempt, s.Source);
                                _clients.Left(row[8], client);
                            }
                            Updated++;
                        }
                        if (rows.Count < 256) break;
                    }
                }
                afterRef = refs[refs.Count - 1][0];
                if (refs.Count < 256) break;
            }
        }

        // ---------------------------------------------------------------- front-end handshake

        /// <summary>
        /// What the front end proved for a handshake. The front-end connection must be unique and compatible (server, endpoints, time) and must hold
        /// exactly one authenticated user interval that was effective at the XPROXY: more than one, or a conflict, is ambiguous; none is missing.
        /// Never the first, the last or the nearest.
        /// </summary>
        AuthToken ResolveToken(AuthEpoch be, AuthBind b)
        {
            var token = new AuthToken();
            if (be.Role == "FrontEnd" || be.Direction != "Receive" || !b.Valid || b.Port <= 0 || !b.Accepted || b.Broken) return token;
            int compatible = 0, eligible = 0;
            bool ambiguous = false;
            AuthToken found = null;
            string after = "";
            while (true)
            {
                var candidates = new List<string>();
                using (var r = With(M("candidates", "SELECT server FROM smtp_auth_fragment WHERE session_id=@p0 AND role='FrontEnd' AND direction='Receive' AND first_ms<=@p1 AND last_ms>=@p2 AND server>@p3 GROUP BY server ORDER BY server LIMIT 32;", "tiit"), b.Sid, b.Ms + _idleMs, b.Ms - _idleMs, after).ExecuteReader())
                    while (r.Read()) candidates.Add(r.GetString(0));
                foreach (var server in candidates)
                {
                    foreach (var fe in Walk(1, server, "Receive", "FrontEnd", b.Sid))
                    {
                        if (!Compatible(fe, b, be)) continue;
                        if (fe.FirstMs - _idleMs > b.Ms || fe.LastMs + _idleMs < b.Ms) continue;
                        compatible = Math.Min(2, compatible + 1);
                        Run(1, fe, new Replay(this, fe, 1, null, true));
                        var replay = new Replay(this, fe, 1, b);
                        Run(1, fe, replay);
                        eligible = Math.Min(2, eligible + replay.Eligible);
                        if (replay.Ambiguous) ambiguous = true;
                        if (found == null) found = replay.Found;
                    }
                }
                if (candidates.Count < 32) break;
                after = candidates[candidates.Count - 1];
            }
            if (compatible > 1 || ambiguous || eligible > 1) { token.Status = SmtpAuth.Ambiguous; return token; }
            if (compatible == 0 || eligible == 0 || found == null) return token;
            found.Status = AuthToken.Ok;
            found.ReadyMs = Math.Max(found.ReadyMs, b.AcceptMs);
            return found;
        }

        bool Compatible(AuthEpoch fe, AuthBind b, AuthEpoch be)
        {
            if (!SmtpAuth.SameIpText(b.Ip, fe.RemoteEp) || SmtpAuth.Port(fe.RemoteEp) != b.Port) return false;
            if (!SmtpAuth.SameIp(fe.LocalEp, be.RemoteEp) && !SameHostLoopback(fe, be)) return false;
            return SameServer(fe.Server, b.PeerHelo);
        }

        static bool SameHostLoopback(AuthEpoch fe, AuthEpoch be)
        {
            if (fe.Role != "FrontEnd" || fe.Direction != "Receive" || be.Role != "Hub" || be.Direction != "Receive") return false;
            if (string.IsNullOrWhiteSpace(fe.Server) || string.IsNullOrWhiteSpace(be.Server) ||
                !string.Equals(fe.Server.Trim(), be.Server.Trim(), StringComparison.OrdinalIgnoreCase)) return false;
            IPAddress local, client, hub, peer;
            if (!SmtpAuth.TryEndpointAddress(fe.LocalEp, out local) || !SmtpAuth.TryEndpointAddress(fe.RemoteEp, out client) ||
                !SmtpAuth.TryEndpointAddress(be.LocalEp, out hub) || !SmtpAuth.TryEndpointAddress(be.RemoteEp, out peer)) return false;
            // A loopback submission can reach this same server's Hub through its physical interface.
            return local.AddressFamily == client.AddressFamily && IPAddress.IsLoopback(local) && IPAddress.IsLoopback(client) &&
                hub.AddressFamily == peer.AddressFamily && !IPAddress.IsLoopback(hub) &&
                !hub.Equals(IPAddress.Any) && !hub.Equals(IPAddress.IPv6Any) && SmtpAuth.Canonical(hub) == SmtpAuth.Canonical(peer);
        }

        /// <summary>The EHLO name of the proxying front end names the server that logged the front-end session. A short name must be unique among the known sources.</summary>
        bool SameServer(string source, string helo)
        {
            if (string.IsNullOrWhiteSpace(source) || string.IsNullOrWhiteSpace(helo)) return false;
            if (string.Equals(source.Trim(), helo.Trim(), StringComparison.OrdinalIgnoreCase)) return true;
            string a = Identity.ServerName(source), b = Identity.ServerName(helo);
            if (a == null || a != b) return false;
            if (source.IndexOf('.') >= 0 && helo.IndexOf('.') >= 0) return false;
            int matches = 0;
            string previous = null;
            using (var r = With(M("servers", "SELECT server FROM source_file ORDER BY server;", ""), new object[0]).ExecuteReader())
                while (r.Read())
                {
                    string name = r.GetString(0);
                    if (name != previous && Identity.ServerName(name) == a && ++matches > 1) return false;
                    previous = name;
                }
            return true;
        }

        // ---------------------------------------------------------------- state machine

        /// <summary>
        /// One connection replayed in order with scalar state. In the main mode it writes the result of every MAIL. With an anchor (the
        /// handshake of a back end) it only counts the authenticated intervals of a front-end connection that were effective at the anchor.
        /// </summary>
        sealed class Replay
        {
            readonly AuthResolver _r;
            readonly AuthEpoch _e;
            readonly int _scope;
            readonly AuthBind _anchor;
            readonly bool _projection;
            Principal _est, _window;
            Principal _atAnchor;
            string _attemptAtAnchor;
            Attempt _open;
            string _last = SmtpAuth.NotAttempted, _lastMech, _helo;
            bool _unknown, _stateConflict, _rHave, _rDone, _timeRegression;
            AuthBind _bind;
            long _prevMs, _rLo, _rHi;
            public int Eligible;
            public bool Ambiguous;
            public AuthToken Found;

            public Replay(AuthResolver resolver, AuthEpoch e, int scope, AuthBind anchor, bool projection = false)
            {
                _r = resolver; _e = e; _scope = scope; _anchor = anchor;
                _projection = projection;
                _unknown = !e.CompleteStart || (e.SeqLess && !e.SeqLessOk);
                _prevMs = e.FirstMs;
            }

            bool Main { get { return _anchor == null && !_projection; } }

            /// <summary>True when the position is not in the range the previous event was in and the ranges are not adjacent (lines of the log were not read).</summary>
            bool Advance(long pos)
            {
                bool gap = false;
                if (!_rHave && !_rDone)
                {
                    var first = _r.NextRange(_scope, _e.Index, long.MinValue);
                    if (first == null) _rDone = true; else { _rHave = true; _rLo = first[0]; _rHi = first[1]; }
                }
                while (_rHave && pos > _rHi)
                {
                    var next = _r.NextRange(_scope, _e.Index, _rHi);
                    if (next == null) { _rHave = false; _rDone = true; break; }
                    if (next[0] > _rHi + 1) gap = true;
                    _rLo = next[0]; _rHi = next[1];
                }
                if (_rDone && pos > _rHi) gap = true;
                return gap;
            }

            public void Feed(AuthObs o)
            {
                if (o.Ms < _prevMs) { _timeRegression = true; if (_open != null) _open.Conflict = true; }
                if (_anchor != null && _prevMs <= _anchor.Ms && o.Ms > _anchor.Ms)
                {
                    _atAnchor = _est;
                    _attemptAtAnchor = _last;
                }
                if (!_e.SeqLess && Advance(o.Pos)) Gap();
                if (o.Conflict) MarkConflict(o);
                if (_window != null && o.K != 'I' && o.K != 'P') _window = null;
                switch (o.K)
                {
                    case 'C':
                        SetEnd(_est, "Closed", o.Ms); Retire(_est);
                        _est = null; _open = null; _window = null; _bind = null; _helo = null; _stateConflict = false; _unknown = false; _timeRegression = false;
                        _last = SmtpAuth.NotAttempted; _lastMech = null;
                        break;
                    case 'E':
                        _helo = o.A;
                        break;
                    case 'B':
                        _open = new Attempt { Mech = o.A, Technical = o.B == "T", BeginPos = o.Pos, BeginMs = o.Ms, MaxPos = o.Pos, MaxMs = o.Ms, Reauth = _est != null, Conflict = _timeRegression };
                        _last = SmtpAuth.InProgress; _lastMech = o.A;
                        break;
                    case 'H':
                        if (_open == null && _unknown) { _open = new Attempt { StartUnknown = true, BeginPos = o.Pos, BeginMs = o.Ms, MaxPos = o.Pos, MaxMs = o.Ms }; _last = SmtpAuth.InProgress; }
                        break;
                    case 'I':
                    case 'P':
                        Identity(o);
                        break;
                    case 'R':
                        Result(o);
                        break;
                    case 'K':
                        if (o.A == "u") { Gap(); break; }
                        if (_open != null) { _last = SmtpAuth.Abandoned; Taint(_est, o.Ms); _open = null; }
                        break;
                    case 'D':
                        if (_open != null) { _last = SmtpAuth.Abandoned; Taint(_est, o.Ms); _open = null; }
                        SetEnd(_est, "Disconnect", o.Ms);
                        break;
                    case 'T':
                        SetEnd(_est, "Closed", o.Ms); Retire(_est);
                        _est = null; _open = null; _window = null; _bind = null; _stateConflict = false; _unknown = false;
                        _last = SmtpAuth.NotAttempted; _lastMech = null;
                        break;
                    case 'X':
                        if (_est == null || !_est.Technical || !SmtpAuth.IsTechnicalMechanism(_est.Mech) || _bind != null) _bind = new AuthBind { Broken = true };
                        else
                        {
                            var b = new AuthBind { Ms = o.Ms, Valid = o.A != null, Sid = o.A, PeerHelo = _helo ?? (_e.Legacy ? _e.Helo : null) };
                            if (b.Valid && o.B != null && o.B != "!")
                            {
                                var p = o.B.Split('|');
                                int port;
                                b.Ip = p[0]; b.Port = p.Length > 1 && int.TryParse(p[1], NumberStyles.None, CultureInfo.InvariantCulture, out port) ? port : 0;
                                b.Helo = p.Length > 2 && p[2].Length > 0 ? p[2] : null;
                            }
                            else b.Valid = false;
                            _bind = b;
                        }
                        break;
                    case 'Y':
                        if (_bind != null && !_bind.Broken && !_bind.Accepted)
                        {
                            if (o.Code >= 200 && o.Code < 300 && _bind.Valid) { _bind.Accepted = true; _bind.AcceptMs = o.Ms; } else _bind.Broken = true;
                        }
                        break;
                    case 'M':
                        if (Main) _r.WriteMail(_scope, _e, o, Snapshot(o));
                        break;
                }
                _prevMs = o.Ms;
            }

            public void Finish()
            {
                Retire(_est);
                _est = null;
            }

            void MarkConflict(AuthObs o)
            {
                if (_open != null) _open.Conflict = true;
                else if (_window != null && (o.K == 'I' || o.K == 'P' || o.K == 'R')) _window.Conflict = true;
                else { _stateConflict = true; Taint(_est, o.Ms); }
            }

            /// <summary>Lines of the log were not read: nothing is known about them, so what was known is closed and a new complete AUTH starts again.</summary>
            void Gap()
            {
                if (_est != null) { SetEnd(_est, "Gap", _prevMs); Retire(_est); _est = null; }
                if (_open != null) _open.Broken = true;
                if (_bind != null) _bind.Broken = true;
                _window = null; _unknown = true; _stateConflict = false;
                _last = SmtpAuth.Unknown; _lastMech = null;
            }

            static void SetEnd(Principal p, string reason, long ms)
            {
                if (p != null && p.EndReason == null) { p.EndReason = reason; p.EndMs = ms; }
            }

            /// <summary>An AUTH that could have replaced the principal ended without an answer or with a refusal: the principal can no longer be attributed from that moment.</summary>
            static void Taint(Principal p, long ms)
            {
                if (p == null) return;
                p.Unattributable = true;
                SetEnd(p, "Tainted", ms);
            }

            static void AddCandidate(Attempt a, AuthObs o)
            {
                if (o.K == 'P') { a.HasProxy = true; a.ProxyMs = o.Ms; }
                if (a.Technical) return;
                if (o.B == "u" && o.A != null)
                {
                    if (a.User == null) a.User = o.A; else if (a.User != o.A) a.Multi = true;
                }
                else if (o.B == "t") a.TechId = true;
            }

            static void Apply(Principal p, Attempt a)
            {
                if (a.HasProxy) { p.HasProxy = true; p.ProxyMs = a.ProxyMs; }
                if (p.Technical) return;
                if (a.User != null) { if (p.User != null && p.User != a.User) p.Ambiguous = true; else p.User = a.User; }
                if (a.Multi) p.Ambiguous = true;
                if (a.TechId) { if (p.User != null) p.Ambiguous = true; p.TechId = true; }
                if (p.User != null && p.TechId) p.Ambiguous = true;
                if (p.Ambiguous) p.User = null;
            }

            void Identity(AuthObs o)
            {
                if (_open != null)
                {
                    AddCandidate(_open, o);
                    _open.MaxPos = Math.Max(_open.MaxPos, o.Pos); _open.MaxMs = Math.Max(_open.MaxMs, o.Ms);
                }
                else if (_window != null)
                {
                    // The completion of a success is the run of identity annotations written right after its 235.
                    var probe = new Attempt { Technical = _window.Technical };
                    AddCandidate(probe, o);
                    _window.EndPos = Math.Max(_window.EndPos, o.Pos);
                    _window.ReadyMs = Math.Max(_window.ReadyMs, o.Ms);
                    Apply(_window, probe);
                }
            }

            void Result(AuthObs o)
            {
                if (_open == null)
                {
                    if (_est == null && _unknown) _last = SmtpAuth.Unknown;
                    return;
                }
                var a = _open;
                _open = null;
                if (o.A == "ok" && o.Code == 235)
                {
                    SetEnd(_est, "Replaced", o.Ms); Retire(_est);
                    var p = new Principal
                    {
                        Mech = a.Mech, Technical = a.Technical, BeginPos = a.BeginPos, BeginMs = a.BeginMs, EndPos = Math.Max(a.MaxPos, o.Pos), SuccessMs = o.Ms, ReadyMs = Math.Max(o.Ms, a.MaxMs),
                        StartUnknown = a.StartUnknown, Broken = a.Broken, Conflict = a.Conflict, HasProxy = a.HasProxy, ProxyMs = a.ProxyMs, Evidence = o.Frag, HeloAtSuccess = _helo
                    };
                    Apply(p, a);
                    if (!_projection)
                    {
                        using (var r = With(_r.S("principal_read", "SELECT user,ambiguous,conflict,ready,evidence_end,has_proxy,proxy_ms FROM principal WHERE scope=@p0 AND epoch=@p1 AND begin=@p2;", "iii"),
                            (long)_scope, (long)_e.Index, p.BeginPos).ExecuteReader())
                            if (r.Read())
                            {
                                p.User = Str(r, 0); p.Ambiguous = r.GetInt64(1) != 0; p.Conflict = r.GetInt64(2) != 0;
                                p.ReadyMs = r.GetInt64(3); p.EndPos = r.GetInt64(4);
                                p.HasProxy = r.GetInt64(5) != 0; p.ProxyMs = r.GetInt64(6);
                            }
                    }
                    _est = p;
                    _window = p.Technical || p.Ambiguous ? null : p;
                    _last = SmtpAuth.Succeeded; _unknown = false; _bind = null; _stateConflict = false;
                }
                else if (o.A == "already")
                {
                    // The server refuses a second AUTH on an authenticated session: the principal and its interval are untouched.
                    _last = SmtpAuth.Failed;
                }
                else
                {
                    if (a.Reauth) Taint(_est, o.Ms);
                    _last = SmtpAuth.Failed;
                }
            }

            AuthSnap Snapshot(AuthObs m)
            {
                var s = new AuthSnap { Result = SmtpAuth.Unknown, Attempt = SmtpAuth.Unknown, Source = SmtpAuth.Missing };
                if (_est != null ? _est.Conflict : _stateConflict) { s.Source = SmtpAuth.Ambiguous; return s; }
                if (_est != null) { if (_est.StartUnknown || _est.Broken) return s; }
                else if (_unknown) return s;
                if (_est == null)
                {
                    s.Result = _open != null ? SmtpAuth.InProgress : _last;
                    s.Attempt = s.Result;
                    s.Source = SmtpAuth.NotApplicable;
                    // The mechanism of the attempt that was made without success: "None" is only for a session that never tried to authenticate.
                    if (_last != SmtpAuth.NotAttempted && _last != SmtpAuth.Unknown && _lastMech != "Unknown") s.Mechanism = _lastMech;
                    return s;
                }
                var est = _est;
                if (m.Pos < est.EndPos || m.Ms < est.ReadyMs) return s;
                s.Attempt = _last;
                s.Mechanism = est.Mech == "Unknown" ? null : est.Mech;
                s.Evidence = est.Evidence;
                if (est.Unattributable || est.Ambiguous) { s.Result = SmtpAuth.Unknown; s.Mechanism = null; s.Source = SmtpAuth.Ambiguous; s.Evidence = 0; return s; }
                s.Result = SmtpAuth.Succeeded;
                if (est.Technical && SmtpAuth.IsTechnicalMechanism(est.Mech))
                {
                    if (_bind == null) { s.Source = SmtpAuth.NotApplicable; return s; }
                    s.Mechanism = null; s.Result = SmtpAuth.Unknown; s.Attempt = SmtpAuth.Unknown; s.Evidence = 0;
                    if (_bind.Broken || !_bind.Accepted) { s.Source = SmtpAuth.Missing; return s; }
                    return _r.Handoff(_e, _bind, m);
                }
                if (est.TechId || est.Technical) { s.Source = SmtpAuth.NotApplicable; return s; }
                if (est.User == null) { s.Source = SmtpAuth.Missing; return s; }
                s.User = est.User; s.Source = SmtpAuth.Direct;
                return s;
            }

            /// <summary>A principal leaves the state: with an anchor, it is counted when it was effective at the handshake.</summary>
            void Retire(Principal p)
            {
                if (p == null || p.Retired) return;
                p.Retired = true;
                if (_projection)
                {
                    With(_r.S("principal_write", "INSERT OR REPLACE INTO principal(scope,epoch,begin,user,ambiguous,conflict,ready,evidence_end,has_proxy,proxy_ms) VALUES(@p0,@p1,@p2,@p3,@p4,@p5,@p6,@p7,@p8,@p9);", "iiitiiiiii"),
                        (long)_scope, (long)_e.Index, p.BeginPos, p.User, p.Ambiguous ? 1L : 0L, p.Conflict ? 1L : 0L, p.ReadyMs, p.EndPos, p.HasProxy ? 1L : 0L, p.ProxyMs).ExecuteNonQuery();
                    return;
                }
                if (Main) return;
                if (p.EndReason == null) p.EndReason = "Open";
                if (!EligibleAt(p)) return;
                Eligible++;
                if (p.EndMs == _anchor.Ms && p.EndReason != "Disconnect") { Ambiguous = true; return; }
                if (p.Ambiguous || p.Conflict || p.User == null) { Ambiguous = true; return; }
                if (Found == null) Found = new AuthToken { User = p.User, Mechanism = p.Mech, Evidence = p.Evidence, ReadyMs = p.ReadyMs,
                    Attempt = ReferenceEquals(_atAnchor, p) ? _attemptAtAnchor : SmtpAuth.Succeeded };
            }

            bool EligibleAt(Principal p)
            {
                var a = _anchor;
                if (p.Broken || p.StartUnknown || !p.HasProxy || (p.User == null && !p.Ambiguous)) return false;
                if (p.BeginMs > a.Ms || Math.Abs(a.Ms - p.ProxyMs) > _r._idleMs) return false;
                string helo = p.HeloAtSuccess ?? (_e.Legacy ? _e.Helo : null);
                if (a.Helo != null && helo != null && !string.Equals(a.Helo, helo, StringComparison.OrdinalIgnoreCase)) return false;
                if (p.ReadyMs <= a.Ms)
                {
                    if (p.EndReason == "Open" || p.EndReason == null) return a.Ms <= _e.LastMs;
                    return a.Ms <= p.EndMs;
                }
                // The front end writes its 235 after the back end asked for the handshake: the same attempt, begun before the XPROXY, whose
                // proxy set-up and success bracket meets the bracket of the handshake. An AUTH begun after the XPROXY never qualifies.
                return p.BeginMs <= a.Ms && Math.Max(p.ProxyMs, a.Ms) <= Math.Min(p.SuccessMs, a.AcceptMs);
            }
        }

        /// <summary>The five values of a transaction of a back end handed over by a front end, from the proof of the handshake.</summary>
        AuthSnap Handoff(AuthEpoch be, AuthBind bind, AuthObs mail)
        {
            var s = new AuthSnap { Result = SmtpAuth.Unknown, Attempt = SmtpAuth.Unknown, Source = SmtpAuth.Missing };
            var t = bind.Token ?? (bind.Token = ResolveToken(be, bind));
            if (t.Status == SmtpAuth.Ambiguous) { s.Source = SmtpAuth.Ambiguous; return s; }
            if (t.Status != AuthToken.Ok || mail.Ms < t.ReadyMs) return s;
            s.Mechanism = t.Mechanism == "Unknown" ? null : t.Mechanism;
            s.Result = SmtpAuth.Succeeded; s.Attempt = t.Attempt ?? SmtpAuth.Succeeded;
            s.User = t.User; s.Source = SmtpAuth.FrontEndProxy; s.Evidence = t.Evidence;
            return s;
        }
    }
}
