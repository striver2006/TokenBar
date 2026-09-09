import Foundation
import SwiftUI

public enum ProviderType: String, CaseIterable, Identifiable, Codable {
    case openAI = "openAI"
    case claudeCode = "claudeCode"
    case gemini = "gemini"
    case deepseek = "deepseek"
    case volcengine = "volcengine"
    case kimi = "kimi"
    case openRouter = "openRouter"
    case glm = "glm"
    case aliyunBailian = "aliyunBailian"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .claudeCode: return "Anthropic (Claude)"
        case .gemini: return "Google Gemini"
        case .deepseek: return LocalizationManager.shared.effectiveLanguage == "zh" ? "DeepSeek (深度求索)" : "DeepSeek"
        case .volcengine: return I18n(.volcengineTitle)
        case .kimi: return I18n(.kimiTitle)
        case .openRouter: return "OpenRouter"
        case .glm: return I18n(.glmTitle)
        case .aliyunBailian: return I18n(.aliyunTitle)
        }
    }

    public var shortName: String {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        switch self {
        case .openAI: return "OpenAI"
        case .claudeCode: return "Anthropic"
        case .gemini: return "Gemini"
        case .deepseek: return "DeepSeek"
        case .volcengine: return isZh ? "火山方舟" : "Ark"
        case .kimi: return "KIMI"
        case .openRouter: return "OpenRouter"
        case .glm: return "GLM"
        case .aliyunBailian: return isZh ? "百炼" : "Bailian"
        }
    }

    public var iconName: String {
        switch self {
        case .openAI: return "circle.hexagonpath.fill"
        case .claudeCode: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .deepseek: return "bolt.horizontal.fill"
        case .volcengine: return "flame.fill"
        case .kimi: return "moon.stars.fill"
        case .openRouter: return "creditcard.fill"
        case .glm: return "bolt.fill"
        case .aliyunBailian: return "cloud.fill"
        }
    }

    public var themeColor: Color {
        switch self {
        case .openAI: return Color(red: 0.06, green: 0.65, blue: 0.53) // OpenAI teal green
        case .claudeCode: return Color(red: 0.85, green: 0.45, blue: 0.28) // Claude terracotta
        case .gemini: return Color(red: 0.25, green: 0.52, blue: 0.95)   // Google blue
        case .deepseek: return Color(red: 0.22, green: 0.48, blue: 0.96) // DeepSeek Royal Blue
        case .volcengine: return Color(red: 0.94, green: 0.30, blue: 0.22) // Volcengine Red
        case .kimi: return Color(red: 0.55, green: 0.35, blue: 0.92)     // Moonshot Purple
        case .openRouter: return Color(red: 0.39, green: 0.40, blue: 0.95) // OpenRouter Indigo
        case .glm: return Color(red: 0.23, green: 0.72, blue: 0.53)      // GLM emerald green
        case .aliyunBailian: return Color(red: 1.0, green: 0.42, blue: 0.0) // Aliyun Orange
        }
    }
}

/// 额度窗口展示类型：percentage 为时间窗口百分比，balance 为纯扣费厂商的货币余额
public enum TokenWindowKind: String, Codable {
    case percentage
    case balance
}

public struct TokenWindow: Identifiable, Codable {
    public var id = UUID()
    public var title: String
    public var usedPercentage: Double
    public var startTime: Date
    public var endTime: Date
    public var usedAmount: Double?
    public var totalLimit: Double?
    public var unit: String
    public var isIdle: Bool

    // 余额窗口 (kind == .balance) 专用字段；可选以便旧数据兼容解码
    public var kind: TokenWindowKind?
    public var balanceAmount: Double?
    public var currency: String?
    public var warningThreshold: Double?
    public var criticalThreshold: Double?
    // 由 RefreshManager 填充的展示辅助字段（不持久化）
    public var lastDelta: Double?
    public var forecastDays: Double?

    public init(
        title: String,
        usedPercentage: Double,
        startTime: Date,
        endTime: Date,
        usedAmount: Double? = nil,
        totalLimit: Double? = nil,
        unit: String = "%",
        isIdle: Bool = false
    ) {
        self.title = title
        self.usedPercentage = min(max(usedPercentage, 0.0), 100.0)
        self.startTime = startTime
        self.endTime = endTime
        self.usedAmount = usedAmount
        self.totalLimit = totalLimit
        self.unit = unit
        self.isIdle = isIdle
    }

    /// 便捷构造余额窗口
    public static func balance(
        title: String,
        amount: Double,
        currency: String,
        warningThreshold: Double?,
        criticalThreshold: Double?
    ) -> TokenWindow {
        var w = TokenWindow(title: title, usedPercentage: 0.0, startTime: Date(), endTime: Date().addingTimeInterval(30 * 86400))
        w.kind = .balance
        w.balanceAmount = amount
        w.currency = currency
        w.warningThreshold = warningThreshold
        w.criticalThreshold = criticalThreshold
        return w
    }

