import XCTest
import SwiftUI
@testable import TokenBar

final class TokenBarTests: XCTestCase {
    func testTokenWindowCalculations() {
        let now = Date()
        let fiveHoursLater = now.addingTimeInterval(5 * 3600)

        let window = TokenWindow(
            title: "5小时额度",
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

    func testExpiredTokenWindow() {
        let past = Date().addingTimeInterval(-3600)
        let expiredTime = Date().addingTimeInterval(-60)

        let window = TokenWindow(
            title: "5小时额度",
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

    func testClaudeLocalConfigParserFromFixture() throws {
        // 固定 fixture，不读开发者机器上的 ~/.claude.json
        let resetsAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(2 * 3600))
        let weeklyReset = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3 * 86400))
        let json: [String: Any] = [
            "oauthAccount": ["emailAddress": "someone@example.com"],
            "cachedUsageUtilization": [
                "utilization": [
                    "five_hour": ["utilization": 37.5, "resets_at": resetsAt],
                    "limits": [["kind": "weekly_all", "percent": 12, "resets_at": weeklyReset]]
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
        XCTAssertEqual(weekly.usedPercentage, 12, accuracy: 0.001)
    }

    func testClaudeLocalConfigParserWithoutCachedUsage() {
        // 登录了但还没有缓存用量：应给出干净的 5 小时窗口，而不是 nil
        let parsed = ClaudeService.shared.parseLocalClaudeJson(["oauthAccount": ["displayName": "Bob"]])
        XCTAssertEqual(parsed.account, "Bob")
        XCTAssertNotNil(parsed.fiveHour)
        XCTAssertTrue(parsed.fiveHour?.isIdle ?? false)
        XCTAssertNil(parsed.weekly)
    }

    func testProviderTypes() {
        XCTAssertEqual(ProviderType.allCases.count, 9)
        withChineseUI {
            XCTAssertEqual(ProviderType.openAI.displayName, "OpenAI")
            XCTAssertEqual(ProviderType.claudeCode.displayName, "Anthropic (Claude)")
            XCTAssertEqual(ProviderType.gemini.displayName, "Google Gemini")
            XCTAssertEqual(ProviderType.deepseek.displayName, "DeepSeek (深度求索)")
            XCTAssertEqual(ProviderType.volcengine.displayName, "火山方舟 (字节跳动)")
            XCTAssertEqual(ProviderType.kimi.displayName, "KIMI (月之暗面)")
            XCTAssertEqual(ProviderType.openRouter.displayName, "OpenRouter")
            XCTAssertEqual(ProviderType.glm.displayName, "GLM (智谱清言)")
            XCTAssertEqual(ProviderType.aliyunBailian.displayName, "阿里云百炼 (Token Plan)")
        }
    }

    func testSettingsTabOrder() {
        let tabs = SettingsTab.allCases
        XCTAssertEqual(tabs.count, 12)
        XCTAssertEqual(tabs[0], .openAI)
        XCTAssertEqual(tabs[1], .anthropic)
        XCTAssertEqual(tabs[2], .gemini)
        XCTAssertEqual(tabs[3], .deepseek)
        XCTAssertEqual(tabs[4], .volcengine)
        XCTAssertEqual(tabs[5], .kimi)
        XCTAssertEqual(tabs[6], .openRouter)
        XCTAssertEqual(tabs[7], .glm)
        XCTAssertEqual(tabs[8], .aliyun)
        XCTAssertEqual(tabs[9], .custom)
        XCTAssertEqual(tabs[10], .displayOrder)
        XCTAssertEqual(tabs[11], .general)
    }

    func testBalanceTokenWindow() {
        let window = TokenWindow.balance(
            title: "账户可用余额",
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

    func testGLMOpenAIEndpoint() {
        let settings = AppSettings.defaultSettings
        XCTAssertEqual(settings.glmEndpoint, "https://open.bigmodel.cn/api/v1")
    }

    func testAliyunTokenPlanConfig() {
        let settings = AppSettings.defaultSettings
        XCTAssertEqual(settings.aliyunEndpoint, "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
        XCTAssertTrue(settings.aliyunEnabled)
    }

    func testAppSettingsBackwardCompatibility() throws {
        // Simulates old settings JSON without new fields
        let oldJson = """
        {
            "refreshIntervalMinutes": 15,
            "enableHover": true,
            "launchAtLogin": false,
            "claudeEnabled": true,
            "geminiEnabled": true,
            "glmEnabled": true,
            "glmApiKey": "165970d15050416cb26195c9c04b5f09.7mtI7cnceBSZuoTx",
            "glmEndpoint": "https://open.bigmodel.cn/api/v1",
            "claudeToken": "sk-ant-test",
            "geminiToken": "ya29.test"
        }
        """

        let data = oldJson.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        // Verifies existing fields are fully preserved
        XCTAssertEqual(decoded.glmApiKey, "165970d15050416cb26195c9c04b5f09.7mtI7cnceBSZuoTx")
        XCTAssertEqual(decoded.glmEndpoint, "https://open.bigmodel.cn/api/v1")
        XCTAssertEqual(decoded.claudeToken, "sk-ant-test")
        XCTAssertEqual(decoded.geminiToken, "ya29.test")
        XCTAssertEqual(decoded.refreshIntervalMinutes, 15)

        // Verifies new fields get safe default values without throwing
        XCTAssertTrue(decoded.aliyunEnabled)
        XCTAssertEqual(decoded.aliyunApiKey, "")
        XCTAssertEqual(decoded.aliyunEndpoint, "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1")
        XCTAssertEqual(decoded.aliyunCookie, "")
        XCTAssertFalse(decoded.openAIEnabled)
        XCTAssertEqual(decoded.openAIApiKey, "")
        XCTAssertEqual(decoded.openAIEndpoint, "https://api.openai.com/v1")
        XCTAssertEqual(decoded.geminiApiKey, "")
        XCTAssertEqual(decoded.geminiEndpoint, "https://generativelanguage.googleapis.com")
        XCTAssertFalse(decoded.deepseekEnabled)
        XCTAssertFalse(decoded.volcengineEnabled)
        XCTAssertFalse(decoded.kimiEnabled)
        XCTAssertFalse(decoded.openRouterEnabled)
        XCTAssertEqual(decoded.openRouterEndpoint, "https://openrouter.ai/api/v1")
        XCTAssertEqual(decoded.deepseekBalanceAlertThreshold, 10)
        XCTAssertEqual(decoded.kimiBalanceAlertThreshold, 10)
        XCTAssertEqual(decoded.openRouterBalanceAlertThreshold, 5)
        XCTAssertTrue(decoded.customProviders.isEmpty)
    }

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

        guard let weekly = result.weekly, let fiveHour = result.fiveHour else {
            XCTFail("weekly and fiveHour windows must not be nil")
            return
        }

        XCTAssertEqual(weekly.usedPercentage, 12.5, accuracy: 0.001)
        XCTAssertEqual(weekly.remainingPercentage, 87.5, accuracy: 0.001)
        XCTAssertEqual(weekly.title, "7天周期额度")

        XCTAssertEqual(fiveHour.usedPercentage, 5.0, accuracy: 0.001)
        XCTAssertEqual(fiveHour.remainingPercentage, 95.0, accuracy: 0.001)
        XCTAssertEqual(fiveHour.title, "5小时额度")
        XCTAssertEqual(result.account, "测试账号")
    }

    func testSettingsTabMapping() {
        XCTAssertEqual(ProviderType.openAI.settingsTab, .openAI)
        XCTAssertEqual(ProviderType.claudeCode.settingsTab, .anthropic)
        XCTAssertEqual(ProviderType.gemini.settingsTab, .gemini)
        XCTAssertEqual(ProviderType.deepseek.settingsTab, .deepseek)
        XCTAssertEqual(ProviderType.volcengine.settingsTab, .volcengine)
        XCTAssertEqual(ProviderType.kimi.settingsTab, .kimi)
        XCTAssertEqual(ProviderType.glm.settingsTab, .glm)
        XCTAssertEqual(ProviderType.aliyunBailian.settingsTab, .aliyun)
    }

    func testOpenAIDurationParsing() {
        let service = OpenAIService.shared
        XCTAssertEqual(service.parseDurationString("20ms"), 0.1, accuracy: 0.01)
        XCTAssertEqual(service.parseDurationString("500ms"), 0.5, accuracy: 0.01)
        XCTAssertEqual(service.parseDurationString("1s"), 1.0, accuracy: 0.01)
        XCTAssertEqual(service.parseDurationString("1m30s"), 90.0, accuracy: 0.01)
        XCTAssertEqual(service.parseDurationString("2h"), 7200.0, accuracy: 0.01)
    }

    func testCustomProviderConfigSerialization() throws {
        let config = CustomProviderConfig(
            name: "DeepSeek",
            isEnabled: true,
            apiKey: "sk-test-123456",
            endpoint: "https://api.deepseek.com/v1",
            apiProtocol: .openAIChat,
            model: "deepseek-chat"
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(CustomProviderConfig.self, from: data)

        XCTAssertEqual(decoded.name, "DeepSeek")
        XCTAssertEqual(decoded.apiProtocol, .openAIChat)
        XCTAssertEqual(decoded.apiKey, "sk-test-123456")
        XCTAssertEqual(decoded.endpoint, "https://api.deepseek.com/v1")
        XCTAssertEqual(decoded.model, "deepseek-chat")
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertNil(decoded.balanceAlertThreshold)
    }

    func testApiProtocolBackwardCompatibility() throws {
        let legacyJson = "\"openAI\"".data(using: .utf8)!
        let proto = try JSONDecoder().decode(ApiProtocol.self, from: legacyJson)
        XCTAssertEqual(proto, .openAIChat)

        let responseJson = "\"openAIResponses\"".data(using: .utf8)!
        let protoResp = try JSONDecoder().decode(ApiProtocol.self, from: responseJson)
        XCTAssertEqual(protoResp, .openAIResponses)
    }

    func testDomesticProviderPresets() {
        let presets = DomesticProviderPreset.allPresets
        XCTAssertGreaterThanOrEqual(presets.count, 6)

        // 1. Verify OpenAI and Anthropic are at the beginning
        XCTAssertEqual(presets[0].name, "OpenAI 兼容代理")
        XCTAssertEqual(presets[0].endpoint, "http://localhost:3000/v1")
        XCTAssertEqual(presets[0].apiProtocol, .openAIChat)

        XCTAssertEqual(presets[1].name, "Anthropic 兼容代理")
        XCTAssertEqual(presets[1].endpoint, "http://localhost:8080/v1")
        XCTAssertEqual(presets[1].apiProtocol, .anthropic)

        // 2. Verify domestic vendors exist
        XCTAssertTrue(presets.contains(where: { $0.name.contains("小米") && $0.endpoint.contains("xiaomimimo.com") }))
        XCTAssertTrue(presets.contains(where: { $0.name.contains("混元") && $0.endpoint.contains("tencentmaas.com") }))
        XCTAssertTrue(presets.contains(where: { $0.name.contains("阶跃星辰") && $0.endpoint.contains("stepfun.com") }))
        XCTAssertTrue(presets.contains(where: { $0.name.contains("硅基流动") }))
        XCTAssertTrue(presets.contains(where: { $0.name.contains("MiniMax") }))

        // 3. Verify vendors with dedicated configuration pages are REMOVED from custom presets
        XCTAssertFalse(presets.contains(where: { $0.name.contains("DeepSeek") }))
        XCTAssertFalse(presets.contains(where: { $0.name.contains("火山方舟") }))
        XCTAssertFalse(presets.contains(where: { $0.name.contains("月之暗面") || $0.name.contains("Kimi") }))
        XCTAssertFalse(presets.contains(where: { $0.name.contains("智谱") }))
    }

    func testGeminiApiKeyConfig() {
        var settings = AppSettings.defaultSettings
        XCTAssertEqual(settings.geminiApiKey, "")
        XCTAssertEqual(settings.geminiEndpoint, "https://generativelanguage.googleapis.com")

        settings.geminiApiKey = "AIzaSyFakeTestKey12345"
        settings.geminiEndpoint = "https://generativelanguage.googleapis.com"
        XCTAssertEqual(settings.geminiApiKey, "AIzaSyFakeTestKey12345")
    }

    func testI18nLocalizationAndSubtitle() {
        // Test App Name
        XCTAssertEqual(I18n(.appName), "TokenBar")

        // Test Chinese
        LocalizationManager.shared.setLanguage(.zhHans)
        XCTAssertEqual(I18n(.subtitle), "模型额度监控")
        XCTAssertEqual(I18n(.refresh), "刷新")
        XCTAssertEqual(I18n(.generalSettings), "通用设置")
        XCTAssertEqual(I18n(.interfaceLanguage), "界面语言")
        XCTAssertEqual(AppLanguage.system.displayName, "跟随系统")
        XCTAssertEqual(ProviderType.deepseek.displayName, "DeepSeek (深度求索)")
        XCTAssertEqual(I18n(.fiveHourWindow), "5小时")

        // Test English
        LocalizationManager.shared.setLanguage(.en)
        XCTAssertEqual(I18n(.subtitle), "Model Quota Monitor")
        XCTAssertEqual(I18n(.refresh), "Refresh")
        XCTAssertEqual(I18n(.generalSettings), "General")
        XCTAssertEqual(I18n(.interfaceLanguage), "Language")
        XCTAssertEqual(AppLanguage.system.displayName, "System")
        XCTAssertEqual(ProviderType.deepseek.displayName, "DeepSeek")
        XCTAssertEqual(I18n(.fiveHourWindow), "5-Hour")

        // Test Settings serialization with appLanguage
        var settings = AppSettings.defaultSettings
        settings.appLanguage = .en
        guard let data = try? JSONEncoder().encode(settings),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            XCTFail("Failed to encode/decode AppSettings with appLanguage")
            return
        }
        XCTAssertEqual(decoded.appLanguage, .en)

        // Reset
        LocalizationManager.shared.setLanguage(.system)
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

    // MARK: - 菜单栏额度摘要

    /// 文案断言依赖中文，显式固定语言，避免受系统区域影响
    private func withChineseUI(_ body: () -> Void) {
        let previous = LocalizationManager.shared.currentLanguage
        LocalizationManager.shared.setLanguage(.zhHans)
        defer { LocalizationManager.shared.setLanguage(previous) }
        body()
    }

    // MARK: - 刷新可靠性（定时刷新停摆修复）

    func testWithTimeoutReturnsTrueWhenOperationFinishesInTime() async {
        let finished = await withTimeout(seconds: 2) { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(finished)
    }

    func testWithTimeoutReturnsFalseWhenOperationOverruns() async {
        let start = Date()
        let finished = await withTimeout(seconds: 0.3) { @MainActor in
            // 故意用一个不响应取消的睡眠，模拟挂死的厂商请求
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        XCTAssertFalse(finished)
        // 关键：必须在预算内返回，而不是等操作自己跑完
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    @MainActor
    func testWithTimeoutFromMainActorContext() async {
        // 复现真实调用场景：从 @MainActor 上下文调用，且 operation 挂在一个
        // 不响应取消的等待上（模拟卡死的网络请求）
        let start = Date()
        let finished = await withTimeout(seconds: 0.5) { @MainActor in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
                // 故意永不 resume
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(finished, "超时必须返回 false")
        XCTAssertLessThan(elapsed, 3.0, "必须在预算内返回，实际 \(elapsed)s")
    }

    func testMenuBarStatusMarksStaleDataWhenLastUpdatedIsOld() {
        withChineseUI {
            let now = Date()
            var quota = ProviderQuota(provider: .aliyunBailian, isAuthorized: true)
            quota.fiveHourWindow = makePercentWindow(title: "5小时额度", used: 38.0)
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
            quota.fiveHourWindow = makePercentWindow(title: "5小时额度", used: 38.0)
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
        quota.fiveHourWindow = makePercentWindow(title: "5小时额度", used: 38.0)
        quota.lastUpdated = nil

        let status = MenuBarStatus.resolve(
            settings: makeSettings(metric: .fiveHour),
            quotas: [.aliyunBailian: quota],
            customQuotas: [:]
        )
        XCTAssertEqual(status?.isStale, false)
    }

    // MARK: - 凭证三态读取与保存决策（防数据丢失）

    /// 「读不到」绝不能被当成「确定没有」—— 混淆这两者就是删掉用户凭证
    func testSecretLookupDistinguishesAbsentFromUnavailable() {
        let store = InMemorySecretStore()
        XCTAssertEqual(store.lookup(.aliyunAccessKeySecret), .absent)

        store.set("SECRET", for: .aliyunAccessKeySecret)
        XCTAssertEqual(store.lookup(.aliyunAccessKeySecret), .found("SECRET"))

        store.isUnavailable = true
        XCTAssertEqual(store.lookup(.aliyunAccessKeySecret), .unavailable)
        XCTAssertNotEqual(store.lookup(.aliyunAccessKeySecret), .absent)

        store.isUnavailable = false
        store.delete(.aliyunAccessKeySecret)
        XCTAssertEqual(store.lookup(.aliyunAccessKeySecret), .absent)
    }

    /// lookup 必须是 protocol 的要求而非纯 extension 默认实现，否则通过
    /// existential 调用会命中默认实现，isUnavailable 静默失效
    func testSecretLookupDispatchesThroughProtocolWitness() {
        let concrete = InMemorySecretStore()
        concrete.isUnavailable = true
        let erased: SecretStoring = concrete
        XCTAssertEqual(erased.lookup(.aliyunAccessKeySecret), .unavailable)
    }

    /// 只实现三个同步方法的 store，其默认 lookup 永远不会凭空报 .unavailable
    func testSecretLookupDefaultImplementationIsConservative() {
        final class MinimalStore: SecretStoring {
            var value: String?
            @discardableResult func set(_ v: String, for key: SecretKey) -> Bool { value = v; return true }
            func get(_ key: SecretKey) -> String? { value }
            @discardableResult func delete(_ key: SecretKey) -> Bool { value = nil; return true }
        }
        let s = MinimalStore()
        XCTAssertEqual(s.lookup(.aliyunAccessKeySecret), .absent)
        s.value = "V"
        XCTAssertEqual(s.lookup(.aliyunAccessKeySecret), .found("V"))
        s.value = ""
        XCTAssertEqual(s.lookup(.aliyunAccessKeySecret), .absent)
    }

    /// 读取失败时空输入框绝不能触发删除。
    /// 这条断言挂了就意味着用户的阿里云 AccessKey Secret 会在一次钥匙串读取超时后被抹掉。
    func testSecretSaveActionNeverDeletesWhenStoreUnreadable() {
        XCTAssertEqual(SecretSaveAction.resolve(input: "", storeReadable: false), .keepExisting)
        XCTAssertEqual(SecretSaveAction.resolve(input: "   ", storeReadable: false), .keepExisting)
        XCTAssertEqual(SecretSaveAction.resolve(input: "\n\t", storeReadable: false), .keepExisting)
    }

    func testSecretSaveActionNormalPaths() {
        XCTAssertEqual(SecretSaveAction.resolve(input: "", storeReadable: true), .delete)
        XCTAssertEqual(SecretSaveAction.resolve(input: "  ", storeReadable: true), .delete)
        XCTAssertEqual(SecretSaveAction.resolve(input: " AK_SECRET ", storeReadable: true),
                       .write("AK_SECRET"))
        // 读不到但用户手动输入了新值 —— 照写，写失败再由调用方中止
        XCTAssertEqual(SecretSaveAction.resolve(input: "NEW", storeReadable: false), .write("NEW"))
    }

    func testSecretLookupAccessors() {
        XCTAssertEqual(SecretLookup.found("X").value, "X")
        XCTAssertNil(SecretLookup.absent.value)
        XCTAssertNil(SecretLookup.unavailable.value)
        XCTAssertTrue(SecretLookup.found("X").isTrustworthy)
        XCTAssertTrue(SecretLookup.absent.isTrustworthy)
        XCTAssertFalse(SecretLookup.unavailable.isTrustworthy)   // 唯一不可信态
    }

    /// 超时分支与完成分支并发抢 resume，只能有一个生效 ——
    /// CheckedContinuation 二次 resume 会直接 crash。
    /// runOnKeychainQueue 与 prefetch 都押在这个类型上。
    func testResumeOnceOnlyFirstWins() async {
        let value: Int = await withCheckedContinuation { cont in
            let gate = ResumeOnce<Int>(cont)
            DispatchQueue.concurrentPerform(iterations: 16) { i in
                gate.resume(i == 0 ? 1 : 2)
            }
        }
        XCTAssertTrue(value == 1 || value == 2)
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

    private func makePercentWindow(title: String, used: Double) -> TokenWindow {
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
            quota.fiveHourWindow = makePercentWindow(title: "5小时额度", used: 38.0)
            quota.weeklyWindow = makePercentWindow(title: "7天周期额度", used: 70.0)

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
            quota.fiveHourWindow = makePercentWindow(title: "5小时额度", used: 38.0)

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
            quota.fiveHourWindow = makePercentWindow(title: "TPM 速率配额", used: 10.0)
            quota.weeklyWindow = TokenWindow.balance(
                title: "账户可用余额",
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
                title: "账户可用余额",
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
            quota.fiveHourWindow = makePercentWindow(title: "5小时额度", used: 38.0)
            quota.weeklyWindow = makePercentWindow(title: "7天周期额度", used: 70.0)
            quota.balanceWindow = TokenWindow.balance(
                title: "账户现金余额",
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

    // MARK: - 弹窗锚点解析

    /// 3440×1440 单屏，菜单栏高 25
    private let anchorScreen = NSRect(x: 0, y: 0, width: 3440, height: 1440)
    private let anchorVisible = NSRect(x: 0, y: 80, width: 3440, height: 1335)
    /// 状态项按钮真实位置（缓存正确时）
    private let anchorButton = NSRect(x: 2815, y: 1415, width: 109, height: 25)

    private func resolveAnchor(
        cached: NSRect?,
        mouse: NSPoint,
        screen: NSRect? = nil,
        visible: NSRect? = nil
    ) -> MenuBarAnchor.Resolution {
        MenuBarAnchor.resolve(
            cachedButtonRect: cached,
            mouseLocation: mouse,
            screenFrame: screen ?? anchorScreen,
            visibleFrame: visible ?? anchorVisible
        )
    }

    func testMenuBarAnchorUsesCachedRectWhenMouseInside() {
        let result = resolveAnchor(cached: anchorButton, mouse: NSPoint(x: 2870, y: 1428))
        XCTAssertEqual(result, MenuBarAnchor.Resolution(rect: anchorButton, isFallback: false))
    }

    func testMenuBarAnchorToleranceAllowsSlightlyOutside() {
        // 越出 1pt（容差 2）仍信任缓存
        let inside = resolveAnchor(cached: anchorButton, mouse: NSPoint(x: 2925, y: 1428))
        XCTAssertFalse(inside.isFallback)
        XCTAssertEqual(inside.rect, anchorButton)

        // 越出 3pt 判定过期
        let outside = resolveAnchor(cached: anchorButton, mouse: NSPoint(x: 2927, y: 1428))
        XCTAssertTrue(outside.isFallback)
    }

    func testMenuBarAnchorFallsBackWhenCachedRectIsStale() {
        // 复现线上故障：缓存停留在 1080p 布局，鼠标实际在 3440 宽屏的图标上
        let stale = NSRect(x: 1815, y: 1055, width: 109, height: 25)
        let result = resolveAnchor(cached: stale, mouse: NSPoint(x: 2870, y: 1428))
        XCTAssertTrue(result.isFallback)
        XCTAssertEqual(result.rect, NSRect(x: 2815.5, y: 1415, width: 109, height: 25))
    }

    func testMenuBarAnchorFallbackClampsToScreenEdges() {
        let stale = NSRect(x: 100, y: 100, width: 109, height: 25)
        let right = resolveAnchor(cached: stale, mouse: NSPoint(x: 3435, y: 1428))
        XCTAssertTrue(right.isFallback)
        XCTAssertEqual(right.rect.maxX, 3440)

        let left = resolveAnchor(cached: stale, mouse: NSPoint(x: 5, y: 1428))
        XCTAssertTrue(left.isFallback)
        XCTAssertEqual(left.rect.minX, 0)
    }

    func testMenuBarAnchorFallbackUsesDefaultHeightWhenMenuBarHidden() {
        let stale = NSRect(x: 100, y: 100, width: 109, height: 25)
        // 菜单栏隐藏：visibleFrame 顶边与屏幕顶边齐平
        let hiddenVisible = NSRect(x: 0, y: 80, width: 3440, height: 1360)
        let result = MenuBarAnchor.resolve(
            cachedButtonRect: stale,
            mouseLocation: NSPoint(x: 2870, y: 1430),
            screenFrame: anchorScreen,
            visibleFrame: hiddenVisible,
            defaultMenuBarHeight: 30
        )
        XCTAssertTrue(result.isFallback)
        XCTAssertEqual(result.rect.height, 30)
        XCTAssertEqual(result.rect.maxY, 1440)
    }

    func testMenuBarAnchorFallbackWithoutCachedRect() {
        let result = resolveAnchor(cached: nil, mouse: NSPoint(x: 2870, y: 1428))
        XCTAssertTrue(result.isFallback)
        XCTAssertEqual(result.rect.width, MenuBarAnchor.defaultButtonWidth)
        XCTAssertEqual(result.rect.midX, 2870)
        XCTAssertEqual(result.rect.maxY, 1440)
    }

    func testMenuBarAnchorKeepsCachedWhenMouseOutsideMenuBarBand() {
        // 从 Dock 重开：鼠标在屏幕中部，无法推导，沿用缓存
        let stale = NSRect(x: 1815, y: 1055, width: 109, height: 25)
        let result = resolveAnchor(cached: stale, mouse: NSPoint(x: 1720, y: 720))
        XCTAssertEqual(result, MenuBarAnchor.Resolution(rect: stale, isFallback: false))
    }

    func testMenuBarAnchorSecondaryScreenOffset() {
        // 副屏位于主屏右侧、抬高 200
        let screen = NSRect(x: 3440, y: 200, width: 1920, height: 1080)
        let visible = NSRect(x: 3440, y: 200, width: 1920, height: 1055)
        let stale = NSRect(x: 100, y: 100, width: 80, height: 25)
        let result = resolveAnchor(cached: stale, mouse: NSPoint(x: 5000, y: 1270), screen: screen, visible: visible)
        XCTAssertTrue(result.isFallback)
        XCTAssertEqual(result.rect, NSRect(x: 4960, y: 1255, width: 80, height: 25))
    }

    func testMenuBarStatusHiddenWhenProviderDisabled() {
        var quota = ProviderQuota(provider: .aliyunBailian, isAuthorized: true)
        quota.fiveHourWindow = makePercentWindow(title: "5小时额度", used: 10.0)

        var settings = makeSettings()
        settings.aliyunEnabled = false
        XCTAssertNil(MenuBarStatus.resolve(settings: settings, quotas: [.aliyunBailian: quota], customQuotas: [:]))
    }

    func testAppSettingsMenuBarFieldsRoundTrip() {
        var settings = AppSettings()
        settings.menuBarQuotaEnabled = true
        settings.menuBarProviderKey = "glm"
        settings.menuBarMetric = .balance

        let data = try! JSONEncoder().encode(settings)
        let decoded = try! JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.menuBarQuotaEnabled)
        XCTAssertEqual(decoded.menuBarProviderKey, "glm")
        XCTAssertEqual(decoded.menuBarMetric, .balance)

        // 旧版本配置（无这三个字段）应能解码并回落到默认值
        let legacy = "{\"refreshIntervalMinutes\":5}".data(using: .utf8)!
        let legacyDecoded = try! JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertFalse(legacyDecoded.menuBarQuotaEnabled)
        XCTAssertEqual(legacyDecoded.menuBarProviderKey, "")
        XCTAssertEqual(legacyDecoded.menuBarMetric, .auto)
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

    // MARK: - AppSettings 的阿里云 AK/SK 字段

    func testAliyunAccessKeyFieldsRoundTrip() throws {
        var settings = AppSettings()
        settings.aliyunAccessKeyId = "LTAItestAK"
        settings.aliyunConsoleRegion = "ap-southeast-1"
        settings.aliyunConsoleSite = "international"
        settings.aliyunConsoleSwitchAgent = 1234567890123456   // 16 位 UID，验证不会溢出
        settings.aliyunReuseCLIConfig = false
        settings.aliyunBalanceAlertThreshold = 20.5

        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.aliyunAccessKeyId, "LTAItestAK")
        XCTAssertEqual(decoded.aliyunConsoleRegion, "ap-southeast-1")
        XCTAssertEqual(decoded.aliyunConsoleSite, "international")
        XCTAssertEqual(decoded.aliyunConsoleSwitchAgent, 1234567890123456)
        XCTAssertFalse(decoded.aliyunReuseCLIConfig)
        XCTAssertEqual(decoded.aliyunBalanceAlertThreshold, 20.5)
    }

    /// 旧版本配置里没有这些字段，必须解码成功并落到默认值。
    func testAliyunAccessKeyFieldsBackwardCompatibility() throws {
        let legacy = "{\"refreshIntervalMinutes\":5,\"aliyunCookie\":\"c\"}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(decoded.aliyunCookie, "c")
        XCTAssertEqual(decoded.aliyunAccessKeyId, "")
        XCTAssertEqual(decoded.aliyunConsoleRegion, "cn-beijing")
        XCTAssertEqual(decoded.aliyunConsoleSite, "domestic")
        XCTAssertEqual(decoded.aliyunConsoleSwitchAgent, 0)
        XCTAssertTrue(decoded.aliyunReuseCLIConfig)
        XCTAssertEqual(decoded.aliyunBalanceAlertThreshold, 10)
    }

    /// AccessKey Secret 与控制台 token 归 SecretStore 管，绝不能出现在 AppSettings 的 JSON 里。
    func testAppSettingsNeverSerializesAliyunSecret() throws {
        var settings = AppSettings()
        settings.aliyunAccessKeyId = "LTAItestAK"
        let json = String(data: try JSONEncoder().encode(settings), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("aliyunAccessKeySecret"))
        XCTAssertFalse(json.contains("aliyunConsoleAccessToken"))
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
        XCTAssertEqual(r.weekly?.usedPercentage ?? 0, 12.5, accuracy: 0.001)
        XCTAssertEqual(r.fiveHour?.usedPercentage ?? 0, 50.0, accuracy: 0.001)
        XCTAssertEqual(r.channel, .cli)
        XCTAssertNil(r.note)
    }

    /// 形状二：Cookie 网关 /data/api.json
    func testAliyunParseCookieGatewayShape() throws {
        let r = try parseAliyun("""
        {"data":{"data":{"per1WeekPercentage":0.25,"per1WeekResetTime":1789122720000}}}
        """, channel: .cookie)
        XCTAssertEqual(r.weekly?.usedPercentage ?? 0, 25.0, accuracy: 0.001)
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
        XCTAssertEqual(r.weekly?.usedPercentage ?? 0, 100.0, accuracy: 0.001)
        XCTAssertEqual(
            r.weekly?.endTime.timeIntervalSince1970 ?? 0, 1789122720.0, accuracy: 0.001)
        // 5 小时窗口整段缺失，不是错误
        XCTAssertNil(r.fiveHour)
        XCTAssertNil(r.note)
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
        XCTAssertNil(r.weekly)
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
        XCTAssertNil(r.weekly)
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

    // MARK: - Gemini 钥匙串探测的缓存/冷却决策

    // 这几条守的是两件事：定时刷新不因授权框停摆（超时后进冷却，不再阻塞后续轮次），
    // 以及用户不被每轮弹一次授权框。子进程本身没法在单测里跑，但决策逻辑可以。

    private func probeDecision(
        cachedAgo: TimeInterval?,
        failedAgo: TimeInterval?,
        ttl: TimeInterval = 300,
        cooldown: TimeInterval = 30
    ) -> KeychainProbeDecision {
        let now = Date()
        return KeychainProbeDecision.resolve(
            now: now,
            cachedAt: cachedAgo.map { now.addingTimeInterval(-$0) } ?? .distantPast,
            hasCache: cachedAgo != nil,
            lastFailure: failedAgo.map { now.addingTimeInterval(-$0) },
            ttl: ttl,
            cooldown: cooldown
        )
    }

    func testKeychainProbeUsesFreshCache() {
        XCTAssertEqual(probeDecision(cachedAgo: 10, failedAgo: nil), .useCache)
    }

    func testKeychainProbeAfterCacheExpired() {
        XCTAssertEqual(probeDecision(cachedAgo: 301, failedAgo: nil), .probe)
    }

    func testKeychainProbeColdStart() {
        XCTAssertEqual(probeDecision(cachedAgo: nil, failedAgo: nil), .probe)
    }

    /// 最关键的一条：上一轮读钥匙串超时（用户没理授权框）后，冷却期内不许再跑子进程。
    /// 这条挂了就意味着刷新间隔设成 1 分钟时，用户每分钟被弹一次授权框。
    func testKeychainProbeCooldownAfterFailureWithoutCache() {
        XCTAssertEqual(probeDecision(cachedAgo: nil, failedAgo: 5), .cooldown)
    }

    func testKeychainProbeResumesAfterCooldownElapsed() {
        XCTAssertEqual(probeDecision(cachedAgo: nil, failedAgo: 31), .probe)
    }

    /// 缓存有效时优先用缓存，不受失败冷却影响 —— 两个条件同时成立时不该退化成放弃。
    func testKeychainProbeCacheWinsOverCooldown() {
        XCTAssertEqual(probeDecision(cachedAgo: 10, failedAgo: 5), .useCache)
    }

    /// 缓存过期 + 仍在冷却：既不读也不弹，调用方拿过期缓存或走文件回退。
    func testKeychainProbeExpiredCacheStillRespectsCooldown() {
        XCTAssertEqual(probeDecision(cachedAgo: 301, failedAgo: 5), .cooldown)
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

    func testStatusWindowIsNotAQuotaWindow() {
        let w = TokenWindow.status(title: "API 连接正常")
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
        // 旧版本持久化的窗口没有 kind 字段，必须仍能解码且不被当成状态型
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"5小时额度","usedPercentage":40,"startTime":0,"endTime":18000,"unit":"%","isIdle":false}
        """
        let w = try JSONDecoder().decode(TokenWindow.self, from: Data(legacy.utf8))
        XCTAssertFalse(w.isStatus)
        XCTAssertEqual(w.remainingPercentage, 60)
    }

    // MARK: - 第 3 批：全部凭证进钥匙串

    func testAppSecretsExtractAndApplyRoundTrip() {
        var settings = AppSettings.defaultSettings
        settings.openAIApiKey = " sk-openai "
        settings.claudeToken = "sk-ant-oat"
        settings.aliyunCookie = "login_aliyunid=1"
        let custom = CustomProviderConfig(name: "MiMo", apiKey: "mimo-key", consoleCookie: "c=1")
        settings.customProviders = [custom]

        let extracted = AppSecrets.extract(from: settings)
        XCTAssertEqual(extracted[.openAIApiKey], "sk-openai")
        XCTAssertEqual(extracted[.claudeToken], "sk-ant-oat")
        XCTAssertEqual(extracted[.aliyunCookie], "login_aliyunid=1")
        XCTAssertEqual(extracted[.custom(custom.id, .apiKey)], "mimo-key")
        XCTAssertEqual(extracted[.custom(custom.id, .consoleCookie)], "c=1")
        XCTAssertNil(extracted[.geminiApiKey], "空字段不应出现在提取结果里")

        var blank = AppSettings.defaultSettings
        blank.customProviders = [CustomProviderConfig(id: custom.id, name: "MiMo")]
        AppSecrets.apply(extracted, to: &blank)
        XCTAssertEqual(blank.openAIApiKey, "sk-openai")
        XCTAssertEqual(blank.claudeToken, "sk-ant-oat")
        XCTAssertEqual(blank.customProviders[0].apiKey, "mimo-key")
        XCTAssertEqual(blank.customProviders[0].consoleCookie, "c=1")

        // 键目录覆盖内置 12 项 + 每个自定义厂商 2 项
        XCTAssertEqual(AppSecrets.keys(for: settings).count, AppSecrets.builtinFields.count + 2)
        XCTAssertEqual(SecretKey.custom(custom.id, .apiKey).account, "custom.\(custom.id.uuidString).apiKey")
    }

    func testAppSettingsEncodingOmitsSecretsOnlyWhenInKeychain() throws {
        var settings = AppSettings.defaultSettings
        settings.openAIApiKey = "sk-openai"
        settings.geminiToken = "ya29.x"
        settings.customProviders = [CustomProviderConfig(name: "X", apiKey: "custom-key", consoleCookie: "ck")]

        // 未迁移：明文照旧落盘（钥匙串可用之前绝不丢凭证）
        settings.secretsInKeychain = false
        let plain = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertTrue(plain.contains("sk-openai"))
        XCTAssertTrue(plain.contains("custom-key"))

        // 已迁移：任何凭证都不得出现在 plist 内容里
        settings.secretsInKeychain = true
        let data = try JSONEncoder().encode(settings)
        let stripped = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(stripped.contains("sk-openai"))
        XCTAssertFalse(stripped.contains("ya29.x"))
        XCTAssertFalse(stripped.contains("custom-key"))
        XCTAssertFalse(stripped.contains("\"ck\""))

        // 非密字段与自定义厂商结构完整保留，且能解码回来
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.customProviders.count, 1)
        XCTAssertEqual(decoded.customProviders[0].name, "X")
        XCTAssertEqual(decoded.customProviders[0].apiKey, "")
        XCTAssertEqual(decoded.openAIApiKey, "")
        XCTAssertFalse(decoded.secretsInKeychain, "标志不参与编解码，启动后由钥匙串加载结果决定")
    }

    func testSecretLoadActionThreeStates() {
        XCTAssertEqual(AppSecrets.loadAction(lookup: .found("K"), legacy: "OLD"), .useStored("K"))
        XCTAssertEqual(AppSecrets.loadAction(lookup: .absent, legacy: " OLD "), .migrate("OLD"))
        XCTAssertEqual(AppSecrets.loadAction(lookup: .absent, legacy: ""), .none)
        // 读不到时绝不迁移、绝不清空：保留旧明文
        XCTAssertEqual(AppSecrets.loadAction(lookup: .unavailable, legacy: "OLD"), .keepLegacy)
        XCTAssertEqual(AppSecrets.loadAction(lookup: .unavailable, legacy: ""), .keepLegacy)
    }

    func testSecretSaveActionDiffAndThreeStates() {
        XCTAssertEqual(AppSecrets.saveAction(current: "A", previous: "A", storeReadable: true), .unchanged)
        XCTAssertEqual(AppSecrets.saveAction(current: nil, previous: nil, storeReadable: true), .unchanged)
        XCTAssertEqual(AppSecrets.saveAction(current: " B ", previous: "A", storeReadable: true), .write("B"))
        XCTAssertEqual(AppSecrets.saveAction(current: "", previous: "A", storeReadable: true), .delete)
        // 输入为空、钥匙串这轮没读到 → 不能删
        XCTAssertEqual(AppSecrets.saveAction(current: "", previous: "A", storeReadable: false), .keepExisting)
        XCTAssertEqual(AppSecrets.saveAction(current: "NEW", previous: nil, storeReadable: false), .write("NEW"))
    }
}
