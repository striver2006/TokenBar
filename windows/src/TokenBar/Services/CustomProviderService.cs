using TokenBar.I18n;
using System;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using TokenBar.Models;

namespace TokenBar.Services
{
    public class CustomProviderService
    {
        public static CustomProviderService Instance { get; } = new CustomProviderService();

        private static readonly HttpClient HttpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

        private CustomProviderService() { }

        public async Task<(TokenWindow? Primary, TokenWindow? Secondary, string? Account)> FetchQuotaAsync(CustomProviderConfig config)
        {
            var trimmedKey = config.ApiKey.Trim();
            if (string.IsNullOrEmpty(trimmedKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? $"请在配置中填入 {config.Name} 的 API KEY" : $"Please enter the API KEY for {config.Name}");
            }

            var endpoint = config.Endpoint.Trim().TrimEnd('/');
            if (string.IsNullOrEmpty(endpoint))
            {
                endpoint = config.Protocol == ApiProtocol.Anthropic ? "https://api.anthropic.com/v1" : "https://api.deepseek.com/v1";
            }

            return config.Protocol switch
            {
                ApiProtocol.OpenAIChat => await FetchOpenAICompatibleAsync(trimmedKey, endpoint, config, isResponseProtocol: false),
                ApiProtocol.OpenAIResponses => await FetchOpenAICompatibleAsync(trimmedKey, endpoint, config, isResponseProtocol: true),
                ApiProtocol.Anthropic => await FetchAnthropicCompatibleAsync(trimmedKey, endpoint, config),
                _ => await FetchOpenAICompatibleAsync(trimmedKey, endpoint, config, isResponseProtocol: false)
            };
        }

        private async Task<(TokenWindow? Primary, TokenWindow? Secondary, string? Account)> FetchOpenAICompatibleAsync(
            string apiKey,
            string endpoint,
            CustomProviderConfig config,
            bool isResponseProtocol)
        {
            string? balanceAccountInfo = null;
            string? planAccountInfo = null;
            TokenWindow? balanceWindow = null;
            TokenWindow? planWindow = null;
            var balanceThreshold = config.BalanceAlertThreshold ?? 10;

            void UseBalance(string title, decimal amount, string currency, string formatted)
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
                var balance = await DeepSeekService.Instance.FetchBalanceAsync(apiKey);
                if (balance != null)
                {
                    var symbol = balance.Value.Currency == "USD" ? "$" : "¥";
                    UseBalance("账户余额", balance.Value.Amount, balance.Value.Currency, $"{symbol}{balance.Value.Amount:0.00}");
                }
            }
            else if (endpoint.Contains("moonshot.cn", StringComparison.OrdinalIgnoreCase))
            {
                var balance = await FetchMoonshotBalanceAsync(apiKey);
                if (balance != null)
                {
                    UseBalance("账户余额", balance.Value, "CNY", $"¥{balance.Value:0.00}");
                }
            }
            else if (endpoint.Contains("siliconflow.cn", StringComparison.OrdinalIgnoreCase))
            {
                var balance = await FetchSiliconFlowBalanceAsync(apiKey);
                if (balance != null)
                {
                    UseBalance("账户余额", balance.Value, "CNY", $"¥{balance.Value:0.00}");
                }
            }
            else if (endpoint.Contains("xiaomimimo.com", StringComparison.OrdinalIgnoreCase))
            {
                // 小米 MiMo：按量余额与 Token Plan 套餐用量都只接受控制台 Cookie；
                // 填了 Cookie 即自动开通两条通道，未填时保持纯 API Key 行为不变。
                var cookie = config.ConsoleCookie.Trim();
                if (cookie.Length > 0)
                {
                    var plan = await FetchMiMoTokenPlanAsync(cookie);
                    if (plan != null)
                    {
                        planWindow = new TokenWindow
                        {
                            Title = "Token Plan 额度",
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

                    var balance = await FetchMiMoBalanceAsync(cookie);
                    if (balance != null)
                    {
                        var symbol = balance.Value.Currency == "USD" ? "$" : "¥";
                        UseBalance("账户余额", balance.Value.Amount, balance.Value.Currency, $"{symbol}{balance.Value.Amount:0.00}");
                    }
                }
            }

            var modelsUrl = endpoint.EndsWith("/models", StringComparison.OrdinalIgnoreCase)
                ? endpoint
                : $"{endpoint}/models";

            using var request = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
            request.Headers.Add("Authorization", $"Bearer {apiKey}");
            request.Headers.Add("Accept", "application/json");

            var resp = await HttpClient.SendAsync(request);
            var body = await resp.Content.ReadAsStringAsync();

            if (resp.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"{config.Name} API Key 认证失败 (HTTP 401)，请核对密钥" : $"{config.Name} API Key authentication failed (HTTP 401). Please check the key");
            }

            if ((int)resp.StatusCode == 429)
            {
                var msg = LocalizationManager.Instance.IsChinese ? "请求过于频繁或额度不足 (HTTP 429)" : "Rate limit reached or quota insufficient (HTTP 429)";
                try
                {
                    using var doc = JsonDocument.Parse(body);
                    if (doc.RootElement.TryGetProperty("error", out var err) &&
                        err.TryGetProperty("message", out var detail))
                    {
                        msg = detail.GetString() ?? msg;
                    }
                }
                catch { }
                throw new Exception(msg);
            }

            if (!resp.IsSuccessStatusCode)
            {
                var snippet = body.Length > 100 ? body.Substring(0, 100) : body;
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"请求端点失败 ({(int)resp.StatusCode}): {snippet}" : $"Endpoint request failed ({(int)resp.StatusCode}): {snippet}");
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

            // 槽位优先级：订阅窗口（Token Plan 百分比）> 余额（金额）> 速率头
            TokenWindow? primaryWindow = planWindow ?? balanceWindow;
            TokenWindow? secondaryWindow = planWindow != null ? balanceWindow : null;

            if (double.TryParse(limitTokensStr, out var limitTokens) &&
                double.TryParse(remainingTokensStr, out var remainingTokens) &&
                limitTokens > 0)
            {
                var used = Math.Max(0.0, limitTokens - remainingTokens);
                var usedPct = Math.Clamp((used / limitTokens) * 100.0, 0.0, 100.0);
                var duration = OpenAIService.Instance.ParseDurationString(resetTokensStr ?? "1s");
                var now = DateTime.Now;

                var rateWindow = new TokenWindow
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
            catch { }

            if (primaryWindow == null)
            {
                primaryWindow = new TokenWindow
                {
                    Title = "接口连接正常",
                    UsedPercentage = 0.0,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(1),
                    Unit = "%",
                    IsIdle = true
                };
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
            CustomProviderConfig config)
        {
            var modelsUrl = endpoint.EndsWith("/models", StringComparison.OrdinalIgnoreCase)
                ? endpoint
                : $"{endpoint}/models";

            using var request = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
            request.Headers.Add("x-api-key", apiKey);
            request.Headers.Add("anthropic-version", "2023-06-01");
            request.Headers.Add("Accept", "application/json");

            var resp = await HttpClient.SendAsync(request);
            var body = await resp.Content.ReadAsStringAsync();

            if (resp.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"{config.Name} Anthropic API Key 无效或未授权 (HTTP 401)" : $"{config.Name} Anthropic API Key invalid or unauthorized (HTTP 401)");
            }

            if ((int)resp.StatusCode == 429)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? "Anthropic 接口请求已触发速率限制 (HTTP 429)" : "Anthropic rate limit exceeded (HTTP 429)");
            }