    public var isBalance: Bool { kind == .balance }

    public var currencySymbol: String { currency == "USD" ? "$" : "¥" }

    public var balanceFormatted: String {
        guard let amount = balanceAmount else { return "--" }
        return String(format: "%@%.2f", currencySymbol, amount)
    }

    public var balanceDeltaFormatted: String {
        guard let delta = lastDelta, delta != 0 else { return "" }
        return String(format: "%@%@%.2f", delta > 0 ? "+" : "-", currencySymbol, abs(delta))
    }

    public var remainingPercentage: Double {
        return max(0.0, 100.0 - usedPercentage)
    }

    public var localizedTitle: String {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        if isZh { return title }

        if title.hasPrefix("可用模型 (") {
            let count = title.replacingOccurrences(of: "可用模型 (", with: "").replacingOccurrences(of: "个)", with: "").replacingOccurrences(of: ")", with: "").trimmingCharacters(in: .whitespaces)
            return "Available Models (\(count))"
        }

        switch title {
        case "5小时额度": return I18n(.fiveHourQuotaTitle)
        case "每周额度": return I18n(.weeklyQuotaTitle)
        case "7天额度", "7天周期额度": return I18n(.sevenDaysQuotaTitle)
        case "账户可用余额", "账户余额": return I18n(.accountBalanceTitle)
        case "Key 额度", "Key 可用额度": return I18n(.keyQuotaTitle)
        case "Token Plan 额度": return I18n(.tokenPlanQuotaTitle)
        case "RPM 速率配额", "RPM 请求速率": return I18n(.rpmRateLimitTitle)
        case "TPM 速率配额", "TPM 速率剩余": return I18n(.tpmRateLimitTitle)
        case "Token 速率配额": return I18n(.tokenRateLimitTitle)
        case "5小时算力额度": return I18n(.fiveHourComputeQuotaTitle)
        case "API 连接正常", "接口连接正常", "Anthropic 协议连接正常", "Anthropic API 连接正常", "DeepSeek 连接正常", "KIMI 连接正常", "接入点连接正常", "API 连接状态":
            return I18n(.apiConnectedTitle)
        case "AI Studio 配额":
            return "AI Studio Quota"
        default: return title
        }
    }

    public var isExpired: Bool {
        if isIdle { return false }
        return Date() >= endTime
    }

    public var timeRemainingFormatted: String {
        if isIdle || (usedPercentage == 0.0 && Date() >= endTime) {
            return I18n(.unusedFull)
        }

        let now = Date()
        let diff = endTime.timeIntervalSince(now)
        if diff <= 0 {
            return I18n(.resetTimeReached)
        }

        let days = Int(diff) / 86400
        let hours = (Int(diff) % 86400) / 3600
        let minutes = (Int(diff) % 3600) / 60

        if days > 0 {
            return String(format: I18n(.timeDaysHours), days, hours)
        } else if hours > 0 {
            return String(format: I18n(.timeHoursMinutes), hours, minutes)
        } else {
            return String(format: I18n(.timeMinutes), max(1, minutes))
        }
    }

    public var timeRangeFormatted: String {
        if isIdle {
            return I18n(.fiveHourIdle)
        }

        let calendar = Calendar.current
        let isSameDay = calendar.isDate(startTime, inSameDayAs: endTime)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.dateFormat = "MM-dd HH:mm"

        if isSameDay {
            return "\(timeFormatter.string(from: startTime)) ~ \(timeFormatter.string(from: endTime))"
        } else {
            return "\(dateTimeFormatter.string(from: startTime)) ~ \(dateTimeFormatter.string(from: endTime))"
        }
    }

    public var statusColor: Color {
        if isBalance {
            if let amount = balanceAmount, let critical = criticalThreshold, amount < critical {
                return Color.red
            }
            if let amount = balanceAmount, let warning = warningThreshold, amount < warning {
                return Color.orange
            }
            return Color.green
        }
        if usedPercentage >= 90 {
            return Color.red
        } else if usedPercentage >= 70 {
            return Color.orange
        } else {
            return Color.green
        }
    }
}

public struct ProviderQuota: Identifiable, Codable {
    public var id = UUID()
    public var provider: ProviderType
    public var isEnabled: Bool
    public var isAuthorized: Bool
    public var accountInfo: String?
    public var fiveHourWindow: TokenWindow?
    public var weeklyWindow: TokenWindow?
    /// 第三个槽位：与时间窗口额度并存的货币余额（目前用于阿里云百炼的账户现金余额）。
    /// 只用两个槽位的厂商保持 nil，卡片不会渲染这一行。
    public var balanceWindow: TokenWindow?
    public var lastUpdated: Date?
    public var errorMessage: String?
    public var isLoading: Bool

