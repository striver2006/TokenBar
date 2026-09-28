using System;
using System.Threading;
using System.Threading.Tasks;

namespace TokenBar.Services
{
    /// <summary>单厂商刷新的结束方式。</summary>
    internal enum ProviderRunOutcome
    {
        /// <summary>body 正常返回</summary>
        Completed,
        /// <summary>body 同步抛出（参数校验之类），没进入等待</summary>
        StartFailed,
        /// <summary>预算到期、ct 取消后 body 很快返回（OperationCanceledException）</summary>
        TimedOut,
        /// <summary>body 抛了非取消异常</summary>
        Faulted,
        /// <summary>预算 + 宽限到期仍未返回，放弃等待（调用方需做超时收尾）</summary>
        Abandoned
    }

    /// <summary>RunAsync 的结果：结束方式 + 异常（供调用方记日志）。</summary>
    internal readonly struct ProviderRunResult
    {
        public ProviderRunOutcome Outcome { get; }
        public Exception? Error { get; }

        public ProviderRunResult(ProviderRunOutcome outcome, Exception? error = null)
        {
            Outcome = outcome;
            Error = error;
        }
    }

    /// <summary>
    /// 给单个厂商的刷新套一层独立超时。从 RefreshManager.RunProviderAsync 原样提取
    /// （行为不变），使超时收尾机制可被单测覆盖。
    ///
    /// 这是"一个厂商挂起就拖垮整轮刷新"的解药：Task.WhenAll 会等待全部任务，
    /// 以前任何一个厂商卡住都会让 RefreshAllAsync 迟迟不返回，闸门被占住，
    /// 之后每一次定时触发和手动刷新都被静默丢弃。
    ///
    /// 预算到期时通过 CancellationToken 真正取消底层 HTTP 请求（各服务把 ct 传到
    /// HttpClient.SendAsync），而不只是放弃等待。
    /// </summary>
    internal static class ProviderBudgetRunner
    {
        public static async Task<ProviderRunResult> RunAsync(
            Func<CancellationToken, Task> body,
            TimeSpan budget,
            TimeSpan grace)
        {
            using var cts = new CancellationTokenSource(budget);

            Task work;
            try
            {
                work = body(cts.Token);
            }
            catch (Exception ex)
            {
                return new ProviderRunResult(ProviderRunOutcome.StartFailed, ex);
            }

            // 兜底等待：ct 取消后各服务应很快抛 OperationCanceledException 返回；
            // 子进程等不响应取消的路径再多给 grace，之后放弃等待（进程已由服务自行 Kill）。
            using var graceCts = new CancellationTokenSource();
            var delay = Task.Delay(budget + grace, graceCts.Token);
            var winner = await Task.WhenAny(work, delay).ConfigureAwait(false);

            if (winner == work)
            {
                graceCts.Cancel();   // 回收 Task.Delay 的定时器，避免堆积
                try
                {
                    await work.ConfigureAwait(false);
                    return new ProviderRunResult(ProviderRunOutcome.Completed);
                }
                catch (OperationCanceledException ex)
                {
                    return new ProviderRunResult(ProviderRunOutcome.TimedOut, ex);
                }
                catch (Exception ex)
                {
                    return new ProviderRunResult(ProviderRunOutcome.Faulted, ex);
                }
            }

            return new ProviderRunResult(ProviderRunOutcome.Abandoned);
        }
    }
}