            if (!resp.IsSuccessStatusCode)
            {
                var snippet = body.Length > 100 ? body.Substring(0, 100) : body;
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"Anthropic 兼容端点响应异常 ({(int)resp.StatusCode}): {snippet}" : $"Anthropic compatible endpoint error ({(int)resp.StatusCode}): {snippet}");
            }

            string? GetHeader(string name)
            {
                if (resp.Headers.TryGetValues(name, out var values))
                    return values.FirstOrDefault();
                if (resp.Content.Headers.TryGetValues(name, out var cv))
                    return cv.FirstOrDefault();
                return null;
            }

            var tokenLimitStr = GetHeader("anthropic-ratelimit-tokens-limit");
            var tokenRemainingStr = GetHeader("anthropic-ratelimit-tokens-remaining");
            var tokenResetStr = GetHeader("anthropic-ratelimit-tokens-reset");

            var reqLimitStr = GetHeader("anthropic-ratelimit-requests-limit");
            var reqRemainingStr = GetHeader("anthropic-ratelimit-requests-remaining");

            TokenWindow? primaryWindow = null;
            TokenWindow? secondaryWindow = null;

            if (double.TryParse(tokenLimitStr, out var limit) &&
                double.TryParse(tokenRemainingStr, out var remaining) &&
                limit > 0)
            {
                var used = Math.Max(0.0, limit - remaining);
                var usedPct = Math.Clamp((used / limit) * 100.0, 0.0, 100.0);
                var duration = OpenAIService.Instance.ParseDurationString(tokenResetStr ?? "1s");
                var now = DateTime.Now;

                primaryWindow = new TokenWindow
                {
                    Title = "Token 速率配额",
                    UsedPercentage = usedPct,
                    StartTime = now,
                    EndTime = now.Add(duration),
                    UsedAmount = used,
                    TotalLimit = limit,
                    Unit = "tokens",
                    IsIdle = used == 0.0
                };
            }

