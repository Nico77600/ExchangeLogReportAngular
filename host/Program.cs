#nullable enable
using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using ExchangeLogReportAngular;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Server.Kestrel.Core;

try
{
PortalOptions options;
try { options = PortalOptions.Parse(args); }
catch (ArgumentException e) { Console.Error.WriteLine(e.Message); return 2; }

SQLitePCL.Batteries_V2.Init();
if (options.StorageMode != StorageMode.None) return await StorageMaintenance.RunCliAsync(options);
string token = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
byte[] tokenHash = SHA256.HashData(Encoding.UTF8.GetBytes(token));
string root = AppContext.BaseDirectory;
string webRoot = Path.Combine(root, "wwwroot");
static bool Inside(string candidate, string directory) =>
    candidate.Equals(directory, StringComparison.OrdinalIgnoreCase) ||
    candidate.StartsWith(directory.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
if (Inside(options.Database, webRoot) || Inside(options.Reports, webRoot) ||
    (options.ReadyFile is not null && Inside(options.ReadyFile, webRoot)))
{
    Console.Error.WriteLine("Database, reports and ready files must be outside wwwroot.");
    return 2;
}
Directory.CreateDirectory(webRoot);
var builder = WebApplication.CreateBuilder(new WebApplicationOptions {
    Args = [], ContentRootPath = root, WebRootPath = webRoot, EnvironmentName = "Production"
});
builder.Configuration.Sources.Clear();
builder.Logging.ClearProviders();
builder.Logging.AddSimpleConsole(o => { o.SingleLine = true; o.TimestampFormat = "HH:mm:ss "; });
builder.Logging.AddFilter("Microsoft.AspNetCore", LogLevel.Warning);
builder.Logging.AddFilter("Microsoft.Extensions.Hosting.Internal.Host", LogLevel.None);
builder.WebHost.ConfigureKestrel(server => {
    server.AddServerHeader = false;
    server.Limits.MaxRequestBodySize = 16384;
    server.Listen(IPAddress.Loopback, options.Port, endpoint => endpoint.Protocols = HttpProtocols.Http1);
});
builder.Services.AddSingleton(options);
builder.Services.AddSingleton<PortalService>();
builder.Services.AddSingleton<StorageMaintenance>();
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow);

await using var app = builder.Build();
var service = app.Services.GetRequiredService<PortalService>();
app.Lifetime.ApplicationStopping.Register(service.StopAccepting);
try { service.Initialize(); }
catch (Exception e) { Console.Error.WriteLine("Could not initialize private report storage: " + PortalDiagnostics.Describe(e)); return 2; }

string authority = "";
string origin = "";
bool readyWritten = false;
string? readyPartial = null;
string csp = PortalContentSecurity.ForWebRoot(webRoot);
app.Use(async (context, next) => {
    context.Response.Headers.ContentSecurityPolicy = csp;
    context.Response.Headers.XContentTypeOptions = "nosniff";
    context.Response.Headers["Referrer-Policy"] = "no-referrer";
    context.Response.Headers["Cross-Origin-Resource-Policy"] = "same-origin";
    context.Response.Headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()";
    if (!string.Equals(context.Request.Host.Value, authority, StringComparison.Ordinal) ||
        !IPAddress.IsLoopback(context.Connection.RemoteIpAddress ?? IPAddress.Any))
    {
        await Problem(context, 400, "Only the exact IPv4 loopback host and port are accepted.");
        return;
    }
    var requestOrigin = context.Request.Headers.Origin;
    string fetchSite = context.Request.Headers["Sec-Fetch-Site"].ToString();
    if ((requestOrigin.Count > 0 && (requestOrigin.Count != 1 || requestOrigin[0] != origin)) ||
        (fetchSite.Length > 0 && fetchSite is not ("same-origin" or "none")))
    {
        await Problem(context, 403, "Cross-origin requests are not allowed.");
        return;
    }
    bool api = context.Request.Path.StartsWithSegments("/api");
    if (api)
    {
        context.Response.Headers.CacheControl = "no-store";
        var supplied = context.Request.Headers["X-Portal-Token"];
        if (supplied.Count != 1 || supplied[0]?.Length != token.Length ||
            !CryptographicOperations.FixedTimeEquals(tokenHash, SHA256.HashData(Encoding.UTF8.GetBytes(supplied[0]!))))
        {
            await Problem(context, 401, "A valid portal capability token is required.");
            return;
        }
    }
    try { await next(context); }
    catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested) { }
    catch (Exception e)
    {
        if (context.Response.HasStarted)
        {
            app.Logger.LogWarning("Streaming response interrupted ({ErrorType}).", e.GetType().Name);
            context.Abort();
            return;
        }
        int status = e switch {
            ApiError problem => problem.Status,
            Microsoft.AspNetCore.Http.BadHttpRequestException bad => bad.StatusCode,
            JsonException => 400,
            _ => 500
        };
        string message = e is ApiError ? e.Message : status < 500 ? "The request is invalid." :
            "The operation failed (" + e.GetType().Name + "). Check local source and report storage.";
        if (status >= 500) app.Logger.LogError("Portal operation failed: {Reason}", PortalDiagnostics.Describe(e));
        await Problem(context, status, message);
    }
});
app.UseDefaultFiles();
app.UseStaticFiles(new StaticFileOptions {
    OnPrepareResponse = context => context.Context.Response.Headers.CacheControl = "no-cache"
});

