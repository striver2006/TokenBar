using System;
using TokenBar.I18n;
using TokenBar.Models;

namespace TokenBar.Services
{
    /// <summary>百炼额度的获取通道，顺序即优先级。须与 mac 端 AliyunChannel 同名同序。</summary>
    public enum AliyunChannel
    {
        /// <summary>AK/SK 原生通道：签名换控制台令牌后以 Bearer 调网关。不受 SSO 多设备互踢限制。</summary>
        AccessKey,
        /// <summary>复用本机已有的控制台令牌，无 AK/SK 时不能自愈。</summary>
        ConsoleToken,
        /// <summary>官方 bl CLI 子进程，保留兼容。</summary>
        Cli,
        /// <summary>控制台 Cookie 直调网关，兜底。</summary>
        Cookie
    }

    public static class AliyunChannelExtensions
    {
        public static string DisplayName(this AliyunChannel channel)
        {
            var isZh = LocalizationManager.Instance.IsChinese;
            return channel switch
            {
                AliyunChannel.AccessKey => "AccessKey",
                AliyunChannel.ConsoleToken => isZh ? "本机控制台令牌" : "Local console token",
                AliyunChannel.Cli => isZh ? "百炼 CLI" : "Bailian CLI",
                AliyunChannel.Cookie => isZh ? "控制台 Cookie" : "Console cookie",
                _ => channel.ToString()
            };
        }
    }

    /// <summary>失败原因分类。须与 mac 端 AliyunChannelError 的 case 一一对应。</summary>
    public enum AliyunErrorKind
    {
        MissingCredentials,
        /// <summary>AK Secret 不对，或本机时钟与服务器偏差过大（签名容差约 ±15 分钟）。</summary>
        SignatureMismatch,
        InvalidAccessKey,
        NoPermission,
        /// <summary>控制台会话失效（多为被其他设备登录顶掉）。有 AK/SK 时可自动续期。</summary>
        NotLogined,
        /// <summary>刚签发的新令牌仍被判未登录 —— 不再重试，避免死循环。</summary>
        NotLoginedAfterRefresh,
        GatewayError,
        Network,
        CliNotFound,
        CliFailed,
        CookieExpired,
        UnexpectedFormat
    }

    /// <summary>
    /// 分类后的百炼通道异常。分类的意义在于给出可操作的提示，
    /// 而不是笼统地回落到「请运行 bl auth login --console」。
    /// </summary>
    public sealed class AliyunChannelException : Exception
    {
        public AliyunErrorKind Kind { get; }
        public string? Code { get; }

        public AliyunChannelException(AliyunErrorKind kind, string? detail = null, string? code = null)
            : base(BuildMessage(kind, detail, code))
        {
            Kind = kind;
            Code = code;
        }

