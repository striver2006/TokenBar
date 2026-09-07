using System;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using TokenBar.Models;

namespace TokenBar.Services
{
    public class GLMService
    {
        public static GLMService Instance { get; } = new GLMService();

        private static readonly HttpClient HttpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

        private GLMService() { }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchQuotaAsync(
            string apiKey,
            string endpoint = "https://open.bigmodel.cn/api/v1")
        {
            var cleanKey = apiKey.Trim();
            if (string.IsNullOrEmpty(cleanKey))
            {
                throw new ArgumentException("API Key 不能为空");
            }

            var trimmedEndpoint = endpoint.Trim().TrimEnd('/');
            string baseHost;
            string openAIEndpoint;

            if (trimmedEndpoint.EndsWith("/api/v1", StringComparison.OrdinalIgnoreCase))
            {
                openAIEndpoint = trimmedEndpoint;
                baseHost = trimmedEndpoint[..^"/api/v1".Length];
            }
            else if (trimmedEndpoint.Contains("/api/paas/v4", StringComparison.OrdinalIgnoreCase))
            {
                baseHost = trimmedEndpoint.Replace("/api/paas/v4", "");
                openAIEndpoint = $"{baseHost}/api/v1";
            }
            else
            {
                baseHost = trimmedEndpoint;
                openAIEndpoint = $"{trimmedEndpoint}/api/v1";
            }

            var keySuffix = cleanKey.Length > 6 ? cleanKey[^4..] : cleanKey;
            var account = $"GLM (...{keySuffix})";

            double? rateLimitTokensRemaining = null;
            double? rateLimitTokensTotal = null;
            double? rateLimitResetDurationSec = null;

            // 1. Verify OpenAI Response Protocol via GET /models
            try
            {
                using var openAiReq = new HttpRequestMessage(HttpMethod.Get, $"{openAIEndpoint}/models");
                openAiReq.Headers.Add("Authorization", $"Bearer {cleanKey}");
                openAiReq.Headers.Add("Accept", "application/json");

                var openAiResp = await HttpClient.SendAsync(openAiReq);
                var openAiData = await openAiResp.Content.ReadAsStringAsync();

                if (openAiResp.StatusCode == System.Net.HttpStatusCode.Unauthorized ||
                    openAiResp.StatusCode == System.Net.HttpStatusCode.Forbidden)
                {
                    throw new Exception("GLM API Key 无效或未授权");
                }

                try
                {
                    using var doc = JsonDocument.Parse(openAiData);
                    if (doc.RootElement.TryGetProperty("code", out var codeProp) && codeProp.GetInt32() == 1001)
                    {
                        var msg = doc.RootElement.TryGetProperty("msg", out var m) ? m.GetString() : "未收到有效 Authorization 参数";
                        throw new Exception($"身份验证失败: {msg}");
                    }
                }
                catch (Exception ex) when (ex.Message.StartsWith("身份验证失败"))
                {
                    throw;
                }
                catch { }

                if (openAiResp.Headers.TryGetValues("x-ratelimit-remaining-tokens", out var remVals) &&
                    double.TryParse(remVals.FirstOrDefault(), out var rem))
                {
                    rateLimitTokensRemaining = rem;
                }
                if (openAiResp.Headers.TryGetValues("x-ratelimit-limit-tokens", out var totVals) &&
                    double.TryParse(totVals.FirstOrDefault(), out var tot))
                {
                    rateLimitTokensTotal = tot;
                }
                if (openAiResp.Headers.TryGetValues("x-ratelimit-reset-tokens", out var rstVals) &&
                    double.TryParse(rstVals.FirstOrDefault(), out var rst))
                {
                    rateLimitResetDurationSec = rst;
                }
            }
            catch (Exception ex) when (ex.Message.Contains("GLM API Key") || ex.Message.Contains("身份验证失败"))
            {
                throw;
            }
            catch { }

            // 2. Query BigModel Quota & 5-hour limit endpoint
            TokenWindow? fiveHourWindow = null;
            TokenWindow? weeklyWindow = null;

            try
            {
                var quotaUrl = $"{baseHost}/api/monitor/usage/quota/limit";
                using var quotaReq = new HttpRequestMessage(HttpMethod.Get, quotaUrl);
                quotaReq.Headers.Add("Authorization", $"Bearer {cleanKey}");
                quotaReq.Headers.Add("Accept", "application/json");
                quotaReq.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) TokenBar/1.0");

                var quotaResp = await HttpClient.SendAsync(quotaReq);
                if (quotaResp.IsSuccessStatusCode)
                {
                    var quotaData = await quotaResp.Content.ReadAsStringAsync();
                    using var doc = JsonDocument.Parse(quotaData);
                    var root = doc.RootElement;

                    JsonElement limitsArray = default;
                    if (root.TryGetProperty("data", out var dataObj) && dataObj.TryGetProperty("limits", out var lim1))
                    {
                        limitsArray = lim1;
                    }
                    else if (root.TryGetProperty("limits", out var lim2))
                    {
                        limitsArray = lim2;
                    }

                    if (limitsArray.ValueKind == JsonValueKind.Array)
                    {
                        foreach (var item in limitsArray.EnumerateArray())
                        {
                            var type = item.TryGetProperty("type", out var tp) ? tp.GetString()?.ToUpperInvariant() ?? "" : "";
                            double pct = 0.0;
                            if (item.TryGetProperty("percentage", out var p1)) pct = p1.GetDouble();
                            else if (item.TryGetProperty("utilization", out var p2)) pct = p2.GetDouble();

                            double resetMs = 0;
                            if (item.TryGetProperty("nextResetTime", out var nrProp))
                            {
                                var val = nrProp.GetDouble();
                                resetMs = val < 10000000000 ? val * 1000 : val;
                            }
                            else
                            {
                                resetMs = DateTimeOffset.UtcNow.AddHours(5).ToUnixTimeMilliseconds();
                            }

                            var resetDate = DateTimeOffset.FromUnixTimeMilliseconds((long)resetMs).LocalDateTime;
                            double? usedTokens = item.TryGetProperty("used", out var up) ? up.GetDouble() : null;
                            double? totalTokens = item.TryGetProperty("total", out var top) ? top.GetDouble() : null;

                            if (type.Contains("TOKEN") || type.Contains("5H") || type.Contains("SESSION") || (fiveHourWindow == null && !type.Contains("WEEK")))
                            {
                                fiveHourWindow = new TokenWindow
                                {
                                    Title = "5小时额度",
                                    UsedPercentage = pct,
                                    StartTime = resetDate.AddHours(-5),
                                    EndTime = resetDate,
                                    UsedAmount = usedTokens,
                                    TotalLimit = totalTokens,
                                    Unit = totalTokens != null ? "Tokens" : "%"
                                };
                            }
                            else if (type.Contains("WEEK") || (weeklyWindow == null && fiveHourWindow != null))
                            {
                                weeklyWindow = new TokenWindow
                                {
                                    Title = "每周额度",
                                    UsedPercentage = pct,
                                    StartTime = resetDate.AddDays(-7),
                                    EndTime = resetDate,
                                    UsedAmount = usedTokens,
                                    TotalLimit = totalTokens,
                                    Unit = totalTokens != null ? "Tokens" : "%"
                                };
                            }
                        }
                    }
                }
            }
            catch { }

