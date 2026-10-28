#Requires -Version 7.4
<#
.SYNOPSIS
    Writes synthetic Exchange Server SE logs with the volumes of a production environment, to measure and
    tune the collection of Exchange Log Report (load test). No Exchange server is needed.

.DESCRIPTION
    The logs have the exact headers and line shapes of Exchange Server SE (same formats as the Pester tests),
    with the noise of a real environment, and the volumes of the 1.6.1 capture of a customer (per server and
    per day, -Scale 1):

        HttpProxy           ~389,000 lines (~285 MB), 13.5 % real users (Outlook MAPI, EWS, Autodiscover, OWA...)
        IIS front end       ~425,000 lines (~110 MB), one line per proxied request + static content
        MAPI back end        ~48,000 lines (~45 MB), 57 % real (the MAPI requests proxied to this server)
        IIS back end        ~125,000 lines (~33 MB), server-to-server traffic (few ActiveSync lines)
        SMTP in (FrontEnd)   ~93,000 lines (~18 MB), 91 % real (load balancer probes otherwise)
        SMTP out (FrontEnd)  ~98,000 lines (~18 MB), 99 % real
        Message tracking    ~104,000 lines (~75 MB), 65 % real (shadow redundancy and health probes otherwise)

    Folders: <Path>\<SERVER>\Exchange\... and <Path>\<SERVER>\inetpub\logs\LogFiles\W3SVC1|W3SVC2, so that
    a configuration only needs ExchangePath and IisLogPath per server. The last write time of every file is
    the time of its last line (BackfillDays works as with real logs).

    The content is deterministic (-Seed): -Only writes the files of some servers only, identical to those of a
    full run (each Exchange server of the lab can generate its own logs in place).

.PARAMETER Path
    Root folder of the logs.

.PARAMETER Server
    Names of the simulated servers (the MAPI and ActiveSync back-end logs of a server hold the requests that
    the front ends of all of them proxied to it).

.PARAMETER Only
    Writes the files of these servers only (default: all).

.PARAMETER Days
    Days of logs, ending at the last full hour (-End).

.PARAMETER Scale
    Volume factor: 1 = the production profile above, 0.1 = a tenth.

.PARAMETER Users
    Real users of the organisation.

.PARAMETER Profile
    Production (default): every server has the volumes above. Decommission (3 servers or more): the last server
    has no real usage (probes, health mailboxes and load balancer checks only) and the one before it a residual
    usage - a few users with old clients (Outlook 2013, RPC over HTTP, old Android and iPhone, an EWS application,
    Internet Explorer) and a scanner that still relays mail through it without TLS. The mailboxes are on the
    other servers. For the screenshots of a decommissioning review.

.EXAMPLE
    .\tools\New-ExlSyntheticLogs.ps1 -Path D:\ElrSim -Server SIM01,SIM02 -Days 14
    About 8 GB of logs per server, the volume of the customer capture.

.EXAMPLE
    .\tools\New-ExlSyntheticLogs.ps1 -Path D:\ElrDemo -Server EXCH01,EXCH02,EXCH03,EXCH04 -Days 30 -Scale 0.05 -Users 800 -Profile Decommission
    A month of logs where EXCH03 is barely used and EXCH04 not at all.

.EXAMPLE
    .\tools\New-ExlSyntheticLogs.ps1 -Path E:\ElrSim -Server EXMBX1,EXMBX2,EXMBX3,EXMBX4 -Only EXMBX1 -Days 14
    On EXMBX1 of the lab: its own logs only, identical to a full run.

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string[]]$Server,
    [string[]]$Only,
    [ValidateRange(1, 60)][int]$Days = 14,
    [ValidateRange(0.001, 20)][double]$Scale = 1.0,
    [ValidateRange(10, 1000000)][int]$Users = 4000,
    [ValidateSet('Production', 'Decommission')][string]$Profile = 'Production',
    [int]$Seed = 1,
    [datetime]$End
)

