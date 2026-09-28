import XCTest
import SwiftUI
@testable import TokenBar

final class AliyunServiceTests: XCTestCase {
    func testAliyunBailianParser() throws {
        let jsonStr = """
        {
            "per1WeekPercentage": 0.125,
            "per1WeekResetTime": 1757808000000,
            "per5HourPercentage": 0.05,
            "per5HourResetTime": 1757200000000
        }
        """
        let data = jsonStr.data(using: .utf8)!
        let result = try AliyunBailianService.parseTokenPlanResponse(
            data, accountLabel: "测试账号", channel: .cli)

        guard let longWindow = result.longWindow, let fiveHour = result.fiveHour else {
            XCTFail("longWindow and fiveHour windows must not be nil")
            return
        }

        XCTAssertEqual(longWindow.usedPercentage, 12.5, accuracy: 0.001)
        XCTAssertEqual(longWindow.remainingPercentage, 87.5, accuracy: 0.001)
        XCTAssertEqual(longWindow.title, "7天周期额度")

        XCTAssertEqual(fiveHour.usedPercentage, 5.0, accuracy: 0.001)
        XCTAssertEqual(fiveHour.remainingPercentage, 95.0, accuracy: 0.001)
        XCTAssertEqual(fiveHour.title, "5小时额度")
        XCTAssertEqual(result.account, "测试账号")
    }

    // MARK: - 阿里云 OpenAPI V3 签名（ACS3-HMAC-SHA256）

    /// 黄金向量：与独立的 Python 参考实现交叉验证过，任何一处改动导致签名变化都会在这里失败。
    func testAliyunSignerGoldenVector() {
        let fixedDate = Date(timeIntervalSince1970: 1704067200) // 2024-01-01T00:00:00Z
        let fixedNonce = "00000000-0000-4000-8000-000000000000"

        let headers = AliyunSigner.signedHeaders(
            host: "modelstudio.cn-beijing.aliyuncs.com",
            pathname: "/modelstudio/cli/generateAccessToken",
            action: "GenerateCLIAccessToken",
            version: "2026-02-10",
            accessKeyId: "LTAItestAK",
            accessKeySecret: "testSecret",
            date: fixedDate,
            nonce: fixedNonce
        )

        XCTAssertEqual(headers["x-acs-date"], "2024-01-01T00:00:00Z")
        XCTAssertEqual(headers["content-type"], "application/json")
        XCTAssertEqual(headers["x-acs-content-sha256"], AliyunSigner.emptyBodySHA256)
        XCTAssertNil(headers["x-acs-security-token"])

        let expectedSignedHeaders = "content-type;host;x-acs-action;x-acs-content-sha256;"
            + "x-acs-date;x-acs-signature-nonce;x-acs-version"
        let expectedSignature = "0efe27d7d7a62efb7c47fb992c4ea0955cfc16a1031c1a93c4edb896e859c4c4"
        XCTAssertEqual(
            headers["authorization"],
            "ACS3-HMAC-SHA256 Credential=LTAItestAK,"
                + "SignedHeaders=\(expectedSignedHeaders),Signature=\(expectedSignature)"
        )

        // 中间产物：canonicalRequest 的哈希也钉死，签名失败时能快速定位是哪一段拼错
        let headerMap = AliyunSigner.canonicalHeaderMap(
            host: "modelstudio.cn-beijing.aliyuncs.com",
            action: "GenerateCLIAccessToken",
            version: "2026-02-10",
            date: fixedDate,
            nonce: fixedNonce,
            contentSha256: AliyunSigner.emptyBodySHA256,
            securityToken: nil
        )
        let canonical = AliyunSigner.canonicalRequest(
            method: "POST",
            pathname: "/modelstudio/cli/generateAccessToken",
            queryString: "",
            headerMap: headerMap,
            contentSha256: AliyunSigner.emptyBodySHA256
        )
        XCTAssertEqual(AliyunSigner.signedHeaderList(headerMap), expectedSignedHeaders)
        XCTAssertEqual(
            AliyunSigner.stringToSign(canonical),
            "ACS3-HMAC-SHA256\ne0075df56bc9c8d65e87022d8e6a1dd873f6b2a603636e5ec63bdacbbb630cbd"
        )
        // canonicalHeaders 以换行结尾，因此 signedHeaders 行之前必有一个空行
        XCTAssertTrue(canonical.contains("x-acs-version:2026-02-10\n\ncontent-type;host;"))
    }

