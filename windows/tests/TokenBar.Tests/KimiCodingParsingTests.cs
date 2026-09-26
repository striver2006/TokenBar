using System;
using System.Text.Json;
using TokenBar.Models;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>Kimi Code 订阅 /usages 三种实测形状的解析与模式判定，fixture 来自真实接口响应（2026-09-26）。</summary>
    public class KimiCodingParsingTests
    {
        private static (TokenWindow? FiveHour, TokenWindow? LongWindow) Parse(string json)
        {
            using var doc = JsonDocument.Parse(json);
            return KimiService.ParseCodingUsages(doc.RootElement);
        }

        [Fact]
        public void NewSubscriptionShape_LimitsWindowBeatsRatioFiveHour()
        {
            // 实测 OAuth 新形状：limits[] 的 300 分钟窗（字符串数字）优先于 usages.limit_5h 比例
            var (fiveHour, longWindow) = Parse("""
                {"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                  "detail":{"limit":"100","used":"21","remaining":"79","resetTime":"2026-09-26T11:52:30.018171Z"}}],
                 "usages":{"limit_5h":{"used_ratio":0.206526,"reset_time":"2026-09-26T11:52:29Z"},
                  "limit_month_total":{"used_ratio":0.0228,"reset_time":"2026-10-26T06:52:30Z"},
                  "limit_month_code":{"used_ratio":0.0083,"reset_time":"2026-10-26T06:52:30Z"}}}
                """);

            Assert.NotNull(fiveHour);
            Assert.Equal("5小时额度", fiveHour!.Title);
            Assert.Equal(21.0, fiveHour.UsedPercentage, 3);
            Assert.Equal(21.0, fiveHour.UsedAmount!.Value, 3);
            Assert.Equal(100.0, fiveHour.TotalLimit!.Value, 3);
            Assert.Equal("次", fiveHour.Unit);
            Assert.False(fiveHour.IsIdle);
            // 带纳秒小数的 ISO 时间要能解析（重置点为 2026-09-26T11:52:30Z，用 Unix 秒比较与时区无关）
            Assert.Equal(DateTimeOffset.Parse("2026-09-26T11:52:30Z").ToUnixTimeSeconds(),
                new DateTimeOffset(fiveHour.EndTime).ToUnixTimeSeconds());

            Assert.NotNull(longWindow);
            Assert.Equal("月度额度", longWindow!.Title);
            Assert.Equal(2.28, longWindow.UsedPercentage, 2);
            Assert.Equal(DateTimeOffset.Parse("2026-10-26T06:52:30Z").ToUnixTimeSeconds(),
                new DateTimeOffset(longWindow.EndTime).ToUnixTimeSeconds());
        }

        [Fact]
        public void ApiKeyLegacyShape_TopLevelUsageIsWeeklyLongWindow()
        {
            // API Key（sk-kimi-）老套餐（7 天周限）：顶层 usage 是长窗口，limits[] 的 300 分钟窗是 5 小时窗
            var (fiveHour, longWindow) = Parse("""
                {"usage":{"limit":"2048","used":"214","remaining":"1834","resetTime":"2026-01-09T15:23:13.716839300Z"},
                 "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                   "detail":{"limit":"200","used":"139","remaining":"61","resetTime":"2026-01-06T13:33:02.717479433Z"}}]}
                """);

            Assert.NotNull(fiveHour);
            Assert.Equal(69.5, fiveHour!.UsedPercentage, 3);
            Assert.Equal(139.0, fiveHour.UsedAmount!.Value, 3);
            Assert.Equal(200.0, fiveHour.TotalLimit!.Value, 3);
            Assert.Equal(DateTimeOffset.Parse("2026-01-06T13:33:02Z").ToUnixTimeSeconds(),
                new DateTimeOffset(fiveHour.EndTime).ToUnixTimeSeconds());

            Assert.NotNull(longWindow);
            // resetTime 距现在不足 20 天（fixture 已过期）→ 「每周额度」
            Assert.Equal("每周额度", longWindow!.Title);
            Assert.Equal(214.0 / 2048.0 * 100.0, longWindow.UsedPercentage, 3);
            Assert.Equal(214.0, longWindow.UsedAmount!.Value, 3);
            Assert.Equal(2048.0, longWindow.TotalLimit!.Value, 3);
        }

        [Fact]
        public void TopLevelUsageWithResetFarAway_IsMonthly()
        {
            var monthlyReset = DateTimeOffset.UtcNow.AddDays(30).ToString("yyyy-MM-ddTHH:mm:ssZ");
            var json = $$"""
                {"usage":{"limit":"1000","used":"100","remaining":"900","resetTime":"{{monthlyReset}}"}}
                """;

            var (_, longWindow) = Parse(json);

            Assert.NotNull(longWindow);
            Assert.Equal("月度额度", longWindow!.Title);
            Assert.Equal(10.0, longWindow.UsedPercentage, 3);
        }

        [Fact]
        public void OAuthOldNestedShape_ReadsCamelCaseFromDataQuota()
        {
            // issue #3908 旧形状：嵌套在 data.quota 里，字段 camelCase，resetAt 无小数秒
            var (fiveHour, longWindow) = Parse("""
                {"code":0,"data":{"kind":"ok","quota":{"usages":
                  {"limit5h":{"resetAt":"2026-09-18T12:07:12Z","usedRatio":0},
                   "limit7d":{"resetAt":"2026-09-23T23:07:12Z","usedRatio":0}}}}}
                """);

            Assert.NotNull(fiveHour);
            Assert.Equal(0.0, fiveHour!.UsedPercentage, 3);
            Assert.True(fiveHour.IsIdle);
            Assert.Equal(DateTimeOffset.Parse("2026-09-18T12:07:12Z").ToUnixTimeSeconds(),
                new DateTimeOffset(fiveHour.EndTime).ToUnixTimeSeconds());

            Assert.NotNull(longWindow);
            Assert.Equal("每周额度", longWindow!.Title);
            Assert.Equal(0.0, longWindow.UsedPercentage, 3);
            Assert.True(longWindow.IsIdle);
            Assert.Equal(DateTimeOffset.Parse("2026-09-23T23:07:12Z").ToUnixTimeSeconds(),
                new DateTimeOffset(longWindow.EndTime).ToUnixTimeSeconds());
        }

        [Theory]
        // 300 分钟 = 18000 秒 → 命中 5 小时窗
        [InlineData("""{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"10","resetTime":"2026-09-26T11:52:30Z"}}]}""", 10.0)]
        // 5 小时 = 18000 秒 → 命中（HOUR 单位换算）
        [InlineData("""{"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"100","used":"10","resetTime":"2026-09-26T11:52:30Z"}}]}""", 10.0)]
        // 18000 秒 → 命中（SECOND 单位换算）
        [InlineData("""{"limits":[{"window":{"duration":18000,"timeUnit":"TIME_UNIT_SECOND"},"detail":{"limit":"100","used":"10","resetTime":"2026-09-26T11:52:30Z"}}]}""", 10.0)]
        // 900 分钟 = 15 小时 ≠ 5 小时窗 → 不命中
        [InlineData("""{"limits":[{"window":{"duration":900,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"10","resetTime":"2026-09-26T11:52:30Z"}}]}""", null)]
        public void FiveHourLimitsWindow_MatchesByWindowSeconds(string json, double? expectedPct)
        {
            var (fiveHour, _) = Parse(json);
            if (expectedPct.HasValue)
            {
                Assert.NotNull(fiveHour);
                Assert.Equal(expectedPct.Value, fiveHour!.UsedPercentage, 3);
            }
            else
            {
                Assert.Null(fiveHour);
            }
        }

        [Fact]
        public void PercentagesAreClamped()
        {
            var (fiveHour, longWindow) = Parse("""
                {"usages":{"limit_5h":{"used_ratio":1.5,"reset_time":"2026-09-26T12:00:00Z"},
                 "limit_month_total":{"used_ratio":-0.2,"reset_time":"2026-10-26T06:52:30Z"}}}
                """);

            Assert.Equal(100.0, fiveHour!.UsedPercentage, 3);
            Assert.Equal(0.0, longWindow!.UsedPercentage, 3);
        }

        [Fact]
        public void StringNumbersWithThousandsSeparator_Parse()
        {
            var (_, longWindow) = Parse("""
                {"usage":{"limit":"2,048","used":"1,024","remaining":"1,024","resetTime":"2026-01-09T15:23:13Z"}}
                """);

            Assert.NotNull(longWindow);
            Assert.Equal(50.0, longWindow!.UsedPercentage, 3);
            Assert.Equal(1024.0, longWindow.UsedAmount!.Value, 3);
            Assert.Equal(2048.0, longWindow.TotalLimit!.Value, 3);
        }

        [Fact]
        public void UnrecognizedShape_ReturnsNulls()
        {
            var (fiveHour, longWindow) = Parse("""{"code":0,"data":{"kind":"ok"}}""");
            Assert.Null(fiveHour);
            Assert.Null(longWindow);
        }

        [Theory]
        [InlineData("sk-kimi-abc123def", "https://api.moonshot.cn/v1", true)]
        [InlineData("SK-KIMI-uppercase", "https://api.moonshot.cn/v1", true)]
        [InlineData("eyJhbGciOiJ.eyJzdWIiOiIx.kdskfj", "https://api.moonshot.cn/v1", true)]
        [InlineData("sk-abcdefghijklmnop", "https://api.kimi.com/coding/v1", true)]
        [InlineData("sk-abcdefghijklmnop", "https://api.kimi.ai/coding/v1", true)]
        [InlineData("sk-abcdefghijklmnop", "https://my-proxy.example.com/coding/v1", true)]
        [InlineData("sk-abcdefghijklmnop", "https://api.moonshot.cn/v1", false)]
        [InlineData("sk-abcdefghijklmnop", "", false)]
        [InlineData("aaa.bbb.cc cc", "https://api.moonshot.cn/v1", false)]
        public void ModeDetection(string apiKey, string endpoint, bool expected)
        {
            Assert.Equal(expected, KimiService.IsCodingSubscriptionMode(apiKey, endpoint));
        }
    }
}
