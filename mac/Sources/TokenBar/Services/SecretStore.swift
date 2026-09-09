import Foundation
import Security

/// 高敏凭证的存取抽象。
///
/// 目前只托管阿里云 AccessKey Secret 与控制台 access_token —— 其余厂商的 API Key
/// 维持原有的 AppSettings 明文存储不变，避免这次改动扩散成全局重构。
///
/// AccessKey Secret 是**阿里云账号级长期凭证**，落到 `~/Library/Preferences/*.plist`
/// 里等于任何以该用户身份运行的进程都能明文读走，风险等级与普通 API Key 不是一档，
/// 所以单独走系统钥匙串。
public protocol SecretStoring {
    /// 写入成功返回 true。钥匙串不可用时返回 false，由调用方决定是否退回明文。
    @discardableResult func set(_ value: String, for key: SecretKey) -> Bool
    func get(_ key: SecretKey) -> String?
    @discardableResult func delete(_ key: SecretKey) -> Bool
}

/// 钥匙串条目的 account 名。与 Windows 端的 TargetName 后缀保持同名。
public enum SecretKey: String, CaseIterable {
    case aliyunAccessKeySecret
    case aliyunConsoleAccessToken
}

/// 基于 macOS 钥匙串（Security.framework）的实现。
///
/// 注意：`mac/Scripts/build_app.sh` 用的是 ad-hoc 签名（`codesign --sign -`），
/// 每次重新构建 cdhash 都会变，钥匙串 ACL 因此不匹配 —— 开发期首次启动会弹一次
/// 「TokenBar 想访问钥匙串」，点「始终允许」即可；正式分发（稳定签名身份）下不会再弹。
/// 所有方法都是**尽力而为**，失败只返回 false/nil，绝不抛错中断额度刷新。
public struct KeychainSecretStore: SecretStoring {
    public static let shared = KeychainSecretStore()

    private let service: String

    public init(service: String = "TokenBar") {
        self.service = service
    }

    private func baseQuery(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }

    @discardableResult
    public func set(_ value: String, for key: SecretKey) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // 先尝试更新已有条目，不存在再新增 —— 比「先删后加」少一次窗口期
        let updateStatus = SecItemUpdate(
            baseQuery(key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }

        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = baseQuery(key)
        addQuery[kSecValueData as String] = data
        // AfterFirstUnlock：允许后台刷新在用户登录后无人值守地读取
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    public func get(_ key: SecretKey) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    @discardableResult
    public func delete(_ key: SecretKey) -> Bool {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// 内存实现，供单测使用（真实钥匙串会弹授权框，不适合放进自动化测试）。
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private var storage: [SecretKey: String] = [:]
    private let lock = NSLock()
    /// 置 true 可模拟「钥匙串不可用」，用于验证明文回退分支。
    public var isUnavailable = false

    public init() {}

    @discardableResult
    public func set(_ value: String, for key: SecretKey) -> Bool {
        if isUnavailable { return false }
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
        return true
    }

    public func get(_ key: SecretKey) -> String? {
        if isUnavailable { return nil }
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    @discardableResult
    public func delete(_ key: SecretKey) -> Bool {
        if isUnavailable { return false }
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
        return true
    }
}
