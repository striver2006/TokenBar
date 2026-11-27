import XCTest
import SwiftUI
@testable import TokenBar

/// retrieveUserQuotaSummary 的假端点：按 host 回响应体，没登记的 host 当作连不上。
private actor GeminiQuotaEndpointFixture {
    private(set) var requestedHosts: [String] = []
    private let responses: [String: String]
    init(_ responses: [String: String]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url!
        requestedHosts.append(url.host ?? "")
        guard let body = responses[url.host ?? ""] else { throw URLError(.cannotConnectToHost) }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class GeminiCredentialTests: XCTestCase {
    override func tearDown() {
        // 官方端点的偏好会落盘；测试进程里不能让用例之间串味
        UserDefaults.standard.removeObject(forKey: GeminiService.preferredCloudCodeEndpointKey)
        super.tearDown()
    }

    private func quotaService(_ fixture: GeminiQuotaEndpointFixture) -> GeminiService {
        UserDefaults.standard.removeObject(forKey: GeminiService.preferredCloudCodeEndpointKey)
        return GeminiService(tokenRefreshEnvironment: .init(candidates: { [] }, send: { try await fixture.send($0) }))
    }

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

    // MARK: - Gemini 配额组解析（retrieveUserQuotaSummary）

    /// 守的是「两个配额端点分组集不同」那次线上事故：daily 端点只回
    /// "Claude and GPT models" 组，Gemini 组只在 cloudcode-pa 上。旧逻辑首个 2xx
    /// 即返回，Gemini 组匹配不上就静默退化到只产 5h 窗口的按模型回退——
    /// 「只有 5 小时额度、没有每周额度」的根因。
    private func quotaSummaryJSON(groups: [[String: Any]]) -> [String: Any] {
        var summary: [String: Any] = ["groups": groups]
        summary["description"] = "Within each group, models share a weekly limit and a 5-hour limit."
        return summary
    }

    private func bucket(_ fields: [String: Any]) -> [String: Any] { fields }

    func testParseGeminiGroupWindowsFromCloudCodeStyleResponse() {
        // cloudcode-pa 实测形状：Gemini Models 与 Claude and GPT models 两组并存，只取前者的桶
        let summary = quotaSummaryJSON(groups: [
            [
                "displayName": "Gemini Models",
                "description": "Models within this group: Gemini Flash, Gemini Pro",
                "buckets": [
                    bucket(["window": "weekly", "remainingFraction": 0.9555, "resetTime": "2030-01-01T00:00:00Z"]),
                    bucket(["window": "5h", "remainingFraction": 0.5, "resetTime": "2030-01-01T00:00:00Z"])
                ]
            ],
            [
                "displayName": "Claude and GPT models",
                "buckets": [
                    bucket(["window": "weekly", "remainingFraction": 1, "resetTime": "2030-01-01T00:00:00Z"]),
                    bucket(["window": "5h", "remainingFraction": 1, "resetTime": "2030-01-01T00:00:00Z"])
                ]
            ]
        ])

        let (fiveHour, weekly, scopedWeekly) = GeminiService.parseGeminiGroupWindows(summary)
        XCTAssertEqual(weekly?.titleKind, .weekly)
        XCTAssertEqual(weekly?.usedPercentage ?? 0, 4.45, accuracy: 0.01, "取 Gemini 组的 weekly（4.45% 已用），不是 Claude 组的 0%")
        XCTAssertEqual(fiveHour?.titleKind, .fiveHour)
        XCTAssertEqual(fiveHour?.usedPercentage ?? 0, 50.0, accuracy: 0.001)
        XCTAssertNil(scopedWeekly)
    }

    func testParseGeminiGroupWindowsDailyStyleResponseHasNoGeminiGroup() {
        // daily-cloudcode-pa 实测形状：只有 Claude/GPT 组 → (nil, nil, nil)，
        // 让 fetchAntigravityQuota 继续试下一个端点而不是错拿别组的额度
        let summary = quotaSummaryJSON(groups: [
            [
                "displayName": "Claude and GPT models",
                "buckets": [
                    bucket(["window": "weekly", "remainingFraction": 1, "resetTime": "2030-01-01T00:00:00Z"]),
                    bucket(["window": "5h", "remainingFraction": 1, "resetTime": "2030-01-01T00:00:00Z"])
                ]
            ]
        ])

        let (fiveHour, weekly, scopedWeekly) = GeminiService.parseGeminiGroupWindows(summary)
        XCTAssertNil(fiveHour)
        XCTAssertNil(weekly)
        XCTAssertNil(scopedWeekly)
    }

    func testParseGeminiGroupWindowsPrefersCanonicalGeminiModelsGroup() {
        // 变体组（如 IDE 面板里的 "Gemini 4 Argon"）排在前面也不能抢走正主的桶，
        // 且独立解析为 scopedWeekly 额度
        let summary = quotaSummaryJSON(groups: [
            [
                "displayName": "Gemini 4 Argon",
                "buckets": [bucket(["window": "weekly", "remainingFraction": 0.07, "resetTime": "2030-01-01T00:00:00Z"])]
            ],
            [
                "displayName": "Gemini Models",
                "buckets": [bucket(["window": "weekly", "remainingFraction": 0.9, "resetTime": "2030-01-01T00:00:00Z"])]
            ]
        ])

        let (fiveHour, weekly, scopedWeekly) = GeminiService.parseGeminiGroupWindows(summary)
        XCTAssertNil(fiveHour)
        XCTAssertEqual(weekly?.usedPercentage ?? 0, 10.0, accuracy: 0.001, "正主 Gemini Models（90% 剩余）优先，Argon（93% 已用）不抢")
        XCTAssertEqual(scopedWeekly?.usedPercentage ?? 0, 93.0, accuracy: 0.001, "Argon 组成功解析出独立周额度")
        XCTAssertEqual(scopedWeekly?.titleKind, .custom("Gemini 4 Argon"))
    }

    func testParseGeminiGroupWindowsArgonOnlyOrReversedOrder() {
        // 正主在前、Argon 在后，两组均有数据
        let summary = quotaSummaryJSON(groups: [
            [
                "displayName": "Gemini Models",
                "buckets": [
                    bucket(["window": "5h", "remainingFraction": 0.8, "resetTime": "2030-01-01T00:00:00Z"]),
                    bucket(["window": "weekly", "remainingFraction": 0.7, "resetTime": "2030-01-01T00:00:00Z"])
                ]
            ],
            [
                "displayName": "Gemini 4 Argon",
                "buckets": [bucket(["window": "weekly", "remainingFraction": 0.45, "resetTime": "2030-01-01T00:00:00Z"])]
            ]
        ])

        let (fiveHour, weekly, scopedWeekly) = GeminiService.parseGeminiGroupWindows(summary)
        XCTAssertEqual(fiveHour?.usedPercentage ?? 0, 20.0, accuracy: 0.001)
        XCTAssertEqual(weekly?.usedPercentage ?? 0, 30.0, accuracy: 0.001)
        XCTAssertEqual(scopedWeekly?.usedPercentage ?? 0, 55.0, accuracy: 0.001)
        XCTAssertEqual(scopedWeekly?.titleKind, .custom("Gemini 4 Argon"))
    }

    func testParseGeminiGroupWindowsWrappedInResponseField() {
        // Antigravity 本地 LanguageServer Connect-RPC 响应形状：带有 {"response": {"groups": [...]}} 包装
        let summary: [String: Any] = [
            "response": [
                "groups": [
                    [
                        "displayName": "Gemini Models",
                        "buckets": [
                            bucket(["window": "5h", "remainingFraction": 0.85, "resetTime": "2030-01-01T00:00:00Z"]),
                            bucket(["window": "weekly", "remainingFraction": 0.60, "resetTime": "2030-01-01T00:00:00Z"])
                        ]
                    ],
                    [
                        "displayName": "Gemini 4 Argon",
                        "buckets": [bucket(["window": "weekly", "remainingFraction": 0.2859, "resetTime": "2030-01-01T00:00:00Z"])]
                    ]
                ]
            ]
        ]

        let (fiveHour, weekly, scopedWeekly) = GeminiService.parseGeminiGroupWindows(summary)
        XCTAssertEqual(fiveHour?.usedPercentage ?? 0, 15.0, accuracy: 0.001)
        XCTAssertEqual(weekly?.usedPercentage ?? 0, 40.0, accuracy: 0.001)
        XCTAssertEqual(scopedWeekly?.usedPercentage ?? 0, 71.41, accuracy: 0.01)
        XCTAssertEqual(scopedWeekly?.titleKind, .custom("Gemini 4 Argon"))
    }

    func testParseQuotaBucketWeeklyAndFiveHour() {
        let weekly = GeminiService.parseQuotaBucket(["bucketId": "gemini-weekly", "remainingFraction": 0.25, "resetTime": "2030-01-01T00:00:00Z"])
        XCTAssertTrue(weekly?.isWeekly ?? false)
        XCTAssertEqual(weekly?.window.titleKind, .weekly)
        XCTAssertEqual(weekly?.window.usedPercentage ?? 0, 75.0, accuracy: 0.001)

        let fiveHour = GeminiService.parseQuotaBucket(["window": "5h", "remainingFraction": 0.8])
        XCTAssertEqual(fiveHour?.window.titleKind, .fiveHour)
        XCTAssertEqual(fiveHour?.window.usedPercentage ?? 0, 20.0, accuracy: 0.001)

        XCTAssertNil(GeminiService.parseQuotaBucket(["window": "daily", "remainingFraction": 0.5]), "未知窗口类型不产窗口")
        XCTAssertNil(GeminiService.parseQuotaBucket(["window": "5h"]), "缺 remainingFraction 不产窗口")
    }

    func testFetchLocalAntigravityQuotaGracefulOrLive() async {
        let service = GeminiService()
        let result = await service.fetchLocalAntigravityQuota()
        if let res = result {
            XCTAssertTrue(res.fiveHour != nil || res.weekly != nil || res.scopedWeekly != nil)
            if let argon = res.scopedWeekly {
                XCTAssertEqual(argon.titleKind, .custom("Gemini 4 Argon"))
            }
        }
    }

    // MARK: - 本地 LanguageServer 进程扫描

    /// Antigravity 2.35.2 实测启动参数：argv 里没有 --csrf_token（ps 对同机所有用户可见），
    /// CSRF token 改经环境变量 ANTIGRAVITY_SERVER_CSRF_TOKEN 传入。只认 argv 的话，
    /// IDE 一升级快速通道就静默失效，退回远程链路。
    private static let currentLanguageServerLine = """
    23335 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --override_ide_name antigravity --subclient_type hub --override_ide_version 2.35.2 --override_user_agent_name antigravity --https_server_port 0 --app_data_dir antigravity --api_server_url https://generativelanguage.googleapis.com --cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com --enable_sidecars --host_bridge_url=http://127.0.0.1:58058 --read_host_bridge_token_from_stdin
    """
    private static let legacyLanguageServerLine = """
    4242 /Applications/Antigravity.app/Contents/Resources/app/extensions/language_server_macos --api_server_url https://server.codeium.com --csrf_token 11111111-2222-3333-4444-555555555555 --cloud_code_endpoint https://cloudcode-pa.googleapis.com
    """
    private static let psEnvironmentDump = """
    /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone HOME=/Users/demo PATH=/usr/bin:/bin ANTIGRAVITY_SERVER_CSRF_TOKEN=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee AGY_REQUIRE_AUTHENTICATED_UI_BOOTSTRAP=1
    """

    func testScanReadsCsrfTokenFromEnvironmentWhenArgvNoLongerCarriesIt() {
        var environmentProbes: [pid_t] = []
        let scan = GeminiService.scanLocalLanguageServers(
            processList: "  100 /Applications/Safari.app/Contents/MacOS/Safari\n\(Self.currentLanguageServerLine)\n",
            environment: { pid in environmentProbes.append(pid); return Self.psEnvironmentDump },
            listeningPorts: { _ in [58071, 58072] }
        )

        XCTAssertEqual(scan.cloudCodeEndpoint, "https://daily-cloudcode-pa.googleapis.com")
        XCTAssertEqual(scan.candidates.map(\.pid), [23335])
        XCTAssertEqual(scan.candidates.first?.csrfToken, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(scan.candidates.first?.ports, [58071, 58072])
        XCTAssertEqual(environmentProbes, [23335], "只为 language_server 进程读环境")
    }

    func testScanKeepsLegacyArgvTokenWithoutReadingEnvironment() {
        var environmentProbes = 0
        let scan = GeminiService.scanLocalLanguageServers(
            processList: Self.legacyLanguageServerLine,
            environment: { _ in environmentProbes += 1; return nil },
            listeningPorts: { _ in [41234] }
        )

        XCTAssertEqual(scan.candidates.first?.csrfToken, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(scan.cloudCodeEndpoint, "https://cloudcode-pa.googleapis.com")
        XCTAssertEqual(environmentProbes, 0, "argv 里有 token 就不必再读环境")
    }

    func testScanRecordsOfficialEndpointEvenWithoutReadableToken() {
        let scan = GeminiService.scanLocalLanguageServers(
            processList: Self.currentLanguageServerLine,
            environment: { _ in "HOME=/Users/demo" },
            listeningPorts: { _ in [58071] }
        )

        XCTAssertTrue(scan.candidates.isEmpty, "拿不到 token 就没有可查询的探针")
        XCTAssertEqual(scan.cloudCodeEndpoint, "https://daily-cloudcode-pa.googleapis.com", "端点仍要带回：远程链路靠它跟随官方客户端")
    }

    func testScanWithoutProcessListYieldsNothing() {
        let scan = GeminiService.scanLocalLanguageServers(processList: nil, environment: { _ in nil }, listeningPorts: { _ in [] })
        XCTAssertNil(scan.cloudCodeEndpoint)
        XCTAssertTrue(scan.candidates.isEmpty)
    }

    func testCommandFlagAcceptsBothArgumentForms() {
        let line = "--csrf_token 1111-2222 --host_bridge_url=http://127.0.0.1:58058"
        XCTAssertEqual(GeminiService.commandFlag(line, name: "--csrf_token"), "1111-2222")
        XCTAssertEqual(GeminiService.commandFlag(line, name: "--host_bridge_url"), "http://127.0.0.1:58058")
        XCTAssertNil(GeminiService.commandFlag("ls --csrf_token", name: "--csrf_token"), "有参数名没有值")
        XCTAssertNil(GeminiService.commandFlag("ls --csrf_token_file=/tmp/x", name: "--csrf_token"), "更长的参数名不算命中")
    }

    func testEnvironmentValueRequiresWholeEntry() {
        let dump = Self.psEnvironmentDump
        XCTAssertEqual(GeminiService.environmentValue(dump, key: "ANTIGRAVITY_SERVER_CSRF_TOKEN"), "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertNil(GeminiService.environmentValue(dump, key: "MISSING_KEY"))
        XCTAssertNil(GeminiService.environmentValue("XANTIGRAVITY_SERVER_CSRF_TOKEN=nope", key: "ANTIGRAVITY_SERVER_CSRF_TOKEN"))
        // 环境从下一行开始也算一项的开头
        XCTAssertEqual(GeminiService.environmentValue("ls --standalone\nANTIGRAVITY_SERVER_CSRF_TOKEN=next-line\n", key: "ANTIGRAVITY_SERVER_CSRF_TOKEN"), "next-line")
    }

    // MARK: - 额度端点选择（两套后端各自记账）

    /// 守的是「Gemini 永远 100%」那次线上事故：官方客户端在 daily 上消费，另一套后端上
    /// 同名的 Gemini 桶没人动过、恒为满额。旧逻辑 cloudcode-pa 排第一，且首个解析出
    /// Gemini 组的响应就用，于是拿到的是那套满额的桶。
    private let dailyHost = "daily-cloudcode-pa.googleapis.com"
    private let prodHost = "cloudcode-pa.googleapis.com"

    private func geminiSummaryBody(weeklyRemaining: Double, fiveHourRemaining: Double) throws -> String {
        let summary = quotaSummaryJSON(groups: [[
            "displayName": "Gemini Models",
            "buckets": [
                bucket(["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": weeklyRemaining, "resetTime": "2030-01-01T00:00:00Z"]),
                bucket(["bucketId": "gemini-5h", "window": "5h", "remainingFraction": fiveHourRemaining, "resetTime": "2030-01-01T00:00:00Z"])
            ]
        ]])
        return String(data: try JSONSerialization.data(withJSONObject: summary), encoding: .utf8)!
    }

    func testQuotaSummaryDefaultsToTheEndpointTheOfficialClientUses() async throws {
        // 2026-11-26 实测读数：daily 上有真实用量，prod 上恒为 1
        let fixture = GeminiQuotaEndpointFixture([
            dailyHost: try geminiSummaryBody(weeklyRemaining: 0.9689531, fiveHourRemaining: 0.89581203),
            prodHost: try geminiSummaryBody(weeklyRemaining: 1, fiveHourRemaining: 1)
        ])
        let service = quotaService(fixture)

        let (fiveHour, weekly, _) = try await service.fetchAntigravityQuota(accessToken: "fixture-access")

        let hosts = await fixture.requestedHosts
        XCTAssertEqual(hosts, [dailyHost], "默认 daily 优先，解析出 Gemini 组后不再碰另一套")
        XCTAssertEqual(weekly?.remainingPercentage ?? 0, 96.89531, accuracy: 0.001)
        XCTAssertEqual(fiveHour?.remainingPercentage ?? 0, 89.581203, accuracy: 0.001)
    }

    func testQuotaSummaryFollowsObservedOfficialEndpointWhenItIsProd() async throws {
        let fixture = GeminiQuotaEndpointFixture([
            dailyHost: try geminiSummaryBody(weeklyRemaining: 1, fiveHourRemaining: 1),
            prodHost: try geminiSummaryBody(weeklyRemaining: 0.54, fiveHourRemaining: 0.72)
        ])
        let service = quotaService(fixture)
        await service.noteOfficialCloudCodeEndpoint("https://\(prodHost)")

        let (fiveHour, weekly, _) = try await service.fetchAntigravityQuota(accessToken: "fixture-access")

        let hosts = await fixture.requestedHosts
        XCTAssertEqual(hosts, [prodHost], "官方客户端钉在哪套后端，就先问哪套")
        XCTAssertEqual(weekly?.remainingPercentage ?? 0, 54.0, accuracy: 0.001)
        XCTAssertEqual(fiveHour?.remainingPercentage ?? 0, 72.0, accuracy: 0.001)
    }

    func testQuotaSummaryFallsThroughToNextEndpointWithoutGeminiGroup() async throws {
        // daily 只回 Claude/GPT 组（2026-10 的 daily 形状）→ 继续试下一个端点，不能错拿别组的额度
        let claudeOnly = String(data: try JSONSerialization.data(withJSONObject: quotaSummaryJSON(groups: [[
            "displayName": "Claude and GPT models",
            "buckets": [
                bucket(["window": "weekly", "remainingFraction": 1]),
                bucket(["window": "5h", "remainingFraction": 1])
            ]
        ]])), encoding: .utf8)!
        let fixture = GeminiQuotaEndpointFixture([
            dailyHost: claudeOnly,
            prodHost: try geminiSummaryBody(weeklyRemaining: 0.54, fiveHourRemaining: 0.72)
        ])
        let service = quotaService(fixture)

        let (fiveHour, weekly, _) = try await service.fetchAntigravityQuota(accessToken: "fixture-access")

        let hosts = await fixture.requestedHosts
        XCTAssertEqual(hosts, [dailyHost, prodHost])
        XCTAssertEqual(weekly?.remainingPercentage ?? 0, 54.0, accuracy: 0.001)
        XCTAssertEqual(fiveHour?.remainingPercentage ?? 0, 72.0, accuracy: 0.001)
    }

    func testQuotaEndpointOrderOnlyReordersKnownEndpoints() {
        let defaults = ["a-daily", "b-prod", "c-other"]
        XCTAssertEqual(GeminiService.orderedCloudCodeEndpoints(preferred: nil, defaults: defaults), defaults, "没观察到官方端点就用默认顺序")
        XCTAssertEqual(GeminiService.orderedCloudCodeEndpoints(preferred: "b-prod", defaults: defaults), ["b-prod", "a-daily", "c-other"])
        XCTAssertEqual(GeminiService.orderedCloudCodeEndpoints(preferred: "c-other", defaults: defaults), ["c-other", "a-daily", "b-prod"])
        XCTAssertEqual(GeminiService.orderedCloudCodeEndpoints(preferred: "a-daily", defaults: defaults), defaults)
        XCTAssertEqual(GeminiService.orderedCloudCodeEndpoints(preferred: "https://untrusted.example", defaults: defaults), defaults, "陌生主机不跟随：access token 不送去别处")
        XCTAssertEqual(
            GeminiService.orderedCloudCodeEndpoints(preferred: nil),
            ["https://\(dailyHost)", "https://\(prodHost)"],
            "默认顺序跟随官方客户端当前的常量"
        )
    }

    func testOfficialEndpointPreferenceIsTrimmedPersistedAndIgnoresUnknownHosts() async {
        let service = quotaService(GeminiQuotaEndpointFixture([:]))
        var preferred = await service.preferredCloudCodeEndpoint
        XCTAssertNil(preferred, "初始没有偏好")

        await service.noteOfficialCloudCodeEndpoint(" https://\(prodHost) \n")
        preferred = await service.preferredCloudCodeEndpoint
        XCTAssertEqual(preferred, "https://\(prodHost)")
        XCTAssertEqual(UserDefaults.standard.string(forKey: GeminiService.preferredCloudCodeEndpointKey), "https://\(prodHost)", "落盘：IDE 没开的那几轮也跟着走")

        await service.noteOfficialCloudCodeEndpoint("https://untrusted.example")
        preferred = await service.preferredCloudCodeEndpoint
        XCTAssertEqual(preferred, "https://\(prodHost)", "陌生主机不改偏好")
    }
}
