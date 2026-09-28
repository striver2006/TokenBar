using System;
using System.Net;
using System.Net.Http;
using TokenBar.I18n;
using TokenBar.Models;
using TokenBar.Services;
using Xunit;

namespace TokenBar.Tests
{
    /// <summary>
    /// ProviderShared 共享件测试：endpoint 规范化、key 尾号掩码、响应头读取、
    /// 速率窗口构造（构造的 HttpResponseMessage 喂头）、401/429/非2xx 错误分类文案逐字断言。
    /// 这些行为是从各 Provider Service 原实现逐字搬迁的，测试即「文案/数值不许漂移」的回归网。
    ///
    /// 注意：LocalizationManager 是全局单例，测试工程已在 AssemblyInfo.cs 禁用并行。
    /// </summary>
    public sealed class ProviderSharedTests : IDisposable
    {
        private readonly AppLanguage _originalLanguage;

        public ProviderSharedTests()
        {
            _originalLanguage = LocalizationManager.Instance.CurrentLanguage;
        }

        public void Dispose()
        {
            LocalizationManager.Instance.SetLanguage(_originalLanguage);
        }

        private static HttpResponseMessage Response(HttpStatusCode status, string body = "")
        {
            return new HttpResponseMessage(status)
            {
                Content = new StringContent(body)
            };
        }

        // ---------- NormalizeEndpoint ----------

        [Theory]
        [InlineData("https://api.x.com/v1", "https://api.x.com/v1")]
        [InlineData("  https://api.x.com/v1  ", "https://api.x.com/v1")]
        [InlineData("https://api.x.com/v1/", "https://api.x.com/v1")]
        [InlineData("https://api.x.com/v1///", "https://api.x.com/v1")]
        public void NormalizeEndpoint_TrimsAndStripsTrailingSlashes(string input, string expected)
        {
            Assert.Equal(expected, ProviderShared.NormalizeEndpoint(input, "fallback"));
        }

        [Theory]
        [InlineData("")]
        [InlineData("   ")]
        [InlineData("/")]
        [InlineData("///")]
        public void NormalizeEndpoint_EmptyAfterTrim_FallsBack(string input)
        {
            Assert.Equal("https://fallback.example/v1", ProviderShared.NormalizeEndpoint(input, "https://fallback.example/v1"));
        }

        [Fact]
        public void NormalizeEndpoint_EmptyFallback_ReplacesEmptyResult()
        {
            // GLM 用法：无兜底，空进空出（与原「只 trim 不兜底」等价）
            Assert.Equal(string.Empty, ProviderShared.NormalizeEndpoint(" / ", string.Empty));
        }

        // ---------- ModelsUrl ----------

        [Theory]
        [InlineData("https://api.x.com/v1", "https://api.x.com/v1/models")]
        [InlineData("https://api.x.com/v1/models", "https://api.x.com/v1/models")]
        [InlineData("https://api.x.com/v1/MODELS", "https://api.x.com/v1/MODELS")]
        [InlineData("https://api.x.com/v1/models/", "https://api.x.com/v1/models//models")]
        public void ModelsUrl_AppendsUnlessAlreadyModels(string baseEndpoint, string expected)
        {
            Assert.Equal(expected, ProviderShared.ModelsUrl(baseEndpoint));
        }

        // ---------- KeySuffixMask ----------

        [Theory]
        [InlineData("sk-1234567890", "7890")]     // Length > 6 → 末 4 位
        [InlineData("abcdefg", "defg")]           // Length == 7 → 末 4 位
        [InlineData("abcdef", "abcdef")]          // Length == 6 → 原样
        [InlineData("abc", "abc")]                // 短 key 不截断
        [InlineData("", "")]
        public void KeySuffixMask_MatchesLegacyGuardedSlice(string key, string expected)
        {
            Assert.Equal(expected, ProviderShared.KeySuffixMask(key));
        }

        // ---------- GetHeader ----------

