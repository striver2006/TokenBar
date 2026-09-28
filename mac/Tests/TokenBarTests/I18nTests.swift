import XCTest
import SwiftUI
@testable import TokenBar

final class I18nTests: XCTestCase {
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

    /// #17：I18nKey 一致性。t() 的 switch 是编译期穷尽的，「漏翻」的真实表现形式只可能是：
    /// 返回空串、返回 key 名本身、或英文分支里残留中文字符。遍历全部 case 逐一断言。
    func testI18nKeyTranslationsAreCompleteInBothLanguages() {
        // CJK 统一表意文字（基本区+扩展A）+ 中文标点 + 全角字符。
        // 注意用 scalar 区间判断而不是 CharacterSet(charactersIn: String)——后者会把
        // 字符串里的 '-' 也当成集合成员。
        func containsCJK(_ s: String) -> Bool {
            s.unicodeScalars.contains { sc in
                (0x4E00...0x9FFF).contains(sc.value) ||
                (0x3400...0x4DBF).contains(sc.value) ||
                (0x3000...0x303F).contains(sc.value) ||
                (0xFF00...0xFFEF).contains(sc.value)
            }
        }
        XCTAssertGreaterThan(I18nKey.allCases.count, 250, "I18nKey case 数量异常，确认 CaseIterable 仍然生效")

        for key in I18nKey.allCases {
            withChineseUI {
                let zh = LocalizationManager.shared.t(key)
                XCTAssertFalse(zh.isEmpty, "zh 翻译为空: \(key.rawValue)")
                XCTAssertNotEqual(zh, key.rawValue, "zh 未翻译（返回了 key 名）: \(key.rawValue)")
            }
            withEnglishUI {
                let en = LocalizationManager.shared.t(key)
                XCTAssertFalse(en.isEmpty, "en 翻译为空: \(key.rawValue)")
                XCTAssertNotEqual(en, key.rawValue, "en 未翻译（返回了 key 名）: \(key.rawValue)")
                XCTAssertFalse(containsCJK(en), "en 翻译残留中文（漏翻）: \(key.rawValue) -> \(en)")
            }
        }
    }
}
