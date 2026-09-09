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

    // MARK: - 菜单栏额度摘要

    /// 文案断言依赖中文，显式固定语言，避免受系统区域影响
    private func withChineseUI(_ body: () -> Void) {
        let previous = LocalizationManager.shared.currentLanguage
        LocalizationManager.shared.setLanguage(.zhHans)
        defer { LocalizationManager.shared.setLanguage(previous) }
        body()
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

    func testMenuBarStatusPrefersBalanceInAutoMode() {
        withChineseUI {
            var quota = ProviderQuota(provider: .deepseek, isAuthorized: true)
            // DeepSeek 的余额落在次槽位，主槽位是没有参考价值的 TPM 速率窗口
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
            // 余额只显示数字，不带币种符号
            XCTAssertEqual(status?.title, "45.09")
            XCTAssertEqual(status?.tooltip, "DeepSeek · 账户可用余额 ¥45.09")
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
