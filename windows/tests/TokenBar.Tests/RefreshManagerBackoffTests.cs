using System;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// 稳态失败退避的纯判定测试（RefreshManager.ShouldSkipTimerRefresh，与 mac 端 failureBackoff 同形）：
    /// 连续全失败 n &gt; 0 轮时，距上次尝试不足 baseInterval × min(2^n, 8) 应跳过本轮定时刷新。
    /// 只对 Timer 触发生效；手动/唤醒/设置刷新不经过该判定。
    /// </summary>
    public class RefreshManagerBackoffTests
    {
        private static readonly TimeSpan OneMinute = TimeSpan.FromMinutes(1);

        [Fact]
        public void NoConsecutiveFailures_NeverSkips()
        {
            // n == 0（上一轮有收获）：哪怕刚刚尝试过也照常刷新
            Assert.False(RefreshManager.ShouldSkipTimerRefresh(0, OneMinute, TimeSpan.Zero));
            Assert.False(RefreshManager.ShouldSkipTimerRefresh(0, TimeSpan.FromMinutes(5), TimeSpan.FromSeconds(1)));
            // 计数为负（防御性输入）同样不退避
            Assert.False(RefreshManager.ShouldSkipTimerRefresh(-1, OneMinute, TimeSpan.Zero));
        }

        [Fact]
        public void OneFailure_SkipsUntilTwiceBaseInterval()
        {
            // n == 1 → 退避 2 × baseInterval
            var baseInterval = TimeSpan.FromMinutes(5);
            Assert.True(RefreshManager.ShouldSkipTimerRefresh(1, baseInterval, TimeSpan.FromMinutes(4)));
            Assert.True(RefreshManager.ShouldSkipTimerRefresh(1, baseInterval, TimeSpan.FromMinutes(9.99)));
            // 边界：正好达到退避间隔不跳过（判定是 elapsed < backoff）
            Assert.False(RefreshManager.ShouldSkipTimerRefresh(1, baseInterval, TimeSpan.FromMinutes(10)));
            Assert.False(RefreshManager.ShouldSkipTimerRefresh(1, baseInterval, TimeSpan.FromMinutes(11)));
        }

        [Fact]
        public void TwoFailures_SkipsUntilFourTimesBaseInterval()
        {
            // n == 2 → 退避 4 × baseInterval
            Assert.True(RefreshManager.ShouldSkipTimerRefresh(2, OneMinute, TimeSpan.FromSeconds(239)));
            Assert.False(RefreshManager.ShouldSkipTimerRefresh(2, OneMinute, TimeSpan.FromMinutes(4)));
        }

        [Fact]
        public void BackoffFactorGrowsThenCapsAtEight()
        {
            // n == 3 → 8 ×；n 继续增长封顶在 8 ×（不会无限拉长）
            Assert.True(RefreshManager.ShouldSkipTimerRefresh(3, OneMinute, TimeSpan.FromMinutes(7.9)));
            Assert.False(RefreshManager.ShouldSkipTimerRefresh(3, OneMinute, TimeSpan.FromMinutes(8)));

            Assert.True(RefreshManager.ShouldSkipTimerRefresh(10, OneMinute, TimeSpan.FromMinutes(7.9)));
            Assert.False(RefreshManager.ShouldSkipTimerRefresh(10, OneMinute, TimeSpan.FromMinutes(8)));

            // 大间隔同样按倍数放大：5min 基础间隔、n=4 → 40min
            var fiveMinutes = TimeSpan.FromMinutes(5);
            Assert.True(RefreshManager.ShouldSkipTimerRefresh(4, fiveMinutes, TimeSpan.FromMinutes(39)));
            Assert.False(RefreshManager.ShouldSkipTimerRefresh(4, fiveMinutes, TimeSpan.FromMinutes(40)));
        }
    }
}
