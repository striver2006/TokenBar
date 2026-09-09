using TokenBar.I18n;
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

        // Antigravity (Google Code Assist) quota backend endpoints.
        // Antigravity uses daily-cloudcode-pa.googleapis.com for actual user quota tracking;
        // cloudcode-pa.googleapis.com is kept as fallback.
        private static readonly string[] CloudCodeQuotaBases = new[]
        {
            "https://daily-cloudcode-pa.googleapis.com",
            "https://cloudcode-pa.googleapis.com"
        };

        // The OAuth client pair used for token refresh is the public "installed app" client that
        // Google ships inside the agy CLI / Antigravity IDE binaries. Nothing is embedded here:
        // candidates are discovered at runtime from the local installation (or the
        // ANTIGRAVITY_CLIENT_ID / ANTIGRAVITY_CLIENT_SECRET environment variables), and the
        // pair that successfully refreshes the stored token is cached for the session.
        private static readonly System.Text.RegularExpressions.Regex ClientIdRegex = new(
            "[0-9]{6,}-[a-z0-9]{10,}\\.apps\\.googleusercontent\\.com",
            System.Text.RegularExpressions.RegexOptions.Compiled);
        private static readonly System.Text.RegularExpressions.Regex ClientSecretRegex = new(
            "GOCSPX-[A-Za-z0-9_-]{28}",
            System.Text.RegularExpressions.RegexOptions.Compiled);

        private static List<(string Id, string Secret)>? _antigravityClientCandidates;

        private static List<(string Id, string Secret)> GetAntigravityClientCandidates()
        {
            if (_antigravityClientCandidates != null)
                return _antigravityClientCandidates;

            var list = new List<(string Id, string Secret)>();
            var envId = Environment.GetEnvironmentVariable("ANTIGRAVITY_CLIENT_ID");
            var envSecret = Environment.GetEnvironmentVariable("ANTIGRAVITY_CLIENT_SECRET");
            if (!string.IsNullOrWhiteSpace(envId) && !string.IsNullOrWhiteSpace(envSecret))
            {
                list.Add((envId!.Trim(), envSecret!.Trim()));
                _antigravityClientCandidates = list;
                return list;
            }

            var ids = new HashSet<string>();
            var secrets = new HashSet<string>();
            var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var scanTargets = new[]
            {
                Path.Combine(localAppData, "agy", "bin", "agy.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".gemini", "bin", "agy.exe"),
                Path.Combine(localAppData, "Programs", "Antigravity", "resources", "bin", "language_server.exe"),
            };
            foreach (var target in scanTargets)
            {
                if (ids.Count > 0 && secrets.Count > 0)
                    break;
                if (File.Exists(target))
                    ScanFileForClientPatterns(target, ids, secrets);
            }

            foreach (var id in ids)
            {
                foreach (var secret in secrets)
                {
                    list.Add((id, secret));
                    if (list.Count >= 8)
                        break;
                }
            }

            _antigravityClientCandidates = list;
            return list;
        }

        /// <summary>Scans a large binary in overlapping chunks for the embedded OAuth client patterns.</summary>
        private static void ScanFileForClientPatterns(string path, HashSet<string> ids, HashSet<string> secrets)
        {
            const int chunkSize = 4 * 1024 * 1024;
            const int overlap = 1024;
            try
            {
                using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, chunkSize);
                var buffer = new byte[chunkSize + overlap];
                int carryOver = 0;
                while (true)
                {
                    var read = fs.Read(buffer, carryOver, chunkSize);
                    if (read == 0)
                        break;
                    var len = carryOver + read;
                    var text = System.Text.Encoding.Latin1.GetString(buffer, 0, len);
                    foreach (System.Text.RegularExpressions.Match m in ClientIdRegex.Matches(text))
                        ids.Add(m.Value);
                    foreach (System.Text.RegularExpressions.Match m in ClientSecretRegex.Matches(text))
                        secrets.Add(m.Value);
                    carryOver = Math.Min(overlap, len);
                    Array.Copy(buffer, len - carryOver, buffer, 0, carryOver);
                    if (read < chunkSize)
                        break;
                }
            }
            catch { }
        }

        // Refreshed access tokens are short-lived (~1h); cache in memory instead of refreshing on every poll.
        private static string? _cachedAccessToken;
        private static DateTime _cachedAccessTokenExpiryUtc = DateTime.MinValue;

        // 上一次令牌刷新整体失败的时刻。候选逐个试是昂贵操作，凭证真失效时每轮都重试纯属浪费。
        private static DateTime? _lastTokenRefreshFailureUtc;
        private static readonly TimeSpan TokenRefreshCooldown = TimeSpan.FromSeconds(120);
        // 候选循环的总预算。HttpClient 的 Timeout 是 15s，8 个候选串行最坏 120s，
        // 远超刷新间隔，会把 RefreshManager 的闸门长时间占住。
        private static readonly TimeSpan TokenRefreshBudget = TimeSpan.FromSeconds(20);
        private const int TokenClientCandidateLimit = 3;

        private sealed class QuotaAuthException : Exception
        {
            public QuotaAuthException() : base("quota auth rejected") { }
        }

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

        public (string? Token, string? RefreshToken, string? Account, DateTime? Expiry) ReadLocalGeminiConfig()
        {
            var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var geminiDir = Path.Combine(userProfile, ".gemini");

            var jetskiPath = Path.Combine(geminiDir, "jetski-standalone-oauth-token");
            var oauthCredsPath = Path.Combine(geminiDir, "oauth_creds.json");
            var accountsPath = Path.Combine(geminiDir, "google_accounts.json");

            string? token = null;
            string? refreshToken = null;
            string? account = null;
            DateTime? expiry = null;

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
                        if (tokObj.TryGetProperty("expiry", out var ep) && ep.ValueKind == JsonValueKind.String)
                            expiry = ParseTokenExpiry(ep.GetString());
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
                        if (tokObj.TryGetProperty("expiry", out var ep) && ep.ValueKind == JsonValueKind.String)
                            expiry = ParseTokenExpiry(ep.GetString());
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
                    if (doc.RootElement.TryGetProperty("active", out var act) && act.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(act.GetString()))
                        account = act.GetString();
                    else if (doc.RootElement.TryGetProperty("old", out var old) && old.ValueKind == JsonValueKind.Array && old.GetArrayLength() > 0)
                        account = old[0].GetString();
                }
                catch { }
            }

            return (token, refreshToken, account, expiry);
        }

        /// <summary>Parses the RFC3339 expiry written by agy/Gemini CLI, e.g. "2026-09-08T01:23:12.8592338+08:00".</summary>
        private static DateTime? ParseTokenExpiry(string? value)
        {
            if (string.IsNullOrWhiteSpace(value))
                return null;
            if (DateTime.TryParse(value, System.Globalization.CultureInfo.InvariantCulture,
                System.Globalization.DateTimeStyles.None, out var parsed))
            {
                return parsed;
            }
            return null;
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
            var refreshToken = local.RefreshToken;
            var detectedAccount = local.Account;

            // Resolve an access token: cached refresh result > valid local token > explicit setting (if valid) > refreshed.
            string accessToken;
            var cached = (_cachedAccessToken != null && DateTime.UtcNow < _cachedAccessTokenExpiryUtc) ? _cachedAccessToken : null;
            if (cached != null)
            {
                accessToken = cached;
            }
            else if (!string.IsNullOrWhiteSpace(local.Token) && local.Expiry != null && local.Expiry > DateTime.Now.AddMinutes(2))
            {
                accessToken = local.Token!;
            }
            else if (!string.IsNullOrWhiteSpace(token) && (local.Expiry == null || local.Expiry > DateTime.Now.AddMinutes(2)))
            {
                accessToken = token!;
            }
            else if (!string.IsNullOrWhiteSpace(refreshToken))
            {
                accessToken = await RefreshAntigravityTokenAsync(refreshToken!);
            }
            else if (!string.IsNullOrWhiteSpace(token ?? local.Token))
            {
                // No expiry info and no refresh token: try it, auth errors surface a clear message below.
                accessToken = (token ?? local.Token)!;
            }
            else
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? "请在设置中配置 Google AI Studio Key 或检测 Google 本地登录凭证" : "Please configure a Google AI Studio Key in Settings, or detect local Google credentials");
            }

            var (fiveHour, weekly) = await FetchQuotaWithAuthRetryAsync(accessToken, refreshToken);

            if (string.IsNullOrEmpty(detectedAccount))
            {
                detectedAccount = await FetchUserInfoAsync(accessToken);
            }

            return (fiveHour, weekly, detectedAccount ?? (LocalizationManager.Instance.IsChinese ? "Google 账号" : "Google Account"));
        }

        /// <summary>Fetches quota; on auth rejection refreshes the token (when possible) and retries once.</summary>
        private async Task<(TokenWindow? FiveHour, TokenWindow? Weekly)> FetchQuotaWithAuthRetryAsync(string accessToken, string? refreshToken)
        {
            try
            {
                return await FetchAntigravityQuotaCoreAsync(accessToken);
            }
            catch (QuotaAuthException)
            {
                if (string.IsNullOrWhiteSpace(refreshToken))
                {
                    throw new Exception(LocalizationManager.Instance.IsChinese
                        ? "Antigravity 凭证无效或已过期，请重新运行 agy 登录或在设置中更新凭证"
                        : "Antigravity credentials are invalid or expired. Please log in again via agy or update credentials in Settings");
                }
                var refreshed = await RefreshAntigravityTokenAsync(refreshToken!);
                return await FetchAntigravityQuotaCoreAsync(refreshed);
            }
        }

        /// <summary>
        /// Exchanges the stored refresh_token for a fresh access token. Tries every discovered
        /// OAuth client pair until one is accepted (the binaries contain more than one client),
        /// then caches the working pair for the session.
        /// </summary>
        private async Task<string> RefreshAntigravityTokenAsync(string refreshToken)
        {
            if (_lastTokenRefreshFailureUtc is DateTime lastFailure
                && DateTime.UtcNow - lastFailure < TokenRefreshCooldown)
            {
                Log.Info("provider", "gemini token 刷新处于冷却期，跳过本轮");
                throw new Exception(LocalizationManager.Instance.IsChinese
                    ? "Google 凭证刷新处于冷却期，请稍后重试或重新运行 agy 登录"
                    : "Google credential refresh is cooling down; retry later or log in again via agy");
            }

            var candidates = GetAntigravityClientCandidates();
            string? lastDetail = null;

            // 整个候选循环的硬预算：任何一个候选慢下来都不能让整轮刷新失控
            var budget = System.Diagnostics.Stopwatch.StartNew();

            // ToList 物化成快照：循环体内成功时会 Remove/Insert 修改 _antigravityClientCandidates
            // （candidates 就是它的同一个引用），而 Take 是延迟求值、包装原 List 的迭代器。
            // 当前靠"改完立即 return"侥幸不触发迭代器校验，快照能彻底消除这个隐患。
            foreach (var client in candidates.Take(TokenClientCandidateLimit).ToList())
            {
                if (budget.Elapsed > TokenRefreshBudget)
                {
                    Log.Error("provider", $"gemini token 刷新超出 {TokenRefreshBudget.TotalSeconds:F0}s 预算，放弃剩余候选");
                    break;
                }

                using var resp = await HttpClient.PostAsync("https://oauth2.googleapis.com/token",
                    new FormUrlEncodedContent(new[]
                    {
                        new System.Collections.Generic.KeyValuePair<string, string>("client_id", client.Id),
                        new System.Collections.Generic.KeyValuePair<string, string>("client_secret", client.Secret),
                        new System.Collections.Generic.KeyValuePair<string, string>("grant_type", "refresh_token"),
                        new System.Collections.Generic.KeyValuePair<string, string>("refresh_token", refreshToken)
                    }));

                var body = await resp.Content.ReadAsStringAsync();
                if (!resp.IsSuccessStatusCode)
                {
                    lastDetail = $"{(int)resp.StatusCode}";
                    continue;
                }

                using var doc = JsonDocument.Parse(body);
                if (!doc.RootElement.TryGetProperty("access_token", out var at) || at.GetString() is not { Length: > 0 })
                {
                    lastDetail = LocalizationManager.Instance.IsChinese ? "响应缺少 access_token" : "missing access_token";
                    continue;
                }

                // Cache the working pair first so later refreshes skip the trial-and-error.
                _antigravityClientCandidates?.Remove(client);
                _antigravityClientCandidates?.Insert(0, client);

                _cachedAccessToken = at.GetString();
                var expiresIn = 3600;
                if (doc.RootElement.TryGetProperty("expires_in", out var ei) && ei.ValueKind == JsonValueKind.Number && ei.TryGetInt32(out var secs))
                {
                    expiresIn = secs;
                }
                _cachedAccessTokenExpiryUtc = DateTime.UtcNow.AddSeconds(Math.Max(60, expiresIn - 120));
                _lastTokenRefreshFailureUtc = null;
                return _cachedAccessToken!;
            }

            _lastTokenRefreshFailureUtc = DateTime.UtcNow;
            Log.Error("provider", "gemini token 刷新失败：所有候选都没能换到 access token");

            var hint = LocalizationManager.Instance.IsChinese
                ? $"Google 凭证刷新失败{(_antigravityClientCandidates is { Count: 0 } ? "（未在本机找到 Antigravity/agy 安装，可设置环境变量 ANTIGRAVITY_CLIENT_ID / ANTIGRAVITY_CLIENT_SECRET）" : $"（HTTP {lastDetail}）")}，请重新运行 agy 登录"
                : $"Failed to refresh Google credentials{(_antigravityClientCandidates is { Count: 0 } ? " (no local Antigravity/agy installation found; set ANTIGRAVITY_CLIENT_ID / ANTIGRAVITY_CLIENT_SECRET)" : $" (HTTP {lastDetail})")}. Please log in again via agy";
            throw new Exception(hint);
        }

        /// <summary>
        /// Fetches the real Antigravity quota (same source as the IDE's usage panel) and maps the
        /// "Gemini Models" group's weekly / 5-hour buckets to TokenWindows.
        /// Throws QuotaAuthException on 401/403 so the caller can refresh and retry.
        /// </summary>
        private async Task<(TokenWindow? FiveHour, TokenWindow? Weekly)> FetchAntigravityQuotaCoreAsync(string accessToken)
        {
            TokenWindow? fiveHour = null;
            TokenWindow? weekly = null;

            var summaryBody = await PostCloudCodeAsync(accessToken, "/v1internal:retrieveUserQuotaSummary");

            using (var doc = JsonDocument.Parse(summaryBody))
            {
                if (doc.RootElement.TryGetProperty("groups", out var groups) && groups.ValueKind == JsonValueKind.Array)
                {
                    foreach (var group in groups.EnumerateArray())
                    {
                        if (!group.TryGetProperty("displayName", out var gName) || gName.ValueKind != JsonValueKind.String)
                            continue;
                        var name = gName.GetString() ?? "";
                        // "Gemini Models" group (skip "Claude and GPT models")
                        if (name.Contains("gemini", StringComparison.OrdinalIgnoreCase))
                        {
                            if (group.TryGetProperty("buckets", out var buckets) && buckets.ValueKind == JsonValueKind.Array)
                            {
                                foreach (var bucket in buckets.EnumerateArray())
                                {
                                    var window = ParseQuotaBucket(bucket, out var isWeekly);
                                    if (window == null)
                                        continue;
                                    if (isWeekly)
                                        weekly = window;
                                    else
                                        fiveHour = window;
                                }
                            }
                            break;
                        }
                    }
                }
            }

            if (fiveHour == null && weekly == null)
            {
                // Older/alternative response shape: fall back to per-model quota and aggregate the gemini family.
                (fiveHour, weekly) = await FetchAntigravityModelsFallbackAsync(accessToken);
            }

            if (fiveHour == null && weekly == null)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese
                    ? "Antigravity 额度响应中未找到 Gemini 配额数据"
                    : "No Gemini quota data found in the Antigravity response");
            }

            return (fiveHour, weekly);
        }

        private async Task<string> PostCloudCodeAsync(string accessToken, string path)
        {
            Exception? lastEx = null;
            foreach (var baseUrl in CloudCodeQuotaBases)
            {
                try
                {
                    using var req = new HttpRequestMessage(HttpMethod.Post, baseUrl + path);
                    req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {accessToken}");
                    req.Headers.TryAddWithoutValidation("User-Agent", "antigravity");
                    req.Content = new StringContent("{}", System.Text.Encoding.UTF8, "application/json");

                    var resp = await HttpClient.SendAsync(req);
                    var body = await resp.Content.ReadAsStringAsync();

                    if ((int)resp.StatusCode == 401 || (int)resp.StatusCode == 403)
                    {
                        throw new QuotaAuthException();
                    }
                    if (!resp.IsSuccessStatusCode)
                    {
                        var trimmed = body.Length > 300 ? body[..300] : body;
                        lastEx = new Exception(LocalizationManager.Instance.IsChinese
                            ? $"Antigravity 额度接口响应异常 ({(int)resp.StatusCode}): {trimmed}"
                            : $"Antigravity quota API error ({(int)resp.StatusCode}): {trimmed}");
                        continue;
                    }
                    return body;
                }
                catch (QuotaAuthException)
                {
                    throw;
                }
                catch (Exception ex)
                {
                    lastEx = ex;
                }
            }

            if (lastEx != null) throw lastEx;
            throw new Exception("Antigravity request failed");
        }

        /// <summary>Maps one quota bucket ({window/bucketId, remainingFraction, resetTime}) to a TokenWindow.</summary>
        private static TokenWindow? ParseQuotaBucket(JsonElement bucket, out bool isWeekly)
        {
            isWeekly = false;

            string kind = "";
            if (bucket.TryGetProperty("window", out var w) && w.ValueKind == JsonValueKind.String)
                kind = w.GetString() ?? "";
            if (string.IsNullOrEmpty(kind) && bucket.TryGetProperty("bucketId", out var bid) && bid.ValueKind == JsonValueKind.String)
                kind = bid.GetString() ?? "";
            if (string.IsNullOrEmpty(kind) && bucket.TryGetProperty("displayName", out var dn) && dn.ValueKind == JsonValueKind.String)
                kind = dn.GetString() ?? "";
            kind = kind.ToLowerInvariant();

            isWeekly = kind.Contains("week");
            var isFiveHour = !isWeekly && (kind.Contains("5h") || kind.Contains("five") || kind.Contains("hour"));
            if (!isWeekly && !isFiveHour)
                return null;

            double? remainingFraction = null;
            if (bucket.TryGetProperty("remainingFraction", out var rf) && rf.ValueKind == JsonValueKind.Number)
            {
                remainingFraction = rf.GetDouble();
            }
            else if (bucket.TryGetProperty("remaining", out var rem) && rem.ValueKind == JsonValueKind.Object &&
                     rem.TryGetProperty("remainingFraction", out var rf2) && rf2.ValueKind == JsonValueKind.Number)
            {
                remainingFraction = rf2.GetDouble();
            }
            if (remainingFraction == null)
                return null;

            DateTime? reset = null;
            if (bucket.TryGetProperty("resetTime", out var rt))
            {
                if (rt.ValueKind == JsonValueKind.String && DateTime.TryParse(rt.GetString(),
                        System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var parsed))
                {
                    reset = parsed;
                }
                else if (rt.ValueKind == JsonValueKind.Number && rt.TryGetInt64(out var epochSeconds))
                {
                    reset = DateTimeOffset.FromUnixTimeSeconds(epochSeconds).LocalDateTime;
                }
            }

            var span = isWeekly ? TimeSpan.FromDays(7) : TimeSpan.FromHours(5);
            // While idle the API keeps the last reset anchor; roll forward so the countdown stays positive.
            var end = reset ?? DateTime.Now.Add(span);
            while (end <= DateTime.Now)
                end = end.Add(span);
            var start = end.Subtract(span);

            var usedPct = Math.Clamp((1.0 - remainingFraction.Value) * 100.0, 0.0, 100.0);
            return new TokenWindow
            {
                Title = isWeekly ? "每周额度" : "5小时额度",
                UsedPercentage = usedPct,
                StartTime = start,
                EndTime = end,
                Unit = "%",
                IsIdle = remainingFraction.Value >= 0.999
            };
        }

        /// <summary>Fallback via fetchAvailableModels: aggregates the most-constrained gemini model into a 5h window.</summary>
        private async Task<(TokenWindow? FiveHour, TokenWindow? Weekly)> FetchAntigravityModelsFallbackAsync(string accessToken)
        {
            var modelsBody = await PostCloudCodeAsync(accessToken, "/v1internal:fetchAvailableModels");

            double? minRemaining = null;
            DateTime? reset = null;
            using var doc = JsonDocument.Parse(modelsBody);
            if (doc.RootElement.TryGetProperty("models", out var models) && models.ValueKind == JsonValueKind.Object)
            {
                foreach (var prop in models.EnumerateObject())
                {
                    if (!prop.Name.StartsWith("gemini", StringComparison.OrdinalIgnoreCase))
                        continue;
                    if (!prop.Value.TryGetProperty("quotaInfo", out var qi) || qi.ValueKind != JsonValueKind.Object)
                        continue;
                    if (qi.TryGetProperty("remainingFraction", out var rf) && rf.ValueKind == JsonValueKind.Number)
                    {
                        var fraction = rf.GetDouble();
                        if (minRemaining == null || fraction < minRemaining)
                        {
                            minRemaining = fraction;
                            if (qi.TryGetProperty("resetTime", out var rt) && rt.ValueKind == JsonValueKind.String &&
                                DateTime.TryParse(rt.GetString(), System.Globalization.CultureInfo.InvariantCulture,
                                    System.Globalization.DateTimeStyles.None, out var parsed))
                            {
                                reset = parsed;
                            }
                        }
                    }
                }
            }

            if (minRemaining == null)
                return (null, null);

            var span = TimeSpan.FromHours(5);
            var end = reset ?? DateTime.Now.Add(span);
            while (end <= DateTime.Now)
                end = end.Add(span);

            var window = new TokenWindow
            {
                Title = "5小时额度",
                UsedPercentage = Math.Clamp((1.0 - minRemaining.Value) * 100.0, 0.0, 100.0),
                StartTime = end.Subtract(span),
                EndTime = end,
                Unit = "%",
                IsIdle = minRemaining.Value >= 0.999
            };
            return (window, null);
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
