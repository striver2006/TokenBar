import XCTest
import SwiftUI
@testable import TokenBar

final class MenuBarStatusTests: XCTestCase {
    func testMenuBarStatusMarksStaleDataWhenLastUpdatedIsOld() {
        withChineseUI {
            let now = Date()
            var quota = ProviderQuota(provider: .aliyunBailian, isAuthorized: true)
            quota.fiveHourWindow = makePercentWindow(title: .fiveHour, used: 38.0)
            // 默认间隔 5 分钟 → 阈值为 max(750, 900) = 900 秒
            quota.lastUpdated = now.addingTimeInterval(-1200)

            let stale = MenuBarStatus.resolve(
                settings: makeSettings(metric: .fiveHour),
                quotas: [.aliyunBailian: quota],
                customQuotas: [:],
                now: now
            )
            XCTAssertEqual(stale?.isStale, true)
            // 数值本身不变，只是 tooltip 追加提示
            XCTAssertEqual(stale?.title, "62%")
            XCTAssertEqual(stale?.tooltip.contains("数据可能已过期"), true)
        }
    }

    func testMenuBarStatusNotStaleWhenFresh() {
        withChineseUI {
            let now = Date()
            var quota = ProviderQuota(provider: .aliyunBailian, isAuthorized: true)
            quota.fiveHourWindow = makePercentWindow(title: .fiveHour, used: 38.0)
            quota.lastUpdated = now.addingTimeInterval(-60)

            let fresh = MenuBarStatus.resolve(
                settings: makeSettings(metric: .fiveHour),
                quotas: [.aliyunBailian: quota],
                customQuotas: [:],
                now: now
            )
            XCTAssertEqual(fresh?.isStale, false)
            XCTAssertEqual(fresh?.tooltip.contains("数据可能已过期"), false)
        }
    }

    func testMenuBarStatusNotStaleWhenNeverUpdated() {
        // lastUpdated 为 nil（还没刷过）不应该被误判成陈旧
        var quota = ProviderQuota(provider: .aliyunBailian, isAuthorized: true)
        quota.fiveHourWindow = makePercentWindow(title: .fiveHour, used: 38.0)
        quota.lastUpdated = nil

        let status = MenuBarStatus.resolve(
            settings: makeSettings(metric: .fiveHour),
            quotas: [.aliyunBailian: quota],
            customQuotas: [:]
        )
        XCTAssertEqual(status?.isStale, false)
    }

    private func makeSettings(
        enabled: Bool = true,
        key: String = "aliyun",
        metric: MenuBarMetric = .auto
    ) -> AppSettings {
        var settings = AppSettings()
        settings.menuBarQuotaEnabled = enabled
        settings.menuBarProviderKey = key
        settings.menuBarMetric = metric
        return settings
    }

    private func makePercentWindow(title: WindowTitle, used: Double) -> TokenWindow {
        TokenWindow(
            title: title,
            usedPercentage: used,
            startTime: Date().addingTimeInterval(-3600),
            endTime: Date().addingTimeInterval(3600)
        )
    }

    func testMenuBarStatusDisabledOrUnselected() {
        let quotas: [ProviderType: ProviderQuota] = [:]
        XCTAssertNil(MenuBarStatus.resolve(settings: makeSettings(enabled: false), quotas: quotas, customQuotas: [:]))
        XCTAssertNil(MenuBarStatus.resolve(settings: makeSettings(key: ""), quotas: quotas, customQuotas: [:]))
    }

    func testMenuBarStatusShowsRemainingPercentage() {
        withChineseUI {
            var quota = ProviderQuota(provider: .aliyunBailian, isAuthorized: true)
            quota.fiveHourWindow = makePercentWindow(title: .fiveHour, used: 38.0)
            quota.weeklyWindow = makePercentWindow(title: .sevenDays, used: 70.0)

            // 只显示数值，不带厂商名；auto 下 5 小时与周期并列
            let auto = MenuBarStatus.resolve(
                settings: makeSettings(metric: .auto),
                quotas: [.aliyunBailian: quota],
                customQuotas: [:]
            )
            XCTAssertEqual(auto?.title, "62%/30%")
            XCTAssertEqual(auto?.tooltip.hasPrefix("百炼 · "), true)

            let five = MenuBarStatus.resolve(
                settings: makeSettings(metric: .fiveHour),
                quotas: [.aliyunBailian: quota],
                customQuotas: [:]
            )
            XCTAssertEqual(five?.title, "62%")

            let weekly = MenuBarStatus.resolve(
                settings: makeSettings(metric: .weekly),
                quotas: [.aliyunBailian: quota],
                customQuotas: [:]
            )
            XCTAssertEqual(weekly?.title, "30%")
        }
    }