        [Fact]
        public void GetHeader_PrefersResponseHeaders_ThenFallsBackToContentHeaders()
        {
            using var resp = Response(HttpStatusCode.OK);
            resp.Headers.TryAddWithoutValidation("x-only-response", "rv");
            resp.Content.Headers.TryAddWithoutValidation("x-only-content", "cv");
            resp.Headers.TryAddWithoutValidation("x-both", "from-response");
            resp.Content.Headers.TryAddWithoutValidation("x-both", "from-content");

            Assert.Equal("rv", resp.GetHeader("x-only-response"));
            Assert.Equal("cv", resp.GetHeader("x-only-content"));
            Assert.Equal("from-response", resp.GetHeader("x-both"));
            Assert.Null(resp.GetHeader("x-missing"));
        }

        // ---------- BuildRateLimitWindow：x-ratelimit 家族（带 reset 头） ----------

        [Fact]
        public void BuildRateLimitWindow_OpenAITokens_MatchesLegacyNumbers()
        {
            using var resp = Response(HttpStatusCode.OK);
            resp.Headers.TryAddWithoutValidation("x-ratelimit-limit-tokens", "1000");
            resp.Headers.TryAddWithoutValidation("x-ratelimit-remaining-tokens", "250");
            resp.Headers.TryAddWithoutValidation("x-ratelimit-reset-tokens", "60");

            var before = DateTime.Now;
            var window = resp.BuildRateLimitWindow(RateLimitHeaderSet.OpenAI("tokens"), WindowTitle.TpmRate, "tokens");
            var after = DateTime.Now;

            Assert.NotNull(window);
            Assert.Equal(WindowTitle.TpmRate, window!.Title);
            Assert.Equal(75.0, window.UsedPercentage, 10);
            Assert.Equal(750.0, window.UsedAmount);
            Assert.Equal(1000.0, window.TotalLimit);
            Assert.Equal("tokens", window.Unit);
            Assert.False(window.IsIdle);
            Assert.Equal(TimeSpan.FromSeconds(60), window.EndTime - window.StartTime);
            Assert.InRange(window.StartTime, before, after);
        }

        [Fact]
        public void BuildRateLimitWindow_MissingResetHeader_FallsBackToOneSecond()
        {
            using var resp = Response(HttpStatusCode.OK);
            resp.Headers.TryAddWithoutValidation("x-ratelimit-limit-tokens", "1000");
            resp.Headers.TryAddWithoutValidation("x-ratelimit-remaining-tokens", "1000");

            var window = resp.BuildRateLimitWindow(RateLimitHeaderSet.OpenAI("tokens"), WindowTitle.TpmRate, "tokens");

            Assert.NotNull(window);
            Assert.Equal(TimeSpan.FromSeconds(1), window!.EndTime - window.StartTime);
            // used == 0 → IsIdle（与 usedPct 判定无关，逐字保留原语义）
            Assert.Equal(0.0, window.UsedPercentage);
            Assert.Equal(0.0, window.UsedAmount);
            Assert.True(window.IsIdle);
        }

        [Theory]
        [InlineData(null, "250", "60")]        // 缺 limit 头
        [InlineData("1000", null, "60")]       // 缺 remaining 头
        [InlineData("0", "0", "60")]           // limit <= 0
        [InlineData("-5", "0", "60")]          // limit <= 0
        [InlineData("abc", "250", "60")]       // 解析失败
        public void BuildRateLimitWindow_InvalidHeaders_ReturnNull(string? limit, string? remaining, string? reset)
        {
            using var resp = Response(HttpStatusCode.OK);
            if (limit != null) resp.Headers.TryAddWithoutValidation("x-ratelimit-limit-tokens", limit);
            if (remaining != null) resp.Headers.TryAddWithoutValidation("x-ratelimit-remaining-tokens", remaining);
            if (reset != null) resp.Headers.TryAddWithoutValidation("x-ratelimit-reset-tokens", reset);

            Assert.Null(resp.BuildRateLimitWindow(RateLimitHeaderSet.OpenAI("tokens"), WindowTitle.TpmRate, "tokens"));
        }

