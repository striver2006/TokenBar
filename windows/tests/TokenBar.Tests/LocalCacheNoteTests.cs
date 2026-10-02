using System;
using TokenBar.I18n;
using TokenBar.Models;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// ProviderQuota.LocalCacheNote / RelativeAge：「更新于」是 TokenBar 的刷新时刻，Claude 的本地缓存
    /// 可能旧得多，卡片要标注缓存自己的抓取时间。用例与 mac 端 testLocalCacheNote /
    /// testRelativeAgeBoundaries 对齐。LocalizationManager 是全局单例，测试工程已在 AssemblyInfo.cs 禁用并行。
    /// </summary>
    public sealed class LocalCacheNoteTests : IDisposable
    {
        private static readonly DateTime Now = new DateTime(2026, 10, 2, 18, 40, 0, DateTimeKind.Local);
        private readonly AppLanguage _originalLanguage;

        public LocalCacheNoteTests()
        {
            _originalLanguage = LocalizationManager.Instance.CurrentLanguage;
        }

        public void Dispose()
        {
            LocalizationManager.Instance.SetLanguage(_originalLanguage);
        }

        [Fact]
        public void LiveData_HasNoNote()
        {
            var quota = new ProviderQuota { Provider = ProviderType.ClaudeCode };
            Assert.Null(quota.LocalCacheNote(Now));
        }

        [Fact]
        public void CacheWithoutTimestamp_ShowsSourceOnly()
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            var quota = new ProviderQuota { Provider = ProviderType.ClaudeCode, IsFromLocalCache = true };
            Assert.Equal("来自 Claude Code 本地缓存", quota.LocalCacheNote(Now));
        }

        [Fact]
        public void CacheWithTimestamp_ShowsAge_InAppLanguage()
        {
            var quota = new ProviderQuota
            {
                Provider = ProviderType.ClaudeCode,
                IsFromLocalCache = true,
                LocalCacheFetchedAt = Now.AddMinutes(-12).AddSeconds(-30)
            };

            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            Assert.Equal("来自 Claude Code 本地缓存 · 12 分钟前", quota.LocalCacheNote(Now));

            quota.LocalCacheFetchedAt = Now.AddHours(-3);
            LocalizationManager.Instance.SetLanguage(AppLanguage.En);
            Assert.Equal("From Claude Code local cache · 3h ago", quota.LocalCacheNote(Now));
        }

        [Theory]
        [InlineData(-30, "刚刚")]   // 时钟回拨的负间隔按刚刚处理
        [InlineData(59, "刚刚")]
        [InlineData(60, "1 分钟前")]
        [InlineData(3599, "59 分钟前")]
        [InlineData(3600, "1 小时前")]
        [InlineData(86399, "23 小时前")]
        [InlineData(2 * 86400, "2 天前")]
        public void RelativeAge_Boundaries(int secondsAgo, string expected)
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            Assert.Equal(expected, ProviderQuota.RelativeAge(Now.AddSeconds(-secondsAgo), Now));
        }
    }
}
