import Foundation

/// 菜单栏图标旁额度摘要的文案计算。
/// 全部为纯函数（不触碰 RefreshManager / AppKit），便于单元测试与 Windows 端对齐。
public enum MenuBarStatus {

    /// 菜单栏展示结果：title 为图标旁短文案，tooltip 为悬停完整说明。
    public struct Text: Equatable {
        public let title: String
        public let tooltip: String

        public init(title: String, tooltip: String) {
            self.title = title
            self.tooltip = tooltip
        }
    }

    /// 厂商名过长时截断，避免挤占菜单栏
    public static let maxProviderNameLength = 8

    /// 依据所选指标挑选用于展示的窗口。
    /// primary / secondary 对内置厂商即 5 小时额度 / 周期额度槽位，对自定义厂商为主 / 次槽位。
    public static func selectWindow(
        primary: TokenWindow?,
        secondary: TokenWindow?,
        metric: MenuBarMetric
    ) -> TokenWindow? {
        switch metric {
        case .fiveHour:
            return primary
        case .weekly:
            return secondary
        case .balance:
            if let p = primary, p.isBalance { return p }
            if let s = secondary, s.isBalance { return s }
            return nil
        case .auto:
            // 纯扣费厂商（DeepSeek / KIMI 等）的余额比速率窗口更值得盯，故余额优先
            if let p = primary, p.isBalance { return p }
            if let s = secondary, s.isBalance { return s }
            return primary ?? secondary
        }
    }

    /// 额度窗口的紧凑标记（余额窗口无标记）。按窗口原始标题判断，与槽位无关。
    public static func marker(for window: TokenWindow) -> String {
        if window.isBalance { return "" }
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        if window.title.contains("5小时") {
            return isZh ? "5时" : "5H"
        }
        if window.title.contains("周") || window.title.contains("7天") {
            return isZh ? "周" : "W"
        }
        return ""
    }

    /// 数值文案：余额窗口显示金额，额度窗口显示剩余百分比（带紧凑标记）。
    public static func valueText(for window: TokenWindow) -> String {
        if window.isBalance {
            return window.balanceFormatted
        }
        let percent = Int(window.remainingPercentage.rounded())
        let mark = marker(for: window)
        return mark.isEmpty ? "\(percent)%" : "\(mark) \(percent)%"
    }

    /// 组合最终展示文案。
    public static func compose(providerName: String, window: TokenWindow) -> Text {
        let name = truncate(providerName)
        let tooltipDetail = window.isBalance
            ? "\(window.localizedTitle) \(window.balanceFormatted)"
            : "\(window.localizedTitle) \(I18n(.remaining)) \(Int(window.remainingPercentage.rounded()))% · \(window.timeRemainingFormatted)"
        return Text(
            title: "\(name) \(valueText(for: window))",
            tooltip: "\(providerName) · \(tooltipDetail)"
        )
    }

    /// 计算当前应展示的菜单栏文案；返回 nil 表示只显示图标。
    public static func resolve(
        settings: AppSettings,
        quotas: [ProviderType: ProviderQuota],
        customQuotas: [UUID: CustomProviderQuota]
    ) -> Text? {
        guard settings.menuBarQuotaEnabled else { return nil }

        let key = settings.menuBarProviderKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }

        let name: String
        let primary: TokenWindow?
        let secondary: TokenWindow?
        let isAuthorized: Bool
        let errorMessage: String?

        if let type = ProviderOrdering.parseProviderType(key) {
            guard settings.isEnabled(type), let quota = quotas[type] else { return nil }
            name = type.shortName
            primary = quota.fiveHourWindow
            secondary = quota.weeklyWindow
            isAuthorized = quota.isAuthorized
            errorMessage = quota.errorMessage
        } else if let id = ProviderOrdering.parseCustomKey(key),
                  let quota = customQuotas[id],
                  settings.customProviders.first(where: { $0.id == id })?.isEnabled == true {
            name = quota.name
            primary = quota.primaryWindow
            secondary = quota.secondaryWindow
            isAuthorized = quota.isAuthorized
            errorMessage = quota.errorMessage
        } else {
            // 所选厂商已被删除或停用
            return nil
        }

        guard let window = selectWindow(primary: primary, secondary: secondary, metric: settings.menuBarMetric) else {
            let hint = errorMessage ?? (isAuthorized ? I18n(.menuBarNoData) : I18n(.notAuthorized))
            return Text(title: "\(truncate(name)) --", tooltip: "\(name) · \(hint)")
        }

        return compose(providerName: name, window: window)
    }

    private static func truncate(_ name: String) -> String {
        guard name.count > maxProviderNameLength else { return name }
        return String(name.prefix(maxProviderNameLength)) + "…"
    }
}
