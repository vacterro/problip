using System;
using System.IO;
using System.Threading;

namespace ProblipTest
{
    // Compiled (native-IL) test seams for BlipStatsStore's Func fields.
    // PowerShell scriptblock delegates must NEVER be invoked on the store's
    // background persistence worker: a scriptblock needs a PS runspace, and on
    // a foreign thread the invocation throws (or crashes the host). Any seam
    // that can run on the worker (ReadText during worker recovery, CommitFile
    // during worker commits) must be one of these compiled delegates.
    public static class StatsSeams
    {
        // --- ReadText behaviors ---
        public static Func<string, string> ThrowingRead(string message)
        {
            return delegate { throw new IOException(message); };
        }

        public static Func<string, string> RealRead()
        {
            return delegate(string p)
            {
                if (!File.Exists(p)) return null;
                return File.ReadAllText(p);
            };
        }

        // --- CommitFile behaviors ---
        public static Func<string, string, bool> FailingCommit()
        {
            return delegate { return false; };
        }

        public static Func<string, string, bool> RealCommit()
        {
            return delegate(string tempPath, string targetPath)
            {
                try
                {
                    if (File.Exists(targetPath))
                        File.Replace(tempPath, targetPath, null);
                    else
                        File.Move(tempPath, targetPath);
                    return true;
                }
                catch { return false; }
            };
        }

        // Gate-blocked commit: the CommitFileGate seam that blocks the worker
        // deterministically until released, plus the release handle.
        public sealed class BlockGate
        {
            readonly ManualResetEvent Release = new ManualResetEvent(false);
            readonly ManualResetEvent Entered = new ManualResetEvent(false);

            public Func<bool> Gate
            {
                get
                {
                    return delegate
                    {
                        Entered.Set();
                        return Release.WaitOne(30000);   // bounded even if the test dies
                    };
                }
            }

            public bool WaitEntered(int timeoutMs) { return Entered.WaitOne(timeoutMs); }
            public void Open() { Release.Set(); }
        }

        // Background-thread runner for driving a compiled-path method (e.g.
        // BlipStatsStore.Flush via reflection) off the main PS thread WITHOUT
        // ever invoking a PowerShell scriptblock delegate: scriptblocks need a
        // runspace and crash the host when invoked on a foreign thread. The
        // body here is compiled IL only; the reflected target is compiled C#.
        public sealed class ReflectedAction
        {
            readonly Delegate _d;
            readonly object _target;
            readonly object[] _args;
            public ReflectedAction(Delegate d, object target, object[] args)
            {
                _d = d; _target = target; _args = args;
            }
            public void Run()
            {
                try { _d.DynamicInvoke(_args ?? new object[0]); }
                catch { /* best-effort by contract of the wrapped call */ }
            }
            public Action Body { get { return Run; } }
        }

        public sealed class ThreadRunner
        {
            readonly Thread _t;
            public ThreadRunner(Action body)
            {
                _t = new Thread(new ThreadStart(body));
                _t.IsBackground = true;
            }
            public void Start() { _t.Start(); }
            public bool Join(int timeoutMs) { return _t.Join(timeoutMs); }
            public bool IsAlive { get { return _t.IsAlive; } }
        }

        // Compiled monotonic clock: the store's NowMs delegate normally is a
        // PowerShell scriptblock, which cannot run on a foreign thread. The
        // background-flush immutability regression runs Flush on a raw thread,
        // so its NowMs (and LocalNow) must be compiled IL delegates.
        public sealed class MonotonicClock
        {
            long _ms;
            public long Ms { get { return Thread.VolatileRead(ref _ms); } set { Thread.VolatileWrite(ref _ms, value); } }
            public Func<long> Now { get { return delegate { return Ms; }; } }
        }

        // Mutable snapshot clock for the immutable-snapshot regressions: the
        // store's LocalNow delegate normally returns this clock's value; a test
        // CHANGES Value while a flush/recovery sits paused between capture and
        // serialization, so a live-object serialization would produce torn
        // period keys while an immutable capture stays coherent.
        public sealed class MutableClock
        {
            DateTime _value;
            public DateTime Value
            {
                get { return Thread.VolatileRead(ref _storageA) == 1 ? _valueB : _valueA; }
                set { if (Thread.VolatileRead(ref _storageA) == 1) { _valueB = value; } else { _valueA = value; } }
            }
            // Two slots + a parity flag: the reader may be between the slot
            // read and its use while a writer swaps the value. The flag flips
            // BEFORE the new value is used, so a reader racing a swap either
            // sees the complete old value or the complete new one.
            long _storageA; DateTime _valueA; DateTime _valueB;
            public MutableClock() { _valueA = default(DateTime); _valueB = default(DateTime); Thread.VolatileWrite(ref _storageA, 1); }
            public Func<DateTime> Now { get { return delegate { return Value; }; } }
        }

        // Blocking commit for the already-started-I/O limitation regression:
        // this CommitFile delegate blocks AFTER WriteCommitFile has fully
        // entered the physical operation (generation eligibility has already
        // passed -- WriteCommitFile is only invoked post-eligibility). On
        // release it completes the REAL atomic replacement and reports the
        // native success, modelling filesystem I/O that was in flight and
        // then finished. Cancellation is impossible by construction; the
        // regression using this seam must never assert otherwise.
        public sealed class BlockingCommit
        {
            readonly ManualResetEvent _entered = new ManualResetEvent(false);
            readonly ManualResetEvent _release = new ManualResetEvent(false);
            public Func<string, string, bool> Commit
            {
                get
                {
                    return delegate(string tempPath, string targetPath)
                    {
                        _entered.Set();
                        if (!_release.WaitOne(30000)) return false;   // bounded even if the test dies
                        try
                        {
                            if (File.Exists(targetPath))
                                File.Replace(tempPath, targetPath, null);
                            else
                                File.Move(tempPath, targetPath);
                            return true;
                        }
                        catch { return false; }
                    };
                }
            }
            public bool WaitEntered(int timeoutMs) { return _entered.WaitOne(timeoutMs); }
            public void Open() { _release.Set(); }
        }

        // Counting real commit, for asserting exact commit counts.
        public sealed class CountingCommit
        {
            int _count;
            readonly Func<string, string, bool> _inner;

            public CountingCommit() : this(null) { }
            public CountingCommit(Func<string, string, bool> inner) { _inner = inner ?? RealCommit(); }

            public Func<string, string, bool> Commit
            {
                get
                {
                    return delegate(string t, string p)
                    {
                        Interlocked.Increment(ref _count);
                        return _inner(t, p);
                    };
                }
            }

            public int Count { get { return Thread.VolatileRead(ref _count); } }
        }
    }
}
