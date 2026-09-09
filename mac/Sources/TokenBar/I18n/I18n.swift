import Foundation
import SwiftUI
import Combine

public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system:
            return LocalizationManager.shared.effectiveLanguage == "zh" ? "跟随系统" : "System"
        case .zhHans:
            return "简体中文"
        case .en:
            return "English"
        }
    }
}

public enum I18nKey: String {
    // App & Header
    case appName
    case subtitle
    case refresh
    case refreshing
    case ready
    case updatedAt
    case openSettings
    case quitApp

    // Windows & Quotas
    case fiveHourWindow
    case weeklyWindow
    case remaining
    case unusedFull
    case resetTimeReached
    case fiveHourIdle
    case configure
    case notAuthorized
    case syncingData
    case serviceOperational
    case timeDaysHours
    case timeHoursMinutes
    case timeMinutes

    // Settings Navigation
    case currentConfigItem
    case generalSettings
    case customProviders
    case displayOrder
    case displayOrderSubtitle
    case displayOrderHint
    case moveUp
    case moveDown
    case resetOrder
    case noEnabledProviders

    // 菜单栏额度摘要
    case menuBarQuotaTitle
    case menuBarQuotaSubtitle
    case menuBarProviderLabel
    case menuBarMetricLabel
    case menuBarMetricAuto
    case menuBarMetricFiveHour
    case menuBarMetricWeekly
    case menuBarMetricBalance
    case menuBarNoProviderSelected
    case menuBarNoData

    // General Preferences Tab
    case generalPreferencesTitle
    case interfaceLanguage
    case refreshInterval
    case refresh1Min
    case refresh5Min
    case refresh15Min
    case refresh30Min
    case refresh60Min
    case enableHoverTitle
    case enableHoverSubtitle
    case launchAtLoginTitle
    case launchAtLoginSubtitle
    case appAboutFooter

    // Provider Tabs & Forms
    case openAITitle
    case openAISubtitle
    case anthropicTitle
    case anthropicSubtitle
    case geminiTitle
    case geminiSubtitle
    case deepseekTitle
    case deepseekSubtitle
    case volcengineTitle
    case volcengineSubtitle
    case kimiTitle
    case kimiSubtitle
    case openRouterTitle
    case openRouterSubtitle
    case glmTitle
    case glmSubtitle
    case aliyunTitle
    case aliyunSubtitle
    case customTitle
    case customSubtitle

    // Status / Actions
    case statusConnected
    case statusNotConnected
    case apiKeyLabel
    case apiEndpointLabel
    case orgIdLabel
    case saveAndTest
    case saveAndConnect
    case clearKey
    case save
    case cancel
    case close
    case addProvider
    case editProvider
    case quickFillPresets
    case providerNameLabel
    case protocolTypeLabel
    case defaultModelLabel
    case noCustomProviders
    case noCustomProvidersHint
    case enableMonitoring
    case alertNotice
    case alertOk

    // Balance (pay-as-you-go) providers
    case balanceBadge
    case balanceVsLast
    case forecastDays
    case forecastCollecting
    case lowBalanceTitle
    case lowBalanceBody
    case balanceThresholdLabel
    case balanceThresholdHint
    case hintOpenRouterKey
    case errMissingOpenRouterKey
    case tokenPlanQuotaTitle
    case consoleCookieLabel
    case consoleCookieHint

    // Placeholders & Secondary Labels
    case placeholderApiKeyOpenAI
    case placeholderApiKeyVolcengine
    case placeholderApiKeyGLM
    case placeholderApiKeyAliyun
    case placeholderOrgId
    case placeholderCustomName
    case placeholderCustomModel
    case defaultCustomProviderName
    case fallbackCustomProviderName

    // Hints & Section Headers
    case hintOpenAIKey
    case hintOpenAIEndpoint
    case methodAnthropicKey
    case labelApiEndpointColon
    case hintAnthropicKey
    case methodClaudeSubscription
    case btnWebLoginRecommended
    case btnReadLocalCLIAuth
    case placeholderClaudeManualToken

    case methodGeminiApiKey
    case labelRecommendedLifetime
    case labelGetKeyColon
    case methodGeminiOAuth
    case btnGoogleWebLogin
    case btnReadLocalGeminiConfig
    case labelManualGeminiToken
    case placeholderGeminiToken

    case hintDeepSeekKey
    case hintVolcengineKey
    case labelVolcengineEndpointId
    case hintKimiKey
    case hintGLMKey
    case glmProtocolTitle
    case glmProtocolOpenAI
    case glmProtocolPaas
    case glmProtocolInternational
    case glmCustomEndpoint

