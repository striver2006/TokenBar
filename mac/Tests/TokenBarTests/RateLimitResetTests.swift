import XCTest
import SwiftUI
@testable import TokenBar

final class RateLimitResetTests: XCTestCase {
    func testOpenAIDurationParsing() {
        let service = OpenAIService.shared
        XCTAssertEqual(service.parseDurationString("20ms"), 0.1, accuracy: 0.01)
        XCTAssertEqual(service.parseDurationString("500ms"), 0.5, accuracy: 0.01)
        XCTAssertEqual(service.parseDurationString("1s"), 1.0, accuracy: 0.01)
        XCTAssertEqual(service.parseDurationString("1m30s"), 90.0, accuracy: 0.01)
        XCTAssertEqual(service.parseDurationString("2h"), 7200.0, accuracy: 0.01)
    }

    // MARK: - 第 1 批：假数据与错误状态

    func testRateLimitResetParsesGoDuration() {
        XCTAssertEqual(RateLimitReset.parse("20ms")!, 0.02, accuracy: 0.0001)
        XCTAssertEqual(RateLimitReset.parse("1s"), 1)
        XCTAssertEqual(RateLimitReset.parse("6m0s"), 360)
        XCTAssertEqual(RateLimitReset.parse("1h2m"), 3720)
        XCTAssertEqual(RateLimitReset.parse(" 1.5s "), 1.5)
    }

    func testRateLimitResetParsesPlainSecondsAndTimestamps() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(RateLimitReset.parse("30", now: now), 30)
        // unix 秒时间戳：距今 600 秒，而不是被当成 17 亿秒
        XCTAssertEqual(RateLimitReset.parse("1700000600", now: now), 600)
        // unix 毫秒时间戳
        XCTAssertEqual(RateLimitReset.parse("1700000600000", now: now), 600)
        // 过去的时间戳 clamp 到 0
        XCTAssertEqual(RateLimitReset.parse("1600000000", now: now), 0)
    }

    func testRateLimitResetClampsAndRejectsGarbage() {
        XCTAssertEqual(RateLimitReset.parse("999999"), RateLimitReset.maxSeconds)
        XCTAssertEqual(RateLimitReset.parse("48h"), RateLimitReset.maxSeconds)
        XCTAssertNil(RateLimitReset.parse(nil))
        XCTAssertNil(RateLimitReset.parse(""))
        XCTAssertNil(RateLimitReset.parse("abc"))
        XCTAssertNil(RateLimitReset.parse("5x"))
        XCTAssertNil(RateLimitReset.parse("1s2"))
        // 兼容旧入口：解析失败按 1 秒兜底
        XCTAssertEqual(OpenAIService.shared.parseDurationString("garbage"), 1.0)
    }

    func testHTTPClientEffectiveTimeout() {
        // 显式设置的 5/10/12/15s 保留原值（15s 曾是被静默钳掉的死代码）
        XCTAssertEqual(HTTPClient.effectiveTimeout(5), 5)
        XCTAssertEqual(HTTPClient.effectiveTimeout(10), 10)
        XCTAssertEqual(HTTPClient.effectiveTimeout(12), 12)
        XCTAssertEqual(HTTPClient.effectiveTimeout(15), 15)
        // 未设置（URLRequest 默认 60s）、越界、非法值一律压回默认
        XCTAssertEqual(HTTPClient.effectiveTimeout(60), HTTPClient.defaultRequestTimeout)
        XCTAssertEqual(HTTPClient.effectiveTimeout(15.5), HTTPClient.defaultRequestTimeout)
        XCTAssertEqual(HTTPClient.effectiveTimeout(0), HTTPClient.defaultRequestTimeout)
        XCTAssertEqual(HTTPClient.effectiveTimeout(-1), HTTPClient.defaultRequestTimeout)
    }
}
