import Foundation
import SwiftUI

public enum ProviderType: String, CaseIterable, Identifiable, Codable {
    case openAI = "openAI"
    case claudeCode = "claudeCode"
    case gemini = "gemini"
    case deepseek = "deepseek"
    case volcengine = "volcengine"
    case kimi = "kimi"
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
        case .glm: return Color(red: 0.23, green: 0.72, blue: 0.53)      // GLM emerald green
        case .aliyunBailian: return Color(red: 1.0, green: 0.42, blue: 0.0) // Aliyun Orange
        }
    }
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

    public var remainingPercentage: Double {
        return max(0.0, 100.0 - usedPercentage)
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

    public init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        apiKey: String = "",
        endpoint: String = "http://localhost:3000/v1",
        apiProtocol: ApiProtocol = .openAIChat,
        model: String = ""
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.apiProtocol = apiProtocol
        self.model = model
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

    public var glmApiKey: String
    public var glmEndpoint: String
    public var aliyunApiKey: String
    public var aliyunEndpoint: String
    public var aliyunCookie: String

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

    public var volcengineApiKey: String
    public var volcengineEndpoint: String
    public var volcengineModel: String

    public var kimiApiKey: String
    public var kimiEndpoint: String
    public var kimiModel: String

    public var customProviders: [CustomProviderConfig]
    public var appLanguage: AppLanguage

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

        case glmApiKey
        case glmEndpoint
        case aliyunApiKey
        case aliyunEndpoint
        case aliyunCookie

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

        case volcengineApiKey
        case volcengineEndpoint
        case volcengineModel

        case kimiApiKey
        case kimiEndpoint
        case kimiModel

        case customProviders
        case appLanguage
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
        glmApiKey: String = "",
        glmEndpoint: String = "https://open.bigmodel.cn/api/v1",
        aliyunApiKey: String = "",
        aliyunEndpoint: String = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
        aliyunCookie: String = "",
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
        volcengineApiKey: String = "",
        volcengineEndpoint: String = "https://ark.cn-beijing.volces.com/api/v3",
        volcengineModel: String = "",
        kimiApiKey: String = "",
        kimiEndpoint: String = "https://api.moonshot.cn/v1",
        kimiModel: String = "moonshot-v1-8k",
        customProviders: [CustomProviderConfig] = [],
        appLanguage: AppLanguage = .system
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
        self.glmApiKey = glmApiKey
        self.glmEndpoint = glmEndpoint
        self.aliyunApiKey = aliyunApiKey
        self.aliyunEndpoint = aliyunEndpoint
        self.aliyunCookie = aliyunCookie
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
        self.volcengineApiKey = volcengineApiKey
        self.volcengineEndpoint = volcengineEndpoint
        self.volcengineModel = volcengineModel
        self.kimiApiKey = kimiApiKey
        self.kimiEndpoint = kimiEndpoint
        self.kimiModel = kimiModel
        self.customProviders = customProviders
        self.appLanguage = appLanguage
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

        self.glmApiKey = try container.decodeIfPresent(String.self, forKey: .glmApiKey) ?? ""
        self.glmEndpoint = try container.decodeIfPresent(String.self, forKey: .glmEndpoint) ?? "https://open.bigmodel.cn/api/v1"
        self.aliyunApiKey = try container.decodeIfPresent(String.self, forKey: .aliyunApiKey) ?? ""
        self.aliyunEndpoint = try container.decodeIfPresent(String.self, forKey: .aliyunEndpoint) ?? "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
        self.aliyunCookie = try container.decodeIfPresent(String.self, forKey: .aliyunCookie) ?? ""

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

        self.volcengineApiKey = try container.decodeIfPresent(String.self, forKey: .volcengineApiKey) ?? ""
        self.volcengineEndpoint = try container.decodeIfPresent(String.self, forKey: .volcengineEndpoint) ?? "https://ark.cn-beijing.volces.com/api/v3"
        self.volcengineModel = try container.decodeIfPresent(String.self, forKey: .volcengineModel) ?? ""

        self.kimiApiKey = try container.decodeIfPresent(String.self, forKey: .kimiApiKey) ?? ""
        self.kimiEndpoint = try container.decodeIfPresent(String.self, forKey: .kimiEndpoint) ?? "https://api.moonshot.cn/v1"
        self.kimiModel = try container.decodeIfPresent(String.self, forKey: .kimiModel) ?? "moonshot-v1-8k"

        self.customProviders = try container.decodeIfPresent([CustomProviderConfig].self, forKey: .customProviders) ?? []
        self.appLanguage = try container.decodeIfPresent(AppLanguage.self, forKey: .appLanguage) ?? .system
    }

    public static let defaultSettings = AppSettings()
}

public enum SettingsTab: String, CaseIterable, Identifiable {
    case openAI = "openAI"
    case anthropic = "anthropic"
    case gemini = "gemini"
    case deepseek = "deepseek"
    case volcengine = "volcengine"
    case kimi = "kimi"
    case glm = "glm"
    case aliyun = "aliyun"
    case custom = "custom"
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
        case .glm: return I18n(.glmTitle)
        case .aliyun: return I18n(.aliyunTitle)
        case .custom: return I18n(.customProviders)
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
        case .glm: return "bolt.fill"
        case .aliyun: return "cloud.fill"
        case .custom: return "network"
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
        case .glm: return .glm
        case .aliyunBailian: return .aliyun
        }
    }
}


