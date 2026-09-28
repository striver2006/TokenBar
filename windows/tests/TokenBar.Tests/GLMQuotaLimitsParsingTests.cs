using System;
using System.Text.Json;
using TokenBar.Models;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// GLM /api/monitor/usage/quota/limit 响应解析测试（GLMService.ParseQuotaLimits）。
    /// 覆盖：data.limits 与顶层 limits 两种形状、nextResetTime 秒/毫秒量级判断、
    /// TOKEN/5H/SESSION → 5小时窗、WEEK → 周窗、未知 type 兜底、缺 limits 抛 OptionalProbeException。
    /// </summary>
    public class GLMQuotaLimitsParsingTests
    {
        // 固定“当前时刻”，缺 nextResetTime 时的兜底窗口锚点，断言完全确定性
        private static readonly DateTime Now = new DateTime(2026, 9, 28, 12, 0, 0, DateTimeKind.Local);

        private static (TokenWindow? FiveHour, TokenWindow? Weekly) Parse(string json)
        {
            using var doc = JsonDocument.Parse(json);
            return GLMService.ParseQuotaLimits(doc.RootElement.Clone(), Now);
        }

        [Fact]
        public void NestedDataLimits_TokenType_ResetInSeconds()
        {
            // data.limits 嵌套形状；type=TOKEN → 5小时窗；nextResetTime 秒级量级（< 1e12）
            var resetEpochSec = new DateTimeOffset(2026, 9, 28, 18, 0, 0, TimeSpan.Zero).ToUnixTimeSeconds();
            var (fiveHour, weekly) = Parse($$"""
                {"data": {"limits": [
                    {"type": "TOKEN", "percentage": 30, "used": 300, "total": 1000, "nextResetTime": {{resetEpochSec}} }
                ] } }
                """);

            Assert.Null(weekly);
            Assert.NotNull(fiveHour);
            Assert.Equal(WindowTitleKind.FiveHour, fiveHour!.Title.Kind);
            Assert.Equal(30, fiveHour.UsedPercentage, 3);
            Assert.Equal(300, fiveHour.UsedAmount!.Value, 3);
            Assert.Equal(1000, fiveHour.TotalLimit!.Value, 3);
            Assert.Equal("Tokens", fiveHour.Unit);
            Assert.False(fiveHour.IsIdle);
            Assert.Equal(resetEpochSec, new DateTimeOffset(fiveHour.EndTime).ToUnixTimeSeconds());
            Assert.Equal(5 * 3600, (fiveHour.EndTime - fiveHour.StartTime).TotalSeconds, 1);
        }

        [Fact]
        public void TopLevelLimits_5HType_ResetInMilliseconds()
        {
            // 顶层 limits 形状；type=5H；nextResetTime 毫秒级量级（> 1e12 → 不再乘 1000）
            var resetEpochMs = new DateTimeOffset(2026, 9, 29, 0, 0, 0, TimeSpan.Zero).ToUnixTimeMilliseconds();
            Assert.True(resetEpochMs > 1e12); // fixture 本身必须落在毫秒量级分支

            var (fiveHour, weekly) = Parse($$"""
                {
                  "limits": [{"type": "5H", "utilization": 12.5, "nextResetTime": {{resetEpochMs}} }]
                }
                """);

            Assert.Null(weekly);
            Assert.NotNull(fiveHour);
            // percentage 缺失 → utilization 兜底
            Assert.Equal(12.5, fiveHour!.UsedPercentage, 3);
            // 无 used/total → 百分比单位
            Assert.Null(fiveHour.UsedAmount);
            Assert.Null(fiveHour.TotalLimit);
            Assert.Equal("%", fiveHour.Unit);
            Assert.Equal(resetEpochMs / 1000, new DateTimeOffset(fiveHour.EndTime).ToUnixTimeSeconds());
        }

        [Fact]
        public void SessionType_ZeroPercent_IsIdle_DefaultAnchor()
        {
            // type=SESSION → 5小时窗；pct == 0 → idle；缺 nextResetTime → 兜底 now + 5h
            var (fiveHour, weekly) = Parse("""
                {"data": {"limits": [{"type": "SESSION", "percentage": 0}]}}
                """);

            Assert.Null(weekly);
            Assert.NotNull(fiveHour);
            Assert.True(fiveHour!.IsIdle);
            Assert.Equal(Now, fiveHour.StartTime);
            Assert.Equal(Now.AddHours(5), fiveHour.EndTime);
        }

        [Fact]
        public void WeekType_GoesToWeeklyWindow_Only()
        {
            // type 含 WEEK → 周窗；缺 nextResetTime → 兜底 now + 7d；5小时窗保持 null
            var (fiveHour, weekly) = Parse("""
                {"limits": [{"type": "WEEK_TOKEN", "percentage": 66}]}
                """);

            Assert.Null(fiveHour);
            Assert.NotNull(weekly);
            Assert.Equal(WindowTitleKind.Weekly, weekly!.Title.Kind);
            Assert.Equal(66, weekly.UsedPercentage, 3);
            Assert.False(weekly.IsIdle);
            Assert.Equal(Now.AddDays(7), weekly.EndTime);
            Assert.Equal(Now, weekly.StartTime);
        }

        [Fact]
        public void UnknownTypes_FirstFallsIntoFiveHour_SecondIntoWeekly()
        {
            // 未知 type（不含 TOKEN/5H/SESSION/WEEK）：首个非周条目兜底进 5小时窗，第二个进周窗
            var (fiveHour, weekly) = Parse("""
                {"limits": [
                    {"type": "MYSTERY", "percentage": 10},
                    {"type": "OTHER", "percentage": 20}
                ]}
                """);

            Assert.NotNull(fiveHour);
            Assert.Equal(10, fiveHour!.UsedPercentage, 3);
            Assert.Equal(WindowTitleKind.FiveHour, fiveHour.Title.Kind);
            Assert.NotNull(weekly);
            Assert.Equal(20, weekly!.UsedPercentage, 3);
            Assert.Equal(WindowTitleKind.Weekly, weekly.Title.Kind);
        }

        [Fact]
        public void PercentageIsClampedTo0_100()
        {
            var (fiveHour, weekly) = Parse("""
                {"limits": [
                    {"type": "TOKEN", "percentage": 150},
                    {"type": "WEEK", "percentage": -3}
                ]}
                """);

            Assert.Equal(100, fiveHour!.UsedPercentage, 3);
            Assert.Equal(0, weekly!.UsedPercentage, 3);
            Assert.True(weekly.IsIdle); // clamp 后 pct == 0 → idle
        }

        [Fact]
        public void MissingLimitsArray_ThrowsOptionalProbeException()
        {
            // 没有 limits 数组 → 「可选探测失败」，调用方静默降级到速率头
            var ex = Assert.Throws<GLMService.OptionalProbeException>(() => { Parse("""{"data": {}}"""); });
            Assert.Equal("响应中没有 limits 数组", ex.Message);

            Assert.Throws<GLMService.OptionalProbeException>(() => { Parse("""{"code": 0}"""); });
        }

        [Fact]
        public void NonObjectItems_Tolerated()
        {
            // 数组里混入非对象条目：跳过而不是崩溃；无 type 的对象条目走「首个非周条目」兜底
            var (fiveHour, weekly) = Parse("""
                {"limits": [42, "x", null, {}, {}]}
                """);

            // 第一个 {} → 5小时窗（pct 0 → idle），第二个 {} → 周窗
            Assert.NotNull(fiveHour);
            Assert.True(fiveHour!.IsIdle);
            Assert.NotNull(weekly);
            Assert.True(weekly!.IsIdle);
        }
    }
}