    func testMenuBarStatusShowsSingleWindowOnly() {
        withChineseUI {
            var quota = ProviderQuota(provider: .aliyunBailian, isAuthorized: true)
            quota.fiveHourWindow = makePercentWindow(title: .fiveHour, used: 38.0)

            let auto = MenuBarStatus.resolve(
                settings: makeSettings(metric: .auto),
                quotas: [.aliyunBailian: quota],
                customQuotas: [:]
            )
            XCTAssertEqual(auto?.title, "62%")
        }
    }

    func testMenuBarStatusAutoModeShowsQuotaFirstThenBalance() {
        withChineseUI {
            var quota = ProviderQuota(provider: .deepseek, isAuthorized: true)
            // DeepSeek 的余额落在次槽位（自定义/纯扣费厂商的写法）
            quota.fiveHourWindow = makePercentWindow(title: .tpmRate, used: 10.0)
            quota.weeklyWindow = TokenWindow.balance(
                title: .accountAvailableBalance,
                amount: 45.09,
                currency: "CNY",
                warningThreshold: 10,
                criticalThreshold: 5
            )

            var settings = makeSettings(key: "deepseek", metric: .auto)
            settings.deepseekEnabled = true
            let status = MenuBarStatus.resolve(settings: settings, quotas: [.deepseek: quota], customQuotas: [:])
            // 额度优先，余额并列在后；余额只显示数字，不带币种符号
            XCTAssertEqual(status?.title, "90%/45.09")
            XCTAssertEqual(status?.tooltip.hasPrefix("DeepSeek · TPM 速率配额"), true)
            XCTAssertEqual(status?.tooltip.hasSuffix("账户可用余额 ¥45.09"), true)
        }
    }

    func testMenuBarStatusAutoModeFallsBackToBalanceOnlyWithoutQuota() {
        withChineseUI {
            var quota = ProviderQuota(provider: .deepseek, isAuthorized: true)
            quota.weeklyWindow = TokenWindow.balance(
                title: .accountAvailableBalance,
                amount: 45.09,
                currency: "CNY",
                warningThreshold: 10,
                criticalThreshold: 5
            )

            var settings = makeSettings(key: "deepseek", metric: .auto)
            settings.deepseekEnabled = true
            let status = MenuBarStatus.resolve(settings: settings, quotas: [.deepseek: quota], customQuotas: [:])
            // 没有额度窗口时，自动模式退化为只显示余额
            XCTAssertEqual(status?.title, "45.09")
        }
    }

    func testMenuBarStatusUsesBalanceWindowFieldForBuiltInProvider() {
        withChineseUI {
            var quota = ProviderQuota(provider: .aliyunBailian, isAuthorized: true)
            quota.fiveHourWindow = makePercentWindow(title: .fiveHour, used: 38.0)
            quota.weeklyWindow = makePercentWindow(title: .sevenDays, used: 70.0)
            quota.balanceWindow = TokenWindow.balance(
                title: .accountBalance,
                amount: 45.09,
                currency: "CNY",
                warningThreshold: 10,
                criticalThreshold: 5
            )

            // 修复前 balanceWindow 完全没被纳入候选：auto 会漏掉余额，balance 指标只能显示占位符
            let auto = MenuBarStatus.resolve(
                settings: makeSettings(metric: .auto),
                quotas: [.aliyunBailian: quota],
                customQuotas: [:]
            )
            XCTAssertEqual(auto?.title, "62%/30%/45.09")

            let balance = MenuBarStatus.resolve(
                settings: makeSettings(metric: .balance),
                quotas: [.aliyunBailian: quota],
                customQuotas: [:]
            )
            XCTAssertEqual(balance?.title, "45.09")

            let quotaOnly = MenuBarStatus.resolve(
                settings: makeSettings(metric: .quota),
                quotas: [.aliyunBailian: quota],
                customQuotas: [:]
            )
            XCTAssertEqual(quotaOnly?.title, "62%/30%")
        }
    }

    func testMenuBarStatusFallsBackWhenNoWindow() {
        withChineseUI {
            var quota = ProviderQuota(provider: .aliyunBailian)
            quota.isAuthorized = false
            quota.errorMessage = "未授权连接"

            let status = MenuBarStatus.resolve(
                settings: makeSettings(metric: .fiveHour),
                quotas: [.aliyunBailian: quota],
                customQuotas: [:]
            )
            XCTAssertEqual(status?.title, "--")
            XCTAssertEqual(status?.tooltip, "百炼 · 未授权连接")
        }
    }

    func testMenuBarStatusHiddenWhenProviderDisabled() {
        var quota = ProviderQuota(provider: .aliyunBailian, isAuthorized: true)
        quota.fiveHourWindow = makePercentWindow(title: .fiveHour, used: 10.0)

        var settings = makeSettings()
        settings.aliyunEnabled = false
        XCTAssertNil(MenuBarStatus.resolve(settings: settings, quotas: [.aliyunBailian: quota], customQuotas: [:]))
    }
}