    /// STS 临时凭证会多签一个 x-acs-security-token，SignedHeaders 列表随之变化。
    func testAliyunSignerIncludesSecurityToken() {
        let headers = AliyunSigner.signedHeaders(
            host: "business.aliyuncs.com",
            action: "QueryAccountBalance",
            version: "2017-12-14",
            accessKeyId: "LTAItestAK",
            accessKeySecret: "testSecret",
            securityToken: "STS_TOKEN_X",
            date: Date(timeIntervalSince1970: 1704067200),
            nonce: "00000000-0000-4000-8000-000000000000"
        )
        XCTAssertEqual(headers["x-acs-security-token"], "STS_TOKEN_X")
        XCTAssertTrue(headers["authorization"]?.contains("x-acs-security-token;x-acs-signature-nonce") == true)
    }

    func testAliyunSignerEmptyBodyHash() {
        XCTAssertEqual(AliyunSigner.hexSHA256(Data()), AliyunSigner.emptyBodySHA256)
    }

    func testAliyunSignerPercentEncode() {
        // encodeURIComponent 会放过 !'()*~-_. ，阿里云要求再转义 !'()* ，只留 -_.~
        XCTAssertEqual(AliyunSigner.percentEncode("a b!'()*~-_."), "a%20b%21%27%28%29%2A~-_.")
        // 网关 api 名里的斜杠必须转义
        XCTAssertEqual(
            AliyunSigner.percentEncode("zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"),
            "zeldaHttp.apikeyMgr.%2Ftokenplan%2Fpersonal%2Fapi%2Fv2%2Fusage"
        )
        // 非 ASCII 按 UTF-8 逐字节转义，须与 Windows 端手写的 PercentEncode 一致
        XCTAssertEqual(AliyunSigner.percentEncode("中文"), "%E4%B8%AD%E6%96%87")
    }

    func testAliyunSignerCanonicalQueryString() {
        // key 升序、空值参数丢弃
        XCTAssertEqual(AliyunSigner.canonicalQueryString(["b": "2", "a": "1", "c": ""]), "a=1&b=2")
        XCTAssertEqual(AliyunSigner.canonicalQueryString([:]), "")
        XCTAssertEqual(AliyunSigner.canonicalQueryString(["k": "v w"]), "k=v%20w")
    }

    /// x-acs-date 必须是 UTC + 公历 + en_US_POSIX，否则在中文/佛历 locale 下签名会失效。
    func testAliyunSignerISODateIsLocaleIndependent() {
        XCTAssertEqual(
            AliyunSigner.iso8601Seconds(Date(timeIntervalSince1970: 1700000000)),
            "2023-11-14T22:13:20Z"
        )
    }

    // MARK: - 百炼 CLI 配置复用（~/.bailian/config.json）

    func testBailianCLIConfigPrefersActiveProfile() {
        let json: [String: Any] = [
            "active_config": "token-plan",
            "access_token": "TOP_LEVEL_TOKEN",
            "console_region": "cn-beijing",
            "console_site": "domestic",
            "token-plan": [
                "access_token": "PROFILE_TOKEN",
                "console_switch_agent": 11751362
            ]
        ]
        let cfg = BailianCLIConfig.parse(json: json)
        XCTAssertEqual(cfg.accessToken, "PROFILE_TOKEN")
        XCTAssertEqual(cfg.consoleSwitchAgent, 11751362)
        // profile 段没有的字段回落顶层
        XCTAssertEqual(cfg.consoleRegion, "cn-beijing")
        XCTAssertEqual(cfg.consoleSite, "domestic")
    }

