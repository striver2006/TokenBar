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
        case .volcengine: return Color(red: 0.0, green: 0.43, blue: 1.0)  // Volcengine Blue（官方品牌蓝 #006EFF）
        case .kimi: return Color(red: 0.55, green: 0.35, blue: 0.92)     // Moonshot Purple
        case .openRouter: return Color(red: 0.39, green: 0.40, blue: 0.95) // OpenRouter Indigo
        case .glm: return Color(red: 0.23, green: 0.72, blue: 0.53)      // GLM emerald green
        case .aliyunBailian: return Color(red: 1.0, green: 0.42, blue: 0.0) // Aliyun Orange
        }
    }
}

/// 额度窗口展示类型：percentage 为时间窗口百分比，balance 为纯扣费厂商的货币余额，
/// status 为「只探测到连通性、拿不到真实额度」的状态型窗口（只渲染标题与状态点，
/// 不渲染「剩余 x%」、进度条与倒计时——那些数字没有数据来源，画出来就是假数据）。
public enum TokenWindowKind: String, Codable {
    case percentage
    case balance
    case status
}

/// 窗口标题的语义枚举：标题不再以中文串形态在代码里漂流，
/// 翻译（localized）与角标（badgePeriod）都从这里穷尽 switch 派生。
/// 新服务接入时必须选定一个 case（真正动态的标题走 .custom），
/// 编译器保证漏登记的 case 无法通过 localized 的穷尽检查——消灭静默漏译。
public enum WindowTitle: Equatable, Codable {
    case fiveHour                // 5小时额度
    case fiveHourCompute         // 5小时算力额度
    case weekly                  // 每周额度
    case monthly                 // 月度额度（历史文案「每月额度」也归并到这里）
    case sevenDays               // 7天周期额度
    case tpmRate                 // TPM 速率配额
    case tpmRemaining            // TPM 速率剩余
    case rpmRate                 // RPM 速率配额
    case rpmRequest              // RPM 请求速率
    case tokenRate               // Token 速率配额
    case accountBalance          // 账户余额
    case accountAvailableBalance // 账户可用余额
    case keyQuota                // Key 可用额度
    case tokenPlan               // Token Plan 额度
    case aiStudioQuota           // AI Studio 配额
    case connected(subject: String? = nil)  // 「XX 连接正常」类状态窗；subject 为品牌/通道名，nil 显示「API 连接正常」
    case availableModels(count: Int)  // 可用模型 (N个)
    case custom(String)          // 真正的动态标题（如 Claude 按模型的周额度用模型名），原样显示

    /// 规范中文标题（中文界面的展示文案，也是历史字符串标题的对照基准）
    public var zhTitle: String {
        switch self {
        case .fiveHour: return "5小时额度"
        case .fiveHourCompute: return "5小时算力额度"
        case .weekly: return "每周额度"
        case .monthly: return "月度额度"
        case .sevenDays: return "7天周期额度"
        case .tpmRate: return "TPM 速率配额"
        case .tpmRemaining: return "TPM 速率剩余"
        case .rpmRate: return "RPM 速率配额"
        case .rpmRequest: return "RPM 请求速率"
        case .tokenRate: return "Token 速率配额"
        case .accountBalance: return "账户余额"
        case .accountAvailableBalance: return "账户可用余额"
        case .keyQuota: return "Key 可用额度"
        case .tokenPlan: return "Token Plan 额度"
        case .aiStudioQuota: return "AI Studio 配额"
        case .connected(let subject):
            guard let subject, !subject.isEmpty else { return "API 连接正常" }
            // ASCII 开头的主体（KIMI/OpenRouter/Anthropic API 等）用空格分隔，
            // 中文主体（接入点/接口）直接连排——与迁移前各服务的原文逐字一致
            let separator = subject.first?.isASCII == true ? " " : ""
            return "\(subject)\(separator)连接正常"
        case .availableModels(let count): return "可用模型 (\(count)个)"
        case .custom(let text): return text
        }
    }

