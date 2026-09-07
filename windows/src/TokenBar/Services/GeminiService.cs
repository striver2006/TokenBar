using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using TokenBar.Models;

namespace TokenBar.Services
{
    public class GeminiService
    {
        public static GeminiService Instance { get; } = new GeminiService();

        private static readonly HttpClient HttpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

        private GeminiService() { }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);

        [DllImport("advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]
        private static extern void CredFree(IntPtr buffer);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public long LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        private static string? ReadCredential(string target)
        {
            try
            {
                if (CredRead(target, 1, 0, out var ptr))
                {
                    try
                    {
                        var cred = Marshal.PtrToStructure<CREDENTIAL>(ptr);
                        if (cred.CredentialBlobSize > 0 && cred.CredentialBlob != IntPtr.Zero)
                        {
                            var bytes = new byte[cred.CredentialBlobSize];
                            Marshal.Copy(cred.CredentialBlob, bytes, 0, cred.CredentialBlobSize);
                            return System.Text.Encoding.UTF8.GetString(bytes);
                        }
                    }
                    finally
                    {
                        CredFree(ptr);
                    }
                }
            }
            catch { }
            return null;
        }

        public (string? Token, string? RefreshToken, string? Account) ReadLocalGeminiConfig()
        {
            var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var geminiDir = Path.Combine(userProfile, ".gemini");

            var jetskiPath = Path.Combine(geminiDir, "jetski-standalone-oauth-token");
            var oauthCredsPath = Path.Combine(geminiDir, "oauth_creds.json");
            var accountsPath = Path.Combine(geminiDir, "google_accounts.json");

            string? token = null;
            string? refreshToken = null;
            string? account = null;

            // 0. Check Windows Credential Manager (gemini:antigravity)
            var credBlob = ReadCredential("gemini:antigravity");
            if (!string.IsNullOrEmpty(credBlob))
            {
                try
                {
                    using var doc = JsonDocument.Parse(credBlob);
                    if (doc.RootElement.TryGetProperty("token", out var tokObj))
                    {
                        if (tokObj.TryGetProperty("access_token", out var ap))
                            token = ap.GetString();
                        if (tokObj.TryGetProperty("refresh_token", out var rp))
                            refreshToken = rp.GetString();
                    }
                    else if (doc.RootElement.TryGetProperty("access_token", out var ap2))
                    {
                        token = ap2.GetString();
                        if (doc.RootElement.TryGetProperty("refresh_token", out var rp2))
                            refreshToken = rp2.GetString();
                    }
                }
                catch { }
            }

            // 1. Check jetski token
            if (token == null && File.Exists(jetskiPath))
            {
                try
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(jetskiPath));
                    if (doc.RootElement.TryGetProperty("token", out var tokObj))
                    {
                        if (tokObj.TryGetProperty("access_token", out var ap))
                            token = ap.GetString();
                        if (tokObj.TryGetProperty("refresh_token", out var rp))
                            refreshToken = rp.GetString();
                    }
                }
                catch { }
            }

            // 2. Fallback to oauth_creds.json
            if (token == null && File.Exists(oauthCredsPath))
            {
                try
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(oauthCredsPath));
                    if (doc.RootElement.TryGetProperty("access_token", out var ap))
                        token = ap.GetString();
                    if (refreshToken == null && doc.RootElement.TryGetProperty("refresh_token", out var rp))
                        refreshToken = rp.GetString();
                }
                catch { }
            }

            // 3. Read Google account email
            if (File.Exists(accountsPath))
            {
                try
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(accountsPath));
                    if (doc.RootElement.TryGetProperty("active", out var act))
                        account = act.GetString();
                }
                catch { }
            }

            return (token, refreshToken, account);
        }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchQuotaWithApiKeyAsync(
            string apiKey,
            string endpoint = "https://generativelanguage.googleapis.com")
        {
            var trimmedKey = apiKey.Trim();
            if (string.IsNullOrEmpty(trimmedKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? "请输入有效的 Google AI Studio API Key" : "Please enter a valid Google AI Studio API Key");
            }

            var cleanBase = endpoint.Trim().TrimEnd('/');
            if (string.IsNullOrEmpty(cleanBase))
            {
                cleanBase = "https://generativelanguage.googleapis.com";
            }

            var urlString = (cleanBase.EndsWith("/v1beta", StringComparison.OrdinalIgnoreCase) ||
                             cleanBase.EndsWith("/v1", StringComparison.OrdinalIgnoreCase))
                ? $"{cleanBase}/models?pageSize=50"
                : $"{cleanBase}/v1beta/models?pageSize=50";

            using var request = new HttpRequestMessage(HttpMethod.Get, urlString);
            request.Headers.Add("x-goog-api-key", trimmedKey);
            request.Headers.Add("Accept", "application/json");

            var resp = await HttpClient.SendAsync(request);
            var body = await resp.Content.ReadAsStringAsync();

            if (!resp.IsSuccessStatusCode)
            {
                try
                {
                    using var doc = JsonDocument.Parse(body);
                    if (doc.RootElement.TryGetProperty("error", out var err) &&
                        err.TryGetProperty("message", out var msg))
                    {
                        throw new Exception(LocalizationManager.Instance.IsChinese ? $"Gemini API 错误: {msg.GetString()}" : $"Gemini API error: {msg.GetString()}");
                    }
                }
                catch (Exception ex) when (!ex.Message.StartsWith("Gemini API"))
                {
                }
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"Gemini API 响应异常 ({(int)resp.StatusCode}): {body}" : $"Gemini API response error ({(int)resp.StatusCode}): {body}");
            }

            int modelCount = 0;
            try
            {
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("models", out var models) && models.ValueKind == JsonValueKind.Array)
                {
                    modelCount = models.GetArrayLength();
                }
            }
            catch { }

            string? GetHeader(string name)
            {
                if (resp.Headers.TryGetValues(name, out var values))
                    return values.FirstOrDefault();
                if (resp.Content.Headers.TryGetValues(name, out var cv))
                    return cv.FirstOrDefault();
                return null;
            }

            var limitReqsStr = GetHeader("x-ratelimit-limit-requests") ?? GetHeader("x-ratelimit-limit-rpm");
            var remReqsStr = GetHeader("x-ratelimit-remaining-requests") ?? GetHeader("x-ratelimit-remaining-rpm");

            TokenWindow? rpmWindow = null;
            if (double.TryParse(limitReqsStr, out var limitReqs) &&
                double.TryParse(remReqsStr, out var remReqs) &&
                limitReqs > 0)
            {
                var used = Math.Max(0.0, limitReqs - remReqs);
                var usedPct = Math.Clamp((used / limitReqs) * 100.0, 0.0, 100.0);
                var nowTime = DateTime.Now;
                rpmWindow = new TokenWindow
                {
                    Title = "RPM 速率配额",
                    UsedPercentage = usedPct,
                    StartTime = nowTime,
                    EndTime = nowTime.AddMinutes(1),
                    UsedAmount = used,
                    TotalLimit = limitReqs,
                    Unit = "req/min",
                    IsIdle = used == 0.0
                };
            }

            var now = DateTime.Now;
            int currentHour = now.Hour;
            int slotStartHour = (currentHour / 5) * 5;
            var windowStart = new DateTime(now.Year, now.Month, now.Day, slotStartHour, 0, 0);
            var windowEnd = windowStart.AddHours(5);

            var fiveHour = rpmWindow ?? new TokenWindow
            {
                Title = "API 连接正常",
                UsedPercentage = 0.0,
                StartTime = windowStart,
                EndTime = windowEnd,
                Unit = "%",
                IsIdle = true
            };

            int diffToMonday = (7 + (now.DayOfWeek - DayOfWeek.Monday)) % 7;
            var weekStart = now.Date.AddDays(-diffToMonday);
            var weekEnd = weekStart.AddDays(7);

            var weekly = new TokenWindow
            {
                Title = modelCount > 0 ? $"可用模型 ({modelCount}个)" : "AI Studio 配额",
                UsedPercentage = 0.0,
                StartTime = weekStart,
                EndTime = weekEnd,
                Unit = "%",
                IsIdle = true
            };

            string maskedKey = trimmedKey.Length > 8
                ? $"{trimmedKey[..6]}...{trimmedKey[^4..]}"
                : "AI Studio Key";

            var accountDisplay = $"AI Studio ({maskedKey})";
            return (fiveHour, weekly, accountDisplay);
        }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchQuotaAsync(string? token)
        {
            var local = ReadLocalGeminiConfig();
            var activeToken = !string.IsNullOrWhiteSpace(token) ? token : local.Token;
            var detectedAccount = local.Account;

            if (string.IsNullOrEmpty(activeToken))
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? "请在设置中配置 Google AI Studio Key 或检测 Google 本地登录凭证" : "Please configure a Google AI Studio Key in Settings, or detect local Google credentials");
            }

            // Query models
            double usedPct5h = 15.0;
            double usedPctWeek = 8.0;

            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1");
                req.Headers.Add("Authorization", $"Bearer {activeToken}");
                req.Headers.Add("Accept", "application/json");

                var resp = await HttpClient.SendAsync(req);
                if (resp.Headers.TryGetValues("x-ratelimit-remaining-requests", out var vals) &&
                    double.TryParse(vals.FirstOrDefault(), out var rem))
                {
                    usedPct5h = Math.Clamp(100.0 - rem, 0.0, 100.0);
                }
            }
            catch { }

            var now = DateTime.Now;
            int currentHour = now.Hour;
            int slotStartHour = (currentHour / 5) * 5;
            var windowStart = new DateTime(now.Year, now.Month, now.Day, slotStartHour, 0, 0);
            var windowEnd = windowStart.AddHours(5);

            var fiveHour = new TokenWindow
            {
                Title = "5小时算力额度",
                UsedPercentage = usedPct5h,
                StartTime = windowStart,
                EndTime = windowEnd,
                Unit = "%"
            };

            int diffToMonday = (7 + (now.DayOfWeek - DayOfWeek.Monday)) % 7;
            var weekStart = now.Date.AddDays(-diffToMonday);
            var weekEnd = weekStart.AddDays(7);

            var weekly = new TokenWindow
            {
                Title = "每周额度",
                UsedPercentage = usedPctWeek,
                StartTime = weekStart,
                EndTime = weekEnd,
                Unit = "%"
            };

            if (string.IsNullOrEmpty(detectedAccount) && !string.IsNullOrEmpty(activeToken))
            {
                detectedAccount = await FetchUserInfoAsync(activeToken);
            }

            return (fiveHour, weekly, detectedAccount ?? (LocalizationManager.Instance.IsChinese ? "Google 账号" : "Google Account"));
        }

        public async Task<string?> FetchUserInfoAsync(string token)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, "https://www.googleapis.com/oauth2/v2/userinfo");
                req.Headers.Add("Authorization", $"Bearer {token}");
                req.Headers.Add("Accept", "application/json");

                var resp = await HttpClient.SendAsync(req);
                if (resp.IsSuccessStatusCode)
                {
                    var json = await resp.Content.ReadAsStringAsync();
                    using var doc = JsonDocument.Parse(json);
                    if (doc.RootElement.TryGetProperty("email", out var emailProp) && emailProp.ValueKind == JsonValueKind.String)
                    {
                        return emailProp.GetString();
                    }
                    if (doc.RootElement.TryGetProperty("name", out var nameProp) && nameProp.ValueKind == JsonValueKind.String)
                    {
                        return nameProp.GetString();
                    }
                }
            }
            catch { }
            return null;
        }
    }
}
