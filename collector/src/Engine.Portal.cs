using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    public static partial class ReportBuilder
    {
        static string PortalJson(Action<Utf8JsonWriter> write)
        {
            using (var stream = new MemoryStream())
            {
                using (var writer = new Utf8JsonWriter(stream)) write(writer);
                return Encoding.UTF8.GetString(stream.ToArray());
            }
        }

        static void PortalSearch(StringBuilder text, object value)
        {
            if (value == null) return;
            var array = value as object[];
            if (array != null) { foreach (var cell in array) PortalSearch(text, cell); return; }
            var rows = value as IEnumerable<object[]>;
            if (rows != null) { foreach (var row in rows) PortalSearch(text, row); return; }
            // Search is a summary, not an unbounded duplicate of transcript/detail text.
            if (text.Length >= 32768) return;
            string part = Convert.ToString(value, CultureInfo.InvariantCulture);
            if (part == null) return;
            text.Append(part, 0, Math.Min(part.Length, 32768 - text.Length)).Append(' ');
        }

        static ReportFile WritePortal(Store store, ReportRequest q, List<Dataset> sets, ReportResult result)
        {
            string target = Path.GetFullPath(q.PortalDatabasePath);
            string partial = target + ".building";
            if (File.Exists(target) || File.Exists(partial)) throw new IOException("Portal snapshot already exists.");
            var cache = new TranscriptCache(store, Math.Min(16L * 1048576, q.WorkingBudgetBytes / 8));
            long count = 0;
            try
            {
                using (var db = new SqliteConnection(new SqliteConnectionStringBuilder {
                    DataSource = partial, Mode = SqliteOpenMode.ReadWriteCreate, Pooling = false
                }.ToString()))
                {
                    db.Open();
                    using (var setup = db.CreateCommand())
                    {
                        setup.CommandText = @"PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;
CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE datasets(name TEXT PRIMARY KEY,columns_json TEXT NOT NULL,total INTEGER NOT NULL);
CREATE TABLE report_rows(dataset TEXT NOT NULL,row_id INTEGER NOT NULL,cells_json TEXT NOT NULL,search_text TEXT NOT NULL,
 PRIMARY KEY(dataset,row_id)) WITHOUT ROWID;";
                        setup.ExecuteNonQuery();
                    }
                    using (var tx = db.BeginTransaction())
                    {
                        using (var meta = db.CreateCommand())
                        {
                            meta.Transaction = tx;
                            meta.CommandText = "INSERT INTO metadata(key,value) VALUES(@k,@v);";
                            meta.Parameters.Add("@k", SqliteType.Text);
                            meta.Parameters.Add("@v", SqliteType.Text);
                            meta.Parameters["@k"].Value = "portal_format";
                            meta.Parameters["@v"].Value = "1";
                            meta.ExecuteNonQuery();
                            meta.Parameters["@k"].Value = "report";
                            meta.Parameters["@v"].Value = PortalJson(w => {
                                w.WriteStartObject();
                                w.WriteString("title", q.Title);
                                w.WriteString("generated", q.Generated);
                                w.WriteString("periodStart", TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds(q.StartMs), q.Zone).ToString("o", CultureInfo.InvariantCulture));
                                w.WriteString("periodEnd", TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds(q.EndMs), q.Zone).ToString("o", CultureInfo.InvariantCulture));
                                w.WriteString("timeZone", q.TimeZoneName);
                                w.WriteBoolean("detailed", q.Detailed);
                                w.WriteBoolean("edge", q.Edge);
                                w.WritePropertyName("notes"); WriteValue(w, result.Notes.ToArray());
                                w.WriteEndObject();
                            });
                            meta.ExecuteNonQuery();
                        }
                        using (var dataset = db.CreateCommand())
                        using (var insert = db.CreateCommand())
                        {
                            dataset.Transaction = tx;
                            dataset.CommandText = "INSERT INTO datasets(name,columns_json,total) VALUES(@n,@c,@t);";
                            dataset.Parameters.Add("@n", SqliteType.Text);
                            dataset.Parameters.Add("@c", SqliteType.Text);
                            dataset.Parameters.Add("@t", SqliteType.Integer);
                            insert.Transaction = tx;
                            insert.CommandText = "INSERT INTO report_rows(dataset,row_id,cells_json,search_text) VALUES(@d,@i,@c,@s);";
                            insert.Parameters.Add("@d", SqliteType.Text);
                            insert.Parameters.Add("@i", SqliteType.Integer);
                            insert.Parameters.Add("@c", SqliteType.Text);
                            insert.Parameters.Add("@s", SqliteType.Text);
                            insert.Prepare();
                            foreach (var d in sets)
                            {
                                dataset.Parameters["@n"].Value = d.Name;
                                dataset.Parameters["@c"].Value = PortalJson(w => {
                                    w.WriteStartArray();
                                    foreach (var c in d.Columns) {
                                        w.WriteStartObject(); w.WriteString("name", c.Name);
                                        w.WriteString("kind", c.Kind); w.WriteBoolean("grid", c.Grid); w.WriteEndObject();
                                    }
                                    w.WriteEndArray();
                                });
                                dataset.Parameters["@t"].Value = d.Rows.Count;
                                dataset.ExecuteNonQuery();
                                insert.Parameters["@d"].Value = d.Name;
                                long rowId = 0;
                                foreach (var source in d.Rows)
                                {
                                    object[] row = cache.Row(source);
                                    var search = new StringBuilder();
                                    for (int i = 0; i < row.Length && i < d.Columns.Count; i++)
                                        if (d.Columns[i].Grid) PortalSearch(search, row[i]);
                                    insert.Parameters["@i"].Value = ++rowId;
                                    insert.Parameters["@c"].Value = PortalJson(w => WriteValue(w, row));
                                    insert.Parameters["@s"].Value = search.ToString();
                                    insert.ExecuteNonQuery();
                                    count++;
                                }
                            }
                        }
                        tx.Commit();
                    }
                }
                File.Move(partial, target);
                return new ReportFile { Path = target, Dataset = "portal", Rows = count, Bytes = new FileInfo(target).Length };
            }
            finally { cache.Clear(); }
        }
    }
}
