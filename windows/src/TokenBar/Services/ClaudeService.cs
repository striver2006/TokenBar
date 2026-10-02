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
    public class ClaudeService
    {
        public static ClaudeService Instance { get; } = new ClaudeService();

        private ClaudeService() { }

        public (TokenWindow? FiveHour, TokenWindow? Weekly, TokenWindow? ScopedWeekly, string? Account, DateTime? FetchedAt)? ReadLocalClaudeJson()
        {
            var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var claudeJsonPath = Path.Combine(userProfile, ".claude.json");

            if (!File.Exists(claudeJsonPath))
            {
                return null;
            }

            try
            {
                var content = File.ReadAllText(claudeJsonPath);
                return ParseLocalClaudeJson(content, DateTime.Now);
            }
            catch (Exception ex)
            {
                Log.Warn("provider", $"读取 ~/.claude.json 失败: {ex.Message}");
                return null;
            }
        }

        /// <summary>
        /// ~/.claude.json 内容 → 窗口/账号 的纯解析（与 mac 端 ClaudeService.parseLocalClaudeJson 同语义）。
        /// 不读文件、不打日志；now 由调用方注入（生产传 DateTime.Now），JSON 非法时抛 JsonException 由调用方兜底。
        /// FetchedAt 是 Claude Code 写缓存时记下的 fetchedAtMs（本地时刻）：这份缓存只在 Claude Code 自己
        /// 查用量（/usage、桌面端 get_usage）时才更新，可能比本轮刷新旧几个小时，展示时必须带上它。
        /// </summary>
        internal static (TokenWindow? FiveHour, TokenWindow? Weekly, TokenWindow? ScopedWeekly, string? Account, DateTime? FetchedAt)? ParseLocalClaudeJson(string json, DateTime now)
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            string? accountEmail = null;
            if (root.TryGetProperty("oauthAccount", out var oauthAccount))
            {
                if (oauthAccount.TryGetProperty("emailAddress", out var emailProp))
                {
                    accountEmail = emailProp.GetString();
                }
                else if (oauthAccount.TryGetProperty("displayName", out var nameProp))
                {
                    accountEmail = nameProp.GetString();
                }
            }

            if (!root.TryGetProperty("cachedUsageUtilization", out var cached) ||
                !cached.TryGetProperty("utilization", out var utilization))
            {
                // If account logged in but no cached utilization yet, create clean initial 5h window
                var initialFiveHour = new TokenWindow
                {
                    Title = WindowTitle.FiveHour,
                    UsedPercentage = 0.0,
                    StartTime = now,
                    EndTime = now.AddHours(5),
                    Unit = "%",
                    IsIdle = true
                };
                return (initialFiveHour, null, null, accountEmail, null);
            }

            DateTime? fetchedAt = null;
            if (cached.TryGetProperty("fetchedAtMs", out var fetchedProp) &&
                fetchedProp.ValueKind == JsonValueKind.Number &&
                fetchedProp.TryGetDouble(out var fetchedMs) &&
                fetchedMs > 0 && fetchedMs < 253_402_300_799_999) // FromUnixTimeMilliseconds 的上限，越界会抛
            {
                fetchedAt = DateTimeOffset.FromUnixTimeMilliseconds((long)fetchedMs).LocalDateTime;
            }

            TokenWindow? fiveHourWindow = null;
            TokenWindow? weeklyWindow = null;

            // 1. Parse 5-hour session window
            if (utilization.TryGetProperty("five_hour", out var fiveHour))
            {
                double util = 0.0;
                if (fiveHour.TryGetProperty("utilization", out var utilProp))
                {
                    util = utilProp.GetDouble();
                }

                string? resetsAtStr = null;
                if (fiveHour.TryGetProperty("resets_at", out var resetsAtProp) &&
                    resetsAtProp.ValueKind == JsonValueKind.String)
                {
                    resetsAtStr = resetsAtProp.GetString();
                }

                if (!string.IsNullOrEmpty(resetsAtStr) && TryParseUtc(resetsAtStr, out var resetsAt))
                {
                    if (resetsAt > now)
                    {
                        fiveHourWindow = new TokenWindow
                        {
                            Title = WindowTitle.FiveHour,
                            UsedPercentage = util,
                            StartTime = resetsAt.AddHours(-5),
                            EndTime = resetsAt,
                            Unit = "%",
                            IsIdle = false
                        };
                    }
                    else
                    {
                        fiveHourWindow = new TokenWindow
                        {
                            Title = WindowTitle.FiveHour,
                            UsedPercentage = 0.0,
                            StartTime = now,
                            EndTime = now.AddHours(5),
                            Unit = "%",
                            IsIdle = true
                        };
                    }
                }
                else
                {
                    fiveHourWindow = new TokenWindow
                    {
                        Title = WindowTitle.FiveHour,
                        UsedPercentage = util,
                        StartTime = now,
                        EndTime = now.AddHours(5),
                        Unit = "%",
                        IsIdle = true
                    };
                }
            }

            // Fallback from limits array if fiveHourWindow is still null
            if (fiveHourWindow == null && utilization.TryGetProperty("limits", out var limits) && limits.ValueKind == JsonValueKind.Array)
            {
                foreach (var limit in limits.EnumerateArray())
                {
                    var kind = limit.TryGetProperty("kind", out var kp) ? kp.GetString() : null;
                    var group = limit.TryGetProperty("group", out var gp) ? gp.GetString() : null;

                    if (kind == "session" || group == "session")
                    {
                        var pct = limit.TryGetProperty("percent", out var pp) ? pp.GetDouble() : 0.0;
                        fiveHourWindow = new TokenWindow
                        {
                            Title = WindowTitle.FiveHour,
                            UsedPercentage = pct,
                            StartTime = now,
                            EndTime = now.AddHours(5),
                            Unit = "%",
                            IsIdle = pct == 0.0
                        };
                        break;
                    }
                }
            }

            if (fiveHourWindow == null)
            {
                fiveHourWindow = new TokenWindow
                {
                    Title = WindowTitle.FiveHour,
                    UsedPercentage = 0.0,
                    StartTime = now,
                    EndTime = now.AddHours(5),
                    Unit = "%",
                    IsIdle = true
                };
            }

            // 2. Parse 7-day weekly window
            if (utilization.TryGetProperty("seven_day", out var sevenDay))
            {
                double util = 0.0;
                if (sevenDay.TryGetProperty("utilization", out var utilProp))
                {
                    util = utilProp.GetDouble();
                }

                string? resetsAtStr = null;
                if (sevenDay.TryGetProperty("resets_at", out var resetsAtProp) &&
                    resetsAtProp.ValueKind == JsonValueKind.String)
                {
                    resetsAtStr = resetsAtProp.GetString();
                }

                if (!string.IsNullOrEmpty(resetsAtStr) && TryParseUtc(resetsAtStr, out var resetsAt))
                {
                    weeklyWindow = new TokenWindow
                    {
                        Title = WindowTitle.Weekly,
                        UsedPercentage = util,
                        StartTime = resetsAt.AddDays(-7),
                        EndTime = resetsAt,
                        Unit = "%",
                        IsIdle = false
                    };
                }
            }

            if (weeklyWindow == null && utilization.TryGetProperty("limits", out var limitsWeekly) && limitsWeekly.ValueKind == JsonValueKind.Array)
            {
                foreach (var limit in limitsWeekly.EnumerateArray())
                {
                    var kind = limit.TryGetProperty("kind", out var kp) ? kp.GetString() : null;
                    var group = limit.TryGetProperty("group", out var gp) ? gp.GetString() : null;

                    if (kind == "weekly_all" || group == "weekly")
                    {
                        var pct = limit.TryGetProperty("percent", out var pp) ? pp.GetDouble() : 0.0;
                        var resetsAtStr = limit.TryGetProperty("resets_at", out var rp) ? rp.GetString() : null;
                        var resetsAt = now.AddDays(7);
                        if (!string.IsNullOrEmpty(resetsAtStr) && TryParseUtc(resetsAtStr, out var parsedReset))
                        {
                            resetsAt = parsedReset;
                        }

                        weeklyWindow = new TokenWindow
                        {
                            Title = WindowTitle.Weekly,
                            UsedPercentage = pct,
                            StartTime = resetsAt.AddDays(-7),
                            EndTime = resetsAt,
                            Unit = "%",
                            IsIdle = false
                        };
                        break;
                    }
                }
            }

            // 按模型圈定的周额度（如 Fable）：weekly fallback 取 first(group == "weekly")
            // 仍命中 weekly_all 而非 weekly_scoped，互不干扰
            var scopedWeeklyWindow = ParseScopedWeeklyLimit(utilization, now);

            return (fiveHourWindow, weeklyWindow, scopedWeeklyWindow, accountEmail, fetchedAt);
        }

        /// <summary>
        /// 解析 ISO8601 / RFC3339 时间戳为本地时间。无时区后缀时按 UTC 理解
        /// （AssumeUniversal），有后缀时按后缀换算（AdjustToUniversal 再转本地）。
        /// </summary>
        internal static bool TryParseUtc(string? text, out DateTime local)
        {
            local = default;
            if (string.IsNullOrWhiteSpace(text)) return false;
            if (DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var dto))
            {
                local = dto.LocalDateTime;
                return true;
            }
            return false;
        }

        /// <summary>
        /// 从 limits[] 里解析按模型圈定的周额度（如 Fable / Opus 专属周额度）。
        /// 条目形如 {kind: "weekly_scoped", percent: 42, resets_at: ..., scope: {model: {display_name: "Fable"}}}。
        /// display_name 缺失的条目给不出有意义的标题，跳过；取第一条匹配。
        /// </summary>
        internal static TokenWindow? ParseScopedWeeklyLimit(JsonElement parent, DateTime now)
        {
            if (!parent.TryGetProperty("limits", out var limits) || limits.ValueKind != JsonValueKind.Array)
            {
                return null;
            }

            foreach (var limit in limits.EnumerateArray())
            {
                if (!limit.TryGetProperty("kind", out var kind) || kind.GetString() != "weekly_scoped")
                {
                    continue;
                }

                if (!limit.TryGetProperty("scope", out var scope) ||
                    !scope.TryGetProperty("model", out var model) ||
                    !model.TryGetProperty("display_name", out var displayNameProp))
                {
                    continue;
                }

                var displayName = displayNameProp.GetString();
                if (string.IsNullOrEmpty(displayName))
                {
                    continue;
                }

                var pct = limit.TryGetProperty("percent", out var pp) ? pp.GetDouble() : 0.0;
                var resetsAtStr = limit.TryGetProperty("resets_at", out var rp) ? rp.GetString() : null;
                var resetsAt = now.AddDays(7);
                if (!string.IsNullOrEmpty(resetsAtStr) && TryParseUtc(resetsAtStr, out var parsedReset))
                {
                    resetsAt = parsedReset;
                }

                return new TokenWindow
                {
                    Title = WindowTitle.Custom(displayName),
                    UsedPercentage = pct,
                    StartTime = resetsAt.AddDays(-7),
                    EndTime = resetsAt,
                    Unit = "%",
                    IsIdle = false
                };
            }

            return null;
        }

        // MARK: - Claude Code 自己的 OAuth 凭证

        /// <summary>
        /// 读 Claude Code 的 OAuth 凭证。Windows 上 Claude Code 把它明文存在 %USERPROFILE%\.claude\.credentials.json
        /// （mac 端在钥匙串 "Claude Code-credentials"）。文件不存在或格式不符返回 null，由调用方退回本地缓存。
        /// </summary>
        public ClaudeCodeCredential? ReadClaudeCodeCredential()
        {
            var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var path = Path.Combine(userProfile, ".claude", ".credentials.json");
            if (!File.Exists(path)) return null;

            try
            {
                return ParseClaudeCodeCredential(File.ReadAllText(path));
            }
            catch (Exception ex)
            {
                Log.Warn("provider", $"读取 Claude Code 凭证失败: {ex.Message}");
                return null;
            }
        }

        /// <summary>
        /// 解析 Claude Code 的凭证 JSON：{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt"(毫秒), ...}}。
        /// 与 mac 端 ClaudeService.parseClaudeCodeCredential 同语义。
        ///
        /// **只取 accessToken**。refreshToken 归 Claude Code 所有且每次使用都会轮换，TokenBar 拿它换新 token
        /// 会让 Claude Code 手里那枚作废——它遇到 invalid_grant 会清空本地凭证，等于把用户登出。
        /// 所以 access token 过期后只能等 Claude Code 自己续期，期间退回本地缓存。
        /// </summary>
        internal static ClaudeCodeCredential? ParseClaudeCodeCredential(string json)
        {
            try
            {
                using var doc = JsonDocument.Parse(json);
                if (doc.RootElement.ValueKind != JsonValueKind.Object ||
                    !doc.RootElement.TryGetProperty("claudeAiOauth", out var oauth) ||
                    oauth.ValueKind != JsonValueKind.Object ||
                    !oauth.TryGetProperty("accessToken", out var tokenProp) ||
                    tokenProp.ValueKind != JsonValueKind.String)
                {
                    return null;
                }

                var token = tokenProp.GetString()?.Trim();
                if (string.IsNullOrEmpty(token)) return null;

                DateTime? expiresAt = null;
                if (oauth.TryGetProperty("expiresAt", out var expProp) &&
                    expProp.ValueKind == JsonValueKind.Number &&
                    expProp.TryGetDouble(out var expMs) &&
                    expMs > 0 && expMs < 253_402_300_799_999) // FromUnixTimeMilliseconds 的上限，越界会抛
                {
                    expiresAt = DateTimeOffset.FromUnixTimeMilliseconds((long)expMs).LocalDateTime;
                }

                return new ClaudeCodeCredential(token, expiresAt);
            }
            catch (JsonException)
            {
                return null;
            }
        }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, TokenWindow? ScopedWeekly, string? Account)> FetchRemoteUsageAsync(string token, CancellationToken ct = default)
        {
            var cleanToken = token.Trim();
            using var req = new HttpRequestMessage(HttpMethod.Get, "https://api.anthropic.com/api/oauth/usage");
            req.Headers.Add("Authorization", $"Bearer {cleanToken}");
            req.Headers.Add("anthropic-beta", "oauth-2025-04-20");
            req.Headers.Add("User-Agent", "claude-code/2.1.263");
            req.Headers.Add("Accept", "application/json");

            using var resp = await Http.Shared.SendAsync(req, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);

            if (!resp.IsSuccessStatusCode)
            {
                throw new Exception($"HTTP {(int)resp.StatusCode}: {body}");
            }

            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;

            TokenWindow? fiveHourWindow = null;
            TokenWindow? weeklyWindow = null;

            if (root.TryGetProperty("five_hour", out var fiveHour))
            {
                double util = fiveHour.TryGetProperty("utilization", out var u) ? u.GetDouble() : 0.0;
                string? resetsAtStr = fiveHour.TryGetProperty("resets_at", out var r) ? r.GetString() : null;

                if (!string.IsNullOrEmpty(resetsAtStr) && TryParseUtc(resetsAtStr, out var resetsAt))
                {
                    if (resetsAt > DateTime.Now)
                    {
                        fiveHourWindow = new TokenWindow
                        {
                            Title = WindowTitle.FiveHour,
                            UsedPercentage = util,
                            StartTime = resetsAt.AddHours(-5),
                            EndTime = resetsAt,
                            Unit = "%",
                            IsIdle = false
                        };
                    }
                    else
                    {
                        var now = DateTime.Now;
                        fiveHourWindow = new TokenWindow
                        {
                            Title = WindowTitle.FiveHour,
                            UsedPercentage = 0.0,
                            StartTime = now,
                            EndTime = now.AddHours(5),
                            Unit = "%",
                            IsIdle = true
                        };
                    }
                }
                else
                {
                    var now = DateTime.Now;
                    fiveHourWindow = new TokenWindow
                    {
                        Title = WindowTitle.FiveHour,
                        UsedPercentage = util,
                        StartTime = now,
                        EndTime = now.AddHours(5),
                        Unit = "%",
                        IsIdle = true
                    };
                }
            }

            if (fiveHourWindow == null)
            {
                var now = DateTime.Now;
                fiveHourWindow = new TokenWindow
                {
                    Title = WindowTitle.FiveHour,
                    UsedPercentage = 0.0,
                    StartTime = now,
                    EndTime = now.AddHours(5),
                    Unit = "%",
                    IsIdle = true
                };
            }

            if (root.TryGetProperty("seven_day", out var sevenDay))
            {
                double util = sevenDay.TryGetProperty("utilization", out var u) ? u.GetDouble() : 0.0;
                string? resetsAtStr = sevenDay.TryGetProperty("resets_at", out var r) ? r.GetString() : null;

                if (!string.IsNullOrEmpty(resetsAtStr) && TryParseUtc(resetsAtStr, out var resetsAt))
                {
                    weeklyWindow = new TokenWindow
                    {
                        Title = WindowTitle.Weekly,
                        UsedPercentage = util,
                        StartTime = resetsAt.AddDays(-7),
                        EndTime = resetsAt,
                        Unit = "%",
                        IsIdle = false
                    };
                }
            }

            // 与 cachedUsageUtilization 同构；若暂未下发 limits 字段则自然为 null，由调用方回落本地缓存
            var scopedWeeklyWindow = ParseScopedWeeklyLimit(root, DateTime.Now);

            return (fiveHourWindow, weeklyWindow, scopedWeeklyWindow, null);
        }

        public async Task<(TokenWindow? Primary, TokenWindow? Secondary, string? Account)> FetchAnthropicQuotaAsync(
            string apiKey,
            string endpoint = "https://api.anthropic.com/v1",
            CancellationToken ct = default)
        {
            var cleanKey = apiKey.Trim();
            if (string.IsNullOrEmpty(cleanKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? "请输入 Anthropic API Key" : "Please enter Anthropic API Key");
            }

            var baseEndpoint = ProviderShared.NormalizeEndpoint(endpoint, "https://api.anthropic.com/v1");

            var modelsUrl = ProviderShared.ModelsUrl(baseEndpoint);

            using var req = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
            req.Headers.Add("x-api-key", cleanKey);
            req.Headers.Add("anthropic-version", "2023-06-01");
            req.Headers.Add("Accept", "application/json");

            using var resp = await Http.Shared.SendAsync(req, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);

            ProviderHttpErrors.ThrowForStatus(resp, body, ProviderHttpErrorOptions.Anthropic);

            TokenWindow? primaryWindow = resp.BuildRateLimitWindow(
                RateLimitHeaderSet.AnthropicFixedWindow("tokens"), WindowTitle.TpmRate, "tokens");

            TokenWindow? secondaryWindow = resp.BuildRateLimitWindow(
                RateLimitHeaderSet.AnthropicFixedWindow("requests"), WindowTitle.RpmRate, "req/min");

            if (primaryWindow == null && secondaryWindow == null)
            {
                primaryWindow = TokenWindow.Status(WindowTitle.ConnectedFor("Anthropic API"));
            }

            var keySuffix = ProviderShared.KeySuffixMask(cleanKey);
            var account = LocalizationManager.Instance.IsChinese ? $"Anthropic API (尾号 {keySuffix})" : $"Anthropic API (...{keySuffix})";

            return (primaryWindow, secondaryWindow, account);
        }
    }

    /// <summary>Claude Code 登录凭证里 TokenBar 用得上的部分。与 mac 端 ClaudeCodeCredential 同语义。</summary>
    /// <param name="AccessToken">OAuth access token</param>
    /// <param name="ExpiresAt">过期时刻（本地）；null 表示凭证里没有，视为可用（401 时自然退回缓存）</param>
    public sealed record ClaudeCodeCredential(string AccessToken, DateTime? ExpiresAt)
    {
        /// <summary>离过期不足 60 秒就不用了：请求在途中过期只会换来一个 401</summary>
        public bool IsUsable(DateTime now) =>
            ExpiresAt is not DateTime expiresAt || (expiresAt - now).TotalSeconds > 60;
    }
}
