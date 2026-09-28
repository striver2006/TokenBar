import XCTest
import SwiftUI
@testable import TokenBar

final class ClaudeParsingTests: XCTestCase {
    func testClaudeLocalConfigParserFromFixture() throws {
        // 固定 fixture，不读开发者机器上的 ~/.claude.json
        let resetsAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 3600))
        let weeklyReset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 86400))
        let json: [String: Any] = [
            "oauthAccount": ["emailAddress": "someone@example.com"],
            "cachedUsageUtilization": [
                "utilization": [
                    "five_hour": ["utilization": 37.5, "resets_at": resetsAt],
                    "limits": [
                        ["kind": "weekly_all", "percent": 12, "resets_at": weeklyReset],
                        // Fable 专属周额度（weekly_scoped），取自真实缓存结构
                        ["kind": "weekly_scoped", "percent": 42, "resets_at": weeklyReset,
                         "scope": ["model": ["id": NSNull(), "display_name": "Fable"]]]
                    ]
                ]
            ]
        ]
        let parsed = ClaudeService.shared.parseLocalClaudeJson(json)
        XCTAssertEqual(parsed.account, "someone@example.com")
        let fiveHour = try XCTUnwrap(parsed.fiveHour)
        XCTAssertEqual(fiveHour.usedPercentage, 37.5, accuracy: 0.001)
        XCTAssertFalse(fiveHour.isIdle)
        XCTAssertEqual(fiveHour.endTime.timeIntervalSince(fiveHour.startTime), 5 * 3600, accuracy: 1)
        let weekly = try XCTUnwrap(parsed.weekly)
        // weekly fallback 取 first(group == "weekly")，仍命中 weekly_all 而非 weekly_scoped
        XCTAssertEqual(weekly.usedPercentage, 12, accuracy: 0.001)
        let scopedWeekly = try XCTUnwrap(parsed.scopedWeekly)
        XCTAssertEqual(scopedWeekly.usedPercentage, 42, accuracy: 0.001)
        XCTAssertEqual(scopedWeekly.title, "Fable")
    }

    func testClaudeScopedWeeklyWithoutModelName() {
        // weekly_scoped 但缺 scope.model.display_name：给不出有意义的标题，应整体跳过
        let json: [String: Any] = [
            "cachedUsageUtilization": [
                "utilization": [
                    "five_hour": ["utilization": 10],
                    "limits": [["kind": "weekly_scoped", "percent": 42]]
                ]
            ]
        ]
        let parsed = ClaudeService.shared.parseLocalClaudeJson(json)
        XCTAssertNil(parsed.scopedWeekly)
        XCTAssertNotNil(parsed.fiveHour)
    }

    func testClaudeLocalConfigParserWithoutCachedUsage() {
        // 登录了但还没有缓存用量：应给出干净的 5 小时窗口，而不是 nil
        let parsed = ClaudeService.shared.parseLocalClaudeJson(["oauthAccount": ["displayName": "Bob"]])
        XCTAssertEqual(parsed.account, "Bob")
        XCTAssertNotNil(parsed.fiveHour)
        XCTAssertTrue(parsed.fiveHour?.isIdle ?? false)
        XCTAssertNil(parsed.weekly)
        XCTAssertNil(parsed.scopedWeekly)
    }
}
