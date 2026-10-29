using TokenBar.I18n;
using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using TokenBar.Models;

namespace TokenBar.Services
{
    public class GeminiService
    {
        public static GeminiService Instance { get; } = new GeminiService();

        private GeminiService() { }

        // Antigravity (Google Code Assist) quota backend endpoints.
        // 两个端点对 retrieveUserQuotaSummary 的分组返回集不同（2026-10 实测）：
        // cloudcode-pa 返回 "Gemini Models" + "Claude and GPT models" 两组，
        // daily-cloudcode-pa 只返回 "Claude and GPT models" 一组——Gemini 组只在
        // cloudcode-pa 上，所以它排前；daily 保留兜底（fetchAvailableModels 两边都通）。
        private static readonly string[] CloudCodeQuotaBases = new[]
        {
            "https://cloudcode-pa.googleapis.com",
            "https://daily-cloudcode-pa.googleapis.com"
        };

        // 配额后端按 User-Agent 中的客户端版本选择返回分组（2026-10 本机同凭证对照实测）：
        // 裸 "antigravity" 只回 Claude/GPT 组，带官方 2.25.0 协议版本才回 Gemini 的
        // weekly/5h 两组桶；裸 UA 会静默退到只产 5h 窗口的模型回退——「没有周额度」的根因。
        // 与 mac 端 GeminiService.cloudCodeUserAgent 同源；这是接口兼容版本，非应用版本。
        private const string CloudCodeUserAgent = "antigravity/2.25.0";

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
            lock (_staticStateLock)
            {
                if (_antigravityClientCandidates != null)
                    return _antigravityClientCandidates;
            }

            var list = new List<(string Id, string Secret)>();
            var envId = Environment.GetEnvironmentVariable("ANTIGRAVITY_CLIENT_ID");
            var envSecret = Environment.GetEnvironmentVariable("ANTIGRAVITY_CLIENT_SECRET");
            if (!string.IsNullOrWhiteSpace(envId) && !string.IsNullOrWhiteSpace(envSecret))
            {
                list.Add((envId!.Trim(), envSecret!.Trim()));
                lock (_staticStateLock)
                {
                    return _antigravityClientCandidates ??= list;
                }
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
                    // 与 TokenClientCandidateLimit 对齐：截断会像 Take(3) 一样把真配对挡在门外
                    if (list.Count >= TokenClientCandidateLimit)
                        break;
                }
                if (list.Count >= TokenClientCandidateLimit)
                    break;
            }