        private static string BuildMessage(AliyunErrorKind kind, string? detail, string? code)
        {
            var isZh = LocalizationManager.Instance.IsChinese;
            var tail = string.IsNullOrWhiteSpace(detail) ? string.Empty : " " + detail;
            return kind switch
            {
                AliyunErrorKind.MissingCredentials => isZh
                    ? "未配置任何可用凭证。百炼兼容 OpenAI 的接口只能对话、不支持配额查询，请在设置中填写 AccessKey ID / Secret（推荐，多台设备可同时在线）。"
                    : "No usable credentials. Bailian's OpenAI-compatible endpoint only supports chat, not quota queries. Add an AccessKey ID / Secret in Settings (recommended - works on several machines at once).",
                AliyunErrorKind.SignatureMismatch => (isZh
                    ? "签名校验失败：请检查 AccessKey Secret 是否正确，以及本机系统时间是否准确（签名容差约 15 分钟）。"
                    : "Signature mismatch: check the AccessKey Secret and your system clock (signatures allow about 15 minutes of drift).") + tail,
                AliyunErrorKind.InvalidAccessKey => (isZh
                    ? "AccessKey ID 不存在或已被禁用。"
                    : "The AccessKey ID does not exist or has been disabled.") + tail,
                AliyunErrorKind.NoPermission => (isZh
                    ? "该 RAM 子用户没有百炼相关权限，请在 RAM 控制台与百炼控制台分别授权。"
                    : "This RAM user lacks Bailian permissions. Grant them in both the RAM console and the Bailian console.") + tail,
                AliyunErrorKind.NotLogined => isZh
                    ? "控制台会话已失效（通常是被其他设备登录顶掉）。配置 AccessKey 后可自动续期。"
                    : "The console session is no longer valid (usually because another device signed in). Configure an AccessKey to renew it automatically.",
                AliyunErrorKind.NotLoginedAfterRefresh => isZh
                    ? "已重新签发控制台令牌，但仍被判定未登录。请检查控制台区域 / 站点 / 代操作 UID 是否设置正确。"
                    : "A fresh console token was issued but is still rejected. Check the console region / site / switch-agent settings.",
                AliyunErrorKind.GatewayError => isZh
                    ? $"控制台网关返回错误 {code}：{detail}"
                    : $"Console gateway error {code}: {detail}",
                AliyunErrorKind.Network => (isZh ? "网络请求失败：" : "Network request failed: ") + detail,
                AliyunErrorKind.CliNotFound => isZh
                    ? "未检测到百炼 CLI ('bl')。可在终端通过 npm install -g @modelstudio/cli 安装。"
                    : "Bailian CLI ('bl') not detected. Install it with npm install -g @modelstudio/cli.",
                AliyunErrorKind.CliFailed => (isZh ? "百炼 CLI 执行失败：" : "Bailian CLI failed: ") + detail,
                AliyunErrorKind.CookieExpired => isZh
                    ? "控制台 Cookie 已失效，请重新登录授权。"
                    : "The console cookie has expired. Please sign in again.",
                AliyunErrorKind.UnexpectedFormat => (isZh
                    ? "返回数据格式不符合预期：" : "Unexpected response format: ") + detail,
                _ => detail ?? kind.ToString()
            };
        }
    }

    /// <summary>一次额度查询所需的全部凭证与控制台定位信息。</summary>
    public sealed class AliyunCredentials
    {
        public string AccessKeyId { get; set; } = string.Empty;
        public string AccessKeySecret { get; set; } = string.Empty;
        /// <summary>已缓存的控制台令牌（来自 SecretStore 或本机 bl 配置）。</summary>
        public string ConsoleAccessToken { get; set; } = string.Empty;
        public string Cookie { get; set; } = string.Empty;
        public string ConsoleRegion { get; set; } = "cn-beijing";
        public string ConsoleSite { get; set; } = "domestic";
        /// <summary>0 表示未设置。</summary>
        public long ConsoleSwitchAgent { get; set; }

        public bool HasAccessKey =>
            !string.IsNullOrWhiteSpace(AccessKeyId) && !string.IsNullOrWhiteSpace(AccessKeySecret);
        public bool HasConsoleToken => !string.IsNullOrWhiteSpace(ConsoleAccessToken);
        public bool HasCookie => !string.IsNullOrWhiteSpace(Cookie);
        public long? SwitchAgentOrNull => ConsoleSwitchAgent > 0 ? ConsoleSwitchAgent : null;
    }

    /// <summary>一次成功查询的结果。</summary>
    public sealed class AliyunQuotaResult
    {
        public TokenWindow? FiveHour { get; set; }
        public TokenWindow? Weekly { get; set; }
        public string? Account { get; set; }
        /// <summary>网关成功但没返回任何窗口数据时的说明文案（不是错误 —— 该窗口可能不限量）。</summary>
        public string? Note { get; set; }
        public AliyunChannel Channel { get; set; }
        /// <summary>本次新签发的控制台令牌，由 RefreshManager 负责落盘。</summary>
        public string? RefreshedToken { get; set; }
    }

    /// <summary>控制台网关的站点路由。</summary>
    public readonly record struct AliyunConsoleGatewayRoute(string Host, string Action);

    /// <summary>阿里云账户现金余额。</summary>
    public readonly record struct AliyunAccountBalance(double Amount, string Currency);
}
