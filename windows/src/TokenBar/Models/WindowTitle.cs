using System;
using System.Globalization;
using TokenBar.I18n;

namespace TokenBar.Models
{
    /// <summary>
    /// 额度窗口标题的语义类型。取代「中文标题字符串当翻译 key」的旧机制：
    /// 服务层只声明语义（FiveHour / Monthly / Connected…），中文规范标题与英文翻译
    /// 都由 WindowTitle + LocalizationManager 统一给出，服务改措辞不再静默破坏英文界面。
    /// 新增种类时必须同时在 LocalizationManager 登记 zh/en 文案（WindowTitleTests 会兜底拦截漏译）。
    /// </summary>
    public enum WindowTitleKind
    {
        FiveHour,
        FiveHourCompute,
        Weekly,
        Monthly,
        SevenDays,
        TpmRate,
        TpmRemaining,
        RpmRate,
        RpmRequest,
        TokenRate,
        AccountBalance,
        AccountAvailableBalance,
        KeyQuota,
        TokenPlan,
        AiStudioQuota,
        /// <summary>所有「XX 连接正常」「API 连接状态」类状态窗；Argument 可选，为中文里的连接主体（如 "KIMI"）。</summary>
        Connected,
        /// <summary>可用模型数量状态窗；Argument = 数量字符串。</summary>
        AvailableModels,
        /// <summary>Argument = 原样显示的动态标题（如按模型圈定的周额度窗口，标题是模型显示名）。</summary>
        Custom
    }

