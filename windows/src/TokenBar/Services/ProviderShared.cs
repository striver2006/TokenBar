using System;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using TokenBar.Helpers;
using TokenBar.Models;

namespace TokenBar.Services
{
    /// <summary>
    /// 各 Provider Service 之间复制粘贴的模板代码收敛到这里：endpoint 规范化、
    /// /models 拼接、key 尾号掩码、响应头读取、x-ratelimit / anthropic-ratelimit
    /// 速率窗口构造、401/429/非2xx 错误分类、Moonshot 余额查询。
    ///
    /// 铁律：这是纯结构重构 —— 所有用户可见行为（错误文案、窗口标题/数值/Unit/IsIdle、
    /// 账号字符串、日志）必须与各服务原实现逐字节一致。任何 provider 间的细微差异
    /// 都通过参数保留，不做「顺手统一」。
    /// </summary>
    public static class ProviderShared
    {
        /// <summary>
        /// endpoint 规范化：Trim + 去尾部斜杠，结果为空时回退 fallback。
        /// 与各服务原来的「Trim().TrimEnd('/') + if empty 赋默认值」块逐字等价
        /// （GLM 传空串 fallback，等价于它原本「无兜底」的行为）。
        /// </summary>
        public static string NormalizeEndpoint(string endpoint, string fallback)
        {
            var trimmed = endpoint.Trim().TrimEnd('/');
            return string.IsNullOrEmpty(trimmed) ? fallback : trimmed;
        }

        /// <summary>拼 /models 列表地址：已以 /models 结尾（忽略大小写）则原样返回。</summary>
        public static string ModelsUrl(string baseEndpoint)
        {
            return baseEndpoint.EndsWith("/models", StringComparison.OrdinalIgnoreCase)
                ? baseEndpoint
                : $"{baseEndpoint}/models";
        }

        /// <summary>API Key 尾号掩码：长度 > 6 时取末 4 位，否则原样返回（短 Key 不截断）。</summary>
        public static string KeySuffixMask(string key)
        {
            return key.Length > 6 ? key[^4..] : key;
        }

        /// <summary>
        /// 大小写不敏感读取响应头的第一个值：先查 response headers，再查 content headers
        /// （x-ratelimit-* 在不同网关下可能落在任意一侧）。取代 8 份手写 GetHeader 局部函数，
        /// 查找顺序与原实现一致。
        /// </summary>
        public static string? GetHeader(this HttpResponseMessage response, string name)
        {
            if (response.Headers.TryGetValues(name, out var values))
                return values.FirstOrDefault();
            if (response.Content.Headers.TryGetValues(name, out var cv))
                return cv.FirstOrDefault();
            return null;
        }

        /// <summary>按候选顺序取第一个非 null 的响应头值（Gemini 的 requests ?? rpm 回退）。</summary>
        private static string? FirstHeader(HttpResponseMessage response, string[] names)
        {
            foreach (var name in names)
            {
                var value = response.GetHeader(name);
                if (value != null) return value;
            }
            return null;
        }

        /// <summary>
        /// 从响应头三元组（limit / remaining / reset）构造速率窗口。
        /// 数值行为与 5 份 x-ratelimit + 2 份 anthropic-ratelimit 原实现逐字一致：
        ///   - limit / remaining 任一解析失败（Float, InvariantCulture）或 limit &lt;= 0 → null；
        ///   - used = Math.Max(0, limit - remaining)；usedPct = Clamp(used/limit*100, 0, 100)；
        ///   - 带 reset 头：duration = RateLimitReset.Parse(reset) ?? 1 秒；无 reset 头：固定 1 分钟；
        ///   - IsIdle = used == 0；StartTime = now；EndTime = now + duration。
        /// 标题与 Unit 由调用方给定（各 provider 不同：TpmRate/TpmRemaining/RpmRate/RpmRequest/TokenRate，
        /// "tokens"/"req"/"req/min"），此处不做任何统一。
        /// </summary>
        public static TokenWindow? BuildRateLimitWindow(
            this HttpResponseMessage response,
            RateLimitHeaderSet headers,
            WindowTitle title,
            string unit)
        {
            var limitStr = FirstHeader(response, headers.LimitHeaders);
            var remainingStr = FirstHeader(response, headers.RemainingHeaders);

            if (!double.TryParse(limitStr, NumberStyles.Float, CultureInfo.InvariantCulture, out var limit) ||
                !double.TryParse(remainingStr, NumberStyles.Float, CultureInfo.InvariantCulture, out var remaining) ||
                limit <= 0)
            {
                return null;
            }

            var used = Math.Max(0.0, limit - remaining);
            var usedPct = Math.Clamp((used / limit) * 100.0, 0.0, 100.0);
            var duration = headers.HasResetHeader
                ? TimeSpan.FromSeconds(RateLimitReset.Parse(FirstHeader(response, headers.ResetHeaders)) ?? 1)
                : TimeSpan.FromMinutes(1);
            var now = DateTime.Now;

            return new TokenWindow
            {
                Title = title,
                UsedPercentage = usedPct,
                StartTime = now,
                EndTime = now.Add(duration),
                UsedAmount = used,
                TotalLimit = limit,
                Unit = unit,
                IsIdle = used == 0.0
            };
        }

