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
    public class KimiService
    {
        public static KimiService Instance { get; } = new KimiService();

        private KimiService() { }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchQuotaAsync(
            string apiKey,
            string endpoint = "https://api.moonshot.cn/v1",
            string model = "moonshot-v1-8k",
            decimal balanceAlertThreshold = 10,
            CancellationToken ct = default)
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
            var balance = await FetchBalanceAsync(cleanKey, baseEndpoint, ct);
            string? balanceString = null;
            if (balance != null)
            {
                balanceString = $"¥{balance.Value:0.00}";
            }

            // 2. Fetch models & rate limits
            var modelsUrl = baseEndpoint.EndsWith("/models", StringComparison.OrdinalIgnoreCase)
                ? baseEndpoint
                : $"{baseEndpoint}/models";

            using var req = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
            req.Headers.Add("Authorization", $"Bearer {cleanKey}");
            req.Headers.Add("Accept", "application/json");

            using var resp = await Http.Shared.SendAsync(req, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);

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

            if (balance != null)
            {
                secondaryWindow = new TokenWindow
                {
                    Title = "账户可用余额",
                    Kind = TokenWindowKind.Balance,
                    BalanceAmount = balance.Value,
                    Currency = "CNY",
                    WarningThreshold = balanceAlertThreshold,
                    CriticalThreshold = balanceAlertThreshold / 2,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(30)
                };
            }

            if (double.TryParse(limitTokensStr, NumberStyles.Float, CultureInfo.InvariantCulture, out var limitTokens) &&
                double.TryParse(remainingTokensStr, NumberStyles.Float, CultureInfo.InvariantCulture, out var remainingTokens) &&
                limitTokens > 0)
            {
                var used = Math.Max(0.0, limitTokens - remainingTokens);
                var usedPct = Math.Clamp((used / limitTokens) * 100.0, 0.0, 100.0);
                var duration = TimeSpan.FromSeconds(RateLimitReset.Parse(resetTokensStr) ?? 1);
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
                primaryWindow = TokenWindow.Status("KIMI 连接正常");
            }

            var keySuffix = cleanKey.Length > 6 ? cleanKey[^4..] : cleanKey;
            var isZh = LocalizationManager.Instance.IsChinese;
            var account = balanceString != null
                ? (isZh ? $"余额: {balanceString}" : $"Balance: {balanceString}")
                : (isZh ? $"KIMI (尾号 {keySuffix})" : $"KIMI (...{keySuffix})");

            return (primaryWindow, secondaryWindow, account);
        }

        /// <summary>查询 Moonshot 账户余额（人民币），失败返回 null。</summary>
        private async Task<decimal?> FetchBalanceAsync(string apiKey, string baseEndpoint, CancellationToken ct)
        {
            try
            {
                var balanceUrl = $"{baseEndpoint}/users/me/balance";
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
                    if (dataObj.TryGetProperty("cash_balance", out var cashProp) && cashProp.ValueKind == JsonValueKind.Number)
                    {
                        return (decimal)cashProp.GetDouble();
                    }
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                Log.Warn("provider", $"kimi 余额查询失败: {ex.Message}");
            }

            return null;
        }
    }
}