    public init(
        provider: ProviderType,
        isEnabled: Bool = true,
        isAuthorized: Bool = false,
        accountInfo: String? = nil,
        fiveHourWindow: TokenWindow? = nil,
        weeklyWindow: TokenWindow? = nil,
        balanceWindow: TokenWindow? = nil,
        lastUpdated: Date? = nil,
        errorMessage: String? = nil,
        isLoading: Bool = false
    ) {
        self.provider = provider
        self.isEnabled = isEnabled
        self.isAuthorized = isAuthorized
        self.accountInfo = accountInfo
        self.fiveHourWindow = fiveHourWindow
        self.weeklyWindow = weeklyWindow
        self.balanceWindow = balanceWindow
        self.lastUpdated = lastUpdated
        self.errorMessage = errorMessage
        self.isLoading = isLoading
    }
}

// MARK: - API Protocol for Domestic / Custom Providers
public enum ApiProtocol: String, CaseIterable, Identifiable, Codable {
    case openAIChat = "openAIChat"
    case openAIResponses = "openAIResponses"
    case anthropic = "anthropic"

    public var id: String { rawValue }

    public var displayName: String {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        switch self {
        case .openAIChat:
            return isZh ? "OpenAI Chat Completions 协议 (/v1/chat/completions)" : "OpenAI Chat Completions Protocol (/v1/chat/completions)"
        case .openAIResponses:
            return isZh ? "OpenAI Response 协议 (/v1/responses 等)" : "OpenAI Response Protocol (/v1/responses, etc.)"
        case .anthropic:
            return isZh ? "Anthropic 兼容协议 (/v1/messages 等)" : "Anthropic Compatible Protocol (/v1/messages, etc.)"
        }
    }

    public var shortName: String {
        switch self {
        case .openAIChat: return "OpenAI Chat"
        case .openAIResponses: return "OpenAI Response"
        case .anthropic: return "Anthropic"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "openAIChat", "openAI":
            self = .openAIChat
        case "openAIResponses", "openAIResponse":
            self = .openAIResponses
        case "anthropic":
            self = .anthropic
        default:
            self = .openAIChat
        }
    }
}

// MARK: - Custom Domestic Provider Configuration
public struct CustomProviderConfig: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var apiKey: String
    public var endpoint: String
    public var apiProtocol: ApiProtocol
    public var model: String
    // 余额提醒阈值（账户币种）；nil 时使用默认值 10
    public var balanceAlertThreshold: Double?
    // 厂商控制台 Web 登录态（如小米 MiMo 的余额/Token Plan 用量查询只接受 Cookie，不接受 API Key）
    public var consoleCookie: String

    public init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        apiKey: String = "",
        endpoint: String = "http://localhost:3000/v1",
        apiProtocol: ApiProtocol = .openAIChat,
        model: String = "",
        balanceAlertThreshold: Double? = nil,
        consoleCookie: String = ""
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.apiProtocol = apiProtocol
        self.model = model
        self.balanceAlertThreshold = balanceAlertThreshold
        self.consoleCookie = consoleCookie
    }
}

// MARK: - Custom Domestic Provider Quota / Status
public struct CustomProviderQuota: Identifiable, Codable {
    public var id: UUID
    public var configId: UUID
    public var name: String
    public var apiProtocol: ApiProtocol
    public var isEnabled: Bool
    public var isAuthorized: Bool
    public var accountInfo: String?
    public var primaryWindow: TokenWindow?
    public var secondaryWindow: TokenWindow?
    public var lastUpdated: Date?
    public var errorMessage: String?
    public var isLoading: Bool

    public init(
        id: UUID = UUID(),
        configId: UUID,
        name: String,
        apiProtocol: ApiProtocol = .openAIChat,
        isEnabled: Bool = true,
        isAuthorized: Bool = false,
        accountInfo: String? = nil,
        primaryWindow: TokenWindow? = nil,
        secondaryWindow: TokenWindow? = nil,
        lastUpdated: Date? = nil,
        errorMessage: String? = nil,
        isLoading: Bool = false
    ) {
        self.id = id
        self.configId = configId
        self.name = name
        self.apiProtocol = apiProtocol
        self.isEnabled = isEnabled
        self.isAuthorized = isAuthorized
        self.accountInfo = accountInfo
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
        self.lastUpdated = lastUpdated
        self.errorMessage = errorMessage
        self.isLoading = isLoading
    }
}