            // 3. Fallback
            if (fiveHourWindow == null)
            {
                var now = DateTime.Now;
                double usedPct = 0.0;
                var fiveHourEnd = now.AddHours(5);

                if (rateLimitTokensRemaining.HasValue && rateLimitTokensTotal.HasValue && rateLimitTokensTotal.Value > 0)
                {
                    usedPct = Math.Clamp((1.0 - (rateLimitTokensRemaining.Value / rateLimitTokensTotal.Value)) * 100.0, 0.0, 100.0);
                }
                if (rateLimitResetDurationSec.HasValue && rateLimitResetDurationSec.Value > 0)
                {
                    fiveHourEnd = now.AddSeconds(rateLimitResetDurationSec.Value);
                }

                fiveHourWindow = new TokenWindow
                {
                    Title = "5小时额度",
                    UsedPercentage = usedPct,
                    StartTime = fiveHourEnd.AddHours(-5),
                    EndTime = fiveHourEnd,
                    UsedAmount = rateLimitTokensRemaining.HasValue && rateLimitTokensTotal.HasValue ? rateLimitTokensTotal.Value - rateLimitTokensRemaining.Value : null,
                    TotalLimit = rateLimitTokensTotal,
                    Unit = rateLimitTokensTotal != null ? "Tokens" : "%"
                };

                int diffToMonday = (7 + (now.DayOfWeek - DayOfWeek.Monday)) % 7;
                var weekStart = now.Date.AddDays(-diffToMonday);
                var weekEnd = weekStart.AddDays(7);

                weeklyWindow = new TokenWindow
                {
                    Title = "每周额度",
                    UsedPercentage = usedPct * 0.6,
                    StartTime = weekStart,
                    EndTime = weekEnd,
                    Unit = "%"
                };
            }

            return (fiveHourWindow, weeklyWindow, account);
        }
    }
}
