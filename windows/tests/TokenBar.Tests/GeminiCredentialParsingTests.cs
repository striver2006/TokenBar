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
    }
}