        /// <summary>
        /// 查询 Moonshot（KIMI）账户余额（人民币），失败返回 null。
        /// KimiService 与 CustomProviderService 的差异全部参数化：
        ///   - balanceUrl：Kimi 用「用户 endpoint + /users/me/balance」，Custom 固定官方地址；
        ///   - allowCashBalanceFallback：Kimi 在 available_balance 缺失时回退 cash_balance，Custom 不回退；
        ///   - logFailurePrefix：日志文案逐字保留（"kimi 余额查询失败" / "custom 余额/套餐查询失败"）。
        /// DeepSeek 余额不在此列：win 端 CustomProviderService 本就委托 DeepSeekService.FetchBalanceAsync，无重复。
        /// </summary>
        public static async Task<decimal?> FetchMoonshotBalanceAsync(
            string apiKey,
            string balanceUrl,
            bool allowCashBalanceFallback,
            string logFailurePrefix,
            CancellationToken ct = default)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, balanceUrl);
                req.Headers.Add("Authorization", $"Bearer {apiKey}");

                using var resp = await Http.Shared.SendAsync(req, ct);
                if (!resp.IsSuccessStatusCode) return null;

                var body = await resp.Content.ReadAsStringAsync(ct);
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("data", out var dataObj))
                {
                    if (dataObj.TryGetProperty("available_balance", out var avProp))
                    {
                        if (avProp.ValueKind == JsonValueKind.Number)
                        {
                            return (decimal)avProp.GetDouble();
                        }
                        if (avProp.ValueKind == JsonValueKind.String &&
                            decimal.TryParse(avProp.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsed))
                        {
                            return parsed;
                        }
                    }
                    if (allowCashBalanceFallback &&
                        dataObj.TryGetProperty("cash_balance", out var cashProp) && cashProp.ValueKind == JsonValueKind.Number)
                    {
                        return (decimal)cashProp.GetDouble();
                    }
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                Log.Warn("provider", $"{logFailurePrefix}: {ex.Message}");
            }

            return null;
        }
    }

    /// <summary>
    /// 速率窗口三元头的名字集合。两个家族的头名构词顺序不同，不能只用「前缀+后缀」表达：
    ///   - OpenAI 系：x-ratelimit-limit-{metric} / x-ratelimit-remaining-{metric} / x-ratelimit-reset-{metric}；
    ///   - Anthropic 系：anthropic-ratelimit-{metric}-limit / -remaining / -reset。
    /// 不带 reset 头的组合（Claude / Gemini）用固定 1 分钟窗口，与原实现一致。
    /// </summary>
    public sealed class RateLimitHeaderSet
    {
        public string[] LimitHeaders { get; }
        public string[] RemainingHeaders { get; }
        public string[] ResetHeaders { get; }

        /// <summary>无 reset 头 → 固定 1 分钟窗口。</summary>
        public bool HasResetHeader => ResetHeaders.Length > 0;

        private RateLimitHeaderSet(string[] limitHeaders, string[] remainingHeaders, string[] resetHeaders)
        {
            LimitHeaders = limitHeaders;
            RemainingHeaders = remainingHeaders;
            ResetHeaders = resetHeaders;
        }

        /// <summary>x-ratelimit 家族，窗口时长取 reset 头（DeepSeek/Kimi/Volcengine/OpenAI/Custom-OpenAI）。</summary>
        public static RateLimitHeaderSet OpenAI(string metric) => new(
            new[] { $"x-ratelimit-limit-{metric}" },
            new[] { $"x-ratelimit-remaining-{metric}" },
            new[] { $"x-ratelimit-reset-{metric}" });

        /// <summary>
        /// x-ratelimit 家族，固定 1 分钟窗口；metricCandidates 按序回退
        /// （Gemini：requests 缺失时读 rpm，等价于原实现的两段 GetHeader ?? 链）。
        /// </summary>
        public static RateLimitHeaderSet OpenAIFixedWindow(params string[] metricCandidates) => new(
            metricCandidates.Select(m => $"x-ratelimit-limit-{m}").ToArray(),
            metricCandidates.Select(m => $"x-ratelimit-remaining-{m}").ToArray(),
            Array.Empty<string>());

        /// <summary>anthropic-ratelimit 家族，窗口时长取 reset 头（Custom-Anthropic 的 tokens 窗）。</summary>
        public static RateLimitHeaderSet Anthropic(string metric) => new(
            new[] { $"anthropic-ratelimit-{metric}-limit" },
            new[] { $"anthropic-ratelimit-{metric}-remaining" },
            new[] { $"anthropic-ratelimit-{metric}-reset" });

        /// <summary>anthropic-ratelimit 家族，固定 1 分钟窗口（Claude 的 tokens/requests 窗、Custom 的 requests 窗）。</summary>
        public static RateLimitHeaderSet AnthropicFixedWindow(string metric) => new(
            new[] { $"anthropic-ratelimit-{metric}-limit" },
            new[] { $"anthropic-ratelimit-{metric}-remaining" },
            Array.Empty<string>());
    }

    /// <summary>
    /// 一个 provider 的 401/429/非2xx 文案与行为差异的参数化描述。
    /// 文案用委托而不是格式串：与各服务原实现的内插语义逐字一致，
    /// 且自定义厂商名里含 '{' 时不会被 string.Format 误伤。
    /// 参数约定：code = 实际 HTTP 状态码；snippet = 按 SnippetLength 截取的响应体前缀。
    /// </summary>
    public sealed class ProviderHttpErrorOptions
    {
        /// <summary>401 文案（GLM 额外覆盖 403，文案内插实际状态码）。</summary>
        public required Func<int, string> UnauthorizedZh { get; init; }
        public required Func<int, string> UnauthorizedEn { get; init; }

        /// <summary>true 时 403 与 401 同罪（目前仅 GLM）。</summary>
        public bool IncludeForbidden { get; init; }

        /// <summary>429 兜底文案（ParseRateLimitJsonMessage 命中时被 error.message 覆盖）。</summary>
        public required Func<int, string> RateLimitZh { get; init; }
        public required Func<int, string> RateLimitEn { get; init; }

        /// <summary>429 是否解析响应体 JSON 的 error.message 覆盖兜底文案（OpenAI / Custom-OpenAI）。</summary>
        public bool ParseRateLimitJsonMessage { get; init; }

        /// <summary>ParseRateLimitJsonMessage 解析失败时的日志前缀："{prefix} 429 响应不是 JSON: {ex}"。</summary>
        public string? RateLimitJsonLogPrefix { get; init; }

        /// <summary>非 2xx 文案（DeepSeek/Anthropic 原版不含状态码，其余内插 code 与 snippet）。</summary>
        public required Func<int, string, string> ErrorZh { get; init; }
        public required Func<int, string, string> ErrorEn { get; init; }

        /// <summary>非 2xx 响应体摘要截取长度（100 / 120，各 provider 不同）。</summary>
        public int SnippetLength { get; init; } = 100;

        // ---------- 各 provider 预设：文案逐字取自原实现 ----------

        public static ProviderHttpErrorOptions DeepSeek { get; } = new()
        {
            UnauthorizedZh = _ => "DeepSeek API Key 无效或未授权 (HTTP 401)",
            UnauthorizedEn = _ => "DeepSeek API Key is invalid or unauthorized (HTTP 401)",
            RateLimitZh = _ => "DeepSeek 请求达到速率限制或额度不足 (HTTP 429)",
            RateLimitEn = _ => "DeepSeek rate limit reached or quota insufficient (HTTP 429)",
            ErrorZh = (_, snippet) => $"DeepSeek 接口异常: {snippet}",
            ErrorEn = (_, snippet) => $"DeepSeek API error: {snippet}",
            SnippetLength = 100
        };

        /// <summary>ClaudeService.FetchAnthropicQuotaAsync（Anthropic 官方 API Key 通道）。</summary>
        public static ProviderHttpErrorOptions Anthropic { get; } = new()
        {
            UnauthorizedZh = _ => "Anthropic API Key 无效或未授权 (HTTP 401)",
            UnauthorizedEn = _ => "Anthropic API Key is invalid or unauthorized (HTTP 401)",
            RateLimitZh = _ => "Anthropic 请求频率或额度超限 (HTTP 429)",
            RateLimitEn = _ => "Anthropic rate limit or quota exceeded (HTTP 429)",
            ErrorZh = (_, snippet) => $"Anthropic 接口响应异常: {snippet}",
            ErrorEn = (_, snippet) => $"Anthropic API response error: {snippet}",
            SnippetLength = 100
        };

        /// <summary>KIMI legacy 与 Kimi Code /usages 两条路径共用（文案本就相同）。</summary>
        public static ProviderHttpErrorOptions Kimi { get; } = new()
        {
            UnauthorizedZh = _ => "KIMI API Key 无效或未授权 (HTTP 401)",
            UnauthorizedEn = _ => "KIMI API Key is invalid or unauthorized (HTTP 401)",
            RateLimitZh = _ => "KIMI 请求并发超限或额度不足 (HTTP 429)",
            RateLimitEn = _ => "KIMI concurrency limit reached or quota insufficient (HTTP 429)",
            ErrorZh = (code, snippet) => $"KIMI 接口响应异常 ({code}): {snippet}",
            ErrorEn = (code, snippet) => $"KIMI API response error ({code}): {snippet}",
            SnippetLength = 100
        };

        public static ProviderHttpErrorOptions Volcengine { get; } = new()
        {
            UnauthorizedZh = _ => "火山方舟 API Key 无效或未授权 (HTTP 401)",
            UnauthorizedEn = _ => "Volcengine Ark API Key is invalid or unauthorized (HTTP 401)",
            RateLimitZh = _ => "火山方舟并发或速率超限 (HTTP 429)",
            RateLimitEn = _ => "Volcengine Ark rate limit or concurrency exceeded (HTTP 429)",
            ErrorZh = (code, snippet) => $"火山方舟响应异常 ({code}): {snippet}",
            ErrorEn = (code, snippet) => $"Volcengine Ark response error ({code}): {snippet}",
            SnippetLength = 100
        };

        public static ProviderHttpErrorOptions OpenAI { get; } = new()
        {
            UnauthorizedZh = _ => "OpenAI API Key 无效或已过期 (HTTP 401)",
            UnauthorizedEn = _ => "OpenAI API Key is invalid or expired (HTTP 401)",
            RateLimitZh = _ => "请求过于频繁或额度已耗尽 (HTTP 429)",
            RateLimitEn = _ => "Rate limit reached or quota exhausted (HTTP 429)",
            ParseRateLimitJsonMessage = true,
            RateLimitJsonLogPrefix = "openai",
            ErrorZh = (code, snippet) => $"OpenAI 接口请求失败 ({code}): {snippet}",
            ErrorEn = (code, snippet) => $"OpenAI request failed ({code}): {snippet}",
            SnippetLength = 120
        };

        /// <summary>GLM /models 探测：401+403 同罪且文案内插实际状态码，摘要 120。</summary>
        public static ProviderHttpErrorOptions GLM { get; } = new()
        {
            UnauthorizedZh = code => $"GLM API Key 无效或未授权 (HTTP {code})",
            UnauthorizedEn = code => $"GLM API Key is invalid or unauthorized (HTTP {code})",
            IncludeForbidden = true,
            RateLimitZh = _ => "GLM 请求过于频繁或额度已耗尽 (HTTP 429)",
            RateLimitEn = _ => "GLM rate limit reached or quota exhausted (HTTP 429)",
            ErrorZh = (code, snippet) => $"GLM 接口请求失败 ({code}): {snippet}",
            ErrorEn = (code, snippet) => $"GLM request failed ({code}): {snippet}",
            SnippetLength = 120
        };

        /// <summary>自定义厂商 OpenAI 兼容通道：401/非2xx 文案带厂商名，429 解析 JSON error.message。</summary>
        public static ProviderHttpErrorOptions CustomOpenAI(string name) => new()
        {
            UnauthorizedZh = _ => $"{name} API Key 认证失败 (HTTP 401)，请核对密钥",
            UnauthorizedEn = _ => $"{name} API Key authentication failed (HTTP 401). Please check the key",
            RateLimitZh = _ => "请求过于频繁或额度不足 (HTTP 429)",
            RateLimitEn = _ => "Rate limit reached or quota insufficient (HTTP 429)",
            ParseRateLimitJsonMessage = true,
            RateLimitJsonLogPrefix = "custom",
            ErrorZh = (code, snippet) => $"请求端点失败 ({code}): {snippet}",
            ErrorEn = (code, snippet) => $"Endpoint request failed ({code}): {snippet}",
            SnippetLength = 100
        };

        /// <summary>自定义厂商 Anthropic 兼容通道。</summary>
        public static ProviderHttpErrorOptions CustomAnthropic(string name) => new()
        {
            UnauthorizedZh = _ => $"{name} Anthropic API Key 无效或未授权 (HTTP 401)",
            UnauthorizedEn = _ => $"{name} Anthropic API Key invalid or unauthorized (HTTP 401)",
            RateLimitZh = _ => "Anthropic 接口请求已触发速率限制 (HTTP 429)",
            RateLimitEn = _ => "Anthropic rate limit exceeded (HTTP 429)",
            ErrorZh = (code, snippet) => $"Anthropic 兼容端点响应异常 ({code}): {snippet}",
            ErrorEn = (code, snippet) => $"Anthropic compatible endpoint error ({code}): {snippet}",
            SnippetLength = 100
        };
    }

    /// <summary>
    /// 401/429/非2xx 三段式错误分类器。ThrowForStatus 按原顺序执行三段；
    /// GLM 需要在 429 与非2xx 之间插入「HTTP 200 里的 code:1001 鉴权失败」检查，
    /// 故三段也单独开放，保证各 provider 的判定顺序与原来逐字一致。
    /// </summary>
    public static class ProviderHttpErrors
    {
        public static void ThrowForStatus(HttpResponseMessage response, string body, ProviderHttpErrorOptions options)
        {
            ThrowIfUnauthorized(response, options);
            ThrowIfRateLimited(response, body, options);
            ThrowIfNotSuccess(response, body, options);
        }

        public static void ThrowIfUnauthorized(HttpResponseMessage response, ProviderHttpErrorOptions options)
        {
            if (response.StatusCode == HttpStatusCode.Unauthorized ||
                (options.IncludeForbidden && response.StatusCode == HttpStatusCode.Forbidden))
            {
                var code = (int)response.StatusCode;
                throw new Exception(I18n.LocalizationManager.Instance.IsChinese
                    ? options.UnauthorizedZh(code)
                    : options.UnauthorizedEn(code));
            }
        }

        public static void ThrowIfRateLimited(HttpResponseMessage response, string body, ProviderHttpErrorOptions options)
        {
            if ((int)response.StatusCode != 429) return;

            var isZh = I18n.LocalizationManager.Instance.IsChinese;
            var msg = isZh ? options.RateLimitZh(429) : options.RateLimitEn(429);
            if (options.ParseRateLimitJsonMessage)
            {
                try
                {
                    using var doc = JsonDocument.Parse(body);
                    if (doc.RootElement.TryGetProperty("error", out var err) &&
                        err.TryGetProperty("message", out var detail))
                    {
                        msg = detail.GetString() ?? msg;
                    }
                }
                catch (JsonException ex)
                {
                    Log.Warn("provider", $"{options.RateLimitJsonLogPrefix} 429 响应不是 JSON: {ex.Message}");
                }
            }
            throw new Exception(msg);
        }

        public static void ThrowIfNotSuccess(HttpResponseMessage response, string body, ProviderHttpErrorOptions options)
        {
            if (response.IsSuccessStatusCode) return;

            var code = (int)response.StatusCode;
            var snippet = body.Length > options.SnippetLength ? body.Substring(0, options.SnippetLength) : body;
            throw new Exception(I18n.LocalizationManager.Instance.IsChinese
                ? options.ErrorZh(code, snippet)
                : options.ErrorEn(code, snippet));
        }
    }
}
