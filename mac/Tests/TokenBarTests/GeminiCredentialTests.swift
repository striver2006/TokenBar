import XCTest
import SwiftUI
@testable import TokenBar

final class GeminiCredentialTests: XCTestCase {
    func testGeminiLocalFilesParserFromFixture() throws {
        // 临时目录充当 home，三个文件全部用 fixture，不依赖本机 ~/.gemini
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tokenbar-gemini-\(UUID().uuidString)")
        let dir = home.appendingPathComponent(".gemini")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let jetski: [String: Any] = ["token": ["access_token": "ya29.jetski", "refresh_token": "1//refresh", "expiry": "2030-01-01T00:00:00Z"]]
        try JSONSerialization.data(withJSONObject: jetski).write(to: dir.appendingPathComponent("jetski-standalone-oauth-token"))
        try JSONSerialization.data(withJSONObject: ["access_token": "ya29.oauth", "refresh_token": "1//oauth"]).write(to: dir.appendingPathComponent("oauth_creds.json"))
        try JSONSerialization.data(withJSONObject: ["active": "user@example.com", "old": ["prev@example.com"]]).write(to: dir.appendingPathComponent("google_accounts.json"))

        let files = GeminiService.parseLocalGeminiFiles(homeDir: home)
        XCTAssertEqual(files.jetskiToken, "ya29.jetski")
        XCTAssertEqual(files.jetskiRefreshToken, "1//refresh")
        XCTAssertNotNil(files.jetskiExpiry)
        XCTAssertEqual(files.oauthToken, "ya29.oauth")
        XCTAssertEqual(files.account, "user@example.com")

        // 目录不存在：全部为 nil，不崩
        let empty = GeminiService.parseLocalGeminiFiles(homeDir: home.appendingPathComponent("missing"))
        XCTAssertNil(empty.jetskiToken)
        XCTAssertNil(empty.account)
    }

    // MARK: - Gemini 凭证三层合并

    // 守的是「钥匙串是活数据、文件可能陈旧」这条顺序：钥匙串有 token 时必须连 expiry 一起用它的，
    // 否则会拿着新 token 配旧 expiry，被误判为过期而去多做一次无谓的刷新。

    private func geminiFiles(
        jetskiToken: String? = nil, jetskiRefresh: String? = nil, jetskiExpiry: Date? = nil,
        oauthToken: String? = nil, oauthRefresh: String? = nil
    ) -> GeminiService.LocalGeminiFiles {
        var f = GeminiService.LocalGeminiFiles()
        f.jetskiToken = jetskiToken
        f.jetskiRefreshToken = jetskiRefresh
        f.jetskiExpiry = jetskiExpiry
        f.oauthToken = oauthToken
        f.oauthRefreshToken = oauthRefresh
        return f
    }

    func testGeminiMergeKeychainWinsWithItsOwnExpiry() {
        let kcExpiry = Date().addingTimeInterval(3600)
        let fileExpiry = Date().addingTimeInterval(-86400)
        let merged = GeminiService.mergeCredentials(
            keychain: .init(token: "kc-at", refreshToken: "kc-rt", expiry: kcExpiry),
            files: geminiFiles(jetskiToken: "file-at", jetskiRefresh: "file-rt", jetskiExpiry: fileExpiry),
            storedRefreshToken: "stored-rt"
        )
        XCTAssertEqual(merged.token, "kc-at")
        XCTAssertEqual(merged.refreshToken, "kc-rt")
        XCTAssertEqual(merged.expiry, kcExpiry)
    }

    func testGeminiMergeFallsBackToFileWhenKeychainUnavailable() {
        let fileExpiry = Date().addingTimeInterval(600)
        let merged = GeminiService.mergeCredentials(
            keychain: nil,
            files: geminiFiles(jetskiToken: "file-at", jetskiRefresh: "file-rt", jetskiExpiry: fileExpiry),
            storedRefreshToken: "stored-rt"
        )
        XCTAssertEqual(merged.token, "file-at")
        XCTAssertEqual(merged.refreshToken, "file-rt")
        XCTAssertEqual(merged.expiry, fileExpiry)
    }

