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
                "fetchedAtMs": 1790937318646,
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
        // 缓存自身的抓取时间：毫秒时间戳原样换算，卡片据此标注「N 分钟前」
        XCTAssertEqual(try XCTUnwrap(parsed.fetchedAt).timeIntervalSince1970, 1790937318.646, accuracy: 0.001)
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
        XCTAssertNil(parsed.fetchedAt)
    }

    func testClaudeCacheWithoutFetchedAtMs() {
        // 老版本 Claude Code 写的缓存可能没有 fetchedAtMs：照常解析窗口，时间戳留空
        let parsed = ClaudeService.shared.parseLocalClaudeJson([
            "cachedUsageUtilization": ["utilization": ["five_hour": ["utilization": 10]]]
        ])
        XCTAssertNotNil(parsed.fiveHour)
        XCTAssertNil(parsed.fetchedAt)
    }

    func testLocalCacheNote() {
        // 「更新于」是 TokenBar 的刷新时刻，缓存可能旧得多：卡片要标注缓存自己的抓取时间
        withChineseUI {
            let now = Date(timeIntervalSince1970: 1_790_940_000)
            var quota = ProviderQuota(provider: .claudeCode)
            XCTAssertNil(quota.localCacheNote(now: now), "实时数据不标注")

            quota.isFromLocalCache = true
            XCTAssertEqual(quota.localCacheNote(now: now), "来自 Claude Code 本地缓存")

            quota.localCacheFetchedAt = now.addingTimeInterval(-12 * 60 - 30)
            XCTAssertEqual(quota.localCacheNote(now: now), "来自 Claude Code 本地缓存 · 12 分钟前")
        }
        withEnglishUI {
            let now = Date(timeIntervalSince1970: 1_790_940_000)
            let quota = ProviderQuota(
                provider: .claudeCode, isFromLocalCache: true,
                localCacheFetchedAt: now.addingTimeInterval(-3 * 3600))
            XCTAssertEqual(quota.localCacheNote(now: now), "From Claude Code local cache · 3h ago")
        }
    }

    func testRelativeAgeBoundaries() {
        withChineseUI {
            let now = Date(timeIntervalSince1970: 1_790_940_000)
            func age(_ seconds: TimeInterval) -> String {
                ProviderQuota.relativeAge(from: now.addingTimeInterval(-seconds), now: now)
            }
            XCTAssertEqual(age(-30), "刚刚", "时钟回拨的负间隔按刚刚处理")
            XCTAssertEqual(age(59), "刚刚")
            XCTAssertEqual(age(60), "1 分钟前")
            XCTAssertEqual(age(3599), "59 分钟前")
            XCTAssertEqual(age(3600), "1 小时前")
            XCTAssertEqual(age(86399), "23 小时前")
            XCTAssertEqual(age(2 * 86400), "2 天前")
        }
    }

    // MARK: - Claude Code 凭证

    func testParseClaudeCodeCredential() throws {
        // 与 Claude Code 写入钥匙串的结构一致；refreshToken 存在但绝不能被取用
        let raw = """
        {"claudeAiOauth":{"accessToken":" sk-ant-oat01-test ","refreshToken":"sk-ant-ort01-test",\
        "expiresAt":1790966400000,"scopes":["user:inference"],"subscriptionType":"max"}}
        """
        let credential = try XCTUnwrap(ClaudeService.parseClaudeCodeCredential(raw))
        XCTAssertEqual(credential.accessToken, "sk-ant-oat01-test", "首尾空白要去掉")
        XCTAssertEqual(try XCTUnwrap(credential.expiresAt).timeIntervalSince1970, 1_790_966_400, accuracy: 0.001)
    }

    func testParseClaudeCodeCredentialRejectsMalformed() {
        XCTAssertNil(ClaudeService.parseClaudeCodeCredential("not json"))
        XCTAssertNil(ClaudeService.parseClaudeCodeCredential(#"{"other":{}}"#))
        XCTAssertNil(ClaudeService.parseClaudeCodeCredential(#"{"claudeAiOauth":{"accessToken":""}}"#),
                     "Claude Code 把失效的 refresh token 标死时会清空 accessToken，不能当成可用凭证")
        // 没有 expiresAt：照常可用，401 时自然退回缓存
        let noExpiry = ClaudeService.parseClaudeCodeCredential(#"{"claudeAiOauth":{"accessToken":"t"}}"#)
        XCTAssertEqual(noExpiry, ClaudeCodeCredential(accessToken: "t", expiresAt: nil))
    }

    func testClaudeCodeCredentialUsability() {
        let now = Date(timeIntervalSince1970: 1_790_940_000)
        XCTAssertTrue(ClaudeCodeCredential(accessToken: "t", expiresAt: nil).isUsable(at: now))
        XCTAssertTrue(ClaudeCodeCredential(accessToken: "t", expiresAt: now.addingTimeInterval(3600)).isUsable(at: now))
        XCTAssertFalse(ClaudeCodeCredential(accessToken: "t", expiresAt: now.addingTimeInterval(30)).isUsable(at: now),
                       "离过期不足 60 秒：请求在途中过期只会换来 401")
        XCTAssertFalse(ClaudeCodeCredential(accessToken: "t", expiresAt: now.addingTimeInterval(-1)).isUsable(at: now))
    }

    func testClaudeCodeKeychainAccountMirrorsClaudeCode() {
        XCTAssertEqual(ClaudeService.claudeCodeKeychainAccount(environment: ["USER": "chenzhenbo"]), "chenzhenbo")
        XCTAssertEqual(ClaudeService.claudeCodeKeychainAccount(environment: ["USER": "a.b-c_d"]), "a.b-c_d")
        // 含空格等非法字符时 Claude Code 退成固定名，这里必须一致，否则查不到条目
        XCTAssertEqual(ClaudeService.claudeCodeKeychainAccount(environment: ["USER": "张 三"]), "claude-code-user")
        XCTAssertEqual(ClaudeService.claudeCodeKeychainAccount(environment: ["USER": ""]), "claude-code-user")
    }

    func testDecodeSecurityPasswordOutput() throws {
        // 可打印内容：security -w 原样输出（带换行）
        let json = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":1790966400000}}"#
        XCTAssertEqual(ClaudeService.decodeSecurityPasswordOutput(json + "\n"), json)
        // 含不可打印字节时 security -w 改输出十六进制：要还原成原文再解析
        let hex = json.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ClaudeService.decodeSecurityPasswordOutput(hex + "\n"), json)
        let credential = try XCTUnwrap(ClaudeService.parseClaudeCodeCredential(ClaudeService.decodeSecurityPasswordOutput(hex)))
        XCTAssertEqual(credential.accessToken, "t")
        // 不是合法十六进制（奇数长度 / 非 hex 字符）：原样返回，交给 JSON 解析去判失败
        XCTAssertEqual(ClaudeService.decodeSecurityPasswordOutput("abc"), "abc")
        XCTAssertEqual(ClaudeService.decodeSecurityPasswordOutput("not-hex!"), "not-hex!")
    }
}
