using System;
using System.Threading;

namespace TokenBar.Services
{
    /// <summary>TryBegin 的三种结果：正常抢到 / 跳过（上一轮进行中）/ 上一轮卡死后强制抢占。</summary>
    internal enum GateAcquireResult
    {
        Acquired,
        Skipped,
        TookOverStale
    }

    /// <summary>
    /// 全量刷新的互斥闸门 + 轮次代数。从 RefreshManager 原样提取（行为不变），
    /// 目的是让「闸门抢占 / generation 丢弃 / 只有当前轮次能收闸门」这三个
    /// 修过多次线上事故的机制可以被单测覆盖。
    ///
    /// 语义：
    /// - 定时器回调在线程池线程、手动刷新在 UI 线程，无锁 check-then-set 会让两者
    ///   同时通过检查并发跑两轮，所以用 CAS 抢占；
    /// - 上一轮卡死超过 staleThreshold 时强制接管（否则之后每次触发都被静默丢弃，
    ///   即"定时刷新彻底停摆"事故的成因）；
    /// - 每轮分配递增 generation，被抢占的旧轮次结束时不能把新轮次的闸门误清掉，
    ///   旧轮次的结果也不能写回（IsStaleGeneration）。
    /// </summary>
    internal sealed class RefreshGate
    {
        /// <summary>默认抢占阈值。有了单厂商超时隔离后一轮最多约 35s 返回，
        /// 90s 纯粹是兜底：防住子进程这类不响应取消的路径。</summary>
        public static readonly TimeSpan DefaultStaleThreshold = TimeSpan.FromSeconds(90);

        private readonly TimeSpan _staleThreshold;
        private int _refreshing;          // 0 = 空闲，1 = 刷新中
        private long _startedAtTicks;     // 本轮开始时刻（UTC ticks，0 表示空闲）
        private long _generation;         // 轮次代数

        public RefreshGate(TimeSpan? staleThreshold = null)
        {
            _staleThreshold = staleThreshold ?? DefaultStaleThreshold;
        }

        public bool IsBusy => Volatile.Read(ref _refreshing) == 1;

        public long CurrentGeneration => Volatile.Read(ref _generation);

        /// <summary>
        /// 尝试开始一轮。返回 Acquired/TookOverStale 时携带本轮 generation（End 与
        /// IsStaleGeneration 都要用）；Skipped 时携带已进行轮次的持有时长供日志用。
        /// </summary>
        public (GateAcquireResult Result, long Generation, TimeSpan HeldFor) TryBegin()
        {
            if (Interlocked.CompareExchange(ref _refreshing, 1, 0) != 0)
            {
                var startedTicks = Volatile.Read(ref _startedAtTicks);
                var elapsed = startedTicks == 0
                    ? TimeSpan.Zero
                    : TimeSpan.FromTicks(DateTime.UtcNow.Ticks - startedTicks);

                if (startedTicks != 0 && elapsed > _staleThreshold)
                {
                    // 闸门已经是 1，无需再 CAS，直接接管这一轮。
                    return (GateAcquireResult.TookOverStale, BeginRound(), elapsed);
                }

                return (GateAcquireResult.Skipped, CurrentGeneration, elapsed);
            }

            return (GateAcquireResult.Acquired, BeginRound(), TimeSpan.Zero);
        }

        private long BeginRound()
        {
            Volatile.Write(ref _startedAtTicks, DateTime.UtcNow.Ticks);
            return Interlocked.Increment(ref _generation);
        }

        /// <summary>收闸。只有仍然是"当前那一轮"才释放；被抢占的旧轮次结束时什么都不做。</summary>
        public void End(long generation)
        {
            if (Volatile.Read(ref _generation) == generation)
            {
                Volatile.Write(ref _startedAtTicks, 0);
                Volatile.Write(ref _refreshing, 0);
            }
        }

        /// <summary>
        /// 结果是否来自已被抢占的旧轮次。generation 为 null 表示不是整轮刷新的一部分
        /// （设置页直接触发），始终允许写回。
        /// </summary>
        public bool IsStaleGeneration(long? generation)
        {
            if (!generation.HasValue) return false;
            return Volatile.Read(ref _generation) != generation.Value;
        }
    }
}
