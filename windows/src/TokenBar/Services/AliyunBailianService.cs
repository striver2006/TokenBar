using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using TokenBar.Models;

namespace TokenBar.Services
{
    public class AliyunBailianService
    {
        public static AliyunBailianService Instance { get; } = new AliyunBailianService();

        private static readonly HttpClient HttpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

        private AliyunBailianService() { }

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

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchQuotaAsync(
            string? apiKey = null,
            string? cookie = null,
            string endpoint = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
        {
            Exception? cliError = null;

            // 1. Try official Bailian CLI (`bl`)
            try
            {
                return await FetchViaCLIAsync();
            }
            catch (Exception ex)
            {
                cliError = ex;
            }

            // 2. Try Console Web Cookie
            if (!string.IsNullOrWhiteSpace(cookie))
            {
                return await FetchViaConsoleAsync(cookie.Trim());
            }

            if (cliError != null)
            {
                throw cliError;
            }

            throw new Exception(LocalizationManager.Instance.IsChinese ? "百炼兼容 OpenAI 接口仅用于模型对话，不支持配额查询。请在终端登录百炼 CLI (`bl auth login --console`) 或使用网页登录授权获取 7天 与 5小时额度。" : "Aliyun Bailian OpenAI-compatible endpoint only supports chat, not quota queries. Please run `bl auth login --console` in terminal or configure web cookies to monitor 7-day and 5-hour quotas.");
        }

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchViaCLIAsync()
        {
            string? blPath = FindBlExecutable();
            if (blPath == null)
            {
                throw new FileNotFoundException(LocalizationManager.Instance.IsChinese ? "未检测到百炼 CLI ('bl')。可在终端通过 npm install -g @modelstudio/cli 安装，或使用网页登录授权。" : "Bailian CLI ('bl') not detected. Install via npm install -g @modelstudio/cli in terminal, or configure web cookies.");
            }

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
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? "无法启动百炼 CLI 进程" : "Unable to launch Bailian CLI process");
            }

            var outputTask = proc.StandardOutput.ReadToEndAsync();
            var errorTask = proc.StandardError.ReadToEndAsync();

            await proc.WaitForExitAsync();
            var stdout = await outputTask;
            var stderr = await errorTask;

            if (!string.IsNullOrWhiteSpace(stdout))
            {
                try
                {
                    return ParseTokenPlanJson(stdout, LocalizationManager.Instance.IsChinese ? "百炼 CLI (cn-beijing)" : "Bailian CLI (cn-beijing)");
                }
                catch { }
            }