    /// <summary>C# 无关联值枚举的替代：Kind + 可选 Argument 的只读结构。</summary>
    public readonly struct WindowTitle : IEquatable<WindowTitle>
    {
        public WindowTitleKind Kind { get; }

        /// <summary>Connected 的连接主体（可空）、AvailableModels 的数量字符串、Custom 的原文；其余种类为 null。</summary>
        public string? Argument { get; }

        private WindowTitle(WindowTitleKind kind, string? argument)
        {
            Kind = kind;
            Argument = argument;
        }

        // ---------- 静态工厂 ----------
        public static WindowTitle FiveHour => new(WindowTitleKind.FiveHour, null);
        public static WindowTitle FiveHourCompute => new(WindowTitleKind.FiveHourCompute, null);
        public static WindowTitle Weekly => new(WindowTitleKind.Weekly, null);
        public static WindowTitle Monthly => new(WindowTitleKind.Monthly, null);
        public static WindowTitle SevenDays => new(WindowTitleKind.SevenDays, null);
        public static WindowTitle TpmRate => new(WindowTitleKind.TpmRate, null);
        public static WindowTitle TpmRemaining => new(WindowTitleKind.TpmRemaining, null);
        public static WindowTitle RpmRate => new(WindowTitleKind.RpmRate, null);
        public static WindowTitle RpmRequest => new(WindowTitleKind.RpmRequest, null);
        public static WindowTitle TokenRate => new(WindowTitleKind.TokenRate, null);
        public static WindowTitle AccountBalance => new(WindowTitleKind.AccountBalance, null);
        public static WindowTitle AccountAvailableBalance => new(WindowTitleKind.AccountAvailableBalance, null);
        public static WindowTitle KeyQuota => new(WindowTitleKind.KeyQuota, null);
        public static WindowTitle TokenPlan => new(WindowTitleKind.TokenPlan, null);
        public static WindowTitle AiStudioQuota => new(WindowTitleKind.AiStudioQuota, null);
        public static WindowTitle Connected => new(WindowTitleKind.Connected, null);
        /// <summary>带主体的连接状态窗：中文显示「{subject} 连接正常」，英文统一 "API Connected"。</summary>
        public static WindowTitle ConnectedFor(string subject) => new(WindowTitleKind.Connected, subject);
        public static WindowTitle AvailableModels(int count) =>
            new(WindowTitleKind.AvailableModels, count.ToString(CultureInfo.InvariantCulture));
        public static WindowTitle Custom(string title) => new(WindowTitleKind.Custom, title);

        /// <summary>规范中文标题。与 LocalizationManager.WinTitle* 的 zh 分支一一对应（WindowTitleTests 断言一致）。</summary>
        public string ZhTitle => Kind switch
        {
            WindowTitleKind.FiveHour => "5小时额度",
            WindowTitleKind.FiveHourCompute => "5小时算力额度",
            WindowTitleKind.Weekly => "每周额度",
            WindowTitleKind.Monthly => "月度额度",
            WindowTitleKind.SevenDays => "7天周期额度",
            WindowTitleKind.TpmRate => "TPM 速率配额",
            WindowTitleKind.TpmRemaining => "TPM 速率剩余",
            WindowTitleKind.RpmRate => "RPM 速率配额",
            WindowTitleKind.RpmRequest => "RPM 请求速率",
            WindowTitleKind.TokenRate => "Token 速率配额",
            WindowTitleKind.AccountBalance => "账户余额",
            WindowTitleKind.AccountAvailableBalance => "账户可用余额",
            WindowTitleKind.KeyQuota => "Key 可用额度",
            WindowTitleKind.TokenPlan => "Token Plan 额度",
            WindowTitleKind.AiStudioQuota => "AI Studio 配额",
            WindowTitleKind.Connected => ConnectedZhTitle,
            WindowTitleKind.AvailableModels => $"可用模型 ({Argument}个)",
            WindowTitleKind.Custom => Argument ?? string.Empty,
            _ => Argument ?? string.Empty
        };

        /// <summary>
        /// 带主体连接标题的规范中文：ASCII 主体（KIMI/OpenRouter/Anthropic API 等）用空格分隔，
        /// 中文主体（接入点/接口）直接连排——与迁移前各服务的原文逐字一致（mac 端同规则）。
        /// </summary>
        private string ConnectedZhTitle
        {
            get
            {
                if (string.IsNullOrEmpty(Argument)) return "API 连接正常";
                var separator = Argument![0] <= 127 ? " " : "";
                return $"{Argument}{separator}连接正常";
            }
        }

        /// <summary>按当前界面语言取标题：中文即 ZhTitle，英文走 LocalizationManager 登记的翻译。</summary>
        public string Localized
        {
            get
            {
                var i18n = LocalizationManager.Instance;
                return Kind switch
                {
                    WindowTitleKind.FiveHour => i18n.WinTitleFiveHour,
                    WindowTitleKind.FiveHourCompute => i18n.WinTitleFiveHourCompute,
                    WindowTitleKind.Weekly => i18n.WinTitleWeekly,
                    WindowTitleKind.Monthly => i18n.WinTitleMonthly,
                    WindowTitleKind.SevenDays => i18n.WinTitleSevenDays,
                    WindowTitleKind.TpmRate => i18n.WinTitleTpmRate,
                    WindowTitleKind.TpmRemaining => i18n.WinTitleTpmRemaining,
                    WindowTitleKind.RpmRate => i18n.WinTitleRpmRate,
                    WindowTitleKind.RpmRequest => i18n.WinTitleRpmRequest,
                    WindowTitleKind.TokenRate => i18n.WinTitleTokenRate,
                    WindowTitleKind.AccountBalance => i18n.WinTitleAccountBalance,
                    WindowTitleKind.AccountAvailableBalance => i18n.WinTitleAccountAvailableBalance,
                    WindowTitleKind.KeyQuota => i18n.WinTitleKeyQuota,
                    WindowTitleKind.TokenPlan => i18n.WinTitleTokenPlan,
                    WindowTitleKind.AiStudioQuota => i18n.WinTitleAiStudioQuota,
                    WindowTitleKind.Connected => Argument == null
                        ? i18n.WinTitleConnected
                        // 中文走 ZhTitle 的主体分隔规则，保证 zh 模式 Localized == ZhTitle
                        : (i18n.IsChinese ? ConnectedZhTitle : string.Format(i18n.WinTitleConnectedSubject, Argument)),
                    WindowTitleKind.AvailableModels => string.Format(i18n.WinTitleAvailableModels, Argument),
                    WindowTitleKind.Custom => Argument ?? string.Empty,
                    _ => Argument ?? string.Empty
                };
            }
        }

        /// <summary>
        /// 卡片角标的周期语义：5小时窗→「5小时」、月度→「每月」、每周/7天→「每周」，
        /// 其余（速率 / 余额 / 状态 / 动态模型名）返回 null，由调用方回退槽位默认角标。
        /// 与旧版按标题 Contains("5小时"/"月"/"周"/"7天") 的推断结果完全一致。
        /// </summary>
        public string? BadgePeriod => Kind switch
        {
            WindowTitleKind.FiveHour or WindowTitleKind.FiveHourCompute => LocalizationManager.Instance.FiveHourWindow,
            WindowTitleKind.Monthly => LocalizationManager.Instance.MonthlyWindow,
            WindowTitleKind.Weekly or WindowTitleKind.SevenDays => LocalizationManager.Instance.WeeklyWindow,
            _ => null
        };

        // ---------- 相等性 ----------
        public bool Equals(WindowTitle other) =>
            Kind == other.Kind && string.Equals(Argument, other.Argument, StringComparison.Ordinal);

        public override bool Equals(object? obj) => obj is WindowTitle other && Equals(other);

        public override int GetHashCode() =>
            Argument == null ? (int)Kind : HashCode.Combine(Kind, Argument);

        public static bool operator ==(WindowTitle left, WindowTitle right) => left.Equals(right);
        public static bool operator !=(WindowTitle left, WindowTitle right) => !left.Equals(right);

        public override string ToString() => ZhTitle;
    }
}