    case aliyunQuotaNoticeTitle
    case aliyunQuotaNoticeDesc
    case aliyunRecommendedAuthTitle
    case btnAliyunTerminalCLI
    case aliyunMethodWebLogin
    case btnAliyunWebLogin
    case hintAliyunKey
    case labelAliyunCookie
    case placeholderAliyunCookie
    case btnAliyunSaveAndRefresh

    // Alert Messages
    case alertOpenAISuccess
    case alertOpenAIFailed
    case alertAnthropicSuccess
    case alertAnthropicFailed
    case alertClaudeWebSuccess
    case alertClaudeLocalSuccess
    case alertClaudeLocalNotFound
    case alertClaudeTokenSaved
    case alertGeminiSuccess
    case alertGeminiWebSuccess
    case alertGeminiLocalSuccess
    case alertGeminiLocalNotFound
    case alertGeminiTokenSaved
    case alertDeepSeekSuccess
    case alertDeepSeekFailed
    case alertVolcengineSuccess
    case alertVolcengineFailed
    case alertKimiSuccess
    case alertKimiFailed
    case alertGLMSuccess
    case alertGLMFailed
    case alertAliyunCLIOpened
    case alertAliyunWebSuccess
    case alertAliyunSuccess
    case alertAliyunFailed
    case alertCustomSavedPrefix
    case alertUnknownError
    case alertCheckKey

    // Menu Items
    case menuAbout
    case menuHide
    case menuHideOthers
    case menuShowAll
    case menuQuit
    case menuRefreshAll
    case menuPreferences
    case menuEdit
    case menuUndo
    case menuRedo
    case menuCut
    case menuCopy
    case menuPaste
    case menuSelectAll
    case menuWindow
    case menuMinimize
    case menuCloseWindow

    // Quota Window Titles
    case fiveHourQuotaTitle
    case weeklyQuotaTitle
    case sevenDaysQuotaTitle
    case accountBalanceTitle
    case keyQuotaTitle
    case rpmRateLimitTitle
    case tpmRateLimitTitle
    case tokenRateLimitTitle
    case fiveHourComputeQuotaTitle
    case apiConnectedTitle

    // Error Messages
    case errMissingAnthropicAuth
    case errMissingGLMKey
    case errMissingOpenAIKey
    case errMissingDeepSeekKey
    case errMissingVolcengineKey
    case errMissingKimiKey
    case errMissingCustomKey
}

