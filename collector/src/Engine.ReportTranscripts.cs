// =============================================================================
//  Exchange Log Report - compact message links and deferred SMTP transcript text
//  Author: Nicolas Fabert
// =============================================================================
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Microsoft.Data.Sqlite;

namespace ExchangeLogReport
{
    public static partial class ReportBuilder
    {
        sealed class MessageSmtpLinks : IDisposable
        {
            readonly ReportScratch _scratch;
            readonly ReportRows _rows;
            readonly string _groups;
            readonly SqliteCommand _lookup, _insert;
            string _lastId;
            long _lastGroup;

            public MessageSmtpLinks(ReportScratch scratch)
            {
                _scratch = scratch;
                _rows = new ReportRows(scratch, staged: true);
                _groups = "m" + scratch.NewId();
                using (var c = scratch.Command("CREATE TABLE " + _groups + "(id INTEGER PRIMARY KEY, message_id TEXT COLLATE EXL_REPORT_ID UNIQUE);"))
                    c.ExecuteNonQuery();
                _lookup = scratch.Own(scratch.Command("SELECT id FROM " + _groups + " WHERE message_id=@m;"));
                _lookup.Parameters.Add("@m", SqliteType.Text);
                _lookup.Prepare();
                _insert = scratch.Own(scratch.Command("INSERT INTO " + _groups + "(message_id) VALUES(@m);"));
                _insert.Parameters.Add("@m", SqliteType.Text);
                _insert.Prepare();
            }

            long Group(string id, bool create)
            {
                if (string.Equals(id, _lastId, StringComparison.OrdinalIgnoreCase)) return _lastGroup;
                _lookup.Parameters["@m"].Value = id;
                object value = _lookup.ExecuteScalar();
                if ((value == null || value is DBNull) && create)
                {
                    _insert.Parameters["@m"].Value = id;
                    _insert.ExecuteNonQuery();
                    value = _lookup.ExecuteScalar();
                }
                _lastId = id; _lastGroup = value == null || value is DBNull ? 0 : Convert.ToInt64(value, CultureInfo.InvariantCulture);
                return _lastGroup;
            }

            public void Add(object[] row) { _rows.Add(row, L(row[1]), Group(S(row[0]), true)); }
            public List<object[]> Read(string id)
            {
                long group = Group(id, false);
                return group == 0 ? new List<object[]>() : _rows.ReadGroup(group);
            }

            public void Dispose()
            {
                var errors = new ReportErrors();
                errors.Run(_lookup.Dispose);
                errors.Run(_insert.Dispose);
                _scratch.Forget(_lookup); _scratch.Forget(_insert);
                errors.Run(_rows.Dispose);
                errors.Run(() => { using (var c = _scratch.Command("DROP TABLE " + _groups + ";")) c.ExecuteNonQuery(); });
                errors.ThrowIfAny();
            }
        }

        sealed class TranscriptCache
        {
            sealed class Entry { public long Id, Bytes; public string Text; }
            readonly Store _store;
            readonly Dictionary<long, LinkedListNode<Entry>> _entries = new Dictionary<long, LinkedListNode<Entry>>();
            readonly LinkedList<Entry> _recent = new LinkedList<Entry>();
            long _bytes;
            public readonly long LimitBytes;
            public long Reads { get; private set; }
            public long DecodedBytes { get; private set; }

            public TranscriptCache(Store store, long limit) { _store = store; LimitBytes = limit; }

            public string Get(long id)
            {
                LinkedListNode<Entry> node;
                if (_entries.TryGetValue(id, out node))
                {
                    _recent.Remove(node); _recent.AddLast(node);
                    return node.Value.Text;
                }
                string text = null;
                foreach (var row in Rows(_store, "SELECT transcript FROM smtp_transaction WHERE id=@id;", new Dictionary<string, object> { { "@id", id } }))
                    text = S(row[0]);
                Reads++;
                long bytes = ReportMemory.Bytes(text) + 128;
                if (text != null) DecodedBytes += text.Length * 2L;
                if (bytes <= LimitBytes)
                {
                    while (_bytes + bytes > LimitBytes && _recent.Count > 0)
                    {
                        var old = _recent.First;
                        _recent.RemoveFirst(); _entries.Remove(old.Value.Id); _bytes -= old.Value.Bytes;
                    }
                    node = _recent.AddLast(new Entry { Id = id, Text = text, Bytes = bytes });
                    _entries[id] = node; _bytes += bytes;
                }
                return text;
            }

            object Resolve(object value)
            {
                var reference = value as TranscriptRef;
                if (reference != null) return Get(reference.Id);
                var array = value as object[];
                if (array != null) return array.Select(x => Resolve(x)).ToArray();
                var rows = value as IEnumerable<object[]>;
                if (rows != null) return rows.Select(x => (object[])Resolve(x)).ToList();
                return value;
            }

            public object[] Row(object[] row) { return (object[])Resolve(row); }
            public void Clear() { _entries.Clear(); _recent.Clear(); _bytes = 0; }
        }

        static void ReferenceTranscripts(IEnumerable<object[]> rows, int slot)
        {
            foreach (var row in rows) if (row[slot] is long) row[slot] = new TranscriptRef((long)row[slot]);
        }
    }
}
