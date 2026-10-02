using System;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// Claude Code 凭证（%USERPROFILE%\.claude\.credentials.json）的纯解析与可用性判定。
    /// 用例与 mac 端 testParseClaudeCodeCredential / testParseClaudeCodeCredentialRejectsMalformed /
    /// testClaudeCodeCredentialUsability 对齐。
    /// </summary>
    public class ClaudeCodeCredentialTests
    {
        private static readonly DateTime Now = new DateTime(2026, 10, 2, 18, 40, 0, DateTimeKind.Local);

        [Fact]
        public void Parse_TakesTrimmedAccessTokenAndExpiry()
        {
            // 与 Claude Code 写入的结构一致；refreshToken 存在但绝不能被取用
            var json = """
                {"claudeAiOauth":{"accessToken":" sk-ant-oat01-test ","refreshToken":"sk-ant-ort01-test",
                 "expiresAt":1790966400000,"scopes":["user:inference"],"subscriptionType":"max"}}
                """;

            var credential = ClaudeService.ParseClaudeCodeCredential(json);

            Assert.NotNull(credential);
            Assert.Equal("sk-ant-oat01-test", credential!.AccessToken);
            Assert.NotNull(credential.ExpiresAt);
            Assert.Equal(1790966400000, new DateTimeOffset(credential.ExpiresAt!.Value).ToUnixTimeMilliseconds());
        }

        [Fact]
        public void Parse_RejectsMalformed()
        {
            Assert.Null(ClaudeService.ParseClaudeCodeCredential("not json"));
            Assert.Null(ClaudeService.ParseClaudeCodeCredential("""{"other":{}}"""));
            Assert.Null(ClaudeService.ParseClaudeCodeCredential("[]"));
            // Claude Code 把失效的 refresh token 标死时会清空 accessToken，不能当成可用凭证
            Assert.Null(ClaudeService.ParseClaudeCodeCredential("""{"claudeAiOauth":{"accessToken":""}}"""));
        }

        [Fact]
        public void Parse_WithoutExpiry_IsUsable()
        {
            // 没有 expiresAt：照常可用，401 时自然退回缓存
            var credential = ClaudeService.ParseClaudeCodeCredential("""{"claudeAiOauth":{"accessToken":"t"}}""");

            Assert.Equal(new ClaudeCodeCredential("t", null), credential);
            Assert.True(credential!.IsUsable(Now));
        }

        [Fact]
        public void IsUsable_RequiresMoreThanOneMinuteLeft()
        {
            Assert.True(new ClaudeCodeCredential("t", Now.AddHours(1)).IsUsable(Now));
            // 离过期不足 60 秒：请求在途中过期只会换来 401
            Assert.False(new ClaudeCodeCredential("t", Now.AddSeconds(30)).IsUsable(Now));
            Assert.False(new ClaudeCodeCredential("t", Now.AddSeconds(-1)).IsUsable(Now));
        }
    }
}
