using System;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>三种嵌套形态的 fixture 与 mac 端 testAliyunParse* 一致。</summary>
    public class AliyunParsingTests
    {
        private static AliyunQuotaResult Parse(string json, AliyunChannel channel = AliyunChannel.AccessKey)
            => AliyunBailianService.ParseTokenPlanResponse(json, "test", channel);

        [Fact]
        public void CliFlatShape()
        {
            var r = Parse("""
                {"per1WeekPercentage":0.125,"per1WeekResetTime":1789122720000,
                 "per5HourPercentage":0.5,"per5HourResetTime":1789000000000}
                """, AliyunChannel.Cli);
            Assert.NotNull(r.Weekly);
            Assert.NotNull(r.FiveHour);
            Assert.Equal(12.5, r.Weekly!.UsedPercentage, 3);
            Assert.Equal(50.0, r.FiveHour!.UsedPercentage, 3);
            Assert.Equal(AliyunChannel.Cli, r.Channel);
            Assert.Null(r.Note);
        }

        [Fact]
        public void CookieGatewayShape()
        {
            var r = Parse("""
                {"data":{"data":{"per1WeekPercentage":0.25,"per1WeekResetTime":1789122720000}}}
                """, AliyunChannel.Cookie);
            Assert.NotNull(r.Weekly);
            Assert.Equal(25.0, r.Weekly!.UsedPercentage, 3);
            Assert.Null(r.FiveHour);
        }

        [Fact]
        public void BearerGatewayShape()
        {
            var r = Parse("""
                {"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],
                  "data":{"msg":"Success.","code":"SUCCESS",
                    "data":{"per1WeekResetTime":1789122720000,"per1WeekPercentage":1.0},
                    "requestId":"x","success":true}},
                  "success":true,"httpStatus":200,"errorCode":"","errorMsg":""},
                 "httpStatusCode":"200","successResponse":true}
                """);
            Assert.NotNull(r.Weekly);
            Assert.Equal(100.0, r.Weekly!.UsedPercentage, 3);
            Assert.Equal(1789122720000, new DateTimeOffset(r.Weekly.EndTime).ToUnixTimeMilliseconds());
            Assert.Null(r.FiveHour);
            Assert.Null(r.Note);
        }

        [Fact]
        public void DeepUnknownShellFallsBackToBfs()
        {
            var r = Parse("""
                {"data":{"DataV2":{"data":{"data":{"wrapper":{"per5HourPercentage":0.5}}}}}}
                """);
            Assert.NotNull(r.FiveHour);
            Assert.Equal(50.0, r.FiveHour!.UsedPercentage, 3);
        }

        [Fact]
        public void NoWindowDataIsNotAnError()
        {
            var r = Parse("""
                {"code":"200","data":{"DataV2":{"data":{"data":{},"success":true}},"success":true,"errorCode":""}}
                """);
            Assert.Null(r.Weekly);
            Assert.Null(r.FiveHour);
            Assert.NotNull(r.Note);
        }

        [Fact]
        public void NotLoginedEnvelopeThrows()
        {
            var ex = Assert.Throws<AliyunChannelException>(() => Parse("""
                {"data":{"success":false,"errorCode":"NotLogined","errorMsg":"x"}}
                """));
            Assert.Equal(AliyunErrorKind.NotLogined, ex.Kind);
        }

        [Fact]
        public void GarbageInputThrowsUnexpectedFormat()
        {
            var ex = Assert.Throws<AliyunChannelException>(() => Parse("not json"));
            Assert.Equal(AliyunErrorKind.UnexpectedFormat, ex.Kind);
        }

        [Theory]
        [InlineData("cn-beijing", "domestic", "bailian-cs.console.aliyun.com", "BroadScopeAspnGateway")]
        [InlineData("cn-beijing", "international", "bailian-cs.console.alibabacloud.com", "BroadScopeAspnGateway")]
        [InlineData("ap-southeast-1", "domestic", "modelstudio-cs.console.aliyun.com", "IntlBroadScopeAspnGateway")]
        [InlineData("ap-southeast-1", "international", "bailian-singapore-cs.alibabacloud.com", "IntlBroadScopeAspnGateway")]
        public void GatewayRoute_MatchesMac(string region, string site, string host, string action)
        {
            var route = AliyunBailianService.GatewayRoute(region, site);
            Assert.Equal(host, route.Host);
            Assert.Equal(action, route.Action);
        }

        [Theory]
        [InlineData("cn-beijing", "cn-beijing")]
        [InlineData(" ap-southeast-1 ", "ap-southeast-1")]
        [InlineData("", "cn-beijing")]
        [InlineData(null, "cn-beijing")]
        [InlineData("cn-beijing --output text", "cn-beijing")]
        [InlineData("\"x\"", "cn-beijing")]
        public void SanitizeCliArg_RejectsShellMetacharacters(string? input, string expected)
        {
            Assert.Equal(expected, AliyunBailianService.SanitizeCliArg(input, "cn-beijing"));
        }
    }
}