$ErrorActionPreference = 'Stop'
# "A,B" given as one value (pwsh -File): a list.
$Server = @($Server | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

if (-not ('ExlSim.Generator' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;

namespace ExlSim
{
    public sealed class Options
    {
        public string Root;
        public string[] Servers = new string[0];
        public string[] Only = new string[0];
        public int Days = 14, Users = 4000, Seed = 1;
        public double Scale = 1.0;
        public DateTime EndUtc;
        public string Domain = "contoso.com", NetBios = "CONTOSO";
        public string Profile = "Production";
    }

    public sealed class Stat
    {
        public string Server, Kind;
        public long Files, Lines, Bytes;
    }

    /// <summary>One log file being written: lines are appended in time order, the file rolls over like Exchange.</summary>
    sealed class LogFile
    {
        public string Path;
        public StreamWriter Writer;
        public int Number;
        public long Bytes, Lines;
        public DateTime LastUtc;
    }

    struct Line
    {
        public long T;
        public string Text;
        public Line(long t, string text) { T = t; Text = text; }
    }

    public sealed class Generator
    {
        // Volumes per server and per day at Scale 1 (1.6.1 capture of a customer, 14 days).
        const double ProxyRealPerDay = 52500, ProxyNoisePerDay = 336500, IisStaticPerDay = 36000;
        const double MapiBeNoisePerDay = 20800, BackEndIisPerDay = 125000;
        const double SmtpInSessionsPerDay = 3600, SmtpInProbesPerDay = 2100, SmtpOutSessionsPerDay = 4250;
        const double MessagesPerDay = 20500, ProbeMessagesPerDay = 4000;
        static readonly UTF8Encoding Utf8Bom = new UTF8Encoding(true);
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        public const string ProxyFields = "DateTime,RequestId,MajorVersion,MinorVersion,BuildVersion,RevisionVersion,ClientRequestId,Protocol,UrlHost,UrlStem,ProtocolAction,AuthenticationType,IsAuthenticated,AuthenticatedUser,Organization,AnchorMailbox,UserAgent,ClientIpAddress,ServerHostName,HttpStatus,BackEndStatus,ErrorCode,Method,ProxyAction,TargetServer,TargetServerVersion,RoutingType,RoutingHint,BackEndCookie,ServerLocatorHost,ServerLocatorLatency,RequestBytes,ResponseBytes,TargetOutstandingRequests,AuthModulePerfContext,HttpPipelineLatency,CalculateTargetBackEndLatency,GlsLatencyBreakup,TotalGlsLatency,AccountForestLatencyBreakup,TotalAccountForestLatency,ResourceForestLatencyBreakup,TotalResourceForestLatency,ADLatency,SharedCacheLatencyBreakup,TotalSharedCacheLatency,ActivityContextLifeTime,ModuleToHandlerSwitchingLatency,ClientReqStreamLatency,BackendReqInitLatency,BackendReqStreamLatency,BackendProcessingLatency,BackendRespInitLatency,BackendRespStreamLatency,ClientRespStreamLatency,KerberosAuthHeaderLatency,HandlerCompletionLatency,RequestHandlerLatency,HandlerToModuleSwitchingLatency,ProxyTime,CoreLatency,RoutingLatency,HttpProxyOverhead,TotalRequestTime,RouteRefresherLatency,UrlQuery,BackEndGenericInfo,GenericInfo,GenericErrors,EdgeTraceId,DatabaseGuid,UserADObjectGuid,PartitionEndpointLookupLatency,RoutingStatus";
        public const string MapiFields = "DateTime,RequestId,MapiRequestId,ClientRequestId,RequestType,HttpStatusCode,ResponseCode,StatusCode,ReturnCode,TotalRequestLatency,DeploymentRing,MajorVersion,MinorVersion,BuildVersion,RevisionVersion,AuthenticatedUserEmail,UPN,Puid,TenantGuid,MailboxId,MDBGuid,ActAsUserEmail,ClientIP,SourceCafeServer,EdgeInfo,NetworkDeviceInfo,SessionCookie,SequenceCookie,MapiClientInfo,ClientSoftware,ClientSoftwareVersion,ClientMode,AuthenticationType,AuthModuleLatency,LiveIdBasicLog,LiveIdBasicError,LiveIdNegotiateError,OAuthLatency,OAuthError,OAuthErrorCategory,OAuthExtraInfo,AuthenticatedUser,RopIds,OperationSpecific,GenericInfo,GenericErrors";
        public const string IisFields = "date time s-ip cs-method cs-uri-stem cs-uri-query s-port cs-username c-ip cs(User-Agent) cs(Referer) sc-status sc-substatus sc-win32-status sc-bytes cs-bytes time-taken";
        public const string SmtpFields = "date-time,connector-id,session-id,sequence-number,local-endpoint,remote-endpoint,event,data,context";
        public const string TrackingFields = "date-time,client-ip,client-hostname,server-ip,server-hostname,source-context,connector-id,source,event-id,internal-message-id,message-id,network-message-id,recipient-address,recipient-status,total-bytes,recipient-count,related-recipient-address,reference,message-subject,sender-address,return-path,message-info,directionality,tenant-id,original-client-ip,original-server-ip,custom-data,transport-traffic-type,log-id,schema-version";

        static readonly string[] ProxyNames = ProxyFields.Split(',');
        static readonly Dictionary<string, int> PX = ProxyNames.Select((n, i) => new KeyValuePair<string, int>(n, i)).ToDictionary(x => x.Key, x => x.Value);
        static readonly string[] MapiNames = MapiFields.Split(',');
        static readonly Dictionary<string, int> MX = MapiNames.Select((n, i) => new KeyValuePair<string, int>(n, i)).ToDictionary(x => x.Key, x => x.Value);

        readonly Options _o;
        readonly string[] _servers;
        readonly HashSet<string> _write;
        readonly Dictionary<string, LogFile> _open = new Dictionary<string, LogFile>(StringComparer.OrdinalIgnoreCase);
        readonly Dictionary<string, Stat> _stats = new Dictionary<string, Stat>(StringComparer.Ordinal);
        readonly string[] _words = ("budget review meeting project status update invoice order delivery report weekly monthly quarterly plan " +
            "contract proposal agenda minutes follow-up request approval travel expense customer partner training offer release incident " +
            "migration server mailbox license renewal schedule draft final signed urgent reminder question answer feedback").Split(' ');
        public Action<string> Progress;

        public Generator(Options o)
        {
            _o = o;
            _servers = o.Servers.Select(s => s.ToUpperInvariant()).ToArray();
            _write = new HashSet<string>((o.Only != null && o.Only.Length > 0 ? o.Only : o.Servers).Select(s => s.ToUpperInvariant()), StringComparer.OrdinalIgnoreCase);
        }

        // ------------------------------------------------------------------ helpers

        Random Rng(int server, int hour, int kind) { unchecked { return new Random(((_o.Seed * 7919 + server) * 104729 + hour) * 31 + kind); } }

        static Guid G(Random r) { var b = new byte[16]; r.NextBytes(b); return new Guid(b); }

        static string Iso(long ms) { return DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", Inv); }
        static string W3c(long ms) { return DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss", Inv); }

        static string Csv(string v)
        {
            if (string.IsNullOrEmpty(v)) return "";
            if (v.IndexOf(',') < 0 && v.IndexOf('"') < 0) return v;
            return "\"" + v.Replace("\"", "\"\"") + "\"";
        }

        static string Join(string[] cells)
        {
            var sb = new StringBuilder(1024);
            for (int i = 0; i < cells.Length; i++) { if (i > 0) sb.Append(','); sb.Append(Csv(cells[i])); }
            return sb.ToString();
        }

        double Volume(double perDay, double weight) { return perDay * _o.Scale * weight; }

        /// <summary>Count with random rounding, so that small volumes are right on average.</summary>
        static int Count(Random r, double expected)
        {
            if (expected <= 0) return 0;
            int n = (int)Math.Floor(expected);
            if (r.NextDouble() < expected - n) n++;
            return n;
        }

        /// <summary>Share of the day's real activity in this hour (UTC; office hours 06-18 UTC, quiet nights and weekends).</summary>
        static double Weight(DateTime hourUtc)
        {
            bool weekend = hourUtc.DayOfWeek == DayOfWeek.Saturday || hourUtc.DayOfWeek == DayOfWeek.Sunday;
            double w = hourUtc.Hour >= 6 && hourUtc.Hour < 18 ? 1.0 : 0.12;
            if (weekend) w *= 0.15;
            return w / 13.44;   // 12 office hours + 12 quiet hours at 0.12 = 13.44
        }

        // ------------------------------------------------------------------ Decommission profile
        // The last server has no real usage (probes, health mailboxes and load balancer checks only); the one before
        // it a residual usage: a few accounts whose old clients still connect to it only (outside the -Users pool),
        // and one scanner that still relays mail through it without TLS. The mailboxes are on the other servers.

        bool Decommission { get { return string.Equals(_o.Profile, "Decommission", StringComparison.OrdinalIgnoreCase) && _servers.Length >= 3; } }
        bool Idle(int s) { return Decommission && s == _servers.Length - 1; }
        bool Residual(int s) { return Decommission && s == _servers.Length - 2; }
        int ActiveServers { get { return Decommission ? _servers.Length - 2 : _servers.Length; } }
        const double ResidualRequestsPerDay = 320, ResidualSmtpPerDay = 36;

        sealed class Legacy { public int Offset; public string[] Protocols; public string Agent; }
        static readonly Legacy[] LegacyUsers =
        {
            new Legacy { Offset = 1, Protocols = new[] { "Mapi", "Mapi", "Autodiscover", "Ews" }, Agent = "Microsoft Office/15.0 (Windows NT 6.1; Microsoft Outlook 15.0.5537; Pro)" },
            new Legacy { Offset = 2, Protocols = new[] { "Mapi", "Mapi", "Autodiscover", "Ews" }, Agent = "Microsoft Office/15.0 (Windows NT 6.1; Microsoft Outlook 15.0.5537; Pro)" },
            new Legacy { Offset = 3, Protocols = new[] { "RpcHttp", "Autodiscover" }, Agent = "MSRPC" },
            new Legacy { Offset = 4, Protocols = new[] { "Eas" }, Agent = "Android-SAMSUNG-SM-A515F/101.10" },
            new Legacy { Offset = 5, Protocols = new[] { "Eas" }, Agent = "Apple-iPhone9C1/1705.36" },
            new Legacy { Offset = 6, Protocols = new[] { "Ews" }, Agent = "ERP-Connector/2.1 (EWS Managed API 2.2)" },
            new Legacy { Offset = 7, Protocols = new[] { "Owa" }, Agent = "Mozilla/5.0 (Windows NT 6.1; Trident/7.0; rv:11.0) like Gecko" }
        };
        const string ScannerIp = "10.30.9.50", ScannerHelo = "scan-legacy01", ScannerFrom = "scanner";

        string UserName(int u) { return "user" + u.ToString("D5", Inv); }
        string Smtp(int u) { return UserName(u) + "@" + _o.Domain; }
        string Account(int u) { return _o.NetBios + "\\" + UserName(u); }
        string Fqdn(int s) { return _servers[s].ToLowerInvariant() + "." + _o.Domain; }
        string ServerIp(int s) { return "10.20.0." + (11 + s).ToString(Inv); }

        sealed class UserInfo { public string Ip, MailboxGuid, Instance, Agent, Device; public int Home; public bool Mac, Mobile; }
        readonly Dictionary<int, UserInfo> _users = new Dictionary<int, UserInfo>();

        UserInfo Info(int u)
        {
            UserInfo x;
            if (_users.TryGetValue(u, out x)) return x;
            var r = new Random(_o.Seed * 31 + u);
            x = new UserInfo
            {
                Ip = "10." + (1 + u % 40).ToString(Inv) + "." + r.Next(0, 255).ToString(Inv) + "." + r.Next(2, 254).ToString(Inv),
                MailboxGuid = G(r).ToString("D"), Instance = "{" + G(r).ToString("D").ToUpperInvariant() + "}",
                Home = u % Math.Max(1, ActiveServers), Mac = r.NextDouble() < 0.05, Mobile = r.NextDouble() < 0.08,
                Device = "Dev" + G(r).ToString("N").Substring(0, 20).ToUpperInvariant()
            };
            x.Agent = x.Mac ? "MacOutlook/16.89.24091630 (Intelx64 Mac OS X 14.6.1 (Build 23G93))"
                : "Microsoft Office/16.0 (Windows NT 10.0; Microsoft Outlook 16.0." + (17928 + u % 7 * 100).ToString(Inv) + "; Pro)";
            _users[u] = x;
            return x;
        }

        int PickUser(Random r) { return 1 + (int)(_o.Users * Math.Pow(r.NextDouble(), 2.2)) % _o.Users; }

        // ------------------------------------------------------------------ files

        string ExchangeRoot(int s) { return System.IO.Path.Combine(_o.Root, _servers[s], "Exchange"); }
        string IisRoot(int s) { return System.IO.Path.Combine(_o.Root, _servers[s], "inetpub", "logs", "LogFiles"); }

        void Count(int s, string kind, long lines, long bytes, bool newFile)
        {
            string key = _servers[s] + "|" + kind;
            Stat st;
            if (!_stats.TryGetValue(key, out st)) { st = new Stat { Server = _servers[s], Kind = kind }; _stats[key] = st; }
            st.Lines += lines; st.Bytes += bytes; if (newFile) st.Files++;
        }

        /// <summary>
        /// Appends lines (already in time order) to the open file of a key. The file is closed at the end of its
        /// hour or day (CloseBefore) and rolls over to the next number at the size limit, like Exchange.
        /// </summary>
        void Append(int s, string kind, string key, Func<int, string> name, string[] header, List<Line> lines, long maxBytes)
        {
            if (!_write.Contains(_servers[s]) || lines.Count == 0) return;
            LogFile f;
            _open.TryGetValue(key, out f);
            foreach (var l in lines)
            {
                if (f != null && maxBytes > 0 && f.Bytes >= maxBytes)
                {
                    int next = f.Number + 1;
                    Close(f);
                    f = Open(s, kind, name(next), next, header);
                }
                if (f == null) f = Open(s, kind, name(1), 1, header);
                f.Writer.WriteLine(l.Text);
                f.Bytes += l.Text.Length + 2;
                f.Lines++;
                f.LastUtc = DateTimeOffset.FromUnixTimeMilliseconds(l.T).UtcDateTime;
                Count(s, kind, 1, l.Text.Length + 2, false);
            }
            _open[key] = f;
        }

        LogFile Open(int s, string kind, string path, int number, string[] header)
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path));
            var f = new LogFile { Path = path, Number = number, Writer = new StreamWriter(path, false, Utf8Bom, 1 << 20) { NewLine = "\r\n" } };
            foreach (var h in header) { f.Writer.WriteLine(h); f.Bytes += h.Length + 2; }
            Count(s, kind, header.Length, f.Bytes, true);
            return f;
        }

        void Close(LogFile f)
        {
            if (f == null) return;
            f.Writer.Dispose();
            var t = f.LastUtc == default(DateTime) ? DateTime.UtcNow : f.LastUtc;
            File.SetLastWriteTimeUtc(f.Path, t);
            var key = _open.FirstOrDefault(kv => ReferenceEquals(kv.Value, f)).Key;
            if (key != null) _open.Remove(key);
        }

        void CloseAll() { foreach (var f in _open.Values.ToList()) Close(f); _open.Clear(); }

        /// <summary>Closes the files whose hour or day is over.</summary>
        void CloseBefore(string keyPrefix)
        {
            foreach (var kv in _open.Where(kv => kv.Key.StartsWith(keyPrefix, StringComparison.Ordinal)).ToList()) Close(kv.Value);
        }

        // ------------------------------------------------------------------ run

        public Stat[] Run()
        {
            var end = new DateTime(_o.EndUtc.Year, _o.EndUtc.Month, _o.EndUtc.Day, _o.EndUtc.Hour, 0, 0, DateTimeKind.Utc);
            var start = end.AddDays(-_o.Days);
            int hours = (int)(end - start).TotalHours;
            string lastDay = null;
            for (int h = 0; h < hours; h++)
            {
                var hour = start.AddHours(h);
                string day = hour.ToString("yyyyMMdd", Inv);
                if (lastDay != null && day != lastDay) CloseBefore("day|");
                lastDay = day;
                var backEnd = new List<Line>[_servers.Length];
                var easBackEnd = new List<Line>[_servers.Length];
                for (int s = 0; s < _servers.Length; s++) { backEnd[s] = new List<Line>(); easBackEnd[s] = new List<Line>(); }
                for (int s = 0; s < _servers.Length; s++) ClientAccess(s, h, hour, backEnd, easBackEnd);
                for (int s = 0; s < _servers.Length; s++)
                {
                    MapiBackEnd(s, h, hour, backEnd[s]);
                    IisBackEnd(s, h, hour, easBackEnd[s]);
                    SmtpReceive(s, h, hour);
                    SmtpSend(s, h, hour);
                    Tracking(s, h, hour);
                }
                CloseBefore("hour|");
                if (Progress != null && (h % 24 == 23 || h == hours - 1)) Progress(string.Format(Inv, "{0} ({1}/{2} days)", hour.ToString("yyyy-MM-dd", Inv), (h + 1) / 24, _o.Days));
            }
            CloseAll();
            return _stats.Values.OrderBy(x => x.Server).ThenBy(x => x.Kind).ToArray();
        }

        // ------------------------------------------------------------------ client access: HttpProxy, IIS front end

        static readonly string[] Protocols = { "Mapi", "Ews", "Autodiscover", "Owa", "Oab", "Ecp", "Rest", "RpcHttp", "PowerShell", "Eas" };
        static readonly double[] ProtocolShare = { 0.52, 0.16, 0.09, 0.08, 0.02, 0.01, 0.03, 0.04, 0.01, 0.04 };
        static readonly string[] ProbeProtocols = { "Mapi", "Ews", "Autodiscover", "Owa", "Oab", "Ecp", "Rest", "RpcHttp", "PowerShell", "Eas", "PushNotifications" };

        static string Stem(string p)
        {
            switch (p)
            {
                case "Mapi": return "/mapi/emsmdb/";
                case "Ews": return "/EWS/Exchange.asmx";
                case "Autodiscover": return "/autodiscover/autodiscover.xml";
                case "Owa": return "/owa/service.svc";
                case "Oab": return "/OAB/3d6e1a2b-1f2e-4c5d-9e8f-0a1b2c3d4e5f/oab.xml";
                case "Ecp": return "/ecp/DDI/DDIService.svc/GetList";
                case "Rest": return "/api/v2.0/me/messages";
                case "RpcHttp": return "/rpc/rpcproxy.dll";
                case "PowerShell": return "/powershell";
                case "Eas": return "/Microsoft-Server-ActiveSync/default.eas";
                default: return "/PushNotifications/";
            }
        }

        void ClientAccess(int s, int h, DateTime hour, List<Line>[] backEnd, List<Line>[] easBackEnd)
        {
            var r = Rng(s, h, 1);
            long h0 = new DateTimeOffset(hour).ToUnixTimeMilliseconds();
            var proxy = new Dictionary<string, List<Line>>(StringComparer.Ordinal);
            foreach (var p in ProbeProtocols) proxy[p] = new List<Line>();
            var iis = new List<Line>();
            string me = _servers[s], fqdn = Fqdn(s), ip = ServerIp(s);

            // Real users (Decommission profile: none on the last server, a few legacy clients on the one before).
            int real = Idle(s) ? 0 : Residual(s) ? Count(r, ResidualRequestsPerDay * Weight(hour)) : Count(r, Volume(ProxyRealPerDay, Weight(hour)));
            for (int i = 0; i < real; i++)
            {
                long t = h0 + (long)(r.NextDouble() * 3600000);
                Legacy legacy = Residual(s) ? LegacyUsers[r.Next(LegacyUsers.Length)] : null;
                int u = legacy != null ? _o.Users + legacy.Offset : PickUser(r);
                var ui = Info(u);
                double x = r.NextDouble(), acc = 0; string p = "Ews";
                for (int k = 0; k < Protocols.Length; k++) { acc += ProtocolShare[k]; if (x < acc) { p = Protocols[k]; break; } }
                if (ui.Mac && p == "Mapi") p = "Ews";
                if (p == "Eas" && !ui.Mobile) p = "Ews";
                if (legacy != null) p = legacy.Protocols[r.Next(legacy.Protocols.Length)];
                int target = p == "Mapi" || p == "Eas" || p == "Ews" || p == "Owa" || p == "Rest" ? ui.Home : r.Next(ActiveServers);
                string agent = legacy != null ? legacy.Agent
                    : p == "Owa" || p == "Ecp" ? "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0"
                    : p == "Eas" ? "Apple-iPhone15C2/2107.102" : p == "PowerShell" ? "Microsoft WinRM Client" : ui.Agent;
                string deviceType = agent.StartsWith("Android", StringComparison.Ordinal) ? "Android" : "iPhone";
                string action = null, clientReq = null, query = null, method = "POST";
                long ms = (long)Math.Exp(3.2 + r.NextDouble() * 1.8 + (r.NextDouble() < 0.02 ? 3 : 0));
                switch (p)
                {
                    case "Mapi":
                        double m = r.NextDouble();
                        action = m < 0.62 ? "Execute" : m < 0.86 ? "NotificationWait" : m < 0.93 ? "PING" : m < 0.965 ? "Connect" : m < 0.985 ? "Bind" : "Disconnect";
                        if (action == "NotificationWait") ms = 60000 + r.Next(0, 840000);
                        clientReq = "R:{" + G(r).ToString("D").ToUpperInvariant() + "}:" + r.Next(1, 900).ToString(Inv) + ";RT:" + action + ";CI:" + ui.Instance + ":1;CID:<null>";
                        query = "?MailboxId=" + ui.MailboxGuid + "@" + _o.Domain;
                        break;
                    case "Ews": action = r.NextDouble() < 0.5 ? "GetItem" : r.NextDouble() < 0.5 ? "FindItem" : "SyncFolderItems"; break;
                    case "Eas":
                        action = r.NextDouble() < 0.6 ? "Ping" : "Sync";
                        if (action == "Ping") ms = 400000 + r.Next(0, 500000);
                        query = "?Cmd=" + action + "&User=" + UserName(u) + "&DeviceId=" + ui.Device + "&DeviceType=" + deviceType;
                        break;
                    case "Owa": action = r.NextDouble() < 0.5 ? "GetItem" : "FindConversation"; query = "?action=" + action + "&app=Mail&n=" + r.Next(1, 300).ToString(Inv); break;
                    case "Autodiscover": method = "POST"; break;
                    case "Oab": method = "GET"; break;
                    case "RpcHttp": method = "RPC_IN_DATA"; ms = 600000 + r.Next(0, 3000000); break;
                }
                int status = 200;
                double f = r.NextDouble();
                if (f < 0.018) status = r.NextDouble() < 0.7 ? 500 : 503;
                else if (f < 0.036) status = r.NextDouble() < 0.6 ? 404 : 400;
                else if (f < 0.045) status = 401;
                else if (f < 0.05 && p == "Owa") status = 440;
                string reqId = G(r).ToString("D");
                bool challenge = r.NextDouble() < 0.12;
                if (challenge)
                {
                    // Anonymous 401 of the NTLM / Kerberos handshake that precedes the request (noise).
                    long tc = t - 3;
                    proxy[p].Add(new Line(tc, ProxyLine(r, tc, G(r).ToString("D"), p, null, null, agent, ui.Ip, me, 401, 401, method, null, null, null, 0, null, null, "Negotiate")));
                    iis.Add(new Line(tc, IisLine(tc, ip, method, Stem(p), "&CorrelationID=<empty>;&cafeReqId=" + G(r).ToString("D") + ";", null, ui.Ip, agent, 401, 2, 5, 3)));
                }
                string user = status == 401 ? null : Account(u);
                string anchor = p == "Mapi" ? "MailboxGuid~" + ui.MailboxGuid : "SMTP:" + Smtp(u);
                proxy[p].Add(new Line(t, ProxyLine(r, t, reqId, p, user, anchor, agent, ui.Ip, me, status, status == 401 ? 0 : status, method, Fqdn(target), action, clientReq, ms, query,
                    status >= 500 ? "BackEndServerException;" : null, p == "Eas" ? "Basic" : "Negotiate")));
                iis.Add(new Line(t, IisLine(t, ip, method, Stem(p), (query ?? "").TrimStart('?') + (query != null ? "&" : "&") + "CorrelationID=<empty>;&cafeReqId=" + reqId + ";",
                    status == 401 ? Account(u) : Account(u), ui.Ip, agent, status, status == 401 ? 1 : 0, status == 401 ? 1326 : 0, ms)));
                if (p == "Mapi" && status < 400) backEnd[target].Add(new Line(t + 2, MapiBackEndLine(r, t + 2, reqId, action, u, ui, me, ms)));
                if (p == "Eas" && status < 400) easBackEnd[target].Add(new Line(t + 2, IisLine(t + 2, ServerIp(target), "POST", "/Microsoft-Server-ActiveSync/Proxy/default.eas",
                    "Cmd=" + action + "&User=" + UserName(u) + "&DeviceId=" + ui.Device + "&DeviceType=" + deviceType + "&Log=SC1:1_PrxFrom:" + ip + "_Ver1:161_As:AllowedG_Mbx:" + Fqdn(target), Account(u), ip, agent, 200, 0, 0, ms)));
            }

            // Noise: Managed Availability probes, health mailboxes, anonymous challenges, load balancer checks.
            int noise = Count(r, Volume(ProxyNoisePerDay, 1.0 / 24));
            for (int i = 0; i < noise; i++)
            {
                long t = h0 + (long)(r.NextDouble() * 3600000);
                double k = r.NextDouble();
                string p = ProbeProtocols[r.Next(ProbeProtocols.Length)];
                string reqId = G(r).ToString("D");
                if (k < 0.62)
                {
                    string health = "HealthMailbox" + (s * 7 + r.Next(0, 6)).ToString("x2", Inv) + "c3d1e2f4a5b6c7d8e9f0a1b2c3d4e5f6a";
                    bool anon = r.NextDouble() < 0.3;
                    string agent = r.NextDouble() < 0.5 ? "AMProbe/Local/ClientAccess" : "Microsoft.Exchange.Monitoring.ActiveMonitoring";
                    proxy[p].Add(new Line(t, ProxyLine(r, t, reqId, p, anon ? null : _o.NetBios + "\\" + health, anon ? null : "SMTP:" + health + "@" + _o.Domain, agent, r.NextDouble() < 0.5 ? "::1" : "127.0.0.1", me,
                        anon ? 401 : 200, anon ? 0 : 200, "POST", fqdn, null, null, (long)r.Next(5, 400), null, null, "Negotiate")));
                    iis.Add(new Line(t, IisLine(t, "::1", "POST", Stem(p), "&CorrelationID=<empty>;&cafeReqId=" + reqId + ";", anon ? null : health + "@" + _o.Domain, "::1", agent, anon ? 401 : 200, anon ? 2 : 0, anon ? 5 : 0, r.Next(5, 400))));
                }
                else if (k < 0.88)
                {
                    int u = PickUser(r);
                    var ui = Info(u);
                    proxy[p].Add(new Line(t, ProxyLine(r, t, reqId, p, null, null, ui.Agent, ui.Ip, me, 401, 0, "POST", null, null, null, (long)r.Next(1, 5), null, null, "Negotiate")));
                    iis.Add(new Line(t, IisLine(t, ip, "POST", Stem(p), "&CorrelationID=<empty>;&cafeReqId=" + reqId + ";", null, ui.Ip, ui.Agent, 401, 2, 5, r.Next(1, 5))));
                }
                else
                {
                    proxy["Owa"].Add(new Line(t, ProxyLine(r, t, reqId, "Owa", null, null, "LoadBalancer-HealthCheck/1.0", "10.20.0.5", me, 200, 200, "GET", fqdn, null, null, 2, null, null, null, "/owa/healthcheck.htm")));
                    iis.Add(new Line(t, IisLine(t, ip, "GET", "/owa/healthcheck.htm", "&CorrelationID=<empty>;&cafeReqId=" + reqId + ";", null, "10.20.0.5", "LoadBalancer-HealthCheck/1.0", 200, 0, 0, 2)));
                }
            }

            // IIS only: static content of OWA and ECP, served without the proxy.
            int stat = Idle(s) ? 0 : Count(r, Volume(IisStaticPerDay, Weight(hour)) * (Residual(s) ? 0.005 : 1));
            for (int i = 0; i < stat; i++)
            {
                long t = h0 + (long)(r.NextDouble() * 3600000);
                var ui = Info(PickUser(r));
                iis.Add(new Line(t, IisLine(t, ip, "GET", "/owa/prem/15.2.1544.4/resources/styles/0/boot.worldwide.mouse.css", "-", null, ui.Ip,
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36", 200, 0, 0, r.Next(0, 30))));
            }

            string stamp = hour.ToString("yyyyMMddHH", Inv);
            foreach (var kv in proxy)
            {
                if (kv.Value.Count == 0) continue;
                kv.Value.Sort((a, b) => a.T.CompareTo(b.T));
                string folder = System.IO.Path.Combine(ExchangeRoot(s), "Logging", "HttpProxy", kv.Key);
                Append(s, "HttpProxy", "hour|" + s + "|px|" + kv.Key, n => System.IO.Path.Combine(folder, "HttpProxy_" + stamp + "-" + n.ToString(Inv) + ".LOG"),
                    new[] { "#Software: Microsoft Exchange Server", "#Version: 15.02.1544.004", "#Log-type: HttpProxy Logs", "#Date: " + Iso(new DateTimeOffset(hour).ToUnixTimeMilliseconds()), "#Fields: " + ProxyFields, ProxyFields },
                    kv.Value, 10L << 20);
            }
            iis.Sort((a, b) => a.T.CompareTo(b.T));
            string iisDay = hour.ToString("yyMMdd", Inv);
            string w3 = System.IO.Path.Combine(IisRoot(s), "W3SVC1");
            Append(s, "IIS front end", "day|" + s + "|w3svc1", n => System.IO.Path.Combine(w3, "u_ex" + iisDay + (n > 1 ? "_x" + n.ToString(Inv) : "") + ".log"),
                new[] { "#Software: Microsoft Internet Information Services 10.0", "#Version: 1.0", "#Date: " + W3c(new DateTimeOffset(hour).ToUnixTimeMilliseconds()), "#Fields: " + IisFields }, iis, 0);
        }

        readonly string[] _px = new string[ProxyNames.Length];

        string ProxyLine(Random r, long t, string reqId, string protocol, string user, string anchor, string agent, string clientIp, string server, int status, int backEnd,
            string method, string target, string action, string clientReq, long ms, string query, string errors, string auth, string stem = null)
        {
            var c = _px;
            Array.Clear(c, 0, c.Length);
            c[PX["DateTime"]] = Iso(t); c[PX["RequestId"]] = reqId; c[PX["MajorVersion"]] = "15"; c[PX["MinorVersion"]] = "2"; c[PX["BuildVersion"]] = "1544"; c[PX["RevisionVersion"]] = "4";
            c[PX["ClientRequestId"]] = clientReq; c[PX["Protocol"]] = protocol; c[PX["UrlHost"]] = "mail." + _o.Domain; c[PX["UrlStem"]] = stem ?? Stem(protocol);
            c[PX["ProtocolAction"]] = protocol == "Owa" || protocol == "Ews" ? action : null; c[PX["AuthenticationType"]] = user == null ? null : auth;
            c[PX["IsAuthenticated"]] = user == null ? "False" : "True"; c[PX["AuthenticatedUser"]] = user; c[PX["AnchorMailbox"]] = anchor; c[PX["UserAgent"]] = agent;
            c[PX["ClientIpAddress"]] = clientIp; c[PX["ServerHostName"]] = server; c[PX["HttpStatus"]] = status.ToString(Inv); c[PX["BackEndStatus"]] = backEnd > 0 ? backEnd.ToString(Inv) : null;
            c[PX["Method"]] = method; c[PX["ProxyAction"]] = target == null ? null : "Proxy"; c[PX["TargetServer"]] = target; c[PX["TargetServerVersion"]] = target == null ? null : "Version 15.2 (Build 1544.4)";
            c[PX["RoutingType"]] = target == null ? null : "DatabaseGuid-ServerVersion"; c[PX["RoutingHint"]] = target == null ? null : "DatabaseGuid~" + G(r).ToString("D");
            c[PX["ServerLocatorHost"]] = target == null ? null : target; c[PX["ServerLocatorLatency"]] = r.Next(0, 3).ToString(Inv);
            c[PX["RequestBytes"]] = r.Next(200, 9000).ToString(Inv); c[PX["ResponseBytes"]] = r.Next(300, 60000).ToString(Inv); c[PX["TargetOutstandingRequests"]] = r.Next(0, 4).ToString(Inv);
            c[PX["AuthModulePerfContext"]] = "UAC=0;ULC=0;LGC=0;CCL=0;LGR=0;AuthInfoRequired=0;";
            c[PX["HttpPipelineLatency"]] = r.Next(0, 9).ToString(Inv); c[PX["CalculateTargetBackEndLatency"]] = r.Next(0, 4).ToString(Inv);
            c[PX["GlsLatencyBreakup"]] = null; c[PX["TotalGlsLatency"]] = "0"; c[PX["TotalAccountForestLatency"]] = "0"; c[PX["TotalResourceForestLatency"]] = "0";
            c[PX["ADLatency"]] = r.Next(0, 5).ToString(Inv); c[PX["TotalSharedCacheLatency"]] = "0"; c[PX["ActivityContextLifeTime"]] = ms.ToString(Inv);
            c[PX["ModuleToHandlerSwitchingLatency"]] = "0"; c[PX["ClientReqStreamLatency"]] = r.Next(0, 3).ToString(Inv); c[PX["BackendReqInitLatency"]] = r.Next(0, 3).ToString(Inv);
            c[PX["BackendReqStreamLatency"]] = r.Next(0, 3).ToString(Inv); c[PX["BackendProcessingLatency"]] = Math.Max(0, ms - 4).ToString(Inv); c[PX["BackendRespInitLatency"]] = r.Next(0, 3).ToString(Inv);
            c[PX["BackendRespStreamLatency"]] = r.Next(0, 3).ToString(Inv); c[PX["ClientRespStreamLatency"]] = r.Next(0, 3).ToString(Inv); c[PX["KerberosAuthHeaderLatency"]] = "0";
            c[PX["HandlerCompletionLatency"]] = "0"; c[PX["RequestHandlerLatency"]] = r.Next(1, 9).ToString(Inv); c[PX["HandlerToModuleSwitchingLatency"]] = "0";
            c[PX["ProxyTime"]] = r.Next(1, 9).ToString(Inv); c[PX["CoreLatency"]] = r.Next(1, 9).ToString(Inv); c[PX["RoutingLatency"]] = r.Next(0, 3).ToString(Inv);
            c[PX["HttpProxyOverhead"]] = r.Next(1, 12).ToString(Inv); c[PX["TotalRequestTime"]] = ms.ToString(Inv); c[PX["RouteRefresherLatency"]] = "0"; c[PX["UrlQuery"]] = query;
            c[PX["GenericInfo"]] = "OnBeginRequest=0;OnAuthenticateRequest=" + r.Next(0, 4).ToString(Inv) + ";OnPostAuthorizeRequest=" + r.Next(1, 6).ToString(Inv) +
                ";OnBeginProxyRequest=" + r.Next(2, 8).ToString(Inv) + ";OnProxyRequest=" + r.Next(2, 9).ToString(Inv) + ";BeginGetResponse=" + r.Next(3, 10).ToString(Inv) +
                ";OnResponseReady=" + ms.ToString(Inv) + ";EndRequest=" + (ms + 1).ToString(Inv) + ";S:ServiceCommonMetadata.HttpMethod=" + method + ";" +
                "I32:ADS.C[" + _o.NetBios + "DC1]=" + r.Next(1, 4).ToString(Inv) + ";F:ADS.AL[" + _o.NetBios + "DC1]=" + (r.NextDouble() * 3).ToString("0.000", Inv) + ";";
            c[PX["GenericErrors"]] = errors;
            c[PX["DatabaseGuid"]] = target == null ? null : G(r).ToString("D"); c[PX["UserADObjectGuid"]] = user == null ? null : G(r).ToString("D");
            c[PX["PartitionEndpointLookupLatency"]] = "0"; c[PX["RoutingStatus"]] = target == null ? null : "Success";
            return Join(c);
        }

        static string IisLine(long t, string serverIp, string method, string stem, string query, string user, string clientIp, string agent, int status, int sub, int win32, long ms)
        {
            var sb = new StringBuilder(300);
            sb.Append(W3c(t)).Append(' ').Append(serverIp).Append(' ').Append(method).Append(' ').Append(stem).Append(' ').Append(string.IsNullOrEmpty(query) ? "-" : query.Replace(' ', '+'))
              .Append(" 443 ").Append(string.IsNullOrEmpty(user) ? "-" : user).Append(' ').Append(clientIp).Append(' ').Append(string.IsNullOrEmpty(agent) ? "-" : agent.Replace(' ', '+'))
              .Append(" - ").Append(status.ToString(Inv)).Append(' ').Append(sub.ToString(Inv)).Append(' ').Append(win32.ToString(Inv)).Append(' ')
              .Append((1200 + (t % 9000)).ToString(Inv)).Append(' ').Append((400 + (t % 3000)).ToString(Inv)).Append(' ').Append(ms.ToString(Inv));
            return sb.ToString();
        }

        // ------------------------------------------------------------------ MAPI back end, IIS back end

        readonly string[] _mx = new string[MapiNames.Length];

        string MapiBackEndLine(Random r, long t, string reqId, string type, int u, UserInfo ui, string cafe, long ms)
        {
            var c = _mx;
            Array.Clear(c, 0, c.Length);
            c[MX["DateTime"]] = Iso(t); c[MX["RequestId"]] = reqId; c[MX["MapiRequestId"]] = G(r).ToString("D"); c[MX["ClientRequestId"]] = "R:{" + G(r).ToString("D").ToUpperInvariant() + "}:1;RT:" + type;
            c[MX["RequestType"]] = type; c[MX["HttpStatusCode"]] = "200"; c[MX["ResponseCode"]] = "0"; c[MX["StatusCode"]] = r.NextDouble() < 0.01 ? "2147746063" : "0"; c[MX["ReturnCode"]] = "0";
            c[MX["TotalRequestLatency"]] = ms.ToString(Inv); c[MX["DeploymentRing"]] = "Production"; c[MX["MajorVersion"]] = "15"; c[MX["MinorVersion"]] = "2"; c[MX["BuildVersion"]] = "1544"; c[MX["RevisionVersion"]] = "4";
            c[MX["AuthenticatedUserEmail"]] = Smtp(u); c[MX["UPN"]] = Smtp(u); c[MX["MailboxId"]] = ui.MailboxGuid + "@" + _o.Domain; c[MX["MDBGuid"]] = G(r).ToString("D");
            c[MX["ClientIP"]] = ui.Ip; c[MX["SourceCafeServer"]] = cafe.ToUpperInvariant() + "." + _o.Domain.ToUpperInvariant(); c[MX["SessionCookie"]] = "MAPIAAAAA" + G(r).ToString("N").Substring(0, 12);
            c[MX["SequenceCookie"]] = "MAPIAAAAA" + G(r).ToString("N").Substring(0, 16); c[MX["MapiClientInfo"]] = ui.Instance + ":1"; c[MX["ClientSoftware"]] = "OUTLOOK.EXE";
            c[MX["ClientSoftwareVersion"]] = "16.0.17928.20114"; c[MX["ClientMode"]] = "Cached"; c[MX["AuthenticationType"]] = "Negotiate"; c[MX["AuthModuleLatency"]] = "0";
            c[MX["AuthenticatedUser"]] = "Anonymous";
            c[MX["RopIds"]] = "2|7|18|19|24|25|51|52|66|72|95|97|104|106|107|108|109|126";
            c[MX["OperationSpecific"]] = type == "Connect" ? "Flags=None;CN=" + Account(u) + ";" : "RopCount=" + r.Next(1, 40).ToString(Inv) + ";";
            c[MX["GenericInfo"]] = "RpcLatency=" + r.Next(1, 30).ToString(Inv) + ";RopLatencies=" + r.Next(1, 30).ToString(Inv) + ";MbxConcurrentRequests=1;ActivityContextLifeTime=" + ms.ToString(Inv) +
                ";BudgetUsed=0;RateLimitDelay=0;Dbl:WLM.TS=" + (r.NextDouble() * 10).ToString("0.000", Inv) + ";I32:ADS.C[" + _o.NetBios + "DC1]=1;F:ADS.AL[" + _o.NetBios + "DC1]=0.6;Dbl:BudgUse.T[]=" +
                (r.NextDouble() * 50).ToString("0.000", Inv) + ";I32:ATE.C[" + _o.NetBios + "DC1.contoso.com]=2;F:ATE.AL[" + _o.NetBios + "DC1." + _o.Domain + "]=0;I32:MB.C=" + r.Next(1, 20).ToString(Inv) + ";";
            return Join(c);
        }

        void MapiBackEnd(int s, int h, DateTime hour, List<Line> real)
        {
            var r = Rng(s, h, 2);
            long h0 = new DateTimeOffset(hour).ToUnixTimeMilliseconds();
            var lines = new List<Line>(real);
            int noise = Count(r, Volume(MapiBeNoisePerDay, 1.0 / 24));
            for (int i = 0; i < noise; i++)
            {
                long t = h0 + (long)(r.NextDouble() * 3600000);
                var c = _mx;
                Array.Clear(c, 0, c.Length);
                string health = "HealthMailbox" + (s * 7 + r.Next(0, 6)).ToString("x2", Inv) + "c3d1e2f4a5b6c7d8e9f0a1b2c3d4e5f6a@" + _o.Domain;
                c[MX["DateTime"]] = Iso(t); c[MX["RequestId"]] = G(r).ToString("D"); c[MX["RequestType"]] = r.NextDouble() < 0.5 ? "Execute" : "Connect"; c[MX["HttpStatusCode"]] = "200";
                c[MX["ResponseCode"]] = "0"; c[MX["StatusCode"]] = "0"; c[MX["ReturnCode"]] = "0"; c[MX["TotalRequestLatency"]] = r.Next(5, 80).ToString(Inv);
                c[MX["AuthenticatedUserEmail"]] = health; c[MX["MailboxId"]] = G(r).ToString("D") + "@" + _o.Domain; c[MX["ClientIP"]] = ServerIp(s);
                c[MX["SourceCafeServer"]] = Fqdn(s).ToUpperInvariant(); c[MX["MapiClientInfo"]] = "{" + G(r).ToString("D").ToUpperInvariant() + "}:1";
                c[MX["ClientSoftware"]] = "Microsoft.Exchange.RpcClientAccess.Monitoring.dll"; c[MX["ClientSoftwareVersion"]] = "15.2.1544.4"; c[MX["ClientMode"]] = "Online";
                c[MX["AuthenticatedUser"]] = "Anonymous"; c[MX["GenericInfo"]] = "RpcLatency=1;RopLatencies=1;MbxConcurrentRequests=1;BudgetUsed=0;RateLimitDelay=0;";
                lines.Add(new Line(t, Join(c)));
            }
            lines.Sort((a, b) => a.T.CompareTo(b.T));
            string folder = System.IO.Path.Combine(ExchangeRoot(s), "Logging", "MapiHttp", "Mailbox");
            string stamp = hour.ToString("yyyyMMddHH", Inv);
            Append(s, "MAPI back end", "hour|" + s + "|mapibe", n => System.IO.Path.Combine(folder, "MapiHttp_" + stamp + "-" + n.ToString(Inv) + ".LOG"),
                new[] { "#Software: Microsoft Exchange Server", "#Version: 15.02.1544.004", "#Log-type: MapiHttp Logs", "#Date: " + Iso(h0), "#Fields: " + MapiFields, MapiFields }, lines, 10L << 20);
        }

        void IisBackEnd(int s, int h, DateTime hour, List<Line> eas)
        {
            var r = Rng(s, h, 3);
            long h0 = new DateTimeOffset(hour).ToUnixTimeMilliseconds();
            var lines = new List<Line>(eas);
            int noise = Count(r, Volume(BackEndIisPerDay, 1.0 / 24));
            string[] stems = { "/mapi/emsmdb/", "/EWS/Exchange.asmx", "/Autodiscover/Autodiscover.xml", "/owa/service.svc", "/PowerShell/", "/mapi/nspi/" };
            for (int i = 0; i < noise; i++)
            {
                long t = h0 + (long)(r.NextDouble() * 3600000);
                var ui = Info(PickUser(r));
                bool probe = r.NextDouble() < 0.4;
                lines.Add(new Line(t, IisLine(t, ServerIp(s), "POST", stems[r.Next(stems.Length)], "&CorrelationID=<empty>;&ClientId=" + G(r).ToString("N").ToUpperInvariant() + "&cafeReqId=" + G(r).ToString("D") + ";",
                    probe ? "HealthMailbox0123456789abcdef@" + _o.Domain : Account(PickUser(r)), ServerIp(r.Next(_servers.Length)), probe ? "AMProbe/Local/ClientAccess" : ui.Agent, 200, 0, 0, r.Next(3, 200))));
            }
            lines.Sort((a, b) => a.T.CompareTo(b.T));
            string iisDay = hour.ToString("yyMMdd", Inv);
            string w3 = System.IO.Path.Combine(IisRoot(s), "W3SVC2");
            Append(s, "IIS back end", "day|" + s + "|w3svc2", n => System.IO.Path.Combine(w3, "u_ex" + iisDay + (n > 1 ? "_x" + n.ToString(Inv) : "") + ".log"),
                new[] { "#Software: Microsoft Internet Information Services 10.0", "#Version: 1.0", "#Date: " + W3c(h0), "#Fields: " + IisFields }, lines, 0);
        }

        // ------------------------------------------------------------------ SMTP protocol logs (front end)

        string MessageId(Random r) { return "<" + G(r).ToString("N").Substring(0, 24).ToUpperInvariant() + "@" + (r.NextDouble() < 0.6 ? _o.Domain : "mail.partner" + r.Next(1, 300).ToString(Inv) + ".example") + ">"; }

        string Subject(Random r)
        {
            int n = r.Next(2, 7);
            var parts = new string[n];
            for (int i = 0; i < n; i++) parts[i] = _words[r.Next(_words.Length)];
            string s = string.Join(" ", parts);
            return char.ToUpperInvariant(s[0]) + s.Substring(1);
        }

        string External(Random r) { return "contact" + r.Next(1, 5000).ToString(Inv) + "@partner" + r.Next(1, 300).ToString(Inv) + ".example"; }

        void SmtpReceive(int s, int h, DateTime hour)
        {
            var r = Rng(s, h, 4);
            long h0 = new DateTimeOffset(hour).ToUnixTimeMilliseconds();
            var lines = new List<Line>();
            string me = _servers[s], fqdn = Fqdn(s).ToUpperInvariant(), local = ServerIp(s) + ":25";
            string conn = me + "\\Default Frontend " + me;
            int sessions = Idle(s) ? 0 : Residual(s) ? Count(r, ResidualSmtpPerDay * Weight(hour)) : Count(r, Volume(SmtpInSessionsPerDay, Weight(hour)));
            long sid = ((long)s << 40) + ((long)h << 20);
            for (int i = 0; i < sessions; i++)
            {
                long t = h0 + (long)(r.NextDouble() * 3590000);
                string id = (0x08DE000000000000L + sid++).ToString("X16", Inv);
                bool scanner = Residual(s);
                bool partner = !scanner && r.NextDouble() < 0.55;
                string remoteIp = scanner ? ScannerIp : partner ? "198.51." + r.Next(0, 99).ToString(Inv) + "." + r.Next(2, 250).ToString(Inv) : "10.30." + r.Next(0, 9).ToString(Inv) + "." + r.Next(2, 250).ToString(Inv);
                string remote = remoteIp + ":" + r.Next(20000, 65000).ToString(Inv);
                string helo = scanner ? ScannerHelo + "." + _o.Domain : partner ? "mail.partner" + r.Next(1, 300).ToString(Inv) + ".example" : "app" + r.Next(1, 40).ToString("D2", Inv) + "." + _o.Domain;
                int seq = 0;
                Action<string, string, string> add = (e, data, ctx) =>
                {
                    lines.Add(new Line(t, Iso(t) + "," + Csv(conn) + "," + id + "," + (seq++).ToString(Inv) + "," + local + "," + remote + "," + e + "," + Csv(data) + "," + Csv(ctx)));
                    t += r.Next(0, 40);
                };
                add("+", "", "");
                add("*", "SMTPSubmit SMTPAcceptAnyRecipient SMTPAcceptAnySender SMTPAcceptAuthoritativeDomainSender AcceptRoutingHeaders", "Set Session Permissions");
                add(">", "220 " + fqdn + " Microsoft ESMTP MAIL Service ready at " + DateTimeOffset.FromUnixTimeMilliseconds(t).UtcDateTime.ToString("ddd, d MMM yyyy HH:mm:ss", Inv) + " +0000", "");
                add("<", "EHLO " + helo, "");
                add(">", "250  " + fqdn + " Hello [" + remoteIp + "] SIZE 37748736 PIPELINING DSN ENHANCEDSTATUSCODES STARTTLS X-ANONYMOUSTLS AUTH NTLM X-EXPS GSSAPI NTLM 8BITMIME BINARYMIME CHUNKING SMTPUTF8 XRDST", "");
                bool tls = !scanner && r.NextDouble() < 0.8;
                if (tls)
                {
                    add("<", "STARTTLS", "");
                    add(">", "220 2.0.0 SMTP server ready", "");
                    add("*", "", "Sending certificate");
                    add("*", "CN=mail." + _o.Domain, "Certificate subject");
                    add("*", "", "TLS protocol SP_PROT_TLS1_2_SERVER negotiation succeeded using bulk encryption algorithm CALG_AES_256 with strength 256 bits, MAC hash algorithm CALG_SHA_384 with strength 384 bits and key exchange algorithm CALG_ECDH_EPHEM with strength 384 bits");
                    add("<", "EHLO " + helo, "");
                    add(">", "250  " + fqdn + " Hello [" + remoteIp + "] SIZE 37748736 PIPELINING DSN ENHANCEDSTATUSCODES AUTH NTLM LOGIN X-EXPS GSSAPI NTLM 8BITMIME BINARYMIME CHUNKING SMTPUTF8 XRDST", "");
                }
                int messages = r.NextDouble() < 0.85 ? 1 : 2;
                for (int m = 0; m < messages; m++)
                {
                    string from = scanner ? ScannerFrom + "@" + _o.Domain : partner ? External(r) : "noreply-app" + r.Next(1, 40).ToString(Inv) + "@" + _o.Domain;
                    add("<", "MAIL FROM:<" + from + "> SIZE=" + r.Next(2000, 900000).ToString(Inv), "");
                    add("*", G(r).ToString("D") + ";" + Iso(t) + ";1", "receiving message");
                    add(">", "250 2.1.0 Sender OK", "");
                    int rcpts = r.NextDouble() < 0.8 ? 1 : r.Next(2, 6);
                    bool unknown = r.NextDouble() < 0.03;
                    for (int k = 0; k < rcpts; k++)
                    {
                        add("<", "RCPT TO:<" + (unknown && k == 0 ? "nobody" + r.Next(1, 999).ToString(Inv) : UserName(PickUser(r))) + "@" + _o.Domain + ">", "");
                        add(">", unknown && k == 0 ? "550 5.1.10 RESOLVER.ADR.RecipientNotFound; Recipient not found by SMTP address lookup" : "250 2.1.5 Recipient OK", "");
                    }
                    if (unknown && rcpts == 1) { add("<", "RSET", ""); add(">", "250 2.0.0 Resetting", ""); continue; }
                    add("<", "BDAT " + r.Next(2000, 900000).ToString(Inv) + " LAST", "");
                    add("*", "", "Proxy destination(s) obtained from OnProxyInboundMessage event");
                    add(">", "250 2.6.0 " + MessageId(r) + " [InternalId=" + r.Next(100000, 999999999).ToString(Inv) + ", Hostname=" + fqdn + "] " + r.Next(2000, 900000).ToString(Inv) + " bytes in " + (r.NextDouble()).ToString("0.000", Inv) + ", " + (r.NextDouble() * 900).ToString("0.000", Inv) + " KB/sec Queued mail for delivery", "");
                }
                add("<", "QUIT", "");
                add(">", "221 2.0.0 Service closing transmission channel", "");
                add("-", "", "Local");
            }
            // Load balancer probes: connection, banner, disconnection.
            int probes = Count(r, Volume(SmtpInProbesPerDay, 1.0 / 24));
            for (int i = 0; i < probes; i++)
            {
                long t = h0 + (long)(r.NextDouble() * 3590000);
                string id = (0x08DE000000000000L + sid++).ToString("X16", Inv);
                string remote = "10.20.0.5:" + r.Next(20000, 65000).ToString(Inv);
                lines.Add(new Line(t, Iso(t) + "," + Csv(conn) + "," + id + ",0," + local + "," + remote + ",+,,"));
                lines.Add(new Line(t, Iso(t) + "," + Csv(conn) + "," + id + ",1," + local + "," + remote + ",*,SMTPSubmit SMTPAcceptAnyRecipient,Set Session Permissions"));
                lines.Add(new Line(t + 1, Iso(t + 1) + "," + Csv(conn) + "," + id + ",2," + local + "," + remote + ",>,\"220 " + fqdn + " Microsoft ESMTP MAIL Service ready\","));
                lines.Add(new Line(t + 2, Iso(t + 2) + "," + Csv(conn) + "," + id + ",3," + local + "," + remote + ",-,,Remote(SocketError)"));
            }
            lines.Sort((a, b) => a.T.CompareTo(b.T));
            string folder = System.IO.Path.Combine(ExchangeRoot(s), "TransportRoles", "Logs", "FrontEnd", "ProtocolLog", "SmtpReceive");
            string day = hour.ToString("yyyyMMdd", Inv);
            Append(s, "SMTP in (FrontEnd)", "day|" + s + "|recv", n => System.IO.Path.Combine(folder, "RECV" + day + (hour.Hour).ToString("D2", Inv) + "-" + n.ToString(Inv) + ".LOG"),
                new[] { "#Software: Microsoft Exchange Server", "#Version: 15.0.0.0", "#Log-type: SMTP Receive Protocol Log", "#Date: " + Iso(h0), "#Fields: " + SmtpFields }, lines, 10L << 20);
        }

        void SmtpSend(int s, int h, DateTime hour)
        {
            var r = Rng(s, h, 5);
            long h0 = new DateTimeOffset(hour).ToUnixTimeMilliseconds();
            var lines = new List<Line>();
            string me = _servers[s], fqdn = Fqdn(s).ToUpperInvariant();
            int sessions = Idle(s) ? 0 : Residual(s) ? Count(r, ResidualSmtpPerDay * Weight(hour)) : Count(r, Volume(SmtpOutSessionsPerDay, Weight(hour)));
            long sid = ((long)s << 40) + ((long)h << 20) + 500000;
            for (int i = 0; i < sessions; i++)
            {
                long t = h0 + (long)(r.NextDouble() * 3590000);
                string id = (0x08DE000000000000L + sid++).ToString("X16", Inv);
                int target = r.Next(ActiveServers);
                string remote = ServerIp(target) + ":2525", local = ServerIp(s) + ":" + r.Next(20000, 65000).ToString(Inv);
                int seq = 0;
                Action<string, string, string> add = (e, data, ctx) =>
                {
                    lines.Add(new Line(t, Iso(t) + ",Inbound Proxy Internal Send Connector," + id + "," + (seq++).ToString(Inv) + "," + local + "," + remote + "," + e + "," + Csv(data) + "," + Csv(ctx)));
                    t += r.Next(0, 30);
                };
                add("+", "", "");
                add("<", "220 " + Fqdn(target).ToUpperInvariant() + " Microsoft ESMTP MAIL Service ready", "");
                add(">", "EHLO " + fqdn, "");
                add("<", "250  " + Fqdn(target).ToUpperInvariant() + " Hello [" + ServerIp(s) + "] SIZE PIPELINING DSN ENHANCEDSTATUSCODES STARTTLS X-ANONYMOUSTLS AUTH NTLM X-EXPS GSSAPI NTLM 8BITMIME BINARYMIME CHUNKING XEXCH50 XRDST XSHADOWREQUEST XPROXY XPROXYFROM XSYSPROBE XSESSIONPARAMS", "");
                add(">", "X-EXPS GSSAPI", "");
                add("<", "235 <authentication response>", "");
                add("*", "", "Client certificate chain validation succeeded");
                int messages = r.NextDouble() < 0.7 ? 1 : r.Next(2, 4);
                for (int m = 0; m < messages; m++)
                {
                    string mid = MessageId(r);
                    add("*", "", "sending message with RecordId " + r.Next(100000, 99999999).ToString(Inv) + " and InternetMessageId " + mid);
                    add(">", "XPROXYFROM SID=" + (0x08DE000000000000L + r.Next()).ToString("X16", Inv) + " IP=198.51.100." + r.Next(2, 250).ToString(Inv) + " PORT=" + r.Next(20000, 65000).ToString(Inv) + " DOMAIN=mail.partner.example SEQNUM=1 PERMS=0 AUTHSRC=Anonymous", "");
                    add(">", "MAIL FROM:<" + External(r) + "> SIZE=" + r.Next(2000, 900000).ToString(Inv), "");
                    add("<", "250 2.1.0 Sender OK", "");
                    int rcpts = r.NextDouble() < 0.8 ? 1 : r.Next(2, 6);
                    for (int k = 0; k < rcpts; k++) { add(">", "RCPT TO:<" + Smtp(PickUser(r)) + ">", ""); add("<", "250 2.1.5 Recipient OK", ""); }
                    add(">", "BDAT " + r.Next(2000, 900000).ToString(Inv) + " LAST", "");
                    add("<", "250 2.6.0 " + mid + " [InternalId=" + r.Next(100000, 999999999).ToString(Inv) + ", Hostname=" + Fqdn(target).ToUpperInvariant() + "] Queued mail for delivery", "");
                }
                add(">", "QUIT", "");
                add("<", "221 2.0.0 Service closing transmission channel", "");
                add("-", "", "Local");
            }
            lines.Sort((a, b) => a.T.CompareTo(b.T));
            string folder = System.IO.Path.Combine(ExchangeRoot(s), "TransportRoles", "Logs", "FrontEnd", "ProtocolLog", "SmtpSend");
            string day = hour.ToString("yyyyMMdd", Inv);
            Append(s, "SMTP out (FrontEnd)", "day|" + s + "|send", n => System.IO.Path.Combine(folder, "SEND" + day + (hour.Hour).ToString("D2", Inv) + "-" + n.ToString(Inv) + ".LOG"),
                new[] { "#Software: Microsoft Exchange Server", "#Version: 15.0.0.0", "#Log-type: SMTP Send Protocol Log", "#Date: " + Iso(h0), "#Fields: " + SmtpFields }, lines, 10L << 20);
        }

        // ------------------------------------------------------------------ message tracking

        string Tracking(Random r, long t, string evt, string source, string messageId, string internalId, string network, string rcpts, string status, int size, int count,
            string subject, string sender, string clientIp, string clientHost, string serverIp, string serverHost, string connector, string sourceContext, string info, string direction, string custom)
        {
            var c = new string[30];
            c[0] = Iso(t); c[1] = clientIp; c[2] = clientHost; c[3] = serverIp; c[4] = serverHost; c[5] = sourceContext; c[6] = connector; c[7] = source; c[8] = evt; c[9] = internalId;
            c[10] = messageId; c[11] = network; c[12] = rcpts; c[13] = status; c[14] = size.ToString(Inv); c[15] = count.ToString(Inv); c[18] = subject; c[19] = sender; c[20] = sender;
            c[21] = info; c[22] = direction; c[23] = "";  c[26] = custom; c[27] = "Email"; c[28] = G(r).ToString("D"); c[29] = "15.02.1544.004";
            return Join(c);
        }

        void Tracking(int s, int h, DateTime hour)
        {
            var r = Rng(s, h, 6);
            long h0 = new DateTimeOffset(hour).ToUnixTimeMilliseconds();
            var hub = new List<Line>();
            var delivery = new List<Line>();
            var submission = new List<Line>();
            string me = _servers[s], fqdn = Fqdn(s).ToUpperInvariant(), ip = ServerIp(s);
            int messages = Idle(s) ? 0 : Residual(s) ? Count(r, ResidualSmtpPerDay * Weight(hour)) : Count(r, Volume(MessagesPerDay, Weight(hour)));
            for (int i = 0; i < messages; i++)
            {
                long t = h0 + (long)(r.NextDouble() * 3500000);
                string mid = MessageId(r), net = G(r).ToString("D"), iid = r.Next(100000, 999999999).ToString(Inv);
                bool outbound = !Residual(s) && r.NextDouble() < 0.35;
                int sender = PickUser(r);
                string from = Residual(s) ? ScannerFrom + "@" + _o.Domain : outbound ? Smtp(sender) : External(r);
                int n = r.NextDouble() < 0.82 ? 1 : r.NextDouble() < 0.9 ? r.Next(2, 6) : r.Next(20, 120);
                var rc = new List<string>();
                for (int k = 0; k < n; k++) rc.Add(outbound && r.NextDouble() < 0.5 ? External(r) : Smtp(PickUser(r)));
                string rcpts = string.Join(";", rc.Distinct());
                string subject = Subject(r);
                int size = r.Next(3000, 2000000);
                string ctx = "08DE" + G(r).ToString("N").Substring(0, 12).ToUpperInvariant() + ";" + Iso(t) + ";0";
                string custom = "S:ProxiedClientIPAddress=" + (outbound ? Info(sender).Ip : "198.51.100." + r.Next(2, 250).ToString(Inv)) + ";S:ProxiedClientHostname=mail.partner.example;" +
                    "S:DeliveryPriority=Normal;S:AccountForest=" + _o.Domain + ";S:FirstForestHop=" + fqdn + ";S:InboundTrustEnabled=False;S:IsSmtpResponseFromExternalServer=False";
                string info = Iso(t - 800) + ";SRV=" + fqdn + ":TOTAL-FE=0.0" + r.Next(10, 99).ToString(Inv) + "|SMR=0.0" + r.Next(10, 99).ToString(Inv) + "(SMRDE=0.000|SMRC=0.0" + r.Next(10, 99).ToString(Inv) + ")|SMS=0.00" + r.Next(1, 9).ToString(Inv);
                string direction = outbound ? "Originating" : "Incoming";
                string src = outbound ? "STOREDRIVER" : "SMTP";
                if (outbound)
                {
                    submission.Add(new Line(t - 400, Tracking(r, t - 400, "SUBMIT", "STOREDRIVER", mid, iid, net, rcpts, "", size, rc.Count, subject, from, null, fqdn, null, null, null,
                        "MDB:" + G(r).ToString("D") + ", Mailbox:" + G(r).ToString("D") + ", Event:" + r.Next(1000, 999999).ToString(Inv) + ", MessageClass:IPM.Note, CreationTime:" + Iso(t - 900) + ", ClientType:MOMT, SubmissionAssistant:MailboxTransportSubmissionEmailAssistant",
                        null, direction, null)));
                }
                hub.Add(new Line(t, Tracking(r, t, "RECEIVE", src, mid, iid, net, rcpts, "", size, rc.Count, subject, from, outbound ? ip : "198.51.100." + r.Next(2, 250).ToString(Inv),
                    outbound ? fqdn : "mail.partner.example", ip, fqdn, outbound ? null : me + "\\Default " + me, ctx, info, direction, custom)));
                hub.Add(new Line(t + 5, Tracking(r, t + 5, "AGENTINFO", "AGENT", mid, iid, net, rcpts, "", size, rc.Count, subject, from, null, null, ip, fqdn, null, "Transport Rule Agent", null, direction,
                    "S:CompCost=|ETR=0;S:DeliveryPriority=Normal;S:AccountForest=" + _o.Domain + ";S:AMA=SUM|v=0|action=|error=|atch=0;S:TRA=ETRP|ruleId=" + G(r).ToString("D") + "|ExecW=0|ExecC=0|ExecT=0;S:DPA=DPAP|DPAPolicy=None")));
                if (r.NextDouble() < 0.7) hub.Add(new Line(t + 6, Tracking(r, t + 6, "HARECEIVE", "SMTP", mid, iid, net, rcpts, "", size, rc.Count, subject, from, ServerIp((s + 1) % ActiveServers), Fqdn((s + 1) % ActiveServers), ip, fqdn, null, ctx, null, direction, null)));
                if (n >= 20) hub.Add(new Line(t + 8, Tracking(r, t + 8, "EXPAND", "ROUTING", mid, iid, net, rcpts, "", size, rc.Count, subject, from, null, null, ip, fqdn, null, null, null, direction, null)));
                double fate = r.NextDouble();
                if (fate < 0.01) hub.Add(new Line(t + 30, Tracking(r, t + 30, "FAIL", "ROUTING", mid, iid, net, rc[0], "550 5.1.1 RESOLVER.ADR.ExRecipNotFound; not found", size, 1, subject, from, null, null, ip, fqdn, null, null, null, direction, null)));
                else if (fate < 0.03) hub.Add(new Line(t + 30, Tracking(r, t + 30, "DEFER", "SMTP", mid, iid, net, rcpts, "451 4.4.0 Primary target IP address responded with: 421 4.4.2 Connection dropped", size, rc.Count, subject, from, null, null, ip, fqdn, null, null, null, direction, null)));
                long td = t + r.Next(200, 5000);
                var internalRcpts = rc.Where(x => x.EndsWith("@" + _o.Domain, StringComparison.Ordinal)).Distinct().ToList();
                var externalRcpts = rc.Where(x => !x.EndsWith("@" + _o.Domain, StringComparison.Ordinal)).Distinct().ToList();
                if (externalRcpts.Count > 0)
                    hub.Add(new Line(td, Tracking(r, td, "SEND", "SMTP", mid, iid, net, string.Join(";", externalRcpts), "250 2.6.0 Queued mail for delivery", size, externalRcpts.Count, subject, from, ip, fqdn, "203.0.113.25", "edge01." + _o.Domain,
                        "Outbound to Internet", ctx, info, direction, null)));
                if (internalRcpts.Count > 0)
                {
                    delivery.Add(new Line(td, Tracking(r, td, "DELIVER", "STOREDRIVER", mid, iid, net, string.Join(";", internalRcpts), "250 2.0.0 Delivered", size, internalRcpts.Count, subject, from, ip, fqdn, ip, fqdn, null,
                        "MDB:" + G(r).ToString("D") + ", Mailbox:" + G(r).ToString("D") + ", Event:" + r.Next(1000, 999999).ToString(Inv) + ", MessageClass:IPM.Note, CreationTime:" + Iso(t) + ", ClientType:User",
                        Iso(t - 800) + ";" + Iso(td) + ";SRV=" + fqdn + ":TOTAL-DEL=0.0" + r.Next(10, 99).ToString(Inv) + "|DEL=0.0" + r.Next(10, 99).ToString(Inv), direction,
                        "S:Mailboxes=" + string.Join(";", Enumerable.Range(0, Math.Min(internalRcpts.Count, 3)).Select(_ => G(r).ToString("D"))) + ";S:StoreObjectIds=AAAAAH" + G(r).ToString("N") + ";S:DeliveryPriority=Normal")));
                }
                if (r.NextDouble() < 0.5) hub.Add(new Line(td + 20, Tracking(r, td + 20, "HADISCARD", "SMTP", mid, iid, net, rcpts, "", size, rc.Count, subject, from, null, null, ip, fqdn, null, null, null, direction, null)));
            }
            int probes = Count(r, Volume(ProbeMessagesPerDay, 1.0 / 24));
            for (int i = 0; i < probes; i++)
            {
                long t = h0 + (long)(r.NextDouble() * 3500000);
                string mid = "<" + G(r).ToString("D") + "@" + fqdn.ToLowerInvariant() + ">", net = G(r).ToString("D"), iid = r.Next(100000, 999999999).ToString(Inv);
                string health = "HealthMailbox" + (s * 7 + r.Next(0, 6)).ToString("x2", Inv) + "c3d1e2f4a5b6c7d8e9f0a1b2c3d4e5f6a@" + _o.Domain;
                string probe = "Probe-" + G(r).ToString("N").Substring(0, 8);
                hub.Add(new Line(t, Tracking(r, t, "RECEIVE", "SMTP", mid, iid, net, health, "", 4000, 1, probe, health, ip, fqdn, ip, fqdn, me + "\\Default " + me, "08DE;" + Iso(t) + ";0", null, "Originating", null)));
                delivery.Add(new Line(t + 300, Tracking(r, t + 300, "DELIVER", "STOREDRIVER", mid, iid, net, health, "250 2.0.0 Delivered", 4000, 1, probe, health, ip, fqdn, ip, fqdn, null, null, null, "Originating", null)));
            }
            string stamp = hour.ToString("yyyyMMddHH", Inv);
            string folder = System.IO.Path.Combine(ExchangeRoot(s), "TransportRoles", "Logs", "MessageTracking");
            var header = new[] { "#Software: Microsoft Exchange Server", "#Version: 15.02.1544.004", "#Log-type: Message Tracking Log", "#Date: " + Iso(h0), "#Fields: " + TrackingFields };
            hub.Sort((a, b) => a.T.CompareTo(b.T));
            delivery.Sort((a, b) => a.T.CompareTo(b.T));
            submission.Sort((a, b) => a.T.CompareTo(b.T));
            Append(s, "Tracking", "hour|" + s + "|trk", n => System.IO.Path.Combine(folder, "MSGTRK" + stamp + "-" + n.ToString(Inv) + ".LOG"), header, hub, 10L << 20);
            Append(s, "Tracking", "hour|" + s + "|trkmd", n => System.IO.Path.Combine(folder, "MSGTRKMD" + stamp + "-" + n.ToString(Inv) + ".LOG"), header, delivery, 10L << 20);
            string day = hour.ToString("yyyyMMdd", Inv);
            Append(s, "Tracking", "day|" + s + "|trkms", n => System.IO.Path.Combine(folder, "MSGTRKMS" + day + "00-" + n.ToString(Inv) + ".LOG"), header, submission, 10L << 20);
        }
    }
}
'@
}

$names = @($Server | ForEach-Object { $_.ToUpperInvariant() })
$o = [ExlSim.Options]::new()
$o.Root = [IO.Path]::GetFullPath($Path)
$o.Servers = [string[]]$names
$o.Only = [string[]]@($Only | Where-Object { $_ } | ForEach-Object { $_.ToUpperInvariant() })
foreach ($n in $o.Only) { if ($n -notin $names) { throw "-Only $n is not in -Server ($($names -join ', '))." } }
$o.Days = $Days; $o.Scale = $Scale; $o.Users = $Users; $o.Seed = $Seed; $o.Profile = $Profile
if ($Profile -eq 'Decommission' -and $names.Count -lt 3) { throw '-Profile Decommission needs 3 servers or more (the last one idle, the one before it residual).' }
$o.EndUtc = if ($PSBoundParameters.ContainsKey('End')) { $End.ToUniversalTime() } else { [DateTime]::UtcNow.AddHours(-1) }
$generator = [ExlSim.Generator]::new($o)
$clock = [Diagnostics.Stopwatch]::StartNew()
$generator.Progress = [Action[string]] { param($m) Write-Host "  $m  $([int]$clock.Elapsed.TotalSeconds) s" }
Write-Host "Writing $Days day(s) of synthetic Exchange logs for $($names -join ', ') (scale $Scale, profile $Profile) into $($o.Root)"
$stats = $generator.Run()
$stats | Select-Object Server, Kind, Files, @{ n = 'Lines'; e = { '{0:N0}' -f $_.Lines } }, @{ n = 'MB'; e = { '{0:N0}' -f ($_.Bytes / 1MB) } }, @{ n = 'Bytes/line'; e = { if ($_.Lines) { [int]($_.Bytes / $_.Lines) } } } | Format-Table -AutoSize | Out-Host
Write-Host ('{0:N1} GB in {1:N0} s' -f (($stats | Measure-Object Bytes -Sum).Sum / 1GB), $clock.Elapsed.TotalSeconds)