        [Fact]
        public void BuildRateLimitWindow_ClampsAndFloorsLikeLegacyMath()
        {
            // remaining > limit → used = Math.Max(0, …) = 0，IsIdle
            using var over = Response(HttpStatusCode.OK);
            over.Headers.TryAddWithoutValidation("x-ratelimit-limit-tokens", "100");
            over.Headers.TryAddWithoutValidation("x-ratelimit-remaining-tokens", "150");
            var w1 = over.BuildRateLimitWindow(RateLimitHeaderSet.OpenAI("tokens"), WindowTitle.TpmRate, "tokens");
            Assert.NotNull(w1);
            Assert.Equal(0.0, w1!.UsedAmount);
            Assert.Equal(0.0, w1.UsedPercentage);
            Assert.True(w1.IsIdle);

            // remaining 为负 → usedPct clamp 到 100
            using var under = Response(HttpStatusCode.OK);
            under.Headers.TryAddWithoutValidation("x-ratelimit-limit-tokens", "100");
            under.Headers.TryAddWithoutValidation("x-ratelimit-remaining-tokens", "-50");
            var w2 = under.BuildRateLimitWindow(RateLimitHeaderSet.OpenAI("tokens"), WindowTitle.TpmRate, "tokens");
            Assert.NotNull(w2);
            Assert.Equal(150.0, w2!.UsedAmount);
            Assert.Equal(100.0, w2.UsedPercentage);
            Assert.False(w2.IsIdle);
        }

        [Fact]
        public void BuildRateLimitWindow_ReadsContentHeadersToo()
        {
            // 部分网关把 x-ratelimit-* 放在 content headers：查找顺序 response → content 必须保留
            using var resp = Response(HttpStatusCode.OK);
            resp.Content.Headers.TryAddWithoutValidation("x-ratelimit-limit-tokens", "800");
            resp.Content.Headers.TryAddWithoutValidation("x-ratelimit-remaining-tokens", "600");
            resp.Content.Headers.TryAddWithoutValidation("x-ratelimit-reset-tokens", "30");

            var window = resp.BuildRateLimitWindow(RateLimitHeaderSet.OpenAI("tokens"), WindowTitle.TpmRate, "tokens");

            Assert.NotNull(window);
            Assert.Equal(200.0, window!.UsedAmount);
            Assert.Equal(800.0, window.TotalLimit);
            Assert.Equal(TimeSpan.FromSeconds(30), window.EndTime - window.StartTime);
        }

        // ---------- BuildRateLimitWindow：anthropic 家族 / 固定 1 分钟窗 / Gemini 候选回退 ----------

        [Fact]
        public void BuildRateLimitWindow_AnthropicFixedWindow_UsesAnthropicHeaderOrderAndOneMinute()
        {
            using var resp = Response(HttpStatusCode.OK);
            resp.Headers.TryAddWithoutValidation("anthropic-ratelimit-tokens-limit", "50000");
            resp.Headers.TryAddWithoutValidation("anthropic-ratelimit-tokens-remaining", "10000");

            var window = resp.BuildRateLimitWindow(
                RateLimitHeaderSet.AnthropicFixedWindow("tokens"), WindowTitle.TpmRate, "tokens");

            Assert.NotNull(window);
            Assert.Equal(WindowTitle.TpmRate, window!.Title);
            Assert.Equal(40000.0, window.UsedAmount);
            Assert.Equal(TimeSpan.FromMinutes(1), window.EndTime - window.StartTime);

            // x-ratelimit 家族的头名不应命中 anthropic 集合
            using var resp2 = Response(HttpStatusCode.OK);
            resp2.Headers.TryAddWithoutValidation("x-ratelimit-limit-tokens", "50000");
            resp2.Headers.TryAddWithoutValidation("x-ratelimit-remaining-tokens", "10000");
            Assert.Null(resp2.BuildRateLimitWindow(
                RateLimitHeaderSet.AnthropicFixedWindow("tokens"), WindowTitle.TpmRate, "tokens"));
        }

        [Fact]
        public void BuildRateLimitWindow_AnthropicWithResetHeader_UsesParsedDuration()
        {
            // Custom-Anthropic tokens 窗：anthropic-ratelimit-tokens-reset 决定时长
            using var resp = Response(HttpStatusCode.OK);
            resp.Headers.TryAddWithoutValidation("anthropic-ratelimit-tokens-limit", "2000");
            resp.Headers.TryAddWithoutValidation("anthropic-ratelimit-tokens-remaining", "500");
            resp.Headers.TryAddWithoutValidation("anthropic-ratelimit-tokens-reset", "45s");

            var window = resp.BuildRateLimitWindow(
                RateLimitHeaderSet.Anthropic("tokens"), WindowTitle.TokenRate, "tokens");

            Assert.NotNull(window);
            Assert.Equal(WindowTitle.TokenRate, window!.Title);
            Assert.Equal(TimeSpan.FromSeconds(45), window.EndTime - window.StartTime);
        }

