using System;
using System.Threading;
using System.Threading.Tasks;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// 全量刷新闸门的三个核心机制：互斥抢占、卡死后强制接管、generation 防脏写。
    /// 这是修过多次线上事故（"定时刷新彻底停摆"等）的逻辑，改动前必须先过这里。
    /// </summary>
    public class RefreshGateTests
    {
        [Fact]
        public void SecondBeginWhileBusyIsSkipped()
        {
            var gate = new RefreshGate();

            var (first, gen1, _) = gate.TryBegin();
            Assert.Equal(GateAcquireResult.Acquired, first);
            Assert.True(gate.IsBusy);

            // 上一轮进行中：第二次进入必须被跳过，且不能推进代数
            var (second, _, heldFor) = gate.TryBegin();
            Assert.Equal(GateAcquireResult.Skipped, second);
            Assert.True(gate.IsBusy);
            Assert.Equal(gen1, gate.CurrentGeneration);
            Assert.True(heldFor >= TimeSpan.Zero);
        }

        [Fact]
        public void StaleGateIsTakenOverAndOldRoundCannotReleaseIt()
        {
            // 阈值缩到 50ms 模拟"上一轮卡死"
            var gate = new RefreshGate(TimeSpan.FromMilliseconds(50));

            var (_, gen1, _) = gate.TryBegin();
            Thread.Sleep(120);

            var (result, gen2, heldFor) = gate.TryBegin();
            Assert.Equal(GateAcquireResult.TookOverStale, result);
            Assert.True(gen2 > gen1);
            Assert.True(heldFor > TimeSpan.FromMilliseconds(50));

            // 被抢占的旧轮次结束时不能把新轮次的闸门误清掉
            gate.End(gen1);
            Assert.True(gate.IsBusy);

            // 新轮次自己收闸才释放
            gate.End(gen2);
            Assert.False(gate.IsBusy);
        }

        [Fact]
        public void EndReleasesGateForCurrentGeneration()
        {
            var gate = new RefreshGate();
            var (_, gen, _) = gate.TryBegin();

            gate.End(gen);
            Assert.False(gate.IsBusy);

            // 释放后可以再次进入，代数继续递增
            var (again, gen2, _) = gate.TryBegin();
            Assert.Equal(GateAcquireResult.Acquired, again);
            Assert.Equal(gen + 1, gen2);
        }

        [Fact]
        public void StaleGenerationDiscardsOldRoundResultsOnly()
        {
            var gate = new RefreshGate(TimeSpan.FromMilliseconds(50));
            var (_, gen1, _) = gate.TryBegin();
            Thread.Sleep(120);
            var (_, gen2, _) = gate.TryBegin();

            // 旧轮次的结果必须丢弃；当前轮次与设置页直调（null）放行
            Assert.True(gate.IsStaleGeneration(gen1));
            Assert.False(gate.IsStaleGeneration(gen2));
            Assert.False(gate.IsStaleGeneration(null));
        }

        [Fact]
        public async Task ConcurrentBeginnersAdmitExactlyOne()
        {
            var gate = new RefreshGate();
            var acquired = 0;

            // 模拟定时器（线程池）与手动刷新（UI 线程）同时进入
            var tasks = new Task[16];
            for (var i = 0; i < tasks.Length; i++)
            {
                tasks[i] = Task.Run(() =>
                {
                    var (result, _, _) = gate.TryBegin();
                    if (result == GateAcquireResult.Acquired)
                        Interlocked.Increment(ref acquired);
                });
            }
            await Task.WhenAll(tasks);

            Assert.Equal(1, acquired);
        }
    }
}
