using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using TokenBar.Models;

namespace TokenBar.Services
{
    public class ClaudeService
    {
        public static ClaudeService Instance { get; } = new ClaudeService();

        private static readonly HttpClient HttpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

        private ClaudeService() { }

        public (TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)? ReadLocalClaudeJson()
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
                using var doc = JsonDocument.Parse(content);
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
                    var now = DateTime.Now;
                    var initialFiveHour = new TokenWindow
                    {
                        Title = "5小时额度",
                        UsedPercentage = 0.0,
                        StartTime = now,
                        EndTime = now.AddHours(5),
                        Unit = "%",
                        IsIdle = true
                    };
                    return (initialFiveHour, null, accountEmail);
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

                    if (!string.IsNullOrEmpty(resetsAtStr) && DateTime.TryParse(resetsAtStr, null, System.Globalization.DateTimeStyles.RoundtripKind, out var resetsAtUtc))
                    {
                        var resetsAt = resetsAtUtc.ToLocalTime();
                        if (resetsAt > DateTime.Now)
                        {
                            fiveHourWindow = new TokenWindow
                            {
                                Title = "5小时额度",
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
                                Title = "5小时额度",
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
                            Title = "5小时额度",
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
                            var now = DateTime.Now;
                            fiveHourWindow = new TokenWindow
                            {
                                Title = "5小时额度",
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
                    var now = DateTime.Now;
                    fiveHourWindow = new TokenWindow
                    {
                        Title = "5小时额度",
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

                    if (!string.IsNullOrEmpty(resetsAtStr) && DateTime.TryParse(resetsAtStr, null, System.Globalization.DateTimeStyles.RoundtripKind, out var resetsAtUtc))
                    {
                        var resetsAt = resetsAtUtc.ToLocalTime();
                        weeklyWindow = new TokenWindow
                        {
                            Title = "每周额度",
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
                            var now = DateTime.Now;
                            var resetsAt = now.AddDays(7);
                            if (!string.IsNullOrEmpty(resetsAtStr) && DateTime.TryParse(resetsAtStr, null, System.Globalization.DateTimeStyles.RoundtripKind, out var rUtc))
                            {
                                resetsAt = rUtc.ToLocalTime();
                            }

                            weeklyWindow = new TokenWindow
                            {
                                Title = "每周额度",
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

                return (fiveHourWindow, weeklyWindow, accountEmail);
            }
            catch
            {
                return null;
            }
        }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchRemoteUsageAsync(string token)
        {
            var cleanToken = token.Trim();
            using var req = new HttpRequestMessage(HttpMethod.Get, "https://api.anthropic.com/api/oauth/usage");
            req.Headers.Add("Authorization", $"Bearer {cleanToken}");
            req.Headers.Add("anthropic-beta", "oauth-2025-04-20");
            req.Headers.Add("User-Agent", "claude-code/2.1.263");
            req.Headers.Add("Accept", "application/json");

            var resp = await HttpClient.SendAsync(req);
            var body = await resp.Content.ReadAsStringAsync();

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

                if (!string.IsNullOrEmpty(resetsAtStr) && DateTime.TryParse(resetsAtStr, null, System.Globalization.DateTimeStyles.RoundtripKind, out var resetsAtUtc))
                {
                    var resetsAt = resetsAtUtc.ToLocalTime();
                    if (resetsAt > DateTime.Now)
                    {
                        fiveHourWindow = new TokenWindow
                        {
                            Title = "5小时额度",
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
                            Title = "5小时额度",
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
                        Title = "5小时额度",
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
                    Title = "5小时额度",
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

                if (!string.IsNullOrEmpty(resetsAtStr) && DateTime.TryParse(resetsAtStr, null, System.Globalization.DateTimeStyles.RoundtripKind, out var resetsAtUtc))
                {
                    var resetsAt = resetsAtUtc.ToLocalTime();
                    weeklyWindow = new TokenWindow
                    {
                        Title = "每周额度",
                        UsedPercentage = util,
                        StartTime = resetsAt.AddDays(-7),
                        EndTime = resetsAt,
                        Unit = "%",
                        IsIdle = false
                    };
                }
            }

            return (fiveHourWindow, weeklyWindow, null);
        }

        public async Task<(TokenWindow? Primary, TokenWindow? Secondary, string? Account)> FetchAnthropicQuotaAsync(
            string apiKey,
            string endpoint = "https://api.anthropic.com/v1")
        {
            var cleanKey = apiKey.Trim();
            if (string.IsNullOrEmpty(cleanKey))
            {
                throw new ArgumentException("请输入 Anthropic API Key");
            }

            var baseEndpoint = endpoint.Trim().TrimEnd('/');
            if (string.IsNullOrEmpty(baseEndpoint))
            {
                baseEndpoint = "https://api.anthropic.com/v1";
            }

            var modelsUrl = baseEndpoint.EndsWith("/models", StringComparison.OrdinalIgnoreCase)
                ? baseEndpoint
                : $"{baseEndpoint}/models";

            using var req = new HttpRequestMessage(HttpMethod.Get, modelsUrl);
            req.Headers.Add("x-api-key", cleanKey);
            req.Headers.Add("anthropic-version", "2023-06-01");
            req.Headers.Add("Accept", "application/json");

            var resp = await HttpClient.SendAsync(req);
            var body = await resp.Content.ReadAsStringAsync();

            if (resp.StatusCode == System.Net.HttpStatusCode.Unauthorized)
            {
                throw new Exception("Anthropic API Key 无效或未授权 (HTTP 401)");
            }

            if ((int)resp.StatusCode == 429)
            {
                throw new Exception("Anthropic 请求频率或额度超限 (HTTP 429)");
            }

            if (!resp.IsSuccessStatusCode)
            {
                var snippet = body.Length > 100 ? body.Substring(0, 100) : body;
                throw new Exception($"Anthropic 接口响应异常: {snippet}");
            }

            string? GetHeader(string name)
            {
                if (resp.Headers.TryGetValues(name, out var values))
                    return values.FirstOrDefault();
                if (resp.Content.Headers.TryGetValues(name, out var cv))
                    return cv.FirstOrDefault();
                return null;
            }

            var limitTokensStr = GetHeader("anthropic-ratelimit-tokens-limit");
            var remainingTokensStr = GetHeader("anthropic-ratelimit-tokens-remaining");

            var limitReqsStr = GetHeader("anthropic-ratelimit-requests-limit");
            var remainingReqsStr = GetHeader("anthropic-ratelimit-requests-remaining");

            TokenWindow? primaryWindow = null;
            TokenWindow? secondaryWindow = null;

            if (double.TryParse(limitTokensStr, out var limitTokens) &&
                double.TryParse(remainingTokensStr, out var remainingTokens) &&
                limitTokens > 0)
            {
                var used = Math.Max(0.0, limitTokens - remainingTokens);
                var usedPct = Math.Clamp((used / limitTokens) * 100.0, 0.0, 100.0);
                var now = DateTime.Now;

                primaryWindow = new TokenWindow
                {
                    Title = "TPM 速率配额",
                    UsedPercentage = usedPct,
                    StartTime = now,
                    EndTime = now.AddMinutes(1),
                    UsedAmount = used,
                    TotalLimit = limitTokens,
                    Unit = "tokens",
                    IsIdle = used == 0.0
                };
            }

            if (double.TryParse(limitReqsStr, out var limitReqs) &&
                double.TryParse(remainingReqsStr, out var remReqs) &&
                limitReqs > 0)
            {
                var used = Math.Max(0.0, limitReqs - remReqs);
                var usedPct = Math.Clamp((used / limitReqs) * 100.0, 0.0, 100.0);
                var now = DateTime.Now;

                secondaryWindow = new TokenWindow
                {
                    Title = "RPM 速率配额",
                    UsedPercentage = usedPct,
                    StartTime = now,
                    EndTime = now.AddMinutes(1),
                    UsedAmount = used,
                    TotalLimit = limitReqs,
                    Unit = "req/min",
                    IsIdle = used == 0.0
                };
            }

            if (primaryWindow == null && secondaryWindow == null)
            {
                primaryWindow = new TokenWindow
                {
                    Title = "Anthropic API 连接正常",
                    UsedPercentage = 0.0,
                    StartTime = DateTime.Now,
                    EndTime = DateTime.Now.AddDays(1),
                    Unit = "%",
                    IsIdle = true
                };
            }

            var keySuffix = cleanKey.Length > 6 ? cleanKey[^4..] : cleanKey;
            var account = $"Anthropic API (尾号 {keySuffix})";

            return (primaryWindow, secondaryWindow, account);
        }
    }
}
