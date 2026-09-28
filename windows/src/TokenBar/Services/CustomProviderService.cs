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
    public class CustomProviderService
    {
        public static CustomProviderService Instance { get; } = new CustomProviderService();

        private CustomProviderService() { }

        public async Task<(TokenWindow? Primary, TokenWindow? Secondary, string? Account)> FetchQuotaAsync(CustomProviderConfig config, CancellationToken ct = default)
        {
            var trimmedKey = config.ApiKey.Trim();
            if (string.IsNullOrEmpty(trimmedKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? $"请在配置中填入 {config.Name} 的 API KEY" : $"Please enter the API KEY for {config.Name}");
            }

            var endpoint = ProviderShared.NormalizeEndpoint(
                config.Endpoint,
                config.Protocol == ApiProtocol.Anthropic ? "https://api.anthropic.com/v1" : "https://api.deepseek.com/v1");

            return config.Protocol switch
            {
                ApiProtocol.OpenAIChat => await FetchOpenAICompatibleAsync(trimmedKey, endpoint, config, isResponseProtocol: false, ct),
                ApiProtocol.OpenAIResponses => await FetchOpenAICompatibleAsync(trimmedKey, endpoint, config, isResponseProtocol: true, ct),
                ApiProtocol.Anthropic => await FetchAnthropicCompatibleAsync(trimmedKey, endpoint, config, ct),
                _ => await FetchOpenAICompatibleAsync(trimmedKey, endpoint, config, isResponseProtocol: false, ct)
            };
        }

        private async Task<(TokenWindow? Primary, TokenWindow? Secondary, string? Account)> FetchOpenAICompatibleAsync(
            string apiKey,
            string endpoint,
            CustomProviderConfig config,
            bool isResponseProtocol,
            CancellationToken ct)
        {
            string? balanceAccountInfo = null;
            string? planAccountInfo = null;
            TokenWindow? balanceWindow = null;
            TokenWindow? planWindow = null;
            var balanceThreshold = config.BalanceAlertThreshold ?? 10;

            void UseBalance(WindowTitle title, decimal amount, string currency, string formatted)
            {
                balanceAccountInfo = LocalizationManager.Instance.IsChinese ? $"余额: {formatted}" : $"Balance: {formatted}";
                balanceWindow = new TokenWindow
                {
                    Title = title,
                    Kind = TokenWindowKind.Balance,
                    BalanceAmount = amount,
                    Currency = currency,
                    WarningThreshold = balanceThreshold,
                    CriticalThreshold = balanceThreshold / 2,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(30)
                };
            }

            if (endpoint.Contains("deepseek.com", StringComparison.OrdinalIgnoreCase))
            {
                var balance = await DeepSeekService.Instance.FetchBalanceAsync(apiKey, ct);
                if (balance != null)
                {
                    var symbol = balance.Value.Currency == "USD" ? "$" : "¥";
                    UseBalance(WindowTitle.AccountBalance, balance.Value.Amount, balance.Value.Currency, $"{symbol}{balance.Value.Amount:0.00}");
                }
            }
            else if (endpoint.Contains("moonshot.cn", StringComparison.OrdinalIgnoreCase))
            {
                var balance = await FetchMoonshotBalanceAsync(apiKey, ct);
                if (balance != null)
                {
                    UseBalance(WindowTitle.AccountBalance, balance.Value, "CNY", $"¥{balance.Value:0.00}");
                }
            }
            else if (endpoint.Contains("siliconflow.cn", StringComparison.OrdinalIgnoreCase))
            {
                var balance = await FetchSiliconFlowBalanceAsync(apiKey, ct);
                if (balance != null)
                {
                    UseBalance(WindowTitle.AccountBalance, balance.Value, "CNY", $"¥{balance.Value:0.00}");
                }
            }
            else if (endpoint.Contains("xiaomimimo.com", StringComparison.OrdinalIgnoreCase))
            {
                // 小米 MiMo：按量余额与 Token Plan 套餐用量都只接受控制台 Cookie；
                // 填了 Cookie 即自动开通两条通道，未填时保持纯 API Key 行为不变。
                var cookie = config.ConsoleCookie.Trim();
                if (cookie.Length > 0)
                {
                    var plan = await FetchMiMoTokenPlanAsync(cookie, ct);
                    if (plan != null)
                    {
                        planWindow = new TokenWindow
                        {
                            Title = WindowTitle.TokenPlan,
                            UsedPercentage = plan.Value.UsedPercent,
                            StartTime = DateTime.Now,
                            EndTime = DateTime.Now.AddDays(30),
                            UsedAmount = plan.Value.Used,
                            TotalLimit = plan.Value.Limit,
                            Unit = "credits"
                        };
                        planAccountInfo = LocalizationManager.Instance.IsChinese
                            ? $"套餐已用 {plan.Value.UsedPercent:0.#}%"
                            : $"Plan used {plan.Value.UsedPercent:0.#}%";
                    }

                    var balance = await FetchMiMoBalanceAsync(cookie, ct);
                    if (balance != null)
                    {
                        var symbol = balance.Value.Currency == "USD" ? "$" : "¥";
                        UseBalance(WindowTitle.AccountBalance, balance.Value.Amount, balance.Value.Currency, $"{symbol}{balance.Value.Amount:0.00}");
                    }
                }
            }

            var modelsUrl = ProviderShared.ModelsUrl(endpoint);

            using var request = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
            request.Headers.Add("Authorization", $"Bearer {apiKey}");
            request.Headers.Add("Accept", "application/json");

            using var resp = await Http.Shared.SendAsync(request, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);

            ProviderHttpErrors.ThrowForStatus(resp, body, ProviderHttpErrorOptions.CustomOpenAI(config.Name));

            // 槽位优先级：订阅窗口（Token Plan 百分比）> 余额（金额）> 速率头
            TokenWindow? primaryWindow = planWindow ?? balanceWindow;
            TokenWindow? secondaryWindow = planWindow != null ? balanceWindow : null;

            var rateWindow = resp.BuildRateLimitWindow(RateLimitHeaderSet.OpenAI("tokens"), WindowTitle.TpmRate, "tokens");
            if (rateWindow != null)
            {
                if (primaryWindow == null)
                    primaryWindow = rateWindow;
                else if (secondaryWindow == null)
                    secondaryWindow = rateWindow;
            }

            int modelCount = 0;
            try
            {
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("data", out var dataArr) && dataArr.ValueKind == JsonValueKind.Array)
                {
                    modelCount = dataArr.GetArrayLength();
                }
            }
            catch (JsonException ex)
            {
                Log.Warn("provider", $"custom /models 响应不是 JSON: {ex.Message}");
            }

            if (primaryWindow == null)
            {
                primaryWindow = TokenWindow.Status(WindowTitle.ConnectedFor("接口"));
            }

            var isZhAcct = LocalizationManager.Instance.IsChinese;
            var combinedInfo = planAccountInfo != null && balanceAccountInfo != null
                ? $"{planAccountInfo} · {balanceAccountInfo}"
                : planAccountInfo ?? balanceAccountInfo;
            var account = combinedInfo ?? (modelCount > 0
                ? (isZhAcct ? $"可用模型: {modelCount}个" : $"{modelCount} models available")
                : (isZhAcct ? "已连接" : "Connected"));
            return (primaryWindow, secondaryWindow, account);
        }

        private async Task<(TokenWindow? Primary, TokenWindow? Secondary, string? Account)> FetchAnthropicCompatibleAsync(
            string apiKey,
            string endpoint,
            CustomProviderConfig config,
            CancellationToken ct)
        {
            var modelsUrl = ProviderShared.ModelsUrl(endpoint);

            using var request = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
            request.Headers.Add("x-api-key", apiKey);
            request.Headers.Add("anthropic-version", "2023-06-01");
            request.Headers.Add("Accept", "application/json");

            using var resp = await Http.Shared.SendAsync(request, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);

            ProviderHttpErrors.ThrowForStatus(resp, body, ProviderHttpErrorOptions.CustomAnthropic(config.Name));

            TokenWindow? primaryWindow = resp.BuildRateLimitWindow(
                RateLimitHeaderSet.Anthropic("tokens"), WindowTitle.TokenRate, "tokens");

            TokenWindow? secondaryWindow = resp.BuildRateLimitWindow(
                RateLimitHeaderSet.AnthropicFixedWindow("requests"), WindowTitle.RpmRate, "req");

            int modelCount = 0;
            try
            {
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("data", out var dataArr) && dataArr.ValueKind == JsonValueKind.Array)
                {
                    modelCount = dataArr.GetArrayLength();
                }
            }
            catch (JsonException ex)
            {
                Log.Warn("provider", $"custom anthropic /models 响应不是 JSON: {ex.Message}");
            }

            if (primaryWindow == null)
            {
                primaryWindow = TokenWindow.Status(WindowTitle.ConnectedFor("Anthropic 协议"));
            }

            var isZhAcct = LocalizationManager.Instance.IsChinese;
            var account = modelCount > 0
                ? (isZhAcct ? $"已接入 (模型数: {modelCount})" : $"Connected ({modelCount} models)")
                : (isZhAcct ? "Anthropic 兼容协议" : "Anthropic Compatible Protocol");
            return (primaryWindow, secondaryWindow, account);
        }

        /// <summary>查询 Moonshot 账户余额（人民币），失败返回 null。实现收敛到 ProviderShared，
        /// 保留 Custom 侧差异：固定官方 endpoint、不回退 cash_balance、日志前缀 "custom"。</summary>
        private Task<decimal?> FetchMoonshotBalanceAsync(string apiKey, CancellationToken ct) =>
            ProviderShared.FetchMoonshotBalanceAsync(
                apiKey,
                "https://api.moonshot.cn/v1/users/me/balance",
                allowCashBalanceFallback: false,
                logFailurePrefix: "custom 余额/套餐查询失败",
                ct);

        /// <summary>查询小米 MiMo 按量余额（仅接受控制台 Cookie），失败返回 null。</summary>
        private async Task<(decimal Amount, string Currency)?> FetchMiMoBalanceAsync(string cookie, CancellationToken ct)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, "https://platform.xiaomimimo.com/api/v1/balance");
                req.Headers.Add("Cookie", cookie);
                req.Headers.Add("User-Agent", $"TokenBar/{AppVersion.Short}");
                req.Headers.Add("Accept", "application/json");

                using var resp = await Http.Shared.SendAsync(req, ct);
                if (!resp.IsSuccessStatusCode) return null;

                var body = await resp.Content.ReadAsStringAsync(ct);
                using var doc = JsonDocument.Parse(body);
                var root = doc.RootElement;
                if (root.TryGetProperty("code", out var codeProp) &&
                    codeProp.ValueKind == JsonValueKind.Number && codeProp.GetInt32() != 0)
                {
                    return null;
                }
                if (root.TryGetProperty("data", out var data) && data.TryGetProperty("balance", out var bal))
                {
                    var raw = bal.ValueKind == JsonValueKind.Number ? bal.GetRawText() : bal.GetString();
                    if (decimal.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out var amount))
                    {
                        var currency = data.TryGetProperty("currency", out var cur) ? cur.GetString() : "CNY";
                        return (amount, string.IsNullOrEmpty(currency) ? "CNY" : currency!);
                    }
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                Log.Warn("provider", $"custom 余额/套餐查询失败: {ex.Message}");
            }
            return null;
        }

        /// <summary>
        /// 查询小米 MiMo Token Plan 套餐用量（仅接受控制台 Cookie）。
        /// data.usage.items[] 中优先取 plan_total_token（套餐总额度），缺失时取第一条；失败返回 null。
        /// </summary>
        private async Task<(double UsedPercent, double Used, double Limit)?> FetchMiMoTokenPlanAsync(string cookie, CancellationToken ct)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage");
                req.Headers.Add("Cookie", cookie);
                req.Headers.Add("User-Agent", $"TokenBar/{AppVersion.Short}");
                req.Headers.Add("Accept", "application/json");

                using var resp = await Http.Shared.SendAsync(req, ct);
                if (!resp.IsSuccessStatusCode) return null;

                var body = await resp.Content.ReadAsStringAsync(ct);
                using var doc = JsonDocument.Parse(body);
                var root = doc.RootElement;
                if (root.TryGetProperty("code", out var codeProp) &&
                    codeProp.ValueKind == JsonValueKind.Number && codeProp.GetInt32() != 0)
                {
                    return null;
                }
                if (!root.TryGetProperty("data", out var data) ||
                    !data.TryGetProperty("usage", out var usage) ||
                    !usage.TryGetProperty("items", out var items) ||
                    items.ValueKind != JsonValueKind.Array ||
                    items.GetArrayLength() == 0)
                {
                    return null;
                }

                int chosenIndex = -1;
                int idx = 0;
                foreach (var item in items.EnumerateArray())
                {
                    if (item.TryGetProperty("name", out var nameProp) &&
                        nameProp.ValueKind == JsonValueKind.String &&
                        string.Equals(nameProp.GetString(), "plan_total_token", StringComparison.OrdinalIgnoreCase))
                    {
                        chosenIndex = idx;
                        break;
                    }
                    idx++;
                }
                if (chosenIndex < 0 && items.GetArrayLength() > 0)
                {
                    chosenIndex = 0;
                }
                if (chosenIndex < 0) return null;
                var chosen = items[chosenIndex];

                double limit = 0, used = 0, percent = 0;
                if (chosen.TryGetProperty("limit", out var limitProp))
                    limit = limitProp.ValueKind == JsonValueKind.Number ? limitProp.GetDouble() : double.TryParse(limitProp.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var l) ? l : 0;
                if (chosen.TryGetProperty("used", out var usedProp))
                    used = usedProp.ValueKind == JsonValueKind.Number ? usedProp.GetDouble() : double.TryParse(usedProp.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var u) ? u : 0;
                if (chosen.TryGetProperty("percent", out var pctProp) && pctProp.ValueKind == JsonValueKind.Number)
                {
                    percent = pctProp.GetDouble();
                }
                else if (limit > 0)
                {
                    percent = used / limit * 100.0;
                }
                else
                {
                    return null;
                }

                return (Math.Clamp(percent, 0.0, 100.0), used, limit);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                Log.Warn("provider", $"custom 余额/套餐查询失败: {ex.Message}");
            }
            return null;
        }

        /// <summary>查询 SiliconFlow 用户余额（人民币），失败返回 null。</summary>
        private async Task<decimal?> FetchSiliconFlowBalanceAsync(string apiKey, CancellationToken ct)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, "https://api.siliconflow.cn/v1/user/info");
                req.Headers.Add("Authorization", $"Bearer {apiKey}");

                using var resp = await Http.Shared.SendAsync(req, ct);
                if (!resp.IsSuccessStatusCode) return null;

                var body = await resp.Content.ReadAsStringAsync(ct);
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("data", out var dataObj) &&
                    dataObj.TryGetProperty("balance", out var bal))
                {
                    var raw = bal.ValueKind == JsonValueKind.Number ? bal.GetRawText() : bal.GetString();
                    if (decimal.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out var parsed))
                        return parsed;
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                Log.Warn("provider", $"custom 余额/套餐查询失败: {ex.Message}");
            }
            return null;
        }
    }
}
