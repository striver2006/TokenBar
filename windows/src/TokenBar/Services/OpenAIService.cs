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
    public class OpenAIService
    {
        public static OpenAIService Instance { get; } = new OpenAIService();

        private OpenAIService() { }

        public async Task<(TokenWindow? Primary, TokenWindow? Secondary, string? Account)> FetchQuotaAsync(
            string apiKey,
            string endpoint = "https://api.openai.com/v1",
            string? organizationId = null,
            CancellationToken ct = default)
        {
            var trimmedKey = apiKey.Trim();
            if (string.IsNullOrEmpty(trimmedKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? "请输入 OpenAI API Key" : "Please enter OpenAI API Key");
            }

            var baseEndpoint = endpoint.Trim().TrimEnd('/');
            if (string.IsNullOrEmpty(baseEndpoint))
            {
                baseEndpoint = "https://api.openai.com/v1";
            }

            var targetUrl = baseEndpoint.EndsWith("/models", StringComparison.OrdinalIgnoreCase)
                ? baseEndpoint
                : $"{baseEndpoint}/models";

            using var request = new HttpRequestMessage(HttpMethod.Get, targetUrl);
            request.Headers.Add("Authorization", $"Bearer {trimmedKey}");
            request.Headers.Add("Accept", "application/json");

            if (!string.IsNullOrWhiteSpace(organizationId))
            {
                request.Headers.Add("OpenAI-Organization", organizationId.Trim());
            }

            HttpResponseMessage response;
            try
            {
                response = await Http.Shared.SendAsync(request, ct);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"OpenAI 网络连接失败: {ex.Message}" : $"OpenAI network connection failed: {ex.Message}", ex);
            }

            using (response)
            {
                var responseBody = await response.Content.ReadAsStringAsync(ct);

                if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized)
                {
                    throw new Exception(LocalizationManager.Instance.IsChinese ? "OpenAI API Key 无效或已过期 (HTTP 401)" : "OpenAI API Key is invalid or expired (HTTP 401)");
                }

                if ((int)response.StatusCode == 429)
                {
                    var msg = LocalizationManager.Instance.IsChinese ? "请求过于频繁或额度已耗尽 (HTTP 429)" : "Rate limit reached or quota exhausted (HTTP 429)";
                    try
                    {
                        using var doc = JsonDocument.Parse(responseBody);
                        if (doc.RootElement.TryGetProperty("error", out var err) &&
                            err.TryGetProperty("message", out var errDetail))
                        {
                            msg = errDetail.GetString() ?? msg;
                        }
                    }
                    catch (JsonException ex)
                    {
                        Log.Warn("provider", $"openai 429 响应不是 JSON: {ex.Message}");
                    }
                    throw new Exception(msg);
                }

                if (!response.IsSuccessStatusCode)
                {
                    var snippet = responseBody.Length > 120 ? responseBody.Substring(0, 120) : responseBody;
                    throw new Exception(LocalizationManager.Instance.IsChinese ? $"OpenAI 接口请求失败 ({(int)response.StatusCode}): {snippet}" : $"OpenAI request failed ({(int)response.StatusCode}): {snippet}");
                }

                // Parse rate limit headers
                string? GetHeader(string name)
                {
                    if (response.Headers.TryGetValues(name, out var values))
                        return values.FirstOrDefault();
                    if (response.Content.Headers.TryGetValues(name, out var contentValues))
                        return contentValues.FirstOrDefault();
                    return null;
                }

                var limitTokensStr = GetHeader("x-ratelimit-limit-tokens");
                var remainingTokensStr = GetHeader("x-ratelimit-remaining-tokens");
                var resetTokensStr = GetHeader("x-ratelimit-reset-tokens");

                var limitReqStr = GetHeader("x-ratelimit-limit-requests");
                var remainingReqStr = GetHeader("x-ratelimit-remaining-requests");
                var resetReqStr = GetHeader("x-ratelimit-reset-requests");

                var orgHeader = GetHeader("openai-organization");

                TokenWindow? primaryWindow = null;
                TokenWindow? secondaryWindow = null;

                // 1. Tokens Rate Limit Window (TPM)
                if (double.TryParse(limitTokensStr, NumberStyles.Float, CultureInfo.InvariantCulture, out var limitTokens) &&
                    double.TryParse(remainingTokensStr, NumberStyles.Float, CultureInfo.InvariantCulture, out var remainingTokens) &&
                    limitTokens > 0)
                {
                    var used = Math.Max(0.0, limitTokens - remainingTokens);
                    var usedPct = Math.Clamp((used / limitTokens) * 100.0, 0.0, 100.0);
                    var resetSec = RateLimitReset.Parse(resetTokensStr) ?? 1;
                    var now = DateTime.Now;
                    var resetDate = now.AddSeconds(resetSec);

                    primaryWindow = new TokenWindow
                    {
                        Title = "TPM 速率剩余",
                        UsedPercentage = usedPct,
                        StartTime = now,
                        EndTime = resetDate,
                        UsedAmount = used,
                        TotalLimit = limitTokens,
                        Unit = "tokens",
                        IsIdle = used == 0.0
                    };
                }

                // 2. Requests Rate Limit Window (RPM)
                if (double.TryParse(limitReqStr, NumberStyles.Float, CultureInfo.InvariantCulture, out var limitReq) &&
                    double.TryParse(remainingReqStr, NumberStyles.Float, CultureInfo.InvariantCulture, out var remainingReq) &&
                    limitReq > 0)
                {
                    var used = Math.Max(0.0, limitReq - remainingReq);
                    var usedPct = Math.Clamp((used / limitReq) * 100.0, 0.0, 100.0);
                    var resetSec = RateLimitReset.Parse(resetReqStr) ?? 1;
                    var now = DateTime.Now;
                    var resetDate = now.AddSeconds(resetSec);

                    secondaryWindow = new TokenWindow
                    {
                        Title = "RPM 请求速率",
                        UsedPercentage = usedPct,
                        StartTime = now,
                        EndTime = resetDate,
                        UsedAmount = used,
                        TotalLimit = limitReq,
                        Unit = "req",
                        IsIdle = used == 0.0
                    };
                }

                int modelCount = 0;
                try
                {
                    using var doc = JsonDocument.Parse(responseBody);
                    if (doc.RootElement.TryGetProperty("data", out var dataArr) &&
                        dataArr.ValueKind == JsonValueKind.Array)
                    {
                        modelCount = dataArr.GetArrayLength();
                    }
                }
                catch (JsonException ex)
                {
                    Log.Warn("provider", $"openai /models 响应不是 JSON: {ex.Message}");
                }

                if (primaryWindow == null)
                {
                    // 没有速率头：只表示连接正常，不编造任何百分比
                    primaryWindow = TokenWindow.Status("API 连接状态");
                }

                var accountInfo = orgHeader ?? organizationId;
                if (string.IsNullOrWhiteSpace(accountInfo))
                {
                    accountInfo = modelCount > 0
                        ? (LocalizationManager.Instance.IsChinese ? $"OpenAI (可用模型: {modelCount}个)" : $"OpenAI ({modelCount} models available)")
                        : "OpenAI API";
                }

                return (primaryWindow, secondaryWindow, accountInfo);
            }
        }
    }
}
