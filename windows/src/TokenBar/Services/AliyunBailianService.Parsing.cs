using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using TokenBar.I18n;
using TokenBar.Models;

namespace TokenBar.Services
{
    /// <summary>
    /// Token Plan 用量响应的解析、凭证装配与账户余额。
    ///
    /// 同一套解析要吃下三种嵌套形状：
    /// 1. bl --output json 的扁平输出：{"per1WeekPercentage":0.125,...}
    /// 2. Cookie 网关 /data/api.json：{"data":{"data":{...}}}
    /// 3. Bearer 网关 /cli/api.json：{"data":{"DataV2":{"data":{"data":{...}}}}}
    ///
    /// 须与 mac 端 AliyunBailianService+Parsing.swift 行为一致。
    /// </summary>
    public partial class AliyunBailianService
    {
        // ---------- 信封错误 ----------

        /// <summary>剥壳之前先判信封层的错误。返回 null 表示这是一个成功响应。</summary>
        internal static AliyunChannelException? DetectEnvelopeError(JsonObject root)
        {
            // CLI 的错误信封
            if (root["error"] is JsonObject errorObj)
            {
                var message = StringValue(errorObj["message"]) ?? "";
                var hint = StringValue(errorObj["hint"]) ?? "";
                if (message.Contains("not logged in", StringComparison.OrdinalIgnoreCase)
                    || hint.Contains("auth login", StringComparison.OrdinalIgnoreCase)
                    || message.Contains("NotLogined", StringComparison.Ordinal))
                {
                    return new AliyunChannelException(AliyunErrorKind.NotLogined);
                }
                var detail = string.Join(" — ", new[] { message, hint }.Where(x => !string.IsNullOrEmpty(x)));
                return new AliyunChannelException(AliyunErrorKind.CliFailed, detail);
            }

            // 网关的错误信封：判定落在顶层 data 上
            if (root["data"] is JsonObject data
                && data["success"] is JsonValue successValue
                && successValue.TryGetValue<bool>(out var success) && !success)
            {
                var code = StringValue(data["errorCode"]) ?? "";
                var message = StringValue(data["errorMsg"]) ?? "";
                if (code.Contains("NotLogined", StringComparison.Ordinal))
                    return new AliyunChannelException(AliyunErrorKind.NotLogined);
                if (code.Contains("Forbidden", StringComparison.Ordinal)
                    || code.Contains("NoPermission", StringComparison.Ordinal)
                    || code.Contains("RAM", StringComparison.Ordinal))
                    return new AliyunChannelException(AliyunErrorKind.NoPermission, $"{code} {message}".Trim());

                return new AliyunChannelException(
                    AliyunErrorKind.GatewayError, message, string.IsNullOrEmpty(code) ? "Unknown" : code);
            }

            return null;
        }

        // ---------- 剥壳 ----------

        /// <summary>官方 bailian-cli-core 的 unwrap 逻辑，外加一层 BFS 兜底。</summary>
        internal static JsonObject UnwrapTokenPlanPayload(JsonObject root)
        {
            var payload = root;
            if (root["data"] is JsonObject data)
            {
                if (data["DataV2"] is JsonObject dataV2)
                {
                    payload = dataV2["data"] is JsonObject inner
                        ? (inner["data"] as JsonObject ?? inner)
                        : dataV2;
                }
                else
                {
                    payload = data["data"] as JsonObject ?? data;
                }
            }
            if (HasAnyQuotaKey(payload)) return payload;

            // 官方 unwrap 只覆盖已知的三层。网关将来再加一层壳时，BFS 兜底能自愈。
            return FirstObjectContainingQuotaKeys(root, maxDepth: 6) ?? payload;
        }

        internal static bool HasAnyQuotaKey(JsonObject obj)
            => QuotaKeys.Any(k => obj.ContainsKey(k));

        /// <summary>广度优先找第一个含额度字段的对象，限制深度避免病态输入下遍历过久。</summary>
        internal static JsonObject? FirstObjectContainingQuotaKeys(JsonObject root, int maxDepth)
        {
            var queue = new Queue<(JsonObject Obj, int Depth)>();
            queue.Enqueue((root, 0));

            while (queue.Count > 0)
            {
                var (current, depth) = queue.Dequeue();
                if (HasAnyQuotaKey(current)) return current;
                if (depth >= maxDepth) continue;

                foreach (var kv in current)
                {
                    switch (kv.Value)
                    {
                        case JsonObject child:
                            queue.Enqueue((child, depth + 1));
                            break;
                        case JsonArray array:
                            foreach (var element in array)
                                if (element is JsonObject arrayChild) queue.Enqueue((arrayChild, depth + 1));
                            break;
                    }
                }
            }
            return null;
        }

        // ---------- 宽松取值 ----------

        /// <summary>数字 / 数字字符串都吃；null、布尔与非数字返回 null（而不是抛错）。</summary>
        internal static double? DoubleValue(JsonNode? node)
        {
            if (node is not JsonValue value) return null;
            if (value.TryGetValue<double>(out var d)) return d;
            if (value.TryGetValue<string>(out var s)
                && double.TryParse(s.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed))
                return parsed;
            return null;
        }

