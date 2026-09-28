using System;
using System.Threading;
using System.Threading.Tasks;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// 单厂商超时隔离机制：预算内完成 / 取消后返回 / 不响应取消被放弃 / 同步抛错。
    /// "一个厂商挂起拖垮整轮刷新、闸门被占死"是历史线上事故，改动前必须先过这里。
    /// </summary>
    public class ProviderBudgetRunnerTests
    {
        private static readonly TimeSpan Budget = TimeSpan.FromMilliseconds(100);
        private static readonly TimeSpan Grace = TimeSpan.FromMilliseconds(100);

        [Fact]
        public async Task FastBodyCompletes()
        {
            var result = await ProviderBudgetRunner.RunAsync(_ => Task.CompletedTask, Budget, Grace);
            Assert.Equal(ProviderRunOutcome.Completed, result.Outcome);
            Assert.Null(result.Error);
        }

        [Fact]
        public async Task BodyHonoringCancellationTimesOut()
        {
            // 模拟正常 HTTP 服务：ct 取消后很快抛 OperationCanceledException
            var result = await ProviderBudgetRunner.RunAsync(
                async ct => await Task.Delay(TimeSpan.FromSeconds(30), ct),
                Budget, Grace);

            Assert.Equal(ProviderRunOutcome.TimedOut, result.Outcome);
            Assert.IsType<OperationCanceledException>(result.Error);
        }

        [Fact]
        public async Task BodyIgnoringCancellationIsAbandoned()
        {
            // 模拟不响应取消的路径（子进程等）：预算+宽限到期后放弃等待，
            // 调用方据此做超时收尾（IsLoading 复位），不会被拖死。
            var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var result = await ProviderBudgetRunner.RunAsync(
                async _ => await release.Task, Budget, Grace);

            Assert.Equal(ProviderRunOutcome.Abandoned, result.Outcome);

            release.SetResult();   // 收尾，避免测试进程挂着未完成任务
        }

        [Fact]
        public async Task ThrowingBodyIsFaulted()
        {
            var result = await ProviderBudgetRunner.RunAsync(
                _ => throw new InvalidOperationException("boom"), Budget, Grace);

            Assert.Equal(ProviderRunOutcome.Faulted, result.Outcome);
            Assert.IsType<InvalidOperationException>(result.Error);
        }

        [Fact]
        public async Task AsyncBodyFailureIsFaulted()
        {
            var result = await ProviderBudgetRunner.RunAsync(
                async _ => { await Task.Yield(); throw new InvalidOperationException("late boom"); },
                Budget, Grace);

            Assert.Equal(ProviderRunOutcome.Faulted, result.Outcome);
            Assert.IsType<InvalidOperationException>(result.Error);
        }

        [Fact]
        public async Task TokenIsCancelledAfterBudget()
        {
            using var observed = new CancellationTokenSource();
            var sawCancellation = false;

            var bodyTask = ProviderBudgetRunner.RunAsync(async ct =>
            {
                try
                {
                    await Task.Delay(TimeSpan.FromSeconds(30), ct);
                }
                catch (OperationCanceledException)
                {
                    sawCancellation = true;
                    throw;
                }
            }, Budget, Grace);

            var result = await bodyTask;
            Assert.Equal(ProviderRunOutcome.TimedOut, result.Outcome);
            Assert.True(sawCancellation);
        }
    }
}