// MARK: - Presets for Domestic Providers
public struct DomesticProviderPreset: Identifiable {
    public var id: String { name }
    public let name: String
    public var localizedName: String {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        if isZh { return name }
        switch name {
        case "OpenAI 兼容代理": return "OpenAI Compatible Proxy"
        case "Anthropic 兼容代理": return "Anthropic Compatible Proxy"
        case "小米 MiMo (Xiaomi)": return "Xiaomi MiMo"
        case "腾讯混元 (Tencent Hunyuan)": return "Tencent Hunyuan"
        case "阶跃星辰 (StepFun)": return "StepFun"
        case "硅基流动 (SiliconFlow)": return "SiliconFlow"
        case "MiniMax (名之梦)": return "MiniMax"
        case "零一万物 (01.AI)": return "01.AI"
        case "百度千帆 (文心一言)": return "Baidu Qianfan"
        default: return name
        }
    }
    public let endpoint: String
    public let apiProtocol: ApiProtocol
    public let placeholderKey: String
    public let defaultModel: String
    public let hint: String

    public static let allPresets: [DomesticProviderPreset] = [
        DomesticProviderPreset(
            name: "OpenAI 兼容代理",
            endpoint: "http://localhost:3000/v1",
            apiProtocol: .openAIChat,
            placeholderKey: "sk-...",
            defaultModel: "gpt-4o",
            hint: "适用于自建 OneAPI / NewAPI / 本地或第三方代理服务"
        ),
        DomesticProviderPreset(
            name: "Anthropic 兼容代理",
            endpoint: "http://localhost:8080/v1",
            apiProtocol: .anthropic,
            placeholderKey: "sk-ant-...",
            defaultModel: "claude-3-5-sonnet-20241022",
            hint: "适用于自建或本地中转代理服务"
        ),
        DomesticProviderPreset(
            name: "小米 MiMo (Xiaomi)",
            endpoint: "https://api.xiaomimimo.com/v1",
            apiProtocol: .openAIChat,
            placeholderKey: "sk-...",
            defaultModel: "mimo-v2.5-pro",
            hint: "小米 MiMo 开放平台 (支持按量付费与 Token Plan)"
        ),
        DomesticProviderPreset(
            name: "腾讯混元 (Tencent Hunyuan)",
            endpoint: "https://tokenhub.tencentmaas.com/v1",
            apiProtocol: .openAIChat,
            placeholderKey: "sk-...",
            defaultModel: "hunyuan-standard",
            hint: "腾讯云大模型服务平台 TokenHub / 混元 API"
        ),
        DomesticProviderPreset(
            name: "阶跃星辰 (StepFun)",
            endpoint: "https://api.stepfun.com/v1",
            apiProtocol: .openAIChat,
            placeholderKey: "sk-...",
            defaultModel: "step-1-8k",
            hint: "阶跃星辰开放平台 (Step-1 / Step-2 系列大模型)"
        ),
        DomesticProviderPreset(
            name: "硅基流动 (SiliconFlow)",
            endpoint: "https://api.siliconflow.cn/v1",
            apiProtocol: .openAIChat,
            placeholderKey: "sk-...",
            defaultModel: "deepseek-ai/DeepSeek-V3",
            hint: "支持用户中心余额与全系列主流模型"
        ),
        DomesticProviderPreset(
            name: "MiniMax (名之梦)",
            endpoint: "https://api.minimax.chat/v1",
            apiProtocol: .openAIChat,
            placeholderKey: "sk-...",
            defaultModel: "MiniMax-Text-01",
            hint: "国内自研通用大模型平台"
        ),
        DomesticProviderPreset(
            name: "零一万物 (01.AI)",
            endpoint: "https://api.lingyiwanwu.com/v1",
            apiProtocol: .openAIChat,
            placeholderKey: "sk-...",
            defaultModel: "yi-lightning",
            hint: "零一万物开放平台 (Yi 系列大模型)"
        ),
        DomesticProviderPreset(
            name: "百度千帆 (文心一言)",
            endpoint: "https://qianfan.baidubce.com/v2",
            apiProtocol: .openAIChat,
            placeholderKey: "bce-v3/...",
            defaultModel: "ernie-4.0-8k-latest",
            hint: "百度智能云千帆大模型平台 (兼容 OpenAI 规范)"
        )
    ]
}

/// 菜单栏图标旁展示的指标。auto 表示按厂商可用窗口自动挑选（额度优先，余额并列）。
/// 与 Windows 端保持同名同 rawValue。
public enum MenuBarMetric: String, CaseIterable, Identifiable, Codable {
    case auto = "auto"
    case fiveHour = "fiveHour"
    case weekly = "weekly"
    case quota = "quota"
    case balance = "balance"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return I18n(.menuBarMetricAuto)
        case .fiveHour: return I18n(.menuBarMetricFiveHour)
        case .weekly: return I18n(.menuBarMetricWeekly)
        case .quota: return I18n(.menuBarMetricQuota)
        case .balance: return I18n(.menuBarMetricBalance)
        }
    }
}

