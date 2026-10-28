#nullable enable
using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReportAngular;

internal sealed record PortalColumn(string Name, string Kind, bool Grid);
internal sealed record PortalDataset(string Name, long Total, PortalColumn[] Columns);
internal sealed record PageQuery(int Offset, int Limit, string Search, int Sort, bool Descending)
{
    public static PageQuery Parse(IQueryCollection values, PortalDataset dataset, bool csv)
    {
        string[] allowed = csv ? ["q", "sort", "descending"] : ["offset", "limit", "q", "sort", "descending"];
        if (values.Any(x => !allowed.Contains(x.Key, StringComparer.Ordinal) || x.Value.Count != 1))
            throw new ApiError(400, "Unknown or duplicate query parameter.");
        int Number(string key, int fallback, int min, int max)
        {
            if (!values.ContainsKey(key)) return fallback;
            if (!int.TryParse(values[key], NumberStyles.None, CultureInfo.InvariantCulture, out int value) ||
                value < min || value > max) throw new ApiError(400, "Invalid " + key + ".");
            return value;
        }
        int offset = csv ? 0 : Number("offset", 0, 0, int.MaxValue);
        int limit = csv ? 200 : Number("limit", 50, 1, 200);
        int sort = Number("sort", 0, 0, dataset.Columns.Length - 1);
        string search = values["q"].ToString();
        if (search.Length > 512) throw new ApiError(400, "Search is limited to 512 characters.");
        bool descending = false;
        if (values.ContainsKey("descending") && values["descending"] != "true" && values["descending"] != "false")
            throw new ApiError(400, "descending must be true or false.");
        descending = values["descending"] == "true";
        return new(offset, limit, search, sort, descending);
    }
}

internal sealed class Snapshot
{
    public const string FileName = "report.sqlite";
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
    private readonly string path;
    private readonly JsonElement metadata;
    private readonly Dictionary<string, PortalDataset> datasets;
    public string Id { get; }
    public string Generated => metadata.GetProperty("generated").GetString() ?? "";

    private Snapshot(string id, string path, JsonElement metadata, Dictionary<string, PortalDataset> datasets)
    { Id = id; this.path = path; this.metadata = metadata; this.datasets = datasets; }