        [Fact]
        public void BuildRateLimitWindow_GeminiStyleCandidates_FallsBackToRpmHeaders()
        {
            // Gemini：requests 头缺失时按序回退 rpm 头（原 GetHeader(...) ?? GetHeader(...) 链）
            using var resp = Response(HttpStatusCode.OK);
            resp.Headers.TryAddWithoutValidation("x-ratelimit-limit-rpm", "60");
            resp.Headers.TryAddWithoutValidation("x-ratelimit-remaining-rpm", "15");

            var window = resp.BuildRateLimitWindow(
                RateLimitHeaderSet.OpenAIFixedWindow("requests", "rpm"), WindowTitle.RpmRate, "req/min");

            Assert.NotNull(window);
            Assert.Equal(WindowTitle.RpmRate, window!.Title);
            Assert.Equal("req/min", window.Unit);
            Assert.Equal(45.0, window.UsedAmount);
            Assert.Equal(75.0, window.UsedPercentage, 10);
            Assert.Equal(TimeSpan.FromMinutes(1), window.EndTime - window.StartTime);

            // requests 头存在时优先于 rpm
            using var resp2 = Response(HttpStatusCode.OK);
            resp2.Headers.TryAddWithoutValidation("x-ratelimit-limit-requests", "100");
            resp2.Headers.TryAddWithoutValidation("x-ratelimit-remaining-requests", "100");
            resp2.Headers.TryAddWithoutValidation("x-ratelimit-limit-rpm", "60");
            resp2.Headers.TryAddWithoutValidation("x-ratelimit-remaining-rpm", "15");
            var window2 = resp2.BuildRateLimitWindow(
                RateLimitHeaderSet.OpenAIFixedWindow("requests", "rpm"), WindowTitle.RpmRate, "req/min");
            Assert.Equal(100.0, window2!.TotalLimit);
            Assert.True(window2.IsIdle);
        }

        // ---------- ProviderHttpErrors：文案逐字断言 ----------

        [Fact]
        public void ThrowForStatus_Success_DoesNotThrow()
        {
            using var resp = Response(HttpStatusCode.OK, "{}");
            ProviderHttpErrors.ThrowForStatus(resp, "{}", ProviderHttpErrorOptions.DeepSeek);
        }

