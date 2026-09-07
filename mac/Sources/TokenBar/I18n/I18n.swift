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
            return isZh ? "TokenBar v1.0.0 • 模型额度监控" : "TokenBar v1.0.0 • Model Quota Monitor"

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
        }
    }
}

public func I18n(_ key: I18nKey) -> String {
    return LocalizationManager.shared.t(key)
}
