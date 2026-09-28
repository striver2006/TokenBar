using System;
using System.Threading;
using System.Threading.Tasks;

namespace TokenBar.Services
{
    /// <summary>
    /// fire-and-forget 的统一出口：`_ = SomeAsync()` 会把异常变成无人观察的
    /// TaskScheduler.UnobservedTaskException（进程不崩，但排查时毫无痕迹），
    /// 一旦将来给这些调用传入可取消 token，还会批量产生未观察的取消异常。
    /// FireAndForget 只补一个「失败必留日志」的续接，不改变调用方的时序语义
    /// （仍然是发起后立即返回，不等待完成）。
    /// </summary>
    public static class TaskFireAndForgetExtensions
    {
        public static void FireAndForget(this Task task, string context)
        {
            task.ContinueWith(
                t => Log.Error("lifecycle",
                    $"fire-and-forget 任务失败 context={context}: {t.Exception?.GetBaseException()}"),
                CancellationToken.None,
                TaskContinuationOptions.OnlyOnFaulted,
                TaskScheduler.Default);
        }
    }
}
