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
    public class DeepSeekService
    {
        public static DeepSeekService Instance { get; } = new DeepSeekService();

        private DeepSeekService() { }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchQuotaAsync(
            string apiKey,
            string endpoint = "https://api.deepseek.com/v1",
            string model = "deepseek-chat",
            decimal balanceAlertThreshold = 10,
            CancellationToken ct = default)
        {
            var cleanKey = apiKey.Trim();
            if (string.IsNullOrEmpty(cleanKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? "请输入 DeepSeek API Key" : "Please enter DeepSeek API Key");
            }

            var baseEndpoint = endpoint.Trim().TrimEnd('/');
            if (string.IsNullOrEmpty(baseEndpoint))
            {
                baseEndpoint = "https://api.deepseek.com/v1";
            }

            // 1. Fetch user balance
            var balance = await FetchBalanceAsync(cleanKey, ct);
            string? balanceString = null;
            if (balance != null)
            {
                var symbol = balance.Value.Currency == "USD" ? "$" : "¥";
                balanceString = $"{symbol}{balance.Value.Amount:0.00}";
            }

            // 2. Fetch models and rate limits
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
                throw new Exception(LocalizationManager.Instance.IsChinese ? "DeepSeek API Key 无效或未授权 (HTTP 401)" : "DeepSeek API Key is invalid or unauthorized (HTTP 401)");
            }

            if ((int)resp.StatusCode == 429)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? "DeepSeek 请求达到速率限制或额度不足 (HTTP 429)" : "DeepSeek rate limit reached or quota insufficient (HTTP 429)");
            }

            if (!resp.IsSuccessStatusCode)
            {
                var snippet = body.Length > 100 ? body.Substring(0, 100) : body;
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"DeepSeek 接口异常: {snippet}" : $"DeepSeek API error: {snippet}");
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
                    BalanceAmount = balance.Value.Amount,
                    Currency = balance.Value.Currency,
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
                primaryWindow = TokenWindow.Status("DeepSeek 连接正常");
            }

            var keySuffix = cleanKey.Length > 6 ? cleanKey[^4..] : cleanKey;
            var isZh = LocalizationManager.Instance.IsChinese;
            var account = balanceString != null
                ? (isZh ? $"余额: {balanceString}" : $"Balance: {balanceString}")
                : (isZh ? $"已授权 (...{keySuffix})" : $"Authorized (...{keySuffix})");

            return (primaryWindow, secondaryWindow, account);
        }

        /// <summary>查询 DeepSeek 账户余额，返回 (金额, 币种)；失败返回 null。</summary>
        public async Task<(decimal Amount, string Currency)?> FetchBalanceAsync(string apiKey, CancellationToken ct = default)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, "https://api.deepseek.com/user/balance");
                req.Headers.Add("Authorization", $"Bearer {apiKey}");

                using var resp = await Http.Shared.SendAsync(req, ct);
                if (!resp.IsSuccessStatusCode) return null;

                var json = await resp.Content.ReadAsStringAsync(ct);
                using var doc = JsonDocument.Parse(json);
                if (doc.RootElement.TryGetProperty("balance_infos", out var infos) &&
                    infos.ValueKind == JsonValueKind.Array &&
                    infos.GetArrayLength() > 0)
                {
                    var first = infos[0];
                    if (first.TryGetProperty("total_balance", out var totalProp))
                    {
                        var totalRaw = totalProp.ValueKind == JsonValueKind.Number
                            ? totalProp.GetRawText()
                            : totalProp.GetString();
                        if (decimal.TryParse(totalRaw, NumberStyles.Any, CultureInfo.InvariantCulture, out var total))
                        {
                            var currency = first.TryGetProperty("currency", out var cp) ? cp.GetString() : "CNY";
                            return (total, currency ?? "CNY");
                        }
                    }
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                Log.Warn("provider", $"deepseek 余额查询失败: {ex.Message}");
            }

            return null;
        }
    }
}