    /// 各失败阶段的文案必须指向确实有效的恢复动作，阶段之间不能互相冒充：
    /// - keychainACL → 设置页授权（去 Antigravity 重登无效）
    /// - refreshTokenDead → Google 账号登录（重新授权也救不了被轮换的 token）
    /// - ownLoginRevoked → 重新登录
    /// 以前只有一个 keychainDenied 布尔：钥匙串读不到时任何环节失败都显示「授权被拒」，
    /// 把 refresh_token 被轮换这类故障反复引向无效的重新授权——这正是本次修的 bug。
    func testGeminiFailureMessagePerStage() {
        let acl = GeminiService.credentialFailureMessage(.keychainACL, isZh: true)
        XCTAssertTrue(acl.contains("读取本地 Gemini 配置"))
        XCTAssertTrue(acl.contains("始终允许"))

        let dead = GeminiService.credentialFailureMessage(.refreshTokenDead, isZh: true)
        XCTAssertTrue(dead.contains("Google 账号登录"))
        XCTAssertFalse(dead.contains("始终允许"), "refresh_token 已被判死时，指引重新授权是无效动作")

        let revoked = GeminiService.credentialFailureMessage(.ownLoginRevoked, isZh: true)
        XCTAssertTrue(revoked.contains("重新登录"))

        let none = GeminiService.credentialFailureMessage(.noCredentials, isZh: true)
        XCTAssertTrue(none.contains("未找到"))

        let cooldown = GeminiService.credentialFailureMessage(.refreshTokenCooldown, isZh: true)
        XCTAssertTrue(cooldown.contains("自动重试"))

        let mismatch = GeminiService.credentialFailureMessage(.clientMismatch, isZh: true)
        XCTAssertTrue(mismatch.contains("配对失效"))
        XCTAssertFalse(mismatch.contains("检查网络"), "client 配对问题不是网络问题")

        let aclEn = GeminiService.credentialFailureMessage(.keychainACL, isZh: false)
        XCTAssertTrue(aclEn.contains("Always Allow"))
    }

    /// 「ACL 拒」只认 -25293/-25308：超时（status=nil）、其它 OSStatus、读取成功
    /// 都不得触发「去重新授权」的指引。
    func testForeignLookupACLDetection() {
        XCTAssertTrue(ForeignLookup(lookup: .unavailable, status: errSecAuthFailed).isACLDenied)
        XCTAssertTrue(ForeignLookup(lookup: .unavailable, status: errSecInteractionNotAllowed).isACLDenied)
        XCTAssertFalse(ForeignLookup(lookup: .unavailable, status: nil).isACLDenied, "超时放弃不是 ACL 拒")
        XCTAssertFalse(ForeignLookup(lookup: .unavailable, status: errSecItemNotFound).isACLDenied)
        XCTAssertFalse(ForeignLookup(lookup: .found("x"), status: errSecSuccess).isACLDenied)
    }

    /// 自有登录的账号展示来自 Google id_token（JWT）：解 base64url payload 取 email。
    func testGeminiEmailFromIDToken() {
        let payload = Data(#"{"email":"user@example.com"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(GeminiService.emailFromIDToken("h.\(payload).s"), "user@example.com")
        XCTAssertNil(GeminiService.emailFromIDToken("not-a-jwt"))
        XCTAssertNil(GeminiService.emailFromIDToken(nil))
    }

    /// 钥匙串只有 refresh_token 没有 access_token 时，token/expiry 从文件补，refresh 仍用钥匙串的。
    func testGeminiMergeFillsMissingFieldsFromFile() {
        let fileExpiry = Date().addingTimeInterval(600)
        let merged = GeminiService.mergeCredentials(
            keychain: .init(token: nil, refreshToken: "kc-rt", expiry: nil),
            files: geminiFiles(jetskiToken: "file-at", jetskiRefresh: "file-rt", jetskiExpiry: fileExpiry),
            storedRefreshToken: nil
        )
        XCTAssertEqual(merged.token, "file-at")
        XCTAssertEqual(merged.refreshToken, "kc-rt")
        XCTAssertEqual(merged.expiry, fileExpiry)
    }

    /// 钥匙串、文件都没有 refresh_token 时才用自有条目里的快照；空串不算有。
    func testGeminiMergeStoredSnapshotIsLastResort() {
        let merged = GeminiService.mergeCredentials(keychain: nil, files: geminiFiles(), storedRefreshToken: "stored-rt")
        XCTAssertNil(merged.token)
        XCTAssertEqual(merged.refreshToken, "stored-rt")

        let empty = GeminiService.mergeCredentials(keychain: nil, files: geminiFiles(), storedRefreshToken: "")
        XCTAssertNil(empty.refreshToken)
    }

    func testGeminiKeychainPayloadDecodesGoKeyringBase64() {
        let inner = #"{"auth_method":"consumer","token":{"access_token":"at","refresh_token":"rt","expiry":"2026-09-10T20:16:39+08:00"}}"#
        let raw = "go-keyring-base64:" + Data(inner.utf8).base64EncodedString()
        let dict = GeminiService.decodeKeychainPayload(raw)
        XCTAssertEqual(dict?["access_token"] as? String, "at")
        XCTAssertEqual(dict?["refresh_token"] as? String, "rt")
        XCTAssertNil(GeminiService.decodeKeychainPayload("go-keyring-base64:@@@"))
        XCTAssertNil(GeminiService.decodeKeychainPayload(#"{"no_token":1}"#))
    }

    func testGeminiFormBodyStrictlyEncodesReservedCharacters() {
        // .urlQueryAllowed 不转义 & = +，refresh_token/client_secret 含这些字符会拆坏表单体
        let body = GeminiService.formBody([
            "grant_type": "refresh_token",
            "refresh_token": "1//0g+a=b&c"
        ])
        let bodyString = String(data: body, encoding: .utf8)!
        XCTAssertEqual(bodyString, "grant_type=refresh_token&refresh_token=1%2F%2F0g%2Ba%3Db%26c")
    }
}
