import XCTest
import SwiftUI
@testable import TokenBar

final class SecretStoreTests: XCTestCase {
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
        // 存量值带空白时要 trim，否则与 saveAction 的已 trim 输入永远不相等，每次保存都重复写
        XCTAssertEqual(AppSecrets.loadAction(lookup: .found(" K "), legacy: ""), .useStored("K"))
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