    func testBailianCLIConfigFallsBackToTopLevel() {
        // active_config 指向一个并不存在的段 → 整体退回顶层
        let json: [String: Any] = [
            "active_config": "missing-profile",
            "access_token": "TOP_LEVEL_TOKEN",
            "access_key_id": "LTAItest",
            "access_key_secret": "secret"
        ]
        let cfg = BailianCLIConfig.parse(json: json)
        XCTAssertEqual(cfg.accessToken, "TOP_LEVEL_TOKEN")
        XCTAssertEqual(cfg.accessKeyId, "LTAItest")
        XCTAssertEqual(cfg.accessKeySecret, "secret")
        XCTAssertNil(cfg.consoleSwitchAgent)
    }

    func testBailianCLIConfigIgnoresBlankValues() {
        let cfg = BailianCLIConfig.parse(json: ["access_token": "   ", "console_site": ""])
        XCTAssertNil(cfg.accessToken)
        XCTAssertNil(cfg.consoleSite)
    }

    func testBailianCLIConfigSwitchAgentAcceptsStringOrNumber() {
        XCTAssertEqual(BailianCLIConfig.parse(json: ["console_switch_agent": 42]).consoleSwitchAgent, 42)
        XCTAssertEqual(BailianCLIConfig.parse(json: ["console_switch_agent": "42"]).consoleSwitchAgent, 42)
        XCTAssertNil(BailianCLIConfig.parse(json: ["console_switch_agent": "abc"]).consoleSwitchAgent)
    }

    func testBailianCLIConfigDirectoryHonorsEnvOverride() {
        let custom = BailianCLIConfig.configDirectory(environment: ["BAILIAN_CONFIG_DIR": "/tmp/bl-custom"])
        XCTAssertEqual(custom.path, "/tmp/bl-custom")

        let fallback = BailianCLIConfig.configDirectory(environment: [:])
        XCTAssertTrue(fallback.path.hasSuffix("/.bailian"))
    }

    /// loadFromDisk 走真实文件系统，但用临时目录做夹具，不依赖开发机上的真实 CLI 配置。
    func testBailianCLIConfigLoadFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-bl-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let payload = """
        {"active_config":"token-plan","console_region":"cn-beijing",
         "token-plan":{"access_token":"FIXTURE_TOKEN","console_site":"domestic"}}
        """
        try payload.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let cfg = try XCTUnwrap(BailianCLIConfig.loadFromDisk(environment: ["BAILIAN_CONFIG_DIR": dir.path]))
        XCTAssertEqual(cfg.accessToken, "FIXTURE_TOKEN")
        XCTAssertEqual(cfg.consoleSite, "domestic")
        XCTAssertEqual(cfg.consoleRegion, "cn-beijing")

