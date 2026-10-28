// =============================================================================
//  Exchange Log Report - engine, part 1: text helpers
// -----------------------------------------------------------------------------
//  Author  : Nicolas Fabert
//  Version : 2.0.0
//  The src\Engine.*.cs files are compiled together by ExchangeLogReport.psm1
//  the first time they are used (and again whenever one of them changes).
//
//  Conventions used by the whole engine
//    - Every time stored in the database is a Unix epoch in MILLISECONDS (UTC).
//    - Exchange writes all its logs in UTC (ISO 8601 "Z" or W3C date + time).
//    - Usage days are calendar days (yyyy-MM-dd) of the report time zone.
// =============================================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace ExchangeLogReport
{
    /// <summary>
    /// Font of the classic Windows console (conhost). The console has no font fallback, so the
    /// module chooses the frame characters from it. Null outside a classic console or on error.
    /// </summary>
    public static class ConsoleFont
    {
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        struct ConsoleFontInfoEx
        {
            public uint Size; public uint Font; public short Width; public short Height; public int Family; public int Weight;
            [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int handle);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetCurrentConsoleFontEx(IntPtr output, bool maximumWindow, ref ConsoleFontInfoEx info);

        public static string FaceName()
        {
            try
            {
                if (Console.IsOutputRedirected || !OperatingSystem.IsWindows()) return null;
                var info = new ConsoleFontInfoEx { Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<ConsoleFontInfoEx>() };
                return GetCurrentConsoleFontEx(GetStdHandle(-11), false, ref info) ? info.FaceName : null;
            }
            catch { return null; }
        }
    }

    /// <summary>
    /// One line of a log file, as bytes in the read buffer (valid until the next line is read). Only the fields
    /// that the parsers use are decoded: most lines are noise and are never turned into a string.
    /// </summary>
    public sealed class LogLine
    {
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, false);
        public byte[] Buffer;
        public int Start, Length;
        public long NextOffset;          // byte offset that follows the line: the resume point

        public int First { get { return Length > 0 ? Buffer[Start] : -1; } }

        public string Text() { return Length <= 0 ? string.Empty : Utf8.GetString(Buffer, Start, Length); }

        /// <summary>The line starts with this ASCII text (case ignored).</summary>
        public bool StartsWith(string ascii)
        {
            if (Length < ascii.Length) return false;
            for (int i = 0; i < ascii.Length; i++)
            {
                int a = Buffer[Start + i], b = ascii[i];
                if (a == b) continue;
                if ((a | 0x20) != (b | 0x20) || (a | 0x20) < 'a' || (a | 0x20) > 'z') return false;
            }
            return true;
        }

        /// <summary>The line contains this ASCII text (case ignored).</summary>
        public bool Contains(string ascii)
        {
            int first = ascii[0] | 0x20, end = Start + Length - ascii.Length;
            for (int p = Start; p <= end; p++)
            {
                if ((Buffer[p] | 0x20) != first) continue;
                int i = 1;
                for (; i < ascii.Length; i++)
                {
                    int a = Buffer[p + i], b = ascii[i];
                    if (a != b && ((a | 0x20) != (b | 0x20) || (a | 0x20) < 'a' || (a | 0x20) > 'z')) break;
                }
                if (i == ascii.Length) return true;
            }
            return false;
        }
    }

    /// <summary>
    /// Reads the complete lines of a log file from a byte offset. The file is opened with full
    /// sharing: Exchange keeps the current log files open for writing. A last line without its
    /// end-of-line is not returned (still being written): it is read again at the next collection.
    /// Each line comes with the byte offset that follows it, which becomes the resume point.
    /// The same LogLine object is returned for every line (no allocation per line).
    /// </summary>
    public static class LogReader
    {
        public static IEnumerable<LogLine> Lines(string path, long offset) { return Lines(path, offset, null); }

        /// <summary>
        /// The same, through the buffer of reuse (one per parse thread): the 1 MB buffer is not allocated again for every file. A buffer
        /// already in use (a file read inside the loop of another) or no reuse: a buffer of its own.
        /// A read that fills the room it was given is followed by a read ahead of the next LineBuffer.AheadSize bytes on the thread pool, while the
        /// lines already read are parsed; the next read takes those bytes first. The file is read in the same order, from the same position, until
        /// a read returns nothing, so the bytes and the lines are the same; a file that a first read does not fill (a small file) is never read ahead.
        /// </summary>
        public static IEnumerable<LogLine> Lines(string path, long offset, LineBuffer reuse)
        {
            bool pooled = reuse != null && !reuse.InUse;
            byte[] buffer = pooled && reuse.Bytes != null ? reuse.Bytes : new byte[LineBuffer.Size];
            byte[] ahead = null;
            if (pooled) reuse.InUse = true;
            try
            {
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1, FileOptions.SequentialScan))
                {
                    Task<int> reading = null;            // the read ahead in progress (into ahead), null: none
                    int aheadStart = 0, aheadLength = 0; // bytes read ahead and not taken yet: ahead[aheadStart..aheadStart+aheadLength)
                    try
                    {
                        if (offset < 0 || offset > fs.Length) offset = 0;
                        fs.Seek(offset, SeekOrigin.Begin);
                        var line = new LogLine { Buffer = buffer };
                        int begin = 0, end = 0;          // unread data: buffer[begin..end)
                        long position = offset;          // file offset of buffer[begin]
                        bool first = offset == 0;
                        while (true)
                        {
                            int nl = end > begin ? Array.IndexOf(buffer, (byte)'\n', begin, end - begin) : -1;
                            if (nl < 0)
                            {
                                // Move the partial line to the start of the buffer (grow it for a very long line), then read more.
                                int pending = end - begin;
                                if (pending > 0 && begin > 0) Buffer.BlockCopy(buffer, begin, buffer, 0, pending);
                                else if (pending == buffer.Length) { Array.Resize(ref buffer, buffer.Length * 2); line.Buffer = buffer; }
                                begin = 0; end = pending;
                                int room = buffer.Length - end, read;
                                bool full;
                                long waitMark = Stopwatch.GetTimestamp();
                                bool ended = false;
                                if (reading != null)
                                {
                                    // The bytes that follow were read ahead: wait for them (the exception of a failed read is thrown here). A read
                                    // ahead that returned nothing is the read that ends the file.
                                    var task = reading;
                                    reading = null;
                                    aheadStart = 0; aheadLength = Math.Max(0, task.GetAwaiter().GetResult());
                                    ended = aheadLength == 0;
                                }
                                if (ended) { read = 0; full = false; }
                                else if (aheadLength > 0)
                                {
                                    // A read ahead shorter than its room is not the end: once its bytes are taken, the next read is made here.
                                    read = Math.Min(room, aheadLength);
                                    Buffer.BlockCopy(ahead, aheadStart, buffer, end, read);
                                    aheadStart += read; aheadLength -= read;
                                    full = aheadLength == 0 && aheadStart == ahead.Length;
                                }
                                else
                                {
                                    read = fs.Read(buffer, end, room);
                                    if (reuse != null) reuse.ReadTicks += Stopwatch.GetTimestamp() - waitMark;
                                    full = read == room;
                                }
                                if (reuse != null) reuse.WaitTicks += Stopwatch.GetTimestamp() - waitMark;
                                if (read <= 0) yield break;
                                if (full)
                                {
                                    // More bytes are likely: read the next ones while these lines are parsed.
                                    if (ahead == null) ahead = pooled && reuse.Ahead != null ? reuse.Ahead : new byte[LineBuffer.AheadSize];
                                    var target = ahead;
                                    aheadStart = 0;
                                    reading = Task.Run(() =>
                                    {
                                        long mark = Stopwatch.GetTimestamp();
                                        int n = fs.Read(target, 0, target.Length);
                                        if (reuse != null) Interlocked.Add(ref reuse.ReadTicks, Stopwatch.GetTimestamp() - mark);
                                        return n;
                                    });
                                }
                                if (first)
                                {
                                    first = false;
                                    if (end + read >= 3 && buffer[0] == 0xEF && buffer[1] == 0xBB && buffer[2] == 0xBF) { begin = 3; position += 3; }
                                }
                                end += read;
                                continue;
                            }
                            int length = nl - begin;
                            if (length > 0 && buffer[nl - 1] == (byte)'\r') length--;
                            line.Buffer = buffer; line.Start = begin; line.Length = length;
                            position += nl + 1 - begin;
                            line.NextOffset = position;
                            begin = nl + 1;
                            yield return line;
                        }
                    }
                    finally
                    {
                        // A read ahead still running (the lines were not all taken, or the parse failed) ends before the file is closed.
                        if (reading != null) { try { reading.Wait(); } catch (Exception) { } }
                    }
                }
            }
            finally
            {
                if (pooled)
                {
                    // A buffer grown for a very long line is kept up to LineBuffer.MaxKept.
                    if (buffer.Length <= LineBuffer.MaxKept) reuse.Bytes = buffer;
                    if (ahead != null) reuse.Ahead = ahead;
                    reuse.InUse = false;
                }
            }
        }
    }

    /// <summary>The read buffers of LogReader.Lines kept from one file to the next by a parse thread (not shared between threads).</summary>
    public sealed class LineBuffer
    {
        internal const int Size = 1 << 20, MaxKept = 8 << 20, AheadSize = Size / 2;
        internal byte[] Bytes;
        internal byte[] Ahead;   // the bytes read ahead (AheadSize), allocated by the first file that is read ahead
        internal bool InUse;
        /// <summary>Stopwatch ticks spent in FileStream.Read by the reads of this thread, ahead ones included (statistics: file reads of the collection).</summary>
        internal long ReadTicks;
        /// <summary>Stopwatch ticks the thread of the lines waited for bytes: its own reads, and the reads ahead not finished when it needed them.</summary>
        internal long WaitTicks;
    }

    /// <summary>
    /// Column names of a log file, read from its "#Fields:" header. HttpProxy, SMTP and message
    /// tracking logs separate fields with commas, IIS (W3C) logs with spaces.
    /// </summary>
    public sealed class FieldMap
    {
        readonly Dictionary<string, int> _map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        public char Separator = ',';
        public string Raw;
        public bool Loaded { get { return _map.Count > 0; } }

        public bool Load(string fieldsLine)
        {
            _map.Clear();
            Raw = null;
            if (string.IsNullOrEmpty(fieldsLine)) return false;
            Raw = fieldsLine;
            string value = fieldsLine.StartsWith("#Fields:", StringComparison.OrdinalIgnoreCase) ? fieldsLine.Substring(8).Trim() : fieldsLine.Trim();
            Separator = value.IndexOf(',') >= 0 ? ',' : ' ';
            var parts = value.Split(Separator);
            for (int i = 0; i < parts.Length; i++)
            {
                string key = parts[i].Trim();
                if (key.Length > 0 && !_map.ContainsKey(key)) _map[key] = i;
            }
            return _map.Count > 0;
        }

        /// <summary>Index of the first column found among the names, -1 when none exists.</summary>
        public int Index(params string[] names)
        {
            foreach (var name in names) { int i; if (_map.TryGetValue(name, out i)) return i; }
            return -1;
        }
    }

    /// <summary>
    /// Splits one line (bytes) into fields without allocating anything: only the fields read with Get are decoded
    /// (HttpProxy lines have more than 70 columns, the engine uses ~25), numbers and times are read from the bytes.
    /// Comma lines follow the CSV rules of Exchange (quotes, doubled quotes).
    /// </summary>
    public sealed class FieldSplitter
    {
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, false);
        byte[] _line = new byte[0];
        int[] _start = new int[128], _end = new int[128];
        bool[] _doubled = new bool[128];
        public int Count;

        void Ensure(int n)
        {
            if (n <= _start.Length) return;
            Array.Resize(ref _start, n * 2); Array.Resize(ref _end, n * 2); Array.Resize(ref _doubled, n * 2);
        }

        public void Split(LogLine line, char separator)
        {
            _line = line.Buffer;
            Count = 0;
            byte sep = (byte)separator;
            int n = line.Start + line.Length, i = line.Start;
            var b = _line;
            if (separator != ',')
            {
                while (true)
                {
                    Ensure(Count + 1);
                    int s = i;
                    int next = i < n ? Array.IndexOf(b, sep, i, n - i) : -1;
                    i = next < 0 ? n : next;
                    _start[Count] = s; _end[Count] = i; _doubled[Count] = false; Count++;
                    if (i >= n) return;
                    i++;
                }
            }
            while (true)
            {
                Ensure(Count + 1);
                if (i < n && b[i] == (byte)'"')
                {
                    int s = i + 1, j = s; bool doubled = false;
                    while (j < n)
                    {
                        if (b[j] == (byte)'"')
                        {
                            if (j + 1 < n && b[j + 1] == (byte)'"') { doubled = true; j += 2; continue; }
                            break;
                        }
                        j++;
                    }
                    _start[Count] = s; _end[Count] = Math.Min(j, n); _doubled[Count] = doubled; Count++;
                    i = j + 1;
                    while (i < n && b[i] != sep) i++;
                }
                else
                {
                    int s = i;
                    int next = i < n ? Array.IndexOf(b, sep, i, n - i) : -1;
                    i = next < 0 ? n : next;
                    _start[Count] = s; _end[Count] = i; _doubled[Count] = false; Count++;
                }
                if (i >= n) return;
                i++;
                if (i == n) { Ensure(Count + 1); _start[Count] = n; _end[Count] = n; _doubled[Count] = false; Count++; return; }
            }
        }

        /// <summary>Field value; null when the column is absent, empty or "-" (W3C empty value).</summary>
        public string Get(int index)
        {
            if (index < 0 || index >= Count) return null;
            int s = _start[index], e = _end[index];
            if (e <= s) return null;
            if (e - s == 1 && _line[s] == (byte)'-') return null;
            string v = Utf8.GetString(_line, s, e - s);
            return _doubled[index] ? v.Replace("\"\"", "\"") : v;
        }

        readonly string[] _cache = new string[16384];

        /// <summary>
        /// Same as Get, for the fields that repeat (accounts, agents, addresses, URLs): the same string is returned for the
        /// same bytes (a small cache per thread), so that a value seen a million times is decoded once.
        /// </summary>
        public string GetCached(int index)
        {
            if (index < 0 || index >= Count) return null;
            int s = _start[index], e = _end[index], n = e - s;
            if (n <= 0) return null;
            if (n == 1 && _line[s] == (byte)'-') return null;
            if (_doubled[index] || n > 512) return Get(index);
            uint h = 2166136261;
            for (int i = s; i < e; i++) h = (h ^ _line[i]) * 16777619;
            int slot = (int)((h ^ (uint)n) & (uint)(_cache.Length - 1));
            string c = _cache[slot];
            if (c != null && c.Length == n)
            {
                int i = 0;
                while (i < n && c[i] == _line[s + i]) i++;
                if (i == n) return c;
            }
            string v = Utf8.GetString(_line, s, n);
            if (v.Length == n) _cache[slot] = v;   // ASCII only: one byte per character
            return v;
        }

        /// <summary>Field value as written (keeps "-", the SMTP disconnect event); null when absent or empty.</summary>
        public string GetRaw(int index)
        {
            if (index < 0 || index >= Count) return null;
            int s = _start[index], e = _end[index];
            return e <= s ? null : Utf8.GetString(_line, s, e - s);
        }

        /// <summary>The field is exactly this ASCII text (no string is created).</summary>
        public bool Is(int index, string ascii)
        {
            if (index < 0 || index >= Count) return false;
            int s = _start[index], e = _end[index];
            if (e - s != ascii.Length) return false;
            for (int i = 0; i < ascii.Length; i++) if (_line[s + i] != ascii[i]) return false;
            return true;
        }

        /// <summary>Whole number of a field (spaces and a sign allowed), else the fallback.</summary>
        public long GetLong(int index, long fallback)
        {
            if (index < 0 || index >= Count) return fallback;
            int s = _start[index], e = _end[index];
            while (s < e && _line[s] == (byte)' ') s++;
            while (e > s && _line[e - 1] == (byte)' ') e--;
            if (s >= e) return fallback;
            bool negative = false;
            if (_line[s] == (byte)'-' || _line[s] == (byte)'+') { negative = _line[s] == (byte)'-'; s++; if (s >= e) return fallback; }
            long v = 0;
            for (int i = s; i < e; i++)
            {
                int d = _line[i] - '0';
                if (d < 0 || d > 9 || v > (long.MaxValue - d) / 10) return fallback;
                v = v * 10 + d;
            }
            return negative ? -v : v;
        }

        public int GetInt(int index, int fallback)
        {
            long v = GetLong(index, long.MinValue);
            return v == long.MinValue || v < int.MinValue || v > int.MaxValue ? fallback : (int)v;
        }

        /// <summary>Time of a field "2026-10-01T08:03:55.018Z" (UTC) in Unix ms.</summary>
        public bool TryTime(int index, out long ms)
        {
            ms = 0;
            if (index < 0 || index >= Count) return false;
            return TimeUtil.TryParseUtc(_line, _start[index], _end[index] - _start[index], out ms);
        }

        /// <summary>Time of a W3C date field and time field ("2026-10-01", "08:03:42", UTC) in Unix ms.</summary>
        public bool TryTime(int dateIndex, int timeIndex, out long ms)
        {
            ms = 0;
            if (dateIndex < 0 || dateIndex >= Count || timeIndex < 0 || timeIndex >= Count) return false;
            int ds = _start[dateIndex], ts = _start[timeIndex];
            if (_end[dateIndex] - ds != 10 || _end[timeIndex] - ts < 8) return false;
            return TimeUtil.TryParseUtc(_line, ds, ts, _end[timeIndex] - ts, out ms);
        }
    }

    /// <summary>
    /// Long texts stored compressed: a BLOB made of one header byte (1) and UTF-8 text compressed with Deflate.
    /// Texts written by an older version stay TEXT: readers accept both.
    /// </summary>
    public static class Packed
    {
        public static byte[] Pack(string text)
        {
            if (text == null) return null;
            var bytes = Encoding.UTF8.GetBytes(text);
            using (var ms = new MemoryStream(bytes.Length / 3 + 16))
            {
                ms.WriteByte(1);
                using (var z = new System.IO.Compression.DeflateStream(ms, System.IO.Compression.CompressionLevel.Fastest, true)) z.Write(bytes, 0, bytes.Length);
                return ms.ToArray();
            }
        }

        /// <summary>
        /// Pack of a text already encoded as UTF-8: the same bytes as Pack of the string those bytes decode to (valid UTF-8), with the bytes
        /// given to Deflate in one write as Pack does.
        /// </summary>
        public static byte[] PackUtf8(ReadOnlySpan<byte> utf8)
        {
            using (var ms = new MemoryStream(utf8.Length / 3 + 16))
            {
                ms.WriteByte(1);
                using (var z = new System.IO.Compression.DeflateStream(ms, System.IO.Compression.CompressionLevel.Fastest, true)) z.Write(utf8);
                return ms.ToArray();
            }
        }

        /// <summary>Keep short or incompressible values as TEXT; the header counts towards the stored size.</summary>
        public static object Adaptive(string text)
        {
            if (text == null) return null;
            int length = Encoding.UTF8.GetByteCount(text);
            if (length < 200) return text;
            byte[] packed = Pack(text);
            return packed.Length < length ? (object)packed : text;
        }

        public static string Text(object value)
        {
            if (value == null || value is DBNull) return null;
            object unpacked = Unpack(value);
            if (unpacked is string) return (string)unpacked;
            throw new InvalidDataException("Expected TEXT or a recognised packed text BLOB.");
        }

        /// <summary>The text of a value read from the database: a packed BLOB is decompressed, anything else is returned as is.</summary>
        public static object Unpack(object value)
        {
            var b = value as byte[];
            if (b == null || b.Length == 0 || b[0] != 1) return value;
            using (var input = new MemoryStream(b, 1, b.Length - 1))
            using (var z = new System.IO.Compression.DeflateStream(input, System.IO.Compression.CompressionMode.Decompress))
            using (var output = new MemoryStream(b.Length * 4))
            {
                z.CopyTo(output);
                return Encoding.UTF8.GetString(output.GetBuffer(), 0, (int)output.Length);
            }
        }
    }

    /// <summary>Time conversions. Parsing is done by hand: it runs once per log line.</summary>
    public static class TimeUtil
    {
        static int Digits(string s, int start, int count)
        {
            int v = 0;
            for (int i = start; i < start + count; i++)
            {
                char c = s[i];
                if (c < '0' || c > '9') return -1;
                v = v * 10 + (c - '0');
            }
            return v;
        }

        /// <summary>"2026-10-01T08:03:55.018Z" or "2026-10-01 08:03:42" (UTC) to Unix ms.</summary>
        public static bool TryParseUtc(string s, out long ms)
        {
            ms = 0;
            if (s == null || s.Length < 19) return false;
            int y = Digits(s, 0, 4), mo = Digits(s, 5, 2), d = Digits(s, 8, 2), h = Digits(s, 11, 2), mi = Digits(s, 14, 2), se = Digits(s, 17, 2);
            if (y < 1900 || mo < 1 || mo > 12 || d < 1 || d > 31 || h < 0 || h > 23 || mi < 0 || mi > 59 || se < 0 || se > 60) return false;
            int frac = 0, p = 19, digits = 0;
            if (p < s.Length && s[p] == '.')
            {
                p++;
                while (p < s.Length && s[p] >= '0' && s[p] <= '9') { if (digits < 3) { frac = frac * 10 + (s[p] - '0'); digits++; } p++; }
                while (digits < 3) { frac *= 10; digits++; }
            }
            try { ms = new DateTimeOffset(y, mo, d, h, mi, Math.Min(se, 59), frac, TimeSpan.Zero).ToUnixTimeMilliseconds(); return true; }
            catch (ArgumentOutOfRangeException) { return false; }
        }

        static int Digits(byte[] s, int start, int count)
        {
            int v = 0;
            for (int i = start; i < start + count; i++)
            {
                int c = s[i] - '0';
                if (c < 0 || c > 9) return -1;
                v = v * 10 + c;
            }
            return v;
        }

        /// <summary>Unix ms of a UTC date and time (fields already checked); false for an impossible date.</summary>
        static bool Compose(int y, int mo, int d, int h, int mi, int se, int frac, out long ms)
        {
            ms = 0;
            if (y < 1900 || y > 9999 || mo < 1 || mo > 12 || d < 1 || d > DateTime.DaysInMonth(y, mo) || h < 0 || h > 23 || mi < 0 || mi > 59 || se < 0 || se > 60) return false;
            // Days since 1970-01-01 (civil calendar, H. Hinnant's algorithm): no DateTime per line.
            int yy = mo <= 2 ? y - 1 : y;
            int era = yy / 400, yoe = yy - era * 400, mp = (mo + 9) % 12;
            int doy = (153 * mp + 2) / 5 + d - 1, doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
            long days = (long)era * 146097 + doe - 719468;
            ms = ((days * 24 + h) * 60 + mi) * 60000L + Math.Min(se, 59) * 1000L + frac;
            return true;
        }

        static int Fraction(byte[] s, int p, int end)
        {
            int frac = 0, digits = 0;
            if (p < end && s[p] == (byte)'.')
            {
                p++;
                while (p < end && s[p] >= (byte)'0' && s[p] <= (byte)'9') { if (digits < 3) { frac = frac * 10 + (s[p] - '0'); digits++; } p++; }
                while (digits < 3) { frac *= 10; digits++; }
            }
            return frac;
        }

        /// <summary>Same as TryParseUtc(string), on the bytes of a field.</summary>
        public static bool TryParseUtc(byte[] s, int start, int length, out long ms)
        {
            ms = 0;
            if (length < 19) return false;
            return Compose(Digits(s, start, 4), Digits(s, start + 5, 2), Digits(s, start + 8, 2), Digits(s, start + 11, 2), Digits(s, start + 14, 2), Digits(s, start + 17, 2),
                Fraction(s, start + 19, start + length), out ms);
        }

        /// <summary>W3C date ("2026-10-01") and time ("08:03:42") fields, UTC.</summary>
        public static bool TryParseUtc(byte[] s, int dateStart, int timeStart, int timeLength, out long ms)
        {
            return Compose(Digits(s, dateStart, 4), Digits(s, dateStart + 5, 2), Digits(s, dateStart + 8, 2), Digits(s, timeStart, 2), Digits(s, timeStart + 3, 2), Digits(s, timeStart + 6, 2),
                Fraction(s, timeStart + 8, timeStart + timeLength), out ms);
        }

        /// <summary>Wall-clock time of the zone to Unix ms (gaps of summer time are moved forward one hour).</summary>
        public static long LocalToUnixMs(DateTime local, TimeZoneInfo zone)
        {
            local = DateTime.SpecifyKind(local, DateTimeKind.Unspecified);
            if (zone.IsInvalidTime(local)) local = local.AddHours(1);
            return new DateTimeOffset(local, zone.GetUtcOffset(local)).ToUnixTimeMilliseconds();
        }

        public static DateTime ToLocal(long utcMs, TimeZoneInfo zone)
        {
            return TimeZoneInfo.ConvertTime(DateTimeOffset.FromUnixTimeMilliseconds(utcMs), zone).DateTime;
        }

        /// <summary>Local wall-clock time as seconds since 1970 "as if UTC": the HTML report displays it with getUTC*.</summary>
        public static long ToLocalSeconds(long utcMs, TimeZoneInfo zone)
        {
            var offset = zone.GetUtcOffset(DateTimeOffset.FromUnixTimeMilliseconds(utcMs));
            return (utcMs + (long)offset.TotalMilliseconds) / 1000;
        }

        public static string Format(long utcMs, TimeZoneInfo zone, string format)
        {
            return ToLocal(utcMs, zone).ToString(format, CultureInfo.InvariantCulture);
        }

        public static string Day(long utcMs, TimeZoneInfo zone) { return Format(utcMs, zone, "yyyy-MM-dd"); }

        public static string Duration(double seconds)
        {
            if (seconds < 0) seconds = 0;
            var t = TimeSpan.FromSeconds(seconds);
            if (t.TotalDays >= 1) return string.Format(CultureInfo.InvariantCulture, "{0} d {1:00} h", (int)t.TotalDays, t.Hours);
            if (t.TotalHours >= 1) return string.Format(CultureInfo.InvariantCulture, "{0} h {1:00} min", (int)t.TotalHours, t.Minutes);
            if (t.TotalMinutes >= 1) return string.Format(CultureInfo.InvariantCulture, "{0} min {1:00} s", t.Minutes, t.Seconds);
            return string.Format(CultureInfo.InvariantCulture, "{0:0.#} s", t.TotalSeconds);
        }
    }

    /// <summary>Local day of a time; cached per quarter of an hour (time zone offsets change on these boundaries).</summary>
    public sealed class DayCache
    {
        readonly TimeZoneInfo _zone;
        long _bucket = long.MinValue;
        string _day;
        public DayCache(TimeZoneInfo zone) { _zone = zone; }
        public string Day(long utcMs)
        {
            long b = utcMs / 900000;
            if (b != _bucket) { _bucket = b; _day = TimeUtil.Day(utcMs, _zone); }
            return _day;
        }
    }

    /// <summary>Identities and client types.</summary>
    public static class Identity
    {
        /// <summary>Authenticated user, lower case ("domain\sam", UPN or SID); null when anonymous.</summary>
        public static string User(string raw)
        {
            if (string.IsNullOrWhiteSpace(raw) || raw == "-") return null;
            string s = raw.Trim().Trim('"');
            // "DOMAIN\" without account name: a client that sent an empty user name.
            if (s.Length == 0 || s[s.Length - 1] == '\\') return null;
            return s.ToLowerInvariant();
        }

        /// <summary>SMTP address of an HttpProxy anchor mailbox ("SMTP:user@contoso.com", "Smtp~..."), else null.</summary>
        public static string Mailbox(string anchor)
        {
            if (string.IsNullOrWhiteSpace(anchor)) return null;
            string s = anchor.Trim();
            if (s.Length > 5 && s.StartsWith("smtp", StringComparison.OrdinalIgnoreCase) && (s[4] == ':' || s[4] == '~')) s = s.Substring(5);
            else if (s.IndexOf('~') >= 0 || s.IndexOf(':') >= 0) return null;
            return s.IndexOf('@') > 0 ? s.ToLowerInvariant() : null;
        }

        /// <summary>Account name without domain: "contoso\healthmailboxb4" and "healthmailboxb4@contoso.com" give "healthmailboxb4".</summary>
        public static string Bare(string identity)
        {
            if (string.IsNullOrEmpty(identity)) return identity;
            string s = identity;
            int b = s.LastIndexOf('\\'); if (b >= 0) s = s.Substring(b + 1);
            int a = s.IndexOf('@'); if (a > 0) s = s.Substring(0, a);
            return s;
        }

        /// <summary>Address between angle brackets of an SMTP command ("MAIL FROM:&lt;a@b&gt; SIZE=1").</summary>
        public static string SmtpAddress(string value)
        {
            if (value == null) return null;
            int lt = value.IndexOf('<'), gt = lt >= 0 ? value.IndexOf('>', lt + 1) : -1;
            string s = lt >= 0 && gt > lt ? value.Substring(lt + 1, gt - lt - 1) : value.Trim().Split(' ')[0];
            return s.Trim().ToLowerInvariant();
        }

        public static string Protocol(string urlStem)
        {
            if (string.IsNullOrEmpty(urlStem)) return "Other";
            string s = urlStem.ToLowerInvariant();
            if (s.StartsWith("/owa")) return "Owa";
            if (s.StartsWith("/ecp")) return "Ecp";
            if (s.StartsWith("/ews")) return "Ews";
            if (s.StartsWith("/mapi")) return "Mapi";
            if (s.StartsWith("/rpc")) return "RpcHttp";
            if (s.StartsWith("/microsoft-server-activesync")) return "Eas";
            if (s.StartsWith("/autodiscover")) return "Autodiscover";
            if (s.StartsWith("/oab")) return "Oab";
            if (s.StartsWith("/powershell")) return "PowerShell";
            if (s.StartsWith("/api")) return "Rest";
            return "Other";
        }

        /// <summary>Client family of a user agent, for the usage views.</summary>
        public static string Client(string userAgent)
        {
            if (string.IsNullOrWhiteSpace(userAgent)) return "Unknown";
            string u = userAgent.ToLowerInvariant();
            if (u.Contains("macoutlook") || u.Contains("outlook-mac")) return "Outlook for Mac";
            if (u.Contains("outlook-ios") || u.Contains("outlook-android") || u.Contains("outlookmobile")) return "Outlook mobile";
            if (u.Contains("microsoft office") || u.Contains("microsoft outlook") || u.Contains("outlook/")) return "Outlook (Windows)";
            if (u.Contains("msrpc")) return "Outlook (RPC/HTTP)";
            if (u.Contains("winrm")) return "PowerShell (WinRM)";
            if (u.Contains("activesync") || u.StartsWith("apple-") || u.Contains("iphone") || u.Contains("ipad") || u.Contains("android")) return "Mobile (ActiveSync)";
            if (u.Contains("teams") || u.Contains("skype")) return "Teams / Skype";
            if (u.Contains("exchangeservicesclient") || u.Contains("ews")) return "EWS application";
            if (u.Contains("mozilla")) return "Browser";
            if (u == "imap4" || u == "pop3") return u.ToUpperInvariant() + " client";
            string first = userAgent.Split('/', ' ')[0];
            return first.Length > 30 ? first.Substring(0, 30) : first;
        }

        public static string Cap(string value, int max)
        {
            return value == null || value.Length <= max ? value : value.Substring(0, max) + "...";
        }

        /// <summary>Value of one parameter of a URL query ("?Cmd=Sync&amp;User=x"), null when absent or empty.</summary>
        public static string QueryValue(string query, string name)
        {
            if (string.IsNullOrEmpty(query)) return null;
            int i = 0;
            while (i < query.Length)
            {
                int start = i;
                if (query[start] == '?' || query[start] == '&') start++;
                int end = query.IndexOf('&', start);
                if (end < 0) end = query.Length;
                int eq = query.IndexOf('=', start);
                if (eq > start && eq < end && eq - start == name.Length && string.Compare(query, start, name, 0, name.Length, StringComparison.OrdinalIgnoreCase) == 0)
                {
                    string v = query.Substring(eq + 1, end - eq - 1);
                    int semi = v.IndexOf(';');
                    if (semi >= 0) v = v.Substring(0, semi);
                    try { v = Uri.UnescapeDataString(v.Replace('+', ' ')); } catch (UriFormatException) { }
                    return v.Length == 0 ? null : v;
                }
                i = end + 1;
            }
            return null;
        }

        /// <summary>Mailbox GUID of "MailboxGuid~&lt;guid&gt;" (HttpProxy anchor) or "&lt;guid&gt;@domain" (MAPI MailboxId), lower case.</summary>
        public static string MailboxGuid(string value)
        {
            if (string.IsNullOrEmpty(value)) return null;
            string s = value.Trim();
            int tilde = s.IndexOf('~');
            if (tilde >= 0) s = s.Substring(tilde + 1);
            int at = s.IndexOf('@');
            if (at > 0) s = s.Substring(0, at);
            Guid g;
            return Guid.TryParse(s, out g) ? g.ToString("D") : null;
        }

        /// <summary>Part of a ";"-separated "KEY:value" list ("R:{..}:1;RT:Connect;CI:{..}:1"), null when absent.</summary>
        public static string Token(string list, string key)
        {
            if (string.IsNullOrEmpty(list)) return null;
            foreach (var part in list.Split(';'))
            {
                if (part.Length > key.Length && part[key.Length] == ':' && part.StartsWith(key, StringComparison.OrdinalIgnoreCase))
                {
                    string v = part.Substring(key.Length + 1).Trim();
                    return v.Length == 0 || v == "<null>" ? null : v;
                }
            }
            return null;
        }

        /// <summary>MAPI client instance ("{5B43EE0C-...}:1" or "5b43ee0c-...:1") as a lower-case GUID.</summary>
        public static string ClientInstance(string value)
        {
            if (string.IsNullOrEmpty(value)) return null;
            string s = value.Trim().TrimStart('{');
            int end = s.IndexOfAny(new[] { '}', ':' });
            if (end > 0) s = s.Substring(0, end);
            Guid g;
            return Guid.TryParse(s, out g) ? g.ToString("D") : null;
        }

        /// <summary>Short upper-case server name: "exch01.contoso.com" gives "EXCH01".</summary>
        public static string ServerName(string fqdn)
        {
            if (string.IsNullOrWhiteSpace(fqdn)) return null;
            string s = fqdn.Trim();
            int dot = s.IndexOf('.');
            if (dot > 0) s = s.Substring(0, dot);
            return s.ToUpperInvariant();
        }

        /// <summary>Address without port: "192.168.1.11:28717" gives "192.168.1.11", "[::1]:25" gives "::1".</summary>
        public static string Host(string endpoint)
        {
            if (string.IsNullOrEmpty(endpoint)) return endpoint;
            string s = endpoint.Trim();
            if (s.StartsWith("[")) { int close = s.IndexOf(']'); return close > 0 ? s.Substring(1, close - 1) : s; }
            int colon = s.LastIndexOf(':');
            return colon > 0 && s.IndexOf(':') == colon ? s.Substring(0, colon) : s;
        }

        /// <summary>
        /// Peer of an SMTP transaction: the lower-case address without port; null when no endpoint was observed. Schema 11 stores it as
        /// smtp_client.remote_host (a pure function of the endpoint text, shared by the collector, the migration, Serve and the verifier).
        /// </summary>
        public static string RemoteHost(string endpoint)
        {
            string value = Host(endpoint);
            return string.IsNullOrEmpty(value) ? null : value.ToLowerInvariant();
        }
    }
}
