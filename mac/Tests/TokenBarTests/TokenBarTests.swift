import XCTest
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
        XCTAssertTrue(window.timeRemainingFormatted.contains("小时") || window.timeRemainingFormatted.contains("分"))
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
        XCTAssertEqual(window.timeRemainingFormatted, "已到重置时间 / 刷新中")
    }

    func testClaudeLocalConfigParser() {
        let local = ClaudeService.shared.readLocalClaudeJson()
        if let local = local {
            print("Detected Claude Account: \(String(describing: local.account))")
            XCTAssertNotNil(local.fiveHour, "Claude 5-hour window should ALWAYS be non-nil")
            if let fiveHour = local.fiveHour {
                XCTAssertFalse(fiveHour.title.isEmpty)
                XCTAssertGreaterThanOrEqual(fiveHour.usedPercentage, 0.0)
                XCTAssertLessThanOrEqual(fiveHour.usedPercentage, 100.0)
                print("Claude 5h:", fiveHour.timeRangeFormatted, fiveHour.timeRemainingFormatted, "Remaining:", fiveHour.remainingPercentage)
            }
            XCTAssertNotNil(local.weekly, "Claude weekly window should be non-nil")
            if let weekly = local.weekly {
                XCTAssertFalse(weekly.title.isEmpty)
                XCTAssertGreaterThanOrEqual(weekly.usedPercentage, 0.0)
                XCTAssertLessThanOrEqual(weekly.usedPercentage, 100.0)
                print("Claude weekly:", weekly.timeRangeFormatted, weekly.timeRemainingFormatted, "Remaining:", weekly.remainingPercentage)
            }
        }
    }

    func testProviderTypes() {
        XCTAssertEqual(ProviderType.allCases.count, 9)
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

    func testSettingsTabOrder() {
        let tabs = SettingsTab.allCases
        XCTAssertEqual(tabs.count, 11)
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
        XCTAssertEqual(tabs[10], .general)
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

    func testBalanceForecastStore() {
        let key = "test-provider-\(UUID().uuidString)"
        defer { BalanceHistoryStore.shared.clear(providerKey: key) }

        // 样本不足：不给出预测
        BalanceHistoryStore.shared.record(providerKey: key, value: 100)
        XCTAssertNil(BalanceHistoryStore.shared.forecastDays(providerKey: key, currentAmount: 100))
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
        let result = try AliyunBailianService.shared.parseTokenPlanJSON(data, accountLabel: "测试账号")

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

    func testGeminiLocalConfig() {
        let local = GeminiService.shared.readLocalGeminiConfig()
        // If antigravity/gemini CLI is present locally on developer machine, test that account and token are detected
        if let localToken = local.token {
            XCTAssertFalse(localToken.isEmpty)
            print("Gemini Local Token detected, length:", localToken.count)
        }
        if let account = local.account {
            XCTAssertFalse(account.isEmpty)
            XCTAssertTrue(account.contains("@"), "Account should be a valid email if present")
            print("Gemini Local Account detected:", account)
        }
    }

    func testGeminiFetchLiveQuota() async throws {
        do {
            let result = try await GeminiService.shared.fetchQuota(token: nil)
            print("=== Live Gemini Fetch Result ===")
            print("Account:", result.account ?? "nil")
            XCTAssertEqual(result.account, "chenzhenbo@gmail.com")
            if let weekly = result.weekly {
                print("Weekly remaining: \(weekly.remainingPercentage)% | Reset: \(weekly.timeRemainingFormatted)")
                XCTAssertGreaterThan(weekly.remainingPercentage, 0)
                XCTAssertLessThanOrEqual(weekly.remainingPercentage, 100)
            } else {
                XCTFail("Weekly quota should not be nil")
            }
            if let fiveHour = result.fiveHour {
                print("5-Hour remaining: \(fiveHour.remainingPercentage)% | Reset: \(fiveHour.timeRemainingFormatted)")
                XCTAssertGreaterThan(fiveHour.remainingPercentage, 0)
                XCTAssertLessThanOrEqual(fiveHour.remainingPercentage, 100)
            } else {
                XCTFail("5-Hour quota should not be nil")
            }
            print("================================")
        } catch {
            XCTFail("Fetch quota threw error: \(error)")
        }
    }
}



