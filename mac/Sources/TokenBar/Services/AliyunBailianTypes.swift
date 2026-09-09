import Foundation

/// 百炼额度的获取通道，顺序即优先级。
public enum AliyunChannel: String, CaseIterable, Sendable {
    /// AK/SK 原生通道：签名换控制台 token 后以 Bearer 调网关。不受 SSO 多设备互踢限制。
    case accessKey
    /// 复用本机已有的控制台 token（TokenBar 缓存或 `~/.bailian/config.json`），无 AK/SK 时不能自愈。
    case consoleToken
    /// 官方 `bl` CLI 子进程，保留兼容。
    case cli
    /// 控制台 Cookie 直调网关，兜底。
    case cookie

    public var displayName: String {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        switch self {
        case .accessKey:    return isZh ? "AccessKey" : "AccessKey"
        case .consoleToken: return isZh ? "本机控制台令牌" : "Local console token"
        case .cli:          return isZh ? "百炼 CLI" : "Bailian CLI"
        case .cookie:       return isZh ? "控制台 Cookie" : "Console cookie"
        }
    }
}

/// 分类后的失败原因。分类的意义在于给出**可操作**的提示，
/// 而不是笼统地回落到「请运行 bl auth login --console」。
public enum AliyunChannelError: Error, LocalizedError, Equatable {
    case missingCredentials
    /// AK Secret 不对，**或本机时钟与服务器偏差过大**（签名带 x-acs-date，容差约 ±15 分钟）
    case signatureMismatch(String)
    case invalidAccessKey(String)
    case noPermission(String)
    /// 控制台会话失效（多为被其他设备登录顶掉）。有 AK/SK 时可自动续期。
    case notLogined
    /// 刚签发的新 token 仍被判未登录 —— 不是过期问题，不再重试，避免死循环。
    case notLoginedAfterRefresh
    case gatewayError(code: String, message: String)
    case network(String)
    case cliNotFound
    case cliFailed(String)
    case cookieExpired
    case unexpectedFormat(String)

    private var isZh: Bool { LocalizationManager.shared.effectiveLanguage == "zh" }

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return isZh
                ? "未配置任何可用凭证。百炼兼容 OpenAI 的接口只能对话、不支持配额查询，请在设置中填写 AccessKey ID / Secret（推荐，多台设备可同时在线）。"
                : "No usable credentials. Bailian's OpenAI-compatible endpoint only supports chat, not quota queries. Add an AccessKey ID / Secret in Settings (recommended — works on several machines at once)."
        case .signatureMismatch(let detail):
            return isZh
                ? "签名校验失败：请检查 AccessKey Secret 是否正确，以及本机系统时间是否准确（签名容差约 15 分钟）。\(detail)"
                : "Signature mismatch: check the AccessKey Secret and your system clock (signatures allow about 15 minutes of drift). \(detail)"
        case .invalidAccessKey(let detail):
            return isZh
                ? "AccessKey ID 不存在或已被禁用。\(detail)"
                : "The AccessKey ID does not exist or has been disabled. \(detail)"
        case .noPermission(let detail):
            return isZh
                ? "该 RAM 子用户没有百炼相关权限，请在 RAM 控制台与百炼控制台分别授权。\(detail)"
                : "This RAM user lacks Bailian permissions. Grant them in both the RAM console and the Bailian console. \(detail)"
        case .notLogined:
            return isZh
                ? "控制台会话已失效（通常是被其他设备登录顶掉）。配置 AccessKey 后可自动续期。"
                : "The console session is no longer valid (usually because another device signed in). Configure an AccessKey to renew it automatically."
        case .notLoginedAfterRefresh:
            return isZh
                ? "已重新签发控制台令牌，但仍被判定未登录。请检查控制台区域 / 站点 / 代操作 UID 是否设置正确。"
                : "A fresh console token was issued but is still rejected. Check the console region / site / switch-agent settings."
        case .gatewayError(let code, let message):
            return isZh ? "控制台网关返回错误 \(code)：\(message)" : "Console gateway error \(code): \(message)"
        case .network(let detail):
            return isZh ? "网络请求失败：\(detail)" : "Network request failed: \(detail)"
        case .cliNotFound:
            return isZh
                ? "未检测到百炼 CLI ('bl')。可在终端通过 npm install -g @modelstudio/cli 安装。"
                : "Bailian CLI ('bl') not detected. Install it with npm install -g @modelstudio/cli."
        case .cliFailed(let detail):
            return isZh ? "百炼 CLI 执行失败：\(detail)" : "Bailian CLI failed: \(detail)"
        case .cookieExpired:
            return isZh ? "控制台 Cookie 已失效，请重新登录授权。" : "The console cookie has expired. Please sign in again."
        case .unexpectedFormat(let detail):
            return isZh ? "返回数据格式不符合预期：\(detail)" : "Unexpected response format: \(detail)"
        }
    }
}

/// 一次额度查询所需的全部凭证与控制台定位信息。
public struct AliyunCredentials: Sendable {
    public var accessKeyId: String
    public var accessKeySecret: String
    /// 已缓存的控制台 token（来自 SecretStore 或本机 `bl` 配置）。
    public var consoleAccessToken: String
    public var cookie: String
    public var consoleRegion: String
    public var consoleSite: String
    /// 0 表示未设置。
    public var consoleSwitchAgent: Int

    public init(
        accessKeyId: String = "",
        accessKeySecret: String = "",
        consoleAccessToken: String = "",
        cookie: String = "",
        consoleRegion: String = "cn-beijing",
        consoleSite: String = "domestic",
        consoleSwitchAgent: Int = 0
    ) {
        self.accessKeyId = accessKeyId
        self.accessKeySecret = accessKeySecret
        self.consoleAccessToken = consoleAccessToken
        self.cookie = cookie
        self.consoleRegion = consoleRegion
        self.consoleSite = consoleSite
        self.consoleSwitchAgent = consoleSwitchAgent
    }

    public var hasAccessKey: Bool {
        !accessKeyId.trimmed.isEmpty && !accessKeySecret.trimmed.isEmpty
    }
    public var hasConsoleToken: Bool { !consoleAccessToken.trimmed.isEmpty }
    public var hasCookie: Bool { !cookie.trimmed.isEmpty }
    public var switchAgentOrNil: Int? { consoleSwitchAgent > 0 ? consoleSwitchAgent : nil }
}

/// 一次成功查询的结果。
/// 注意：TokenWindow 非 Sendable，故此结构体不标 Sendable（仅在同一 actor 上下文内流转）。
public struct AliyunQuotaResult {
    public var fiveHour: TokenWindow?
    public var weekly: TokenWindow?
    public var account: String?
    /// 网关成功但没返回任何窗口数据时的说明文案（不是错误 —— 该窗口可能不限量）。
    public var note: String?
    public var channel: AliyunChannel
    /// 本次新签发的控制台 token，由 RefreshManager 负责落盘。
    public var refreshedToken: String?

    public init(
        fiveHour: TokenWindow? = nil,
        weekly: TokenWindow? = nil,
        account: String? = nil,
        note: String? = nil,
        channel: AliyunChannel,
        refreshedToken: String? = nil
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.account = account
        self.note = note
        self.channel = channel
        self.refreshedToken = refreshedToken
    }
}

/// 控制台网关的站点路由。
public struct AliyunConsoleGatewayRoute: Equatable, Sendable {
    public let host: String
    public let action: String
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
