import XCTest
import SwiftUI
@testable import TokenBar

final class SettingsTests: XCTestCase {
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
        // 新增字段：老配置里没有，必须解成空串而不是抛错
        XCTAssertEqual(decoded.geminiRefreshToken, "")
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
}
