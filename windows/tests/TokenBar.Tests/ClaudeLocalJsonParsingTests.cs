using System;
using System.Text.Json;
using TokenBar.Models;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// ~/.claude.json → 窗口/账号 的纯解析测试（ClaudeService.ParseLocalClaudeJson）。
    /// 固定 fixture + 注入 now，不读开发者机器上的真实 ~/.claude.json。
    /// 用例与 mac 端 TokenBarTests.testClaudeLocalConfigParserFromFixture /
    /// testClaudeScopedWeeklyWithoutModelName / testClaudeLocalConfigParserWithoutCachedUsage 对齐。
    /// </summary>
    public class ClaudeLocalJsonParsingTests
    {
        // 固定“当前时刻”，所有 resets_at fixture 都相对它构造，断言完全确定性
        private static readonly DateTime Now = new DateTime(2026, 9, 28, 12, 0, 0, DateTimeKind.Local);

        /// <summary>把本地时刻转成带 Z 后缀的 UTC ISO8601 串（生产缓存里的真实形状）。</summary>
        private static string IsoUtc(DateTime local) =>
            new DateTimeOffset(local).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ");

        [Fact]
        public void Fixture_FiveHourAndWeeklyAllAndScopedWeekly()
        {
            // 与 mac testClaudeLocalConfigParserFromFixture 同一 fixture：
            // five_hour 37.5%（2 小时后重置）+ limits[weekly_all 12%, weekly_scoped Fable 42%]
            var resetsAt = IsoUtc(Now.AddHours(2));
            var weeklyReset = IsoUtc(Now.AddDays(3));
            var json = $$"""
                {
                  "oauthAccount": {"emailAddress": "someone@example.com"},
                  "cachedUsageUtilization": {
                    "utilization": {
                      "five_hour": {"utilization": 37.5, "resets_at": "{{resetsAt}}" },
                      "limits": [
                        {"kind": "weekly_all", "percent": 12, "resets_at": "{{weeklyReset}}" },
                        {"kind": "weekly_scoped", "percent": 42, "resets_at": "{{weeklyReset}}",
                         "scope": {"model": {"id": null, "display_name": "Fable"} } }
                      ]
                    }
                  }
                }
                """;

            var parsed = ClaudeService.ParseLocalClaudeJson(json, Now);

            Assert.NotNull(parsed);
            Assert.Equal("someone@example.com", parsed!.Value.Account);

            var fiveHour = parsed.Value.FiveHour;
            Assert.NotNull(fiveHour);
            Assert.Equal(WindowTitleKind.FiveHour, fiveHour!.Title.Kind);
            Assert.Equal(37.5, fiveHour.UsedPercentage, 3);
            Assert.False(fiveHour.IsIdle);
            Assert.Equal(5 * 3600, (fiveHour.EndTime - fiveHour.StartTime).TotalSeconds, 1);
            Assert.Equal(Now.AddHours(2), fiveHour.EndTime);

            // weekly fallback 取 first(kind == "weekly_all")，命中 weekly_all 而非 weekly_scoped
            var weekly = parsed.Value.Weekly;
            Assert.NotNull(weekly);
            Assert.Equal(WindowTitleKind.Weekly, weekly!.Title.Kind);
            Assert.Equal(12, weekly.UsedPercentage, 3);
            Assert.False(weekly.IsIdle);
            Assert.Equal(Now.AddDays(3), weekly.EndTime);
            Assert.Equal(Now.AddDays(3).AddDays(-7), weekly.StartTime);

            var scopedWeekly = parsed.Value.ScopedWeekly;
            Assert.NotNull(scopedWeekly);
            Assert.Equal(42, scopedWeekly!.UsedPercentage, 3);
            Assert.Equal(WindowTitleKind.Custom, scopedWeekly.Title.Kind);
            Assert.Equal("Fable", scopedWeekly.Title.Argument);
        }

        [Fact]
        public void ScopedWeeklyWithoutModelName_IsSkippedEntirely()
        {
            // 与 mac testClaudeScopedWeeklyWithoutModelName 对齐：
            // weekly_scoped 缺 scope.model.display_name，给不出有意义的标题，整体跳过
            var json = """
                {
                  "cachedUsageUtilization": {
                    "utilization": {
                      "five_hour": {"utilization": 10},
                      "limits": [{"kind": "weekly_scoped", "percent": 42}]
                    }
                  }
                }
                """;

            var parsed = ClaudeService.ParseLocalClaudeJson(json, Now);

            Assert.NotNull(parsed);
            Assert.Null(parsed!.Value.ScopedWeekly);
            // five_hour 无 resets_at：给出保留用量的 idle 窗口
            var fiveHour = parsed.Value.FiveHour;
            Assert.NotNull(fiveHour);
            Assert.Equal(10, fiveHour!.UsedPercentage, 3);
            Assert.True(fiveHour.IsIdle);
            Assert.Equal(Now, fiveHour.StartTime);
            Assert.Equal(Now.AddHours(5), fiveHour.EndTime);
        }

        [Fact]
        public void WithoutCachedUsage_ReturnsCleanIdleFiveHourWindow()
        {
            // 与 mac testClaudeLocalConfigParserWithoutCachedUsage 对齐：
            // 登录了但还没有缓存用量 → 干净的 5 小时 idle 窗口，账号回退 displayName
            var json = """{"oauthAccount": {"displayName": "Bob"}}""";

            var parsed = ClaudeService.ParseLocalClaudeJson(json, Now);

            Assert.NotNull(parsed);
            Assert.Equal("Bob", parsed!.Value.Account);
            var fiveHour = parsed.Value.FiveHour;
            Assert.NotNull(fiveHour);
            Assert.True(fiveHour!.IsIdle);
            Assert.Equal(0.0, fiveHour.UsedPercentage, 3);
            Assert.Equal(Now, fiveHour.StartTime);
            Assert.Equal(Now.AddHours(5), fiveHour.EndTime);
            Assert.Null(parsed.Value.Weekly);
            Assert.Null(parsed.Value.ScopedWeekly);
        }

        [Fact]
        public void ExpiredFiveHourReset_FallsBackToIdleWindow()
        {
            // resets_at 已过期：清零并给出从 now 起的新 5 小时 idle 窗口
            var json = $$"""
                {
                  "cachedUsageUtilization": {
                    "utilization": {"five_hour": {"utilization": 88, "resets_at": "{{IsoUtc(Now.AddHours(-1))}}" } }
                  }
                }
                """;

            var parsed = ClaudeService.ParseLocalClaudeJson(json, Now);

            Assert.NotNull(parsed);
            var fiveHour = parsed!.Value.FiveHour;
            Assert.NotNull(fiveHour);
            Assert.True(fiveHour!.IsIdle);
            Assert.Equal(0.0, fiveHour.UsedPercentage, 3);
            Assert.Equal(Now, fiveHour.StartTime);
            Assert.Equal(Now.AddHours(5), fiveHour.EndTime);
        }

        [Fact]
        public void SevenDay_BeatsLimitsWeeklyFallback()
        {
            // seven_day 带 resets_at：直接构造周窗口，limits fallback 不再参与
            var reset = IsoUtc(Now.AddDays(2));
            var json = $$"""
                {
                  "cachedUsageUtilization": {
                    "utilization": {
                      "five_hour": {"utilization": 5},
                      "seven_day": {"utilization": 55, "resets_at": "{{reset}}"},
                      "limits": [{"kind": "weekly_all", "percent": 12}]
                    }
                  }
                }
                """;

            var parsed = ClaudeService.ParseLocalClaudeJson(json, Now);

            Assert.NotNull(parsed);
            var weekly = parsed!.Value.Weekly;
            Assert.NotNull(weekly);
            Assert.Equal(55, weekly!.UsedPercentage, 3);
            Assert.False(weekly.IsIdle);
            Assert.Equal(Now.AddDays(2), weekly.EndTime);
            Assert.Equal(Now.AddDays(2).AddDays(-7), weekly.StartTime);
        }

        [Fact]
        public void LimitsSessionFallback_WhenNoFiveHourEntry()
        {
            // 无 five_hour 字段：limits[kind=session] 兜底进 5 小时窗，StartTime 即 now
            var json = """
                {
                  "cachedUsageUtilization": {
                    "utilization": {"limits": [{"kind": "session", "percent": 25}]}
                  }
                }
                """;

            var parsed = ClaudeService.ParseLocalClaudeJson(json, Now);

            Assert.NotNull(parsed);
            var fiveHour = parsed!.Value.FiveHour;
            Assert.NotNull(fiveHour);
            Assert.Equal(25, fiveHour!.UsedPercentage, 3);
            Assert.False(fiveHour.IsIdle); // pct != 0 → 非 idle
            Assert.Equal(Now, fiveHour.StartTime);
            Assert.Equal(Now.AddHours(5), fiveHour.EndTime);
        }

        [Fact]
        public void NoFiveHourNoSessionLimit_StillGetsIdleWindow()
        {
            // utilization 里既无 five_hour 也无 session 条目：仍然给出 0% idle 5 小时窗
            var json = """{"cachedUsageUtilization": {"utilization": {}}}""";

            var parsed = ClaudeService.ParseLocalClaudeJson(json, Now);

            Assert.NotNull(parsed);
            var fiveHour = parsed!.Value.FiveHour;
            Assert.NotNull(fiveHour);
            Assert.True(fiveHour!.IsIdle);
            Assert.Equal(0.0, fiveHour.UsedPercentage, 3);
            Assert.Null(parsed.Value.Weekly);
        }

        [Fact]
        public void InvalidJson_Throws_ForCallerToSwallow()
        {
            // ReadLocalClaudeJson 的 try/catch 负责兜底并返回 null；纯函数如实上抛
            Assert.Throws<JsonException>(() => { ClaudeService.ParseLocalClaudeJson("{ not json", Now); });
        }

        [Fact]
        public void TryParseUtc_NoSuffixTreatedAsUtc_SuffixAdjusted_GarbageRejected()
        {
            // 无时区后缀按 UTC 理解
            Assert.True(ClaudeService.TryParseUtc("2026-09-28T10:00:00", out var naive));
            Assert.Equal(DateTimeOffset.Parse("2026-09-28T10:00:00Z").ToUnixTimeSeconds(),
                new DateTimeOffset(naive).ToUnixTimeSeconds());

            // 带偏移后缀按后缀换算成本地时刻
            Assert.True(ClaudeService.TryParseUtc("2026-09-28T10:00:00+08:00", out var withOffset));
            Assert.Equal(DateTimeOffset.Parse("2026-09-28T02:00:00Z").ToUnixTimeSeconds(),
                new DateTimeOffset(withOffset).ToUnixTimeSeconds());

            Assert.False(ClaudeService.TryParseUtc("not-a-date", out _));
            Assert.False(ClaudeService.TryParseUtc(null, out _));
            Assert.False(ClaudeService.TryParseUtc("   ", out _));
        }
    }
}