    /// 当前语言的展示标题：中文返回 zhTitle，英文穷尽映射到 I18nKey。
    public var localized: String {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        if isZh { return zhTitle }
        switch self {
        case .fiveHour: return I18n(.fiveHourQuotaTitle)
        case .fiveHourCompute: return I18n(.fiveHourComputeQuotaTitle)
        case .weekly: return I18n(.weeklyQuotaTitle)
        case .monthly: return I18n(.monthlyQuotaTitle)
        case .sevenDays: return I18n(.sevenDaysQuotaTitle)
        case .tpmRate, .tpmRemaining: return I18n(.tpmRateLimitTitle)
        case .rpmRate, .rpmRequest: return I18n(.rpmRateLimitTitle)
        case .tokenRate: return I18n(.tokenRateLimitTitle)
        case .accountBalance, .accountAvailableBalance: return I18n(.accountBalanceTitle)
        case .keyQuota: return I18n(.keyQuotaTitle)
        case .tokenPlan: return I18n(.tokenPlanQuotaTitle)
        case .aiStudioQuota: return I18n(.aiStudioQuotaTitle)
        case .connected: return I18n(.apiConnectedTitle)
        case .availableModels(let count): return "Available Models (\(count))"
        case .custom(let text): return text
        }
    }

    /// 角标周期语义。与旧版 contains("5小时")/contains("月")/contains("7天")/contains("周")
    /// 对全部登记标题的推断结果一一对应；速率/余额/状态/模型数窗口本来推断不出（走 fallback），
    /// 动态标题（.custom，如模型名）同样返回 nil 交给调用方的槽位默认角标。
    public enum BadgePeriod {
        case fiveHour
        case weekly
        case monthly
    }

    public var badgePeriod: BadgePeriod? {
        switch self {
        case .fiveHour, .fiveHourCompute: return .fiveHour
        case .monthly: return .monthly
        case .weekly, .sevenDays: return .weekly
        case .tpmRate, .tpmRemaining, .rpmRate, .rpmRequest, .tokenRate,
             .accountBalance, .accountAvailableBalance, .keyQuota, .tokenPlan,
             .aiStudioQuota, .connected, .availableModels, .custom:
            return nil
        }
    }

    /// 自定义厂商卡片的次槽位角标用：是否 TPM 类速率窗口
    /// （取代旧的 `title.uppercased().contains("TPM")` 字符串嗅探）。
    public var isTpmKind: Bool {
        switch self {
        case .tpmRate, .tpmRemaining: return true
        case .fiveHour, .fiveHourCompute, .weekly, .monthly, .sevenDays,
             .rpmRate, .rpmRequest, .tokenRate,
             .accountBalance, .accountAvailableBalance, .keyQuota, .tokenPlan,
             .aiStudioQuota, .connected, .availableModels, .custom:
            return false
        }
    }

    /// 历史字符串标题 → 语义枚举（仅用于解码旧格式 JSON 的兼容层；
    /// TokenWindow 并不持久化到磁盘，这层映射是防御性的）。
    /// 未登记的字符串按 .custom 原样保留，与旧 localizedTitle 的 default 分支行为一致。
    public init(legacyTitle: String) {
        switch legacyTitle {
        case "5小时额度": self = .fiveHour
        case "5小时算力额度": self = .fiveHourCompute
        case "每周额度": self = .weekly
        case "每月额度", "月度额度": self = .monthly
        case "7天额度", "7天周期额度": self = .sevenDays
        case "TPM 速率配额": self = .tpmRate
        case "TPM 速率剩余": self = .tpmRemaining
        case "RPM 速率配额": self = .rpmRate
        case "RPM 请求速率": self = .rpmRequest
        case "Token 速率配额": self = .tokenRate
        case "账户余额": self = .accountBalance
        case "账户可用余额": self = .accountAvailableBalance
        case "Key 额度", "Key 可用额度": self = .keyQuota
        case "Token Plan 额度": self = .tokenPlan
        case "AI Studio 配额": self = .aiStudioQuota
        case "API 连接正常", "API 连接状态": self = .connected()
        case "接口连接正常": self = .connected(subject: "接口")
        case "接入点连接正常": self = .connected(subject: "接入点")
        case "Anthropic 协议连接正常": self = .connected(subject: "Anthropic 协议")
        case "Anthropic API 连接正常": self = .connected(subject: "Anthropic API")
        case "DeepSeek 连接正常": self = .connected(subject: "DeepSeek")
        case "KIMI 连接正常": self = .connected(subject: "KIMI")
        case "OpenRouter 连接正常": self = .connected(subject: "OpenRouter")
        default:
            if legacyTitle.hasPrefix("可用模型 ("),
               let count = Int(legacyTitle.filter { $0.isNumber }) {
                self = .availableModels(count: count)
            } else {
                self = .custom(legacyTitle)
            }
        }
    }
}

public struct TokenWindow: Identifiable, Codable {
    public var id = UUID()
    /// 标题的语义来源；展示一律经 `title` / `localizedTitle` 派生
    public var titleKind: WindowTitle
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

