using TokenBar.I18n;
using System;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using TokenBar.Models;

namespace TokenBar.Services
{
    /// <summary>
    /// OpenRouter（LLM 聚合平台，纯按量扣费，美元结算）。
    /// 优先 GET /credits 查询账户余额（需 Management Key）；
    /// 403/401 权限不足时回退 GET /key：普通 Key 也能拿到自身用量与限额。
    /// </summary>
    public class OpenRouterService
    {
        public static OpenRouterService Instance { get; } = new OpenRouterService();

        private static readonly HttpClient HttpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

        private OpenRouterService() { }

        public async Task<(TokenWindow? Primary, TokenWindow? Secondary, string? Account)> FetchQuotaAsync(
            string apiKey,
            string endpoint = "https://openrouter.ai/api/v1",
            decimal balanceAlertThreshold = 5)
        {
            var cleanKey = apiKey.Trim();
            if (string.IsNullOrEmpty(cleanKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? "请输入 OpenRouter API Key" : "Please enter OpenRouter API Key");
            }

            var baseEndpoint = endpoint.Trim().TrimEnd('/');
            if (string.IsNullOrEmpty(baseEndpoint))
            {
                baseEndpoint = "https://openrouter.ai/api/v1";
            }

            var isZh = LocalizationManager.Instance.IsChinese;

            // 1. 账户余额（Management Key 专属；普通 Key 会收到 403）
            decimal? accountBalance = null;
            bool creditsUnauthorized = false;
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, $"{baseEndpoint}/credits");
                req.Headers.Add("Authorization", $"Bearer {cleanKey}");

                var resp = await HttpClient.SendAsync(req);
                if (resp.StatusCode == System.Net.HttpStatusCode.Unauthorized)
                {
                    creditsUnauthorized = true;
                }
                else if (resp.IsSuccessStatusCode)
                {
                    var json = await resp.Content.ReadAsStringAsync();
                    using var doc = JsonDocument.Parse(json);
                    if (doc.RootElement.TryGetProperty("data", out var data) &&
                        data.TryGetProperty("total_credits", out var creditsProp) &&
                        data.TryGetProperty("total_usage", out var usageProp) &&
                        creditsProp.ValueKind == JsonValueKind.Number &&
                        usageProp.ValueKind == JsonValueKind.Number)
                    {
                        var balance = (decimal)creditsProp.GetDouble() - (decimal)usageProp.GetDouble();
                        accountBalance = Math.Max(0, balance);
                    }
                }
            }
            catch
            {
                // 网络异常时继续尝试 /key，两者皆失败再抛错
            }

            // 2. 当前 Key 的用量与限额（普通 Key 即可访问）
            string? keyLabel = null;
            decimal? keyUsage = null;
            decimal? keyLimit = null;
            decimal? keyRemaining = null;
            bool keyFetched = false;
            bool keyAuthFailed = false;
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, $"{baseEndpoint}/key");
                req.Headers.Add("Authorization", $"Bearer {cleanKey}");

                var resp = await HttpClient.SendAsync(req);
                if (resp.StatusCode == System.Net.HttpStatusCode.Unauthorized ||
                    resp.StatusCode == System.Net.HttpStatusCode.Forbidden)
                {
                    keyAuthFailed = true;
                }
                else if (resp.IsSuccessStatusCode)
                {
                    var json = await resp.Content.ReadAsStringAsync();
                    using var doc = JsonDocument.Parse(json);
                    if (doc.RootElement.TryGetProperty("data", out var data))
                    {
                        keyFetched = true;
                        if (data.TryGetProperty("label", out var labelProp) && labelProp.ValueKind == JsonValueKind.String)
                            keyLabel = labelProp.GetString();
                        if (data.TryGetProperty("usage", out var usageProp) && usageProp.ValueKind == JsonValueKind.Number)
                            keyUsage = (decimal)usageProp.GetDouble();
                        if (data.TryGetProperty("limit", out var limitProp))
                        {
                            if (limitProp.ValueKind == JsonValueKind.Number && limitProp.GetDouble() > 0)
                                keyLimit = (decimal)limitProp.GetDouble();
                        }
                        if (data.TryGetProperty("limit_remaining", out var remProp) && remProp.ValueKind == JsonValueKind.Number)
                            keyRemaining = (decimal)remProp.GetDouble();
                    }
                }
            }
            catch
            {
                // 与 /credits 一样容错，最后统一判断
            }

            if (accountBalance == null && !keyFetched)
            {
                if (creditsUnauthorized || keyAuthFailed)
                {
                    throw new Exception(isZh
                        ? "OpenRouter API Key 无效或未授权 (HTTP 401/403)"
                        : "OpenRouter API Key is invalid or unauthorized (HTTP 401/403)");
                }
                throw new Exception(isZh
                    ? "OpenRouter 接口异常，余额与 Key 信息均不可用"
                    : "OpenRouter API error: neither credits nor key info is available");
            }

            // 3. 组装窗口：余额为主窗口；Key 有上限时附加"Key 额度"百分比窗口
            TokenWindow? balanceWindow = null;
            if (accountBalance.HasValue)
            {
                balanceWindow = new TokenWindow
                {
                    Title = "账户可用余额",
                    Kind = TokenWindowKind.Balance,
                    BalanceAmount = accountBalance.Value,
                    Currency = "USD",
                    WarningThreshold = balanceAlertThreshold,
                    CriticalThreshold = balanceAlertThreshold / 2,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(30)
                };
            }
            else if (keyLimit.HasValue)
            {
                // 无权限查账户余额，但 Key 有上限：以 Key 剩余额度充当余额展示
                balanceWindow = new TokenWindow
                {
                    Title = "Key 可用额度",
                    Kind = TokenWindowKind.Balance,
                    BalanceAmount = Math.Max(0, keyRemaining ?? (keyLimit.Value - (keyUsage ?? 0))),
                    Currency = "USD",
                    WarningThreshold = balanceAlertThreshold,
                    CriticalThreshold = balanceAlertThreshold / 2,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(30)
                };
            }

            TokenWindow? keyWindow = null;
            if (keyLimit.HasValue && keyLimit.Value > 0)
            {
                var usedPct = Math.Clamp((double)((keyUsage ?? 0) / keyLimit.Value) * 100.0, 0.0, 100.0);
                keyWindow = new TokenWindow
                {
                    Title = "Key 额度",
                    UsedPercentage = usedPct,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(30),
                    UsedAmount = (double?)(keyUsage ?? 0),
                    TotalLimit = (double)keyLimit.Value,
                    Unit = "$",
                    IsIdle = usedPct <= 0
                };
            }

            if (balanceWindow == null && keyWindow == null)
            {
                balanceWindow = new TokenWindow
                {
                    Title = "OpenRouter 连接正常",
                    UsedPercentage = 0.0,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(1),
                    Unit = "%",
                    IsIdle = true
                };
            }

            // 4. 卡片头部账号信息
            string account;
            if (accountBalance.HasValue)
            {
                account = isZh ? $"余额: ${accountBalance.Value:0.00}" : $"Balance: ${accountBalance.Value:0.00}";
            }
            else if (keyUsage.HasValue)
            {
                var labelPart = string.IsNullOrEmpty(keyLabel) ? "" : $" · {keyLabel}";
                account = isZh
                    ? $"Key 有效{labelPart} (已用 ${keyUsage.Value:0.00})"
                    : $"Key valid{labelPart} (used ${keyUsage.Value:0.00})";
            }
            else
            {
                account = isZh ? "Key 有效" : "Key valid";
            }

            return (balanceWindow, keyWindow, account);
        }
    }
}
