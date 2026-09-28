using TokenBar.I18n;
using System;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using TokenBar.Helpers;
using TokenBar.Models;

namespace TokenBar.Services
{
    public class GLMService
    {
        public static GLMService Instance { get; } = new GLMService();

        private GLMService() { }

        /// <summary>
        /// 只在探测阶段「可选失败」时抛出：例如配额接口 404 / 401 / 403 / 返回格式不符。
        /// /models 的鉴权失败与网络错误不属于这一类，必须上抛让卡片显示错误。
        /// </summary>
        private sealed class OptionalProbeException : Exception
        {
            public OptionalProbeException(string message) : base(message) { }
        }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchQuotaAsync(
            string apiKey,
            string endpoint = "https://open.bigmodel.cn/api/v1",
            CancellationToken ct = default)
        {
            var cleanKey = apiKey.Trim();
            if (string.IsNullOrEmpty(cleanKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? "API Key 不能为空" : "API Key cannot be empty");
            }

            // GLM 无默认 endpoint 兜底：传空 fallback 与原来「只 trim 不兜底」逐字等价
            var trimmedEndpoint = ProviderShared.NormalizeEndpoint(endpoint, string.Empty);
            string baseHost;
            string openAIEndpoint;

            if (trimmedEndpoint.EndsWith("/api/v1", StringComparison.OrdinalIgnoreCase))
            {
                openAIEndpoint = trimmedEndpoint;
                baseHost = trimmedEndpoint[..^"/api/v1".Length];
            }
            else if (trimmedEndpoint.Contains("/api/paas/v4", StringComparison.OrdinalIgnoreCase))
            {
                baseHost = trimmedEndpoint.Replace("/api/paas/v4", "");
                openAIEndpoint = $"{baseHost}/api/v1";
            }
            else
            {
                baseHost = trimmedEndpoint;
                openAIEndpoint = $"{trimmedEndpoint}/api/v1";
            }

            var keySuffix = ProviderShared.KeySuffixMask(cleanKey);
            var account = $"GLM (...{keySuffix})";
            var isZh = LocalizationManager.Instance.IsChinese;

            double? rateLimitTokensRemaining = null;
            double? rateLimitTokensTotal = null;
            double? rateLimitResetDurationSec = null;

            // 1. GET /models：既是鉴权探测，也顺带读取速率头。
            //    401/403、网络错误、超时在这里直接上抛 —— 以前被整体吞掉后卡片会显示一份编造的额度。
            {
                using var openAiReq = new HttpRequestMessage(HttpMethod.Get, $"{openAIEndpoint}/models");
                openAiReq.Headers.Add("Authorization", $"Bearer {cleanKey}");
                openAiReq.Headers.Add("Accept", "application/json");

                using var openAiResp = await Http.Shared.SendAsync(openAiReq, ct);
                var openAiData = await openAiResp.Content.ReadAsStringAsync(ct);

                // 三段式错误分类共用 ProviderHttpErrors，但 GLM 必须在 429 与非2xx 之间
                // 插入「HTTP 200 里的 code:1001 鉴权失败」检查，故逐段调用保持原判定顺序。
                ProviderHttpErrors.ThrowIfUnauthorized(openAiResp, ProviderHttpErrorOptions.GLM);
                ProviderHttpErrors.ThrowIfRateLimited(openAiResp, openAiData, ProviderHttpErrorOptions.GLM);

                // 智谱在 200 里也可能返回 {"code":1001,"msg":"..."} 表示鉴权失败
                string? authFailureMsg = null;
                try
                {
                    using var doc = JsonDocument.Parse(openAiData);
                    if (doc.RootElement.ValueKind == JsonValueKind.Object &&
                        doc.RootElement.TryGetProperty("code", out var codeProp) &&
                        codeProp.ValueKind == JsonValueKind.Number && codeProp.GetInt32() == 1001)
                    {
                        authFailureMsg = doc.RootElement.TryGetProperty("msg", out var m) && m.ValueKind == JsonValueKind.String
                            ? m.GetString()
                            : (isZh ? "未收到有效 Authorization 参数" : "Valid Authorization parameter not received");
                    }
                }
                catch (JsonException ex)
                {
                    Log.Warn("provider", $"glm /models 响应不是 JSON: {ex.Message}");
                }
                if (authFailureMsg != null)
                {
                    throw new Exception(isZh ? $"身份验证失败: {authFailureMsg}" : $"Authentication failed: {authFailureMsg}");
                }

                ProviderHttpErrors.ThrowIfNotSuccess(openAiResp, openAiData, ProviderHttpErrorOptions.GLM);

                // 速率头有意不走 ProviderShared.BuildRateLimitWindow：GLM 只读 response headers
                // （不查 content headers）、usedPct 用 (1 - remaining/total) 公式、UsedAmount 不做
                // Math.Max(0,…) 下限、IsIdle 依据 usedPct 而非 used、reset 缺失时兜底 60s 而非 1s，
                // 且窗口在配额接口失败后才回退构造 —— 与共享 builder 的语义差异是刻意保留的行为。
                if (openAiResp.Headers.TryGetValues("x-ratelimit-remaining-tokens", out var remVals) &&
                    double.TryParse(remVals.FirstOrDefault(), NumberStyles.Float, CultureInfo.InvariantCulture, out var rem))
                {
                    rateLimitTokensRemaining = rem;
                }
                if (openAiResp.Headers.TryGetValues("x-ratelimit-limit-tokens", out var totVals) &&
                    double.TryParse(totVals.FirstOrDefault(), NumberStyles.Float, CultureInfo.InvariantCulture, out var tot))
                {
                    rateLimitTokensTotal = tot;
                }
                if (openAiResp.Headers.TryGetValues("x-ratelimit-reset-tokens", out var rstVals))
                {
                    rateLimitResetDurationSec = RateLimitReset.Parse(rstVals.FirstOrDefault());
                }
            }

            // 2. 配额接口 /api/monitor/usage/quota/limit —— 这是「可选探测」：接口不存在 / 鉴权范围不符 /
            //    格式不符时静默降级到速率头；网络错误与取消仍然上抛。
            TokenWindow? fiveHourWindow = null;
            TokenWindow? weeklyWindow = null;

            try
            {
                (fiveHourWindow, weeklyWindow) = await FetchQuotaLimitsAsync(baseHost, cleanKey, ct);
            }
            catch (OptionalProbeException ex)
            {
                Log.Info("provider", $"glm 配额接口不可用，退回速率头: {ex.Message}");
            }

            // 3. 退回速率头：只有真的拿到了 limit/remaining 才构造窗口；什么都没有就返回 null，
            //    让卡片如实显示「同步中 / 无额度数据」，而不是编一份 usedPct * 0.6 的每周额度。
            if (fiveHourWindow == null &&
                rateLimitTokensRemaining.HasValue && rateLimitTokensTotal.HasValue && rateLimitTokensTotal.Value > 0)
            {
                var now = DateTime.Now;
                var usedPct = Math.Clamp((1.0 - (rateLimitTokensRemaining.Value / rateLimitTokensTotal.Value)) * 100.0, 0.0, 100.0);
                var resetSec = rateLimitResetDurationSec.HasValue && rateLimitResetDurationSec.Value > 0
                    ? rateLimitResetDurationSec.Value
                    : 60;
                var resetAt = now.AddSeconds(resetSec);

                fiveHourWindow = new TokenWindow
                {
                    Title = WindowTitle.TpmRate,
                    UsedPercentage = usedPct,
                    StartTime = now,
                    EndTime = resetAt,
                    UsedAmount = rateLimitTokensTotal.Value - rateLimitTokensRemaining.Value,
                    TotalLimit = rateLimitTokensTotal,
                    Unit = "tokens",
                    IsIdle = usedPct == 0.0
                };
            }

            if (fiveHourWindow == null && weeklyWindow == null)
            {
                // 鉴权通过但没有任何额度数据：给一个状态型窗口，卡片只显示绿色状态点
                fiveHourWindow = TokenWindow.Status(WindowTitle.Connected);
            }

            return (fiveHourWindow, weeklyWindow, account);
        }

