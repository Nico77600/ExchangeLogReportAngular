// =============================================================================
//  Exchange Log Report - ordered CPU workers and estimated report-buffer budget
//  Author: Nicolas Fabert
// =============================================================================
using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.ExceptionServices;
using System.Threading.Tasks;

namespace ExchangeLogReport
{
    internal sealed class ReportErrors
    {
        readonly List<Exception> _errors = new List<Exception>();
        public void Add(Exception error) { _errors.Add(error); }
        // Cleanup is attempted completely; no failure is replaced or swallowed.
        public void Run(Action action)
        {
            try { action(); }
            catch (Exception error) { _errors.Add(error); }
        }
        public void ThrowIfAny()
        {
            if (_errors.Count == 1) ExceptionDispatchInfo.Capture(_errors[0]).Throw();
            if (_errors.Count > 1) throw new AggregateException("Report operation and cleanup failed.", _errors);
        }
    }

    internal static class ReportMemory
    {
        public static long Bytes(object value)
        {
            if (value == null) return 8;
            if (value is TranscriptRef) return 32;
            var s = value as string; if (s != null) return 32L + s.Length * 2L;
            var strings = value as string[]; if (strings != null) return 32L + strings.Sum(x => Bytes(x));
            var array = value as object[]; if (array != null) return 32L + array.Sum(x => Bytes(x));
            var rows = value as IEnumerable<object[]>; if (rows != null) return 32L + rows.Sum(x => Bytes(x));
            return 32;
        }
    }

    public static partial class ReportBuilder
    {
        sealed class Pending<T> { public Task<T> Task; public long Bytes; }

        // Database readers and output writers stay on the caller; only independent CPU work runs in parallel.
        static IEnumerable<TOut> OrderedWork<TIn, TOut>(IEnumerable<TIn> source, ReportRequest q, Func<TIn, long> estimate, Func<TIn, TOut> transform, long inputBytes = 0)
        {
            var pending = new Queue<Pending<TOut>>();
            long bytes = 0;
            try
            {
                foreach (var item in source)
                {
                    long cost = Math.Max(1, estimate(item));
                    while (pending.Count > 0 && (pending.Count >= q.EffectiveParallelism || cost > q.WorkingBudgetBytes - inputBytes - bytes))
                    {
                        var next = pending.Dequeue();
                        try { yield return next.Task.GetAwaiter().GetResult(); }
                        finally { bytes -= next.Bytes; q.Scratch.Working(inputBytes + bytes); }
                    }
                    if (q.EffectiveParallelism == 1)
                    {
                        q.Scratch.Working(inputBytes + cost);
                        try { yield return transform(item); }
                        finally { q.Scratch.Working(inputBytes); }
                    }
                    else
                    {
                        bytes += cost;
                        q.Scratch.Working(inputBytes + bytes);
                        pending.Enqueue(new Pending<TOut> { Bytes = cost, Task = Task.Run(() => transform(item)) });
                    }
                }
                while (pending.Count > 0)
                {
                    var next = pending.Dequeue();
                    try { yield return next.Task.GetAwaiter().GetResult(); }
                    finally { bytes -= next.Bytes; q.Scratch.Working(inputBytes + bytes); }
                }
            }
            finally
            {
                var all = Task.WhenAll(pending.Select(x => x.Task));
                try { all.GetAwaiter().GetResult(); }
                // The owning report surfaces these after the primary failure, including consumer failures.
                catch (Exception error)
                {
                    if (all.Exception != null) q.Scratch.WorkerFailures.AddRange(all.Exception.InnerExceptions);
                    else q.Scratch.WorkerFailures.Add(error);
                }
                finally { q.Scratch.Working(0); }
            }
        }
    }
}