    /// 兼容层：旧格式 JSON 用中文字符串 `title` 存标题；新格式用 `titleKind`。
    /// TokenWindow 只存在于内存态（落盘的只有 AppSettings 与余额历史点），
    /// 这里保留对旧字符串键的解码能力仅为防御（历史版本曾持久化过窗口）。
    enum CodingKeys: String, CodingKey {
        case id, titleKind, usedPercentage, startTime, endTime
        case usedAmount, totalLimit, unit, isIdle
        case kind, balanceAmount, currency, warningThreshold, criticalThreshold
        case lastDelta, forecastDays
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case title
    }

    public init(
        title: WindowTitle,
        usedPercentage: Double,
        startTime: Date,
        endTime: Date,
        usedAmount: Double? = nil,
        totalLimit: Double? = nil,
        unit: String = "%",
        isIdle: Bool = false
    ) {
        self.titleKind = title
        self.usedPercentage = min(max(usedPercentage, 0.0), 100.0)
        self.startTime = startTime
        self.endTime = endTime
        self.usedAmount = usedAmount
        self.totalLimit = totalLimit
        self.unit = unit
        self.isIdle = isIdle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let kind = try c.decodeIfPresent(WindowTitle.self, forKey: .titleKind) {
            titleKind = kind
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            titleKind = WindowTitle(legacyTitle: try legacy.decodeIfPresent(String.self, forKey: .title) ?? "")
        }
        usedPercentage = try c.decode(Double.self, forKey: .usedPercentage)
        startTime = try c.decode(Date.self, forKey: .startTime)
        endTime = try c.decode(Date.self, forKey: .endTime)
        usedAmount = try c.decodeIfPresent(Double.self, forKey: .usedAmount)
        totalLimit = try c.decodeIfPresent(Double.self, forKey: .totalLimit)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? "%"
        isIdle = try c.decodeIfPresent(Bool.self, forKey: .isIdle) ?? false
        kind = try c.decodeIfPresent(TokenWindowKind.self, forKey: .kind)
        balanceAmount = try c.decodeIfPresent(Double.self, forKey: .balanceAmount)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        warningThreshold = try c.decodeIfPresent(Double.self, forKey: .warningThreshold)
        criticalThreshold = try c.decodeIfPresent(Double.self, forKey: .criticalThreshold)
        lastDelta = try c.decodeIfPresent(Double.self, forKey: .lastDelta)
        forecastDays = try c.decodeIfPresent(Double.self, forKey: .forecastDays)
    }

    /// 中文标题（保持既有字符串读取方兼容）；本地化展示请用 `localizedTitle`
    public var title: String { titleKind.zhTitle }

