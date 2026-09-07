using System;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using TokenBar.Models;

namespace TokenBar.Services
{
    public class KimiService
    {
        public static KimiService Instance { get; } = new KimiService();

        private static readonly HttpClient HttpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

        private KimiService() { }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchQuotaAsync(
            string apiKey,
            string endpoint = "https://api.moonshot.cn/v1",
            string model = "moonshot-v1-8k")
        {
            var cleanKey = apiKey.Trim();
            if (string.IsNullOrEmpty(cleanKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? "请输入 KIMI / Moonshot API Key" : "Please enter KIMI / Moonshot API Key");
            }

            var baseEndpoint = endpoint.Trim().TrimEnd('/');
            if (string.IsNullOrEmpty(baseEndpoint))
            {
                baseEndpoint = "https://api.moonshot.cn/v1";
            }

            // 1. Fetch balance
            var balanceString = await FetchBalanceAsync(cleanKey, baseEndpoint);

            // 2. Fetch models & rate limits
            var modelsUrl = baseEndpoint.EndsWith("/models", StringComparison.OrdinalIgnoreCase)
                ? baseEndpoint
                : $"{baseEndpoint}/models";

            using var req = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
            req.Headers.Add("Authorization", $"Bearer {cleanKey}");
            req.Headers.Add("Accept", "application/json");

            var resp = await HttpClient.SendAsync(req);
            var body = await resp.Content.ReadAsStringAsync();

            if (resp.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? "KIMI API Key 无效或未授权 (HTTP 401)" : "KIMI API Key is invalid or unauthorized (HTTP 401)");
            }

            if ((int)resp.StatusCode == 429)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? "KIMI 请求并发超限或额度不足 (HTTP 429)" : "KIMI concurrency limit reached or quota insufficient (HTTP 429)");
            }

            if (!resp.IsSuccessStatusCode)
            {
                var snippet = body.Length > 100 ? body.Substring(0, 100) : body;
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"KIMI 接口响应异常 ({(int)resp.StatusCode}): {snippet}" : $"KIMI API response error ({(int)resp.StatusCode}): {snippet}");
            }

            string? GetHeader(string name)
            {
                if (resp.Headers.TryGetValues(name, out var values))
                    return values.FirstOrDefault();
                if (resp.Content.Headers.TryGetValues(name, out var cv))
                    return cv.FirstOrDefault();
                return null;
            }

            var limitTokensStr = GetHeader("x-ratelimit-limit-tokens");
            var remainingTokensStr = GetHeader("x-ratelimit-remaining-tokens");
            var resetTokensStr = GetHeader("x-ratelimit-reset-tokens");

            TokenWindow? primaryWindow = null;
            TokenWindow? secondaryWindow = null;

            if (balanceString != null)
            {
                secondaryWindow = new TokenWindow
                {
                    Title = "账户可用余额",
                    UsedPercentage = 0.0,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(30),
                    Unit = "¥",
                    IsIdle = true
                };
            }

            if (double.TryParse(limitTokensStr, out var limitTokens) &&
                double.TryParse(remainingTokensStr, out var remainingTokens) &&
                limitTokens > 0)
            {
                var used = Math.Max(0.0, limitTokens - remainingTokens);
                var usedPct = Math.Clamp((used / limitTokens) * 100.0, 0.0, 100.0);
                var duration = OpenAIService.Instance.ParseDurationString(resetTokensStr ?? "1s");
                var now = DateTime.Now;

                primaryWindow = new TokenWindow
                {
                    Title = "TPM 速率配额",
                    UsedPercentage = usedPct,
                    StartTime = now,
                    EndTime = now.Add(duration),
                    UsedAmount = used,
                    TotalLimit = limitTokens,
                    Unit = "tokens",
                    IsIdle = used == 0.0
                };
            }

            if (primaryWindow == null && secondaryWindow == null)
            {
                primaryWindow = new TokenWindow
                {
                    Title = "KIMI 连接正常",
                    UsedPercentage = 0.0,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(1),
                    Unit = "%",
                    IsIdle = true
                };
            }

            var keySuffix = cleanKey.Length > 6 ? cleanKey[^4..] : cleanKey;
            var isZh = LocalizationManager.Instance.IsChinese;
            var account = balanceString != null
                ? (isZh ? $"余额: {balanceString}" : $"Balance: {balanceString}")
                : (isZh ? $"KIMI (尾号 {keySuffix})" : $"KIMI (...{keySuffix})");

            return (primaryWindow, secondaryWindow, account);
        }

        private async Task<string?> FetchBalanceAsync(string apiKey, string baseEndpoint)
        {
            try
            {
                var balanceUrl = $"{baseEndpoint}/users/me/balance";
                using var req = new HttpRequestMessage(HttpMethod.Get, balanceUrl);
                req.Headers.Add("Authorization", $"Bearer {apiKey}");

                var resp = await HttpClient.SendAsync(req);
                if (!resp.IsSuccessStatusCode) return null;

                var body = await resp.Content.ReadAsStringAsync();
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("data", out var dataObj))
                {
                    if (dataObj.TryGetProperty("available_balance", out var avProp))
                    {
                        if (avProp.ValueKind == JsonValueKind.Number)
                        {
                            return $"¥{avProp.GetDouble():F2}";
                        }
                        if (avProp.ValueKind == JsonValueKind.String)
                        {
                            return $"¥{avProp.GetString()}";
                        }
                    }
                    if (dataObj.TryGetProperty("cash_balance", out var cashProp) && cashProp.ValueKind == JsonValueKind.Number)
                    {
                        return $"¥{cashProp.GetDouble():F2}";
                    }
                }
            }
            catch { }

            return null;
        }
    }
}