            if (double.TryParse(reqLimitStr, out var reqLimit) &&
                double.TryParse(reqRemainingStr, out var reqRem) &&
                reqLimit > 0)
            {
                var used = Math.Max(0.0, reqLimit - reqRem);
                var usedPct = Math.Clamp((used / reqLimit) * 100.0, 0.0, 100.0);

                secondaryWindow = new TokenWindow
                {
                    Title = "RPM 速率配额",
                    UsedPercentage = usedPct,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddMinutes(1),
                    UsedAmount = used,
                    TotalLimit = reqLimit,
                    Unit = "req",
                    IsIdle = used == 0.0
                };
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
            catch { }

            if (primaryWindow == null)
            {
                primaryWindow = new TokenWindow
                {
                    Title = "Anthropic 协议连接正常",
                    UsedPercentage = 0.0,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(1),
                    Unit = "%",
                    IsIdle = true
                };
            }

            var isZhAcct = LocalizationManager.Instance.IsChinese;
            var account = modelCount > 0
                ? (isZhAcct ? $"已接入 (模型数: {modelCount})" : $"Connected ({modelCount} models)")
                : (isZhAcct ? "Anthropic 兼容协议" : "Anthropic Compatible Protocol");
            return (primaryWindow, secondaryWindow, account);
        }

        /// <summary>查询 Moonshot 账户余额（人民币），失败返回 null。</summary>
        private async Task<decimal?> FetchMoonshotBalanceAsync(string apiKey)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, "https://api.moonshot.cn/v1/users/me/balance");
                req.Headers.Add("Authorization", $"Bearer {apiKey}");

                var resp = await HttpClient.SendAsync(req);
                if (!resp.IsSuccessStatusCode) return null;

                var body = await resp.Content.ReadAsStringAsync();
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("data", out var dataObj) &&
                    dataObj.TryGetProperty("available_balance", out var av))
                {
                    if (av.ValueKind == JsonValueKind.Number)
                        return (decimal)av.GetDouble();
                    if (av.ValueKind == JsonValueKind.String &&
                        decimal.TryParse(av.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsed))
                        return parsed;
                }
            }
            catch { }
            return null;
        }

        /// <summary>查询小米 MiMo 按量余额（仅接受控制台 Cookie），失败返回 null。</summary>
        private async Task<(decimal Amount, string Currency)?> FetchMiMoBalanceAsync(string cookie)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, "https://platform.xiaomimimo.com/api/v1/balance");
                req.Headers.Add("Cookie", cookie);
                req.Headers.Add("User-Agent", "TokenBar/1.0");
                req.Headers.Add("Accept", "application/json");

                var resp = await HttpClient.SendAsync(req);
                if (!resp.IsSuccessStatusCode) return null;

                var body = await resp.Content.ReadAsStringAsync();
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
            catch { }
            return null;
        }

        /// <summary>
        /// 查询小米 MiMo Token Plan 套餐用量（仅接受控制台 Cookie）。
        /// data.usage.items[] 中优先取 plan_total_token（套餐总额度），缺失时取第一条；失败返回 null。
        /// </summary>
        private async Task<(double UsedPercent, double Used, double Limit)?> FetchMiMoTokenPlanAsync(string cookie)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage");
                req.Headers.Add("Cookie", cookie);
                req.Headers.Add("User-Agent", "TokenBar/1.0");
                req.Headers.Add("Accept", "application/json");

                var resp = await HttpClient.SendAsync(req);
                if (!resp.IsSuccessStatusCode) return null;

                var body = await resp.Content.ReadAsStringAsync();
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
            catch { }
            return null;
        }

        /// <summary>查询 SiliconFlow 用户余额（人民币），失败返回 null。</summary>
        private async Task<decimal?> FetchSiliconFlowBalanceAsync(string apiKey)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, "https://api.siliconflow.cn/v1/user/info");
                req.Headers.Add("Authorization", $"Bearer {apiKey}");

                var resp = await HttpClient.SendAsync(req);
                if (!resp.IsSuccessStatusCode) return null;

                var body = await resp.Content.ReadAsStringAsync();
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("data", out var dataObj) &&
                    dataObj.TryGetProperty("balance", out var bal))
                {
                    var raw = bal.ValueKind == JsonValueKind.Number ? bal.GetRawText() : bal.GetString();
                    if (decimal.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out var parsed))
                        return parsed;
                }
            }
            catch { }
            return null;
        }
    }
}