    /// 便捷构造余额窗口
    public static func balance(
        title: WindowTitle,
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

    /// 便捷构造状态型窗口：只表达「接口连通」，没有任何额度数字
    public static func status(title: WindowTitle) -> TokenWindow {
        var w = TokenWindow(title: title, usedPercentage: 0.0, startTime: Date(), endTime: Date().addingTimeInterval(86400), isIdle: true)
        w.kind = .status
        return w
    }

    public var isBalance: Bool { kind == .balance }
    public var isStatus: Bool { kind == .status }

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

    public var localizedTitle: String { titleKind.localized }

    /// 卡片角标按窗口标题的周期语义推断：月度额度显示「每月」而不是槽位默认的「每周」；
    /// 推断不出（如按模型圈定的周额度标题是模型名）时回退调用方按槽位给的默认角标。
    public func badgeLabel(fallback: String) -> String {
        switch titleKind.badgePeriod {
        case .fiveHour: return I18n(.fiveHourWindow)
        case .monthly: return I18n(.monthlyWindow)
        case .weekly: return I18n(.weeklyWindow)
        case nil: return fallback
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
    /// 第四槽位：按模型圈定的周额度（如 Anthropic 订阅的 Fable/Opus 专属周额度，
    /// 来自 ~/.claude.json limits[] 的 weekly_scoped 条目，title 即模型显示名）。
    /// 没有这类额度的厂商保持 nil，卡片不会渲染这一行。
    public var scopedWeeklyWindow: TokenWindow?
    /// 第三个槽位：与时间窗口额度并存的货币余额（目前用于阿里云百炼的账户现金余额）。
    /// 只用两个槽位的厂商保持 nil，卡片不会渲染这一行。
    public var balanceWindow: TokenWindow?
    public var lastUpdated: Date?
    public var errorMessage: String?
    public var isLoading: Bool
    /// 「配置了但本轮刷新失败」（网络未就绪/超时/服务端错误），与「未配置」区分开：
    /// 卡片据此显示「重试」而非「去配置」，且不清除 isAuthorized 与旧数据，成功后自动回落。
    public var hadRefreshError: Bool
    /// 本轮展示的是厂商客户端的本地缓存而非实时数据。目前只有 Claude：远端查不到时退回
    /// `~/.claude.json` 的 cachedUsageUtilization。卡片据此标注来源与缓存时间，
    /// 免得「更新于」把几小时前的缓存显示成刚拿到的。
    public var isFromLocalCache: Bool
    /// 本地缓存自身的抓取时间（Claude：fetchedAtMs）；缓存里没有时间戳时为 nil
    public var localCacheFetchedAt: Date?

    public init(
        provider: ProviderType,
        isEnabled: Bool = true,
        isAuthorized: Bool = false,
        accountInfo: String? = nil,
        fiveHourWindow: TokenWindow? = nil,
        weeklyWindow: TokenWindow? = nil,
        scopedWeeklyWindow: TokenWindow? = nil,
        balanceWindow: TokenWindow? = nil,
        lastUpdated: Date? = nil,
        errorMessage: String? = nil,
        isLoading: Bool = false,
        hadRefreshError: Bool = false,
        isFromLocalCache: Bool = false,
        localCacheFetchedAt: Date? = nil
    ) {
        self.provider = provider
        self.isEnabled = isEnabled
        self.isAuthorized = isAuthorized
        self.accountInfo = accountInfo
        self.fiveHourWindow = fiveHourWindow
        self.weeklyWindow = weeklyWindow
        self.scopedWeeklyWindow = scopedWeeklyWindow
        self.balanceWindow = balanceWindow
        self.lastUpdated = lastUpdated
        self.errorMessage = errorMessage
        self.isLoading = isLoading
        self.hadRefreshError = hadRefreshError
        self.isFromLocalCache = isFromLocalCache
        self.localCacheFetchedAt = localCacheFetchedAt
    }
}

extension ProviderQuota {
    /// 卡片末尾的数据来源小字（「来自 Claude Code 本地缓存 · 12 分钟前」）；实时数据返回 nil
    public func localCacheNote(now: Date = Date()) -> String? {
        guard isFromLocalCache else { return nil }
        guard let fetchedAt = localCacheFetchedAt else { return I18n(.localCacheNoteNoTime) }
        return String(format: I18n(.localCacheNote), Self.relativeAge(from: fetchedAt, now: now))
    }

    /// 「N 分钟前」式的相对时间。不用 RelativeDateTimeFormatter：它跟系统 locale 走，
    /// 而界面语言由 App 自己的设置决定，混用会出现「来自 Claude Code 本地缓存 · 12 minutes ago」。
    /// 时钟回拨导致的负间隔按「刚刚」处理。
    static func relativeAge(from date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return I18n(.ageJustNow) }
        if seconds < 3600 { return String(format: I18n(.ageMinutesAgo), seconds / 60) }
        if seconds < 86400 { return String(format: I18n(.ageHoursAgo), seconds / 3600) }
        return String(format: I18n(.ageDaysAgo), seconds / 86400)
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
    /// 语义同 ProviderQuota.hadRefreshError
    public var hadRefreshError: Bool

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
        isLoading: Bool = false,
        hadRefreshError: Bool = false
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
        self.hadRefreshError = hadRefreshError
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
    /// 从 ~/.gemini 读到的 Antigravity refresh_token 快照，只存钥匙串。
    /// 文件被 Antigravity 清掉后仍能靠它续期 access_token。
    public var geminiRefreshToken: String
    /// TokenBar 自己的 Google 账号登录绑定的邮箱（展示用；refresh_token 本体在钥匙串）。
    /// 为空表示未用自有登录，走本地 Antigravity 凭证链路。
    public var geminiOwnAccount: String

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

    /// 凭证是否已经全部在钥匙串里。为 true 时 `encode(to:)` 不再把任何 Key / Token / Cookie
    /// 写进 plist；为 false（首次启动、或钥匙串读不到 / 迁移失败）时照旧写明文，
    /// 保证在安全存储可用之前**不会丢掉用户已经配好的凭证**。不参与编解码。
    public var secretsInKeychain: Bool = false

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
        case geminiRefreshToken
        case geminiOwnAccount

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
        geminiRefreshToken: String = "",
        geminiOwnAccount: String = "",
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
        self.geminiRefreshToken = geminiRefreshToken
        self.geminiOwnAccount = geminiOwnAccount
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
        self.geminiRefreshToken = try container.decodeIfPresent(String.self, forKey: .geminiRefreshToken) ?? ""
        self.geminiOwnAccount = try container.decodeIfPresent(String.self, forKey: .geminiOwnAccount) ?? ""

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

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(refreshIntervalMinutes, forKey: .refreshIntervalMinutes)
        try c.encode(enableHover, forKey: .enableHover)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(claudeEnabled, forKey: .claudeEnabled)
        try c.encode(geminiEnabled, forKey: .geminiEnabled)
        try c.encode(glmEnabled, forKey: .glmEnabled)
        try c.encode(aliyunEnabled, forKey: .aliyunEnabled)
        try c.encode(openAIEnabled, forKey: .openAIEnabled)
        try c.encode(deepseekEnabled, forKey: .deepseekEnabled)
        try c.encode(volcengineEnabled, forKey: .volcengineEnabled)
        try c.encode(kimiEnabled, forKey: .kimiEnabled)
        try c.encode(openRouterEnabled, forKey: .openRouterEnabled)

        try c.encode(glmEndpoint, forKey: .glmEndpoint)
        try c.encode(aliyunEndpoint, forKey: .aliyunEndpoint)
        try c.encode(aliyunAccessKeyId, forKey: .aliyunAccessKeyId)
        try c.encode(aliyunConsoleRegion, forKey: .aliyunConsoleRegion)
        try c.encode(aliyunConsoleSite, forKey: .aliyunConsoleSite)
        try c.encode(aliyunConsoleSwitchAgent, forKey: .aliyunConsoleSwitchAgent)
        try c.encode(aliyunReuseCLIConfig, forKey: .aliyunReuseCLIConfig)
        try c.encode(aliyunBalanceAlertThreshold, forKey: .aliyunBalanceAlertThreshold)
        try c.encode(openAIEndpoint, forKey: .openAIEndpoint)
        try c.encode(openAIOrgId, forKey: .openAIOrgId)
        try c.encode(anthropicEndpoint, forKey: .anthropicEndpoint)
        try c.encode(geminiEndpoint, forKey: .geminiEndpoint)
        try c.encode(deepseekEndpoint, forKey: .deepseekEndpoint)
        try c.encode(deepseekModel, forKey: .deepseekModel)
        try c.encode(deepseekBalanceAlertThreshold, forKey: .deepseekBalanceAlertThreshold)
        try c.encode(volcengineEndpoint, forKey: .volcengineEndpoint)
        try c.encode(volcengineModel, forKey: .volcengineModel)
        try c.encode(kimiEndpoint, forKey: .kimiEndpoint)
        try c.encode(kimiModel, forKey: .kimiModel)
        try c.encode(kimiBalanceAlertThreshold, forKey: .kimiBalanceAlertThreshold)
        try c.encode(openRouterEndpoint, forKey: .openRouterEndpoint)
        try c.encode(openRouterBalanceAlertThreshold, forKey: .openRouterBalanceAlertThreshold)
        try c.encode(appLanguage, forKey: .appLanguage)
        try c.encode(providerOrder, forKey: .providerOrder)
        try c.encode(menuBarQuotaEnabled, forKey: .menuBarQuotaEnabled)
        try c.encode(menuBarProviderKey, forKey: .menuBarProviderKey)
        try c.encode(menuBarMetric, forKey: .menuBarMetric)

        // 凭证字段：已进钥匙串则一律不落盘（写空串而不是省略键，便于 plist 里旧值被覆盖清掉）
        if secretsInKeychain {
            for field in AppSecrets.builtinFields {
                try c.encode("", forKey: Self.codingKey(for: field.key))
            }
            try c.encode(customProviders.map { $0.strippingSecrets() }, forKey: .customProviders)
        } else {
            for field in AppSecrets.builtinFields {
                try c.encode(field.get(self), forKey: Self.codingKey(for: field.key))
            }
            try c.encode(customProviders, forKey: .customProviders)
        }
    }

    private static func codingKey(for key: SecretKey) -> CodingKeys {
        // account 名与 CodingKeys 的 rawValue 刻意同名
        guard let ck = CodingKeys(rawValue: key.account) else {
            preconditionFailure("SecretKey \(key.account) 没有对应的 AppSettings 字段")
        }
        return ck
    }

    public static let defaultSettings = AppSettings()
}

extension CustomProviderConfig {
    /// 去掉凭证字段后的副本，供落盘用
    public func strippingSecrets() -> CustomProviderConfig {
        var copy = self
        copy.apiKey = ""
        copy.consoleCookie = ""
        return copy
    }
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


