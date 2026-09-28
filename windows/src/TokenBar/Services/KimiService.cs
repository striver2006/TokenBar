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
    public class KimiService
    {
        public static KimiService Instance { get; } = new KimiService();

        private KimiService() { }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchQuotaAsync(
            string apiKey,
            string endpoint = "https://api.moonshot.cn/v1",
            string model = "moonshot-v1-8k",
            decimal balanceAlertThreshold = 10,
            CancellationToken ct = default)
        {
            var cleanKey = apiKey.Trim();
            if (string.IsNullOrEmpty(cleanKey))
            {
                throw new ArgumentException(LocalizationManager.Instance.IsChinese ? "请输入 KIMI / Moonshot API Key" : "Please enter KIMI / Moonshot API Key");
            }

            var baseEndpoint = ProviderShared.NormalizeEndpoint(endpoint, "https://api.moonshot.cn/v1");

            // Kimi Code 订阅模式（sk-kimi- Key / OAuth JWT / kimi coding 端点）走 coding 接口；
            // 其余按量付费 Key 保持 legacy 逻辑（余额 + /models 速率头）不变。
            if (IsCodingSubscriptionMode(cleanKey, baseEndpoint))
            {
                return await FetchCodingQuotaAsync(cleanKey, baseEndpoint, ct);
            }

            // 1. Fetch balance
            var balance = await FetchBalanceAsync(cleanKey, baseEndpoint, ct);
            string? balanceString = null;
            if (balance != null)
            {
                balanceString = $"¥{balance.Value:0.00}";
            }

            // 2. Fetch models & rate limits
            var modelsUrl = ProviderShared.ModelsUrl(baseEndpoint);

            using var req = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
            req.Headers.Add("Authorization", $"Bearer {cleanKey}");
            req.Headers.Add("Accept", "application/json");

            using var resp = await Http.Shared.SendAsync(req, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);

            ProviderHttpErrors.ThrowForStatus(resp, body, ProviderHttpErrorOptions.Kimi);

            TokenWindow? primaryWindow = null;
            TokenWindow? secondaryWindow = null;

            if (balance != null)
            {
                secondaryWindow = new TokenWindow
                {
                    Title = WindowTitle.AccountAvailableBalance,
                    Kind = TokenWindowKind.Balance,
                    BalanceAmount = balance.Value,
                    Currency = "CNY",
                    WarningThreshold = balanceAlertThreshold,
                    CriticalThreshold = balanceAlertThreshold / 2,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(30)
                };
            }

            primaryWindow = resp.BuildRateLimitWindow(RateLimitHeaderSet.OpenAI("tokens"), WindowTitle.TpmRate, "tokens");

            if (primaryWindow == null && secondaryWindow == null)
            {
                primaryWindow = TokenWindow.Status(WindowTitle.ConnectedFor("KIMI"));
            }

            var keySuffix = ProviderShared.KeySuffixMask(cleanKey);
            var isZh = LocalizationManager.Instance.IsChinese;
            var account = balanceString != null
                ? (isZh ? $"余额: {balanceString}" : $"Balance: {balanceString}")
                : (isZh ? $"KIMI (尾号 {keySuffix})" : $"KIMI (...{keySuffix})");

            return (primaryWindow, secondaryWindow, account);
        }

        /// <summary>查询 Moonshot 账户余额（人民币），失败返回 null。实现收敛到 ProviderShared，
        /// 保留 Kimi 侧差异：endpoint 跟随用户配置、available_balance 缺失时回退 cash_balance、日志前缀 "kimi"。</summary>
        private Task<decimal?> FetchBalanceAsync(string apiKey, string baseEndpoint, CancellationToken ct) =>
            ProviderShared.FetchMoonshotBalanceAsync(
                apiKey,
                $"{baseEndpoint}/users/me/balance",
                allowCashBalanceFallback: true,
                logFailurePrefix: "kimi 余额查询失败",
                ct);

        /// <summary>
        /// 判定是否走 Kimi Code 订阅模式：sk-kimi- 前缀的 Key、JWT 形态的 OAuth token，
        /// 或 endpoint 指向 kimi coding 网关（api.kimi.com / api.kimi.ai / 含 /coding）。
        /// </summary>
        internal static bool IsCodingSubscriptionMode(string apiKey, string endpoint)
        {
            if (apiKey.StartsWith("sk-kimi-", StringComparison.OrdinalIgnoreCase))
                return true;

            // OAuth token / kimi-auth JWT：恰好两个 '.' 且无空白
            if (apiKey.Count(c => c == '.') == 2 && !apiKey.Any(char.IsWhiteSpace))
                return true;

            if (endpoint.Contains("api.kimi.com", StringComparison.OrdinalIgnoreCase) ||
                endpoint.Contains("api.kimi.ai", StringComparison.OrdinalIgnoreCase) ||
                endpoint.Contains("/coding", StringComparison.OrdinalIgnoreCase))
                return true;

            return false;
        }

        /// <summary>
        /// Kimi Code 订阅模式：并发请求 /usages（主）与 /me（账号展示），
        /// 解析 5 小时滚动窗口 + 月/周长窗口。订阅制无余额概念，忽略 balanceAlertThreshold。
        /// </summary>
        private async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchCodingQuotaAsync(
            string cleanKey, string userEndpoint, CancellationToken ct)
        {
            var isZh = LocalizationManager.Instance.IsChinese;
            var codingBase = userEndpoint.Contains("/coding", StringComparison.OrdinalIgnoreCase)
                ? userEndpoint
                : "https://api.kimi.com/coding/v1";

            // /usages 是主请求（10s 超时）；/me 只用于账号显示（5s 超时，失败容忍）
            using var usagesCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            usagesCts.CancelAfter(TimeSpan.FromSeconds(10));
            var usagesTask = FetchUsagesBodyAsync(cleanKey, codingBase, usagesCts.Token);

            using var meCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            meCts.CancelAfter(TimeSpan.FromSeconds(5));
            var meTask = FetchMeBodyAsync(cleanKey, codingBase, meCts.Token);

            string usagesBody;
            try
            {
                usagesBody = await usagesTask;
            }
            catch (OperationCanceledException) when (usagesCts.IsCancellationRequested && !ct.IsCancellationRequested)
            {
                // /usages 自身超时（非外层取消）：观察掉 /me 任务后报超时
                try { await meTask; } catch { /* /me 失败不阻塞 */ }
                throw new Exception(isZh ? "KIMI 请求超时，请检查网络后重试" : "KIMI request timed out, please check your network and retry");
            }
            catch (Exception)
            {
                // 主请求失败：观察掉 /me 任务避免未观察异常后，按原样上抛
                try { await meTask; } catch { /* /me 失败不阻塞 */ }
                throw;
            }

            string? meBody = null;
            try
            {
                meBody = await meTask;
            }
            catch (OperationCanceledException) when (meCts.IsCancellationRequested && !ct.IsCancellationRequested)
            {
                Log.Warn("provider", "kimi /me 查询超时");
            }
            catch (Exception ex)
            {
                Log.Warn("provider", $"kimi /me 查询失败: {ex.Message}");
            }

            TokenWindow? fiveHour;
            TokenWindow? longWindow;
            try
            {
                using var doc = JsonDocument.Parse(usagesBody);
                (fiveHour, longWindow) = ParseCodingUsages(doc.RootElement);
            }
            catch (JsonException ex)
            {
                throw new Exception(isZh
                    ? $"KIMI 额度响应解析失败: {ex.Message}"
                    : $"Failed to parse KIMI quota response: {ex.Message}");
            }

            // HTTP 200 但两种形状都没解析到任何窗口 → 回退状态窗
            if (fiveHour == null && longWindow == null)
            {
                fiveHour = TokenWindow.Status(WindowTitle.ConnectedFor("KIMI"));
            }

            return (fiveHour, longWindow, ResolveMeAccount(meBody, cleanKey, isZh));
        }

        /// <summary>请求 {base}/usages，错误处理与 legacy 路径一致（401/429/其它非 2xx 带 body 摘要）。</summary>
        private static async Task<string> FetchUsagesBodyAsync(string apiKey, string codingBase, CancellationToken ct)
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"{codingBase}/usages");
            req.Headers.Add("Authorization", $"Bearer {apiKey}");
            req.Headers.Add("Accept", "application/json");
            // 部分账号不带 UA 会 404，必须带
            req.Headers.TryAddWithoutValidation("User-Agent", "KimiCLI/1.0.0");

            using var resp = await Http.Shared.SendAsync(req, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);

            ProviderHttpErrors.ThrowForStatus(resp, body, ProviderHttpErrorOptions.Kimi);

            return body;
        }

        /// <summary>请求 {base}/me 拿账号昵称与等级，非 2xx / 网络错误返回 null（失败不阻塞）。</summary>
        private static async Task<string?> FetchMeBodyAsync(string apiKey, string codingBase, CancellationToken ct)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Get, $"{codingBase}/me");
                req.Headers.Add("Authorization", $"Bearer {apiKey}");
                req.Headers.Add("Accept", "application/json");
                req.Headers.TryAddWithoutValidation("User-Agent", "KimiCLI/1.0.0");

                using var resp = await Http.Shared.SendAsync(req, ct);
                if (!resp.IsSuccessStatusCode) return null;
                return await resp.Content.ReadAsStringAsync(ct);
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                Log.Warn("provider", $"kimi /me 查询失败: {ex.Message}");
                return null;
            }
        }

        /// <summary>/me 成功 → "nickname (user_level_name)"，等级为空只留 nickname；失败沿用「KIMI (尾号 xxxx)」。</summary>
        private static string ResolveMeAccount(string? meBody, string cleanKey, bool isZh)
        {
            if (meBody != null)
            {
                try
                {
                    using var meDoc = JsonDocument.Parse(meBody);
                    var root = meDoc.RootElement;
                    if (root.ValueKind == JsonValueKind.Object)
                    {
                        var nickname = ReadString(root, "nickname");
                        var level = ReadString(root, "user_level_name");
                        if (!string.IsNullOrWhiteSpace(nickname))
                        {
                            return string.IsNullOrWhiteSpace(level)
                                ? nickname!
                                : $"{nickname} ({level})";
                        }
                    }
                }
                catch (JsonException ex)
                {
                    Log.Warn("provider", $"kimi /me 响应解析失败: {ex.Message}");
                }
            }

            var keySuffix = ProviderShared.KeySuffixMask(cleanKey);
            return isZh ? $"KIMI (尾号 {keySuffix})" : $"KIMI (...{keySuffix})";
        }

        /// <summary>
        /// 解析 Kimi Code /usages 的三种实测形状，5 小时窗与长窗口各自按序取第一个命中：
        /// 5小时窗：① limits[] 中 window 折算 18000 秒的项（detail 的 limit/used/resetTime 字符串数字）；
        ///          ② usages.limit_5h / limit5h（含 data.quota 嵌套）的 used_ratio。
        /// 长窗口：① usages.limit_month_total → 「月度额度」；
        ///          ② 顶层 usage 对象，resetTime 距现在 ≥20 天按「月度额度」，否则「每周额度」；
        ///          ③ usages.limit7d / limit_7d（含嵌套）→ 「每周额度」。
        /// 两种形状都没解析到任何窗口时返回 (null, null)，由调用方回退状态窗。
        /// </summary>
        internal static (TokenWindow? FiveHour, TokenWindow? LongWindow) ParseCodingUsages(JsonElement root)
        {
            if (root.ValueKind != JsonValueKind.Object)
                return (null, null);

            TokenWindow? fiveHour = ParseFiveHourFromLimits(root) ?? ParseFiveHourFromUsages(root);
            TokenWindow? longWindow = ParseMonthlyFromUsages(root)
                ?? ParseTopLevelUsageWindow(root)
                ?? ParseSevenDayFromUsages(root);
            return (fiveHour, longWindow);
        }

        /// <summary>取 usages 对象：优先根级 usages，兼容 OAuth 旧形状嵌套在 data.quota 里。</summary>
        private static JsonElement? FindUsagesObject(JsonElement root)
        {
            if (root.TryGetProperty("usages", out var usages) && usages.ValueKind == JsonValueKind.Object)
                return usages;
            if (root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object &&
                data.TryGetProperty("quota", out var quota) && quota.ValueKind == JsonValueKind.Object &&
                quota.TryGetProperty("usages", out var nested) && nested.ValueKind == JsonValueKind.Object)
                return nested;
            return null;
        }

        /// <summary>5小时窗形状①：limits[] 里 window 折算 18000 秒的项，detail 给字符串数字的 limit/used。</summary>
        private static TokenWindow? ParseFiveHourFromLimits(JsonElement root)
        {
            if (!root.TryGetProperty("limits", out var limits) || limits.ValueKind != JsonValueKind.Array)
                return null;

            foreach (var item in limits.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object ||
                    !item.TryGetProperty("window", out var window) || window.ValueKind != JsonValueKind.Object ||
                    !window.TryGetProperty("duration", out var durationProp))
                    continue;

                double duration;
                if (durationProp.ValueKind == JsonValueKind.Number)
                {
                    duration = durationProp.GetDouble();
                }
                else if (durationProp.ValueKind == JsonValueKind.String &&
                         double.TryParse(durationProp.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsedDuration))
                {
                    duration = parsedDuration;
                }
                else
                {
                    continue;
                }

                var timeUnit = window.TryGetProperty("timeUnit", out var unitProp) && unitProp.ValueKind == JsonValueKind.String
                    ? unitProp.GetString()
                    : null;
                var durationSec = timeUnit switch
                {
                    "TIME_UNIT_SECOND" or "SECOND" => duration,
                    "TIME_UNIT_MINUTE" or "MINUTE" => duration * 60,
                    "TIME_UNIT_HOUR" or "HOUR" => duration * 3600,
                    "TIME_UNIT_DAY" or "DAY" => duration * 86400,
                    _ => -1.0,
                };
                if (durationSec != 18000)
                    continue;

                if (!item.TryGetProperty("detail", out var detail) || detail.ValueKind != JsonValueKind.Object)
                    continue;

                var limit = ReadDouble(detail, "limit");
                var used = ReadDouble(detail, "used");
                if (limit == null || used == null || limit.Value <= 0)
                    continue;

                var resetAt = ParseIsoTime(ReadString(detail, "resetTime"));
                var now = DateTime.Now;
                return new TokenWindow
                {
                    Title = WindowTitle.FiveHour,
                    UsedPercentage = Math.Clamp(used.Value / limit.Value * 100.0, 0.0, 100.0),
                    StartTime = now,
                    EndTime = resetAt ?? now.AddHours(5),
                    UsedAmount = used.Value,
                    TotalLimit = limit.Value,
                    Unit = "次",
                    IsIdle = used.Value == 0.0
                };
            }

            return null;
        }

        /// <summary>5小时窗形状②：usages.limit_5h / limit5h（含 data.quota 嵌套）的 used_ratio。</summary>
        private static TokenWindow? ParseFiveHourFromUsages(JsonElement root)
        {
            var usages = FindUsagesObject(root);
            if (usages == null)
                return null;

            JsonElement? entry = null;
            if (usages.Value.TryGetProperty("limit_5h", out var a) && a.ValueKind == JsonValueKind.Object)
                entry = a;
            else if (usages.Value.TryGetProperty("limit5h", out var b) && b.ValueKind == JsonValueKind.Object)
                entry = b;

            return entry.HasValue
                ? BuildRatioWindow(WindowTitle.FiveHour, entry.Value, TimeSpan.FromHours(5))
                : null;
        }

        /// <summary>长窗口形状①：usages.limit_month_total → 「月度额度」。</summary>
        private static TokenWindow? ParseMonthlyFromUsages(JsonElement root)
        {
            var usages = FindUsagesObject(root);
            if (usages == null)
                return null;

            return usages.Value.TryGetProperty("limit_month_total", out var entry) && entry.ValueKind == JsonValueKind.Object
                ? BuildRatioWindow(WindowTitle.Monthly, entry, TimeSpan.FromDays(30))
                : null;
        }

        /// <summary>长窗口形状②：顶层 usage（7 天老套餐字符串数字）；resetTime 距现在 ≥20 天按「月度额度」，否则「每周额度」。</summary>
        private static TokenWindow? ParseTopLevelUsageWindow(JsonElement root)
        {
            if (!root.TryGetProperty("usage", out var usage) || usage.ValueKind != JsonValueKind.Object)
                return null;

            var limit = ReadDouble(usage, "limit");
            var used = ReadDouble(usage, "used");
            if (limit == null || used == null || limit.Value <= 0)
                return null;

            var resetAt = ParseIsoTime(ReadString(usage, "resetTime"));
            var usedPct = Math.Clamp(used.Value / limit.Value * 100.0, 0.0, 100.0);
            var now = DateTime.Now;
            return new TokenWindow
            {
                Title = resetAt.HasValue && (resetAt.Value - now).TotalDays >= 20 ? WindowTitle.Monthly : WindowTitle.Weekly,
                UsedPercentage = usedPct,
                StartTime = now,
                EndTime = resetAt ?? now.AddDays(7),
                UsedAmount = used.Value,
                TotalLimit = limit.Value,
                Unit = "次",
                IsIdle = usedPct == 0.0
            };
        }

        /// <summary>长窗口形状③：usages.limit7d / limit_7d（含嵌套）→ 「每周额度」。</summary>
        private static TokenWindow? ParseSevenDayFromUsages(JsonElement root)
        {
            var usages = FindUsagesObject(root);
            if (usages == null)
                return null;

            JsonElement? entry = null;
            if (usages.Value.TryGetProperty("limit7d", out var a) && a.ValueKind == JsonValueKind.Object)
                entry = a;
            else if (usages.Value.TryGetProperty("limit_7d", out var b) && b.ValueKind == JsonValueKind.Object)
                entry = b;

            return entry.HasValue
                ? BuildRatioWindow(WindowTitle.Weekly, entry.Value, TimeSpan.FromDays(7))
                : null;
        }

        /// <summary>used_ratio / usedRatio（0..1 比例，兼容字符串数字）×100 构造比例窗口；reset_time / resetAt 取重置时间。</summary>
        private static TokenWindow? BuildRatioWindow(WindowTitle title, JsonElement entry, TimeSpan fallbackDuration)
        {
            var ratio = ReadDouble(entry, "used_ratio") ?? ReadDouble(entry, "usedRatio");
            if (ratio == null)
                return null;

            var resetText = ReadString(entry, "reset_time") ?? ReadString(entry, "resetAt");
            var resetAt = ParseIsoTime(resetText);
            var usedPct = Math.Clamp(ratio.Value * 100.0, 0.0, 100.0);
            var now = DateTime.Now;
            return new TokenWindow
            {
                Title = title,
                UsedPercentage = usedPct,
                StartTime = now,
                EndTime = resetAt ?? now.Add(fallbackDuration),
                Unit = "%",
                IsIdle = usedPct == 0.0
            };
        }

        /// <summary>读字段为 double：JSON 数字或字符串数字（Float | AllowThousands，不变区域）。</summary>
        private static double? ReadDouble(JsonElement obj, string name)
        {
            if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(name, out var prop))
                return null;
            if (prop.ValueKind == JsonValueKind.Number && prop.TryGetDouble(out var num))
                return num;
            if (prop.ValueKind == JsonValueKind.String &&
                double.TryParse(prop.GetString(), NumberStyles.Float | NumberStyles.AllowThousands, CultureInfo.InvariantCulture, out var parsed))
                return parsed;
            return null;
        }

        /// <summary>读字符串字段，非字符串或缺省返回 null。</summary>
        private static string? ReadString(JsonElement obj, string name)
        {
            if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(name, out var prop))
                return null;
            return prop.ValueKind == JsonValueKind.String ? prop.GetString() : null;
        }

        /// <summary>解析 ISO 时间（纳秒小数 + Z 与整秒 + Z 均可），统一按 UTC 解释后换算成本地时间。</summary>
        private static DateTime? ParseIsoTime(string? text)
        {
            if (string.IsNullOrWhiteSpace(text))
                return null;
            if (DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var dto))
                return dto.LocalDateTime;
            return null;
        }
    }
}
