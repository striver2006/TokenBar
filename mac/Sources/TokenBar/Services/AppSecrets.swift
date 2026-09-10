import Foundation

/// `AppSettings` 里哪些字段是凭证、各自对应哪个钥匙串条目，以及在内存模型与钥匙串
/// 之间搬运它们的纯函数。RefreshManager 启动时用它把钥匙串读进 settings，保存时用它
/// 算出哪些条目要写 / 要删；`AppSettings.encode(to:)` 用它决定哪些字段不落盘。
///
/// 内存中的 `AppSettings` 仍然持有明文（刷新链路与设置页照旧读 `settings.xxxApiKey`），
/// 只是**持久化时不再写进 plist**。
public enum AppSecrets {
    /// 内置厂商字段 ↔ 钥匙串键
    public static let builtinFields: [(key: SecretKey, get: (AppSettings) -> String, set: (inout AppSettings, String) -> Void)] = [
        (.openAIApiKey, { $0.openAIApiKey }, { $0.openAIApiKey = $1 }),
        (.anthropicApiKey, { $0.anthropicApiKey }, { $0.anthropicApiKey = $1 }),
        (.claudeToken, { $0.claudeToken }, { $0.claudeToken = $1 }),
        (.geminiApiKey, { $0.geminiApiKey }, { $0.geminiApiKey = $1 }),
        (.geminiToken, { $0.geminiToken }, { $0.geminiToken = $1 }),
        (.geminiRefreshToken, { $0.geminiRefreshToken }, { $0.geminiRefreshToken = $1 }),
        (.deepseekApiKey, { $0.deepseekApiKey }, { $0.deepseekApiKey = $1 }),
        (.volcengineApiKey, { $0.volcengineApiKey }, { $0.volcengineApiKey = $1 }),
        (.kimiApiKey, { $0.kimiApiKey }, { $0.kimiApiKey = $1 }),
        (.openRouterApiKey, { $0.openRouterApiKey }, { $0.openRouterApiKey = $1 }),
        (.glmApiKey, { $0.glmApiKey }, { $0.glmApiKey = $1 }),
        (.aliyunApiKey, { $0.aliyunApiKey }, { $0.aliyunApiKey = $1 }),
        (.aliyunCookie, { $0.aliyunCookie }, { $0.aliyunCookie = $1 }),
    ]

    /// 这份 settings 涉及的全部钥匙串键（内置 + 每个自定义厂商两个）
    public static func keys(for settings: AppSettings) -> [SecretKey] {
        var keys = builtinFields.map(\.key)
        for config in settings.customProviders {
            for field in SecretKey.CustomSecretField.allCases {
                keys.append(.custom(config.id, field))
            }
        }
        return keys
    }

    /// 取出内存里非空的凭证值
    public static func extract(from settings: AppSettings) -> [SecretKey: String] {
        var out: [SecretKey: String] = [:]
        for field in builtinFields {
            let v = field.get(settings).trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { out[field.key] = v }
        }
        for config in settings.customProviders {
            let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { out[.custom(config.id, .apiKey)] = key }
            let cookie = config.consoleCookie.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cookie.isEmpty { out[.custom(config.id, .consoleCookie)] = cookie }
        }
        return out
    }

    /// 把钥匙串读到的值写回内存模型；字典里没有的键不动（保留旧明文，供迁移或降级）
    public static func apply(_ values: [SecretKey: String], to settings: inout AppSettings) {
        for field in builtinFields {
            if let v = values[field.key] { field.set(&settings, v) }
        }
        for idx in settings.customProviders.indices {
            let id = settings.customProviders[idx].id
            if let v = values[.custom(id, .apiKey)] { settings.customProviders[idx].apiKey = v }
            if let v = values[.custom(id, .consoleCookie)] { settings.customProviders[idx].consoleCookie = v }
        }
    }

    /// 启动加载时对单个键的处置。纯函数，便于单测。
    public enum LoadAction: Equatable, Sendable {
        /// 钥匙串有值：以它为准（覆盖 plist 里可能残留的旧明文）
        case useStored(String)
        /// 钥匙串确定没有、plist 有旧明文：迁进钥匙串
        case migrate(String)
        /// 钥匙串确定没有、plist 也没有：无事可做
        case none
        /// 这一轮读不到：保留内存里的旧明文（可能为空），什么都不写、不删，下次启动再试
        case keepLegacy
    }

    public static func loadAction(lookup: SecretLookup, legacy: String) -> LoadAction {
        let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        switch lookup {
        // 同样 trim：saveAction 的 current 来自 extract（已 trim），
        // 这里不 trim 会让带空白的存量值每次保存都被判成「变更」而重复写入
        case .found(let v): return .useStored(v.trimmingCharacters(in: .whitespacesAndNewlines))
        case .absent: return trimmed.isEmpty ? .none : .migrate(trimmed)
        case .unavailable: return .keepLegacy
        }
    }

    /// 保存时对单个键的处置。`previous` 是上次与钥匙串对齐后的值（nil 表示没有）。
    public enum SaveAction: Equatable, Sendable {
        case write(String)
        case delete
        /// 输入为空但这一轮没读到钥匙串：空只代表「没读到」，不代表「要删」
        case keepExisting
        case unchanged
    }

    public static func saveAction(current: String?, previous: String?, storeReadable: Bool) -> SaveAction {
        let cur = current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prev = previous ?? ""
        if cur == prev { return .unchanged }
        if !cur.isEmpty { return .write(cur) }
        return storeReadable ? .delete : .keepExisting
    }
}
