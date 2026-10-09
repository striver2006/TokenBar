using System;
using System.Text.Json;
using TokenBar.Models;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests;

public class CodexQuotaParsingTests
{
    [Fact]
    public void SubscriptionUsesServerUsageAndReset()
    {
        using var doc = JsonDocument.Parse("""{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1800100000}}}""");
        var (primary, secondary) = CodexService.ParseRateLimits(doc.RootElement);
        Assert.Equal(75, primary!.RemainingPercentage);
        Assert.Equal(WindowTitle.FiveHour, primary.Title);
        Assert.Equal(TimeSpan.FromHours(5), primary.EndTime - primary.StartTime);
        Assert.Equal(1800000000, new DateTimeOffset(primary.EndTime).ToUnixTimeSeconds());
        Assert.Equal(0, secondary!.RemainingPercentage);
        Assert.Equal(WindowTitle.Weekly, secondary.Title);
    }

    [Fact]
    public void CodexBucketOverridesLegacyAndCanHaveOneWindow()
    {
        using var doc = JsonDocument.Parse("""{"rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":300,"resetsAt":1800000000}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":2,"windowDurationMins":10080,"resetsAt":1800000000},"secondary":null}}}""");
        var (primary, secondary) = CodexService.ParseRateLimits(doc.RootElement);
        Assert.Equal(98, primary!.RemainingPercentage);
        Assert.Equal(WindowTitle.Weekly, primary.Title);
        Assert.Null(secondary);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"rateLimits\":{}}")]
    [InlineData("{\"rateLimits\":{\"primary\":null,\"secondary\":null}}")]
    [InlineData("{\"rateLimits\":{\"primary\":{\"usedPercent\":true,\"windowDurationMins\":300,\"resetsAt\":1800000000}}}")]
    [InlineData("{\"rateLimits\":{\"primary\":{\"usedPercent\":25,\"windowDurationMins\":0,\"resetsAt\":1800000000}}}")]
    public void MissingOrMalformedWindowsDoNotBecomeFullQuota(string json)
    {
        using var doc = JsonDocument.Parse(json);
        Assert.ThrowsAny<Exception>(() => CodexService.ParseRateLimits(doc.RootElement));
    }

    [Fact]
    public void OldSettingsKeepApiMode()
    {
        var settings = JsonSerializer.Deserialize<AppSettings>("{\"OpenAIApiKey\":\"test-key\"}")!;
        Assert.False(settings.OpenAIUseCodexSubscription);
        Assert.Equal("test-key", settings.OpenAIApiKey);
        settings.OpenAIUseCodexSubscription = true;
        settings.CodexExecutablePath = @"C:\Tools\codex.exe";
        var roundTrip = JsonSerializer.Deserialize<AppSettings>(JsonSerializer.Serialize(settings))!;
        Assert.True(roundTrip.OpenAIUseCodexSubscription);
        Assert.Equal(settings.CodexExecutablePath, roundTrip.CodexExecutablePath);
    }
}
