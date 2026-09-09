using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using TokenBar.I18n;
using TokenBar.Models;

namespace TokenBar.Services
{
    /// <summary>
    /// 阿里云百炼 Token Plan 额度获取。四条通道，顺序即优先级：
    ///   1. AccessKey 原生（签名换控制台令牌 → Bearer 调网关，不受 SSO 多设备互踢限制，失效自愈）
    ///   2. 复用本机已有的控制台令牌（TokenBar 缓存或 %USERPROFILE%\.bailian\config.json）
    ///   3. 官方 bl CLI 子进程（保留兼容）
    ///   4. 控制台 Cookie 直调网关（兜底）
    ///
    /// 本文件须与 mac 端 AliyunBailianService.swift + AliyunBailianService+Parsing.swift 行为一致。
    /// </summary>
    public partial class AliyunBailianService
    {
        public static AliyunBailianService Instance { get; } = new AliyunBailianService();

        private static readonly HttpClient HttpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

        /// <summary>控制台网关上查询 Token Plan 用量的 API 名。</summary>
        public const string TokenPlanUsageApi = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage";
        /// <summary>用 AK/SK 换控制台令牌的 OpenAPI。</summary>
        public const string GenerateTokenPath = "/modelstudio/cli/generateAccessToken";
        public const string GenerateTokenAction = "GenerateCLIAccessToken";
        public const string GenerateTokenVersion = "2026-02-10";
        /// <summary>查询阿里云账户现金余额的 BSS OpenAPI。</summary>
        public const string BalanceHost = "business.aliyuncs.com";
        public const string BalanceAction = "QueryAccountBalance";
        public const string BalanceVersion = "2017-12-14";

        private static readonly string[] QuotaKeys =
        {
            "per1WeekPercentage", "per5HourPercentage", "per1WeekResetTime", "per5HourResetTime"
        };

        private readonly TokenCoordinator _tokens = new TokenCoordinator();
        private static bool IsZh => LocalizationManager.Instance.IsChinese;

        private AliyunBailianService() { }

        // ---------- 终端登录（保留，作为备用通道的入口） ----------