app.MapGet("/api/status", () => Results.Json(service.Status()));
app.MapGet("/api/storage/audit", async (HttpContext context, StorageMaintenance storage) => {
    if (context.Request.Query.Count != 0) throw new ApiError(400, "Storage audit accepts no query parameters.");
    return Results.Json(await storage.AuditAsync());
});
app.MapGet("/api/reports", () => Results.Json(service.Reports()));
app.MapPost("/api/reports", async (HttpContext context) => {
    if (app.Lifetime.ApplicationStopping.IsCancellationRequested) throw new ApiError(503, "The portal is stopping.");
    if (!context.Request.HasJsonContentType()) throw new ApiError(415, "Content-Type must be application/json.");
    var input = await context.Request.ReadFromJsonAsync<BuildInput>(new JsonSerializerOptions(JsonSerializerDefaults.Web) {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    }, context.RequestAborted) ?? throw new ApiError(400, "A report request is required.");
    return Results.Json(service.Start(input), statusCode: 202);
});
app.MapGet("/api/jobs/{id}", (string id) => Results.Json(service.Job(id)));
app.MapGet("/api/reports/{id}", (string id) => Results.Json(service.Report(id).Detail()));
app.MapGet("/api/reports/{id}/datasets/{name}", (string id, string name, HttpContext context) => {
    var report = service.Report(id);
    var dataset = report.Dataset(name);
    return Results.Json(report.Page(dataset, PageQuery.Parse(context.Request.Query, dataset, false)));
});
app.MapGet("/api/reports/{id}/datasets/{name}/csv", async (string id, string name, HttpContext context) => {
    var report = service.Report(id);
    var dataset = report.Dataset(name);
    await report.Csv(context, dataset, PageQuery.Parse(context.Request.Query, dataset, true));
});
app.MapPost("/api/shutdown", (HttpContext context) => {
    context.Response.OnCompleted(() => { app.Lifetime.StopApplication(); return Task.CompletedTask; });
    return Results.Json(new { state = "Stopping" });
});

try
{
    await app.StartAsync();
    var addresses = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()
        ?? throw new InvalidOperationException("No loopback address was assigned.");
    string url = addresses.Addresses.Single();
    var uri = new Uri(url);
    if (uri.Host != "127.0.0.1") throw new InvalidOperationException("Unexpected listening address.");
    authority = uri.Authority;
    origin = uri.GetLeftPart(UriPartial.Authority);
    if (options.ReadyFile is not null)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(options.ReadyFile)!);
        var ready = new Dictionary<string, object> { ["url"] = origin, ["pid"] = Environment.ProcessId };
        if (options.ReadyFileWithToken) ready["token"] = token;
        string partial = options.ReadyFile + "." + Environment.ProcessId + ".building";
        await using (var readyStream = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            readyPartial = partial;
            await JsonSerializer.SerializeAsync(readyStream, ready);
            await readyStream.FlushAsync();
        }
        File.Move(partial, options.ReadyFile);
        readyPartial = null;
        readyWritten = true;
    }
    app.Logger.LogInformation("Private read-only portal ready at {Url}. Edge mode: {Edge}.", origin, options.Edge);
    app.Logger.LogInformation("Delivered collector defaults only: 14-day detail retention. Collector configuration files are not loaded by this pilot.");
    if (!options.NoBrowser)
    {
        try { Process.Start(new ProcessStartInfo(origin + "/#token=" + token) { UseShellExecute = true }); }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        { app.Logger.LogWarning("Browser could not be opened: {Reason}", PortalDiagnostics.Describe(e)); }
    }
    await app.WaitForShutdownAsync();
    await service.DrainAsync();
    return 0;
}
catch (Exception e)
{
    Console.Error.WriteLine("Portal could not run: " + PortalDiagnostics.Describe(e));
    return 2;
}
finally
{
    if (readyPartial is not null)
    {
        try { File.Delete(readyPartial); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { Console.Error.WriteLine("Incomplete ready file could not be removed (" + e.GetType().Name + ")."); }
    }
    if (readyWritten && options.ReadyFile is not null && File.Exists(options.ReadyFile))
    {
        try { File.Delete(options.ReadyFile); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { Console.Error.WriteLine("Private ready file could not be removed (" + e.GetType().Name + ")."); }
    }
}

static Task Problem(HttpContext context, int status, string message) =>
    Results.Problem(statusCode: status, title: message).ExecuteAsync(context);

}
catch (Exception error)
{
    Console.Error.WriteLine("Portal initialization failed: " + PortalDiagnostics.Describe(error));
    return 2;
}