            lock (_staticStateLock)
            {
                // 并发下先到者 wins：另一个线程已填充就直接复用它的结果
                return _antigravityClientCandidates ??= list;
            }
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
            catch (Exception ex)
            {
                Log.Warn("provider", $"扫描 Antigravity 二进制失败: {ex.Message}");
            }
        }

        // Refreshed access tokens are short-lived (~1h); cache in memory instead of refreshing on every poll.
        private static string? _cachedAccessToken;
        private static DateTime _cachedAccessTokenExpiryUtc = DateTime.MinValue;

        // 上一次令牌刷新整体失败的时刻。候选逐个试是昂贵操作，凭证真失效时每轮都重试纯属浪费。
        private static DateTime? _lastTokenRefreshFailureUtc;
        // 以上字段与 _antigravityClientCandidates 都是 static 可变状态：设置页「测试连接」
        // 会与定时轮次并发进入，必须持锁成对读写，否则出现「旧 token 配新 expiry」错配。
        private static readonly object _staticStateLock = new();
        // token 刷新整体串行化（候选循环含 HTTP 请求，用 SemaphoreSlim 而非 lock），防并发刷新互相踩踏。
        private static readonly SemaphoreSlim _tokenRefreshSemaphore = new(1, 1);
        private static readonly TimeSpan TokenRefreshCooldown = TimeSpan.FromSeconds(120);
        // 候选循环的总预算。共享 HttpClient 的 Timeout 是 30s，多个候选串行最坏会到分钟级，
        // 远超刷新间隔，会把 RefreshManager 的闸门长时间占住。
        private static readonly TimeSpan TokenRefreshBudget = TimeSpan.FromSeconds(20);
        // agy 二进制里嵌着多个 OAuth client（2026-10 本机实测 3 个 ID × 3 个 secret），
        // 交叉配对共 9 个组合；真正的 Antigravity 登录客户端可能排在第 4 位之后，
        // 只试前 3 个会永远刷不出 token，必须覆盖全量（每个失败响应都很快，20s 预算兜底）。
        private const int TokenClientCandidateLimit = 9;

        // ---------- 自有 Google 登录（loopback OAuth）----------
        // 与 mac 端 geminiOwnRefreshToken 钥匙串条目同义：TokenBar 自己登录换来的
        // refresh_token 存在自己的凭据管理器条目里，Antigravity 重登轮换 token 影响不到它。
        private static readonly SecretKey OwnRefreshTokenKey = SecretKey.GeminiOwnRefreshToken;
        private static readonly TimeSpan LoginCallbackBudget = TimeSpan.FromMinutes(5);
        private static readonly Random LoginPortRandom = new();
        private readonly object _ownStateLock = new();
        private string? _ownRefreshTokenCache;
        private bool _ownRefreshTokenLoaded;
        /// <summary>登录成功时记下的账号（来自 id_token / userinfo），自有路径显示用</summary>
        private string? _ownAccountHint;
        /// <summary>一次登录流程中「授权 URL 用的 client」必须和「换 code 的 client」完全一致，否则 Google 拒收 code。</summary>
        private (string Id, string Secret)? _pendingLoginClient;

        private sealed class QuotaAuthException : Exception
        {
            public QuotaAuthException() : base("quota auth rejected") { }
        }

        /// <summary>
        /// Gemini 凭证链的失败阶段，每个阶段对应一个确实有用的恢复动作。
        /// 与 mac 端 CredentialStage 同构（去掉 keychainACL：Windows 凭据管理器没有 ACL 授权框这回事）。
        /// </summary>
        internal enum GeminiCredentialStage
        {
            /// <summary>哪里都没有凭证（未登录、未安装 Antigravity）</summary>
            NoCredentials,
            /// <summary>refresh_token 存在但 Google 判 invalid_grant——已被 Antigravity 重新登录轮换</summary>
            RefreshTokenDead,
            /// <summary>刷新刚失败过、处于冷却期（瞬态，下轮自动重试）</summary>
            RefreshTokenCooldown,
            /// <summary>token 端点网络不可达</summary>
            TokenRefreshUnreachable,
            /// <summary>扫描出的 client id/secret 全部配不上（Antigravity 组件更新过）</summary>
            ClientMismatch,
            /// <summary>换到了 access token，但配额接口 401/403</summary>
            QuotaRejected,
            /// <summary>TokenBar 自己的 Google 登录凭证被判无效（被重新授权吊销）</summary>
            OwnLoginRevoked
        }

        internal sealed class GeminiCredentialException : Exception
        {
            public GeminiCredentialStage Stage { get; }

            public GeminiCredentialException(GeminiCredentialStage stage)
                : base(CredentialFailureMessage(stage))
            {
                Stage = stage;
            }

            internal static string CredentialFailureMessage(GeminiCredentialStage stage)
            {
                var zh = LocalizationManager.Instance.IsChinese;
                return stage switch
                {
                    GeminiCredentialStage.NoCredentials => zh
                        ? "未找到 Gemini 凭证：请在 设置 → Gemini 用 Google 账号登录，或先在 Antigravity 中登录（也可设置 ANTIGRAVITY_CLIENT_ID / ANTIGRAVITY_CLIENT_SECRET 环境变量）"
                        : "No Gemini credentials found. Sign in with your Google account in Settings → Gemini, or log in via Antigravity first (you can also set ANTIGRAVITY_CLIENT_ID / ANTIGRAVITY_CLIENT_SECRET)"
                    ,
                    GeminiCredentialStage.RefreshTokenDead => zh
                        ? "Gemini 凭证已失效（Antigravity 重新登录会轮换 refresh_token）。推荐在 设置 → Gemini 直接用 Google 账号登录，一次登录不再依赖本地文件"
                        : "Gemini credentials are no longer valid (Antigravity re-logins rotate the refresh_token). Sign in with your Google account in Settings → Gemini for a login that no longer depends on local files"
                    ,
                    GeminiCredentialStage.RefreshTokenCooldown => zh
                        ? "Gemini 令牌刷新冷却中，稍后自动重试"
                        : "Gemini token refresh is cooling down; it will retry automatically"
                    ,
                    GeminiCredentialStage.TokenRefreshUnreachable => zh
                        ? "无法连接 Google 账号服务，请检查网络后稍候重试"
                        : "Cannot reach Google's account service; check the network and retry later"
                    ,
                    GeminiCredentialStage.ClientMismatch => zh
                        ? "本地 OAuth 客户端配对失效（Antigravity 组件更新过）：请重启 TokenBar 重新扫描，或在 设置 → Gemini 用 Google 账号登录"
                        : "Local OAuth client pairing is broken (Antigravity components updated). Restart TokenBar to rescan, or sign in with your Google account in Settings → Gemini"
                    ,
                    GeminiCredentialStage.QuotaRejected => zh
                        ? "额度接口拒绝了访问令牌（权限不足或接口协议变更），请尝试重新登录"
                        : "The quota API rejected the access token (insufficient scopes or a protocol change). Try signing in again"
                    ,
                    GeminiCredentialStage.OwnLoginRevoked => zh
                        ? "TokenBar 的 Google 登录已失效（可能被重新授权吊销），请到 设置 → Gemini 重新登录"
                        : "TokenBar's Google sign-in was revoked (possibly by a re-consent). Please sign in again in Settings → Gemini"
                    ,
                    _ => zh ? "Gemini 凭证获取失败" : "Failed to obtain Gemini credentials"
                };
            }
        }

        /// <summary>
        /// 一次 refresh_token 刷新的结构化结果。旧的 string 返回值时代调用方只知道「没成」，
        /// 分不清「凭证死了（重试无用）」「网络不通（重试有用）」「冷却中（本轮跳过）」。
        /// </summary>
        internal enum TokenRefreshOutcomeKind
        {
            Success,
            /// <summary>Google 判 invalid_grant：refresh_token 已被轮换/吊销，重试无用</summary>
            InvalidGrant,
            /// <summary>全部候选的 id/secret 配不上（Antigravity 组件更新过）</summary>
            ClientMismatch,
            /// <summary>网络/传输层失败，或响应形状不认识</summary>
            Unreachable,
            /// <summary>上一轮刷新刚失败过，冷却期内跳过本轮</summary>
            Cooldown,
            /// <summary>本机找不到任何 OAuth client 配对</summary>
            NoCandidates
        }

        private readonly struct TokenRefreshResult
        {
            public TokenRefreshOutcomeKind Kind { get; }
            public string? AccessToken { get; }
            public TokenRefreshResult(TokenRefreshOutcomeKind kind, string? accessToken = null)
            {
                Kind = kind;
                AccessToken = accessToken;
            }
        }

        private static string? ReadCredential(string target)
        {
            try
            {
                // 复用 SecretStore 的 CredRead/CredFree P/Invoke（此前本文件自带一份拷贝）。
                // 语义保持原样：条目不存在 / blob 为空返回 null；异常在此捕获并按原文案记日志。
                return CredentialSecretStore.ReadRawCredentialBlob(target);
            }
            catch (Exception ex)
            {
                Log.Warn("provider", $"读取凭据管理器 {target} 失败: {ex.Message}");
            }
            return null;
        }

        /// <summary>
        /// 读取本地 Gemini 凭证：凭据管理器 `gemini:antigravity` > jetski 文件 > oauth_creds.json。
        /// 三层都没有 refresh_token 时用设置里的快照兜底，避免 Antigravity 卸载/轮换后额度失联。
        /// </summary>
        public (string? Token, string? RefreshToken, string? Account, DateTime? Expiry) ReadLocalGeminiConfig(string? storedRefreshToken = null)
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
                catch (Exception ex)
                {
                    Log.Warn("provider", $"解析 gemini:antigravity 凭据失败: {ex.Message}");
                }
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
                catch (Exception ex)
                {
                    Log.Warn("provider", $"解析 jetski-standalone-oauth-token 失败: {ex.Message}");
                }
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
                catch (Exception ex)
                {
                    Log.Warn("provider", $"解析 oauth_creds.json 失败: {ex.Message}");
                }
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
                catch (Exception ex)
                {
                    Log.Warn("provider", $"解析 google_accounts.json 失败: {ex.Message}");
                }
            }

            if (string.IsNullOrWhiteSpace(refreshToken) && !string.IsNullOrWhiteSpace(storedRefreshToken))
                refreshToken = storedRefreshToken;

            return (token, refreshToken, account, expiry);
        }

        /// <summary>Parses the RFC3339 expiry written by agy/Gemini CLI, e.g. "2026-09-08T01:23:12.8592338+08:00".</summary>
        private static DateTime? ParseTokenExpiry(string? value)
        {
            if (string.IsNullOrWhiteSpace(value))
                return null;
            if (DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
            {
                return parsed.LocalDateTime;
            }
            return null;
        }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchQuotaWithApiKeyAsync(
            string apiKey,
            string endpoint = "https://generativelanguage.googleapis.com",
            CancellationToken ct = default)
        {
            var trimmedKey = apiKey.Trim();
            if (string.IsNullOrEmpty(trimmedKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? "请输入有效的 Google AI Studio API Key" : "Please enter a valid Google AI Studio API Key");
            }

            var cleanBase = ProviderShared.NormalizeEndpoint(endpoint, "https://generativelanguage.googleapis.com");

            var urlString = (cleanBase.EndsWith("/v1beta", StringComparison.OrdinalIgnoreCase) ||
                             cleanBase.EndsWith("/v1", StringComparison.OrdinalIgnoreCase))
                ? $"{cleanBase}/models?pageSize=50"
                : $"{cleanBase}/v1beta/models?pageSize=50";

            using var request = new HttpRequestMessage(HttpMethod.Get, urlString);
            request.Headers.Add("x-goog-api-key", trimmedKey);
            request.Headers.Add("Accept", "application/json");

            using var resp = await Http.Shared.SendAsync(request, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);

            if (!resp.IsSuccessStatusCode)
            {
                string? apiErrorMessage = null;
                try
                {
                    using var doc = JsonDocument.Parse(body);
                    if (doc.RootElement.TryGetProperty("error", out var err) &&
                        err.TryGetProperty("message", out var msg) && msg.ValueKind == JsonValueKind.String)
                    {
                        apiErrorMessage = msg.GetString();
                    }
                }
                catch (JsonException ex)
                {
                    Log.Warn("provider", $"gemini 错误响应不是 JSON: {ex.Message}");
                }
                if (!string.IsNullOrEmpty(apiErrorMessage))
                {
                    throw new Exception(LocalizationManager.Instance.IsChinese ? $"Gemini API 错误: {apiErrorMessage}" : $"Gemini API error: {apiErrorMessage}");
                }
                var snippet = body.Length > 300 ? body[..300] : body;
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"Gemini API 响应异常 ({(int)resp.StatusCode}): {snippet}" : $"Gemini API response error ({(int)resp.StatusCode}): {snippet}");
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
            catch (JsonException ex)
            {
                Log.Warn("provider", $"gemini /models 响应不是 JSON: {ex.Message}");
            }

            // RPM 窗口：requests 头缺失时回退 rpm 头（候选顺序与原 GetHeader ?? 链一致），固定 1 分钟窗口
            TokenWindow? rpmWindow = resp.BuildRateLimitWindow(
                RateLimitHeaderSet.OpenAIFixedWindow("requests", "rpm"), WindowTitle.RpmRate, "req/min");

            // AI Studio 的 API Key 没有任何可查询的周期额度：
            // 没有速率头时只显示「API 连接正常」状态窗口；第二行用「可用模型 (N)」状态窗口，
            // 不再用「当前小时/5」拼出假的 5 小时起止，也不再编造 usedPercentage=0 的每周额度。
            var fiveHour = rpmWindow ?? TokenWindow.Status(WindowTitle.Connected);
            TokenWindow? weekly = modelCount > 0 ? TokenWindow.Status(WindowTitle.AvailableModels(modelCount)) : null;

            string maskedKey = trimmedKey.Length > 8
                ? $"{trimmedKey[..6]}...{trimmedKey[^4..]}"
                : "AI Studio Key";

            var accountDisplay = $"AI Studio ({maskedKey})";
            return (fiveHour, weekly, accountDisplay);
        }

        private static (int Port, string CsrfToken)? _cachedLocalServer;

        private static readonly HttpClientHandler _insecureHandler = new()
        {
            ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
        };
        private static readonly HttpClient _localLanguageServerClient = new(_insecureHandler)
        {
            Timeout = TimeSpan.FromSeconds(2)
        };

        /// <summary>
        /// 探测本地运行的 Antigravity LanguageServer（Connect-RPC 端口）。
        /// 当用户运行 Antigravity IDE 时，本地 language_server 进程直接提供包含「Gemini 4 Argon」在内的全量实时额度。
        /// </summary>
        private async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, TokenWindow? ScopedWeekly)> FetchLocalAntigravityQuotaAsync(CancellationToken ct = default)
        {
            try
            {
                // 1. 若有缓存的探针，先尝试一次快速请求
                if (_cachedLocalServer is { } cached)
                {
                    var cachedResult = await TryQueryLocalLanguageServerAsync(cached.Port, cached.CsrfToken, ct);
                    if (cachedResult != null) return cachedResult.Value;
                    _cachedLocalServer = null;
                }

                // 2. 查找是否有 language_server 进程
                var procs = System.Diagnostics.Process.GetProcessesByName("language_server");
                if (procs.Length == 0) return (null, null, null);

                // 3. 扫描各 language_server 进程的命令行以获取 csrf_token 和监听端口
                foreach (var proc in procs)
                {
                    try
                    {
                        var pid = proc.Id;
                        var (csrfToken, ports) = GetWindowsProcessInfo(pid);
                        if (string.IsNullOrEmpty(csrfToken) || ports.Count == 0) continue;

                        foreach (var port in ports)
                        {
                            var result = await TryQueryLocalLanguageServerAsync(port, csrfToken, ct);
                            if (result != null)
                            {
                                _cachedLocalServer = (port, csrfToken);
                                return result.Value;
                            }
                        }
                    }
                    catch
                    {
                        // 忽略单个进程探测失败
                    }
                }
            }
            catch (Exception ex)
            {
                Log.Debug("provider", $"本地 Antigravity LanguageServer 探测失败: {ex.Message}");
            }
            return (null, null, null);
        }

        private static async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, TokenWindow? ScopedWeekly)?> TryQueryLocalLanguageServerAsync(int port, string csrfToken, CancellationToken ct)
        {
            try
            {
                var url = $"https://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary";
                using var req = new HttpRequestMessage(HttpMethod.Post, url);
                req.Headers.Add("x-codeium-csrf-token", csrfToken);
                req.Content = new StringContent("{\"force_refresh\": true}", System.Text.Encoding.UTF8, "application/json");

                using var resp = await _localLanguageServerClient.SendAsync(req, ct);
                if (!resp.IsSuccessStatusCode) return null;
                var body = await resp.Content.ReadAsStringAsync(ct);
                var windows = ParseGeminiGroupWindows(body);
                if (windows.FiveHour != null || windows.Weekly != null || windows.ScopedWeekly != null)
                {
                    return windows;
                }
            }
            catch
            {
                // 连接失败或超时
            }
            return null;
        }

        private static (string? CsrfToken, List<int> Ports) GetWindowsProcessInfo(int pid)
        {
            string? csrfToken = null;
            var ports = new List<int>();

            // 1. 获取命令行提取 csrf_token
            try
            {
                using var p = new System.Diagnostics.Process();
                p.StartInfo.FileName = "powershell";
                p.StartInfo.Arguments = $"-NoProfile -NonInteractive -Command \"(Get-CimInstance Win32_Process -Filter 'ProcessId = {pid}').CommandLine\"";
                p.StartInfo.UseShellExecute = false;
                p.StartInfo.RedirectStandardOutput = true;
                p.StartInfo.CreateNoWindow = true;
                p.Start();
                var cmdLine = p.StandardOutput.ReadToEnd();
                p.WaitForExit(1000);

                var match = System.Text.RegularExpressions.Regex.Match(cmdLine, @"--csrf_token[=\s]+([a-f0-9-]+)");
                if (match.Success)
                {
                    csrfToken = match.Groups[1].Value.Trim();
                }
            }
            catch { }

            if (string.IsNullOrEmpty(csrfToken)) return (null, ports);

            // 2. 获取该 PID 监听的 TCP 端口
            try
            {
                using var p = new System.Diagnostics.Process();
                p.StartInfo.FileName = "netstat";
                p.StartInfo.Arguments = "-ano -p tcp";
                p.StartInfo.UseShellExecute = false;
                p.StartInfo.RedirectStandardOutput = true;
                p.StartInfo.CreateNoWindow = true;
                p.Start();
                var output = p.StandardOutput.ReadToEnd();
                p.WaitForExit(1500);

                foreach (var line in output.Split('\n'))
                {
                    if (line.Contains("LISTENING") && line.TrimEnd().EndsWith($" {pid}"))
                    {
                        var parts = System.Text.RegularExpressions.Regex.Split(line.Trim(), @"\s+");
                        if (parts.Length >= 2)
                        {
                            var addr = parts[1];
                            var lastColon = addr.LastIndexOf(':');
                            if (lastColon >= 0 && int.TryParse(addr[(lastColon + 1)..], out var port) && !ports.Contains(port))
                            {
                                ports.Add(port);
                            }
                        }
                    }
                }
            }
            catch { }

            return (csrfToken, ports);
        }

        /// <summary>
        /// 凭证优先级：**TokenBar 自己的 Google 登录**（`geminiOwnRefreshToken`）> 凭据管理器
        /// `gemini:antigravity` 条目 > `~/.gemini` 文件 > 设置里的快照 refresh_token。
        /// 自有登录走通时完全不碰外来凭证——Antigravity 重登轮换 token 与它无关。
        /// 返回值带上本轮用到的 refresh_token，调用方据此落快照；自有路径恒为 null
        /// （自有 token 已在自己的凭据条目里，交出去只会覆盖掉 Antigravity 的快照）。
        /// </summary>
        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, TokenWindow? ScopedWeekly, string? Account, string? RefreshToken)> FetchQuotaAsync(
            string? token, string? storedRefreshToken = null, CancellationToken ct = default)
        {
            // 优先尝试本地正在运行的 Antigravity LanguageServer：
            // 当用户打开 Antigravity IDE 时，本地服务直接持有最全且权威的实时额度（含 Gemini 4 Argon），
            // 且无需消耗网络与令牌刷新，零延迟。
            var localQuota = await FetchLocalAntigravityQuotaAsync(ct);
            if (localQuota.FiveHour != null || localQuota.Weekly != null || localQuota.ScopedWeekly != null)
            {
                var localCfg = ReadLocalGeminiConfig(storedRefreshToken);
                var acc = localCfg.Account ?? (LocalizationManager.Instance.IsChinese ? "Antigravity 本地" : "Antigravity Local");
                return (localQuota.FiveHour, localQuota.Weekly, localQuota.ScopedWeekly, acc, localCfg.RefreshToken ?? storedRefreshToken);
            }

            var own = await LoadOwnRefreshTokenAsync();
            if (!string.IsNullOrEmpty(own))
            {
                try
                {
                    return await FetchQuotaWithOwnCredentialAsync(own!, ct);
                }
                catch (GeminiCredentialException ex) when (ex.Stage == GeminiCredentialStage.OwnLoginRevoked)
                {
                    ClearOwnRefreshToken();
                    // 落到下面的本地链路；若本地链路也失败，最终错误按它的阶段报
                }
            }

            var local = ReadLocalGeminiConfig(storedRefreshToken);
            var refreshToken = local.RefreshToken;
            var detectedAccount = local.Account;

            // Resolve an access token: cached refresh result > valid local token > explicit setting (if valid) > refreshed.
            string accessToken;
            string? cached;
            lock (_staticStateLock)
            {
                // token 与 expiry 必须成对读，否则并发刷新时可能拿到「旧 token 配新 expiry」
                cached = (_cachedAccessToken != null && DateTime.UtcNow < _cachedAccessTokenExpiryUtc) ? _cachedAccessToken : null;
            }
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
                accessToken = await RequireRefreshedTokenAsync(refreshToken!, GeminiCredentialStage.RefreshTokenDead, ct);
            }
            else if (!string.IsNullOrWhiteSpace(token ?? local.Token))
            {
                // No expiry info and no refresh token: try it, auth errors surface a clear message below.
                accessToken = (token ?? local.Token)!;
            }
            else
            {
                throw new GeminiCredentialException(GeminiCredentialStage.NoCredentials);
            }

            var (fiveHour, weekly, scopedWeekly) = await FetchQuotaWithAuthRetryAsync(accessToken, refreshToken, ct);

            if (string.IsNullOrEmpty(detectedAccount))
            {
                detectedAccount = await FetchUserInfoAsync(accessToken, ct);
            }

            return (fiveHour, weekly, scopedWeekly, detectedAccount ?? (LocalizationManager.Instance.IsChinese ? "Google 账号" : "Google Account"), refreshToken);
        }

        /// <summary>
        /// 自有登录凭证的完整路径：刷新 → 配额 → 账号。invalid_grant 抛 OwnLoginRevoked，
        /// 由 FetchQuotaAsync 捕获后清掉自有凭证并当场落到旧链路。
        /// </summary>
        private async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, TokenWindow? ScopedWeekly, string? Account, string? RefreshToken)> FetchQuotaWithOwnCredentialAsync(string refreshToken, CancellationToken ct)
        {
            string accessToken;
            string? cached;
            lock (_staticStateLock)
            {
                cached = (_cachedAccessToken != null && DateTime.UtcNow < _cachedAccessTokenExpiryUtc) ? _cachedAccessToken : null;
            }
            accessToken = cached ?? await RequireRefreshedTokenAsync(refreshToken, GeminiCredentialStage.OwnLoginRevoked, ct);

            try
            {
                var (fiveHour, weekly, scopedWeekly) = await FetchAntigravityQuotaCoreAsync(accessToken, ct);
                return (fiveHour, weekly, scopedWeekly, await OwnAccountDisplayAsync(accessToken, ct), null);
            }
            catch (QuotaAuthException)
            {
                // 缓存的 token 刚好跨过过期线：强制刷新一次再试；仍被拒才判 quotaRejected。
                lock (_staticStateLock)
                {
                    _cachedAccessToken = null;
                    _cachedAccessTokenExpiryUtc = DateTime.MinValue;
                }
                var refreshed = await RequireRefreshedTokenAsync(refreshToken, GeminiCredentialStage.OwnLoginRevoked, ct);
                try
                {
                    var (fiveHour, weekly, scopedWeekly) = await FetchAntigravityQuotaCoreAsync(refreshed, ct);
                    return (fiveHour, weekly, scopedWeekly, await OwnAccountDisplayAsync(refreshed, ct), null);
                }
                catch (QuotaAuthException)
                {
                    throw new GeminiCredentialException(GeminiCredentialStage.QuotaRejected);
                }
            }
        }

        private async Task<string> OwnAccountDisplayAsync(string accessToken, CancellationToken ct)
        {
            if (string.IsNullOrEmpty(_ownAccountHint))
            {
                var fetched = await FetchUserInfoAsync(accessToken, ct);
                if (!string.IsNullOrEmpty(fetched)) _ownAccountHint = fetched;
            }
            return !string.IsNullOrEmpty(_ownAccountHint)
                ? _ownAccountHint!
                : (LocalizationManager.Instance.IsChinese ? "Google 账号" : "Google Account");
        }

        /// <summary>Fetches quota; on auth rejection refreshes the token (when possible) and retries once.</summary>
        private async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, TokenWindow? ScopedWeekly)> FetchQuotaWithAuthRetryAsync(string accessToken, string? refreshToken, CancellationToken ct)
        {
            try
            {
                return await FetchAntigravityQuotaCoreAsync(accessToken, ct);
            }
            catch (QuotaAuthException)
            {
                if (string.IsNullOrWhiteSpace(refreshToken))
                    throw new GeminiCredentialException(GeminiCredentialStage.QuotaRejected);
                var refreshed = await RequireRefreshedTokenAsync(refreshToken!, GeminiCredentialStage.RefreshTokenDead, ct);
                try
                {
                    return await FetchAntigravityQuotaCoreAsync(refreshed, ct);
                }
                catch (QuotaAuthException)
                {
                    throw new GeminiCredentialException(GeminiCredentialStage.QuotaRejected);
                }
            }
        }

        /// <summary>
        /// Exchanges the stored refresh_token for a fresh access token. Tries every discovered
        /// OAuth client pair until one is accepted (the binaries contain more than one client),
        /// then caches the working pair for the session.
        /// </summary>
        private async Task<TokenRefreshResult> RefreshAntigravityTokenResultAsync(string refreshToken, CancellationToken ct)
        {
            // 设置页「测试连接」与定时轮次可能并发进入（前者绕过刷新闸门），
            // 串行化整个刷新流程，防止两个线程同时跑候选循环、互相踩踏静态缓存。
            await _tokenRefreshSemaphore.WaitAsync(ct).ConfigureAwait(false);
            try
            {
                lock (_staticStateLock)
                {
                    // 双重检查：等锁期间另一个线程可能刚刚刷新成功
                    if (_cachedAccessToken != null && DateTime.UtcNow < _cachedAccessTokenExpiryUtc)
                        return new TokenRefreshResult(TokenRefreshOutcomeKind.Success, _cachedAccessToken);

                    if (_lastTokenRefreshFailureUtc is DateTime lastFailure
                        && DateTime.UtcNow - lastFailure < TokenRefreshCooldown)
                    {
                        Log.Info("provider", "gemini token 刷新处于冷却期，跳过本轮");
                        return new TokenRefreshResult(TokenRefreshOutcomeKind.Cooldown);
                    }
                }

                var candidates = GetAntigravityClientCandidates();
                // ToList 物化成快照：循环体内成功时会 Remove/Insert 修改 _antigravityClientCandidates
                // （candidates 就是它的同一个引用），而 Take 是延迟求值、包装原 List 的迭代器。
                var trialList = candidates.Take(TokenClientCandidateLimit).ToList();
                if (trialList.Count == 0)
                    return new TokenRefreshResult(TokenRefreshOutcomeKind.NoCandidates);

                var sawInvalidGrant = false;
                var sawClientRejection = false;
                var sawTransportError = false;
                string? lastDetail = null;

                // 整个候选循环的硬预算：任何一个候选慢下来都不能让整轮刷新失控
                var budget = System.Diagnostics.Stopwatch.StartNew();

                foreach (var client in trialList)
                {
                    if (budget.Elapsed > TokenRefreshBudget)
                    {
                        Log.Error("provider", $"gemini token 刷新超出 {TokenRefreshBudget.TotalSeconds:F0}s 预算，放弃剩余候选");
                        break;
                    }

                    string body;
                    int status;
                    try
                    {
                        using var resp = await Http.Shared.PostAsync("https://oauth2.googleapis.com/token",
                            new FormUrlEncodedContent(new[]
                            {
                                new System.Collections.Generic.KeyValuePair<string, string>("client_id", client.Id),
                                new System.Collections.Generic.KeyValuePair<string, string>("client_secret", client.Secret),
                                new System.Collections.Generic.KeyValuePair<string, string>("grant_type", "refresh_token"),
                                new System.Collections.Generic.KeyValuePair<string, string>("refresh_token", refreshToken)
                            }), ct).ConfigureAwait(false);
                        body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
                        status = (int)resp.StatusCode;
                    }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (Exception ex)
                    {
                        sawTransportError = true;
                        lastDetail = ex.Message;
                        continue;
                    }

                    if (status == 200)
                    {
                        string? newToken;
                        int expiresIn;
                        try
                        {
                            using var doc = JsonDocument.Parse(body);
                            newToken = doc.RootElement.TryGetProperty("access_token", out var at) ? at.GetString() : null;
                            expiresIn = doc.RootElement.TryGetProperty("expires_in", out var ei) && ei.ValueKind == JsonValueKind.Number && ei.TryGetInt32(out var secs)
                                ? secs : 3600;
                        }
                        catch (JsonException)
                        {
                            newToken = null;
                            expiresIn = 3600;
                        }
                        if (!string.IsNullOrEmpty(newToken))
                        {
                            // Cache the working pair first so later refreshes skip the trial-and-error.
                            lock (_staticStateLock)
                            {
                                _antigravityClientCandidates?.Remove(client);
                                _antigravityClientCandidates?.Insert(0, client);
                                _cachedAccessToken = newToken;
                                _cachedAccessTokenExpiryUtc = DateTime.UtcNow.AddSeconds(Math.Max(60, expiresIn - 120));
                                _lastTokenRefreshFailureUtc = null;
                            }
                            return new TokenRefreshResult(TokenRefreshOutcomeKind.Success, newToken);
                        }
                        lastDetail = LocalizationManager.Instance.IsChinese ? "响应缺少 access_token" : "missing access_token";
                        continue;
                    }

                    // 非 200：解析错误体区分「凭证死了」「配对错了」。invalid_grant 是 refresh_token
                    // 级的判决（已被轮换/吊销），换候选也救不回来，但仍让循环跑完——万一有别的
                    // client 真的认它；invalid_client / unauthorized_client 只是当前配对不对。
                    var code = ParseTokenErrorCode(body);
                    lastDetail = code == null ? $"{status}" : $"{status} {code}";
                    if (code == "invalid_grant") sawInvalidGrant = true;
                    if (code == "invalid_client" || code == "unauthorized_client") sawClientRejection = true;
                    Log.Error("provider", $"gemini token 刷新候选被拒 status={status} code={code ?? "unknown"}");
                }

                lock (_staticStateLock)
                {
                    _lastTokenRefreshFailureUtc = DateTime.UtcNow;
                }

                if (sawInvalidGrant)
                {
                    Log.Error("provider", "gemini token 刷新失败：refresh_token 已被判 invalid_grant（被轮换或吊销）");
                    return new TokenRefreshResult(TokenRefreshOutcomeKind.InvalidGrant);
                }
                if (sawClientRejection && !sawTransportError)
                {
                    Log.Error("provider", "gemini token 刷新失败：全部候选的 id/secret 配不上（Antigravity 组件更新过）");
                    return new TokenRefreshResult(TokenRefreshOutcomeKind.ClientMismatch);
                }
                Log.Error("provider", $"gemini token 刷新失败：所有候选都没能换到 access token（最后细节：{lastDetail ?? "无"}）");
                return new TokenRefreshResult(TokenRefreshOutcomeKind.Unreachable);
            }
            finally
            {
                _tokenRefreshSemaphore.Release();
            }
        }

        /// <summary>从 Google token 端点的错误响应体里取 OAuth error code。纯函数，供单测。</summary>
        internal static string? ParseTokenErrorCode(string body)
        {
            try
            {
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("error", out var err))
                {
                    if (err.ValueKind == JsonValueKind.String)
                        return err.GetString();
                    if (err.ValueKind == JsonValueKind.Object &&
                        err.TryGetProperty("code", out var codeProp) && codeProp.ValueKind == JsonValueKind.String)
                        return codeProp.GetString();
                }
            }
            catch (JsonException)
            {
            }
            return null;
        }

        /// <summary>
        /// 刷新并保证拿到 access token；失败按阶段抛 <see cref="GeminiCredentialException"/>。
        /// invalid_grant 对外来凭证与自有登录的意义不同（前者=建议自有登录，后者=清掉回退），由调用方指定。
        /// </summary>
        private async Task<string> RequireRefreshedTokenAsync(string refreshToken, GeminiCredentialStage invalidGrantStage, CancellationToken ct)
        {
            var result = await RefreshAntigravityTokenResultAsync(refreshToken, ct);
            return result.Kind switch
            {
                TokenRefreshOutcomeKind.Success => result.AccessToken!,
                TokenRefreshOutcomeKind.InvalidGrant => throw new GeminiCredentialException(invalidGrantStage),
                TokenRefreshOutcomeKind.ClientMismatch => throw new GeminiCredentialException(GeminiCredentialStage.ClientMismatch),
                TokenRefreshOutcomeKind.Cooldown => throw new GeminiCredentialException(GeminiCredentialStage.RefreshTokenCooldown),
                TokenRefreshOutcomeKind.NoCandidates => throw new GeminiCredentialException(GeminiCredentialStage.NoCredentials),
                _ => throw new GeminiCredentialException(GeminiCredentialStage.TokenRefreshUnreachable),
            };
        }

        // MARK: - 自有 Google 登录实现

        /// <summary>读取自有登录凭证。凭据管理器暂时读不到时不置 loaded——下一轮刷新自然重试。</summary>
        public async Task<string?> LoadOwnRefreshTokenAsync()
        {
            lock (_ownStateLock)
            {
                if (_ownRefreshTokenLoaded) return _ownRefreshTokenCache;
            }
            var lookup = await Task.Run(() => CredentialSecretStore.Instance.Lookup(OwnRefreshTokenKey));
            lock (_ownStateLock)
            {
                switch (lookup.Kind)
                {
                    case SecretLookupKind.Found:
                        _ownRefreshTokenCache = lookup.Value;
                        _ownRefreshTokenLoaded = true;
                        break;
                    case SecretLookupKind.Absent:
                        _ownRefreshTokenCache = null;
                        _ownRefreshTokenLoaded = true;
                        break;
                        // Unavailable：不置 loaded，本轮按「没有」处理，下轮重试
                }
                return _ownRefreshTokenCache;
            }
        }

        /// <summary>自有登录是否处于有效状态（设置页展示 / 失效后自愈用）</summary>
        public async Task<bool> HasOwnLoginAsync() => !string.IsNullOrEmpty(await LoadOwnRefreshTokenAsync());

        /// <summary>自有凭证被 Google 判失效时就地清掉；条目删除失败只记日志（内存已清，下次登录会覆盖）。</summary>
        private void ClearOwnRefreshToken()
        {
            lock (_ownStateLock)
            {
                _ownRefreshTokenCache = null;
                _ownRefreshTokenLoaded = true;
            }
            _ = Task.Run(() =>
            {
                try
                {
                    if (!CredentialSecretStore.Instance.Delete(OwnRefreshTokenKey))
                        Log.Warn("provider", "gemini 自有登录凭据条目删除失败");
                }
                catch (Exception ex)
                {
                    Log.Warn("provider", $"gemini 自有登录凭据条目删除异常: {ex.Message}");
                }
            });
        }

        /// <summary>「退出登录」：清自有凭证与账号提示，回到本地 Antigravity 凭证链路。</summary>
        public async Task ClearOwnLoginAsync()
        {
            lock (_ownStateLock)
            {
                _ownRefreshTokenCache = null;
                _ownRefreshTokenLoaded = true;
                _ownAccountHint = null;
            }
            await Task.Run(() => CredentialSecretStore.Instance.Delete(OwnRefreshTokenKey));
        }

        public sealed record GoogleLoginPlan(string AuthorizeUrl, int RedirectPort);

        /// <summary>与 Antigravity 凭证完全相同的 scope 集合（从 agy 刷出的 token 实测得到），
        /// 保证自有登录换出的 access token 对配额接口有同等权限。</summary>
        internal static readonly string[] LoginScopes =
        {
            "openid",
            "https://www.googleapis.com/auth/userinfo.email",
            "https://www.googleapis.com/auth/userinfo.profile",
            "https://www.googleapis.com/auth/cloud-platform",
            "https://www.googleapis.com/auth/cclog",
            "https://www.googleapis.com/auth/aicode",
            "https://www.googleapis.com/auth/experimentsandconfigs",
        };

        /// <summary>探测专用：禁用自动重定向，只看授权端点 302 的 Location 头（几百字节）。
        /// Http.Shared 会自动跟随到 ~800KB 的登录页/错误页，探测用它太浪费。</summary>
        private static readonly HttpClient ProbeClient = new(new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            ConnectTimeout = TimeSpan.FromSeconds(10),
        })
        { Timeout = TimeSpan.FromSeconds(15) };

        /// <summary>拼授权页 URL。探测与真实登录必须用完全相同的参数（含端口），行为才一致。</summary>
        internal static string BuildGoogleAuthorizeUrl(string clientId, int port)
        {
            var items = new System.Collections.Generic.Dictionary<string, string>
            {
                ["client_id"] = clientId,
                ["redirect_uri"] = $"http://localhost:{port}",
                ["response_type"] = "code",
                ["scope"] = string.Join(" ", LoginScopes),
                // access_type=offline + prompt=consent 确保 Google 一定下发 refresh_token
                ["access_type"] = "offline",
                ["prompt"] = "consent",
            };
            var query = string.Join("&", items.Select(kv => $"{Uri.EscapeDataString(kv.Key)}={Uri.EscapeDataString(kv.Value)}"));
            return $"https://accounts.google.com/o/oauth2/v2/auth?{query}";
        }

        /// <summary>探测某个 client_id 请求 <see cref="LoginScopes"/> 时 Google 是否放行。
        /// restricted_client（scope 未在该 client 注册）时 Google 302 到 signin/oauth/error——
        /// 这正是「点登录弹 403 禁止访问」的页面；正常则 302 到 v3/signin/identifier 登录页。
        /// 返回 true=可用 / false=明确被拒；网络异常等判不了的情况按可用处理（保持旧行为，交给浏览器兜底）。</summary>
        private static async Task<bool> AuthorizeScopeAcceptedAsync(string clientId, int port, CancellationToken ct)
        {
            try
            {
                using var resp = await ProbeClient.GetAsync(BuildGoogleAuthorizeUrl(clientId, port), ct).ConfigureAwait(false);
                if ((int)resp.StatusCode is 301 or 302 or 303 or 307)
                {
                    var location = resp.Headers.Location?.ToString();
                    if (!string.IsNullOrEmpty(location))
                    {
                        var rejected = location.Contains("/signin/oauth/error", StringComparison.OrdinalIgnoreCase);
                        if (rejected)
                            Log.Info("provider", $"gemini 登录探测：client {clientId[..13]}… 被拒(重定向到错误页)");
                        return !rejected;
                    }
                    return true;
                }
                // 200 等其他状态：无 cookie 的裸请求理论上拿不到，按不拒绝处理
                return true;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception ex)
            {
                Log.Warn("provider", $"gemini 登录探测失败（按可用处理）: {ex.Message}");
                return true;
            }
        }

        /// <summary>构造授权页 URL（loopback 重定向，随机端口）。
        /// 候选按序探测：agy 二进制里嵌的多个 client 未必都注册了 aicode 这类受限 scope，
        /// 盲取第一个会在授权页弹 403 restricted_client（v1.7.5 实测）。全被拒/探测不了时退回第一个候选。
        /// 本地找不到任何 OAuth client 时返回 null。</summary>
        public async Task<GoogleLoginPlan?> PrepareGoogleLoginAsync(CancellationToken ct = default)
        {
            var candidates = GetAntigravityClientCandidates();
            if (candidates.Count == 0)
                return null;

            int port;
            lock (LoginPortRandom)
                port = LoginPortRandom.Next(21000, 60001);

            var client = candidates[0];
            var probedIds = new HashSet<string>();
            foreach (var c in candidates)
            {
                if (!probedIds.Add(c.Id))
                    continue; // 同 ID 只探一次（secret 不影响授权页）
                if (await AuthorizeScopeAcceptedAsync(c.Id, port, ct).ConfigureAwait(false))
                {
                    client = c;
                    break;
                }
            }
            _pendingLoginClient = client;
            return new GoogleLoginPlan(BuildGoogleAuthorizeUrl(client.Id, port), port);
        }

        /// <summary>用授权码换 token 并落库。`redirectPort` 必须与 <see cref="PrepareGoogleLoginAsync"/> 返回的一致。</summary>
        public async Task<(string Account, string RefreshToken)> ExchangeGoogleLoginCodeAsync(string code, int redirectPort, CancellationToken ct = default)
        {
            var client = _pendingLoginClient;
            if (client == null)
            {
                var candidates = GetAntigravityClientCandidates();
                if (candidates.Count > 0)
                    client = candidates[0];
            }
            if (client == null)
                throw new GeminiCredentialException(GeminiCredentialStage.NoCredentials);

            // 授权码只绑定 client_id，secret 不对时换同 ID 的其他候选重试即可：
            // 候选表是扫描出的 ID×secret 交叉乘积，排在真实配对前面的组合 secret 未必匹配。
            var trials = new List<(string Id, string Secret)> { client.Value };
            foreach (var c in GetAntigravityClientCandidates())
            {
                if (trials.Count >= 4)
                    break;
                if (c.Id == client.Value.Id && trials.All(t => t.Secret != c.Secret))
                    trials.Add(c);
            }
            var usedClient = client.Value;

            string body = "";
            var exchangeOk = false;
            foreach (var trial in trials)
            {
                using var resp = await Http.Shared.PostAsync("https://oauth2.googleapis.com/token",
                    new FormUrlEncodedContent(new[]
                    {
                        new System.Collections.Generic.KeyValuePair<string, string>("client_id", trial.Id),
                        new System.Collections.Generic.KeyValuePair<string, string>("client_secret", trial.Secret),
                        new System.Collections.Generic.KeyValuePair<string, string>("grant_type", "authorization_code"),
                        new System.Collections.Generic.KeyValuePair<string, string>("code", code),
                        new System.Collections.Generic.KeyValuePair<string, string>("redirect_uri", $"http://localhost:{redirectPort}")
                    }), ct).ConfigureAwait(false);
                body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
                if (resp.IsSuccessStatusCode)
                {
                    exchangeOk = true;
                    usedClient = trial;
                    break;
                }
                var err = ParseTokenErrorCode(body);
                if (err != "invalid_client" && err != "unauthorized_client")
                    break; // invalid_grant 等其他错误换 secret 救不回来
                Log.Info("provider", $"gemini 登录 code 交换被拒({err})，同 ID 换 secret 重试");
            }

            string? refreshToken = null;
            string? accessToken = null;
            string? idToken = null;
            var expiresIn = 3600;
            if (exchangeOk)
            {
                try
                {
                    using var doc = JsonDocument.Parse(body);
                    if (doc.RootElement.TryGetProperty("refresh_token", out var rt) && rt.ValueKind == JsonValueKind.String)
                        refreshToken = rt.GetString();
                    if (doc.RootElement.TryGetProperty("access_token", out var at) && at.ValueKind == JsonValueKind.String)
                        accessToken = at.GetString();
                    if (doc.RootElement.TryGetProperty("id_token", out var idt) && idt.ValueKind == JsonValueKind.String)
                        idToken = idt.GetString();
                    if (doc.RootElement.TryGetProperty("expires_in", out var ei) && ei.ValueKind == JsonValueKind.Number && ei.TryGetInt32(out var secs))
                        expiresIn = secs;
                }
                catch (JsonException)
                {
                }
            }
            if (string.IsNullOrEmpty(refreshToken))
            {
                var detail = ParseTokenErrorCode(body) ?? "HTTP error";
                Log.Error("provider", $"provider=gemini Google 登录 code 交换失败: {detail}");
                throw new Exception(LocalizationManager.Instance.IsChinese
                    ? $"Google 登录 code 交换失败：{detail}，请重试"
                    : $"Google login code exchange failed: {detail}. Please retry");
            }

            _pendingLoginClient = null;
            lock (_staticStateLock)
            {
                // 交换成功说明这套配对可用，置顶让后续刷新跳过试错
                _antigravityClientCandidates?.Remove(usedClient);
                if (_antigravityClientCandidates != null)
                    _antigravityClientCandidates.Insert(0, usedClient);
                if (!string.IsNullOrEmpty(accessToken))
                {
                    _cachedAccessToken = accessToken;
                    _cachedAccessTokenExpiryUtc = DateTime.UtcNow.AddSeconds(Math.Max(60, expiresIn - 120));
                    _lastTokenRefreshFailureUtc = null;
                }
            }
            // 落自有凭据条目：以前只放内存，App 一重启自有登录就丢，又退回 Antigravity 链路。
            // 写失败也保留内存值（本次运行照常可用），只记 error，别为此让整个登录失败。
            var persisted = await Task.Run(() => CredentialSecretStore.Instance.Set(OwnRefreshTokenKey, refreshToken!));
            if (!persisted)
                Log.Error("provider", "provider=gemini 自有登录 refresh_token 写入凭据管理器失败，重启后需重新登录");
            lock (_ownStateLock)
            {
                _ownRefreshTokenCache = refreshToken;
                _ownRefreshTokenLoaded = true;
            }

            _ownAccountHint = EmailFromIdToken(idToken);
            if (string.IsNullOrEmpty(_ownAccountHint) && !string.IsNullOrEmpty(accessToken))
                _ownAccountHint = await FetchUserInfoAsync(accessToken!, ct);
            var account = !string.IsNullOrEmpty(_ownAccountHint)
                ? _ownAccountHint!
                : (LocalizationManager.Instance.IsChinese ? "Google 账号" : "Google Account");
            return (account, refreshToken!);
        }

        /// <summary>从 Google id_token（JWT）里解出 email。不做签名校验：token 是刚从 Google 的
        /// TLS 响应体里拿到的，这里只是展示账号，不是鉴权依据。纯函数，供单测。</summary>
        internal static string? EmailFromIdToken(string? idToken)
        {
            if (string.IsNullOrWhiteSpace(idToken))
                return null;
            var parts = idToken.Split('.');
            if (parts.Length != 3)
                return null;
            var b64 = parts[1].Replace('-', '+').Replace('_', '/');
            b64 = b64.PadRight(b64.Length + (4 - b64.Length % 4) % 4, '=');
            try
            {
                var json = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(b64));
                using var doc = JsonDocument.Parse(json);
                return doc.RootElement.TryGetProperty("email", out var email) && email.ValueKind == JsonValueKind.String
                    ? email.GetString()
                    : null;
            }
            catch (Exception ex)
            {
                Log.Warn("provider", $"解析 id_token 失败: {ex.Message}");
                return null;
            }
        }

        /// <summary>等待 Google 重定向回 localhost 拿授权码（一次性监听，5 分钟预算）。
        /// 超时抛带本地化消息的异常；用户在浏览器取消/拒绝时同样抛异常。</summary>
        public static async Task<string> WaitForGoogleLoginCodeAsync(int port, CancellationToken ct = default)
        {
            var zh = LocalizationManager.Instance.IsChinese;
            System.Net.HttpListener listener;
            try
            {
                listener = new System.Net.HttpListener();
                listener.Prefixes.Add($"http://localhost:{port}/");
                listener.Start();
            }
            catch (Exception ex)
            {
                throw new Exception(zh
                    ? $"无法启动本地登录回调监听（端口 {port}）：{ex.Message}"
                    : $"Cannot start the local sign-in callback listener (port {port}): {ex.Message}");
            }
            try
            {
                using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                timeoutCts.CancelAfter(LoginCallbackBudget);
                System.Net.HttpListenerContext context;
                try
                {
                    context = await listener.GetContextAsync().WaitAsync(timeoutCts.Token);
                }
                catch (OperationCanceledException)
                {
                    throw new Exception(zh
                        ? "等待 Google 登录超时（5 分钟），请重新发起登录"
                        : "Timed out waiting for Google sign-in (5 minutes). Please start the login again");
                }

                var code = context.Request.QueryString["code"];
                var error = context.Request.QueryString["error"];

                var html = (zh
                    ? (string.IsNullOrEmpty(code)
                        ? "<meta charset=\"utf-8\"><h2>授权未成功，请关闭此页返回 TokenBar 重试</h2>"
                        : "<meta charset=\"utf-8\"><h2>授权完成！可以关闭此页返回 TokenBar</h2>")
                    : (string.IsNullOrEmpty(code)
                        ? "<meta charset=\"utf-8\"><h2>Authorization failed. Close this page and retry in TokenBar</h2>"
                        : "<meta charset=\"utf-8\"><h2>Authorized! Close this page and return to TokenBar</h2>"));
                var bytes = System.Text.Encoding.UTF8.GetBytes(html);
                context.Response.ContentType = "text/html; charset=utf-8";
                context.Response.ContentLength64 = bytes.Length;
                await context.Response.OutputStream.WriteAsync(bytes, 0, bytes.Length);
                context.Response.Close();

                if (!string.IsNullOrEmpty(code))
                    return code!;
                throw new Exception(zh
                    ? $"Google 登录未完成：{error ?? "未收到授权码"}"
                    : $"Google sign-in did not complete: {error ?? "no authorization code received"}");
            }
            finally
            {
                listener.Stop();
                listener.Close();
            }
        }

        /// <summary>
        /// Fetches the real Antigravity quota (same source as the IDE's usage panel) and maps the
        /// "Gemini Models" group's weekly / 5-hour buckets to TokenWindows, alongside any "Gemini 4 Argon" scoped quota bucket.
        /// Throws QuotaAuthException on 401/403 so the caller can refresh and retry.
        ///
        /// 两个配额端点返回的分组集不同（实测 daily 端点只回 "Claude and GPT models" 组，
        /// Gemini 组只在 cloudcode-pa 上），所以不能「第一个 2xx 就用」：逐个端点解析，
        /// 直到某个响应里解析出 Gemini 组；全部没有再走按模型聚合的回退。此前 daily 排
        /// 第一且首个 2xx 即返回，Gemini 组永远匹配不上，静默退化到只产 5h 窗口的回退——
        /// 这正是「只有 5 小时额度、没有每周额度」那次线上问题的根因。
        /// </summary>
        private async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, TokenWindow? ScopedWeekly)> FetchAntigravityQuotaCoreAsync(string accessToken, CancellationToken ct)
        {
            Exception? lastError = null;
            var sawSuccessfulSummary = false;
            foreach (var baseUrl in CloudCodeQuotaBases)
            {
                try
                {
                    var summaryBody = await PostCloudCodeOnceAsync(accessToken, "/v1internal:retrieveUserQuotaSummary", baseUrl, ct);
                    sawSuccessfulSummary = true;
                    var (fiveHour, weekly, scopedWeekly) = ParseGeminiGroupWindows(summaryBody);
                    if (fiveHour != null || weekly != null || scopedWeekly != null)
                        return (fiveHour, weekly, scopedWeekly);
                }
                catch (QuotaAuthException)
                {
                    // 401/403 是令牌级问题，换端点无意义——抛给上层走刷新重试
                    throw;
                }
                catch (OperationCanceledException) when (ct.IsCancellationRequested)
                {
                    throw;
                }
                catch (Exception ex)
                {
                    lastError = ex;
                }
            }
            if (!sawSuccessfulSummary)
                throw lastError ?? new Exception("Antigravity request failed");

            // Older/alternative response shape: fall back to per-model quota and aggregate the gemini family.
            var (fbFiveHour, fbWeekly) = await FetchAntigravityModelsFallbackAsync(accessToken, ct);
            if (fbFiveHour == null && fbWeekly == null)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese
                    ? "Antigravity 额度响应中未找到 Gemini 配额数据"
                    : "No Gemini quota data found in the Antigravity response");
            }
            return (fbFiveHour, fbWeekly, null);
        }

        /// <summary>
        /// 从 retrieveUserQuotaSummary 响应里挑 Gemini 组并映射成 weekly/5h 窗口，同时提取 Gemini 4 Argon 额度。
        /// 组选择：
        /// - 正主 Gemini Models 组：优先名字含 "gemini models" 的组；没有时退回第一个名字含 gemini 且不含 argon 的组。
        /// - Gemini 4 Argon 组：优先名字含 "gemini 4 argon" 的组；没有时退回第一个名字含 argon 的组。
        /// 返回 (fiveHour, weekly, scopedWeekly)，当该响应里没有任何可用的 Gemini 相关组时返回 (null, null, null)。
        /// 必须在 doc 存活期间调用；TokenWindow 当场物化，返回后 doc 可释放。
        /// </summary>
        internal static (TokenWindow? FiveHour, TokenWindow? Weekly, TokenWindow? ScopedWeekly) ParseGeminiGroupWindows(string summaryBody)
        {
            using var doc = JsonDocument.Parse(summaryBody);
            var root = doc.RootElement.TryGetProperty("response", out var resp) && resp.ValueKind == JsonValueKind.Object
                ? resp
                : doc.RootElement;
            if (!root.TryGetProperty("groups", out var groups) || groups.ValueKind != JsonValueKind.Array)
                return (null, null, null);

            JsonElement targetGroup = default;
            JsonElement firstGeminiGroup = default;
            JsonElement targetArgonGroup = default;
            JsonElement firstArgonGroup = default;
            var haveTarget = false;
            var haveFirstGemini = false;
            var haveTargetArgon = false;
            var haveFirstArgon = false;

            foreach (var group in groups.EnumerateArray())
            {
                if (!group.TryGetProperty("displayName", out var gName) || gName.ValueKind != JsonValueKind.String)
                    continue;
                var rawName = gName.GetString() ?? "";
                var name = rawName.ToLowerInvariant();

                if (name.Contains("argon"))
                {
                    if (name.Contains("gemini 4 argon"))
                    {
                        targetArgonGroup = group;
                        haveTargetArgon = true;
                    }
                    else if (!haveFirstArgon)
                    {
                        firstArgonGroup = group;
                        haveFirstArgon = true;
                    }
                    continue;
                }

                if (!name.Contains("gemini"))
                    continue;
                if (name.Contains("gemini models"))
                {
                    targetGroup = group;
                    haveTarget = true;
                }
                else if (!haveFirstGemini)
                {
                    firstGeminiGroup = group;
                    haveFirstGemini = true;
                }
            }

            TokenWindow? fiveHour = null;
            TokenWindow? weekly = null;
            if (haveTarget || haveFirstGemini)
            {
                var chosen = haveTarget ? targetGroup : firstGeminiGroup;
                if (chosen.TryGetProperty("buckets", out var buckets) && buckets.ValueKind == JsonValueKind.Array)
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
            }

            TokenWindow? scopedWeekly = null;
            if (haveTargetArgon || haveFirstArgon)
            {
                var argon = haveTargetArgon ? targetArgonGroup : firstArgonGroup;
                string titleText = "Gemini 4 Argon";
                if (argon.TryGetProperty("displayName", out var dName) && dName.ValueKind == JsonValueKind.String)
                {
                    var s = (dName.GetString() ?? "").Trim();
                    if (!string.IsNullOrEmpty(s)) titleText = s;
                }

                if (argon.TryGetProperty("buckets", out var aBuckets) && aBuckets.ValueKind == JsonValueKind.Array)
                {
                    foreach (var bucket in aBuckets.EnumerateArray())
                    {
                        var window = ParseQuotaBucket(bucket, out var isWeekly);
                        if (window == null)
                            continue;
                        window.Title = WindowTitle.Custom(titleText);
                        if (isWeekly)
                        {
                            scopedWeekly = window;
                            break;
                        }
                        else if (scopedWeekly == null)
                        {
                            scopedWeekly = window;
                        }
                    }
                }
            }

            return (fiveHour, weekly, scopedWeekly);
        }

        /// <summary>
        /// Loops the quota endpoints, first successful response wins. 供响应形状与端点无关的
        /// 调用（fetchAvailableModels）使用；分组集依赖端点的 retrieveUserQuotaSummary
        /// 必须走 FetchAntigravityQuotaCoreAsync 的逐端点解析。
        /// </summary>
        private async Task<string> PostCloudCodeAsync(string accessToken, string path, CancellationToken ct)
        {
            Exception? lastEx = null;
            foreach (var baseUrl in CloudCodeQuotaBases)
            {
                try
                {
                    return await PostCloudCodeOnceAsync(accessToken, path, baseUrl, ct);
                }
                catch (QuotaAuthException)
                {
                    throw;
                }
                // 只有调用方预算取消才需要立即中止（此时 ct.IsCancellationRequested 为真）。
                // 连接/请求超时同样以 OperationCanceledException 形态抛出但与预算无关——
                // 那只说明当前 base URL 连不上，应当继续试下一个，而不是把整轮刷新判死。
                catch (OperationCanceledException) when (ct.IsCancellationRequested)
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

        /// <summary>
        /// Single-base POST to a Cloud Code quota endpoint.
        /// 401/403 抛 QuotaAuthException（令牌级问题，换端点救不了）；非 2xx 与解析失败抛
        /// 普通错误，由调用方决定是否换下一个端点。
        /// </summary>
        private static async Task<string> PostCloudCodeOnceAsync(string accessToken, string path, string baseUrl, CancellationToken ct)
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, baseUrl + path);
            req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {accessToken}");
            req.Headers.TryAddWithoutValidation("User-Agent", CloudCodeUserAgent);
            req.Content = new StringContent("{}", System.Text.Encoding.UTF8, "application/json");

            using var resp = await Http.Shared.SendAsync(req, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);

            if ((int)resp.StatusCode == 401 || (int)resp.StatusCode == 403)
            {
                throw new QuotaAuthException();
            }
            if (!resp.IsSuccessStatusCode)
            {
                var trimmed = body.Length > 300 ? body[..300] : body;
                throw new Exception(LocalizationManager.Instance.IsChinese
                    ? $"Antigravity 额度接口响应异常 ({(int)resp.StatusCode}): {trimmed}"
                    : $"Antigravity quota API error ({(int)resp.StatusCode}): {trimmed}");
            }
            return body;
        }

        /// <summary>Maps one quota bucket ({window/bucketId, remainingFraction, resetTime}) to a TokenWindow.</summary>
        internal static TokenWindow? ParseQuotaBucket(JsonElement bucket, out bool isWeekly)
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
                if (rt.ValueKind == JsonValueKind.String && DateTimeOffset.TryParse(rt.GetString(),
                        CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
                {
                    reset = parsed.LocalDateTime;
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
                Title = isWeekly ? WindowTitle.Weekly : WindowTitle.FiveHour,
                UsedPercentage = usedPct,
                StartTime = start,
                EndTime = end,
                Unit = "%",
                IsIdle = remainingFraction.Value >= 0.999
            };
        }

        /// <summary>Fallback via fetchAvailableModels: aggregates the most-constrained gemini model into a 5h window.</summary>
        private async Task<(TokenWindow? FiveHour, TokenWindow? Weekly)> FetchAntigravityModelsFallbackAsync(string accessToken, CancellationToken ct)
        {
            var modelsBody = await PostCloudCodeAsync(accessToken, "/v1internal:fetchAvailableModels", ct);

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
                                DateTimeOffset.TryParse(rt.GetString(), CultureInfo.InvariantCulture,
                                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
                            {
                                reset = parsed.LocalDateTime;
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
                Title = WindowTitle.FiveHour,
                UsedPercentage = Math.Clamp((1.0 - minRemaining.Value) * 100.0, 0.0, 100.0),
                StartTime = end.Subtract(span),
                EndTime = end,
                Unit = "%",
                IsIdle = minRemaining.Value >= 0.999
            };
            return (window, null);
        }

        public async Task<string?> FetchUserInfoAsync(string token, CancellationToken ct = default)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, "https://www.googleapis.com/oauth2/v2/userinfo");
                req.Headers.Add("Authorization", $"Bearer {token}");
                req.Headers.Add("Accept", "application/json");

                using var resp = await Http.Shared.SendAsync(req, ct);
                if (resp.IsSuccessStatusCode)
                {
                    var json = await resp.Content.ReadAsStringAsync(ct);
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
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                Log.Warn("provider", $"gemini userinfo 查询失败: {ex.Message}");
            }
            return null;
        }
    }
}