        public static void OpenTerminalToLoginCLI()
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = "/k bl auth login --console",
                    UseShellExecute = true
                });
            }
            catch { }
        }

        // ---------- 通道编排 ----------

        /// <summary>
        /// 依据手上的凭证决定要依次尝试哪些通道。纯函数。
        ///
        /// 有 AK/SK 时不单独跑 ConsoleToken —— AccessKey 内部本来就会先用缓存令牌，
        /// 只有拿不到或遇到 NotLogined 才签发新的。
        /// </summary>
        public static List<AliyunChannel> PlannedChannels(AliyunCredentials credentials)
        {
            var channels = new List<AliyunChannel>();
            if (credentials.HasAccessKey) channels.Add(AliyunChannel.AccessKey);
            else if (credentials.HasConsoleToken) channels.Add(AliyunChannel.ConsoleToken);

            channels.Add(AliyunChannel.Cli);
            if (credentials.HasCookie) channels.Add(AliyunChannel.Cookie);
            return channels;
        }

        /// <summary>按优先级依次尝试各通道；全部失败时抛出聚合了每级失败原因的异常。</summary>
        public async Task<AliyunQuotaResult> FetchQuotaAsync(AliyunCredentials credentials)
        {
            var failures = new List<(AliyunChannel Channel, string Message)>();

            foreach (var channel in PlannedChannels(credentials))
            {
                try
                {
                    return channel switch
                    {
                        AliyunChannel.AccessKey => await FetchViaAccessKeyAsync(credentials),
                        AliyunChannel.ConsoleToken => await FetchViaConsoleTokenAsync(credentials),
                        AliyunChannel.Cli => await FetchViaCliAsync(),
                        AliyunChannel.Cookie => await FetchViaCookieAsync(credentials),
                        _ => throw new AliyunChannelException(AliyunErrorKind.MissingCredentials)
                    };
                }
                catch (Exception ex)
                {
                    failures.Add((channel, ex.Message));
                }
            }

            throw AggregateError(failures, credentials);
        }

        /// <summary>把各通道的失败原因拼成一条对用户有指导意义的错误。</summary>
        internal static Exception AggregateError(
            List<(AliyunChannel Channel, string Message)> failures,
            AliyunCredentials credentials)
        {
            if (failures.Count == 0) return new AliyunChannelException(AliyunErrorKind.MissingCredentials);

            var header = IsZh ? "百炼额度获取失败：" : "Could not read Bailian quota:";
            var lines = failures.Select(f => $"· {f.Channel.DisplayName()}：{f.Message}");
            var message = string.Join("\n", new[] { header }.Concat(lines));

            if (!credentials.HasAccessKey)
            {
                message += "\n" + (IsZh
                    ? "建议在设置中填写 AccessKey ID / Secret —— 这是唯一支持多台设备同时在线的方式。"
                    : "Add an AccessKey ID / Secret in Settings - it is the only option that keeps several machines online at once.");
            }
            return new Exception(message);
        }

        // ---------- 通道 1：AK/SK 原生（含失效自愈） ----------

        /// <summary>
        /// 先用缓存令牌打网关；遇到 NotLogined 才用 AK/SK 换新令牌并重试一次。
        ///
        /// 三重防失控：直线代码不自我调用（最多 2 次网关 + 2 次签名）；
        /// TokenCoordinator 串行化签发；签发失败后 30 秒内复用上次错误。
        /// </summary>
        internal async Task<AliyunQuotaResult> FetchViaAccessKeyAsync(AliyunCredentials credentials)
        {
            var token = credentials.ConsoleAccessToken.Trim();
            string? refreshedToken = null;
            var freshlyIssued = false;

            if (string.IsNullOrEmpty(token))
            {
                token = await _tokens.IssueAsync(() => GenerateConsoleAccessTokenAsync(credentials));
                refreshedToken = token;
                freshlyIssued = true;
            }

            try
            {
                var result = await QueryTokenPlanAsync(token, credentials, AliyunChannel.AccessKey);
                result.RefreshedToken = refreshedToken;
                return result;
            }
            catch (AliyunChannelException ex) when (ex.Kind == AliyunErrorKind.NotLogined)
            {
                // 刚换的令牌仍被判未登录 → 不是过期问题，直接抛，避免死循环
                if (freshlyIssued) throw new AliyunChannelException(AliyunErrorKind.NotLoginedAfterRefresh);

                var newToken = await _tokens.IssueAsync(
                    () => GenerateConsoleAccessTokenAsync(credentials), force: true);
                var result = await QueryTokenPlanAsync(newToken, credentials, AliyunChannel.AccessKey);
                result.RefreshedToken = newToken;
                return result;
            }
        }

        /// <summary>通道 2：只有现成令牌、没有 AK/SK —— 无法自愈，失败即降级。</summary>
        internal Task<AliyunQuotaResult> FetchViaConsoleTokenAsync(AliyunCredentials credentials)
            => QueryTokenPlanAsync(credentials.ConsoleAccessToken.Trim(), credentials, AliyunChannel.ConsoleToken);

        /// <summary>用 AK/SK 调 GenerateCLIAccessToken 换一枚控制台令牌。</summary>
        internal async Task<string> GenerateConsoleAccessTokenAsync(AliyunCredentials credentials)
        {
            var host = OpenApiHost(credentials.ConsoleRegion);
            // 官方 CLI 在这里发的是空 body、空 query，签名必须完全一致
            var headers = AliyunSigner.SignedHeaders(
                host: host,
                action: GenerateTokenAction,
                version: GenerateTokenVersion,
                accessKeyId: credentials.AccessKeyId.Trim(),
                accessKeySecret: credentials.AccessKeySecret.Trim(),
                pathname: GenerateTokenPath);

            using var req = new HttpRequestMessage(HttpMethod.Post, $"https://{host}{GenerateTokenPath}");
            ApplySignedHeaders(req, headers);

            HttpResponseMessage resp;
            string body;
            try
            {
                resp = await HttpClient.SendAsync(req);
                body = await resp.Content.ReadAsStringAsync();
            }
            catch (Exception ex)
            {
                throw new AliyunChannelException(AliyunErrorKind.Network, ex.Message);
            }

            string? token = null, code = null, message = null;
            var success = true;
            try
            {
                using var doc = JsonDocument.Parse(body);
                var root = doc.RootElement;
                if (root.TryGetProperty("cliAccessToken", out var t) && t.ValueKind == JsonValueKind.String)
                    token = t.GetString()?.Trim();
                if (root.TryGetProperty("Code", out var c) && c.ValueKind == JsonValueKind.String)
                    code = c.GetString();
                if (root.TryGetProperty("Message", out var m) && m.ValueKind == JsonValueKind.String)
                    message = m.GetString();
                if (root.TryGetProperty("Success", out var s) && s.ValueKind == JsonValueKind.False)
                    success = false;
            }
            catch { }

            if (!string.IsNullOrEmpty(token) && resp.IsSuccessStatusCode && success) return token!;
            throw ClassifyOpenApiError((int)resp.StatusCode, code ?? "", message ?? "", body);
        }

        /// <summary>
        /// 把签好名的 header 写进请求。
        ///
        /// 两个必须的细节：host 交给 HttpClient 自动填；content-type 必须精确等于
        /// "application/json"（不能带 charset），否则与签名不一致，服务端必返 SignatureDoesNotMatch。
        /// </summary>
        private static void ApplySignedHeaders(HttpRequestMessage req, IDictionary<string, string> headers)
        {
            req.Content = new StringContent(string.Empty, Encoding.UTF8);
            req.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json");

            foreach (var kv in headers)
            {
                if (kv.Key == "host" || kv.Key == "content-type") continue;
                req.Headers.TryAddWithoutValidation(kv.Key, kv.Value);
            }
        }

        /// <summary>把 OpenAPI 的错误码翻译成可操作的分类。</summary>
        internal static AliyunChannelException ClassifyOpenApiError(
            int status, string code, string message, string raw)
        {
            var detail = string.IsNullOrEmpty(message)
                ? (raw.Length > 200 ? raw.Substring(0, 200) : raw)
                : message;
            var joined = code + " " + message;

            if (joined.Contains("SignatureDoesNotMatch", StringComparison.Ordinal))
                return new AliyunChannelException(AliyunErrorKind.SignatureMismatch, detail, code);
            if (code.Contains("InvalidAccessKeyId", StringComparison.Ordinal)
                || code.Contains("AccessKeyId.NotFound", StringComparison.Ordinal))
                return new AliyunChannelException(AliyunErrorKind.InvalidAccessKey, detail, code);
            if (code.Contains("Forbidden", StringComparison.Ordinal)
                || code.Contains("NoPermission", StringComparison.Ordinal)
                || code.Contains("RAM", StringComparison.Ordinal)
                || status == 403)
                return new AliyunChannelException(AliyunErrorKind.NoPermission, detail, code);

            return new AliyunChannelException(
                AliyunErrorKind.GatewayError, detail, string.IsNullOrEmpty(code) ? $"HTTP {status}" : code);
        }

        // ---------- 控制台网关（Bearer） ----------

        /// <summary>GenerateCLIAccessToken 所在的 OpenAPI 域名。</summary>
        public static string OpenApiHost(string region)
            => region?.Trim() == "ap-southeast-1"
                ? "modelstudio.ap-southeast-1.aliyuncs.com"
                : "modelstudio.cn-beijing.aliyuncs.com";

        /// <summary>控制台网关的站点路由；未知 region 回落到 cn-beijing 那一档（保留 site）。</summary>
        public static AliyunConsoleGatewayRoute GatewayRoute(string region, string site)
        {
            var isIntlSite = site?.Trim() == "international";
            return region?.Trim() switch
            {
                "ap-southeast-1" => new AliyunConsoleGatewayRoute(
                    isIntlSite ? "bailian-singapore-cs.alibabacloud.com" : "modelstudio-cs.console.aliyun.com",
                    "IntlBroadScopeAspnGateway"),
                _ => new AliyunConsoleGatewayRoute(
                    isIntlSite ? "bailian-cs.console.alibabacloud.com" : "bailian-cs.console.aliyun.com",
                    "BroadScopeAspnGateway")
            };
        }

        /// <summary>网关请求体里的 params JSON。</summary>
        public static string GatewayParamsJson(string api, long? switchAgent)
        {
            var cornerstone = new Dictionary<string, object>
            {
                ["protocol"] = "V2",
                ["console"] = "ONE_CONSOLE",
                ["productCode"] = "p_efm",
                ["switchUserType"] = 3,
                ["consoleSite"] = "BAILIAN_ALIYUN"
            };
            if (switchAgent.HasValue) cornerstone["switchAgent"] = switchAgent.Value;

            var payload = new Dictionary<string, object>
            {
                ["Api"] = api,
                ["V"] = "1.0",
                ["Data"] = new Dictionary<string, object> { ["cornerstoneParam"] = cornerstone }
            };
            return JsonSerializer.Serialize(payload);
        }

        /// <summary>以 Bearer 令牌调控制台网关查 Token Plan 用量。</summary>
        internal async Task<AliyunQuotaResult> QueryTokenPlanAsync(
            string token, AliyunCredentials credentials, AliyunChannel channel)
        {
            if (string.IsNullOrWhiteSpace(token))
                throw new AliyunChannelException(AliyunErrorKind.NotLogined);

            var route = GatewayRoute(credentials.ConsoleRegion, credentials.ConsoleSite);
            var url = $"https://{route.Host}/cli/api.json?action={route.Action}"
                      + $"&product=sfm_bailian&api={AliyunSigner.PercentEncode(TokenPlanUsageApi)}";

            using var req = new HttpRequestMessage(HttpMethod.Post, url);
            req.Headers.TryAddWithoutValidation("Accept", "*/*");
            req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + token);
            req.Content = FormBody(new Dictionary<string, string>
            {
                ["params"] = GatewayParamsJson(TokenPlanUsageApi, credentials.SwitchAgentOrNull),
                ["region"] = credentials.ConsoleRegion.Trim()
            });

            HttpResponseMessage resp;
            string body;
            try
            {
                resp = await HttpClient.SendAsync(req);
                body = await resp.Content.ReadAsStringAsync();
            }
            catch (Exception ex)
            {
                throw new AliyunChannelException(AliyunErrorKind.Network, ex.Message);
            }

            if (resp.StatusCode == HttpStatusCode.Unauthorized || resp.StatusCode == HttpStatusCode.Forbidden)
                throw new AliyunChannelException(AliyunErrorKind.NotLogined);

            var label = $"{channel.DisplayName()}（{credentials.ConsoleRegion.Trim()}）";
            return ParseTokenPlanResponse(body, label, channel);
        }

        /// <summary>
        /// application/x-www-form-urlencoded 请求体。
        ///
        /// 刻意不用 FormUrlEncodedContent —— 它按 application/x-www-form-urlencoded 的旧规则编码，
        /// 对 params JSON 里的特殊字符处理与 mac 端不一致；这里统一走 RFC3986。
        /// </summary>
        internal static HttpContent FormBody(IDictionary<string, string> fields)
        {
            var encoded = string.Join("&", fields
                .OrderBy(kv => kv.Key, StringComparer.Ordinal)
                .Select(kv => $"{AliyunSigner.PercentEncode(kv.Key)}={AliyunSigner.PercentEncode(kv.Value)}"));

            var content = new StringContent(encoded, Encoding.UTF8);
            content.Headers.ContentType = new MediaTypeHeaderValue("application/x-www-form-urlencoded");
            return content;
        }

        // ---------- 通道 3：官方 CLI ----------

        public async Task<AliyunQuotaResult> FetchViaCliAsync()
        {
            var blPath = FindBlExecutable();
            if (blPath == null) throw new AliyunChannelException(AliyunErrorKind.CliNotFound);

            var psi = new ProcessStartInfo
            {
                FileName = blPath,
                Arguments = "usage token-plan --console-region cn-beijing --console-site domestic --output json",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var proc = Process.Start(psi);
            if (proc == null)
                throw new AliyunChannelException(AliyunErrorKind.CliFailed,
                    IsZh ? "无法启动百炼 CLI 进程" : "Unable to launch the Bailian CLI process");

            var outputTask = proc.StandardOutput.ReadToEndAsync();
            var errorTask = proc.StandardError.ReadToEndAsync();
            await proc.WaitForExitAsync();
            var stdout = await outputTask;
            var stderr = await errorTask;

            var label = IsZh ? "百炼 CLI (cn-beijing)" : "Bailian CLI (cn-beijing)";
            if (!string.IsNullOrWhiteSpace(stdout))
            {
                return ParseTokenPlanResponse(stdout, label, AliyunChannel.Cli);
            }
            throw new AliyunChannelException(AliyunErrorKind.CliFailed,
                string.IsNullOrWhiteSpace(stderr) ? "(no output)" : stderr.Trim());
        }

        private static string? FindBlExecutable()
        {
            var candidates = new[] { "bl.cmd", "bl.exe", "bl.bat", "bl" };

            var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            var npmDir = Path.Combine(appData, "npm");
            foreach (var c in candidates)
            {
                var full = Path.Combine(npmDir, c);
                if (File.Exists(full)) return full;
            }

            var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (var dir in pathEnv.Split(';', StringSplitOptions.RemoveEmptyEntries))
            {
                foreach (var c in candidates)
                {
                    try
                    {
                        var full = Path.Combine(dir.Trim(), c);
                        if (File.Exists(full)) return full;
                    }
                    catch { }
                }
            }
            return null;
        }

        // ---------- 通道 4：控制台 Cookie（兜底） ----------

        internal async Task<AliyunQuotaResult> FetchViaCookieAsync(AliyunCredentials credentials)
        {
            var url = "https://bailian-cs.console.aliyun.com/data/api.json?action=BroadScopeAspnGateway"
                      + $"&product=sfm_bailian&api={AliyunSigner.PercentEncode(TokenPlanUsageApi)}&_v=undefined";

            using var req = new HttpRequestMessage(HttpMethod.Post, url);
            req.Headers.TryAddWithoutValidation("Accept", "application/json, text/plain, */*");
            req.Headers.TryAddWithoutValidation("Cookie", credentials.Cookie.Trim());
            req.Headers.TryAddWithoutValidation("Origin", "https://bailian.console.aliyun.com");
            req.Headers.TryAddWithoutValidation("Referer", "https://bailian.console.aliyun.com/cn-beijing?tab=plan");
            req.Headers.TryAddWithoutValidation("User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36");
            req.Headers.TryAddWithoutValidation("X-Requested-With", "XMLHttpRequest");

            var cornerstone = new Dictionary<string, object>
            {
                ["feTraceId"] = Guid.NewGuid().ToString("N"),
                ["feURL"] = "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan",
                ["protocol"] = "V2",
                ["console"] = "ONE_CONSOLE",
                ["productCode"] = "p_efm",
                ["switchUserType"] = 3,
                ["domain"] = "bailian.console.aliyun.com",
                ["consoleSite"] = "BAILIAN_ALIYUN",
                ["userNickName"] = "",
                ["userPrincipalName"] = "",
                ["xsp_lang"] = "zh-CN"
            };
            if (credentials.SwitchAgentOrNull.HasValue)
                cornerstone["switchAgent"] = credentials.SwitchAgentOrNull.Value;

            req.Content = FormBody(new Dictionary<string, string>
            {
                ["params"] = JsonSerializer.Serialize(cornerstone),
                ["region"] = "cn-beijing"
            });

            HttpResponseMessage resp;
            string body;
            try
            {
                resp = await HttpClient.SendAsync(req);
                body = await resp.Content.ReadAsStringAsync();
            }
            catch (Exception ex)
            {
                throw new AliyunChannelException(AliyunErrorKind.Network, ex.Message);
            }

            if (resp.StatusCode == HttpStatusCode.Unauthorized || resp.StatusCode == HttpStatusCode.Forbidden)
                throw new AliyunChannelException(AliyunErrorKind.CookieExpired);

            var label = IsZh ? "控制台网页授权" : "Console Web Auth";
            return ParseTokenPlanResponse(body, label, AliyunChannel.Cookie);
        }

        // ---------- 令牌签发的串行化与节流 ----------

        /// <summary>串行化令牌签发，并对连续失败做节流。</summary>
        private sealed class TokenCoordinator
        {
            private readonly SemaphoreSlim _gate = new SemaphoreSlim(1, 1);
            private static readonly TimeSpan FailureCooldown = TimeSpan.FromSeconds(30);

            private string? _cachedToken;
            private DateTime _lastFailureAt = DateTime.MinValue;
            private Exception? _lastFailure;

            public async Task<string> IssueAsync(Func<Task<string>> generate, bool force = false)
            {
                await _gate.WaitAsync();
                try
                {
                    if (!force && !string.IsNullOrEmpty(_cachedToken)) return _cachedToken!;

                    // AK 填错时不要每轮刷新都去打 OpenAPI，30 秒内直接复用上次错误
                    if (_lastFailure != null && DateTime.UtcNow - _lastFailureAt < FailureCooldown)
                        throw _lastFailure;

                    try
                    {
                        var token = await generate();
                        _cachedToken = token;
                        _lastFailure = null;
                        return token;
                    }
                    catch (Exception ex)
                    {
                        _lastFailure = ex;
                        _lastFailureAt = DateTime.UtcNow;
                        throw;
                    }
                }
                finally
                {
                    _gate.Release();
                }
            }
        }
    }
}
