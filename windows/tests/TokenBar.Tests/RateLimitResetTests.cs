using System;
using TokenBar.Helpers;
using Xunit;

namespace TokenBar.Tests
{
    public class RateLimitResetTests
    {
        [Theory]
        [InlineData("20ms", 0.02)]
        [InlineData("1s", 1)]
        [InlineData("1.5s", 1.5)]
        [InlineData("6m0s", 360)]
        [InlineData("1h2m", 3720)]
        [InlineData("1h2m3s", 3723)]
        [InlineData(" 30s ", 30)]
        public void GoDuration(string input, double expected)
        {
            var parsed = RateLimitReset.Parse(input);
            Assert.NotNull(parsed);
            Assert.Equal(expected, parsed!.Value, 6);
        }

        [Theory]
        [InlineData("60", 60)]
        [InlineData("0.5", 0.5)]
        [InlineData("0", 0)]
        public void PlainSeconds(string input, double expected)
        {
            Assert.Equal(expected, RateLimitReset.Parse(input)!.Value, 6);
        }

        [Fact]
        public void UnixSecondsTimestamp_IsConvertedToRelative()
        {
            var future = DateTimeOffset.UtcNow.AddSeconds(120).ToUnixTimeSeconds();
            var parsed = RateLimitReset.Parse(future.ToString());
            Assert.NotNull(parsed);
            Assert.InRange(parsed!.Value, 110, 125);
        }

        [Fact]
        public void UnixMillisecondsTimestamp_IsConvertedToRelative()
        {
            var future = DateTimeOffset.UtcNow.AddSeconds(300).ToUnixTimeMilliseconds();
            var parsed = RateLimitReset.Parse(future.ToString());
            Assert.NotNull(parsed);
            Assert.InRange(parsed!.Value, 290, 305);
        }

        [Fact]
        public void PastTimestamp_ClampsToZero()
        {
            var past = DateTimeOffset.UtcNow.AddHours(-1).ToUnixTimeSeconds();
            Assert.Equal(0, RateLimitReset.Parse(past.ToString())!.Value, 6);
        }

        [Fact]
        public void HugeDuration_ClampsToOneDay()
        {
            Assert.Equal(86400, RateLimitReset.Parse("100h")!.Value, 6);
            Assert.Equal(86400, RateLimitReset.Parse("999999")!.Value, 6);
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("   ")]
        [InlineData("abc")]
        [InlineData("s")]
        [InlineData("1x")]
        [InlineData("-5s")]
        public void Garbage_ReturnsNull(string? input)
        {
            Assert.Null(RateLimitReset.Parse(input));
        }

        [Fact]
        public void NegativePlainNumber_ClampsToZero()
        {
            Assert.Equal(0, RateLimitReset.Parse("-5")!.Value, 6);
        }
    }
}