        internal static string? StringValue(JsonNode? node)
        {
            if (node is not JsonValue value) return null;
            if (value.TryGetValue<string>(out var s)) return s;
            if (value.TryGetValue<double>(out var d)) return d.ToString(CultureInfo.InvariantCulture);
            return null;
        }

        // ---------- 主解析 ----------

        public static AliyunQuotaResult ParseTokenPlanResponse(
            string json, string accountLabel, AliyunChannel channel)
        {
            JsonObject root;
            try
            {
                root = JsonNode.Parse(json) as JsonObject
                    ?? throw new AliyunChannelException(AliyunErrorKind.UnexpectedFormat, Truncate(json));
            }
            catch (AliyunChannelException) { throw; }
            catch
            {
                throw new AliyunChannelException(AliyunErrorKind.UnexpectedFormat, Truncate(json));
            }

            var envelopeError = DetectEnvelopeError(root);
            if (envelopeError != null) throw envelopeError;

            var payload = UnwrapTokenPlanPayload(root);
            var weekly = MakeWindow("7天周期额度",
                DoubleValue(payload["per1WeekPercentage"]),
                DoubleValue(payload["per1WeekResetTime"]),
                TimeSpan.FromDays(7));
            var fiveHour = MakeWindow("5小时额度",
                DoubleValue(payload["per5HourPercentage"]),
                DoubleValue(payload["per5HourResetTime"]),
                TimeSpan.FromHours(5));

            // 两个窗口都没数据不是错误 —— 官方 CLI 在这种情况下显示「该窗口可能不限量」。
            // 只要信封层是成功的，就照样算已授权，把说明放进 Note。
            string? note = null;
            if (weekly == null && fiveHour == null)
            {
                note = IsZh
                    ? "本周期未返回限额数据（该窗口可能不限量），可在百炼 Token Plan 控制台核对。"
                    : "No quota figures returned for this period (the window may be unlimited). Check the Bailian Token Plan console.";
            }

            return new AliyunQuotaResult
            {
                FiveHour = fiveHour,
                Weekly = weekly,
                Account = accountLabel,
                Note = note,
                Channel = channel
            };
        }

        private static string Truncate(string s) => s.Length > 200 ? s.Substring(0, 200) : s;

        /// <summary>百分比是 0~1 的小数，重置时间是 epoch 毫秒。</summary>
        internal static TokenWindow? MakeWindow(
            string title, double? percentage, double? resetMilliseconds, TimeSpan duration)
        {
            if (!percentage.HasValue) return null;

            var usedPct = Math.Clamp(percentage.Value * 100.0, 0.0, 100.0);
            var resetDate = resetMilliseconds.HasValue && resetMilliseconds.Value > 0
                ? DateTimeOffset.FromUnixTimeMilliseconds((long)resetMilliseconds.Value).LocalDateTime
                : DateTime.Now.Add(duration);

            return new TokenWindow
            {
                Title = title,
                UsedPercentage = usedPct,
                StartTime = resetDate.Subtract(duration),
                EndTime = resetDate,
                Unit = "%",
                IsIdle = usedPct == 0.0
            };
        }

        // ---------- 凭证装配 ----------