public struct AppSettings: Codable {
    public var refreshIntervalMinutes: Int
    public var enableHover: Bool
    public var launchAtLogin: Bool
    public var claudeEnabled: Bool
    public var geminiEnabled: Bool
    public var glmEnabled: Bool
    public var aliyunEnabled: Bool
    public var openAIEnabled: Bool
    public var deepseekEnabled: Bool
    public var volcengineEnabled: Bool
    public var kimiEnabled: Bool
    public var openRouterEnabled: Bool

    public var glmApiKey: String
    public var glmEndpoint: String
    /// 历史字段：从未参与额度查询链路（百炼兼容 OpenAI 端点只能对话），
    /// 仅为旧配置反序列化兼容保留，UI 已移除。
    public var aliyunApiKey: String
    /// 历史字段，同上。
    public var aliyunEndpoint: String
    public var aliyunCookie: String

    // MARK: 阿里云百炼 AK/SK 通道（首选，不受控制台 SSO 多设备互踢限制）
    // AccessKey Secret 与控制台 token 不落在这里 —— 见 SecretStore（Keychain / 凭据管理器）。
    public var aliyunAccessKeyId: String
    public var aliyunConsoleRegion: String
    public var aliyunConsoleSite: String
    /// 企业代操作 UID；0 表示未设置。阿里云 UID 可能是 16 位，故用 Int（64 位）。
    public var aliyunConsoleSwitchAgent: Int
    /// 是否复用本机 ~/.bailian/config.json 里已有的控制台凭证（只读，不写回）。
    public var aliyunReuseCLIConfig: Bool
    /// 阿里云账户现金余额提醒阈值，类型与默认值对齐 deepseek / kimi / openRouter。
    public var aliyunBalanceAlertThreshold: Double

    public var openAIApiKey: String
    public var openAIEndpoint: String
    public var openAIOrgId: String

    public var anthropicApiKey: String
    public var anthropicEndpoint: String
    public var claudeToken: String
    public var geminiApiKey: String
    public var geminiEndpoint: String
    public var geminiToken: String

    public var deepseekApiKey: String
    public var deepseekEndpoint: String
    public var deepseekModel: String
    public var deepseekBalanceAlertThreshold: Double

    public var volcengineApiKey: String
    public var volcengineEndpoint: String
    public var volcengineModel: String

    public var kimiApiKey: String
    public var kimiEndpoint: String
    public var kimiModel: String
    public var kimiBalanceAlertThreshold: Double

    public var openRouterApiKey: String
    public var openRouterEndpoint: String
    public var openRouterBalanceAlertThreshold: Double

    public var customProviders: [CustomProviderConfig]
    public var appLanguage: AppLanguage

    // 浮动框卡片显示顺序（键约定见 ProviderOrdering）；空数组表示默认顺序，
    // 未列入的已启用厂商按默认顺序追加在末尾
    public var providerOrder: [String]

    // 菜单栏图标旁的额度摘要：是否显示、展示哪个厂商（键约定见 ProviderOrdering）、展示哪个指标
    public var menuBarQuotaEnabled: Bool
    public var menuBarProviderKey: String
    public var menuBarMetric: MenuBarMetric

    enum CodingKeys: String, CodingKey {
        case refreshIntervalMinutes
        case enableHover
        case launchAtLogin
        case claudeEnabled
        case geminiEnabled
        case glmEnabled
        case aliyunEnabled
        case openAIEnabled
        case deepseekEnabled
        case volcengineEnabled
        case kimiEnabled
        case openRouterEnabled

        case glmApiKey
        case glmEndpoint
        case aliyunApiKey
        case aliyunEndpoint
        case aliyunCookie
        case aliyunAccessKeyId
        case aliyunConsoleRegion
        case aliyunConsoleSite
        case aliyunConsoleSwitchAgent
        case aliyunReuseCLIConfig
        case aliyunBalanceAlertThreshold

        case openAIApiKey
        case openAIEndpoint
        case openAIOrgId

        case anthropicApiKey
        case anthropicEndpoint
        case claudeToken
        case geminiApiKey
        case geminiEndpoint
        case geminiToken

        case deepseekApiKey
        case deepseekEndpoint
        case deepseekModel
        case deepseekBalanceAlertThreshold

        case volcengineApiKey
        case volcengineEndpoint
        case volcengineModel

        case kimiApiKey
        case kimiEndpoint
        case kimiModel
        case kimiBalanceAlertThreshold

        case openRouterApiKey
        case openRouterEndpoint
        case openRouterBalanceAlertThreshold

        case customProviders
        case appLanguage
        case providerOrder
        case menuBarQuotaEnabled
        case menuBarProviderKey
        case menuBarMetric
    }

