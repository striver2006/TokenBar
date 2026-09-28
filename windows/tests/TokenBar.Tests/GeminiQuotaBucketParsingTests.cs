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
    }
}
