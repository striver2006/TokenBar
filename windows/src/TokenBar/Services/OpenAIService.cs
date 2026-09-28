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
    public class OpenAIService
    {
        public static OpenAIService Instance { get; } = new OpenAIService();

        private OpenAIService() { }

        public async Task<(TokenWindow? Primary, TokenWindow? Secondary, string? Account)> FetchQuotaAsync(
            string apiKey,
            string endpoint = "https://api.openai.com/v1",
            string? organizationId = null,
            CancellationToken ct = default)
        {
            var trimmedKey = apiKey.Trim();
            if (string.IsNullOrEmpty(trimmedKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? "请输入 OpenAI API Key" : "Please enter OpenAI API Key");
            }

            var baseEndpoint = ProviderShared.NormalizeEndpoint(endpoint, "https://api.openai.com/v1");

            var targetUrl = ProviderShared.ModelsUrl(baseEndpoint);

            using var request = new HttpRequestMessage(HttpMethod.Get, targetUrl);
            request.Headers.Add("Authorization", $"Bearer {trimmedKey}");
            request.Headers.Add("Accept", "application/json");

            if (!string.IsNullOrWhiteSpace(organizationId))
            {
                request.Headers.Add("OpenAI-Organization", organizationId.Trim());
            }

            HttpResponseMessage response;
            try
            {
                response = await Http.Shared.SendAsync(request, ct);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"OpenAI 网络连接失败: {ex.Message}" : $"OpenAI network connection failed: {ex.Message}", ex);
            }

            using (response)
            {
                var responseBody = await response.Content.ReadAsStringAsync(ct);

                ProviderHttpErrors.ThrowForStatus(response, responseBody, ProviderHttpErrorOptions.OpenAI);

                // Parse rate limit headers
                var orgHeader = response.GetHeader("openai-organization");

                // 1. Tokens Rate Limit Window (TPM)
                TokenWindow? primaryWindow = response.BuildRateLimitWindow(
                    RateLimitHeaderSet.OpenAI("tokens"), WindowTitle.TpmRemaining, "tokens");

                // 2. Requests Rate Limit Window (RPM)
                TokenWindow? secondaryWindow = response.BuildRateLimitWindow(
                    RateLimitHeaderSet.OpenAI("requests"), WindowTitle.RpmRequest, "req");

                int modelCount = 0;
                try
                {
                    using var doc = JsonDocument.Parse(responseBody);
                    if (doc.RootElement.TryGetProperty("data", out var dataArr) &&
                        dataArr.ValueKind == JsonValueKind.Array)
                    {
                        modelCount = dataArr.GetArrayLength();
                    }
                }
                catch (JsonException ex)
                {
                    Log.Warn("provider", $"openai /models 响应不是 JSON: {ex.Message}");
                }

                if (primaryWindow == null)
                {
                    // 没有速率头：只表示连接正常，不编造任何百分比
                    primaryWindow = TokenWindow.Status(WindowTitle.Connected);
                }

                var accountInfo = orgHeader ?? organizationId;
                if (string.IsNullOrWhiteSpace(accountInfo))
                {
                    accountInfo = modelCount > 0
                        ? (LocalizationManager.Instance.IsChinese ? $"OpenAI (可用模型: {modelCount}个)" : $"OpenAI ({modelCount} models available)")
                        : "OpenAI API";
                }

                return (primaryWindow, secondaryWindow, accountInfo);
            }
        }
    }
}
