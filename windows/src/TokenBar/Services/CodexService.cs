using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using TokenBar.I18n;
using TokenBar.Models;

namespace TokenBar.Services;

/// <summary>Account-only RPCs; Codex owns authentication and token refresh.</summary>
public static class CodexService
{
    private static Exception Error(string zh, string en) => new InvalidOperationException(
        LocalizationManager.Instance.IsChinese ? zh : en);

    public static async Task<(TokenWindow? Primary, TokenWindow? Secondary, string? Account)> FetchQuotaAsync(
        string executablePath = "", CancellationToken ct = default)
    {
        var path = executablePath.Trim();
        if (path.Length > 0 && (!Path.IsPathFullyQualified(path) || !File.Exists(path)))
            throw Error("Codex 路径无效，请填写可执行文件的绝对路径", "Invalid Codex path; enter an absolute executable path");
        using var process = new Process { StartInfo = new ProcessStartInfo {
            FileName = path.Length > 0 ? path : "codex.exe",
            Arguments = "app-server", UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = Path.GetTempPath()
        }};
        try { process.Start(); }
        catch (System.ComponentModel.Win32Exception) {
            throw Error("未找到 Codex，请安装 Codex CLI 或填写可执行文件路径", "Codex not found; install Codex CLI or enter its executable path");
        }
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(20));
        var token = timeout.Token;
        // Drain stderr without retaining potentially sensitive diagnostics.
        async Task DrainErrors() {
            var buffer = new char[4096];
            try { while (await process.StandardError.ReadAsync(buffer.AsMemory(), token) > 0) { } }
            catch (OperationCanceledException) { }
        }
        var drain = DrainErrors();
        async Task Send(object message) {
            await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(message).AsMemory(), token);
            await process.StandardInput.FlushAsync(token);
        }
        async Task<JsonElement> Response(int id) {
            while (true) {
                var line = await process.StandardOutput.ReadLineAsync(token);
                if (line == null || line.Length > 1_048_576)
                    throw Error("Codex 进程退出或响应无效，请检查登录状态及网络", "Codex exited or returned an invalid response; check your login and network");
                using var document = JsonDocument.Parse(line);
                var root = document.RootElement;
                if (!root.TryGetProperty("id", out var rpcId) || !rpcId.TryGetInt32(out var value) || value != id) continue;
                if (root.TryGetProperty("error", out _))
                    throw Error("Codex 查询失败，请确认已用 ChatGPT 订阅账号登录，并更新 Codex 后重试", "Codex query failed; sign in with your ChatGPT subscription and update Codex");
                return root.GetProperty("result").Clone();
            }
        }
        try {
            await Send(new { id = 1, method = "initialize", @params = new { clientInfo = new { name = "tokenbar", version = "1.0" } } });
            await Response(1);
            await Send(new { method = "initialized", @params = new { } });
            await Send(new { id = 2, method = "account/read", @params = new { refreshToken = false } });
            var accountResult = await Response(2);
            if (!accountResult.TryGetProperty("account", out var account) || account.ValueKind != JsonValueKind.Object
                || !account.TryGetProperty("type", out var type) || type.GetString() != "chatgpt")
                throw Error("请先在 Codex 中使用 ChatGPT 订阅账号登录（codex login）", "Sign in to Codex with your ChatGPT subscription (codex login)");
            await Send(new { id = 3, method = "account/rateLimits/read" });
            var windows = ParseRateLimits(await Response(3));
            var plan = account.TryGetProperty("planType", out var p) ? p.GetString() : null;
            return (windows.Primary, windows.Secondary, $"Codex · {plan ?? "ChatGPT"}");
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) {
            throw Error("Codex 查询超时，请检查登录状态及网络", "Codex timed out; check your login and network");
        }
        finally {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync(CancellationToken.None);
            timeout.Cancel();
            await drain;
        }
    }

    public static (TokenWindow? Primary, TokenWindow? Secondary) ParseRateLimits(JsonElement result)
    {
        JsonElement limits;
        if (result.TryGetProperty("rateLimitsByLimitId", out var buckets) && buckets.ValueKind == JsonValueKind.Object
            && buckets.TryGetProperty("codex", out var codex) && codex.ValueKind == JsonValueKind.Object) limits = codex;
        else if (!result.TryGetProperty("rateLimits", out limits) || limits.ValueKind != JsonValueKind.Object)
            throw new FormatException("Invalid Codex rate limits response");
        TokenWindow? Window(string key) {
            if (!limits.TryGetProperty(key, out var raw) || raw.ValueKind == JsonValueKind.Null) return null;
            if (raw.ValueKind != JsonValueKind.Object
                || !raw.TryGetProperty("usedPercent", out var u) || u.ValueKind != JsonValueKind.Number || !u.TryGetDouble(out var used)
                || !raw.TryGetProperty("windowDurationMins", out var d) || d.ValueKind != JsonValueKind.Number || !d.TryGetDouble(out var duration)
                || !raw.TryGetProperty("resetsAt", out var r) || r.ValueKind != JsonValueKind.Number || !r.TryGetDouble(out var reset)
                || !double.IsFinite(used) || !double.IsFinite(duration) || !double.IsFinite(reset)
                || duration <= 0 || duration > 525600 || reset <= 0 || reset >= 253402300800)
                throw new FormatException("Invalid Codex quota window");
            var end = DateTimeOffset.FromUnixTimeSeconds((long)reset).LocalDateTime;
            return new TokenWindow {
                Title = duration == 300 ? WindowTitle.FiveHour : duration == 10080 ? WindowTitle.Weekly : WindowTitle.Custom($"Codex ({(int)duration} min)"),
                UsedPercentage = Math.Clamp(used, 0, 100), StartTime = end.AddMinutes(-duration), EndTime = end
            };
        }
        var primary = Window("primary"); var secondary = Window("secondary");
        if (primary == null && secondary == null)
            throw Error("Codex 未返回订阅额度窗口，请稍后重试", "Codex returned no subscription quota windows; retry later");
        return (primary, secondary);
    }
}
