using TokenBar.I18n;
using System;
using System.Globalization;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
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

            var baseEndpoint = ProviderShared.NormalizeEndpoint(endpoint, "https://api.deepseek.com/v1");

            // 1. Fetch user balance
            var balance = await FetchBalanceAsync(cleanKey, ct);
            string? balanceString = null;
            if (balance != null)
            {
                var symbol = balance.Value.Currency == "USD" ? "$" : "¥";
                balanceString = $"{symbol}{balance.Value.Amount:0.00}";
            }

            // 2. Fetch models and rate limits
            var modelsUrl = ProviderShared.ModelsUrl(baseEndpoint);

            using var req = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
            req.Headers.Add("Authorization", $"Bearer {cleanKey}");
            req.Headers.Add("Accept", "application/json");

            using var resp = await Http.Shared.SendAsync(req, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);

            ProviderHttpErrors.ThrowForStatus(resp, body, ProviderHttpErrorOptions.DeepSeek);

            TokenWindow? primaryWindow = null;
            TokenWindow? secondaryWindow = null;

            if (balance != null)
            {
                secondaryWindow = new TokenWindow
                {
                    Title = WindowTitle.AccountAvailableBalance,
                    Kind = TokenWindowKind.Balance,
                    BalanceAmount = balance.Value.Amount,
                    Currency = balance.Value.Currency,
                    WarningThreshold = balanceAlertThreshold,
                    CriticalThreshold = balanceAlertThreshold / 2,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(30)
                };
            }

            primaryWindow = resp.BuildRateLimitWindow(RateLimitHeaderSet.OpenAI("tokens"), WindowTitle.TpmRate, "tokens");

            if (primaryWindow == null && secondaryWindow == null)
            {
                primaryWindow = TokenWindow.Status(WindowTitle.ConnectedFor("DeepSeek"));
            }

            var keySuffix = ProviderShared.KeySuffixMask(cleanKey);
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