        // 目录里没有 config.json 时返回 nil，而不是抛错
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokenbar-bl-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertNil(BailianCLIConfig.loadFromDisk(environment: ["BAILIAN_CONFIG_DIR": empty.path]))
    }

    // MARK: - 百炼：三种响应形状的解析

    private func parseAliyun(_ json: String, channel: AliyunChannel = .accessKey) throws -> AliyunQuotaResult {
        try AliyunBailianService.parseTokenPlanResponse(
            json.data(using: .utf8)!, accountLabel: "T", channel: channel)
    }

    /// 形状一：`bl --output json` 的扁平输出
    func testAliyunParseCLIShape() throws {
        let r = try parseAliyun("""
        {"per1WeekPercentage":0.125,"per1WeekResetTime":1789122720000,
         "per5HourPercentage":0.5,"per5HourResetTime":1789000000000}
        """, channel: .cli)
        XCTAssertEqual(r.longWindow?.usedPercentage ?? 0, 12.5, accuracy: 0.001)
        XCTAssertEqual(r.fiveHour?.usedPercentage ?? 0, 50.0, accuracy: 0.001)
        XCTAssertEqual(r.channel, .cli)
        XCTAssertNil(r.note)
    }

    /// 形状二：Cookie 网关 /data/api.json
    func testAliyunParseCookieGatewayShape() throws {
        let r = try parseAliyun("""
        {"data":{"data":{"per1WeekPercentage":0.25,"per1WeekResetTime":1789122720000}}}
        """, channel: .cookie)
        XCTAssertEqual(r.longWindow?.usedPercentage ?? 0, 25.0, accuracy: 0.001)
        XCTAssertNil(r.fiveHour)
    }

    /// 形状三：Bearer 网关 /cli/api.json —— 这是实测抓到的真实报文
    func testAliyunParseBearerGatewayShape() throws {
        let r = try parseAliyun("""
        {"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],
          "data":{"msg":"Success.","code":"SUCCESS",
            "data":{"per1WeekResetTime":1789122720000,"per1WeekPercentage":1.0},
            "requestId":"x","success":true}},
          "success":true,"httpStatus":200,"errorCode":"","errorMsg":""},
         "httpStatusCode":"200","successResponse":true}
        """)
        XCTAssertEqual(r.longWindow?.usedPercentage ?? 0, 100.0, accuracy: 0.001)
        XCTAssertEqual(
            r.longWindow?.endTime.timeIntervalSince1970 ?? 0, 1789122720.0, accuracy: 0.001)
        // 5 小时窗口整段缺失，不是错误
        XCTAssertNil(r.fiveHour)
        XCTAssertNil(r.note)
    }

    /// 2026-09 起订阅月限额的实测形状：只返回 per1Month*，旧字段整体消失
    func testAliyunParseMonthlyShape() throws {
        let r = try parseAliyun("""
        {"code":"200","data":{"DataV2":{"ret":["SUCCESS::接口调用成功"],
          "data":{"msg":"Success.","code":"SUCCESS",
            "data":{"per1MonthPercentage":0.056,"per1MonthResetTime":1791129600000},
            "requestId":"x","success":true}},
          "success":true,"httpStatus":200,"errorCode":"","errorMsg":""},
         "httpStatusCode":"200","successResponse":true}
        """)
        XCTAssertEqual(r.longWindow?.title, "月度额度")
        XCTAssertEqual(r.longWindow?.usedPercentage ?? 0, 5.6, accuracy: 0.001)
        XCTAssertEqual(
            r.longWindow?.endTime.timeIntervalSince1970 ?? 0, 1791129600.0, accuracy: 0.001)
        // 订阅月窗口按 30 天派生起点
        XCTAssertEqual(
            r.longWindow.map { $0.endTime.timeIntervalSince($0.startTime) } ?? 0,
            30 * 86400, accuracy: 1)
        XCTAssertNil(r.fiveHour)
        XCTAssertNil(r.note)
    }

    /// 月度与周字段并存（过渡期）时，月度优先占长窗口
    func testAliyunParseMonthlyTakesPrecedenceOverWeekly() throws {
        let r = try parseAliyun("""
        {"per1MonthPercentage":0.4,"per1MonthResetTime":1791129600000,
         "per1WeekPercentage":0.9,"per1WeekResetTime":1789122720000}
        """)
        XCTAssertEqual(r.longWindow?.title, "月度额度")
        XCTAssertEqual(r.longWindow?.usedPercentage ?? 0, 40.0, accuracy: 0.001)
    }

    /// 服务端沿用 per1Week 字段承载月度语义时的兜底：
    /// 重置点距今超过 8 天不可能是 7 天窗口，按订阅月（30 天）展示
    func testAliyunParseFarFutureWeeklyResetRelabeledAsMonthly() throws {
        let farReset = Int((Date().timeIntervalSince1970 + 20 * 86400) * 1000)
        let r = try parseAliyun("""
        {"per1WeekPercentage":0.3,"per1WeekResetTime":\(farReset)}
        """)
        XCTAssertEqual(r.longWindow?.title, "月度额度")
        XCTAssertEqual(r.longWindow?.usedPercentage ?? 0, 30.0, accuracy: 0.001)
        XCTAssertEqual(
            r.longWindow.map { $0.endTime.timeIntervalSince($0.startTime) } ?? 0,
            30 * 86400, accuracy: 1)
    }

    /// 网关将来再套一层壳时，BFS 兜底要能找到
    func testAliyunParseDeepUnknownShellFallback() throws {
        let r = try parseAliyun("""
        {"data":{"DataV2":{"data":{"data":{"wrapper":{"per5HourPercentage":0.5}}}}}}
        """)
        XCTAssertEqual(r.fiveHour?.usedPercentage ?? 0, 50.0, accuracy: 0.001)
    }

    /// 两个窗口都没数据 → 不抛错，给出 note（官方 CLI 语义：该窗口可能不限量）
    func testAliyunParseNoWindowDataIsNotAnError() throws {
        let r = try parseAliyun("""
        {"code":"200","data":{"DataV2":{"data":{"data":{},"success":true}},"success":true,"errorCode":""}}
        """)
        XCTAssertNil(r.longWindow)
        XCTAssertNil(r.fiveHour)
        XCTAssertNotNil(r.note)
    }

    func testAliyunParseNotLoginedEnvelope() {
        XCTAssertThrowsError(try parseAliyun("""
        {"data":{"success":false,"errorCode":"NotLogined","errorMsg":"session expired"}}
        """)) { error in
            XCTAssertEqual(error as? AliyunChannelError, .notLogined)
        }
    }

    func testAliyunParseGatewayErrorEnvelope() {
        XCTAssertThrowsError(try parseAliyun("""
        {"data":{"success":false,"errorCode":"Forbidden.RAM","errorMsg":"no permission"}}
        """)) { error in
            guard case .noPermission = (error as? AliyunChannelError) else {
                return XCTFail("应分类为 noPermission，实际是 \(error)")
            }
        }
    }

    func testAliyunParseCLIErrorEnvelope() {
        XCTAssertThrowsError(try parseAliyun("""
        {"error":{"message":"You are not logged in","hint":"Run bl auth login --console"}}
        """, channel: .cli)) { error in
            XCTAssertEqual(error as? AliyunChannelError, .notLogined)
        }
    }

    /// null / 字符串 / 布尔混进来都不能崩
    func testAliyunParseLooseNumberHandling() throws {
        let r = try parseAliyun("""
        {"per1WeekPercentage":null,"per5HourPercentage":"0.05","per5HourResetTime":true}
        """)
        XCTAssertNil(r.longWindow)
        XCTAssertEqual(r.fiveHour?.usedPercentage ?? 0, 5.0, accuracy: 0.001)
        // resetTime 是布尔 → 当作缺失，回落到「现在 + 5 小时」
        XCTAssertGreaterThan(r.fiveHour?.endTime ?? Date.distantPast, Date())
    }

    func testAliyunParseGarbageInput() {
        XCTAssertThrowsError(try parseAliyun("not json at all")) { error in
            guard case .unexpectedFormat = (error as? AliyunChannelError) else {
                return XCTFail("应分类为 unexpectedFormat，实际是 \(error)")
            }
        }
    }

    // MARK: - 百炼：站点路由与请求体

    func testAliyunGatewayRouting() {
        let cnDomestic = AliyunBailianService.gatewayRoute(region: "cn-beijing", site: "domestic")
        XCTAssertEqual(cnDomestic.host, "bailian-cs.console.aliyun.com")
        XCTAssertEqual(cnDomestic.action, "BroadScopeAspnGateway")

        let cnIntl = AliyunBailianService.gatewayRoute(region: "cn-beijing", site: "international")
        XCTAssertEqual(cnIntl.host, "bailian-cs.console.alibabacloud.com")

        let sgDomestic = AliyunBailianService.gatewayRoute(region: "ap-southeast-1", site: "domestic")
        XCTAssertEqual(sgDomestic.host, "modelstudio-cs.console.aliyun.com")
        XCTAssertEqual(sgDomestic.action, "IntlBroadScopeAspnGateway")

        let sgIntl = AliyunBailianService.gatewayRoute(region: "ap-southeast-1", site: "international")
        XCTAssertEqual(sgIntl.host, "bailian-singapore-cs.alibabacloud.com")

        // 未知 region 回落到 cn-beijing 那一档，但保留 site
        let unknown = AliyunBailianService.gatewayRoute(region: "us-east-1", site: "international")
        XCTAssertEqual(unknown.host, "bailian-cs.console.alibabacloud.com")
    }

    func testAliyunOpenAPIHostRouting() {
        XCTAssertEqual(AliyunBailianService.openAPIHost(region: "cn-beijing"),
                       "modelstudio.cn-beijing.aliyuncs.com")
        XCTAssertEqual(AliyunBailianService.openAPIHost(region: "ap-southeast-1"),
                       "modelstudio.ap-southeast-1.aliyuncs.com")
        XCTAssertEqual(AliyunBailianService.openAPIHost(region: "unknown"),
                       "modelstudio.cn-beijing.aliyuncs.com")
    }

    func testAliyunGatewayParamsJSON() throws {
        let withAgent = AliyunBailianService.gatewayParamsJSON(api: "some.api", switchAgent: 11751362)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: withAgent.data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(parsed["Api"] as? String, "some.api")
        XCTAssertEqual(parsed["V"] as? String, "1.0")
        let cornerstone = try XCTUnwrap(
            (parsed["Data"] as? [String: Any])?["cornerstoneParam"] as? [String: Any])
        XCTAssertEqual(cornerstone["protocol"] as? String, "V2")
        XCTAssertEqual(cornerstone["console"] as? String, "ONE_CONSOLE")
        XCTAssertEqual(cornerstone["productCode"] as? String, "p_efm")
        XCTAssertEqual(cornerstone["switchUserType"] as? Int, 3)
        XCTAssertEqual(cornerstone["consoleSite"] as? String, "BAILIAN_ALIYUN")
        XCTAssertEqual(cornerstone["switchAgent"] as? Int, 11751362)

        // 未设置代操作 UID 时不能带这个字段
        let without = AliyunBailianService.gatewayParamsJSON(api: "some.api", switchAgent: nil)
        XCTAssertFalse(without.contains("switchAgent"))
    }

    /// 表单体必须自己按 RFC3986 编码 —— URLComponents 的 query 允许集不转义 & + =，
    /// params JSON 里一旦出现就会把表单拆坏。
    func testAliyunFormBodyEscapesSpecialCharacters() throws {
        let body = try XCTUnwrap(String(
            data: AliyunBailianService.formBody(["params": "{\"a\":\"b&c=d+e\"}", "region": "cn-beijing"]),
            encoding: .utf8))
        XCTAssertTrue(body.hasPrefix("params="))
        XCTAssertTrue(body.contains("&region=cn-beijing"))
        XCTAssertFalse(body.contains("b&c"))   // & 已被转义成 %26
        XCTAssertTrue(body.contains("%26"))
        XCTAssertTrue(body.contains("%3D"))
        XCTAssertTrue(body.contains("%2B"))
    }

    // MARK: - 百炼：通道编排与凭证装配

    func testAliyunPlannedChannels() {
        var creds = AliyunCredentials(accessKeyId: "id", accessKeySecret: "sec", cookie: "c")
        XCTAssertEqual(AliyunBailianService.plannedChannels(for: creds), [.accessKey, .cli, .cookie])

        // 有 AK/SK 时不单独跑 consoleToken —— accessKey 内部本来就先用缓存令牌
        creds.consoleAccessToken = "tok"
        XCTAssertEqual(AliyunBailianService.plannedChannels(for: creds), [.accessKey, .cli, .cookie])

        creds = AliyunCredentials(consoleAccessToken: "tok")
        XCTAssertEqual(AliyunBailianService.plannedChannels(for: creds), [.consoleToken, .cli])

        creds = AliyunCredentials(cookie: "c")
        XCTAssertEqual(AliyunBailianService.plannedChannels(for: creds), [.cli, .cookie])

        XCTAssertEqual(AliyunBailianService.plannedChannels(for: AliyunCredentials()), [.cli])

        // bl 不存在 / 冷却期内：CLI 通道不参与，不再每轮遍历 PATH 或起子进程
        creds = AliyunCredentials(accessKeyId: "id", accessKeySecret: "sec", cookie: "c")
        XCTAssertEqual(AliyunBailianService.plannedChannels(for: creds, cliAvailable: false), [.accessKey, .cookie])
        XCTAssertEqual(AliyunBailianService.plannedChannels(for: AliyunCredentials(), cliAvailable: false), [])
    }

    func testAliyunResolveCredentialsPrefersUserSettings() {
        var settings = AppSettings()
        settings.aliyunAccessKeyId = "USER_AK"
        settings.aliyunConsoleRegion = "ap-southeast-1"
        settings.aliyunConsoleSite = "international"
        settings.aliyunConsoleSwitchAgent = 999

        let store = InMemorySecretStore()
        store.set("USER_SECRET", for: .aliyunAccessKeySecret)
        store.set("USER_TOKEN", for: .aliyunConsoleAccessToken)

        let cli = BailianCLIConfig(
            accessToken: "CLI_TOKEN", accessKeyId: "CLI_AK", accessKeySecret: "CLI_SECRET",
            consoleSwitchAgent: 111)

        let creds = AliyunBailianService.resolveCredentials(
            settings: settings, secretStore: store, cliConfig: cli)
        XCTAssertEqual(creds.accessKeyId, "USER_AK")
        XCTAssertEqual(creds.accessKeySecret, "USER_SECRET")
        XCTAssertEqual(creds.consoleAccessToken, "USER_TOKEN")
        XCTAssertEqual(creds.consoleRegion, "ap-southeast-1")
        XCTAssertEqual(creds.consoleSite, "international")
        XCTAssertEqual(creds.consoleSwitchAgent, 999)
    }

    /// 用户什么都没配、但本机 bl 登录过 —— 应零配置借用其凭证
    func testAliyunResolveCredentialsReusesCLIConfig() {
        let cli = BailianCLIConfig(
            accessToken: "CLI_TOKEN", accessKeyId: "CLI_AK", accessKeySecret: "CLI_SECRET",
            consoleSwitchAgent: 111)
        let creds = AliyunBailianService.resolveCredentials(
            settings: AppSettings(), secretStore: InMemorySecretStore(), cliConfig: cli)
        XCTAssertEqual(creds.accessKeyId, "CLI_AK")
        XCTAssertEqual(creds.accessKeySecret, "CLI_SECRET")
        XCTAssertEqual(creds.consoleAccessToken, "CLI_TOKEN")
        XCTAssertEqual(creds.consoleSwitchAgent, 111)
        XCTAssertTrue(creds.hasAccessKey)
    }

    /// 关掉复用开关后，绝不碰本机 bl 配置
    func testAliyunResolveCredentialsRespectsReuseToggle() {
        var settings = AppSettings()
        settings.aliyunReuseCLIConfig = false
        let cli = BailianCLIConfig(accessToken: "CLI_TOKEN", accessKeyId: "CLI_AK", accessKeySecret: "S")
        let creds = AliyunBailianService.resolveCredentials(
            settings: settings, secretStore: InMemorySecretStore(), cliConfig: cli)
        XCTAssertFalse(creds.hasAccessKey)
        XCTAssertFalse(creds.hasConsoleToken)
    }

    /// 安全存储不可用时不得回落到明文 —— 宁可如实报错
    func testAliyunResolveCredentialsWithUnavailableSecretStore() {
        var settings = AppSettings()
        settings.aliyunAccessKeyId = "USER_AK"
        settings.aliyunReuseCLIConfig = false

        let store = InMemorySecretStore()
        store.isUnavailable = true
        let creds = AliyunBailianService.resolveCredentials(
            settings: settings, secretStore: store, cliConfig: nil)
        XCTAssertEqual(creds.accessKeyId, "USER_AK")
        XCTAssertEqual(creds.accessKeySecret, "")
        XCTAssertFalse(creds.hasAccessKey)   // 缺 secret 就不算有 AK/SK
    }

    func testAliyunOpenAPIErrorClassification() {
        func classify(_ code: String, status: Int = 400) -> AliyunChannelError {
            AliyunBailianService.classifyOpenAPIError(
                status: status, code: code, message: "m", raw: Data())
        }
        guard case .signatureMismatch = classify("SignatureDoesNotMatch") else {
            return XCTFail("SignatureDoesNotMatch 未正确分类")
        }
        guard case .invalidAccessKey = classify("InvalidAccessKeyId.NotFound") else {
            return XCTFail("InvalidAccessKeyId 未正确分类")
        }
        guard case .noPermission = classify("Forbidden.RAM", status: 403) else {
            return XCTFail("Forbidden 未正确分类")
        }
        guard case .gatewayError = classify("Throttling.User") else {
            return XCTFail("其他错误应落到 gatewayError")
        }
    }

    // MARK: - 百炼：阿里云账户现金余额

    func testAliyunParseAccountBalance() throws {
        let json = """
        {"Code":"200","Message":"Successful!","Success":true,
         "Data":{"AvailableAmount":"1,234.56","AvailableCashAmount":"1,000.00",
                 "CreditAmount":"0","Currency":"CNY","QuotaLimit":"0"}}
        """
        let balance = try AliyunBailianService.parseAccountBalance(json.data(using: .utf8)!)
        // 优先取 AvailableCashAmount，且千分位逗号要被剥掉
        XCTAssertEqual(balance.amount, 1000.0, accuracy: 0.001)
        XCTAssertEqual(balance.currency, "CNY")
    }

    func testAliyunAccountBalanceFallsBackToAvailableAmount() throws {
        let json = """
        {"Success":true,"Data":{"AvailableAmount":"88.5","Currency":"USD"}}
        """
        let balance = try AliyunBailianService.parseAccountBalance(json.data(using: .utf8)!)
        XCTAssertEqual(balance.amount, 88.5, accuracy: 0.001)
        XCTAssertEqual(balance.currency, "USD")
    }

    func testAliyunAccountBalanceHandlesNegativeAndMissingCurrency() throws {
        let json = """
        {"Success":true,"Data":{"AvailableCashAmount":"-12.34"}}
        """
        let balance = try AliyunBailianService.parseAccountBalance(json.data(using: .utf8)!)
        XCTAssertEqual(balance.amount, -12.34, accuracy: 0.001)
        XCTAssertEqual(balance.currency, "CNY")   // 缺 Currency 时的默认值
    }

    func testAliyunAccountBalanceErrorEnvelope() {
        let json = """
        {"Success":false,"Code":"Forbidden.RAM","Message":"no bss permission"}
        """
        XCTAssertThrowsError(
            try AliyunBailianService.parseAccountBalance(json.data(using: .utf8)!)
        ) { error in
            guard case .noPermission = (error as? AliyunChannelError) else {
                return XCTFail("应分类为 noPermission，实际是 \(error)")
            }
        }
    }

    func testAliyunAccountBalanceMissingData() {
        XCTAssertThrowsError(
            try AliyunBailianService.parseAccountBalance("{\"Success\":true}".data(using: .utf8)!)
        ) { error in
            guard case .unexpectedFormat = (error as? AliyunChannelError) else {
                return XCTFail("应分类为 unexpectedFormat，实际是 \(error)")
            }
        }
    }
}