        /// <summary>
        /// 查询 BigModel 配额与 5 小时限额。
        /// 抛 OptionalProbeException 表示「这个接口对该账号不可用」，可以静默降级；
        /// 其他异常（401/403、网络、取消）原样上抛。
        /// </summary>
        private static async Task<(TokenWindow? FiveHour, TokenWindow? Weekly)> FetchQuotaLimitsAsync(
            string baseHost, string cleanKey, CancellationToken ct)
        {
            var quotaUrl = $"{baseHost}/api/monitor/usage/quota/limit";
            using var quotaReq = new HttpRequestMessage(HttpMethod.Get, quotaUrl);
            quotaReq.Headers.Add("Authorization", $"Bearer {cleanKey}");
            quotaReq.Headers.Add("Accept", "application/json");
            // 与 mac 端对齐：该接口对 UA 敏感，裸 TokenBar UA 可能拿不到数据
            quotaReq.Headers.TryAddWithoutValidation("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) TokenBar/1.0");

            using var quotaResp = await Http.Shared.SendAsync(quotaReq, ct);

            if (quotaResp.StatusCode == System.Net.HttpStatusCode.Unauthorized ||
                quotaResp.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                // 与 mac 端对齐：/models 已做过鉴权探测并硬抛 401/403；走到这里说明 Key 本身有效，
                // 只是配额接口对该账号不可用（权限范围不同），静默降级到速率头而不是整卡报错。
                throw new OptionalProbeException($"配额接口鉴权拒绝 (HTTP {(int)quotaResp.StatusCode})");
            }
            if (!quotaResp.IsSuccessStatusCode)
            {
                throw new OptionalProbeException($"HTTP {(int)quotaResp.StatusCode}");
            }

            var quotaData = await quotaResp.Content.ReadAsStringAsync(ct);
            JsonDocument doc;
            try
            {
                doc = JsonDocument.Parse(quotaData);
            }
            catch (JsonException ex)
            {
                throw new OptionalProbeException($"非 JSON 响应: {ex.Message}");
            }

            using (doc)
            {
                var root = doc.RootElement;
                JsonElement limitsArray = default;
                if (root.ValueKind == JsonValueKind.Object)
                {
                    if (root.TryGetProperty("data", out var dataObj) &&
                        dataObj.ValueKind == JsonValueKind.Object &&
                        dataObj.TryGetProperty("limits", out var lim1))
                    {
                        limitsArray = lim1;
                    }
                    else if (root.TryGetProperty("limits", out var lim2))
                    {
                        limitsArray = lim2;
                    }
                }

                if (limitsArray.ValueKind != JsonValueKind.Array)
                {
                    throw new OptionalProbeException("响应中没有 limits 数组");
                }

                TokenWindow? fiveHourWindow = null;
                TokenWindow? weeklyWindow = null;

                foreach (var item in limitsArray.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.Object) continue;

                    var type = item.TryGetProperty("type", out var tp) && tp.ValueKind == JsonValueKind.String
                        ? tp.GetString()?.ToUpperInvariant() ?? ""
                        : "";

                    double pct = 0.0;
                    if (item.TryGetProperty("percentage", out var p1) && p1.ValueKind == JsonValueKind.Number) pct = p1.GetDouble();
                    else if (item.TryGetProperty("utilization", out var p2) && p2.ValueKind == JsonValueKind.Number) pct = p2.GetDouble();
                    pct = Math.Clamp(pct, 0.0, 100.0);

                    // nextResetTime 按量级区分秒 / 毫秒：> 1e12 视为毫秒（秒级时间戳到 2286 年也不会超过 1e10）
                    DateTime? resetDate = null;
                    if (item.TryGetProperty("nextResetTime", out var nrProp) && nrProp.ValueKind == JsonValueKind.Number)
                    {
                        var val = nrProp.GetDouble();
                        if (val > 0)
                        {
                            var resetMs = val > 1e12 ? val : val * 1000;
                            resetDate = DateTimeOffset.FromUnixTimeMilliseconds((long)resetMs).LocalDateTime;
                        }
                    }

                    double? usedTokens = item.TryGetProperty("used", out var up) && up.ValueKind == JsonValueKind.Number ? up.GetDouble() : null;
                    double? totalTokens = item.TryGetProperty("total", out var top) && top.ValueKind == JsonValueKind.Number ? top.GetDouble() : null;

                    var isWeekly = type.Contains("WEEK");
                    var isFiveHour = !isWeekly && (type.Contains("TOKEN") || type.Contains("5H") || type.Contains("SESSION"));

                    if (isFiveHour || (!isWeekly && fiveHourWindow == null))
                    {
                        var end = resetDate ?? DateTime.Now.AddHours(5);
                        fiveHourWindow = new TokenWindow
                        {
                            Title = WindowTitle.FiveHour,
                            UsedPercentage = pct,
                            StartTime = end.AddHours(-5),
                            EndTime = end,
                            UsedAmount = usedTokens,
                            TotalLimit = totalTokens,
                            Unit = totalTokens != null ? "Tokens" : "%",
                            IsIdle = pct == 0.0
                        };
                    }
                    else if (isWeekly || weeklyWindow == null)
                    {
                        var end = resetDate ?? DateTime.Now.AddDays(7);
                        weeklyWindow = new TokenWindow
                        {
                            Title = WindowTitle.Weekly,
                            UsedPercentage = pct,
                            StartTime = end.AddDays(-7),
                            EndTime = end,
                            UsedAmount = usedTokens,
                            TotalLimit = totalTokens,
                            Unit = totalTokens != null ? "Tokens" : "%",
                            IsIdle = pct == 0.0
                        };
                    }
                }

                return (fiveHourWindow, weeklyWindow);
            }
        }
    }
}
