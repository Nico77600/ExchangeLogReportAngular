#nullable enable
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace ExchangeLogReportAngular;

internal static class PortalContentSecurity
{
    public static string ForWebRoot(string webRoot)
    {
        string index = Path.Combine(webRoot, "index.html");
        return ForHtml(File.Exists(index) ? File.ReadAllText(index) : "");
    }

    public static string ForHtml(string html)
    {
        string allowedTheme = "";
        Match first = Regex.Match(html, @"<script\b(?<attributes>[^>]*)>(?<body>[\s\S]*?)</script\s*>",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        if (first.Success &&
            !Regex.IsMatch(first.Groups["attributes"].Value, @"(?:^|\s)src\s*=", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
        {
            string body = first.Groups["body"].Value;
            if (body.Contains("scoutTheme", StringComparison.Ordinal) &&
                body.Contains("prefers-color-scheme", StringComparison.Ordinal) &&
                body.Contains("data-theme", StringComparison.Ordinal))
            {
                // HTML normalizes CR/CRLF to LF before CSP hashes inline script text.
                body = body.Replace("\r\n", "\n").Replace('\r', '\n');
                allowedTheme = " 'sha256-" + Convert.ToBase64String(SHA256.HashData(Encoding.UTF8.GetBytes(body))) + "'";
            }
        }
        return "default-src 'self'; script-src 'self'" + allowedTheme +
            "; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'self'; " +
            "object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";
    }
}
