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
    public class VolcengineService
    {
        public static VolcengineService Instance { get; } = new VolcengineService();

        private VolcengineService() { }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchQuotaAsync(
            string apiKey,
            string endpoint = "https://ark.cn-beijing.volces.com/api/v3",
            string model = "",
            CancellationToken ct = default)
        {
            var cleanKey = apiKey.Trim();
            if (string.IsNullOrEmpty(cleanKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? "请输入火山方舟 API Key" : "Please enter Volcengine Ark API Key");
            }

            var baseEndpoint = endpoint.Trim().TrimEnd('/');
            if (string.IsNullOrEmpty(baseEndpoint))
            {
                baseEndpoint = "https://ark.cn-beijing.volces.com/api/v3";
            }

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
                throw new Exception(LocalizationManager.Instance.IsChinese ? "火山方舟 API Key 无效或未授权 (HTTP 401)" : "Volcengine Ark API Key is invalid or unauthorized (HTTP 401)");
            }

            if ((int)resp.StatusCode == 429)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? "火山方舟并发或速率超限 (HTTP 429)" : "Volcengine Ark rate limit or concurrency exceeded (HTTP 429)");
            }

            if (!resp.IsSuccessStatusCode)
            {
                var snippet = body.Length > 100 ? body.Substring(0, 100) : body;
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"火山方舟响应异常 ({(int)resp.StatusCode}): {snippet}" : $"Volcengine Ark response error ({(int)resp.StatusCode}): {snippet}");
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
                Log.Warn("provider", $"volcengine /models 响应不是 JSON: {ex.Message}");
            }

            if (primaryWindow == null)
            {
                primaryWindow = TokenWindow.Status("接入点连接正常");
            }

            var keySuffix = cleanKey.Length > 6 ? cleanKey[^4..] : cleanKey;
            var isZh = LocalizationManager.Instance.IsChinese;
            var modelLabel = !string.IsNullOrEmpty(model) ? model : (isZh ? $"模型数: {modelCount}" : $"{modelCount} models");
            var account = isZh ? $"火山方舟 ({modelLabel} • 尾号 {keySuffix})" : $"Volcengine Ark ({modelLabel} • ...{keySuffix})";

            return (primaryWindow, null, account);
        }
    }
}
