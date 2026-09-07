using System;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using TokenBar.Models;

namespace TokenBar.Services
{
    public class OpenAIService
    {
        public static OpenAIService Instance { get; } = new OpenAIService();

        private static readonly HttpClient HttpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

        private OpenAIService() { }

        public async Task<(TokenWindow? Primary, TokenWindow? Secondary, string? Account)> FetchQuotaAsync(
            string apiKey,
            string endpoint = "https://api.openai.com/v1",
            string? organizationId = null)
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
                response = await HttpClient.SendAsync(request);
            }
            catch (Exception ex)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"OpenAI 网络连接失败: {ex.Message}" : $"OpenAI network connection failed: {ex.Message}", ex);
            }

            var responseBody = await response.Content.ReadAsStringAsync();

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
                catch { }
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
            if (double.TryParse(limitTokensStr, out var limitTokens) &&
                double.TryParse(remainingTokensStr, out var remainingTokens) &&
                limitTokens > 0)
            {
                var used = Math.Max(0.0, limitTokens - remainingTokens);
                var usedPct = Math.Clamp((used / limitTokens) * 100.0, 0.0, 100.0);
                var duration = ParseDurationString(resetTokensStr ?? "1s");
                var now = DateTime.Now;
                var resetDate = now.Add(duration);

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
            if (double.TryParse(limitReqStr, out var limitReq) &&
                double.TryParse(remainingReqStr, out var remainingReq) &&
                limitReq > 0)
            {
                var used = Math.Max(0.0, limitReq - remainingReq);
                var usedPct = Math.Clamp((used / limitReq) * 100.0, 0.0, 100.0);
                var duration = ParseDurationString(resetReqStr ?? "1s");
                var now = DateTime.Now;
                var resetDate = now.Add(duration);

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
            catch { }

            if (primaryWindow == null)
            {
                primaryWindow = new TokenWindow
                {
                    Title = "API 连接状态",
                    UsedPercentage = 0.0,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(1),
                    Unit = "%",
                    IsIdle = true
                };
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

        public TimeSpan ParseDurationString(string str)
        {
            var clean = str.Trim();
            if (string.IsNullOrEmpty(clean)) return TimeSpan.FromSeconds(1);

            if (clean.EndsWith("ms", StringComparison.OrdinalIgnoreCase))
            {
                var numStr = clean[..^2];
                if (double.TryParse(numStr, out var ms))
                {
                    return TimeSpan.FromMilliseconds(Math.Max(100, ms));
                }
            }

            double totalSeconds = 0.0;
            var numBuf = "";

            foreach (var ch in clean)
            {
                if (char.IsDigit(ch) || ch == '.')
                {
                    numBuf += ch;
                }
                else if (ch == 'h' || ch == 'H')
                {
                    if (double.TryParse(numBuf, out var val)) totalSeconds += val * 3600;
                    numBuf = "";
                }
                else if ((ch == 'm' || ch == 'M') && !clean.Contains("ms", StringComparison.OrdinalIgnoreCase))
                {
                    if (double.TryParse(numBuf, out var val)) totalSeconds += val * 60;
                    numBuf = "";
                }
                else if (ch == 's' || ch == 'S')
                {
                    if (double.TryParse(numBuf, out var val)) totalSeconds += val;
                    numBuf = "";
                }
            }

            if (totalSeconds > 0)
            {
                return TimeSpan.FromSeconds(totalSeconds);
            }

            if (double.TryParse(clean, out var direct))
            {
                return TimeSpan.FromSeconds(direct);
            }

            return TimeSpan.FromSeconds(1);
        }
    }
}
