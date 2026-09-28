import XCTest
import SwiftUI
@testable import TokenBar

final class KimiParsingTests: XCTestCase {
    // MARK: - KIMI Code 订阅（/coding/v1/usages）

    private func parseKimiUsages(_ json: String) -> (fiveHour: TokenWindow?, longWindow: TokenWindow?) {
        let data = json.data(using: .utf8)!
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return KimiService.shared.parseCodingUsages(obj)
    }

    /// 测试用参考时间：带不带小数秒都能解析（与生产代码同策略）
    private func kimiISO(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)!
    }

    private func kimiISOString(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// 实测 OAuth 形状（2026-09-26 真实报文）：limits[] 的 300 分钟窗优先于 usages.limit_5h，
    /// 长窗口取 limit_month_total，limit_month_code 忽略
    func testKimiCodingOAuthShape() throws {
        let parsed = parseKimiUsages("""
        {"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"21","remaining":"79","resetTime":"2026-09-26T11:52:30.018171Z"}}],"usages":{"limit_5h":{"used_ratio":0.206526,"reset_time":"2026-09-26T11:52:29Z"},"limit_month_total":{"used_ratio":0.0228,"reset_time":"2026-10-26T06:52:30Z"},"limit_month_code":{"used_ratio":0.0083,"reset_time":"2026-10-26T06:52:30Z"}}}
        """)
        let fiveHour = try XCTUnwrap(parsed.fiveHour)
        XCTAssertEqual(fiveHour.title, "5小时额度")
        XCTAssertEqual(fiveHour.usedPercentage, 21.0, accuracy: 0.001)
        XCTAssertEqual(fiveHour.unit, "次")
        XCTAssertEqual(fiveHour.usedAmount ?? -1, 21, accuracy: 0.001)
        XCTAssertEqual(fiveHour.totalLimit ?? -1, 100, accuracy: 0.001)
        XCTAssertFalse(fiveHour.isIdle)
        // resetTime 带纳秒小数也要能解析
        XCTAssertEqual(fiveHour.endTime.timeIntervalSince1970,
                       kimiISO("2026-09-26T11:52:30.018171Z").timeIntervalSince1970, accuracy: 0.001)

        let long = try XCTUnwrap(parsed.longWindow)
        XCTAssertEqual(long.title, "月度额度")
        XCTAssertEqual(long.usedPercentage, 2.28, accuracy: 0.001)
        XCTAssertEqual(long.endTime.timeIntervalSince1970,
                       kimiISO("2026-10-26T06:52:30Z").timeIntervalSince1970, accuracy: 0.001)
    }

    /// API Key（sk-kimi-）老套餐形状：顶层 usage 是 7 天长窗口，limits[] 300 分钟窗是 5 小时窗
    func testKimiCodingApiKeyLegacyShape() throws {
        let parsed = parseKimiUsages("""
        {"usage":{"limit":"2048","used":"214","remaining":"1834","resetTime":"2026-01-09T15:23:13.716839300Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"200","used":"139","remaining":"61","resetTime":"2026-01-06T13:33:02.717479433Z"}}]}
        """)
        let fiveHour = try XCTUnwrap(parsed.fiveHour)
        XCTAssertEqual(fiveHour.usedPercentage, 69.5, accuracy: 0.001)
        XCTAssertEqual(fiveHour.unit, "次")
        XCTAssertEqual(fiveHour.usedAmount ?? -1, 139, accuracy: 0.001)
        XCTAssertEqual(fiveHour.totalLimit ?? -1, 200, accuracy: 0.001)
        XCTAssertFalse(fiveHour.isIdle)
        XCTAssertEqual(fiveHour.endTime.timeIntervalSince1970,
                       kimiISO("2026-01-06T13:33:02.717479433Z").timeIntervalSince1970, accuracy: 0.001)

        let long = try XCTUnwrap(parsed.longWindow)
        // fixture 的 resetTime（2026-01-09）距今不足 20 天 → 每周额度
        XCTAssertEqual(long.title, "每周额度")
        XCTAssertEqual(long.usedPercentage, 214.0 / 2048 * 100, accuracy: 0.001)
        XCTAssertEqual(long.unit, "次")
        XCTAssertEqual(long.usedAmount ?? -1, 214, accuracy: 0.001)
        XCTAssertEqual(long.totalLimit ?? -1, 2048, accuracy: 0.001)
    }

    /// 顶层 usage 的长窗口标题按 resetTime 距今时长区分月度 / 每周
    func testKimiCodingTopLevelUsageMonthlyVsWeeklyTitle() throws {
        let monthlyReset = kimiISOString(Date().addingTimeInterval(30 * 86400))
        let monthly = parseKimiUsages("""
        {"usage":{"limit":"1000","used":"100","resetTime":"\(monthlyReset)"}}
        """)
        XCTAssertEqual(monthly.longWindow?.title, "月度额度")
        XCTAssertEqual(monthly.longWindow?.usedPercentage ?? -1, 10, accuracy: 0.001)
        // 该形状没有任何 5 小时数据来源
        XCTAssertNil(monthly.fiveHour)

        let weeklyReset = kimiISOString(Date().addingTimeInterval(3 * 86400))
        let weekly = parseKimiUsages("""
        {"usage":{"limit":"1000","used":"500","resetTime":"\(weeklyReset)"}}
        """)
        XCTAssertEqual(weekly.longWindow?.title, "每周额度")
        XCTAssertEqual(weekly.longWindow?.usedPercentage ?? -1, 50, accuracy: 0.001)
        XCTAssertTrue(weekly.longWindow?.isIdle == false)
    }

    /// OAuth 旧形状（issue #3908）：嵌套在 data.quota 里，字段 camelCase，usedRatio 全 0 → IsIdle
    func testKimiCodingNestedQuotaShape() throws {
        let parsed = parseKimiUsages("""
        {"code":0,"data":{"kind":"ok","quota":{"usages":{"limit5h":{"resetAt":"2026-09-18T12:07:12Z","usedRatio":0},"limit7d":{"resetAt":"2026-09-23T23:07:12Z","usedRatio":0}}}}}
        """)
        let fiveHour = try XCTUnwrap(parsed.fiveHour)
        XCTAssertEqual(fiveHour.usedPercentage, 0, accuracy: 0.001)
        XCTAssertTrue(fiveHour.isIdle)
        XCTAssertEqual(fiveHour.endTime.timeIntervalSince1970,
                       kimiISO("2026-09-18T12:07:12Z").timeIntervalSince1970, accuracy: 0.001)

        let long = try XCTUnwrap(parsed.longWindow)
        XCTAssertEqual(long.title, "每周额度")
        XCTAssertEqual(long.usedPercentage, 0, accuracy: 0.001)
        XCTAssertTrue(long.isIdle)
        XCTAssertEqual(long.endTime.timeIntervalSince1970,
                       kimiISO("2026-09-23T23:07:12Z").timeIntervalSince1970, accuracy: 0.001)
    }

    /// window 单位换算：SECOND / HOUR 折算成 18000 秒都认作 5 小时窗
    func testKimiCodingWindowUnitConversion() throws {
        let bySecond = parseKimiUsages("""
        {"limits":[{"window":{"duration":18000,"timeUnit":"TIME_UNIT_SECOND"},"detail":{"limit":"50","used":"0","resetTime":"2026-09-26T12:00:00Z"}}]}
        """)
        let w1 = try XCTUnwrap(bySecond.fiveHour)
        XCTAssertEqual(w1.usedPercentage, 0, accuracy: 0.001)
        XCTAssertTrue(w1.isIdle)

        let byHour = parseKimiUsages("""
        {"limits":[{"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"50","used":"10","resetTime":"2026-09-26T12:00:00Z"}}]}
        """)
        let w2 = try XCTUnwrap(byHour.fiveHour)
        XCTAssertEqual(w2.usedPercentage, 20, accuracy: 0.001)

        // 非 5 小时窗（如 300 秒）不能误认
        let tooShort = parseKimiUsages("""
        {"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_SECOND"},"detail":{"limit":"50","used":"10","resetTime":"2026-09-26T12:00:00Z"}}]}
        """)
        XCTAssertNil(tooShort.fiveHour)
    }

    /// resetTime 带小数与不带小数两种 ISO 格式都能解析
    func testKimiResetTimeParsesFractionalAndPlainISO() {
        let withFrac = try! XCTUnwrap(KimiService.parseISO8601("2026-09-26T11:52:30.018171Z"))
        let plain = try! XCTUnwrap(KimiService.parseISO8601("2026-09-26T11:52:30Z"))
        let nano = try! XCTUnwrap(KimiService.parseISO8601("2026-01-09T15:23:13.716839300Z"))
        XCTAssertEqual(withFrac.timeIntervalSince1970,
                       kimiISO("2026-09-26T11:52:30.018171Z").timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(plain.timeIntervalSince1970,
                       kimiISO("2026-09-26T11:52:30Z").timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(nano.timeIntervalSince1970,
                       kimiISO("2026-01-09T15:23:13.716839300Z").timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(KimiService.parseISO8601("not a date"))
    }

    /// limit/used 字符串数字解析：used > limit 时百分比 clamp 到 100
    func testKimiCodingStringNumbersAndClamp() throws {
        let parsed = parseKimiUsages("""
        {"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"130","resetTime":"2026-09-26T12:00:00Z"}}]}
        """)
        let fiveHour = try XCTUnwrap(parsed.fiveHour)
        XCTAssertEqual(fiveHour.usedPercentage, 100, accuracy: 0.001)
        XCTAssertEqual(fiveHour.usedAmount ?? -1, 130, accuracy: 0.001)

        // used_ratio 超过 1 同样 clamp
        let over = parseKimiUsages("""
        {"usages":{"limit_5h":{"used_ratio":1.5,"reset_time":"2026-09-26T12:00:00Z"}}}
        """)
        XCTAssertEqual(over.fiveHour?.usedPercentage ?? -1, 100, accuracy: 0.001)
    }

    /// 模式判定：sk-kimi- / JWT 形 Key / coding 端点 → 订阅模式；普通 sk- + 默认端点 → legacy
    func testKimiCodingSubscriptionModeDetection() {
        // sk-kimi- 前缀
        XCTAssertTrue(KimiService.isCodingSubscription(key: "sk-kimi-abc123", endpoint: "https://api.moonshot.cn/v1"))
        // JWT 形：恰好两个 . 且无空白
        XCTAssertTrue(KimiService.isCodingSubscription(
            key: "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJVadQssw5c",
            endpoint: "https://api.moonshot.cn/v1"))
        // 两个 . 但含空白 → 不算 JWT
        XCTAssertFalse(KimiService.isCodingSubscription(key: "aa.bb.cc dd", endpoint: "https://api.moonshot.cn/v1"))
        // 端点指向 coding 网关
        XCTAssertTrue(KimiService.isCodingSubscription(key: "sk-ordinary", endpoint: "https://api.kimi.com/coding/v1"))
        XCTAssertTrue(KimiService.isCodingSubscription(key: "sk-ordinary", endpoint: "https://api.kimi.ai/coding/v1"))
        XCTAssertTrue(KimiService.isCodingSubscription(key: "sk-ordinary", endpoint: "https://proxy.example.com/coding/v1"))
        // 普通 sk- Key + 默认端点 → legacy
        XCTAssertFalse(KimiService.isCodingSubscription(key: "sk-abc123def456ghi", endpoint: "https://api.moonshot.cn/v1"))
        XCTAssertFalse(KimiService.isCodingSubscription(key: "sk-abc123def456ghi", endpoint: ""))
    }

    /// 订阅模式 base：端点含 /coding 沿用用户的，否则强制官方 coding 网关
    func testKimiCodingSubscriptionBase() {
        XCTAssertEqual(KimiService.codingSubscriptionBase(endpoint: "https://api.kimi.com/coding/v1"),
                       "https://api.kimi.com/coding/v1")
        XCTAssertEqual(KimiService.codingSubscriptionBase(endpoint: "https://proxy.example.com/coding/v1/"),
                       "https://proxy.example.com/coding/v1")
        XCTAssertEqual(KimiService.codingSubscriptionBase(endpoint: "https://api.moonshot.cn/v1"),
                       "https://api.kimi.com/coding/v1")
        XCTAssertEqual(KimiService.codingSubscriptionBase(endpoint: ""),
                       "https://api.kimi.com/coding/v1")
    }
}
