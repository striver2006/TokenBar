using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// 低余额提醒状态机（BalanceMonitor）：低于阈值只触发一次气泡，
    /// 余额回升到阈值 1.2 倍及以上才重新武装；[阈值, 1.2×阈值) 之间既不重复提醒也不复位。
    /// 只测纯判定与状态推进，不触碰托盘/历史存储。
    /// </summary>
    public class BalanceMonitorTests
    {
        // ---------- 纯函数判定 ----------

        [Fact]
        public void BelowThresholdFiresOnlyWhenNotYetAlerted()
        {
            Assert.Equal((Fire: true, Disarm: false), BalanceMonitor.EvaluateAlert(amount: 5m, threshold: 10m, alreadyAlerted: false));
            // 已提醒过：仍低于阈值也不重复触发
            Assert.Equal((Fire: false, Disarm: false), BalanceMonitor.EvaluateAlert(amount: 5m, threshold: 10m, alreadyAlerted: true));
        }

        [Fact]
        public void AtOrJustAboveThresholdDoesNothing()
        {
            // 恰好等于阈值：不算低余额，也不复位
            Assert.Equal((Fire: false, Disarm: false), BalanceMonitor.EvaluateAlert(amount: 10m, threshold: 10m, alreadyAlerted: true));
            // [阈值, 1.2×阈值)：不重复提醒，也不提前解除武装
            Assert.Equal((Fire: false, Disarm: false), BalanceMonitor.EvaluateAlert(amount: 11.9m, threshold: 10m, alreadyAlerted: true));
        }

        [Fact]
        public void AtOrAboveResetBandDisarms()
        {
            // 恰好 1.2×阈值：复位（下次再低于阈值可重新触发）
            Assert.Equal((Fire: false, Disarm: true), BalanceMonitor.EvaluateAlert(amount: 12m, threshold: 10m, alreadyAlerted: true));
            Assert.Equal((Fire: false, Disarm: true), BalanceMonitor.EvaluateAlert(amount: 100m, threshold: 10m, alreadyAlerted: false));
        }

        // ---------- 实例级状态推进（与原 _balanceAlerted 集合语义等价） ----------

        [Fact]
        public void AlertFiresOnceUntilResetToBandAboveThreshold()
        {
            var monitor = new BalanceMonitor();

            // 首次低于阈值：触发
            Assert.True(monitor.RegisterBalanceAlert("deepseek", amount: 5m, threshold: 10m));
            // 仍低于阈值：不重复触发
            Assert.False(monitor.RegisterBalanceAlert("deepseek", amount: 4m, threshold: 10m));
            // 回升到 [阈值, 1.2×阈值)：不复位，再次跌破仍不触发
            Assert.False(monitor.RegisterBalanceAlert("deepseek", amount: 11m, threshold: 10m));
            Assert.False(monitor.RegisterBalanceAlert("deepseek", amount: 6m, threshold: 10m));
            // 回升到 1.2×阈值以上：重新武装
            Assert.False(monitor.RegisterBalanceAlert("deepseek", amount: 12m, threshold: 10m));
            // 再次跌破：重新触发一次
            Assert.True(monitor.RegisterBalanceAlert("deepseek", amount: 7m, threshold: 10m));
            Assert.False(monitor.RegisterBalanceAlert("deepseek", amount: 6m, threshold: 10m));
        }

        [Fact]
        public void ProviderKeysAreTrackedIndependently()
        {
            var monitor = new BalanceMonitor();

            Assert.True(monitor.RegisterBalanceAlert("kimi", amount: 1m, threshold: 10m));
            // 另一个 provider 首次低于阈值：独立触发
            Assert.True(monitor.RegisterBalanceAlert("openrouter", amount: 2m, threshold: 5m));
            Assert.False(monitor.RegisterBalanceAlert("kimi", amount: 1m, threshold: 10m));
        }
    }
}
