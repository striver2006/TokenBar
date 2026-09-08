import Foundation

/// 浮动框卡片显示顺序的键约定与排序辅助。
/// 内置厂商使用固定小写键，自定义厂商使用 "custom:{UUID}"；
/// AppSettings.providerOrder 为空表示默认顺序，未列入的厂商按默认顺序追加在末尾。
/// 键约定与 Windows 端 Services/ProviderOrdering.cs 保持一致。
public enum ProviderOrdering {
    public static let customKeyPrefix = "custom:"

    /// 内置厂商默认顺序（与浮动框历史渲染顺序一致）。
    public static let defaultOrder: [String] = [
        "openai", "claude", "gemini", "deepseek", "volcengine",
        "kimi", "openrouter", "glm", "aliyun"
    ]

    public static func customKey(_ id: UUID) -> String {
        customKeyPrefix + id.uuidString
    }

    public static func parseCustomKey(_ key: String) -> UUID? {
        guard key.hasPrefix(customKeyPrefix) else { return nil }
        return UUID(uuidString: String(key.dropFirst(customKeyPrefix.count)))
    }

    /// 内置厂商的顺序键。
    public static func key(of type: ProviderType) -> String {
        switch type {
        case .openAI: return "openai"
        case .claudeCode: return "claude"
        case .gemini: return "gemini"
        case .deepseek: return "deepseek"
        case .volcengine: return "volcengine"
        case .kimi: return "kimi"
        case .openRouter: return "openrouter"
        case .glm: return "glm"
        case .aliyunBailian: return "aliyun"
        }
    }

    /// 顺序键反查内置厂商；自定义厂商键（custom:*）返回 nil。
    public static func parseProviderType(_ key: String) -> ProviderType? {
        switch key {
        case "openai": return .openAI
        case "claude": return .claudeCode
        case "gemini": return .gemini
        case "deepseek": return .deepseek
        case "volcengine": return .volcengine
        case "kimi": return .kimi
        case "openrouter": return .openRouter
        case "glm": return .glm
        case "aliyun": return .aliyunBailian
        default: return nil
        }
    }

    /// 返回 key 的排序下标：已列入 order 则为其位置；否则排在所有已列出项之后，
    /// 内置厂商之间保持默认相对顺序、自定义厂商保持原有相对顺序。
    public static func sortIndex(_ key: String, order: [String]) -> Int {
        if let idx = order.firstIndex(of: key) {
            return idx
        }
        let baseIndex = order.count
        if let defaultIdx = defaultOrder.firstIndex(of: key) {
            return baseIndex + defaultIdx
        }
        return baseIndex + defaultOrder.count
    }
}
