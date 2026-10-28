// =============================================================================
//  Exchange Log Report - engine, part 7: sending the report by e-mail (SMTP)
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 2.0.0
//
//  A small SMTP client (RFC 5321) written for the tool, so that every option is
//  explicit and checked:
//    Encryption      None      plain SMTP (port 25)
//                    StartTls  STARTTLS, required: the message is never sent in clear
//                              if the server does not offer it (ports 25 and 587)
//                    Tls       TLS from the first byte (SMTPS, port 465)
//    Authentication  Anonymous no AUTH (a receive connector that accepts anonymous or
//                              IP-based relay)
//                    Basic     AUTH LOGIN (or PLAIN); only over TLS, never in clear
//                    Kerberos  AUTH GSSAPI (RFC 4752) with the Kerberos package only (no
//                              NTLM fallback): the account running the tool (the computer
//                              account for SYSTEM), or the account of the credential file
//  The server certificate is checked (chain and name) unless its thumbprint is
//  pinned in the configuration (self-signed certificate of an Exchange server).
//  The message is a MIME multipart message: text and HTML summary of the report,
//  the report as attachment (HTML file, or every file in a zip archive).
//  Every command and response is kept (AUTH data masked) for -Mode MailTest and the log.
// =============================================================================
using System;
using System.Buffers;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace ExchangeLogReport
{
    /// <summary>SMTP settings of the Mail section of the configuration.</summary>
    public sealed class MailSettings
    {
        public string Server, HeloName, From, FromName = "Exchange Log Report", TargetName, CertificateThumbprint;
        public int Port = 25, TimeoutSeconds = 60;
        public string Encryption = "StartTls";        // None | StartTls | Tls
        public string Authentication = "Anonymous";   // Anonymous | Basic | Kerberos
        public string UserName, Password;             // Basic; Kerberos with another account
        public string[] To = new string[0], Cc = new string[0], Bcc = new string[0];
    }

    public sealed class MailAttachment
    {
        public string Name, ContentType = "application/octet-stream";
        public byte[] Content;
    }

    public sealed class MailContent
    {
        public string Subject, Text, Html;
        public List<MailAttachment> Attachments = new List<MailAttachment>();
        /// <summary>Size of the report left out because it is larger than the limit (0: nothing left out).</summary>
        public long OmittedBytes;
    }

    /// <summary>What happened: the conversation (AUTH data masked), the TLS and authentication used, the refused recipients.</summary>
    public sealed class MailResult
    {
        public bool Sent;
        public string Error, Tls, Certificate, AuthenticationUsed, Response, MessageId;
        public List<string> Transcript = new List<string>();
        public List<string> Refused = new List<string>();
        public string[] ServerCapabilities = new string[0];
        public long MessageBytes;
    }

    public sealed class SmtpException : Exception
    {
        public int Code;
        public SmtpException(string message, int code = 0) : base(message) { Code = code; }
    }

    public static class SmtpSender
    {
        static readonly Encoding Ascii = new ASCIIEncoding();

        /// <summary>Sends one message. Never throws: the outcome and the conversation are in the result.</summary>
        public static MailResult Send(MailSettings s, MailContent m)
        {
            var result = new MailResult();
            try { Run(s, m, result); }
            catch (Exception ex)
            {
                result.Sent = false;
                result.Error = ex is SmtpException || ex is AuthenticationException || ex is IOException || ex is SocketException ? ex.Message : ex.GetType().Name + ": " + ex.Message;
                if (ex.InnerException != null && !(ex is SmtpException)) result.Error += " (" + ex.InnerException.Message + ")";
            }
            return result;
        }

        sealed class Connection : IDisposable
        {
            public TcpClient Client;
            public Stream Stream;
            public MailResult Result;
            readonly byte[] _buffer = new byte[8192];
            int _length, _position;

            public void Write(string line, string shown = null)
            {
                Result.Transcript.Add("C: " + (shown ?? line));
                var bytes = Ascii.GetBytes(line + "\r\n");
                Stream.Write(bytes, 0, bytes.Length);
                Stream.Flush();
            }

            string ReadLine()
            {
                var sb = new StringBuilder();
                while (true)
                {
                    if (_position >= _length)
                    {
                        _length = Stream.Read(_buffer, 0, _buffer.Length);
                        _position = 0;
                        if (_length <= 0) throw new SmtpException("The SMTP server closed the connection.");
                    }
                    char c = (char)_buffer[_position++];
                    if (c == '\n') { if (sb.Length > 0 && sb[sb.Length - 1] == '\r') sb.Length--; return sb.ToString(); }
                    sb.Append(c);
                    if (sb.Length > 65536) throw new SmtpException("SMTP response line too long.");
                }
            }

            /// <summary>One response (several lines "250-..." then "250 ..."): code and lines without the code.</summary>
            public int Read(out List<string> lines)
            {
                lines = new List<string>();
                while (true)
                {
                    string l = ReadLine();
                    Result.Transcript.Add("S: " + l);
                    if (l.Length < 3) throw new SmtpException("Unexpected SMTP response: " + l);
                    lines.Add(l.Length > 4 ? l.Substring(4) : "");
                    if (l.Length == 3 || l[3] != '-')
                    {
                        int code;
                        if (!int.TryParse(l.Substring(0, 3), NumberStyles.None, CultureInfo.InvariantCulture, out code)) throw new SmtpException("Unexpected SMTP response: " + l);
                        return code;
                    }
                }
            }

            public string Expect(int expected, string what)
            {
                List<string> lines;
                int code = Read(out lines);
                string text = code.ToString(CultureInfo.InvariantCulture) + " " + string.Join(" ", lines);
                if (code / 100 != expected / 100 && code != expected) throw new SmtpException(what + " refused by the server: " + text, code);
                return text;
            }

            public void ResetBuffer() { _length = 0; _position = 0; }

            public void Dispose()
            {
                try { if (Stream != null) Stream.Dispose(); } catch (Exception) { }
                try { if (Client != null) Client.Dispose(); } catch (Exception) { }
            }
        }

        static void Run(MailSettings s, MailContent m, MailResult result)
        {
            if (string.IsNullOrWhiteSpace(s.Server)) throw new SmtpException("Mail.SmtpServer is not set.");
            var recipients = (s.To ?? new string[0]).Concat(s.Cc ?? new string[0]).Concat(s.Bcc ?? new string[0]).Where(x => !string.IsNullOrWhiteSpace(x)).Select(x => x.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
            if (recipients.Count == 0) throw new SmtpException("No recipient (Mail.To).");
            bool basic = string.Equals(s.Authentication, "Basic", StringComparison.OrdinalIgnoreCase);
            bool kerberos = string.Equals(s.Authentication, "Kerberos", StringComparison.OrdinalIgnoreCase);
            bool implicitTls = string.Equals(s.Encryption, "Tls", StringComparison.OrdinalIgnoreCase);
            bool startTls = string.Equals(s.Encryption, "StartTls", StringComparison.OrdinalIgnoreCase);
            if (basic && !implicitTls && !startTls) throw new SmtpException("Basic authentication sends the password: it needs Encryption = 'StartTls' or 'Tls'.");
            string helo = string.IsNullOrWhiteSpace(s.HeloName) ? LocalFqdn() : s.HeloName.Trim();
            byte[] message = Mime.Build(s, m, out string messageId);
            result.MessageBytes = message.Length;
            result.MessageId = messageId;

            using (var c = new Connection { Result = result })
            {
                c.Client = new TcpClient();
                var connect = c.Client.ConnectAsync(s.Server, s.Port);
                if (!connect.Wait(TimeSpan.FromSeconds(s.TimeoutSeconds))) throw new SmtpException("No answer from " + s.Server + ":" + s.Port + " within " + s.TimeoutSeconds + " s.");
                if (connect.IsFaulted) throw connect.Exception.GetBaseException();
                c.Client.ReceiveTimeout = c.Client.SendTimeout = s.TimeoutSeconds * 1000;
                c.Stream = c.Client.GetStream();
                result.Transcript.Add("* connected to " + s.Server + ":" + s.Port + " (" + c.Client.Client.RemoteEndPoint + ")");
                if (implicitTls) Secure(c, s, result);
                c.Expect(220, "Connection");
                var capabilities = Ehlo(c, helo);
                if (startTls)
                {
                    if (!capabilities.Any(x => x.Equals("STARTTLS", StringComparison.OrdinalIgnoreCase)))
                        throw new SmtpException("The server does not offer STARTTLS: the message is not sent in clear (Encryption = 'StartTls'). Use Encryption = 'None' only on a trusted network.");
                    c.Write("STARTTLS");
                    c.Expect(220, "STARTTLS");
                    c.ResetBuffer();
                    Secure(c, s, result);
                    capabilities = Ehlo(c, helo);
                }
                result.ServerCapabilities = capabilities.ToArray();
                var auth = capabilities.Where(x => x.StartsWith("AUTH ", StringComparison.OrdinalIgnoreCase) || x.StartsWith("AUTH=", StringComparison.OrdinalIgnoreCase))
                    .SelectMany(x => x.Substring(5).Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries)).Select(x => x.ToUpperInvariant()).Distinct().ToList();
                if (basic) AuthBasic(c, s, auth, result);
                else if (kerberos) AuthKerberos(c, s, auth, result);
                else result.AuthenticationUsed = "Anonymous";

                bool size = capabilities.Any(x => x.StartsWith("SIZE", StringComparison.OrdinalIgnoreCase));
                c.Write("MAIL FROM:<" + s.From + ">" + (size ? " SIZE=" + message.Length.ToString(CultureInfo.InvariantCulture) : ""));
                c.Expect(250, "MAIL FROM:<" + s.From + ">");
                int accepted = 0;
                foreach (var r in recipients)
                {
                    c.Write("RCPT TO:<" + r + ">");
                    List<string> lines;
                    int code = c.Read(out lines);
                    if (code / 100 == 2) accepted++;
                    else result.Refused.Add(r + ": " + code.ToString(CultureInfo.InvariantCulture) + " " + string.Join(" ", lines));
                }
                if (accepted == 0) throw new SmtpException("Every recipient was refused: " + string.Join("; ", result.Refused));
                c.Write("DATA");
                c.Expect(354, "DATA");
                result.Transcript.Add("C: (message, " + message.Length.ToString("N0", CultureInfo.InvariantCulture) + " bytes)");
                message = DotStuff(message);
                c.Stream.Write(message, 0, message.Length);
                var end = Ascii.GetBytes("\r\n.\r\n");
                c.Stream.Write(end, 0, end.Length);
                c.Stream.Flush();
                result.Response = c.Expect(250, "The message");
                result.Sent = true;
                try { c.Write("QUIT"); List<string> bye; c.Read(out bye); } catch (Exception) { }
            }
        }

        /// <summary>A line starting with "." is sent with one more "." (RFC 5321 4.5.2), so that it never ends the DATA.</summary>
        static byte[] DotStuff(byte[] message)
        {
            int extra = message.Length > 0 && message[0] == (byte)'.' ? 1 : 0;
            for (int i = 2; i < message.Length; i++) if (message[i] == (byte)'.' && message[i - 1] == (byte)'\n' && message[i - 2] == (byte)'\r') extra++;
            if (extra == 0) return message;
            var result = new byte[message.Length + extra];
            int j = 0;
            for (int i = 0; i < message.Length; i++)
            {
                if (message[i] == (byte)'.' && (i == 0 || (i >= 2 && message[i - 1] == (byte)'\n' && message[i - 2] == (byte)'\r'))) result[j++] = (byte)'.';
                result[j++] = message[i];
            }
            return result;
        }

        static List<string> Ehlo(Connection c, string helo)
        {
            c.Write("EHLO " + helo);
            List<string> lines;
            int code = c.Read(out lines);
            if (code != 250) throw new SmtpException("EHLO refused by the server: " + code.ToString(CultureInfo.InvariantCulture) + " " + string.Join(" ", lines), code);
            return lines.Skip(1).Select(x => x.Trim()).ToList();
        }

        static void Secure(Connection c, MailSettings s, MailResult result)
        {
            string pinned = string.IsNullOrWhiteSpace(s.CertificateThumbprint) ? null : s.CertificateThumbprint.Replace(" ", "").Replace(":", "").ToUpperInvariant();
            string problem = null;
            var ssl = new SslStream(c.Stream, false, (sender, certificate, chain, errors) =>
            {
                var cert = certificate == null ? null : new X509Certificate2(certificate);
                if (cert != null) result.Certificate = cert.Subject + " (thumbprint " + cert.Thumbprint + ", expires " + cert.NotAfter.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) + ")";
                if (pinned != null)
                {
                    if (cert != null && string.Equals(cert.Thumbprint, pinned, StringComparison.OrdinalIgnoreCase)) return true;
                    problem = "the certificate of the server is not the one of Mail.CertificateThumbprint (" + (cert == null ? "no certificate" : cert.Thumbprint) + ")";
                    return false;
                }
                if (errors == SslPolicyErrors.None) return true;
                problem = "the certificate of the server is not trusted (" + errors + "). Use the name of the certificate in Mail.SmtpServer, or pin its thumbprint in Mail.CertificateThumbprint";
                return false;
            });
            try { ssl.AuthenticateAsClient(new SslClientAuthenticationOptions { TargetHost = s.Server, EnabledSslProtocols = SslProtocols.None, CertificateRevocationCheckMode = X509RevocationMode.NoCheck }); }
            catch (AuthenticationException ex) { throw new SmtpException("TLS failed: " + (problem ?? ex.Message)); }
            c.Stream = ssl;
            string protocol;
            switch (ssl.SslProtocol)
            {
                case SslProtocols.Tls13: protocol = "TLS 1.3"; break;
                case SslProtocols.Tls12: protocol = "TLS 1.2"; break;
                default: protocol = ssl.SslProtocol.ToString(); break;
            }
            result.Tls = protocol + ", " + ssl.NegotiatedCipherSuite;
            result.Transcript.Add("* " + result.Tls + (result.Certificate != null ? ", certificate " + result.Certificate : ""));
        }

        static void AuthBasic(Connection c, MailSettings s, List<string> mechanisms, MailResult result)
        {
            if (string.IsNullOrEmpty(s.UserName) || s.Password == null) throw new SmtpException("Basic authentication needs the account and its password (Mail.CredentialFile: run -Mode MailTest -Credential once).");
            if (mechanisms.Contains("LOGIN"))
            {
                c.Write("AUTH LOGIN");
                c.Expect(334, "AUTH LOGIN");
                c.Write(Convert.ToBase64String(Encoding.UTF8.GetBytes(s.UserName)), "(account " + s.UserName + ")");
                c.Expect(334, "AUTH LOGIN");
                c.Write(Convert.ToBase64String(Encoding.UTF8.GetBytes(s.Password)), "(password)");
                c.Expect(235, "The account " + s.UserName);
                result.AuthenticationUsed = "Basic (AUTH LOGIN, " + s.UserName + ")";
                return;
            }
            if (mechanisms.Contains("PLAIN"))
            {
                var token = Convert.ToBase64String(Encoding.UTF8.GetBytes("\0" + s.UserName + "\0" + s.Password));
                c.Write("AUTH PLAIN " + token, "AUTH PLAIN (account " + s.UserName + ", password)");
                c.Expect(235, "The account " + s.UserName);
                result.AuthenticationUsed = "Basic (AUTH PLAIN, " + s.UserName + ")";
                return;
            }
            throw new SmtpException("The server does not offer Basic authentication (AUTH LOGIN or PLAIN) on this connection" + (mechanisms.Count > 0 ? "; it offers " + string.Join(", ", mechanisms) : ": no AUTH at all") + ".");
        }

        /// <summary>
        /// SASL GSSAPI (RFC 4752) with the Kerberos package: the Kerberos tokens are exchanged in 334 challenges, then the
        /// server sends its security layers wrapped; the client answers "no security layer" wrapped (TLS protects the session).
        /// </summary>
        static void AuthKerberos(Connection c, MailSettings s, List<string> mechanisms, MailResult result)
        {
            if (!mechanisms.Contains("GSSAPI"))
                throw new SmtpException("The server does not offer Kerberos (AUTH GSSAPI)" + (mechanisms.Count > 0 ? "; it offers " + string.Join(", ", mechanisms) : ": no AUTH at all") + ". On Exchange, the receive connector needs Integrated Windows authentication.");
            string spn = string.IsNullOrWhiteSpace(s.TargetName) ? "SMTPSVC/" + s.Server : s.TargetName.Trim();
            var credential = string.IsNullOrEmpty(s.UserName) ? CredentialCache.DefaultNetworkCredentials : new NetworkCredential(s.UserName, s.Password);
            using (var context = new NegotiateAuthentication(new NegotiateAuthenticationClientOptions
            {
                Package = "Kerberos", TargetName = spn, Credential = credential, RequiredProtectionLevel = ProtectionLevel.Sign, RequireMutualAuthentication = true
            }))
            {
                NegotiateAuthenticationStatusCode status;
                byte[] token = context.GetOutgoingBlob(ReadOnlySpan<byte>.Empty, out status);
                if (status != NegotiateAuthenticationStatusCode.ContinueNeeded && status != NegotiateAuthenticationStatusCode.Completed)
                    throw new SmtpException("Kerberos failed before contacting the server (" + status + "): no ticket for " + spn + ". Check the name in Mail.SmtpServer (a name, not an address), the SPN (Mail.TargetName behind a load balancer) and that this account can get a Kerberos ticket.");
                c.Write("AUTH GSSAPI " + Convert.ToBase64String(token ?? new byte[0]), "AUTH GSSAPI (Kerberos ticket for " + spn + ")");
                for (int round = 0; round < 10; round++)
                {
                    List<string> lines;
                    int code = c.Read(out lines);
                    if (code == 235)
                    {
                        result.AuthenticationUsed = "Kerberos (AUTH GSSAPI, " + (string.IsNullOrEmpty(s.UserName) ? Environment.UserDomainName + "\\" + Environment.UserName : s.UserName) + ", " + spn + ")";
                        return;
                    }
                    if (code != 334)
                    {
                        string text = code.ToString(CultureInfo.InvariantCulture) + " " + string.Join(" ", lines);
                        string hint = text.IndexOf("proxy", StringComparison.OrdinalIgnoreCase) >= 0
                            ? ". An Exchange front end (client connector, port 587) hands an authenticated session over to the mailbox of the account: the account needs a mailbox, and the computer account (SYSTEM) has none. Save a mailbox account in Mail.CredentialFile (-Mode MailTest -Credential), or use a receive connector of the Transport service that accepts Integrated authentication"
                            : "";
                        throw new SmtpException("Kerberos authentication refused by the server: " + text + hint, code);
                    }
                    byte[] challenge = string.IsNullOrWhiteSpace(lines[0]) ? new byte[0] : Convert.FromBase64String(lines[0].Trim());
                    byte[] answer;
                    if (!context.IsAuthenticated)
                    {
                        answer = context.GetOutgoingBlob(challenge, out status);
                        if (status != NegotiateAuthenticationStatusCode.ContinueNeeded && status != NegotiateAuthenticationStatusCode.Completed)
                            throw new SmtpException("Kerberos failed (" + status + ") with the answer of the server.");
                    }
                    else
                    {
                        // Security layer: the server offers its layers; the client chooses none (1), max size 0.
                        var plain = new ArrayBufferWriter<byte>();
                        bool encrypted;
                        var unwrapped = context.Unwrap(challenge, plain, out encrypted);
                        if (unwrapped != NegotiateAuthenticationStatusCode.Completed || plain.WrittenCount < 4) throw new SmtpException("Kerberos: unexpected security layer message from the server (" + unwrapped + ").");
                        if ((plain.WrittenSpan[0] & 1) == 0) throw new SmtpException("Kerberos: the server requires a security layer, which the tool does not support (TLS protects the session).");
                        var wrapped = new ArrayBufferWriter<byte>();
                        bool isEncrypted;
                        var w = context.Wrap(new byte[] { 1, 0, 0, 0 }, wrapped, false, out isEncrypted);
                        if (w != NegotiateAuthenticationStatusCode.Completed) throw new SmtpException("Kerberos: the security layer answer could not be built (" + w + ").");
                        answer = wrapped.WrittenSpan.ToArray();
                    }
                    c.Write(answer == null || answer.Length == 0 ? "" : Convert.ToBase64String(answer), "(Kerberos token)");
                }
                throw new SmtpException("Kerberos authentication did not complete.");
            }
        }

        static string LocalFqdn()
        {
            try
            {
                var props = System.Net.NetworkInformation.IPGlobalProperties.GetIPGlobalProperties();
                return string.IsNullOrEmpty(props.DomainName) ? props.HostName : props.HostName + "." + props.DomainName;
            }
            catch (Exception) { return Environment.MachineName; }
        }
    }

    /// <summary>MIME message (RFC 5322, 2045-2047, 2231): multipart/mixed { multipart/alternative { text, html }, attachments }.</summary>
    public static class Mime
    {
        public static byte[] Build(MailSettings s, MailContent m, out string messageId)
        {
            string domain = s.From != null && s.From.IndexOf('@') > 0 ? s.From.Substring(s.From.IndexOf('@') + 1) : "localhost";
            messageId = "<" + Guid.NewGuid().ToString("N") + "@" + domain + ">";
            string mixed = "elr-mixed-" + Guid.NewGuid().ToString("N"), alternative = "elr-alt-" + Guid.NewGuid().ToString("N");
            var sb = new StringBuilder();
            Action<string> line = x => sb.Append(x).Append("\r\n");
            line("From: " + Address(s.FromName, s.From));
            if (s.To != null && s.To.Length > 0) line("To: " + string.Join(", ", s.To.Select(x => "<" + x.Trim() + ">")));
            if (s.Cc != null && s.Cc.Length > 0) line("Cc: " + string.Join(", ", s.Cc.Select(x => "<" + x.Trim() + ">")));
            line("Subject: " + Header(m.Subject ?? ""));
            line("Date: " + DateTimeOffset.Now.ToString("ddd, dd MMM yyyy HH:mm:ss ", CultureInfo.InvariantCulture) + DateTimeOffset.Now.ToString("zzz", CultureInfo.InvariantCulture).Replace(":", ""));
            line("Message-ID: " + messageId);
            line("MIME-Version: 1.0");
            line("X-Mailer: Exchange Log Report");
            line("Content-Type: multipart/mixed; boundary=\"" + mixed + "\"");
            line("");
            line("This is a multi-part message in MIME format.");
            line("--" + mixed);
            line("Content-Type: multipart/alternative; boundary=\"" + alternative + "\"");
            line("");
            line("--" + alternative);
            line("Content-Type: text/plain; charset=utf-8");
            line("Content-Transfer-Encoding: base64");
            line("");
            Base64(sb, Encoding.UTF8.GetBytes(m.Text ?? ""));
            line("--" + alternative);
            line("Content-Type: text/html; charset=utf-8");
            line("Content-Transfer-Encoding: base64");
            line("");
            Base64(sb, Encoding.UTF8.GetBytes(m.Html ?? ""));
            line("--" + alternative + "--");
            foreach (var a in m.Attachments)
            {
                line("--" + mixed);
                line("Content-Type: " + a.ContentType + "; " + Parameter("name", a.Name));
                line("Content-Disposition: attachment; " + Parameter("filename", a.Name));
                line("Content-Transfer-Encoding: base64");
                line("");
                Base64(sb, a.Content);
            }
            line("--" + mixed + "--");
            return Encoding.ASCII.GetBytes(sb.ToString());
        }

        static string Address(string name, string address)
        {
            if (string.IsNullOrWhiteSpace(name)) return "<" + address + ">";
            return Header(name) + " <" + address + ">";
        }

        /// <summary>RFC 2047 encoded word when the text is not plain ASCII.</summary>
        public static string Header(string text)
        {
            if (text.All(ch => ch >= 32 && ch < 127)) return text;
            var bytes = Encoding.UTF8.GetBytes(text);
            // Encoded words of at most 45 bytes (60 base64 characters), folded on several lines.
            var parts = new List<string>();
            int i = 0;
            while (i < bytes.Length)
            {
                int n = Math.Min(45, bytes.Length - i);
                while (n > 1 && i + n < bytes.Length && (bytes[i + n] & 0xC0) == 0x80) n--;   // do not cut a UTF-8 character
                parts.Add("=?utf-8?B?" + Convert.ToBase64String(bytes, i, n) + "?=");
                i += n;
            }
            return string.Join("\r\n ", parts);
        }

        /// <summary>name="value", or RFC 2231 name*=utf-8''value for a name that is not ASCII.</summary>
        static string Parameter(string name, string value)
        {
            if (value.All(ch => ch >= 32 && ch < 127 && ch != '"' && ch != '\\')) return name + "=\"" + value + "\"";
            var sb = new StringBuilder(name + "*=utf-8''");
            foreach (var b in Encoding.UTF8.GetBytes(value))
            {
                char ch = (char)b;
                if (b < 128 && (char.IsLetterOrDigit(ch) || "-._~".IndexOf(ch) >= 0)) sb.Append(ch);
                else sb.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
            }
            return sb.ToString();
        }

        static void Base64(StringBuilder sb, byte[] bytes)
        {
            string b64 = Convert.ToBase64String(bytes ?? new byte[0]);
            for (int i = 0; i < b64.Length; i += 76) sb.Append(b64, i, Math.Min(76, b64.Length - i)).Append("\r\n");
        }
    }

    /// <summary>The e-mail of a report: summary in the body, the report attached.</summary>
    public static class ReportMail
    {
        static string H(object v) { return WebUtility.HtmlEncode(Convert.ToString(v, CultureInfo.InvariantCulture) ?? ""); }
        static string N(object v) { return v == null ? "-" : Convert.ToInt64(v, CultureInfo.InvariantCulture).ToString("N0", CultureInfo.GetCultureInfo("en-US")); }

        /// <summary>
        /// Builds the message. Attach: Html (the HTML file; zipped when it is larger than the limit), Zip (every file of
        /// the report in one archive) or None. An attachment still larger than maxBytes is left out and the body says so.
        /// </summary>
        public static MailContent Build(ReportResult report, string subject, string title, string period, string reportType, string computer, string attach, long maxBytes)
        {
            var m = new MailContent { Subject = subject };
            string note = null;
            if (!string.Equals(attach, "None", StringComparison.OrdinalIgnoreCase))
            {
                MailAttachment a = null;
                if (string.Equals(attach, "Html", StringComparison.OrdinalIgnoreCase) && report.HtmlPath != null && File.Exists(report.HtmlPath))
                {
                    var bytes = File.ReadAllBytes(report.HtmlPath);
                    a = bytes.LongLength <= maxBytes
                        ? new MailAttachment { Name = Path.GetFileName(report.HtmlPath), ContentType = "text/html", Content = bytes }
                        : Zip(new[] { report.HtmlPath }, Path.GetFileNameWithoutExtension(report.HtmlPath) + ".zip");
                }
                else a = Zip(report.Files.Select(f => f.Path).Where(File.Exists).ToArray(), Path.GetFileName(report.Folder.TrimEnd('\\', '/')) + ".zip");
                if (a != null && a.Content.LongLength > maxBytes)
                {
                    note = string.Format(CultureInfo.InvariantCulture, "The report ({0:0.0} MB) is larger than Mail.MaxAttachmentMB: it is not attached. It is in {1} on {2}.", a.Content.LongLength / 1048576.0, report.Folder, computer);
                    m.OmittedBytes = a.Content.LongLength;
                    a = null;
                }
                if (a != null) m.Attachments.Add(a);
            }
            else note = "The report is in " + report.Folder + " on " + computer + ".";

            var counts = report.Counts;
            Func<string, long> count = k => { long v; return counts.TryGetValue(k, out v) ? v : 0; };
            var figures = new List<KeyValuePair<string, string>>();
            bool edge = counts.ContainsKey("smtpdestinations");
            if (!edge) figures.Add(new KeyValuePair<string, string>("Real users", N(count("users"))));
            if (counts.ContainsKey("sessions")) figures.Add(new KeyValuePair<string, string>("Client sessions", N(count("sessions")) + " (" + N(count("sessionsWithFailures")) + " with failures)"));
            if (counts.ContainsKey("issues")) figures.Add(new KeyValuePair<string, string>("Failed or slow requests", N(count("issues"))));
            if (counts.ContainsKey("messages")) figures.Add(new KeyValuePair<string, string>("Messages", N(count("messages")) + " (" + N(count("smtp")) + " SMTP transactions)"));
            if (counts.ContainsKey("smtpclients")) figures.Add(new KeyValuePair<string, string>("SMTP clients", N(count("smtpclients"))));
            if (edge) figures.Add(new KeyValuePair<string, string>("SMTP destinations", N(count("smtpdestinations"))));

            var text = new StringBuilder();
            text.Append(title).Append("\r\n").Append(reportType).Append(" report, ").Append(period).Append("\r\n\r\n");
            foreach (var f in figures) text.Append(f.Key).Append(": ").Append(f.Value).Append("\r\n");
            var html = new StringBuilder();
            html.Append("<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body style=\"font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2328;margin:0;padding:16px\">");
            html.Append("<div style=\"border-left:4px solid #d63e73;padding:4px 12px;margin-bottom:16px\"><div style=\"font-size:20px;font-weight:600\">").Append(H(title)).Append("</div>");
            html.Append("<div style=\"color:#57606a\">").Append(H(reportType)).Append(" report &middot; ").Append(H(period)).Append("</div></div>");
            html.Append("<table style=\"border-collapse:collapse;margin-bottom:16px\">");
            foreach (var f in figures) html.Append("<tr><td style=\"padding:3px 16px 3px 0;color:#57606a\">").Append(H(f.Key)).Append("</td><td style=\"padding:3px 0;font-weight:600\">").Append(H(f.Value)).Append("</td></tr>");
            html.Append("</table>");
            var servers = report.ServerRows;
            if (servers != null && servers.Count > 0)
            {
                string[] head = edge ? new[] { "Server", "Verdict", "SMTP received", "SMTP sent", "SMTP rejected", "Messages" }
                                     : new[] { "Server", "Verdict", "Real users", "Requests", "Unresolved failures", "SMTP received", "SMTP sent", "Messages" };
                int[] cols = edge ? new[] { 0, 1, 10, 11, 12, 13 } : new[] { 0, 1, 2, 3, 5, 10, 11, 13 };
                html.Append("<table style=\"border-collapse:collapse;font-size:13px\"><tr>");
                foreach (var h in head) html.Append("<th style=\"text-align:").Append(h == "Server" || h == "Verdict" ? "left" : "right").Append(";padding:6px 10px;border-bottom:2px solid #d0d7de;background:#f6f8fa\">").Append(H(h)).Append("</th>");
                html.Append("</tr>");
                text.Append("\r\n").Append(string.Join(" | ", head)).Append("\r\n");
                foreach (var row in servers)
                {
                    string verdict = Convert.ToString(row[1], CultureInfo.InvariantCulture);
                    string color = verdict == "No real usage" ? "#9a6700" : "#1a7f37";
                    html.Append("<tr>");
                    for (int i = 0; i < cols.Length; i++)
                    {
                        object v = row[cols[i]];
                        bool label = i < 2;
                        string shown = label ? Convert.ToString(v, CultureInfo.InvariantCulture) : N(v);
                        html.Append("<td style=\"padding:5px 10px;border-bottom:1px solid #eaeef2;text-align:").Append(label ? "left" : "right")
                            .Append(i == 1 ? ";color:" + color + ";font-weight:600" : "").Append("\">").Append(H(shown)).Append("</td>");
                    }
                    html.Append("</tr>");
                    text.Append(string.Join(" | ", cols.Select((c, i) => i < 2 ? Convert.ToString(row[c], CultureInfo.InvariantCulture) : N(row[c])))).Append("\r\n");
                }
                html.Append("</table>");
            }
            AppendHighlights(report.Highlights, html, text);
            string attached = m.Attachments.Count > 0 ? "Attached: " + m.Attachments[0].Name + " (" + (m.Attachments[0].Content.LongLength / 1024.0).ToString("N0", CultureInfo.InvariantCulture) + " KB)." : null;
            foreach (var p in new[] { attached, note }.Where(x => x != null))
            {
                html.Append("<p style=\"color:#57606a;margin-top:16px\">").Append(H(p)).Append("</p>");
                text.Append("\r\n").Append(p).Append("\r\n");
            }
            html.Append("<p style=\"color:#8c959f;font-size:12px;margin-top:24px\">Exchange Log Report &middot; ").Append(H(computer)).Append("</p></body></html>");
            m.Text = text.ToString();
            m.Html = html.ToString();
            return m;
        }

        /// <summary>
        /// Detailed report: the main problems of the period, 10 per kind (users with unresolved failures, failed
        /// client sessions, SMTP clients with refused mail), so that a daily e-mail can be read without opening the
        /// report. The kinds without any problem are named in one line.
        /// </summary>
        static void AppendHighlights(List<ReportHighlight> highlights, StringBuilder html, StringBuilder text)
        {
            if (highlights == null || highlights.Count == 0) return;
            const string th = "text-align:left;padding:5px 8px;border-bottom:2px solid #d0d7de;background:#f6f8fa;font-weight:600";
            const string td = "padding:4px 8px;border-bottom:1px solid #eaeef2;vertical-align:top";
            html.Append("<div style=\"font-size:16px;font-weight:600;margin:24px 0 4px\">Main problems</div>");
            text.Append("\r\nMAIN PROBLEMS\r\n");
            foreach (var h in highlights.Where(x => x.Total > 0))
            {
                string head = h.Title + " (" + N(h.Total) + (h.Total > h.Rows.Count ? ", first " + h.Rows.Count.ToString(CultureInfo.InvariantCulture) : "") + ")";
                html.Append("<div style=\"font-weight:600;margin:16px 0 2px;color:#a40e4c\">").Append(H(head)).Append("</div>");
                html.Append("<div style=\"color:#57606a;font-size:12px;margin-bottom:6px\">").Append(H(h.Hint)).Append("</div>");
                html.Append("<table style=\"border-collapse:collapse;font-size:12px\"><tr>");
                foreach (var c in h.Columns) html.Append("<th style=\"").Append(th).Append("\">").Append(H(c)).Append("</th>");
                html.Append("</tr>");
                foreach (var r in h.Rows)
                {
                    html.Append("<tr>");
                    foreach (var v in r) html.Append("<td style=\"").Append(td).Append("\">").Append(H(v)).Append("</td>");
                    html.Append("</tr>");
                }
                html.Append("</table>");
                text.Append("\r\n").Append(head).Append("\r\n").Append(string.Join(" | ", h.Columns)).Append("\r\n");
                foreach (var r in h.Rows) text.Append(string.Join(" | ", r)).Append("\r\n");
            }
            var none = highlights.Where(x => x.Total == 0).Select(x => x.Title.ToLowerInvariant()).ToList();
            if (none.Count > 0)
            {
                string line = "None in this period: " + string.Join(", ", none) + ".";
                html.Append("<p style=\"color:#1a7f37;margin-top:16px\">").Append(H(line)).Append("</p>");
                text.Append("\r\n").Append(line).Append("\r\n");
            }
        }

        static MailAttachment Zip(string[] files, string name)
        {
            if (files.Length == 0) return null;
            using (var ms = new MemoryStream())
            {
                using (var zip = new ZipArchive(ms, ZipArchiveMode.Create, true))
                    foreach (var f in files) zip.CreateEntryFromFile(f, Path.GetFileName(f), CompressionLevel.Optimal);
                return new MailAttachment { Name = name, ContentType = "application/zip", Content = ms.ToArray() };
            }
        }
    }
}
