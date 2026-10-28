using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    public sealed class ServeOptions
    {
        public string DatabasePath { get; set; }
        public string WebRoot { get; set; }
        public int Port { get; set; } = 8765;
        public bool NoBrowser { get; set; }
        public string ReadyFile { get; set; }
        public bool ReadyFileWithToken { get; set; }
        public int RequestTimeoutSeconds { get; set; } = 15;
        public int MmapMB { get; set; }
        public int MaxConcurrency { get; set; } = 4;
    }

    public static class ServeHost
    {
        public static void Run(ServeOptions options) { RunAsync(options, CancellationToken.None).GetAwaiter().GetResult(); }
        public static Task RunAsync(ServeOptions options) { return RunAsync(options, CancellationToken.None); }
        public static async Task RunAsync(ServeOptions options, CancellationToken cancellationToken)
        {
            if (options == null) throw new ArgumentNullException(nameof(options));
            if (options.Port < 0 || options.Port > 65535 || options.RequestTimeoutSeconds < 1 || options.RequestTimeoutSeconds > 120 ||
                options.MmapMB < 0 || options.MmapMB > 256 || options.MaxConcurrency < 1 || options.MaxConcurrency > 8)
                throw new ArgumentOutOfRangeException(nameof(options), "Port 0..65535, timeout 1..120s, mmap 0..256 MB, concurrency 1..8.");
            options.DatabasePath = Path.GetFullPath(options.DatabasePath);
            options.WebRoot = Path.GetFullPath(options.WebRoot);
            CheckPath(options.WebRoot, options.WebRoot);
            if (!File.Exists(Path.Combine(options.WebRoot, "index.html"))) throw new FileNotFoundException("Compiled web\\index.html is required; Serve does not build it.");
            CheckPath(options.WebRoot, Path.Combine(options.WebRoot, "index.html"));
            if (options.ReadyFile != null && File.Exists(options.ReadyFile)) throw new IOException("Ready file exists; refusing to overwrite it.");
            int port = options.Port;
            if (port == 0)
            {
                var probe = new TcpListener(IPAddress.Loopback, 0);
                try { probe.Start(); port = ((IPEndPoint)probe.LocalEndpoint).Port; } finally { probe.Stop(); }
            }
            string origin = "http://127.0.0.1" + (port == 80 ? "" : ":" + port.ToString(CultureInfo.InvariantCulture));
            byte[] tokenBytes = RandomNumberGenerator.GetBytes(32);
            string token = Convert.ToHexString(tokenBytes).ToLowerInvariant();
            string url = origin + "/#token=" + token;
            string policy = ContentSecurity(File.ReadAllText(Path.Combine(options.WebRoot, "index.html")));
            using (var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            using (var listener = new HttpListener())
            using (var slots = new SemaphoreSlim(options.MaxConcurrency))
            {
                listener.Prefixes.Add(origin + "/");
                try { listener.Start(); }
                catch (HttpListenerException error)
                {
                    string message = "HttpListener could not bind " + origin +
                        ". Windows HTTP.sys may require an administrator-approved URL ACL for this exact 127.0.0.1 prefix (or another free port). No URL ACL, firewall or service setting was changed. " + error.Message;
                    try
                    {
                        if (options.ReadyFile != null)
                            WriteReady(options.ReadyFile, JsonSerializer.Serialize(new {
                                status = "blocked",
                                code = error.NativeErrorCode == 5 ? "HttpListenerAccessDenied" : "HttpListenerBindFailed",
                                nativeErrorCode = error.NativeErrorCode, message,
                                url = origin + "/", port, mode = "Serve", readOnly = true, processId = Environment.ProcessId }));
                    }
                    finally { CryptographicOperations.ZeroMemory(tokenBytes); }
                    throw new InvalidOperationException(message, error);
                }
                bool readyCreated = false;
                ConsoleCancelEventHandler interrupt = (s,e) => { e.Cancel = true; stop.Cancel(); };
                Console.CancelKeyPress += interrupt;
                var running = new List<Task>();
                using (stop.Token.Register(() => listener.Stop()))
                try
                {
                    if (options.ReadyFile != null)
                    {
                        WriteReady(options.ReadyFile, JsonSerializer.Serialize(new {
                            status = "ready", url = origin + "/", port, mode = "Serve", readOnly = true, processId = Environment.ProcessId,
                            token = options.ReadyFileWithToken ? token : null }));
                        readyCreated = true;
                    }
                    Console.WriteLine("Serve (read-only): " + origin + "/");
                    if (!options.NoBrowser)
                    {
                        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
                        catch { throw new InvalidOperationException("Could not open the browser. Restart with -NoBrowser -ReadyFile <private path> -ReadyFileWithToken for an explicit private automation token. The token was not logged."); }
                    }
                    else if (!options.ReadyFileWithToken || options.ReadyFile == null)
                        Console.WriteLine("Browser suppressed. For authenticated automation, explicitly request a private ReadyFile with ReadyFileWithToken.");
                    while (!stop.IsCancellationRequested)
                    {
                        HttpListenerContext context;
                        try { context = await listener.GetContextAsync().ConfigureAwait(false); }
                        catch (Exception e) when ((e is HttpListenerException || e is ObjectDisposedException) && stop.IsCancellationRequested) { break; }
                        if (!slots.Wait(0))
                        {
                            using var busy = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                            busy.CancelAfter(TimeSpan.FromSeconds(options.RequestTimeoutSeconds));
                            using var abort = busy.Token.Register(() => Abort(context.Response));
                            try
                            {
                                Headers(context.Response, policy);
                                context.Response.Headers["Retry-After"] = "1";
                                await Json(context.Response, 429, new { error = new { code = "Busy", message = "Concurrency limit reached; retry explicitly." } }, busy.Token).ConfigureAwait(false);
                                context.Response.Close();
                            }
                            catch (Exception e) when (e is IOException || e is HttpListenerException || e is ObjectDisposedException || e is OperationCanceledException) { Abort(context.Response); }
                            continue;
                        }
                        running.RemoveAll(t => t.IsCompleted);
                        running.Add(Task.Run(async () => {
                            try { await Handle(context, options, origin, tokenBytes, policy, stop).ConfigureAwait(false); }
                            finally { slots.Release(); }
                        }));
                    }
                }
                finally
                {
                    stop.Cancel(); listener.Stop();
                    try { await Task.WhenAll(running).ConfigureAwait(false); }
                    finally
                    {
                        Console.CancelKeyPress -= interrupt;
                        try { if (readyCreated) File.Delete(options.ReadyFile); }
                        finally { CryptographicOperations.ZeroMemory(tokenBytes); }
                    }
                }
            }
        }

        static void WriteReady(string path, string json)
        {
            var security = new FileSecurity();
            var owner = WindowsIdentity.GetCurrent().User;
            security.SetOwner(owner); security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new FileSystemAccessRule(owner, FileSystemRights.FullControl, AccessControlType.Allow));
            using (var stream = FileSystemAclExtensions.Create(new FileInfo(Path.GetFullPath(path)), FileMode.CreateNew,
                FileSystemRights.FullControl, FileShare.Read, 4096, FileOptions.None, security))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false))) writer.Write(json);
        }

        static void Headers(HttpListenerResponse response, string policy)
        {
            response.Headers["Cache-Control"] = "no-store";
            response.Headers["Pragma"] = "no-cache";
            response.Headers["X-Content-Type-Options"] = "nosniff";
            response.Headers["X-Frame-Options"] = "DENY";
            response.Headers["Referrer-Policy"] = "no-referrer";
            response.Headers["Content-Security-Policy"] = policy;
        }
        static async Task Json(HttpListenerResponse response, int status, object value, CancellationToken cancel)
        {
            byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(value);
            response.StatusCode = status; response.ContentType = "application/json; charset=utf-8";
            response.ContentLength64 = bytes.Length;
            await response.OutputStream.WriteAsync(bytes, 0, bytes.Length, cancel).ConfigureAwait(false);
        }
        static void Abort(HttpListenerResponse response)
        {
            try { response.Abort(); }
            catch (Exception e) when (e is HttpListenerException || e is ObjectDisposedException || e is IOException) { }
        }
        static bool Auth(HttpListenerRequest request, byte[] expected)
        {
            string supplied = request.Headers["X-Portal-Token"];
            if (supplied == null || supplied.Length != 64) return false;
            byte[] actual;
            try { actual = Convert.FromHexString(supplied); } catch (FormatException) { return false; }
            bool ok = CryptographicOperations.FixedTimeEquals(actual, expected);
            CryptographicOperations.ZeroMemory(actual); return ok;
        }
        static void LocalRequest(HttpListenerRequest request, string origin)
        {
            if (request.RemoteEndPoint == null || !IPAddress.IsLoopback(request.RemoteEndPoint.Address) ||
                !string.Equals(request.Headers["Host"], origin.Substring("http://".Length), StringComparison.Ordinal))
                throw new ServeError(403, "LocalOnly", "Only the exact loopback authority is allowed.");
            string supplied = request.Headers["Origin"], site = request.Headers["Sec-Fetch-Site"];
            if ((supplied != null && !string.Equals(supplied, origin, StringComparison.Ordinal)) ||
                (site != null && site != "same-origin" && site != "none"))
                throw new ServeError(403, "OriginDenied", "Cross-origin requests are not allowed.");
            if (request.Url.Query.Length > 4096) throw new ServeError(400, "QueryTooLong", "Query is too long.");
        }
        static readonly string[] BaseParameters = { "from","to","server","user" };
        static readonly string[] ListParameters = { "from","to","server","user","status","page","size" };
        static bool SpaPath(string path)
        {
            return Regex.IsMatch(path, @"^/(?:|overview|messages(?:/[1-9]\d*)?|sessions(?:/[1-9]\d*)?|smtp(?:/clients(?:/[1-9]\d*(?:/transactions)?)?|/transactions(?:/[1-9]\d*)?)?)$", RegexOptions.CultureInvariant);
        }
        static async Task Handle(HttpListenerContext context, ServeOptions options, string origin, byte[] token, string policy, CancellationTokenSource stop)
        {
            var response = context.Response;
            bool streaming = false, shutdown = false;
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token))
            {
                deadline.CancelAfter(TimeSpan.FromSeconds(options.RequestTimeoutSeconds));
                using var abortStream = deadline.Token.Register(() => { if (Volatile.Read(ref streaming)) Abort(response); });
                try
                {
                    Headers(response, policy);
                    var request = context.Request;
                    LocalRequest(request, origin);
                    string path = SafeUrlPath(request.RawUrl);
                    if (!path.StartsWith("/api/", StringComparison.Ordinal))
                    {
                        if (request.HttpMethod != "GET" && request.HttpMethod != "HEAD") throw new ServeError(405, "Method", "GET or HEAD required.");
                        if (request.QueryString.Count != 0)
                        {
                            if (!SpaPath(path)) throw new ServeError(400, "InvalidParameter", "Only known SPA routes accept validated filter parameters.");
                            ServeFilter.Parse(request.QueryString, ListParameters);
                        }
                        await Static(response, request.HttpMethod == "HEAD", options.WebRoot, path, deadline.Token).ConfigureAwait(false);
                        return;
                    }
                    if (!Auth(request, token)) throw new ServeError(401, "Unauthorized", "X-Portal-Token is required.");
                    if (path == "/api/shutdown")
                    {
                        if (request.HttpMethod != "POST" || request.QueryString.Count != 0 || request.HasEntityBody)
                            throw new ServeError(400, "InvalidShutdown", "Use an authenticated empty POST without query parameters.");
                        await Json(response, 200, new { stopped = true }, deadline.Token).ConfigureAwait(false);
                        shutdown = true; return;
                    }
                    if (request.HttpMethod != "GET") throw new ServeError(405, "Method", "GET required.");
                    if (request.HasEntityBody) throw new ServeError(400, "InvalidBody", "GET bodies are not accepted.");
                    bool meta = path == "/api/meta";
                    var filter = ServeFilter.Parse(request.QueryString, meta ? new string[0] :
                        path == "/api/export.csv" ? ListParameters.Concat(new[]{"view"}).Except(new[]{"page","size"}).ToArray() :
                        path == "/api/overview" || path == "/api/overview/counts" ? BaseParameters :
                        Regex.IsMatch(path, @"^/api/smtp/clients/[1-9]\d*$") ? BaseParameters.Concat(new[]{"status"}).ToArray() :
                        Regex.IsMatch(path, @"^/api/(?:messages|sessions|smtp(?:/transactions)?)/[1-9]\d*$") ? BaseParameters : ListParameters);
                    if (meta && !File.Exists(options.DatabasePath))
                    { await Json(response, 200, ServeRead.MissingMeta(), deadline.Token).ConfigureAwait(false); return; }
                    using (var db = new ServeRead(options, deadline.Token))
                    {
                        if (meta) { await Json(response, 200, db.Meta(options), deadline.Token).ConfigureAwait(false); return; }
                        db.Ready();
                        object result;
                        if (path == "/api/overview") result = db.Overview(filter);
                        else if (path == "/api/overview/counts") result = db.OverviewCounts(filter);
                        else if (path == "/api/messages") result = db.Page("messages", filter);
                        else if (path == "/api/sessions") result = db.Page("sessions", filter);
                        else if (path == "/api/smtp/clients") result = db.Page("smtpclients", filter);
                        else if (path == "/api/smtp/transactions") result = db.Page("smtp", filter);
                        else if (Regex.IsMatch(path, @"^/api/smtp/clients/[1-9]\d*/transactions$"))
                        {
                            var match = Regex.Match(path, @"^/api/smtp/clients/(?<id>[1-9]\d*)/transactions$");
                            long id;
                            if (!long.TryParse(match.Groups["id"].Value, NumberStyles.None, CultureInfo.InvariantCulture, out id))
                                throw new ServeError(404, "NotFound", "SMTP client not found.");
                            result = db.ClientTransactions(id, filter);
                        }
                        else if (path == "/api/export.csv")
                        {
                            if (filter.View != "messages" && filter.View != "sessions" && filter.View != "smtp" && filter.View != "smtp-transactions")
                                throw new ServeError(400, "InvalidView", "view must be messages, sessions, smtp or smtp-transactions.");
                            string view = filter.View == "smtp" ? "smtpclients" : filter.View == "smtp-transactions" ? "smtp" : filter.View;
                            response.ContentType = "text/csv; charset=utf-8";
                            response.Headers["Content-Disposition"] = "attachment; filename=\"" + filter.View + ".csv\"";
                            response.Headers["X-Export-Completion"] = "A complete chunked HTTP body is required; timeout or query failure aborts the stream.";
                            response.SendChunked = true;
                            // Validate/step the reader before sending the first byte.
                            using (var rows = db.ReadRows(view, filter, true).GetEnumerator())
                            {
                                bool more = rows.MoveNext();
                                streaming = true;
                                await Write(response, "\uFEFF" + string.Join(";", ServeRead.Columns(view).Select(c => Csv(c.name))) + "\r\n", deadline.Token).ConfigureAwait(false);
                                while (more)
                                {
                                    deadline.Token.ThrowIfCancellationRequested();
                                    await Write(response, string.Join(";", rows.Current.cells.Select(Csv)) + "\r\n", deadline.Token).ConfigureAwait(false);
                                    more = rows.MoveNext();
                                }
                            }
                            return;
                        }
                        else
                        {
                            var match = Regex.Match(path, @"^/api/(?<view>messages|sessions|smtp(?:/(?:clients|transactions))?)/(?<id>[1-9]\d*)$");
                            long id;
                            if (!match.Success || !long.TryParse(match.Groups["id"].Value, NumberStyles.None, CultureInfo.InvariantCulture, out id))
                                throw new ServeError(404, "NotFound", "Unknown API route.");
                            result = match.Groups["view"].Value == "messages" ? db.Message(id, filter) :
                                match.Groups["view"].Value == "sessions" ? db.Session(id, filter) :
                                match.Groups["view"].Value == "smtp/clients" ? db.Client(id, filter) : db.Smtp(id, filter);
                        }
                        deadline.Token.ThrowIfCancellationRequested();
                        await Json(response, 200, result, deadline.Token).ConfigureAwait(false);
                    }
                }
                catch (Exception error)
                {
                    if (streaming || stop.IsCancellationRequested) { Abort(response); }
                    else
                    {
                        var known = error as ServeError;
                        var sqlite = error as SqliteException;
                        int status = deadline.IsCancellationRequested ? 504 : known != null ? known.Status : sqlite != null && (sqlite.SqliteErrorCode == 5 || sqlite.SqliteErrorCode == 6) ? 503 :
                            sqlite != null && sqlite.SqliteErrorCode == 9 ? 504 : 500;
                        string code = status == 504 ? "Deadline" : known != null ? known.Code : status == 503 ? "DatabaseBusy" : "QueryFailed";
                        if (status == 503) response.Headers["Retry-After"] = "1";
                        try { await Json(response, status, new { error = new { code, message = known != null ? known.Message :
                            "Request failed; no fallback or migration was performed.", retryable = status == 503, retryAfterSeconds = status == 503 ? (int?)1 : null } }, CancellationToken.None).ConfigureAwait(false); }
                        catch (Exception e) when (e is IOException || e is HttpListenerException || e is ObjectDisposedException) { Abort(response); }
                    }
                }
                finally
                {
                    try { response.Close(); }
                    catch (Exception e) when (e is IOException || e is HttpListenerException || e is ObjectDisposedException) { }
                    if (shutdown) stop.Cancel();
                }
            }
        }
        static Task Write(HttpListenerResponse response, string text, CancellationToken cancel)
        { var bytes = Encoding.UTF8.GetBytes(text); return response.OutputStream.WriteAsync(bytes, 0, bytes.Length, cancel); }
        static string Csv(object value)
        {
            if (value == null || value is long || value is int || value is double) return ReportBuilder.Csv(value, ";");
            string text;
            if (value is string) text = (string)value;
            else if (value is IEnumerable<string>) text = string.Join("; ", (IEnumerable<string>)value);
            else text = Convert.ToString(value, CultureInfo.InvariantCulture);
            string leading = text.TrimStart();
            if (leading.Length > 0 && ("=+-@".IndexOf(leading[0]) >= 0 || text[0] == '\t' || text[0] == '\r' || text[0] == '\n')) text = "'" + text;
            return ReportBuilder.Csv(text, ";");
        }
        static string SafeUrlPath(string raw)
        {
            string path = raw.Split('?')[0];
            try { path = Uri.UnescapeDataString(path); }
            catch (UriFormatException) { throw new ServeError(400, "InvalidPath", "Malformed path."); }
            if (!path.StartsWith("/", StringComparison.Ordinal) || path.Contains('\\') || path.Contains('%') || path.Contains(':') ||
                path.Any(char.IsControl) || path.Split('/').Any(x => x == "." || x == ".."))
                throw new ServeError(400, "InvalidPath", "Unsafe path.");
            return path;
        }
        static void CheckPath(string root, string file)
        {
            string canonical = Path.GetFullPath(file);
            if (!canonical.Equals(root, StringComparison.OrdinalIgnoreCase) && !canonical.StartsWith(root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new ServeError(400, "InvalidPath", "Path leaves web root.");
            var current = new DirectoryInfo(Path.GetDirectoryName(canonical));
            while (current != null)
            {
                if ((current.Attributes & FileAttributes.ReparsePoint) != 0) throw new ServeError(403, "ReparsePoint", "Reparse paths are not served.");
                current = current.Parent;
            }
            if ((File.GetAttributes(canonical) & FileAttributes.ReparsePoint) != 0) throw new ServeError(403, "ReparsePoint", "Reparse paths are not served.");
        }
        static async Task Static(HttpListenerResponse response, bool head, string root, string path, CancellationToken cancel)
        {
            string file = Path.GetFullPath(Path.Combine(root, path.TrimStart('/').Replace('/', Path.DirectorySeparatorChar)));
            if (!File.Exists(file))
            {
                if (!SpaPath(path)) throw new ServeError(404, "NotFound", "Static resource not found.");
                file = Path.Combine(root, "index.html");
            }
            CheckPath(root, file);
            string extension = Path.GetExtension(file).ToLowerInvariant();
            string mime = extension == ".html" ? "text/html" : extension == ".js" ? "text/javascript" : extension == ".css" ? "text/css" :
                extension == ".svg" ? "image/svg+xml" : extension == ".png" ? "image/png" : extension == ".ico" ? "image/x-icon" :
                extension == ".woff2" ? "font/woff2" : extension == ".woff" ? "font/woff" : null;
            if (mime == null) throw new ServeError(404, "NotFound", "File type is not served.");
            response.ContentType = mime + (mime.StartsWith("text/", StringComparison.Ordinal) ? "; charset=utf-8" : "");
            using (var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true))
            {
                response.ContentLength64 = stream.Length;
                if (!head) await stream.CopyToAsync(response.OutputStream, 65536, cancel).ConfigureAwait(false);
            }
        }
        static string ContentSecurity(string html)
        {
            string theme = "";
            var first = Regex.Match(html, @"<script\b(?<attributes>[^>]*)>(?<body>[\s\S]*?)</script\s*>", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
            if (first.Success && !Regex.IsMatch(first.Groups["attributes"].Value, @"(?:^|\s)src\s*=", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
            {
                string body = first.Groups["body"].Value;
                if (body.Contains("scoutTheme", StringComparison.Ordinal) && body.Contains("prefers-color-scheme", StringComparison.Ordinal) && body.Contains("data-theme", StringComparison.Ordinal))
                    theme = " 'sha256-" + Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(body.Replace("\r\n", "\n").Replace('\r', '\n')))) + "'";
            }
            return "default-src 'self'; script-src 'self'" + theme + "; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";
        }
    }
}