            if (!string.IsNullOrWhiteSpace(stderr))
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? $"百炼 CLI 错误: {stderr}" : $"Bailian CLI error: {stderr}");
            }

            throw new Exception(LocalizationManager.Instance.IsChinese ? "百炼 CLI 未返回有效的额度数据，请先运行 bl auth login --console 进行登录" : "Bailian CLI returned no valid quota data. Please run `bl auth login --console` to authenticate.");
        }

        private static string? FindBlExecutable()
        {
            var candidates = new[]
            {
                "bl.cmd", "bl.exe", "bl.bat", "bl"
            };

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

        public async Task<(TokenWindow? FiveHour, TokenWindow? Weekly, string? Account)> FetchViaConsoleAsync(string cookie)
        {
            var url = "https://bailian-cs.console.aliyun.com/data/api.json?action=BroadScopeAspnGateway&product=sfm_bailian&api=zeldaHttp.apikeyMgr.%2Ftokenplan%2Fpersonal%2Fapi%2Fv2%2Fusage&_v=undefined";

            using var req = new HttpRequestMessage(HttpMethod.Post, url);
            req.Headers.Add("Accept", "application/json, text/plain, */*");
            req.Headers.Add("Cookie", cookie);
            req.Headers.Add("Origin", "https://bailian.console.aliyun.com");
            req.Headers.Add("Referer", "https://bailian.console.aliyun.com/cn-beijing?tab=plan");
            req.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) TokenBar/1.0");
            req.Headers.Add("X-Requested-With", "XMLHttpRequest");

            var traceId = Guid.NewGuid().ToString("N");
            var paramDict = new
            {
                feTraceId = traceId,
                feURL = "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan",
                protocol = "V2",
                console = "ONE_CONSOLE",
                productCode = "p_efm",
                switchUserType = 3,
                domain = "bailian.console.aliyun.com",
                consoleSite = "BAILIAN_ALIYUN",
                userNickName = "",
                userPrincipalName = "",
                xsp_lang = "zh-CN"
            };

            var paramsJson = JsonSerializer.Serialize(paramDict);
            var content = new FormUrlEncodedContent(new[]
            {
                new System.Collections.Generic.KeyValuePair<string, string>("params", paramsJson),
                new System.Collections.Generic.KeyValuePair<string, string>("region", "cn-beijing")
            });
            req.Content = content;

            var resp = await HttpClient.SendAsync(req);
            var body = await resp.Content.ReadAsStringAsync();

            if (resp.StatusCode == System.Net.HttpStatusCode.Unauthorized || resp.StatusCode == System.Net.HttpStatusCode.Forbidden)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? "控制台 Cookie 已失效，请重新登录授权" : "Console Cookie expired. Please log in and authorize again");
            }

            return ParseTokenPlanJson(body, LocalizationManager.Instance.IsChinese ? "控制台网页授权" : "Console Web Auth");
        }

        public (TokenWindow? FiveHour, TokenWindow? Weekly, string? Account) ParseTokenPlanJson(string jsonText, string accountLabel)
        {
            using var doc = JsonDocument.Parse(jsonText);
            var root = doc.RootElement;

            if (root.TryGetProperty("error", out var errObj) && errObj.TryGetProperty("message", out var msgProp))
            {
                var isZh = LocalizationManager.Instance.IsChinese;
                var msg = msgProp.GetString() ?? (isZh ? "未知错误" : "Unknown error");
                var hint = errObj.TryGetProperty("hint", out var hp) ? hp.GetString() : (isZh ? "请运行 bl auth login --console 登录" : "Please run bl auth login --console to login");
                throw new Exception($"{msg} ({hint})");
            }

            var payload = root;
            if (root.TryGetProperty("data", out var dataObj))
            {
                payload = dataObj;
            }

            double? per1WeekPctVal = payload.TryGetProperty("per1WeekPercentage", out var wProp) ? wProp.GetDouble() : null;
            double? per1WeekResetMs = payload.TryGetProperty("per1WeekResetTime", out var wrProp) ? wrProp.GetDouble() : null;
            double? per5HourPctVal = payload.TryGetProperty("per5HourPercentage", out var hProp) ? hProp.GetDouble() : null;
            double? per5HourResetMs = payload.TryGetProperty("per5HourResetTime", out var hrProp) ? hrProp.GetDouble() : null;

            if (!per1WeekPctVal.HasValue && !per5HourPctVal.HasValue)
            {
                throw new Exception(LocalizationManager.Instance.IsChinese ? "返回数据中未包含 7天或5小时配额字段" : "Response data missing 7-day or 5-hour quota fields");
            }

            TokenWindow? weeklyWindow = null;
            if (per1WeekPctVal.HasValue)
            {
                var usedPct = Math.Clamp(per1WeekPctVal.Value * 100.0, 0.0, 100.0);
                DateTime resetDate = per1WeekResetMs.HasValue && per1WeekResetMs.Value > 0
                    ? DateTimeOffset.FromUnixTimeMilliseconds((long)per1WeekResetMs.Value).LocalDateTime
                    : DateTime.Now.AddDays(7);

                weeklyWindow = new TokenWindow
                {
                    Title = "7天周期额度",
                    UsedPercentage = usedPct,
                    StartTime = resetDate.AddDays(-7),
                    EndTime = resetDate,
                    Unit = "%",
                    IsIdle = usedPct == 0.0
                };
            }

            TokenWindow? fiveHourWindow = null;
            if (per5HourPctVal.HasValue)
            {
                var usedPct = Math.Clamp(per5HourPctVal.Value * 100.0, 0.0, 100.0);
                DateTime resetDate = per5HourResetMs.HasValue && per5HourResetMs.Value > 0
                    ? DateTimeOffset.FromUnixTimeMilliseconds((long)per5HourResetMs.Value).LocalDateTime
                    : DateTime.Now.AddHours(5);

                fiveHourWindow = new TokenWindow
                {
                    Title = "5小时额度",
                    UsedPercentage = usedPct,
                    StartTime = resetDate.AddHours(-5),
                    EndTime = resetDate,
                    Unit = "%",
                    IsIdle = usedPct == 0.0
                };
            }

            return (fiveHourWindow, weeklyWindow, accountLabel);
        }
    }
}
