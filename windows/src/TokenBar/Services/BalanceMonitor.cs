using System;
using System.Collections.Generic;
using TokenBar.I18n;
using TokenBar.Models;
using TokenBar.Tray;

namespace TokenBar.Services
{
    /// <summary>
    /// 余额窗口的展示辅助状态（较上次差值 + 低余额提醒状态机）与托盘气泡，进程内有效。
    /// 从 RefreshManager.ProcessBalance 原样提取：两段 lock 的划分、BalanceHistoryStore
    /// 的调用时机、阈值 → 1.2× 复位逻辑、气泡文案与 Dispatcher 投递都与原实现逐字节一致。
    ///
    /// 低余额状态机的判定抽成纯函数 <see cref="EvaluateAlert"/>，可独立单测。
    /// </summary>
    internal sealed class BalanceMonitor
    {
        private readonly object _balanceLock = new();
        private readonly Dictionary<string, decimal> _lastBalance = new();
        private readonly HashSet<string> _balanceAlerted = new();

        /// <summary>
        /// 低余额状态机的纯判定（不碰任何状态）：
        /// - 低于阈值且未提醒过 → 触发一次气泡；已提醒过 → 静默；
        /// - 达到阈值 1.2 倍及以上 → 解除武装（下次再低于阈值可重新触发）；
        /// - 介于 [阈值, 1.2×阈值) 之间 → 什么都不做：既不重复提醒，也不提前复位。
        /// </summary>
        internal static (bool Fire, bool Disarm) EvaluateAlert(decimal amount, decimal threshold, bool alreadyAlerted)
        {
            if (amount < threshold) return (!alreadyAlerted, false);
            if (amount >= threshold * 1.2m) return (false, true);
            return (false, false);
        }

        /// <summary>
        /// 推进某个 providerKey 的提醒状态机，返回是否应弹一次气泡。
        /// 与原实现的 `_balanceAlerted.Add / Remove` 语义逐字等价。
        /// </summary>
        internal bool RegisterBalanceAlert(string providerKey, decimal amount, decimal threshold)
        {
            lock (_balanceLock)
            {
                var (fire, disarm) = EvaluateAlert(amount, threshold, _balanceAlerted.Contains(providerKey));
                if (fire) _balanceAlerted.Add(providerKey);
                else if (disarm) _balanceAlerted.Remove(providerKey);
                return fire;
            }
        }

        /// <summary>
        /// 余额窗口刷新成功后的统一处理：
        /// 1) 记录与上次刷新的差值（内存）；2) 写入本地历史并计算"预计可用天数"；
        /// 3) 低余额时触发一次托盘气泡提醒，恢复到阈值 1.2 倍以上后重新武装。
        /// </summary>
        public void Process(string providerKey, string displayName, TokenWindow? window, decimal threshold)
        {
            if (window == null || window.Kind != TokenWindowKind.Balance || !window.BalanceAmount.HasValue) return;
            var amount = window.BalanceAmount.Value;

            lock (_balanceLock)
            {
                if (_lastBalance.TryGetValue(providerKey, out var prev))
                {
                    window.LastDelta = amount - prev;
                }
                _lastBalance[providerKey] = amount;
            }

            BalanceHistoryStore.Record(providerKey, amount);
            window.ForecastDays = BalanceHistoryStore.GetForecastDays(providerKey, amount);

            if (threshold <= 0) return;

            var fire = RegisterBalanceAlert(providerKey, amount, threshold);

            if (fire)
            {
                var i18n = LocalizationManager.Instance;
                var title = i18n.LowBalanceTitle;
                var body = string.Format(i18n.LowBalanceBody, displayName, window.BalanceFormatted);
                var app = System.Windows.Application.Current;
                if (app != null && app.Dispatcher != null)
                {
                    app.Dispatcher.InvokeAsync(() => TrayIconManager.Instance?.ShowBalloon(title, body));
                }
                else
                {
                    TrayIconManager.Instance?.ShowBalloon(title, body);
                }
            }
        }

        /// <summary>自定义厂商被删除时清掉它的差值与提醒状态（与原 RemoveCustomProvider 的 lock 块等价）</summary>
        public void Forget(string providerKey)
        {
            lock (_balanceLock)
            {
                _lastBalance.Remove(providerKey);
                _balanceAlerted.Remove(providerKey);
            }
        }
    }
}