    public init(
        refreshIntervalMinutes: Int = 5,
        enableHover: Bool = true,
        launchAtLogin: Bool = false,
        claudeEnabled: Bool = true,
        geminiEnabled: Bool = true,
        glmEnabled: Bool = true,
        aliyunEnabled: Bool = true,
        openAIEnabled: Bool = false,
        deepseekEnabled: Bool = false,
        volcengineEnabled: Bool = false,
        kimiEnabled: Bool = false,
        openRouterEnabled: Bool = false,
        glmApiKey: String = "",
        glmEndpoint: String = "https://open.bigmodel.cn/api/v1",
        aliyunApiKey: String = "",
        aliyunEndpoint: String = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
        aliyunCookie: String = "",
        aliyunAccessKeyId: String = "",
        aliyunConsoleRegion: String = "cn-beijing",
        aliyunConsoleSite: String = "domestic",
        aliyunConsoleSwitchAgent: Int = 0,
        aliyunReuseCLIConfig: Bool = true,
        aliyunBalanceAlertThreshold: Double = 10,
        openAIApiKey: String = "",
        openAIEndpoint: String = "https://api.openai.com/v1",
        openAIOrgId: String = "",
        anthropicApiKey: String = "",
        anthropicEndpoint: String = "https://api.anthropic.com/v1",
        claudeToken: String = "",
        geminiApiKey: String = "",
        geminiEndpoint: String = "https://generativelanguage.googleapis.com",
        geminiToken: String = "",
        deepseekApiKey: String = "",
        deepseekEndpoint: String = "https://api.deepseek.com/v1",
        deepseekModel: String = "deepseek-chat",
        deepseekBalanceAlertThreshold: Double = 10,
        volcengineApiKey: String = "",
        volcengineEndpoint: String = "https://ark.cn-beijing.volces.com/api/v3",
        volcengineModel: String = "",
        kimiApiKey: String = "",
        kimiEndpoint: String = "https://api.moonshot.cn/v1",
        kimiModel: String = "moonshot-v1-8k",
        kimiBalanceAlertThreshold: Double = 10,
        openRouterApiKey: String = "",
        openRouterEndpoint: String = "https://openrouter.ai/api/v1",
        openRouterBalanceAlertThreshold: Double = 5,
        customProviders: [CustomProviderConfig] = [],
        appLanguage: AppLanguage = .system,
        providerOrder: [String] = [],
        menuBarQuotaEnabled: Bool = false,
        menuBarProviderKey: String = "",
        menuBarMetric: MenuBarMetric = .auto
    ) {
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.enableHover = enableHover
        self.launchAtLogin = launchAtLogin
        self.claudeEnabled = claudeEnabled
        self.geminiEnabled = geminiEnabled
        self.glmEnabled = glmEnabled
        self.aliyunEnabled = aliyunEnabled
        self.openAIEnabled = openAIEnabled
        self.deepseekEnabled = deepseekEnabled
        self.volcengineEnabled = volcengineEnabled
        self.kimiEnabled = kimiEnabled
        self.openRouterEnabled = openRouterEnabled
        self.glmApiKey = glmApiKey
        self.glmEndpoint = glmEndpoint
        self.aliyunApiKey = aliyunApiKey
        self.aliyunEndpoint = aliyunEndpoint
        self.aliyunCookie = aliyunCookie
        self.aliyunAccessKeyId = aliyunAccessKeyId
        self.aliyunConsoleRegion = aliyunConsoleRegion
        self.aliyunConsoleSite = aliyunConsoleSite
        self.aliyunConsoleSwitchAgent = aliyunConsoleSwitchAgent
        self.aliyunReuseCLIConfig = aliyunReuseCLIConfig
        self.aliyunBalanceAlertThreshold = aliyunBalanceAlertThreshold
        self.openAIApiKey = openAIApiKey
        self.openAIEndpoint = openAIEndpoint
        self.openAIOrgId = openAIOrgId
        self.anthropicApiKey = anthropicApiKey
        self.anthropicEndpoint = anthropicEndpoint
        self.claudeToken = claudeToken
        self.geminiApiKey = geminiApiKey
        self.geminiEndpoint = geminiEndpoint
        self.geminiToken = geminiToken
        self.deepseekApiKey = deepseekApiKey
        self.deepseekEndpoint = deepseekEndpoint
        self.deepseekModel = deepseekModel
        self.deepseekBalanceAlertThreshold = deepseekBalanceAlertThreshold
        self.volcengineApiKey = volcengineApiKey
        self.volcengineEndpoint = volcengineEndpoint
        self.volcengineModel = volcengineModel
        self.kimiApiKey = kimiApiKey
        self.kimiEndpoint = kimiEndpoint
        self.kimiModel = kimiModel
        self.kimiBalanceAlertThreshold = kimiBalanceAlertThreshold
        self.openRouterApiKey = openRouterApiKey
        self.openRouterEndpoint = openRouterEndpoint
        self.openRouterBalanceAlertThreshold = openRouterBalanceAlertThreshold
        self.customProviders = customProviders
        self.appLanguage = appLanguage
        self.providerOrder = providerOrder
        self.menuBarQuotaEnabled = menuBarQuotaEnabled
        self.menuBarProviderKey = menuBarProviderKey
        self.menuBarMetric = menuBarMetric
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.refreshIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalMinutes) ?? 5
        self.enableHover = try container.decodeIfPresent(Bool.self, forKey: .enableHover) ?? true
        self.launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        self.claudeEnabled = try container.decodeIfPresent(Bool.self, forKey: .claudeEnabled) ?? true
        self.geminiEnabled = try container.decodeIfPresent(Bool.self, forKey: .geminiEnabled) ?? true
        self.glmEnabled = try container.decodeIfPresent(Bool.self, forKey: .glmEnabled) ?? true
        self.aliyunEnabled = try container.decodeIfPresent(Bool.self, forKey: .aliyunEnabled) ?? true
        self.openAIEnabled = try container.decodeIfPresent(Bool.self, forKey: .openAIEnabled) ?? false
        self.deepseekEnabled = try container.decodeIfPresent(Bool.self, forKey: .deepseekEnabled) ?? false
        self.volcengineEnabled = try container.decodeIfPresent(Bool.self, forKey: .volcengineEnabled) ?? false
        self.kimiEnabled = try container.decodeIfPresent(Bool.self, forKey: .kimiEnabled) ?? false
        self.openRouterEnabled = try container.decodeIfPresent(Bool.self, forKey: .openRouterEnabled) ?? false

