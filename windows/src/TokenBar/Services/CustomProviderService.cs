using System;
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
                throw new ArgumentException($"请在配置中填入 {config.Name} 的 API KEY");
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
            TokenWindow? balanceWindow = null;

            if (endpoint.Contains("deepseek.com", StringComparison.OrdinalIgnoreCase))
            {
                var balance = await DeepSeekService.Instance.FetchBalanceAsync(apiKey);
                if (balance != null)
                {
                    balanceAccountInfo = $"余额: {balance}";
                    balanceWindow = new TokenWindow
                    {
                        Title = "账户余额",
                        UsedPercentage = 0.0,
                        StartTime = DateTime.Now,
                        EndTime = DateTime.Now.AddDays(30),
                        Unit = "¥",
                        IsIdle = true
                    };
                }
            }
            else if (endpoint.Contains("moonshot.cn", StringComparison.OrdinalIgnoreCase))
            {
                var balance = await FetchMoonshotBalanceAsync(apiKey);
                if (balance != null)
                {
                    balanceAccountInfo = $"余额: {balance}";
                    balanceWindow = new TokenWindow
                    {
                        Title = "账户余额",
                        UsedPercentage = 0.0,
                        StartTime = DateTime.Now,
                        EndTime = DateTime.Now.AddDays(30),
                        Unit = "¥",
                        IsIdle = true
                    };
                }
            }
            else if (endpoint.Contains("siliconflow.cn", StringComparison.OrdinalIgnoreCase))
            {
                var balance = await FetchSiliconFlowBalanceAsync(apiKey);
                if (balance != null)
                {
                    balanceAccountInfo = $"余额: {balance}";
                    balanceWindow = new TokenWindow
                    {
                        Title = "账户余额",
                        UsedPercentage = 0.0,
                        StartTime = DateTime.Now,
                        EndTime = DateTime.Now.AddDays(30),
                        Unit = "¥",
                        IsIdle = true
                    };
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
                throw new Exception($"{config.Name} API Key 认证失败 (HTTP 401)，请核对密钥");
            }

            if ((int)resp.StatusCode == 429)
            {
                var msg = "请求过于频繁或额度不足 (HTTP 429)";
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
                throw new Exception($"请求端点失败 ({(int)resp.StatusCode}): {snippet}");
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

            TokenWindow? primaryWindow = balanceWindow;
            TokenWindow? secondaryWindow = null;

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
                else
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

            var account = balanceAccountInfo ?? (modelCount > 0 ? $"可用模型: {modelCount}个" : "已连接");
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
                throw new Exception($"{config.Name} Anthropic API Key 无效或未授权 (HTTP 401)");
            }

            if ((int)resp.StatusCode == 429)
            {
                throw new Exception("Anthropic 接口请求已触发速率限制 (HTTP 429)");
            }

            if (!resp.IsSuccessStatusCode)
            {
                var snippet = body.Length > 100 ? body.Substring(0, 100) : body;
                throw new Exception($"Anthropic 兼容端点响应异常 ({(int)resp.StatusCode}): {snippet}");
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

            var account = modelCount > 0 ? $"已接入 (模型数: {modelCount})" : "Anthropic 兼容协议";
            return (primaryWindow, secondaryWindow, account);
        }

        private async Task<string?> FetchMoonshotBalanceAsync(string apiKey)
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
                    return $"¥{av.GetDouble():F2}";
                }
            }
            catch { }
            return null;
        }

        private async Task<string?> FetchSiliconFlowBalanceAsync(string apiKey)
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
                    return $"¥{bal.GetString()}";
                }
            }
            catch { }
            return null;
        }
    }
}
