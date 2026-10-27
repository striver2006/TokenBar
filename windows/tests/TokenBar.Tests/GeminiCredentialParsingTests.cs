using System;
using System.Text;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// Gemini 凭证链的纯函数测试：token 端点错误分类（invalid_grant 判决）与
    /// id_token email 解析。这两处决定「冷却期文案」是否掩盖真实根因。
    /// </summary>
    public class GeminiCredentialParsingTests
    {
        [Theory]
        [InlineData("""{"error":"invalid_grant","error_description":"Bad Request"}""", "invalid_grant")]
        [InlineData("""{"error":"invalid_client"}""", "invalid_client")]
        [InlineData("""{"error":"unauthorized_client"}""", "unauthorized_client")]
        [InlineData("""{"error":{"code":"invalid_grant"},"error_description":"Token expired"}""", "invalid_grant")]
        [InlineData("""{"access_token":"x"}""", null)]
        [InlineData("not json at all", null)]
        [InlineData("", null)]
        public void ParseTokenErrorCode_ClassifiesOAuthErrors(string body, string? expected)
        {
            Assert.Equal(expected, GeminiService.ParseTokenErrorCode(body));
        }

        private static string MakeIdToken(string payloadJson)
        {
            static string B64Url(string s) =>
                Convert.ToBase64String(Encoding.UTF8.GetBytes(s)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
            return $"{B64Url("{\"alg\":\"none\"}")}.{B64Url(payloadJson)}.sig";
        }

        [Fact]
        public void EmailFromIdToken_ReturnsEmail()
        {
            var token = MakeIdToken("""{"email":"user@example.com","sub":"123"}""");
            Assert.Equal("user@example.com", GeminiService.EmailFromIdToken(token));
        }

        [Theory]
        [InlineData(null)]
        [InlineData("")]
        [InlineData("garbage")]
        [InlineData("a.b.c")]
        public void EmailFromIdToken_BadInput_ReturnsNull(string? token)
        {
            Assert.Null(GeminiService.EmailFromIdToken(token));
        }

        [Fact]
        public void EmailFromIdToken_NoEmailClaim_ReturnsNull()
        {
            var token = MakeIdToken("""{"sub":"123"}""");
            Assert.Null(GeminiService.EmailFromIdToken(token));
        }

        // v1.7.6 回归锚点：授权 URL 的参数集与 scope 集合是「点登录弹 403 restricted_client」
        // 修复（登录前探测甄别 client）的输入，任何一处被改动都应显式更新这里。
        [Fact]
        public void BuildGoogleAuthorizeUrl_ContainsScopeAndLoopback()
        {
            var url = GeminiService.BuildGoogleAuthorizeUrl("1234567890-abcdefg.apps.googleusercontent.com", 45678);
            Assert.StartsWith("https://accounts.google.com/o/oauth2/v2/auth?", url);
            Assert.Contains("client_id=1234567890-abcdefg.apps.googleusercontent.com", url);
            Assert.Contains("redirect_uri=http%3A%2F%2Flocalhost%3A45678", url);
            Assert.Contains("response_type=code", url);
            Assert.Contains("access_type=offline", url);
            Assert.Contains("prompt=consent", url);
        }

        [Fact]
        public void LoginScopes_IncludeRestrictedAicodeScope()
        {
            // aicode 是受限 scope：client 没注册它时授权页直接 403（v1.7.5 现场），
            // 且配额接口依赖这一整套 scope，缺一个周额度分组就没了。
            Assert.Contains("https://www.googleapis.com/auth/aicode", GeminiService.LoginScopes);
            Assert.Contains("https://www.googleapis.com/auth/cloud-platform", GeminiService.LoginScopes);
            Assert.Contains("openid", GeminiService.LoginScopes);
        }
    }
}