        /// <summary>
        /// 从设置项、安全存储和本机 bl 配置装配出一次查询所需的凭证。
        ///
        /// AccessKey Secret 与控制台令牌只来自 SecretStore —— 刻意不在 AppSettings 里留明文回退位，
        /// 安全存储写不进去时宁可如实报错，也不把账号级长期凭证落到明文配置里。
        ///
        /// 本机若已 bl auth login，在允许复用的前提下借用其令牌与 AK/SK；
        /// 借来的凭证只在内存里用，绝不写回 %USERPROFILE%\.bailian\config.json。
        /// </summary>
        /// <param name="secretStore">
        /// **必须**传入已经在后台读好的内存快照（CredentialSecretStore.PrefetchAsync 的返回值）。
        /// 刻意不再回退到 CredentialSecretStore.Instance：那会让这个同步函数在调用线程上
        /// 阻塞等凭据管理器，把最危险的选项做成打字最少的选项。与 mac 端 resolveCredentials 一致。
        /// </param>
        public static AliyunCredentials ResolveCredentials(
            AppSettings settings,
            ISecretStore secretStore,
            BailianCliConfig? cliConfig = null)
        {
            var store = secretStore;
            var reusable = settings.AliyunReuseCliConfig
                ? (cliConfig ?? BailianCliConfig.LoadFromDisk())
                : null;

            var region = settings.AliyunConsoleRegion?.Trim();
            var site = settings.AliyunConsoleSite?.Trim();

            var credentials = new AliyunCredentials
            {
                AccessKeyId = settings.AliyunAccessKeyId?.Trim() ?? string.Empty,
                AccessKeySecret = store.Get(SecretKey.AliyunAccessKeySecret)?.Trim() ?? string.Empty,
                ConsoleAccessToken = store.Get(SecretKey.AliyunConsoleAccessToken)?.Trim() ?? string.Empty,
                Cookie = settings.AliyunCookie?.Trim() ?? string.Empty,
                ConsoleRegion = string.IsNullOrEmpty(region) ? "cn-beijing" : region!,
                ConsoleSite = string.IsNullOrEmpty(site) ? "domestic" : site!,
                ConsoleSwitchAgent = settings.AliyunConsoleSwitchAgent
            };

            if (reusable == null) return credentials;

            // 用户没配 AK/SK，但本机 bl 配过 —— 直接借用，两者缺一不可才算数
            if (!credentials.HasAccessKey
                && !string.IsNullOrWhiteSpace(reusable.AccessKeyId)
                && !string.IsNullOrWhiteSpace(reusable.AccessKeySecret))
            {
                credentials.AccessKeyId = reusable.AccessKeyId!;
                credentials.AccessKeySecret = reusable.AccessKeySecret!;
            }
            if (!credentials.HasConsoleToken && !string.IsNullOrWhiteSpace(reusable.AccessToken))
            {
                credentials.ConsoleAccessToken = reusable.AccessToken!;
            }
            // 代操作 UID 用户没填时才借用（bl 登录企业账号时会带上）
            if (credentials.ConsoleSwitchAgent == 0 && reusable.ConsoleSwitchAgent.HasValue)
            {
                credentials.ConsoleSwitchAgent = reusable.ConsoleSwitchAgent.Value;
            }
            return credentials;
        }

        // ---------- 账户现金余额（BSS OpenAPI QueryAccountBalance） ----------

        /// <summary>阿里云返回的金额是字符串，且可能带千分位逗号与货币符号。</summary>
        internal static double? ParseAmount(JsonNode? node)
        {
            var text = StringValue(node);
            if (text == null) return DoubleValue(node);

            var cleaned = new string(text.Where(c => char.IsDigit(c) || c == '.' || c == '-').ToArray());
            return double.TryParse(cleaned, NumberStyles.Float, CultureInfo.InvariantCulture, out var v)
                ? v : (double?)null;
        }

        public static AliyunAccountBalance ParseAccountBalance(string json)
        {
            JsonObject root;
            try
            {
                root = JsonNode.Parse(json) as JsonObject
                    ?? throw new AliyunChannelException(AliyunErrorKind.UnexpectedFormat, Truncate(json));
            }
            catch (AliyunChannelException) { throw; }
            catch
            {
                throw new AliyunChannelException(AliyunErrorKind.UnexpectedFormat, Truncate(json));
            }

            if (root["Success"] is JsonValue sv && sv.TryGetValue<bool>(out var ok) && !ok)
            {
                throw ClassifyOpenApiError(200,
                    StringValue(root["Code"]) ?? "", StringValue(root["Message"]) ?? "", json);
            }
            if (root["Data"] is not JsonObject payload)
            {
                throw new AliyunChannelException(
                    AliyunErrorKind.UnexpectedFormat, "QueryAccountBalance 响应缺少 Data");
            }

            var amount = ParseAmount(payload["AvailableCashAmount"]) ?? ParseAmount(payload["AvailableAmount"]);
            if (!amount.HasValue)
            {
                throw new AliyunChannelException(
                    AliyunErrorKind.UnexpectedFormat, "QueryAccountBalance 响应缺少可用余额字段");
            }

            return new AliyunAccountBalance(amount.Value, StringValue(payload["Currency"]) ?? "CNY");
        }

        /// <summary>
        /// 查询阿里云账户现金余额。
        /// 需要 RAM 权限 bss:DescribeAcccount（只读；官方文档就是这个拼写）。
        /// </summary>
        public async Task<AliyunAccountBalance> FetchAccountBalanceAsync(AliyunCredentials credentials)
        {
            if (!credentials.HasAccessKey)
                throw new AliyunChannelException(AliyunErrorKind.MissingCredentials);

            var headers = AliyunSigner.SignedHeaders(
                host: BalanceHost,
                action: BalanceAction,
                version: BalanceVersion,
                accessKeyId: credentials.AccessKeyId.Trim(),
                accessKeySecret: credentials.AccessKeySecret.Trim(),
                pathname: "/");

            using var req = new HttpRequestMessage(HttpMethod.Post, $"https://{BalanceHost}/");
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

            if (!resp.IsSuccessStatusCode)
            {
                string code = "", message = "";
                try
                {
                    if (JsonNode.Parse(body) is JsonObject errRoot)
                    {
                        code = StringValue(errRoot["Code"]) ?? "";
                        message = StringValue(errRoot["Message"]) ?? "";
                    }
                }
                catch { }
                throw ClassifyOpenApiError((int)resp.StatusCode, code, message, body);
            }

            return ParseAccountBalance(body);
        }
    }
}