        self.glmApiKey = try container.decodeIfPresent(String.self, forKey: .glmApiKey) ?? ""
        self.glmEndpoint = try container.decodeIfPresent(String.self, forKey: .glmEndpoint) ?? "https://open.bigmodel.cn/api/v1"
        self.aliyunApiKey = try container.decodeIfPresent(String.self, forKey: .aliyunApiKey) ?? ""
        self.aliyunEndpoint = try container.decodeIfPresent(String.self, forKey: .aliyunEndpoint) ?? "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
        self.aliyunCookie = try container.decodeIfPresent(String.self, forKey: .aliyunCookie) ?? ""
        self.aliyunAccessKeyId = try container.decodeIfPresent(String.self, forKey: .aliyunAccessKeyId) ?? ""
        self.aliyunConsoleRegion = try container.decodeIfPresent(String.self, forKey: .aliyunConsoleRegion) ?? "cn-beijing"
        self.aliyunConsoleSite = try container.decodeIfPresent(String.self, forKey: .aliyunConsoleSite) ?? "domestic"
        self.aliyunConsoleSwitchAgent = try container.decodeIfPresent(Int.self, forKey: .aliyunConsoleSwitchAgent) ?? 0
        self.aliyunReuseCLIConfig = try container.decodeIfPresent(Bool.self, forKey: .aliyunReuseCLIConfig) ?? true
        self.aliyunBalanceAlertThreshold = try container.decodeIfPresent(Double.self, forKey: .aliyunBalanceAlertThreshold) ?? 10

        self.openAIApiKey = try container.decodeIfPresent(String.self, forKey: .openAIApiKey) ?? ""
        self.openAIEndpoint = try container.decodeIfPresent(String.self, forKey: .openAIEndpoint) ?? "https://api.openai.com/v1"
        self.openAIOrgId = try container.decodeIfPresent(String.self, forKey: .openAIOrgId) ?? ""

        self.anthropicApiKey = try container.decodeIfPresent(String.self, forKey: .anthropicApiKey) ?? ""
        self.anthropicEndpoint = try container.decodeIfPresent(String.self, forKey: .anthropicEndpoint) ?? "https://api.anthropic.com/v1"
        self.claudeToken = try container.decodeIfPresent(String.self, forKey: .claudeToken) ?? ""
        self.geminiApiKey = try container.decodeIfPresent(String.self, forKey: .geminiApiKey) ?? ""
        self.geminiEndpoint = try container.decodeIfPresent(String.self, forKey: .geminiEndpoint) ?? "https://generativelanguage.googleapis.com"
        self.geminiToken = try container.decodeIfPresent(String.self, forKey: .geminiToken) ?? ""

        self.deepseekApiKey = try container.decodeIfPresent(String.self, forKey: .deepseekApiKey) ?? ""
        self.deepseekEndpoint = try container.decodeIfPresent(String.self, forKey: .deepseekEndpoint) ?? "https://api.deepseek.com/v1"
        self.deepseekModel = try container.decodeIfPresent(String.self, forKey: .deepseekModel) ?? "deepseek-chat"
        self.deepseekBalanceAlertThreshold = try container.decodeIfPresent(Double.self, forKey: .deepseekBalanceAlertThreshold) ?? 10

