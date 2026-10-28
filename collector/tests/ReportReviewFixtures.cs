using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;

public static class ReportReviewFixtures
{
    const BindingFlags Hidden = BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Public;

    public static string[] WorkerAndConsumerFailures(Type requestType, string folder)
    {
        var assembly = requestType.Assembly;
        var scratchType = assembly.GetType("ExchangeLogReport.ReportScratch");
        var scratch = Activator.CreateInstance(scratchType, Hidden, null, new object[] { folder, 64L * 1048576 }, null);
        var request = Activator.CreateInstance(requestType);
        requestType.GetField("Parallelism").SetValue(request, 2);
        requestType.GetField("Scratch", Hidden).SetValue(request, scratch);
        var method = assembly.GetType("ExchangeLogReport.ReportBuilder").GetMethod("OrderedWork", BindingFlags.NonPublic | BindingFlags.Static)
            .MakeGenericMethod(typeof(int), typeof(int));
        var messages = new List<string>();
        using (var signal = new ManualResetEventSlim(false))
        {
            Func<int, long> estimate = x => 1;
            Func<int, int> transform = x =>
            {
                if (x == 1) { signal.Wait(); throw new InvalidDataException("secondary worker failure"); }
                return x;
            };
            var sequence = (IEnumerable<int>)method.Invoke(null, new object[] { Enumerable.Range(0, 3), request, estimate, transform, 0L });
            try
            {
                foreach (var value in sequence) { signal.Set(); throw new IOException("primary consumer failure"); }
            }
            catch (IOException error) { messages.Add(error.Message); }
            finally { signal.Set(); }
        }
        var failures = (IEnumerable)scratchType.GetField("WorkerFailures").GetValue(scratch);
        foreach (Exception error in failures) messages.Add(error.Message);
        ((IDisposable)scratch).Dispose();
        return messages.ToArray();
    }

    public static bool IndependentSamplesAndRelease(Type requestType, string folder)
    {
        var assembly = requestType.Assembly;
        var scratchType = assembly.GetType("ExchangeLogReport.ReportScratch");
        var rowsType = assembly.GetType("ExchangeLogReport.ReportRows");
        var scratch = Activator.CreateInstance(scratchType, Hidden, null, new object[] { folder, 64L * 1048576 }, null);
        var rows = Activator.CreateInstance(rowsType, Hidden, null, new object[] { scratch, false }, null);
        var add = rowsType.GetMethod("Add", BindingFlags.NonPublic | BindingFlags.Instance);
        var sample = rowsType.GetMethod("Sample", BindingFlags.NonPublic | BindingFlags.Instance);
        try
        {
            add.Invoke(rows, new object[] { new object[] { 1L, "small value" }, 1000L, 1L, 0 });
            var first = (List<object[]>)sample.Invoke(rows, new object[] { 1L, 1L });
            first[0][1] = new string('x', 1000000);
            var second = (List<object[]>)sample.Invoke(rows, new object[] { 1L, 1L });
            if ((string)second[0][1] != "small value") return false;
            ((IDisposable)rows).Dispose();
            var datasets = (ICollection)scratchType.GetField("_datasets", BindingFlags.NonPublic | BindingFlags.Instance).GetValue(scratch);
            long retained = (long)scratchType.GetField("_retained", BindingFlags.NonPublic | BindingFlags.Instance).GetValue(scratch);
            return datasets.Count == 0 && retained == 0;
        }
        finally { ((IDisposable)rows).Dispose(); ((IDisposable)scratch).Dispose(); }
    }

    public static long[] SortUtc(Type requestType, string folder, bool spill)
    {
        var assembly = requestType.Assembly;
        var scratchType = assembly.GetType("ExchangeLogReport.ReportScratch");
        var rowsType = assembly.GetType("ExchangeLogReport.ReportRows");
        var scratch = Activator.CreateInstance(scratchType, Hidden, null, new object[] { folder, 64L * 1048576 }, null);
        var rows = Activator.CreateInstance(rowsType, Hidden, null, new object[] { scratch, false }, null);
        var add = rowsType.GetMethod("Add", BindingFlags.NonPublic | BindingFlags.Instance);
        try
        {
            add.Invoke(rows, new object[] { new object[] { 10L, "later wall-clock label" }, 2000L, 0L, 0 });
            add.Invoke(rows, new object[] { new object[] { 30L, "earlier UTC" }, 1000L, 0L, 0 });
            if (spill) rowsType.GetMethod("Spill", BindingFlags.NonPublic | BindingFlags.Instance).Invoke(rows, null);
            rowsType.GetMethod("SortByTime", BindingFlags.NonPublic | BindingFlags.Instance).Invoke(rows, null);
            return ((IEnumerable<object[]>)rows).Select(row => (long)row[0]).ToArray();
        }
        finally { ((IDisposable)rows).Dispose(); ((IDisposable)scratch).Dispose(); }
    }
}