    public static bool IsReparse(string path) => (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;

    public static Snapshot Load(string id, string path)
    {
        using var db = PortalService.OpenReadOnly(path);
        using var command = db.CreateCommand();
        command.CommandText = "SELECT value FROM metadata WHERE key='portal_format';";
        if (command.ExecuteScalar() as string != "1") throw new InvalidDataException("Unknown portal format.");
        command.CommandText = "SELECT value FROM metadata WHERE key='report';";
        string json = command.ExecuteScalar() as string ?? throw new InvalidDataException("Missing report metadata.");
        using var doc = JsonDocument.Parse(json);
        JsonElement meta = doc.RootElement.Clone();
        foreach (string field in new[] { "title", "generated", "periodStart", "periodEnd", "timeZone", "detailed", "edge", "notes" })
            if (!meta.TryGetProperty(field, out _)) throw new InvalidDataException("Incomplete report metadata.");
        command.CommandText = "SELECT name,total,columns_json FROM datasets ORDER BY rowid;";
        using var reader = command.ExecuteReader();
        var datasets = new Dictionary<string, PortalDataset>(StringComparer.Ordinal);
        while (reader.Read())
        {
            var columns = JsonSerializer.Deserialize<PortalColumn[]>(reader.GetString(2), JsonOptions)
                ?? throw new InvalidDataException("Missing columns.");
            if (columns.Length == 0) throw new InvalidDataException("Empty columns.");
            string name = reader.GetString(0);
            datasets.Add(name, new(name, reader.GetInt64(1), columns));
        }
        return new(id, path, meta, datasets);
    }

    private object Header(bool detail)
    {
        var result = new Dictionary<string, object?> { ["id"] = Id };
        foreach (var prop in metadata.EnumerateObject())
            if (detail || prop.Name != "notes") result[prop.Name] = prop.Value;
        if (detail) result["datasets"] = datasets.Values.ToArray();
        return result;
    }
    public object Summary() => Header(false);
    public object Detail() => Header(true);
    public Snapshot AtPath(string newPath) => new(Id, newPath, metadata, datasets);
    public PortalDataset Dataset(string name) => datasets.TryGetValue(name, out var dataset)
        ? dataset : throw new ApiError(404, "Dataset not found.");

    private SqliteConnection Open()
    {
        if (IsReparse(Path.GetDirectoryName(path)!) || IsReparse(path))
            throw new ApiError(409, "The report directory changed; restart the portal.");
        return PortalService.OpenReadOnly(path);
    }

    private static SqliteCommand Query(SqliteConnection db, SqliteTransaction tx, PortalDataset dataset,
        PageQuery query, bool count, bool csv)
    {
        var command = db.CreateCommand();
        command.Transaction = tx;
        string filter = query.Search.Length > 0 ? " AND search_text LIKE @search ESCAPE '\\'" : "";
        command.CommandText = (count ? "SELECT count(*)" : "SELECT row_id,cells_json") +
            " FROM report_rows WHERE dataset=@dataset" + filter;
        command.Parameters.AddWithValue("@dataset", dataset.Name);
        if (query.Search.Length > 0)
            command.Parameters.AddWithValue("@search", "%" + query.Search.Replace("\\", "\\\\")
                .Replace("%", "\\%").Replace("_", "\\_") + "%");
        if (!count)
        {
            // Only validated integer JSON offsets and a fixed kind whitelist enter this expression.
            string expression = "json_extract(cells_json,'$[" + query.Sort.ToString(CultureInfo.InvariantCulture) + "]')";
            string kind = dataset.Columns[query.Sort].Kind;
            expression = kind is "num" or "time" ? "CAST(" + expression + " AS NUMERIC)" : "CAST(" + expression + " AS TEXT) COLLATE NOCASE";
            command.CommandText += " ORDER BY " + expression + (query.Descending ? " DESC" : " ASC") + ",row_id ASC";
            if (!csv)
            {
                command.CommandText += " LIMIT @limit OFFSET @offset";
                command.Parameters.AddWithValue("@limit", query.Limit);
                command.Parameters.AddWithValue("@offset", query.Offset);
            }
        }
        command.CommandText += ";";
        return command;
    }

    public object Page(PortalDataset dataset, PageQuery query)
    {
        using var db = Open();
        using var tx = db.BeginTransaction(deferred: true);
        using var count = Query(db, tx, dataset, query, true, false);
        long total = Convert.ToInt64(count.ExecuteScalar(), CultureInfo.InvariantCulture);
        using var command = Query(db, tx, dataset, query, false, false);
        using var reader = command.ExecuteReader();
        var rows = new List<object>(query.Limit);
        while (reader.Read())
        {
            using var doc = JsonDocument.Parse(reader.GetString(1));
            rows.Add(new { id = reader.GetInt64(0), cells = doc.RootElement.Clone() });
        }
        return new { total, offset = query.Offset, limit = query.Limit, rows };
    }

    public async Task Csv(HttpContext context, PortalDataset dataset, PageQuery query)
    {
        using var db = Open();
        using var tx = db.BeginTransaction(deferred: true);
        using var command = Query(db, tx, dataset, query, false, true);
        using var reader = command.ExecuteReader();
        context.Response.ContentType = "text/csv; charset=utf-8";
        context.Response.Headers.ContentDisposition = "attachment; filename=\"ExchangeLogs-" + Id + ".csv\"";
        await context.Response.Body.WriteAsync(new byte[] { 0xef, 0xbb, 0xbf }, context.RequestAborted);
        await using var writer = new StreamWriter(context.Response.Body, new UTF8Encoding(false), 16384, leaveOpen: true);
        await writer.WriteLineAsync(string.Join(";", dataset.Columns.Select(c => Escape(c.Name, true))));
        int batch = 0;
        while (reader.Read())
        {
            context.RequestAborted.ThrowIfCancellationRequested();
            using var doc = JsonDocument.Parse(reader.GetString(1));
            var cells = doc.RootElement.EnumerateArray().ToArray();
            var line = new StringBuilder();
            for (int i = 0; i < dataset.Columns.Length; i++)
            {
                if (i > 0) line.Append(';');
                if (i >= cells.Length) continue;
                var cell = cells[i];
                string text;
                if (cell.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) text = "";
                else if (dataset.Columns[i].Kind == "time" && cell.TryGetInt64(out long seconds))
                    text = DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);
                else text = cell.ValueKind == JsonValueKind.String ? cell.GetString() ?? "" : cell.GetRawText();
                line.Append(Escape(text, cell.ValueKind != JsonValueKind.Number));
            }
            await writer.WriteLineAsync(line.ToString());
            if (++batch % 100 == 0) await writer.FlushAsync(context.RequestAborted);
        }
        await writer.FlushAsync(context.RequestAborted);
    }

    private static string Escape(string text, bool guardFormula)
    {
        if (guardFormula && text.Length > 0)
        {
            string trimmed = text.TrimStart();
            if (text[0] is '\t' or '\r' or '\n' || (trimmed.Length > 0 && trimmed[0] is '=' or '+' or '-' or '@'))
                text = "'" + text;
        }
        return "\"" + text.Replace("\"", "\"\"") + "\"";
    }
}
