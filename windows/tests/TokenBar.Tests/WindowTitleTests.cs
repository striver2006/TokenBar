using System;
using TokenBar.I18n;
using TokenBar.Models;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>WindowTitle 语义标题的翻译登记表测试：遍历全部 WindowTitleKind，
    /// 中文模式必须回规范中文，英文模式必须已登记翻译（Custom 原样显示除外），
    /// 新增 Kind 忘记补翻译时这里直接失败，消灭静默漏译。</summary>
    public sealed class WindowTitleTests : IDisposable
    {
        private readonly AppLanguage _originalLanguage;

        public WindowTitleTests()
        {
            _originalLanguage = LocalizationManager.Instance.CurrentLanguage;
        }

        public void Dispose()
        {
            LocalizationManager.Instance.SetLanguage(_originalLanguage);
        }

        private static WindowTitle Sample(WindowTitleKind kind) => kind switch
        {
            WindowTitleKind.FiveHour => WindowTitle.FiveHour,
            WindowTitleKind.FiveHourCompute => WindowTitle.FiveHourCompute,
            WindowTitleKind.Weekly => WindowTitle.Weekly,
            WindowTitleKind.Monthly => WindowTitle.Monthly,
            WindowTitleKind.SevenDays => WindowTitle.SevenDays,
            WindowTitleKind.TpmRate => WindowTitle.TpmRate,
            WindowTitleKind.TpmRemaining => WindowTitle.TpmRemaining,
            WindowTitleKind.RpmRate => WindowTitle.RpmRate,
            WindowTitleKind.RpmRequest => WindowTitle.RpmRequest,
            WindowTitleKind.TokenRate => WindowTitle.TokenRate,
            WindowTitleKind.AccountBalance => WindowTitle.AccountBalance,
            WindowTitleKind.AccountAvailableBalance => WindowTitle.AccountAvailableBalance,
            WindowTitleKind.KeyQuota => WindowTitle.KeyQuota,
            WindowTitleKind.TokenPlan => WindowTitle.TokenPlan,
            WindowTitleKind.AiStudioQuota => WindowTitle.AiStudioQuota,
            WindowTitleKind.Connected => WindowTitle.Connected,
            WindowTitleKind.AvailableModels => WindowTitle.AvailableModels(12),
            WindowTitleKind.Custom => WindowTitle.Custom("Opus 4.5"),
            _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, "未覆盖的 WindowTitleKind")
        };

        [Fact]
        public void ChineseMode_AllKinds_LocalizedEqualsCanonicalZhTitle()
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            foreach (WindowTitleKind kind in Enum.GetValues<WindowTitleKind>())
            {
                var title = Sample(kind);
                Assert.False(string.IsNullOrWhiteSpace(title.ZhTitle), $"{kind} 缺规范中文标题");
                Assert.Equal(title.ZhTitle, title.Localized);
            }
        }

        [Fact]
        public void EnglishMode_AllKinds_HaveRegisteredTranslation()
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.En);
            foreach (WindowTitleKind kind in Enum.GetValues<WindowTitleKind>())
            {
                var title = Sample(kind);
                Assert.False(string.IsNullOrWhiteSpace(title.Localized), $"{kind} 缺英文翻译");
                // Custom 是原样显示的动态标题（模型名等），不参与翻译登记
                if (kind != WindowTitleKind.Custom)
                    Assert.NotEqual(title.ZhTitle, title.Localized);
            }
        }

        [Fact]
        public void ConnectedWithSubject_KeepsZhSubjectButEnIsGeneric()
        {
            var title = WindowTitle.ConnectedFor("KIMI");
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            Assert.Equal("KIMI 连接正常", title.ZhTitle);
            Assert.Equal("KIMI 连接正常", title.Localized);
            LocalizationManager.Instance.SetLanguage(AppLanguage.En);
            Assert.Equal("API Connected", title.Localized);
        }

        [Fact]
        public void AvailableModels_FormatsCountInBothLanguages()
        {
            var title = WindowTitle.AvailableModels(7);
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            Assert.Equal("可用模型 (7个)", title.Localized);
            LocalizationManager.Instance.SetLanguage(AppLanguage.En);
            Assert.Equal("Available Models (7)", title.Localized);
        }

        [Fact]
        public void BadgePeriod_MatchesLegacyContainsInference()
        {
            var i18n = LocalizationManager.Instance;
            Assert.Equal(i18n.FiveHourWindow, WindowTitle.FiveHour.BadgePeriod);
            Assert.Equal(i18n.FiveHourWindow, WindowTitle.FiveHourCompute.BadgePeriod);
            Assert.Equal(i18n.MonthlyWindow, WindowTitle.Monthly.BadgePeriod);
            Assert.Equal(i18n.WeeklyWindow, WindowTitle.Weekly.BadgePeriod);
            Assert.Equal(i18n.WeeklyWindow, WindowTitle.SevenDays.BadgePeriod);
            Assert.Null(WindowTitle.TpmRate.BadgePeriod);
            Assert.Null(WindowTitle.AccountBalance.BadgePeriod);
            Assert.Null(WindowTitle.Connected.BadgePeriod);
            Assert.Null(WindowTitle.AvailableModels(3).BadgePeriod);
            Assert.Null(WindowTitle.Custom("Opus 4.5").BadgePeriod);
        }
    }
}