        self.volcengineApiKey = try container.decodeIfPresent(String.self, forKey: .volcengineApiKey) ?? ""
        self.volcengineEndpoint = try container.decodeIfPresent(String.self, forKey: .volcengineEndpoint) ?? "https://ark.cn-beijing.volces.com/api/v3"
        self.volcengineModel = try container.decodeIfPresent(String.self, forKey: .volcengineModel) ?? ""

        self.kimiApiKey = try container.decodeIfPresent(String.self, forKey: .kimiApiKey) ?? ""
        self.kimiEndpoint = try container.decodeIfPresent(String.self, forKey: .kimiEndpoint) ?? "https://api.moonshot.cn/v1"
        self.kimiModel = try container.decodeIfPresent(String.self, forKey: .kimiModel) ?? "moonshot-v1-8k"
        self.kimiBalanceAlertThreshold = try container.decodeIfPresent(Double.self, forKey: .kimiBalanceAlertThreshold) ?? 10

        self.openRouterApiKey = try container.decodeIfPresent(String.self, forKey: .openRouterApiKey) ?? ""
        self.openRouterEndpoint = try container.decodeIfPresent(String.self, forKey: .openRouterEndpoint) ?? "https://openrouter.ai/api/v1"
        self.openRouterBalanceAlertThreshold = try container.decodeIfPresent(Double.self, forKey: .openRouterBalanceAlertThreshold) ?? 5

        self.customProviders = try container.decodeIfPresent([CustomProviderConfig].self, forKey: .customProviders) ?? []
        self.appLanguage = try container.decodeIfPresent(AppLanguage.self, forKey: .appLanguage) ?? .system
        self.providerOrder = try container.decodeIfPresent([String].self, forKey: .providerOrder) ?? []
        self.menuBarQuotaEnabled = try container.decodeIfPresent(Bool.self, forKey: .menuBarQuotaEnabled) ?? false
        self.menuBarProviderKey = try container.decodeIfPresent(String.self, forKey: .menuBarProviderKey) ?? ""
        self.menuBarMetric = try container.decodeIfPresent(MenuBarMetric.self, forKey: .menuBarMetric) ?? .auto
    }

    public static let defaultSettings = AppSettings()
}

extension AppSettings {
    /// 内置厂商是否已开启监控
    public func isEnabled(_ type: ProviderType) -> Bool {
        switch type {
        case .openAI: return openAIEnabled
        case .claudeCode: return claudeEnabled
        case .gemini: return geminiEnabled
        case .deepseek: return deepseekEnabled
        case .volcengine: return volcengineEnabled
        case .kimi: return kimiEnabled
        case .openRouter: return openRouterEnabled
        case .glm: return glmEnabled
        case .aliyunBailian: return aliyunEnabled
        }
    }
}

public enum SettingsTab: String, CaseIterable, Identifiable {
    case openAI = "openAI"
    case anthropic = "anthropic"
    case gemini = "gemini"
    case deepseek = "deepseek"
    case volcengine = "volcengine"
    case kimi = "kimi"
    case openRouter = "openRouter"
    case glm = "glm"
    case aliyun = "aliyun"
    case custom = "custom"
    case displayOrder = "displayOrder"
    case general = "general"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        case .deepseek: return "DeepSeek"
        case .volcengine: return I18n(.volcengineTitle)
        case .kimi: return I18n(.kimiTitle)
        case .openRouter: return "OpenRouter"
        case .glm: return I18n(.glmTitle)
        case .aliyun: return I18n(.aliyunTitle)
        case .custom: return I18n(.customProviders)
        case .displayOrder: return I18n(.displayOrder)
        case .general: return I18n(.generalSettings)
        }
    }

    public var icon: String {
        switch self {
        case .openAI: return "circle.hexagonpath.fill"
        case .anthropic: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .deepseek: return "bolt.horizontal.fill"
        case .volcengine: return "flame.fill"
        case .kimi: return "moon.stars.fill"
        case .openRouter: return "creditcard.fill"
        case .glm: return "bolt.fill"
        case .aliyun: return "cloud.fill"
        case .custom: return "network"
        case .displayOrder: return "arrow.up.arrow.down"
        case .general: return "gearshape"
        }
    }
}

extension ProviderType {
    public var settingsTab: SettingsTab {
        switch self {
        case .openAI: return .openAI
        case .claudeCode: return .anthropic
        case .gemini: return .gemini
        case .deepseek: return .deepseek
        case .volcengine: return .volcengine
        case .kimi: return .kimi
        case .openRouter: return .openRouter
        case .glm: return .glm
        case .aliyunBailian: return .aliyun
        }
    }
}


