import XCTest
import SwiftUI
@testable import TokenBar

final class TokenWindowTests: XCTestCase {
    func testTokenWindowCalculations() {
        let now = Date()
        let fiveHoursLater = now.addingTimeInterval(5 * 3600)

        let window = TokenWindow(
            title: .fiveHour,
            usedPercentage: 45.0,
            startTime: now,
            endTime: fiveHoursLater,
            unit: "%"
        )

        XCTAssertEqual(window.remainingPercentage, 55.0, accuracy: 0.001)
        XCTAssertFalse(window.isExpired)
        withChineseUI {
            XCTAssertTrue(window.timeRemainingFormatted.contains("小时") || window.timeRemainingFormatted.contains("分"))
        }
        XCTAssertFalse(window.timeRangeFormatted.isEmpty)
    }

    /// 卡片角标按窗口标题的周期语义推断：月度额度应显示「每月」而非槽位默认的「每周」
    func testWindowBadgeLabelInfersCycleFromTitle() {
        func make(_ kind: WindowTitle) -> TokenWindow {
            TokenWindow(title: kind, usedPercentage: 0, startTime: Date(), endTime: Date())
        }
        XCTAssertEqual(make(.monthly).badgeLabel(fallback: "FALLBACK"), I18n(.monthlyWindow))
        XCTAssertEqual(make(.weekly).badgeLabel(fallback: "FALLBACK"), I18n(.weeklyWindow))
        XCTAssertEqual(make(.sevenDays).badgeLabel(fallback: "FALLBACK"), I18n(.weeklyWindow))
        XCTAssertEqual(make(.fiveHour).badgeLabel(fallback: "FALLBACK"), I18n(.fiveHourWindow))
        XCTAssertEqual(make(.fiveHourCompute).badgeLabel(fallback: "FALLBACK"), I18n(.fiveHourWindow))
        // 速率 / 余额 / 状态窗没有周期语义 → 回退槽位默认角标
        XCTAssertEqual(make(.tpmRate).badgeLabel(fallback: "FALLBACK"), "FALLBACK")
        XCTAssertEqual(make(.accountAvailableBalance).badgeLabel(fallback: "FALLBACK"), "FALLBACK")
        XCTAssertEqual(make(.connected()).badgeLabel(fallback: "FALLBACK"), "FALLBACK")
        XCTAssertEqual(make(.availableModels(count: 3)).badgeLabel(fallback: "FALLBACK"), "FALLBACK")
        // 推断不出（如按模型圈定的周额度，标题是模型名）→ 回退槽位默认角标
        XCTAssertEqual(make(.custom("Opus 4.5")).badgeLabel(fallback: "FALLBACK"), "FALLBACK")
    }

    /// WindowTitle 全部 case 的样例（带关联值的给代表值）。
    /// 新增 case 时这里必须同步补样例——testWindowTitleSamplesCoverAllCases 会数着。
    private let windowTitleSamples: [WindowTitle] = [
        .fiveHour, .fiveHourCompute, .weekly, .monthly, .sevenDays,
        .tpmRate, .tpmRemaining, .rpmRate, .rpmRequest, .tokenRate,
        .accountBalance, .accountAvailableBalance, .keyQuota, .tokenPlan,
        .aiStudioQuota, .connected(),
        .availableModels(count: 3), .custom("Fable")
    ]

    func testWindowTitleSamplesCoverAllCases() {
        // 18 = WindowTitle 当前全部 case 数；新增 case 未补样例时此断言先挂
        XCTAssertEqual(windowTitleSamples.count, 18)
    }

    /// 穷尽性保障：每个 case 在中文模式下 localized == zhTitle 且非空；
    /// 英文模式下 localized 非空、且除 .custom（原样透传的动态标题）外
    /// 绝不等于中文原文——即全部登记了英文翻译，不会再静默漏译。
    func testWindowTitleLocalizationIsExhaustive() {
        let previous = LocalizationManager.shared.currentLanguage
        defer { LocalizationManager.shared.setLanguage(previous) }

        LocalizationManager.shared.setLanguage(.zhHans)
        for kind in windowTitleSamples {
            XCTAssertEqual(kind.localized, kind.zhTitle, "\(kind) 中文模式应返回 zhTitle")
            XCTAssertFalse(kind.zhTitle.isEmpty, "\(kind) zhTitle 不能为空")
        }

        LocalizationManager.shared.setLanguage(.en)
        for kind in windowTitleSamples {
            let en = kind.localized
            XCTAssertFalse(en.isEmpty, "\(kind) 英文标题不能为空")
            if case .custom = kind { continue }   // 动态标题原样显示，豁免
            XCTAssertNotEqual(en, kind.zhTitle, "\(kind) 英文模式漏译：仍显示中文原文")
        }
    }

