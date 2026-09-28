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

            var baseEndpoint = ProviderShared.NormalizeEndpoint(endpoint, "https://ark.cn-beijing.volces.com/api/v3");

            var modelsUrl = ProviderShared.ModelsUrl(baseEndpoint);

            using var req = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
            req.Headers.Add("Authorization", $"Bearer {cleanKey}");
            req.Headers.Add("Accept", "application/json");

            using var resp = await Http.Shared.SendAsync(req, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);

            ProviderHttpErrors.ThrowForStatus(resp, body, ProviderHttpErrorOptions.Volcengine);

            TokenWindow? primaryWindow = resp.BuildRateLimitWindow(
                RateLimitHeaderSet.OpenAI("tokens"), WindowTitle.TpmRate, "tokens");

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
                primaryWindow = TokenWindow.Status(WindowTitle.ConnectedFor("接入点"));
            }

            var keySuffix = ProviderShared.KeySuffixMask(cleanKey);
            var isZh = LocalizationManager.Instance.IsChinese;
            var modelLabel = !string.IsNullOrEmpty(model) ? model : (isZh ? $"模型数: {modelCount}" : $"{modelCount} models");
            var account = isZh ? $"火山方舟 ({modelLabel} • 尾号 {keySuffix})" : $"Volcengine Ark ({modelLabel} • ...{keySuffix})";

            return (primaryWindow, null, account);
        }
    }
}
