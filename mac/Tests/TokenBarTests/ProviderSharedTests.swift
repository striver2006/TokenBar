import XCTest
@testable import TokenBar

/// ProviderShared.swift 共享件的单元测试。
/// 断言目标：重构后各 provider 的用户可见行为（窗口数值、错误文案）与重构前逐字节一致。
final class ProviderSharedTests: XCTestCase {

    // MARK: - Helpers

    private func makeResponse(status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://example.com/v1/models")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    /// 文案断言依赖固定语言，避免受系统区域影响（对齐 TokenBarTests.withChineseUI）
    private func withLanguage(_ lang: AppLanguage, _ body: () -> Void) {
        let previous = LocalizationManager.shared.currentLanguage
        LocalizationManager.shared.setLanguage(lang)
        defer { LocalizationManager.shared.setLanguage(previous) }
        body()
    }

    // MARK: - normalizeEndpoint

    func testNormalizeEndpointEmptyUsesFallback() {
        XCTAssertEqual(normalizeEndpoint("", fallback: "https://api.openai.com/v1"), "https://api.openai.com/v1")
        XCTAssertEqual(normalizeEndpoint("   \n ", fallback: "https://api.deepseek.com/v1"), "https://api.deepseek.com/v1")
    }

    func testNormalizeEndpointTrimsAndStripsTrailingSlashes() {
        XCTAssertEqual(normalizeEndpoint("  https://api.moonshot.cn/v1  ", fallback: "x"), "https://api.moonshot.cn/v1")
        XCTAssertEqual(normalizeEndpoint("https://api.moonshot.cn/v1/", fallback: "x"), "https://api.moonshot.cn/v1")
        XCTAssertEqual(normalizeEndpoint("https://api.moonshot.cn/v1///", fallback: "x"), "https://api.moonshot.cn/v1")
    }

    func testNormalizeEndpointFallbackAlsoStripped() {
        // 空输入落到 fallback 后同样去尾斜杠（与原内联块顺序一致：先兜底再去斜杠）
        XCTAssertEqual(normalizeEndpoint("", fallback: "https://api.example.com/v1/"), "https://api.example.com/v1")
    }

    // MARK: - modelsURLString

    func testModelsURLStringAppendsOnlyWhenMissing() {
        XCTAssertEqual(modelsURLString(base: "https://api.openai.com/v1"), "https://api.openai.com/v1/models")
        XCTAssertEqual(modelsURLString(base: "https://api.openai.com/v1/models"), "https://api.openai.com/v1/models")
    }

    // MARK: - keySuffixMask

    func testKeySuffixMask() {
        XCTAssertEqual(keySuffixMask("sk-abcdefghijklmnop"), "mnop")
        XCTAssertEqual(keySuffixMask("1234567"), "4567")
        // 恰好 6 位不掩码（原实现是 count > 6）
        XCTAssertEqual(keySuffixMask("123456"), "123456")
        XCTAssertEqual(keySuffixMask("abc"), "abc")
        XCTAssertEqual(keySuffixMask(""), "")
    }

    // MARK: - RateLimitReset.parseOrDefault

    func testParseOrDefaultMatchesLegacyParseDurationString() {
        XCTAssertEqual(RateLimitReset.parseOrDefault("1s"), 1.0, accuracy: 0.001)
        XCTAssertEqual(RateLimitReset.parseOrDefault("500ms"), 0.5, accuracy: 0.001)
        // 毫秒级下限 0.1
        XCTAssertEqual(RateLimitReset.parseOrDefault("20ms"), 0.1, accuracy: 0.001)
        // 解析失败按 1s 兜底
        XCTAssertEqual(RateLimitReset.parseOrDefault("garbage"), 1.0, accuracy: 0.001)
        // 0 也被抬到下限
        XCTAssertEqual(RateLimitReset.parseOrDefault("0s"), 0.1, accuracy: 0.001)
        // 与保留的旧入口一致（有既有测试引用）
        XCTAssertEqual(OpenAIService.shared.parseDurationString("1m30s"), RateLimitReset.parseOrDefault("1m30s"), accuracy: 0.001)
    }

    // MARK: - RateLimitWindowBuilder

    func testRateLimitWindowBuilderBasicNumbers() {
        let resp = makeResponse(status: 200, headers: [
            "x-ratelimit-limit-tokens": "1000",
            "x-ratelimit-remaining-tokens": "250",
            "x-ratelimit-reset-tokens": "30s"
        ])
        let window = RateLimitWindowBuilder.build(
            response: resp,
            limitHeader: "x-ratelimit-limit-tokens",
            remainingHeader: "x-ratelimit-remaining-tokens",
            reset: .header("x-ratelimit-reset-tokens", fallback: "1s"),
            title: .tpmRate,
            unit: "tokens"
        )
        XCTAssertNotNil(window)
        guard let win = window else { return }
        XCTAssertEqual(win.usedAmount ?? .nan, 750.0, accuracy: 0.001)
        XCTAssertEqual(win.totalLimit ?? .nan, 1000.0, accuracy: 0.001)
        XCTAssertEqual(win.usedPercentage, 75.0, accuracy: 0.001)
        XCTAssertEqual(win.unit, "tokens")
        XCTAssertEqual(win.titleKind, .tpmRate)
        XCTAssertFalse(win.isIdle)
        XCTAssertEqual(win.endTime.timeIntervalSince(win.startTime), 30.0, accuracy: 0.001)
    }

    func testRateLimitWindowBuilderHeaderCaseInsensitive() {
        // value(forHTTPHeaderField:) 大小写不敏感，服务器返回混合大小写也能读到
        let resp = makeResponse(status: 200, headers: [
            "X-RateLimit-Limit-Tokens": "800",
            "X-Ratelimit-Remaining-Tokens": "800"
        ])
        let window = RateLimitWindowBuilder.build(
            response: resp,
            limitHeader: "x-ratelimit-limit-tokens",
            remainingHeader: "x-ratelimit-remaining-tokens",
            reset: .header("x-ratelimit-reset-tokens", fallback: "1s"),
            title: .tpmRemaining,
            unit: "tokens"
        )
        guard let win = window else { return XCTFail("window should not be nil") }
        XCTAssertEqual(win.usedAmount ?? .nan, 0.0, accuracy: 0.001)
        XCTAssertEqual(win.usedPercentage, 0.0, accuracy: 0.001)
        XCTAssertEqual(win.isIdle, true)
        // reset 头缺失 → "1s" 兜底
        XCTAssertEqual(win.endTime.timeIntervalSince(win.startTime), 1.0, accuracy: 0.001)
    }

    func testRateLimitWindowBuilderNilCases() {
        // 缺头
        let noHeaders = makeResponse(status: 200)
        XCTAssertNil(RateLimitWindowBuilder.build(
            response: noHeaders,
            limitHeader: "x-ratelimit-limit-tokens",
            remainingHeader: "x-ratelimit-remaining-tokens",
            reset: .header("x-ratelimit-reset-tokens", fallback: "1s"),
            title: .tpmRate,
            unit: "tokens"
        ))

        // limit = 0
        let zeroLimit = makeResponse(status: 200, headers: [
            "x-ratelimit-limit-tokens": "0",
            "x-ratelimit-remaining-tokens": "0"
        ])
        XCTAssertNil(RateLimitWindowBuilder.build(
            response: zeroLimit,
            limitHeader: "x-ratelimit-limit-tokens",
            remainingHeader: "x-ratelimit-remaining-tokens",
            reset: .header("x-ratelimit-reset-tokens", fallback: "1s"),
            title: .tpmRate,
            unit: "tokens"
        ))

        // 非法数字
        let garbage = makeResponse(status: 200, headers: [
            "x-ratelimit-limit-tokens": "abc",
            "x-ratelimit-remaining-tokens": "10"
        ])
        XCTAssertNil(RateLimitWindowBuilder.build(
            response: garbage,
            limitHeader: "x-ratelimit-limit-tokens",
            remainingHeader: "x-ratelimit-remaining-tokens",
            reset: .header("x-ratelimit-reset-tokens", fallback: "1s"),
            title: .tpmRate,
            unit: "tokens"
        ))

        // remaining 缺失（limit 存在）
        let missingRemaining = makeResponse(status: 200, headers: [
            "x-ratelimit-limit-tokens": "100"
        ])
        XCTAssertNil(RateLimitWindowBuilder.build(
            response: missingRemaining,
            limitHeader: "x-ratelimit-limit-tokens",
            remainingHeader: "x-ratelimit-remaining-tokens",
            reset: .header("x-ratelimit-reset-tokens", fallback: "1s"),
            title: .tpmRate,
            unit: "tokens"
        ))
    }

    func testRateLimitWindowBuilderClamping() {
        // remaining > limit：used 钳到 0，isIdle = true
        let over = makeResponse(status: 200, headers: [
            "anthropic-ratelimit-tokens-limit": "100",
            "anthropic-ratelimit-tokens-remaining": "150"
        ])
        let win = RateLimitWindowBuilder.build(
            response: over,
            limitHeader: "anthropic-ratelimit-tokens-limit",
            remainingHeader: "anthropic-ratelimit-tokens-remaining",
            reset: .fixed(60),
            title: .tokenRate,
            unit: "tokens"
        )
        guard let w1 = win else { return XCTFail("window should not be nil") }
        XCTAssertEqual(w1.usedAmount ?? .nan, 0.0, accuracy: 0.001)
        XCTAssertEqual(w1.usedPercentage, 0.0, accuracy: 0.001)
        XCTAssertEqual(w1.isIdle, true)
        XCTAssertEqual(w1.titleKind, .tokenRate)
        // 固定窗长（Claude / CustomProvider-Anthropic requests 的 60s 形状）
        XCTAssertEqual(w1.endTime.timeIntervalSince(w1.startTime), 60.0, accuracy: 0.001)

        // 负 remaining：pct 钳到 100
        let negative = makeResponse(status: 200, headers: [
            "anthropic-ratelimit-tokens-limit": "100",
            "anthropic-ratelimit-tokens-remaining": "-20"
        ])
        let win2 = RateLimitWindowBuilder.build(
            response: negative,
            limitHeader: "anthropic-ratelimit-tokens-limit",
            remainingHeader: "anthropic-ratelimit-tokens-remaining",
            reset: .fixed(60),
            title: .tokenRate,
            unit: "tokens"
        )
        guard let w2 = win2 else { return XCTFail("window should not be nil") }
        XCTAssertEqual(w2.usedAmount ?? .nan, 120.0, accuracy: 0.001)
        XCTAssertEqual(w2.usedPercentage, 100.0, accuracy: 0.001)
        XCTAssertEqual(w2.isIdle, false)
    }

    func testRateLimitWindowBuilderResetGarbageFallsBackToOneSecond() {
        let resp = makeResponse(status: 200, headers: [
            "x-ratelimit-limit-requests": "60",
            "x-ratelimit-remaining-requests": "30",
            "x-ratelimit-reset-requests": "not-a-duration"
        ])
        let win = RateLimitWindowBuilder.build(
            response: resp,
            limitHeader: "x-ratelimit-limit-requests",
            remainingHeader: "x-ratelimit-remaining-requests",
            reset: .header("x-ratelimit-reset-requests", fallback: "1s"),
            title: .rpmRequest,
            unit: "req"
        )
        guard let w = win else { return XCTFail("window should not be nil") }
        XCTAssertEqual(w.usedAmount ?? .nan, 30.0, accuracy: 0.001)
        XCTAssertEqual(w.titleKind, .rpmRequest)
        XCTAssertEqual(w.unit, "req")
        // 头存在但不可解析 → 1s 兜底（原 parseDurationString 语义）
        XCTAssertEqual(w.endTime.timeIntervalSince(w.startTime), 1.0, accuracy: 0.001)
    }

    // MARK: - throwForStatus：各 provider 文案逐字节断言（中文）

    func testThrowForStatusOpenAICopies() {
        withLanguage(.zhHans) {
            // 401
            do {
                try throwForStatus(makeResponse(status: 401), data: Data(), domain: "OpenAIService", messages: OpenAIService.errorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.domain, "OpenAIService")
                XCTAssertEqual(e.code, 401)
                XCTAssertEqual(e.localizedDescription, "OpenAI API Key 无效或已过期 (HTTP 401)")
            } catch { XCTFail("wrong error") }

            // 429 带 JSON error.message → 整体替换文案
            let detail = "{\"error\": {\"message\": \"You exceeded your current quota\"}}"
            do {
                try throwForStatus(makeResponse(status: 429), data: Data(detail.utf8), domain: "OpenAIService", messages: OpenAIService.errorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.code, 429)
                XCTAssertEqual(e.localizedDescription, "You exceeded your current quota")
            } catch { XCTFail("wrong error") }

            // 429 无 JSON detail → 默认文案
            do {
                try throwForStatus(makeResponse(status: 429), data: Data("plain".utf8), domain: "OpenAIService", messages: OpenAIService.errorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.localizedDescription, "请求过于频繁或额度已耗尽 (HTTP 429)")
            } catch { XCTFail("wrong error") }

            // 非 2xx：snippet 截 120，文案带状态码
            let longBody = String(repeating: "a", count: 150)
            do {
                try throwForStatus(makeResponse(status: 500), data: Data(longBody.utf8), domain: "OpenAIService", messages: OpenAIService.errorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.code, 500)
                XCTAssertEqual(e.localizedDescription, "OpenAI 接口请求失败 (500): \(String(repeating: "a", count: 120))")
            } catch { XCTFail("wrong error") }

            // 非 UTF-8 响应体 → "HTTP <code>" 兜底
            let invalidUTF8 = Data([0xFF, 0xFE, 0xFD])
            do {
                try throwForStatus(makeResponse(status: 502), data: invalidUTF8, domain: "OpenAIService", messages: OpenAIService.errorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.localizedDescription, "OpenAI 接口请求失败 (502): HTTP 502")
            } catch { XCTFail("wrong error") }
        }
    }

    func testThrowForStatusFixedRateLimitCopyAndShortSnippet() {
        withLanguage(.zhHans) {
            // Kimi：429 固定文案（即使 body 里有 error.message 也不解析）
            let detail = "{\"error\": {\"message\": \"should not appear\"}}"
            do {
                try throwForStatus(makeResponse(status: 429), data: Data(detail.utf8), domain: "KimiService", messages: KimiService.errorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.localizedDescription, "KIMI 请求并发超限或额度不足 (HTTP 429)")
            } catch { XCTFail("wrong error") }

            // Kimi：非 2xx 带状态码，snippet 截 100
            let longBody = String(repeating: "b", count: 150)
            do {
                try throwForStatus(makeResponse(status: 503), data: Data(longBody.utf8), domain: "KimiService", messages: KimiService.errorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.localizedDescription, "KIMI 接口响应异常 (503): \(String(repeating: "b", count: 100))")
            } catch { XCTFail("wrong error") }

            // DeepSeek：失败文案不带状态码
            do {
                try throwForStatus(makeResponse(status: 500), data: Data("boom".utf8), domain: "DeepSeekService", messages: DeepSeekService.errorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.localizedDescription, "DeepSeek 接口异常: boom")
            } catch { XCTFail("wrong error") }

            // Claude（Anthropic API Key 链路）：失败文案不带状态码
            do {
                try throwForStatus(makeResponse(status: 401), data: Data(), domain: "ClaudeService", messages: ClaudeService.anthropicErrorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.localizedDescription, "Anthropic API Key 无效或未授权 (HTTP 401)")
            } catch { XCTFail("wrong error") }
            do {
                try throwForStatus(makeResponse(status: 500), data: Data("oops".utf8), domain: "ClaudeService", messages: ClaudeService.anthropicErrorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.localizedDescription, "Anthropic 接口响应异常: oops")
            } catch { XCTFail("wrong error") }

            // Volcengine：失败文案带状态码
            do {
                try throwForStatus(makeResponse(status: 500), data: Data("err".utf8), domain: "VolcengineService", messages: VolcengineService.errorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.localizedDescription, "火山方舟响应异常 (500): err")
            } catch { XCTFail("wrong error") }
        }
    }

    func testThrowForStatusEnglishCopies() {
        withLanguage(.en) {
            do {
                try throwForStatus(makeResponse(status: 401), data: Data(), domain: "DeepSeekService", messages: DeepSeekService.errorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.localizedDescription, "DeepSeek API Key is invalid or unauthorized (HTTP 401)")
            } catch { XCTFail("wrong error") }

            do {
                try throwForStatus(makeResponse(status: 429), data: Data(), domain: "VolcengineService", messages: VolcengineService.errorMessages)
                XCTFail("should throw")
            } catch let e as NSError {
                XCTAssertEqual(e.localizedDescription, "Volcengine Ark concurrency or rate limit exceeded (HTTP 429)")
            } catch { XCTFail("wrong error") }
        }
    }

    func testThrowForStatusPassesThrough2xx() throws {
        // 2xx 不抛错（含 204 等无 body 形状）
        try throwForStatus(makeResponse(status: 200), data: Data(), domain: "X", messages: OpenAIService.errorMessages)
        try throwForStatus(makeResponse(status: 204), data: Data(), domain: "X", messages: OpenAIService.errorMessages)
        try throwForStatus(makeResponse(status: 299), data: Data(), domain: "X", messages: OpenAIService.errorMessages)
    }
}