public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()

    private let lock = NSLock()
    private var cachedLanguage: AppLanguage = .system

    @Published public var currentLanguage: AppLanguage = .system

    private init() {}

    public var effectiveLanguage: String {
        lock.lock()
        let lang = cachedLanguage
        lock.unlock()
        switch lang {
        case .zhHans:
            return "zh"
        case .en:
            return "en"
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "zh"
            return preferred.starts(with: "zh") ? "zh" : "en"
        }
    }

    public func setLanguage(_ lang: AppLanguage) {
        lock.lock()
        cachedLanguage = lang
        lock.unlock()

        if Thread.isMainThread {
            if self.currentLanguage != lang {
                self.currentLanguage = lang
            }
        } else {
            Task { @MainActor in
                if self.currentLanguage != lang {
                    self.currentLanguage = lang
                }
            }
        }
    }

    public func t(_ key: I18nKey) -> String {
        let isZh = effectiveLanguage == "zh"
        switch key {
        case .appName:
            return "TokenBar"
        case .subtitle:
            return isZh ? "模型额度监控" : "Model Quota Monitor"
        case .refresh:
            return isZh ? "刷新" : "Refresh"
        case .refreshing:
            return isZh ? "刷新中" : "Refreshing"
        case .ready:
            return isZh ? "准备就绪" : "Ready"
        case .updatedAt:
            return isZh ? "更新于: " : "Updated: "
        case .openSettings:
            return isZh ? "打开设置 (Cmd+,)" : "Settings (Cmd+,)"
        case .quitApp:
            return isZh ? "退出 TokenBar" : "Quit TokenBar"

        case .fiveHourWindow:
            return isZh ? "5小时" : "5-Hour"
        case .weeklyWindow:
            return isZh ? "每周" : "Weekly"
        case .remaining:
            return isZh ? "剩余" : "Left"
        case .unusedFull:
            return isZh ? "未消耗 / 100% 充足" : "Unused / 100% Available"
        case .resetTimeReached:
            return isZh ? "已到重置时间 / 刷新中" : "Reset time reached / Refreshing"
        case .fiveHourIdle:
            return isZh ? "5小时窗口已重置 (调用后开启)" : "5h window reset (starts on call)"
        case .configure:
            return isZh ? "去配置" : "Configure"
        case .notAuthorized:
            return isZh ? "尚未完成授权配置" : "Authorization required"
        case .syncingData:
            return isZh ? "正在同步额度信息..." : "Syncing quota data..."
        case .serviceOperational:
            return isZh ? "服务可用，接口正常" : "Operational & healthy"
        case .timeDaysHours:
            return isZh ? "剩余 %d天 %d小时" : "%dd %dh left"
        case .timeHoursMinutes:
            return isZh ? "剩余 %d小时 %d分" : "%dh %dm left"
        case .timeMinutes:
            return isZh ? "剩余 %d分钟" : "%dm left"

        case .currentConfigItem:
            return isZh ? "当前配置项:" : "Current:"
        case .generalSettings:
            return isZh ? "通用设置" : "General"
        case .customProviders:
            return isZh ? "国内厂商 / 自定义" : "Custom Providers"
        case .displayOrder:
            return isZh ? "显示顺序" : "Display Order"
        case .displayOrderSubtitle:
            return isZh ? "调整浮动框中各厂商余额卡片的先后顺序" : "Reorder provider balance cards in the popover"
        case .displayOrderHint:
            return isZh ? "使用上移 / 下移调整顺序，修改立即生效并自动保存；未列出的新启用厂商将排在末尾。" : "Use Move Up / Move Down to reorder. Changes apply to the popover immediately; newly enabled providers are appended at the end."
        case .moveUp:
            return isZh ? "上移" : "Up"
        case .moveDown:
            return isZh ? "下移" : "Down"
        case .resetOrder:
            return isZh ? "恢复默认顺序" : "Reset to Default"
        case .noEnabledProviders:
            return isZh ? "尚未启用任何厂商，请先在各厂商页开启监控" : "No providers enabled yet. Turn on monitoring in each provider tab first."

        case .menuBarQuotaTitle:
            return isZh ? "菜单栏显示额度" : "Show Quota in Menu Bar"
        case .menuBarQuotaSubtitle:
            return isZh ? "在菜单栏图标旁只显示数值，如 34%/67%（5小时/周期剩余）或 45.09（余额）" : "Show values only next to the menu bar icon, e.g. 34%/67% (5-hour / weekly left) or 45.09 (balance)"
        case .menuBarProviderLabel:
            return isZh ? "显示厂商" : "Provider"
        case .menuBarMetricLabel:
            return isZh ? "显示指标" : "Metric"
        case .menuBarMetricAuto:
            return isZh ? "自动（余额优先，额度并列）" : "Auto (balance first, both quotas)"
        case .menuBarMetricFiveHour:
            return isZh ? "5 小时剩余额度" : "5-hour remaining"
        case .menuBarMetricWeekly:
            return isZh ? "周期剩余额度" : "Weekly remaining"
        case .menuBarMetricBalance:
            return isZh ? "账户余额" : "Account balance"
        case .menuBarNoProviderSelected:
            return isZh ? "未选择厂商" : "No provider selected"
        case .menuBarNoData:
            return isZh ? "暂无数据" : "No data"

        case .generalPreferencesTitle:
            return isZh ? "通用偏好设置" : "General Preferences"
        case .interfaceLanguage:
            return isZh ? "界面语言" : "Language"
        case .refreshInterval:
            return isZh ? "定期主动刷新周期" : "Auto-Refresh Interval"
        case .refresh1Min:
            return isZh ? "1 分钟" : "1 Minute"
        case .refresh5Min:
            return isZh ? "5 分钟 (推荐)" : "5 Minutes (Recommended)"
        case .refresh15Min:
            return isZh ? "15 分钟" : "15 Minutes"
        case .refresh30Min:
            return isZh ? "30 分钟" : "30 Minutes"
        case .refresh60Min:
            return isZh ? "60 分钟" : "60 Minutes"
        case .enableHoverTitle:
            return isZh ? "鼠标悬停自动显示小提示浮窗" : "Hover Preview"
        case .enableHoverSubtitle:
            return isZh ? "鼠标移动到状态栏图标上方时自动展示额度卡片" : "Show quota popover when cursor hovers menu bar icon"
        case .launchAtLoginTitle:
            return isZh ? "开机自动启动" : "Launch at Login"
        case .launchAtLoginSubtitle:
            return isZh ? "登录 macOS 时自动在状态栏运行 TokenBar" : "Automatically launch TokenBar when logging into macOS"
        case .appAboutFooter:
            return isZh ? "TokenBar v1.1.0 • 模型额度监控" : "TokenBar v1.1.0 • Model Quota Monitor"

        case .openAITitle:
            return "OpenAI API"
        case .openAISubtitle:
            return isZh ? "配置官方或代理 API KEY，监控 TPM/RPM 速率限制与可用模型" : "Configure API Key to monitor TPM/RPM limits & models"
        case .anthropicTitle:
            return "Anthropic (Claude)"
        case .anthropicSubtitle:
            return isZh ? "同时支持 Anthropic API Key (官方/代理) 与 Claude Code 订阅授权 (网页/本地)" : "Supports Anthropic API Key and Claude Code subscriptions"
        case .geminiTitle:
            return "Google Gemini"
        case .geminiSubtitle:
            return isZh ? "支持 Google AI Studio API Key (永久有效) 或 Google 账号网页/本地凭证" : "Supports Google AI Studio API Key and OAuth credentials"
        case .deepseekTitle:
            return isZh ? "DeepSeek (深度求索) 授权" : "DeepSeek API"
        case .deepseekSubtitle:
            return isZh ? "配置 DeepSeek API Key，自动查询账户可用余额与 TPM/RPM 速率限制" : "Configure DeepSeek API Key to monitor balance & rate limits"
        case .volcengineTitle:
            return isZh ? "火山方舟 (字节跳动)" : "Volcengine Ark (ByteDance)"
        case .volcengineSubtitle:
            return isZh ? "配置火山方舟 API Key，监控大模型接入点与调用配额" : "Configure Ark API Key to monitor model endpoint quotas"
        case .kimiTitle:
            return isZh ? "KIMI (月之暗面)" : "KIMI (Moonshot AI)"
        case .kimiSubtitle:
            return isZh ? "配置 Moonshot API Key，查询账户余额与 RPM/TPM 限额" : "Configure Moonshot API Key to monitor balance & limits"
        case .openRouterTitle:
            return "OpenRouter"
        case .openRouterSubtitle:
            return isZh ? "纯按量扣费聚合平台，监控美元账户余额（查询余额需 Management Key）" : "Pay-as-you-go aggregator: monitor USD balance (Management key required)"
        case .glmTitle:
            return isZh ? "GLM (智谱清言)" : "GLM (Zhipu AI)"
        case .glmSubtitle:
            return isZh ? "配置智谱 BigModel API Key，实时监测账户与接口状态" : "Configure Zhipu BigModel API Key to monitor quota & status"
        case .aliyunTitle:
            return isZh ? "阿里云百炼 (Token Plan)" : "Aliyun Bailian (Token Plan)"
        case .aliyunSubtitle:
            return isZh ? "配置阿里云百炼 DashScope API Key 或 Token Plan 端点" : "Configure DashScope API Key or Token Plan endpoint"
        case .customTitle:
            return isZh ? "国内厂商 / 自定义接口" : "Custom & Domestic Providers"
        case .customSubtitle:
            return isZh ? "支持 OpenAI Chat Completions、OpenAI Response 或 Anthropic 协议" : "Supports OpenAI Chat, Response, and Anthropic protocols"

        case .statusConnected:
            return isZh ? "已连接并可用" : "Connected & Active"
        case .statusNotConnected:
            return isZh ? "未授权连接" : "Not Authorized"
        case .apiKeyLabel:
            return isZh ? "API KEY" : "API Key"
        case .apiEndpointLabel:
            return isZh ? "API 接入端点" : "API Endpoint"
        case .orgIdLabel:
            return isZh ? "组织 ID (OpenAI-Organization, 可选)" : "Organization ID (Optional)"
        case .saveAndTest:
            return isZh ? "保存并测试连接" : "Save & Test Connection"
        case .saveAndConnect:
            return isZh ? "保存并连接" : "Save & Connect"
        case .clearKey:
            return isZh ? "清除 Key" : "Clear Key"
        case .save:
            return isZh ? "保存" : "Save"
        case .cancel:
            return isZh ? "取消" : "Cancel"
        case .close:
            return isZh ? "关闭" : "Close"
        case .addProvider:
            return isZh ? "添加新厂商" : "Add Provider"
        case .editProvider:
            return isZh ? "编辑模型厂商" : "Edit Provider"
        case .quickFillPresets:
            return isZh ? "快捷预填常用国内厂商:" : "Quick Fill Domestic Presets:"
        case .providerNameLabel:
            return isZh ? "厂商名称" : "Provider Name"
        case .protocolTypeLabel:
            return isZh ? "接口协议类型" : "Protocol Type"
        case .defaultModelLabel:
            return isZh ? "默认模型 (可选)" : "Default Model (Optional)"
        case .noCustomProviders:
            return isZh ? "暂未添加任何国内或自定义厂商" : "No custom providers added yet"
        case .noCustomProvidersHint:
            return isZh ? "点击上方「＋ 添加新厂商」可添加硅基流动、MiniMax、通义千问等自定义端点。" : "Click '+ Add Provider' above to add SiliconFlow, MiniMax, etc."
        case .alertNotice:
            return isZh ? "提示" : "Notice"
        case .alertOk:
            return isZh ? "好的" : "OK"
        case .enableMonitoring:
            return isZh ? "启用监控" : "Enable Monitoring"

        case .balanceBadge:
            return isZh ? "余额" : "Balance"
        case .balanceVsLast:
            return isZh ? "较上次 %@" : "Since last %@"
        case .forecastDays:
            return isZh ? "预计可用 ~%.0f 天" : "~%.0f days left"
        case .forecastCollecting:
            return isZh ? "消耗统计中…" : "Collecting usage stats…"
        case .lowBalanceTitle:
            return isZh ? "余额不足提醒" : "Low Balance"
        case .lowBalanceBody:
            return isZh ? "%@ 余额仅剩 %@，请及时充值" : "%@ balance is low: %@. Please top up."
        case .balanceThresholdLabel:
            return isZh ? "余额提醒阈值 (按账户币种)" : "Low-balance Alert Threshold (account currency)"
        case .balanceThresholdHint:
            return isZh ? "余额低于该值时通知提醒，并在额度卡片中变为橙/红色。" : "A notification is shown and the balance turns orange/red when below this value."
        case .hintOpenRouterKey:
            return isZh ? "可在 openrouter.ai/keys 创建。普通 Key 仅能查询自身用量；查询账户余额请使用后台创建的 Management Key。" : "Create at openrouter.ai/keys. Regular keys expose per-key usage only; use a Management Key to query the account balance."
        case .errMissingOpenRouterKey:
            return isZh ? "请在配置中输入 OpenRouter API Key" : "Please enter OpenRouter API Key in settings"
        case .tokenPlanQuotaTitle:
            return isZh ? "Token Plan 额度" : "Token Plan Quota"
        case .consoleCookieLabel:
            return isZh ? "控制台 Cookie (选填)" : "Console Cookie (optional)"
        case .consoleCookieHint:
            return isZh ? "小米 MiMo 等厂商的余额与套餐用量查询需要官网登录态：浏览器登录后按 F12 -> 网络 复制请求 Cookie 粘贴于此。" : "Balance/plan queries for vendors like Xiaomi MiMo require the web session cookie: log in, press F12 -> Network, copy the request Cookie and paste it here."

        // Placeholders & Secondary Labels
        case .placeholderApiKeyOpenAI:
            return isZh ? "sk-... 或 sk-proj-..." : "sk-... or sk-proj-..."
        case .placeholderApiKeyVolcengine:
            return isZh ? "sk-... 或 API Key" : "sk-... or API Key"
        case .placeholderApiKeyGLM:
            return isZh ? "例如: 75f...your_api_key" : "e.g. 75f...your_api_key"
        case .placeholderApiKeyAliyun:
            return isZh ? "例如: sk-sp-xxxxxxxx" : "e.g. sk-sp-xxxxxxxx"
        case .placeholderOrgId:
            return isZh ? "org-xxxxxxxx (选填)" : "org-xxxxxxxx (Optional)"
        case .placeholderCustomName:
            return isZh ? "例如: OpenAI 兼容代理" : "e.g. OpenAI Compatible Proxy"
        case .placeholderCustomModel:
            return isZh ? "例如: deepseek-chat 或 claude-3-5-sonnet" : "e.g. deepseek-chat or claude-3-5-sonnet"
        case .defaultCustomProviderName:
            return isZh ? "OpenAI 兼容代理" : "OpenAI Compatible Proxy"
        case .fallbackCustomProviderName:
            return isZh ? "自定义厂商" : "Custom Provider"

        // Hints & Section Headers
        case .hintOpenAIKey:
            return isZh ? "可在 OpenAI Platform (platform.openai.com) -> API Keys 中生成。" : "Can be generated in OpenAI Platform (platform.openai.com) -> API Keys."
        case .hintOpenAIEndpoint:
            return isZh ? "默认为官方接口，亦可配置中转反向代理地址。" : "Defaults to official endpoint. Reverse proxy URLs are supported."
        case .methodAnthropicKey:
            return isZh ? "方式一：Anthropic API Key (官方或代理)" : "Method 1: Anthropic API Key (Official or Proxy)"
        case .labelApiEndpointColon:
            return isZh ? "接入端点:" : "API Endpoint:"
        case .hintAnthropicKey:
            return isZh ? "可在 Anthropic Console (console.anthropic.com) 生成。" : "Can be generated in Anthropic Console (console.anthropic.com)."
        case .methodClaudeSubscription:
            return isZh ? "方式二：Claude Code 订阅 (监控 5小时与每周额度)" : "Method 2: Claude Code Subscription (5h & Weekly Quotas)"
        case .btnWebLoginRecommended:
            return isZh ? "网站登录授权 (推荐)" : "Web Login Authorization (Recommended)"
        case .btnReadLocalCLIAuth:
            return isZh ? "读取本地 CLI 授权" : "Read Local CLI Auth"
        case .placeholderClaudeManualToken:
            return isZh ? "手动输入 OAuth Token / Session (可选备用)" : "Enter OAuth Token / Session (Optional backup)"

        case .methodGeminiApiKey:
            return isZh ? "方式一：Google AI Studio API Key" : "Method 1: Google AI Studio API Key"
        case .labelRecommendedLifetime:
            return isZh ? "(推荐，永久有效)" : "(Recommended, Lifetime)"
        case .labelGetKeyColon:
            return isZh ? "获取密钥:" : "Get Key:"
        case .methodGeminiOAuth:
            return isZh ? "方式二：Google 账号网页登录 / 本地凭证 (OAuth)" : "Method 2: Google Account Web Login / Local Credentials (OAuth)"
        case .btnGoogleWebLogin:
            return isZh ? "Google 网站登录授权" : "Google Web Login Authorization"
        case .btnReadLocalGeminiConfig:
            return isZh ? "读取本地 Gemini 配置" : "Read Local Gemini Credentials"
        case .labelManualGeminiToken:
            return isZh ? "手动设置 Gemini OAuth Access Token (可选)" : "Manual Gemini OAuth Access Token (Optional)"
        case .placeholderGeminiToken:
            return isZh ? "输入 Access Token" : "Enter Access Token"

        case .hintDeepSeekKey:
            return isZh ? "可在 DeepSeek 开放平台 (platform.deepseek.com) -> API Keys 中生成。" : "Can be generated in DeepSeek Platform (platform.deepseek.com) -> API Keys."
        case .hintVolcengineKey:
            return isZh ? "可在 火山引擎控制台 (console.volcengine.com/ark) -> API Key 管理中创建。" : "Can be created in Volcengine Console (console.volcengine.com/ark) -> API Keys."
        case .labelVolcengineEndpointId:
            return isZh ? "接入点 ID (Endpoint ID, 选填)" : "Endpoint ID (Optional)"
        case .hintKimiKey:
            return isZh ? "可在 Moonshot 开放平台 (platform.moonshot.cn) -> API Key 管理中创建。" : "Can be created in Moonshot Platform (platform.moonshot.cn) -> API Keys."
        case .hintGLMKey:
            return isZh ? "可在 智谱开放平台 (open.bigmodel.cn) -> API Keys 中获取。" : "Can be obtained in Zhipu Platform (open.bigmodel.cn) -> API Keys."
        case .glmProtocolTitle:
            return isZh ? "接入协议与端点 (OpenAI Response 协议)" : "Protocol & Endpoint (OpenAI Response Protocol)"
        case .glmProtocolOpenAI:
            return isZh ? "OpenAI Response 协议 (https://open.bigmodel.cn/api/v1)" : "OpenAI Response Protocol (https://open.bigmodel.cn/api/v1)"
        case .glmProtocolPaas:
            return isZh ? "PaaS v4 协议 (https://open.bigmodel.cn/api/paas/v4)" : "PaaS v4 Protocol (https://open.bigmodel.cn/api/paas/v4)"
        case .glmProtocolInternational:
            return isZh ? "国际站 (https://api.z.ai/api/v1)" : "International (https://api.z.ai/api/v1)"
        case .glmCustomEndpoint:
            return isZh ? "自定义端点:" : "Custom Endpoint:"

        case .aliyunQuotaNoticeTitle:
            return isZh ? "额度获取说明" : "Quota Retrieval Notice"
        case .aliyunQuotaNoticeDesc:
            return isZh ? "阿里云百炼的 OpenAI 兼容端点（如 token-plan.../compatible-mode/v1）仅用于模型对话推理，并不提供配额查询接口。TokenBar 支持通过百炼官方 CLI (`bl`) 或控制台网页登录会话自动获取真实的 7 天周期额度 与 5 小时额度。" : "Aliyun Bailian's OpenAI-compatible endpoint is for model inference only and does not support quota lookup. TokenBar retrieves real 7-day and 5-hour quotas via the official CLI (`bl`) or console web login."
        case .aliyunRecommendedAuthTitle:
            return isZh ? "推荐授权方式" : "Recommended Authorization"
        case .btnAliyunTerminalCLI:
            return isZh ? "在终端登录百炼 CLI (推荐)" : "Login Bailian CLI in Terminal (Recommended)"
        case .aliyunMethodWebLogin:
            return isZh ? "控制台网页登录授权" : "Console Web Login Authorization"
        case .btnAliyunWebLogin:
            return isZh ? "控制台网页登录授权" : "Console Web Login Authorization"
        case .hintAliyunKey:
            return isZh ? "百炼专属 API Key 通常以 sk-sp- 开头，供推理端点与工具使用。" : "Bailian API Key usually starts with sk-sp-, used for model inference."
        case .labelAliyunCookie:
            return isZh ? "控制台 Session Cookie (可选/备用)" : "Console Session Cookie (Optional/Backup)"
        case .placeholderAliyunCookie:
            return isZh ? "通过网页登录会自动填入，亦可手动粘贴" : "Auto-filled via web login, or paste manually"
        case .btnAliyunSaveAndRefresh:
            return isZh ? "保存并刷新检测额度" : "Save & Refresh Quota"

        // Alert Messages
        case .alertOpenAISuccess:
            return isZh ? "OpenAI 授权连接成功！已检测到接口状态与可用模型。" : "OpenAI connection successful! API status and available models detected."
        case .alertOpenAIFailed:
            return isZh ? "OpenAI 连接失败: " : "OpenAI connection failed: "
        case .alertAnthropicSuccess:
            return isZh ? "Anthropic API Key 校验成功！" : "Anthropic API Key verified successfully!"
        case .alertAnthropicFailed:
            return isZh ? "校验失败: " : "Verification failed: "
        case .alertClaudeWebSuccess:
            return isZh ? "Claude Code 网页登录授权成功！" : "Claude Code web login authorization successful!"
        case .alertClaudeLocalSuccess:
            return isZh ? "成功从 ~/.claude.json 读取并同步本地 Claude CLI 配额！" : "Successfully read and synced local Claude CLI quota from ~/.claude.json!"
        case .alertClaudeLocalNotFound:
            return isZh ? "未在本地找到 ~/.claude.json 配置文件，请先在终端运行 claude 进行登录，或使用上方网页登录授权。" : "Could not find ~/.claude.json locally. Please run claude login in terminal or use web login above."
        case .alertClaudeTokenSaved:
            return isZh ? "Claude Token 已保存并刷新！" : "Claude Token saved and refreshed!"
        case .alertGeminiSuccess:
            return isZh ? "Google AI Studio API 连接成功！" : "Google AI Studio API connected successfully!"
        case .alertGeminiWebSuccess:
            return isZh ? "Gemini 网站登录授权成功！" : "Gemini web login authorization successful!"
        case .alertGeminiLocalSuccess:
            return isZh ? "已从 ~/.gemini/oauth_creds.json 读取本地凭证！" : "Successfully read local credentials from ~/.gemini/oauth_creds.json!"
        case .alertGeminiLocalNotFound:
            return isZh ? "未检测到本地 ~/.gemini 配置文件，请使用网页登录授权。" : "No local ~/.gemini config found. Please use web login authorization."
        case .alertGeminiTokenSaved:
            return isZh ? "Gemini Token 已保存！" : "Gemini Token saved!"
        case .alertDeepSeekSuccess:
            return isZh ? "DeepSeek 连接成功！已查询到账户状态与余额。" : "DeepSeek connected successfully! Account status and balance retrieved."
        case .alertDeepSeekFailed:
            return isZh ? "DeepSeek 连接失败: " : "DeepSeek connection failed: "
        case .alertVolcengineSuccess:
            return isZh ? "火山方舟连接成功！已确认接口可用。" : "Volcengine Ark connected successfully! Service verified."
        case .alertVolcengineFailed:
            return isZh ? "火山方舟连接失败: " : "Volcengine Ark connection failed: "
        case .alertKimiSuccess:
            return isZh ? "KIMI 连接成功！已查询到可用余额。" : "KIMI connected successfully! Available balance retrieved."
        case .alertKimiFailed:
            return isZh ? "KIMI 连接失败: " : "KIMI connection failed: "
        case .alertGLMSuccess:
            return isZh ? "GLM API Key 校验成功，已成功拉取额度数据！" : "GLM API Key verified successfully, quota data retrieved!"
        case .alertGLMFailed:
            return isZh ? "GLM 校验失败: " : "GLM verification failed: "
        case .alertAliyunCLIOpened:
            return isZh ? "已为你打开终端并运行 bl auth login --console。\n登录成功后，请返回此处点击「保存并刷新检测额度」即可！" : "Opened Terminal running 'bl auth login --console'.\nAfter logging in, return here and click 'Save & Refresh Quota'!"
        case .alertAliyunWebSuccess:
            return isZh ? "阿里云控制台网页登录授权成功！" : "Aliyun Console web login authorization successful!"
        case .alertAliyunSuccess:
            return isZh ? "百炼配额获取成功！已更新 7 天周期额度与 5 小时额度。" : "Bailian quota retrieved successfully! 7-day and 5-hour quotas updated."
        case .alertAliyunFailed:
            return isZh ? "百炼获取失败: " : "Bailian retrieval failed: "
        case .alertCustomSavedPrefix:
            return isZh ? " 已保存，正在检测连通性..." : " saved, checking connectivity..."
        case .alertUnknownError:
            return isZh ? "未知错误" : "Unknown error"
        case .alertCheckKey:
            return isZh ? "请核对Key" : "Please check your key"

        case .menuAbout:
            return isZh ? "关于 TokenBar" : "About TokenBar"
        case .menuHide:
            return isZh ? "隐藏 TokenBar" : "Hide TokenBar"
        case .menuHideOthers:
            return isZh ? "隐藏其他" : "Hide Others"
        case .menuShowAll:
            return isZh ? "显示全部" : "Show All"
        case .menuQuit:
            return isZh ? "退出 TokenBar" : "Quit TokenBar"
        case .menuRefreshAll:
            return isZh ? "立即刷新全部额度" : "Refresh All Quotas Now"
        case .menuPreferences:
            return isZh ? "偏好设置..." : "Preferences..."
        case .menuEdit:
            return isZh ? "编辑" : "Edit"
        case .menuUndo:
            return isZh ? "撤销" : "Undo"
        case .menuRedo:
            return isZh ? "重做" : "Redo"
        case .menuCut:
            return isZh ? "剪切" : "Cut"
        case .menuCopy:
            return isZh ? "复制" : "Copy"
        case .menuPaste:
            return isZh ? "粘贴" : "Paste"
        case .menuSelectAll:
            return isZh ? "全选" : "Select All"
        case .menuWindow:
            return isZh ? "窗口" : "Window"
        case .menuMinimize:
            return isZh ? "最小化" : "Minimize"
        case .menuCloseWindow:
            return isZh ? "关闭窗口" : "Close Window"
        case .fiveHourQuotaTitle:
            return isZh ? "5小时额度" : "5-Hour Quota"
        case .weeklyQuotaTitle:
            return isZh ? "每周额度" : "Weekly Quota"
        case .sevenDaysQuotaTitle:
            return isZh ? "7天额度" : "7-Day Quota"
        case .accountBalanceTitle:
            return isZh ? "账户可用余额" : "Account Balance"
        case .keyQuotaTitle:
            return isZh ? "Key 额度" : "Key Quota"
        case .rpmRateLimitTitle:
            return isZh ? "RPM 速率配额" : "RPM Rate Limit"
        case .tpmRateLimitTitle:
            return isZh ? "TPM 速率配额" : "TPM Rate Limit"
        case .tokenRateLimitTitle:
            return isZh ? "Token 速率配额" : "Token Rate Limit"
        case .fiveHourComputeQuotaTitle:
            return isZh ? "5小时算力额度" : "5-Hour Compute Quota"
        case .apiConnectedTitle:
            return isZh ? "API 连接正常" : "API Connected"
        case .errMissingAnthropicAuth:
            return isZh ? "未配置 Anthropic API Key 或 Claude Code 网页/本地授权" : "Anthropic API Key or Claude Code authorization not configured"
        case .errMissingGLMKey:
            return isZh ? "请在配置中输入 GLM API KEY" : "Please enter GLM API Key in settings"
        case .errMissingOpenAIKey:
            return isZh ? "请在配置中输入 OpenAI API Key" : "Please enter OpenAI API Key in settings"
        case .errMissingDeepSeekKey:
            return isZh ? "请在配置中输入 DeepSeek API Key" : "Please enter DeepSeek API Key in settings"
        case .errMissingVolcengineKey:
            return isZh ? "请在配置中输入火山方舟 API Key" : "Please enter Volcengine Ark API Key in settings"
        case .errMissingKimiKey:
            return isZh ? "请在配置中输入 KIMI API Key" : "Please enter KIMI API Key in settings"
        case .errMissingCustomKey:
            return isZh ? "请在配置中填入 API KEY" : "Please enter API Key in settings"
        }
    }
}

public func I18n(_ key: I18nKey) -> String {
    return LocalizationManager.shared.t(key)
}