        [Fact]
        public void ThrowForStatus_DeepSeek_ExactMessages()
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", ProviderHttpErrorOptions.DeepSeek));
                Assert.Equal("DeepSeek API Key 无效或未授权 (HTTP 401)", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "", ProviderHttpErrorOptions.DeepSeek));
                Assert.Equal("DeepSeek 请求达到速率限制或额度不足 (HTTP 429)", ex.Message);
            }
            using (var r500 = Response(HttpStatusCode.InternalServerError, new string('x', 150)))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, new string('x', 150), ProviderHttpErrorOptions.DeepSeek));
                // 原版不带状态码；摘要截 100
                Assert.Equal($"DeepSeek 接口异常: {new string('x', 100)}", ex.Message);
            }

            LocalizationManager.Instance.SetLanguage(AppLanguage.En);
            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", ProviderHttpErrorOptions.DeepSeek));
                Assert.Equal("DeepSeek API Key is invalid or unauthorized (HTTP 401)", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "", ProviderHttpErrorOptions.DeepSeek));
                Assert.Equal("DeepSeek rate limit reached or quota insufficient (HTTP 429)", ex.Message);
            }
            using (var r503 = Response(HttpStatusCode.ServiceUnavailable, "boom"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r503, "boom", ProviderHttpErrorOptions.DeepSeek));
                Assert.Equal("DeepSeek API error: boom", ex.Message);
            }
        }

        [Fact]
        public void ThrowForStatus_Anthropic_ExactMessages()
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", ProviderHttpErrorOptions.Anthropic));
                Assert.Equal("Anthropic API Key 无效或未授权 (HTTP 401)", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "", ProviderHttpErrorOptions.Anthropic));
                Assert.Equal("Anthropic 请求频率或额度超限 (HTTP 429)", ex.Message);
            }
            using (var r500 = Response(HttpStatusCode.InternalServerError, "oops"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, "oops", ProviderHttpErrorOptions.Anthropic));
                Assert.Equal("Anthropic 接口响应异常: oops", ex.Message);
            }

            LocalizationManager.Instance.SetLanguage(AppLanguage.En);
            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", ProviderHttpErrorOptions.Anthropic));
                Assert.Equal("Anthropic API Key is invalid or unauthorized (HTTP 401)", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "", ProviderHttpErrorOptions.Anthropic));
                Assert.Equal("Anthropic rate limit or quota exceeded (HTTP 429)", ex.Message);
            }
            using (var r500 = Response(HttpStatusCode.InternalServerError, "oops"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, "oops", ProviderHttpErrorOptions.Anthropic));
                Assert.Equal("Anthropic API response error: oops", ex.Message);
            }
        }

        [Fact]
        public void ThrowForStatus_Kimi_ExactMessagesWithStatusCode()
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", ProviderHttpErrorOptions.Kimi));
                Assert.Equal("KIMI API Key 无效或未授权 (HTTP 401)", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "", ProviderHttpErrorOptions.Kimi));
                Assert.Equal("KIMI 请求并发超限或额度不足 (HTTP 429)", ex.Message);
            }
            using (var r500 = Response(HttpStatusCode.InternalServerError, "err"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, "err", ProviderHttpErrorOptions.Kimi));
                Assert.Equal("KIMI 接口响应异常 (500): err", ex.Message);
            }

            LocalizationManager.Instance.SetLanguage(AppLanguage.En);
            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", ProviderHttpErrorOptions.Kimi));
                Assert.Equal("KIMI API Key is invalid or unauthorized (HTTP 401)", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "", ProviderHttpErrorOptions.Kimi));
                Assert.Equal("KIMI concurrency limit reached or quota insufficient (HTTP 429)", ex.Message);
            }
            using (var r502 = Response(HttpStatusCode.BadGateway, "err"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r502, "err", ProviderHttpErrorOptions.Kimi));
                Assert.Equal("KIMI API response error (502): err", ex.Message);
            }
        }

        [Fact]
        public void ThrowForStatus_Volcengine_ExactMessages()
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", ProviderHttpErrorOptions.Volcengine));
                Assert.Equal("火山方舟 API Key 无效或未授权 (HTTP 401)", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "", ProviderHttpErrorOptions.Volcengine));
                Assert.Equal("火山方舟并发或速率超限 (HTTP 429)", ex.Message);
            }
            using (var r500 = Response(HttpStatusCode.InternalServerError, "bad"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, "bad", ProviderHttpErrorOptions.Volcengine));
                Assert.Equal("火山方舟响应异常 (500): bad", ex.Message);
            }

            LocalizationManager.Instance.SetLanguage(AppLanguage.En);
            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", ProviderHttpErrorOptions.Volcengine));
                Assert.Equal("Volcengine Ark API Key is invalid or unauthorized (HTTP 401)", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "", ProviderHttpErrorOptions.Volcengine));
                Assert.Equal("Volcengine Ark rate limit or concurrency exceeded (HTTP 429)", ex.Message);
            }
            using (var r500 = Response(HttpStatusCode.InternalServerError, "bad"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, "bad", ProviderHttpErrorOptions.Volcengine));
                Assert.Equal("Volcengine Ark response error (500): bad", ex.Message);
            }
        }

        [Fact]
        public void ThrowForStatus_OpenAI_JsonMessageOverrideAndSnippet120()
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);

            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", ProviderHttpErrorOptions.OpenAI));
                Assert.Equal("OpenAI API Key 无效或已过期 (HTTP 401)", ex.Message);
            }

            // 429 + JSON error.message → 覆盖兜底文案
            const string jsonBody = "{\"error\":{\"message\":\"慢一点\"}}";
            using (var r429 = Response((HttpStatusCode)429, jsonBody))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, jsonBody, ProviderHttpErrorOptions.OpenAI));
                Assert.Equal("慢一点", ex.Message);
            }

            // 429 + 非 JSON → 兜底文案（原版仅 catch JsonException 后继续抛兜底）
            using (var r429 = Response((HttpStatusCode)429, "not json"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "not json", ProviderHttpErrorOptions.OpenAI));
                Assert.Equal("请求过于频繁或额度已耗尽 (HTTP 429)", ex.Message);
            }

            // 429 + error.message 非字符串 → 原实现 GetString() 抛 InvalidOperationException 且不被
            // catch(JsonException) 拦截；共享分类器逐字保留该行为
            const string numericMsg = "{\"error\":{\"message\":42}}";
            using (var r429 = Response((HttpStatusCode)429, numericMsg))
            {
                Assert.Throws<InvalidOperationException>(
                    () => ProviderHttpErrors.ThrowForStatus(r429, numericMsg, ProviderHttpErrorOptions.OpenAI));
            }

            // 非 2xx：摘要截 120（OpenAI 特有）
            var longBody = new string('y', 150);
            using (var r500 = Response(HttpStatusCode.InternalServerError, longBody))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, longBody, ProviderHttpErrorOptions.OpenAI));
                Assert.Equal($"OpenAI 接口请求失败 (500): {new string('y', 120)}", ex.Message);
            }

            LocalizationManager.Instance.SetLanguage(AppLanguage.En);
            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", ProviderHttpErrorOptions.OpenAI));
                Assert.Equal("OpenAI API Key is invalid or expired (HTTP 401)", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429, "not json"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "not json", ProviderHttpErrorOptions.OpenAI));
                Assert.Equal("Rate limit reached or quota exhausted (HTTP 429)", ex.Message);
            }
            using (var r500 = Response(HttpStatusCode.InternalServerError, longBody))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, longBody, ProviderHttpErrorOptions.OpenAI));
                Assert.Equal($"OpenAI request failed (500): {new string('y', 120)}", ex.Message);
            }
        }

        [Fact]
        public void ThrowForStatus_GLM_CoversForbiddenAndInterpolatesStatusCode()
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            using (var r403 = Response(HttpStatusCode.Forbidden))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r403, "", ProviderHttpErrorOptions.GLM));
                Assert.Equal("GLM API Key 无效或未授权 (HTTP 403)", ex.Message);
            }
            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", ProviderHttpErrorOptions.GLM));
                Assert.Equal("GLM API Key 无效或未授权 (HTTP 401)", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "", ProviderHttpErrorOptions.GLM));
                Assert.Equal("GLM 请求过于频繁或额度已耗尽 (HTTP 429)", ex.Message);
            }
            var longBody = new string('z', 150);
            using (var r500 = Response(HttpStatusCode.InternalServerError, longBody))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, longBody, ProviderHttpErrorOptions.GLM));
                Assert.Equal($"GLM 接口请求失败 (500): {new string('z', 120)}", ex.Message);
            }

            // 403 覆盖是 GLM 专属：其它预设（如 DeepSeek）遇 403 走非 2xx 摘要分支
            LocalizationManager.Instance.SetLanguage(AppLanguage.En);
            using (var r403 = Response(HttpStatusCode.Forbidden, "denied"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r403, "denied", ProviderHttpErrorOptions.DeepSeek));
                Assert.Equal("DeepSeek API error: denied", ex.Message);
            }
            using (var r403 = Response(HttpStatusCode.Forbidden))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r403, "", ProviderHttpErrorOptions.GLM));
                Assert.Equal("GLM API Key is invalid or unauthorized (HTTP 403)", ex.Message);
            }
        }

        [Fact]
        public void ThrowForStatus_GLM_SplitCallsAllowProbeCheckInBetween()
        {
            // GLM 的真实调用序列：401/403 → 429 → (200 里的 code:1001 检查) → 非 2xx。
            // 三段拆开调用时，200 响应必须三段全过、不抛任何异常。
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            using var resp = Response(HttpStatusCode.OK, "{\"code\":1001,\"msg\":\"x\"}");
            ProviderHttpErrors.ThrowIfUnauthorized(resp, ProviderHttpErrorOptions.GLM);
            ProviderHttpErrors.ThrowIfRateLimited(resp, "{\"code\":1001,\"msg\":\"x\"}", ProviderHttpErrorOptions.GLM);
            ProviderHttpErrors.ThrowIfNotSuccess(resp, "{\"code\":1001,\"msg\":\"x\"}", ProviderHttpErrorOptions.GLM);
        }

        [Fact]
        public void ThrowForStatus_CustomOpenAI_InterpolatesProviderName()
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            var options = ProviderHttpErrorOptions.CustomOpenAI("我的代理");

            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", options));
                Assert.Equal("我的代理 API Key 认证失败 (HTTP 401)，请核对密钥", ex.Message);
            }

            const string jsonBody = "{\"error\":{\"message\":\"quota gone\"}}";
            using (var r429 = Response((HttpStatusCode)429, jsonBody))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, jsonBody, options));
                Assert.Equal("quota gone", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429, "nope"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "nope", options));
                Assert.Equal("请求过于频繁或额度不足 (HTTP 429)", ex.Message);
            }
            using (var r500 = Response(HttpStatusCode.InternalServerError, "failed!"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, "failed!", options));
                Assert.Equal("请求端点失败 (500): failed!", ex.Message);
            }

            LocalizationManager.Instance.SetLanguage(AppLanguage.En);
            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", options));
                Assert.Equal("我的代理 API Key authentication failed (HTTP 401). Please check the key", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429, "nope"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "nope", options));
                Assert.Equal("Rate limit reached or quota insufficient (HTTP 429)", ex.Message);
            }
            using (var r500 = Response(HttpStatusCode.InternalServerError, "failed!"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, "failed!", options));
                Assert.Equal("Endpoint request failed (500): failed!", ex.Message);
            }
        }

        [Fact]
        public void ThrowForStatus_CustomOpenAI_ProviderNameWithBracesIsNotFormatInterpreted()
        {
            // 文案用委托内插而非 string.Format：厂商名含 '{' 不能被误当占位符（原实现同样安全）
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            var options = ProviderHttpErrorOptions.CustomOpenAI("代理{0}");
            using var r401 = Response(HttpStatusCode.Unauthorized);
            var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", options));
            Assert.Equal("代理{0} API Key 认证失败 (HTTP 401)，请核对密钥", ex.Message);
        }

        [Fact]
        public void ThrowForStatus_CustomAnthropic_ExactMessages()
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            var options = ProviderHttpErrorOptions.CustomAnthropic("中转站");

            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", options));
                Assert.Equal("中转站 Anthropic API Key 无效或未授权 (HTTP 401)", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "", options));
                Assert.Equal("Anthropic 接口请求已触发速率限制 (HTTP 429)", ex.Message);
            }
            using (var r500 = Response(HttpStatusCode.InternalServerError, "err"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, "err", options));
                Assert.Equal("Anthropic 兼容端点响应异常 (500): err", ex.Message);
            }

            LocalizationManager.Instance.SetLanguage(AppLanguage.En);
            using (var r401 = Response(HttpStatusCode.Unauthorized))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r401, "", options));
                Assert.Equal("中转站 Anthropic API Key invalid or unauthorized (HTTP 401)", ex.Message);
            }
            using (var r429 = Response((HttpStatusCode)429))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r429, "", options));
                Assert.Equal("Anthropic rate limit exceeded (HTTP 429)", ex.Message);
            }
            using (var r500 = Response(HttpStatusCode.InternalServerError, "err"))
            {
                var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(r500, "err", options));
                Assert.Equal("Anthropic compatible endpoint error (500): err", ex.Message);
            }
        }

        [Fact]
        public void ThrowForStatus_SnippetShorterThanLimit_NotTruncated()
        {
            LocalizationManager.Instance.SetLanguage(AppLanguage.ZhHans);
            using var resp = Response(HttpStatusCode.InternalServerError, "短错误");
            var ex = Assert.Throws<Exception>(() => ProviderHttpErrors.ThrowForStatus(resp, "短错误", ProviderHttpErrorOptions.Kimi));
            Assert.Equal("KIMI 接口响应异常 (500): 短错误", ex.Message);
        }
    }
}
