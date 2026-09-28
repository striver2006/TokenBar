import XCTest
import SwiftUI
@testable import TokenBar

// 跨测试文件共享的 helper。原为 TokenBarTests 的私有方法，拆分测试文件后提为
// 文件级自由函数 —— 调用点写法（withChineseUI { ... }）保持不变。

/// 文案断言依赖中文，显式固定语言，避免受系统区域影响
func withChineseUI(_ body: () -> Void) {
    let previous = LocalizationManager.shared.currentLanguage
    LocalizationManager.shared.setLanguage(.zhHans)
    defer { LocalizationManager.shared.setLanguage(previous) }
    body()
}

/// 英文文案断言同样显式固定语言（I18n 一致性测试用）
func withEnglishUI(_ body: () -> Void) {
    let previous = LocalizationManager.shared.currentLanguage
    LocalizationManager.shared.setLanguage(.en)
    defer { LocalizationManager.shared.setLanguage(previous) }
    body()
}
