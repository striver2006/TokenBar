using System;
using System.Text.Json;
using TokenBar.Models;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// Antigravity 配额 bucket（{window/bucketId/displayName, remainingFraction, resetTime}）
    /// → TokenWindow 的解析测试（GeminiService.ParseQuotaBucket）。fixture 形状照抄代码分支。
    /// </summary>
    public class GeminiQuotaBucketParsingTests
    {
        private static TokenWindow? Parse(string json, out bool isWeekly)
        {
            using var doc = JsonDocument.Parse(json);
            var bucket = doc.RootElement;
            // ParseQuotaBucket 只读值类型字段并当场物化 TokenWindow，doc 释放后结果仍有效
            return GeminiService.ParseQuotaBucket(bucket.Clone(), out isWeekly);
        }

        [Fact]
        public void FiveHourWindow_StringResetTime_RemainingFractionTopLevel()
        {
            var window = Parse("""
                {"window": "5h", "remainingFraction": 0.5, "resetTime": "2030-01-01T00:00:00Z"}
                """, out var isWeekly);

            Assert.False(isWeekly);
            Assert.NotNull(window);
            Assert.Equal(WindowTitleKind.FiveHour, window!.Title.Kind);
            Assert.Equal(50.0, window.UsedPercentage, 3);
            Assert.False(window.IsIdle);
            Assert.Equal("2030-01-01T00:00:00Z",
                new DateTimeOffset(window.EndTime).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"));
            Assert.Equal(5 * 3600, (window.EndTime - window.StartTime).TotalSeconds, 1);
        }

        [Fact]
        public void WeeklyViaBucketId_EpochSecondsResetTime()
        {
            // window 缺失 → bucketId 兜底；"week" 关键字 → 周窗口；resetTime 数字按 epoch 秒
            var epoch = new DateTimeOffset(2030, 6, 1, 0, 0, 0, TimeSpan.Zero).ToUnixTimeSeconds();
            var window = Parse($$"""{"bucketId": "weekly-quota", "remainingFraction": 0.25, "resetTime": {{epoch}}}""",
                out var isWeekly);

            Assert.True(isWeekly);
            Assert.NotNull(window);
            Assert.Equal(WindowTitleKind.Weekly, window!.Title.Kind);
            Assert.Equal(75.0, window.UsedPercentage, 3);
            Assert.Equal(epoch, new DateTimeOffset(window.EndTime).ToUnixTimeSeconds());
            Assert.Equal(7 * 24 * 3600, (window.EndTime - window.StartTime).TotalSeconds, 1);
        }

        [Fact]
        public void KindViaDisplayName_FullFractionIsIdle()
        {
            // displayName 兜底 + remainingFraction ≥ 0.999 → idle（配额基本没动）
            var window = Parse("""
                {"displayName": "Five Hour", "remainingFraction": 1.0}
                """, out var isWeekly);

            Assert.False(isWeekly);
            Assert.NotNull(window);
            Assert.True(window!.IsIdle);
            Assert.Equal(0.0, window.UsedPercentage, 3);
            // 无 resetTime：以 now 为锚滚动出正的 5 小时窗口
            Assert.True(window.EndTime > DateTime.Now);
            Assert.Equal(5 * 3600, (window.EndTime - window.StartTime).TotalSeconds, 1);
        }

        [Fact]
        public void RemainingFractionNestedInRemainingObject()
        {
            var window = Parse("""
                {"window": "5h", "remaining": {"remainingFraction": 0.8}}
                """, out var isWeekly);

            Assert.False(isWeekly);
            Assert.NotNull(window);
            Assert.Equal(20.0, window!.UsedPercentage, 3);
        }

        [Fact]
        public void UnknownKind_ReturnsNull()
        {
            var window = Parse("""
                {"window": "daily", "remainingFraction": 0.5}
                """, out var isWeekly);

            Assert.False(isWeekly);
            Assert.Null(window);
        }

        [Fact]
        public void MissingRemainingFraction_ReturnsNull()
        {
            var window = Parse("""
                {"window": "5h", "resetTime": "2030-01-01T00:00:00Z"}
                """, out var isWeekly);

            Assert.False(isWeekly);
            Assert.Null(window);
        }

        [Fact]
        public void UsedPercentageClampedTo100()
        {
            // remainingFraction 为负（超用）→ usedPct 钳到 100
            var window = Parse("""
                {"window": "5h", "remainingFraction": -0.2}
                """, out _);

            Assert.NotNull(window);
            Assert.Equal(100.0, window!.UsedPercentage, 3);
        }

        // 组级解析（GeminiService.ParseGeminiGroupWindows）。守的是「两个配额端点分组集
        // 不同」那次线上事故：daily 端点只回 "Claude and GPT models" 组，Gemini 组只在
        // cloudcode-pa 上。旧逻辑首个 2xx 即返回，Gemini 组匹配不上就静默退化到只产 5h
        // 窗口的按模型回退——「只有 5 小时额度、没有每周额度」的根因。

        private static string Summary(params string[] groups) =>
            $$"""{"groups": [{{string.Join(",", groups)}}]}""";

        [Fact]
        public void GroupParsing_TakesGeminiModelsBuckets_FromCloudCodeStyleResponse()
        {
            var (fiveHour, weekly, scopedWeekly) = GeminiService.ParseGeminiGroupWindows(Summary(
                """
                {"displayName": "Gemini Models", "buckets": [
                    {"window": "weekly", "remainingFraction": 0.9555, "resetTime": "2030-01-01T00:00:00Z"},
                    {"window": "5h", "remainingFraction": 0.5, "resetTime": "2030-01-01T00:00:00Z"}]}
                """,
                """
                {"displayName": "Claude and GPT models", "buckets": [
                    {"window": "weekly", "remainingFraction": 1},
                    {"window": "5h", "remainingFraction": 1}]}
                """));

            Assert.NotNull(weekly);
            Assert.Equal(WindowTitleKind.Weekly, weekly!.Title.Kind);
            Assert.Equal(4.45, weekly.UsedPercentage, 1); // 取 Gemini 组的 weekly，不是 Claude 组的 0%
            Assert.NotNull(fiveHour);
            Assert.Equal(WindowTitleKind.FiveHour, fiveHour!.Title.Kind);
            Assert.Equal(50.0, fiveHour.UsedPercentage, 3);
            Assert.Null(scopedWeekly);
        }

        [Fact]
        public void GroupParsing_DailyStyleResponseWithoutGeminiGroup_ReturnsBothNull()
        {
            // daily-cloudcode-pa 实测形状：只有 Claude/GPT 组 → (null, null, null)，
            // 让 FetchAntigravityQuotaCoreAsync 继续试下一个端点而不是错拿别组的额度
            var (fiveHour, weekly, scopedWeekly) = GeminiService.ParseGeminiGroupWindows(Summary(
                """
                {"displayName": "Claude and GPT models", "buckets": [
                    {"window": "weekly", "remainingFraction": 1},
                    {"window": "5h", "remainingFraction": 1}]}
                """));

            Assert.Null(fiveHour);
            Assert.Null(weekly);
            Assert.Null(scopedWeekly);
        }

        [Fact]
        public void GroupParsing_PrefersCanonicalGeminiModelsOverVariants()
        {
            // 变体组（如 IDE 面板里的 "Gemini 4 Argon"）排在前面也不能抢走正主的桶，
            // 且能正确提取出独立周额度
            var (fiveHour, weekly, scopedWeekly) = GeminiService.ParseGeminiGroupWindows(Summary(
                """
                {"displayName": "Gemini 4 Argon", "buckets": [
                    {"window": "weekly", "remainingFraction": 0.07}]}
                """,
                """
                {"displayName": "Gemini Models", "buckets": [
                    {"window": "weekly", "remainingFraction": 0.9}]}
                """));

            Assert.Null(fiveHour);
            Assert.NotNull(weekly);
            Assert.Equal(10.0, weekly!.UsedPercentage, 3); // 正主 Gemini Models（90% 剩余）优先
            Assert.NotNull(scopedWeekly);
            Assert.Equal(93.0, scopedWeekly!.UsedPercentage, 3);
            Assert.Equal(WindowTitleKind.Custom, scopedWeekly.Title.Kind);
            Assert.Equal("Gemini 4 Argon", scopedWeekly.Title.Argument);
        }

        [Fact]
        public void GroupParsing_ExtractsScopedWeeklyForArgon_BothOrders()
        {
            // 正主在前、Argon 在后，均提取到窗口
            var (fiveHour, weekly, scopedWeekly) = GeminiService.ParseGeminiGroupWindows(Summary(
                """
                {"displayName": "Gemini Models", "buckets": [
                    {"window": "5h", "remainingFraction": 0.8},
                    {"window": "weekly", "remainingFraction": 0.7}]}
                """,
                """
                {"displayName": "Gemini 4 Argon", "buckets": [
                    {"window": "weekly", "remainingFraction": 0.45}]}
                """));

            Assert.NotNull(fiveHour);
            Assert.Equal(20.0, fiveHour!.UsedPercentage, 3);
            Assert.NotNull(weekly);
            Assert.Equal(30.0, weekly!.UsedPercentage, 3);
            Assert.NotNull(scopedWeekly);
            Assert.Equal(55.0, scopedWeekly!.UsedPercentage, 3);
            Assert.Equal(WindowTitleKind.Custom, scopedWeekly.Title.Kind);
            Assert.Equal("Gemini 4 Argon", scopedWeekly.Title.Argument);
        }

        [Fact]
        public void GroupParsing_WrappedInResponseField_ParsesArgonAndMainGroups()
        {
            var json = """
                {
                  "response": {
                    "groups": [
                      {
                        "displayName": "Gemini Models",
                        "buckets": [
                          {"window": "5h", "remainingFraction": 0.85, "resetTime": "2030-01-01T00:00:00Z"},
                          {"window": "weekly", "remainingFraction": 0.60, "resetTime": "2030-01-01T00:00:00Z"}
                        ]
                      },
                      {
                        "displayName": "Gemini 4 Argon",
                        "buckets": [
                          {"window": "weekly", "remainingFraction": 0.2859, "resetTime": "2030-01-01T00:00:00Z"}
                        ]
                      }
                    ]
                  }
                }
                """;

            var (fiveHour, weekly, scopedWeekly) = GeminiService.ParseGeminiGroupWindows(json);
            Assert.NotNull(fiveHour);
            Assert.Equal(15.0, fiveHour!.UsedPercentage, 3);
            Assert.NotNull(weekly);
            Assert.Equal(40.0, weekly!.UsedPercentage, 3);
            Assert.NotNull(scopedWeekly);
            Assert.Equal(71.41, scopedWeekly!.UsedPercentage, 2);
            Assert.Equal(WindowTitleKind.Custom, scopedWeekly.Title.Kind);
            Assert.Equal("Gemini 4 Argon", scopedWeekly.Title.Argument);
        }
    }
}