    /// zhTitle → 枚举的往返一致，历史别名与未登记字符串的归宿也要钉死
    func testWindowTitleLegacyStringMapping() {
        for kind in windowTitleSamples {
            XCTAssertEqual(WindowTitle(legacyTitle: kind.zhTitle), kind, "\(kind) 应能从规范中文标题还原")
        }
        // 历史变体归并
        XCTAssertEqual(WindowTitle(legacyTitle: "每月额度"), .monthly)
        XCTAssertEqual(WindowTitle(legacyTitle: "7天额度"), .sevenDays)
        XCTAssertEqual(WindowTitle(legacyTitle: "Key 额度"), .keyQuota)
        XCTAssertEqual(WindowTitle(legacyTitle: "OpenRouter 连接正常"), .connected(subject: "OpenRouter"))
        XCTAssertEqual(WindowTitle(legacyTitle: "API 连接状态"), .connected())
        // 旧格式带「个」的模型数标题也要能解析
        XCTAssertEqual(WindowTitle(legacyTitle: "可用模型 (12个)"), .availableModels(count: 12))
        // 未登记字符串按 custom 原样保留（与旧 localizedTitle 的 default 分支一致）
        XCTAssertEqual(WindowTitle(legacyTitle: "某个新服务的标题"), .custom("某个新服务的标题"))
    }

    /// 新格式（titleKind）编解码往返
    func testTokenWindowCodableRoundTripsTitleKind() throws {
        let w = TokenWindow(
            title: .availableModels(count: 7),
            usedPercentage: 10,
            startTime: Date(),
            endTime: Date().addingTimeInterval(3600)
        )
        let decoded = try JSONDecoder().decode(TokenWindow.self, from: JSONEncoder().encode(w))
        XCTAssertEqual(decoded.titleKind, .availableModels(count: 7))
        XCTAssertEqual(decoded.title, "可用模型 (7个)")
    }

    func testExpiredTokenWindow() {
        let past = Date().addingTimeInterval(-3600)
        let expiredTime = Date().addingTimeInterval(-60)

        let window = TokenWindow(
            title: .fiveHour,
            usedPercentage: 95.0,
            startTime: past,
            endTime: expiredTime,
            unit: "%"
        )

        XCTAssertEqual(window.remainingPercentage, 5.0, accuracy: 0.001)
        XCTAssertTrue(window.isExpired)
        withChineseUI {
            XCTAssertEqual(window.timeRemainingFormatted, "已到重置时间 / 刷新中")
        }
    }

    func testBalanceTokenWindow() {
        let window = TokenWindow.balance(
            title: .accountAvailableBalance,
            amount: 23.456,
            currency: "CNY",
            warningThreshold: 10,
            criticalThreshold: 5
        )

        XCTAssertTrue(window.isBalance)
        XCTAssertEqual(window.balanceFormatted, "¥23.46")
        XCTAssertEqual(window.statusColor, Color.green)

        var low = window
        low.balanceAmount = 3
        XCTAssertEqual(low.statusColor, Color.red)

        low.balanceAmount = 8
        XCTAssertEqual(low.statusColor, Color.orange)

        var usd = window
        usd.currency = "USD"
        XCTAssertEqual(usd.balanceFormatted, "$23.46")

        var delta = window
        delta.lastDelta = -0.85
        XCTAssertEqual(delta.balanceDeltaFormatted, "-¥0.85")

        delta.lastDelta = 12.0
        XCTAssertEqual(delta.balanceDeltaFormatted, "+¥12.00")
    }

    func testBalanceForecastStore() async {
        let key = "test-provider-\(UUID().uuidString)"
        let store = BalanceHistoryStore.shared

        // 样本不足：不给出预测
        await store.record(providerKey: key, value: 100)
        let forecast = await store.forecastDays(providerKey: key, currentAmount: 100)
        XCTAssertNil(forecast)
        // 一次跳转完成记录 + 预测
        let combined = await store.recordAndForecast(providerKey: key, value: 99)
        XCTAssertNil(combined)

        await store.clear(providerKey: key)
    }

    func testStatusWindowIsNotAQuotaWindow() {
        let w = TokenWindow.status(title: .connected())
        XCTAssertTrue(w.isStatus)
        XCTAssertFalse(w.isBalance)
        XCTAssertTrue(w.isIdle)
        withChineseUI {
            XCTAssertEqual(w.localizedTitle, "API 连接正常")
        }
        // 菜单栏常驻额度不能挑到状态型窗口去显示「剩余 100%」
        let selected = MenuBarStatus.selectWindows(primary: w, secondary: nil, balance: nil, metric: .quota)
        XCTAssertTrue(selected.isEmpty)
    }

    func testStatusWindowKindDecodesFromLegacyJSON() throws {
        // 旧版本持久化的窗口没有 kind 字段、且标题还是中文字符串，
        // 必须仍能解码：字符串标题经兼容层映射回语义枚举，且不被当成状态型
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"5小时额度","usedPercentage":40,"startTime":0,"endTime":18000,"unit":"%","isIdle":false}
        """
        let w = try JSONDecoder().decode(TokenWindow.self, from: Data(legacy.utf8))
        XCTAssertFalse(w.isStatus)
        XCTAssertEqual(w.remainingPercentage, 60)
        XCTAssertEqual(w.titleKind, .fiveHour)
        XCTAssertEqual(w.title, "5小时额度")
    }
}
