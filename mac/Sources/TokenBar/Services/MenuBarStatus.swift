import Foundation

/// 菜单栏图标旁额度摘要的文案计算。
/// 全部为纯函数（不触碰 RefreshManager / AppKit），便于单元测试。
///
/// 菜单栏只显示数值、不显示厂商名：额度为剩余百分比（同时展示时以 "/" 分隔，
/// 如 `34%/67%` 表示 5 小时 / 周期剩余），余额只显示金额数字（如 `45.09`）。
/// "自动"模式为额度优先、余额并列，如 `34%/67%/45.09`。
/// 厂商名与额度名称、重置倒计时等完整信息放在悬停 tooltip 中。
public enum MenuBarStatus {

    /// 菜单栏展示结果：title 为图标旁短文案，tooltip 为悬停完整说明。
    public struct Text: Equatable {
        public let title: String
        public let tooltip: String
        /// 数据已明显超过刷新周期没更新。菜单栏据此把数值变灰，
        /// 避免"第一轮成功之后，之后每轮都失败但界面照样显示旧百分比"。
        public let isStale: Bool

        public init(title: String, tooltip: String, isStale: Bool = false) {
            self.title = title
            self.tooltip = tooltip
            self.isStale = isStale
        }
    }

    /// 无数据时的占位文案
    public static let placeholder = "--"

    /// 依据所选指标挑选用于展示的窗口（可能是 0、1 或 2 个）。
    /// primary / secondary 对内置厂商即 5 小时额度 / 周期额度槽位，对自定义厂商为主 / 次槽位。
    public static func selectWindows(
        primary: TokenWindow?,
        secondary: TokenWindow?,
        balance: TokenWindow? = nil,
        metric: MenuBarMetric
    ) -> [TokenWindow] {
        let quotaWindows = [primary, secondary].compactMap { $0 }.filter { !$0.isBalance }
        let resolvedBalance = balance ?? balanceWindow(primary: primary, secondary: secondary)

        switch metric {
        case .fiveHour:
            return [primary].compactMap { $0 }
        case .weekly:
            return [secondary].compactMap { $0 }
        case .quota:
            return quotaWindows
        case .balance:
            return [resolvedBalance].compactMap { $0 }
        case .auto:
            // 额度优先展示，余额（如有）并列在后；纯扣费厂商没有额度窗口时自然退化为只显示余额
            var windows = quotaWindows
            if let b = resolvedBalance {
                windows.append(b)
            }
            return windows
        }
    }

    /// 单个窗口的数值文案：余额只给数字，额度给剩余百分比。
    public static func valueText(for window: TokenWindow) -> String {
        if window.isBalance {
            guard let amount = window.balanceAmount else { return placeholder }
            return String(format: "%.2f", amount)
        }
        return "\(Int(window.remainingPercentage.rounded()))%"
    }

    /// tooltip 中单个窗口的完整描述
    public static func detailText(for window: TokenWindow) -> String {
        if window.isBalance {
            return "\(window.localizedTitle) \(window.balanceFormatted)"
        }
        return "\(window.localizedTitle) \(I18n(.remaining)) \(Int(window.remainingPercentage.rounded()))% · \(window.timeRemainingFormatted)"
    }

    /// 计算当前应展示的菜单栏文案；返回 nil 表示只显示图标。
    public static func resolve(
        settings: AppSettings,
        quotas: [ProviderType: ProviderQuota],
        customQuotas: [UUID: CustomProviderQuota],
        now: Date = Date()
    ) -> Text? {
        guard settings.menuBarQuotaEnabled else { return nil }

        let key = settings.menuBarProviderKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }

        let name: String
        let primary: TokenWindow?
        let secondary: TokenWindow?
        let balance: TokenWindow?
        let isAuthorized: Bool
        let errorMessage: String?
        let lastUpdated: Date?

        if let type = ProviderOrdering.parseProviderType(key) {
            guard settings.isEnabled(type), let quota = quotas[type] else { return nil }
            name = type.shortName
            primary = quota.fiveHourWindow
            secondary = quota.weeklyWindow
            balance = quota.balanceWindow
            isAuthorized = quota.isAuthorized
            errorMessage = quota.errorMessage
            lastUpdated = quota.lastUpdated
        } else if let id = ProviderOrdering.parseCustomKey(key),
                  let quota = customQuotas[id],
                  settings.customProviders.first(where: { $0.id == id })?.isEnabled == true {
            name = quota.name
            primary = quota.primaryWindow
            secondary = quota.secondaryWindow
            balance = nil
            isAuthorized = quota.isAuthorized
            errorMessage = quota.errorMessage
            lastUpdated = quota.lastUpdated
        } else {
            // 所选厂商已被删除或停用
            return nil
        }

        let windows = selectWindows(primary: primary, secondary: secondary, balance: balance, metric: settings.menuBarMetric)
        guard !windows.isEmpty else {
            let hint = errorMessage ?? (isAuthorized ? I18n(.menuBarNoData) : I18n(.notAuthorized))
            return Text(title: placeholder, tooltip: "\(name) · \(hint)")
        }

        // 容忍 2.5 个刷新周期（至少 15 分钟）；超过就认为这份数值不再可信。
        let staleAfter = max(Double(settings.refreshIntervalMinutes) * 60 * 2.5, 900)
        let isStale = lastUpdated.map { now.timeIntervalSince($0) > staleAfter } ?? false

        var tooltipParts = [name] + windows.map(detailText)
        if isStale {
            let stamp = lastUpdated.map { staleTimeFormatter.string(from: $0) } ?? "?"
            tooltipParts.append("\(I18n(.dataStale))（\(stamp)）")
        }

        // title 保持不变：加符号会让菜单栏宽度来回抖动，陈旧状态改用颜色表达。
        return Text(
            title: windows.map(valueText).joined(separator: "/"),
            tooltip: tooltipParts.joined(separator: " · "),
            isStale: isStale
        )
    }

    private static let staleTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func balanceWindow(primary: TokenWindow?, secondary: TokenWindow?) -> TokenWindow? {
        if let p = primary, p.isBalance { return p }
        if let s = secondary, s.isBalance { return s }
        return nil
    }
}
