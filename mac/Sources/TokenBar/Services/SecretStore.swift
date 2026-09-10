import Foundation
import Security

/// 高敏凭证的存取抽象。
///
/// 托管**全部**长期凭证：各厂商 API Key、Claude / Gemini 的 OAuth token、控制台 Cookie、
/// 自定义厂商的 Key 与 Cookie，以及阿里云 AccessKey Secret / 控制台 access_token。
/// 键目录见 `AppSecrets`。以前只有阿里云两项进钥匙串，其余明文躺在
/// `~/Library/Preferences/*.plist` 里 —— 任何以该用户身份运行的进程都能读走，
/// 与 PRD 4.2「所有密钥、Cookie、Token 保存在受保护介质」不符。
public protocol SecretStoring {
    /// 写入成功返回 true。钥匙串不可用时返回 false，由调用方决定是否退回明文。
    @discardableResult func set(_ value: String, for key: SecretKey) -> Bool
    func get(_ key: SecretKey) -> String?
    @discardableResult func delete(_ key: SecretKey) -> Bool

    /// 三态读取。**有写权限的调用方（设置页）必须用这个而不是 `get`。**
    ///
    /// 注意这是协议的**要求**而不只是 extension 默认实现：只放 extension 会走静态派发，
    /// `(InMemorySecretStore() as SecretStoring).lookup(...)` 会命中默认实现而不是重写版，
    /// `isUnavailable` 静默失效 —— 正是这个 API 要防的那种错误。
    func lookup(_ key: SecretKey) -> SecretLookup
}

public extension SecretStoring {
    /// 保守默认实现：只能区分「有值」和「没值」，**永远不会凭空报 `.unavailable`**。
    /// 能区分失败原因的实现必须重写。
    func lookup(_ key: SecretKey) -> SecretLookup {
        if let v = get(key), !v.isEmpty { return .found(v) }
        return .absent
    }
}

/// 一次凭证读取的结果。
///
/// 存在的唯一理由是把「确定没有」和「读不到」分开 —— `String?` 表达不了这个差别，
/// 而有写权限的调用方把两者混为一谈就是**数据丢失**：读取超时 → 输入框留空 →
/// 用户点保存 → 走 delete 分支 → 钥匙串里真实存在的 AccessKey Secret 被抹掉。
///
/// 刷新链路容忍「读不到」（降级成未授权，下一轮自愈）；设置页不行，它能写。
public enum SecretLookup: Equatable, Sendable {
    /// 读到了非空值
    case found(String)
    /// 确实没有：`errSecItemNotFound`，或条目存在但内容是空串
    case absent
    /// 这一轮没读到：超时、授权被拒、钥匙串锁定、securityd 异常、数据非 UTF-8……
    /// **不表示条目不存在。** 任何「空就删掉」的推断在这个状态下都必须放弃。
    case unavailable

    public var value: String? {
        if case .found(let v) = self { return v }
        return nil
    }

    /// 结果是否可以拿来做「写还是删」的判断依据
    public var isTrustworthy: Bool { self != .unavailable }
}

/// 保存一个 secret 输入框时该做什么。
///
/// 抽成独立类型只有一个目的：这条分支判断错了就是用户凭证被删，必须能被单测覆盖，
/// 而它原本埋在 `@MainActor` 的 SwiftUI View 私有方法里，测不到。
public enum SecretSaveAction: Equatable, Sendable {
    /// 输入框有内容 —— 写进去
    case write(String)
    /// 输入框为空、且读取结果可信 —— 用户确实想清空
    case delete
    /// 输入框为空、但读取结果不可信 —— 空只代表「没读到」，不代表「要删」。
    /// 保持原样，只提示用户。
    case keepExisting

    /// - Parameter storeReadable: 本次读取是否成功（`.unavailable` 传 false）
    public static func resolve(input: String, storeReadable: Bool) -> SecretSaveAction {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return .write(trimmed) }
        return storeReadable ? .delete : .keepExisting
    }
}

/// 钥匙串条目的 account 名（service 固定为 "TokenBar"）。与 Windows 端的 TargetName 后缀保持同名。
///
/// struct 而非 enum：自定义厂商的键带 UUID，枚举表达不了。内置键以静态成员提供，
/// 调用处写法（`.aliyunAccessKeySecret`）与以前一致。
public struct SecretKey: Hashable, Sendable, CustomStringConvertible {
    public let account: String

    public init(account: String) { self.account = account }

    public var description: String { account }

    public static let aliyunAccessKeySecret = SecretKey(account: "aliyunAccessKeySecret")
    public static let aliyunConsoleAccessToken = SecretKey(account: "aliyunConsoleAccessToken")

    public static let openAIApiKey = SecretKey(account: "openAIApiKey")
    public static let anthropicApiKey = SecretKey(account: "anthropicApiKey")
    public static let claudeToken = SecretKey(account: "claudeToken")
    public static let geminiApiKey = SecretKey(account: "geminiApiKey")
    public static let geminiToken = SecretKey(account: "geminiToken")
    public static let deepseekApiKey = SecretKey(account: "deepseekApiKey")
    public static let volcengineApiKey = SecretKey(account: "volcengineApiKey")
    public static let kimiApiKey = SecretKey(account: "kimiApiKey")
    public static let openRouterApiKey = SecretKey(account: "openRouterApiKey")
    public static let glmApiKey = SecretKey(account: "glmApiKey")
    public static let aliyunApiKey = SecretKey(account: "aliyunApiKey")
    public static let aliyunCookie = SecretKey(account: "aliyunCookie")

    /// 自定义厂商的字段：`custom.<uuid>.apiKey` / `custom.<uuid>.consoleCookie`
    public static func custom(_ id: UUID, _ field: CustomSecretField) -> SecretKey {
        SecretKey(account: "custom.\(id.uuidString).\(field.rawValue)")
    }

    public enum CustomSecretField: String, CaseIterable, Sendable {
        case apiKey
        case consoleCookie
    }
}

/// 基于 macOS 钥匙串（Security.framework）的实现。
///
/// 签名与授权框：`mac/Scripts/build_app.sh` 已改用固定的开发者证书，designated
/// requirement 基于 bundle id + 证书 CN 而非 cdhash，所以重新编译不会再反复弹
/// 「TokenBar 想访问钥匙串」。但授权框只是钥匙串阻塞**最高频的一个**原因 ——
/// 钥匙串锁定、securityd 繁忙、iCloud 钥匙串同步、条目被设成「每次都询问」照样会卡，
/// 所以同步方法**一律不得在主线程调用**（见 `assertOffMain`）。
///
/// 所有方法都是**尽力而为**，失败只返回 false/nil/`.unavailable`，绝不抛错中断额度刷新。
public struct KeychainSecretStore: SecretStoring, Sendable {
    public static let shared = KeychainSecretStore()

    private let service: String

    public init(service: String = "TokenBar") {
        self.service = service
    }

    private func baseQuery(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.account
        ]
    }

    @discardableResult
    public func set(_ value: String, for key: SecretKey) -> Bool {
        Self.assertOffMain(#function)
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

    /// 同步读，保留 `OSStatus` 语义。**必须在后台线程调用。**
    public func lookup(_ key: SecretKey) -> SecretLookup {
        Self.assertOffMain(#function)

        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                // 条目在、内容取不出来。归到「读不到」而不是「没有」——
                // 宁可让调用方保守放弃，也不能诱导它去删一个存在的条目。
                Log.lifecycle.error("keychain lookup 解码失败 account=\(key.account, privacy: .public)")
                return .unavailable
            }
            return value.isEmpty ? .absent : .found(value)
        case errSecItemNotFound:
            return .absent
        default:
            // errSecAuthFailed / errSecInteractionNotAllowed / errSecUserCanceled /
            // errSecNotAvailable / errSecMissingEntitlement …… 一律「读不到」。
            Log.lifecycle.error(
                "keychain lookup 失败 account=\(key.account, privacy: .public) status=\(status, privacy: .public)")
            return .unavailable
        }
    }

    /// 兼容只关心值的调用方。注意它把 `.absent` 和 `.unavailable` 抹平成 nil ——
    /// **有写权限的调用方不要用它**，用 `lookup`。
    public func get(_ key: SecretKey) -> String? { lookup(key).value }

    @discardableResult
    public func delete(_ key: SecretKey) -> Bool {
        Self.assertOffMain(#function)
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - 后台访问

    /// 钥匙串专用串行队列。securityd 是单点，并发打它没有收益；
    /// 这个队列存在的真正理由是把同步的 Security 调用挪出主线程。
    private static let queue = DispatchQueue(label: "com.tokenbar.mac.keychain", qos: .userInitiated)

    /// 主线程护栏。
    ///
    /// Security 的同步 API 走 mach IPC 等 securityd，授权框弹出时更是无限期等待。
    /// 在 MainActor 上调用 = 主线程冻结 = 所有 provider 的刷新任务集体停摆
    /// （commit 514ed13 修的就是这个）。Release 下被编译掉，只在开发期把误用炸出来。
    private static func assertOffMain(_ fn: String) {
        assert(
            !Thread.isMainThread,
            "钥匙串同步调用 \(fn) 不得在主线程执行，请走 lookupAsync / setAsync / deleteAsync / prefetch")
    }

    /// 把一次同步钥匙串调用挪到串行队列上执行，`timeout` 秒后放弃等待并返回 `timedOutValue`。
    ///
    /// 「放弃」只是不等了：Security 的同步 API 不可取消，队列上那次调用照样会跑完
    /// （比如用户 10 秒后才点掉授权框），只是结果被丢弃。写操作因此可能出现
    /// 「报了失败但其实写进去了」的迟到成功 —— 保守方向，调用方重试一次即可自洽。
    ///
    /// self 是 struct：闭包捕获的是值拷贝（只含一个 `let service: String`），
    /// 没有引用环，也不存在跨线程看到中途状态的问题。
    private func runOnKeychainQueue<T: Sendable>(
        timeout: TimeInterval,
        timedOutValue: T,
        _ work: @escaping @Sendable (KeychainSecretStore) -> T
    ) async -> T {
        let store = self
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let gate = ResumeOnce<T>(cont)
            // 超时用可取消的 DispatchWorkItem：正常完成后立即撤掉，不留一个 5~10 秒后才醒的闭包
            let timeoutItem = DispatchWorkItem { gate.resume(timedOutValue) }
            Self.queue.async {
                gate.resume(work(store))
                timeoutItem.cancel()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        }
    }

    /// 后台读单个 secret，带超时。超时/失败返回 `.unavailable`，**绝不伪装成 `.absent`**。
    public func lookupAsync(_ key: SecretKey, timeout: TimeInterval = 5) async -> SecretLookup {
        await runOnKeychainQueue(timeout: timeout, timedOutValue: .unavailable) { $0.lookup(key) }
    }

    /// 后台写，可 await 拿到结果。
    ///
    /// `setInBackground` 是 fire-and-forget，保不住「写失败即中止、绝不降级明文」的语义，
    /// 需要那条语义的调用方必须用这个。
    ///
    /// 超时给 10 秒而不是读的 5 秒：写可能触发钥匙串授权框，5 秒内用户根本来不及点，
    /// 那样会把「用户还没点确认」误报成「写失败」。
    @discardableResult
    public func setAsync(_ value: String, for key: SecretKey, timeout: TimeInterval = 10) async -> Bool {
        await runOnKeychainQueue(timeout: timeout, timedOutValue: false) { $0.set(value, for: key) }
    }

    /// 后台删，可 await 拿到结果。条目本来就不存在（`errSecItemNotFound`）算成功。
    @discardableResult
    public func deleteAsync(_ key: SecretKey, timeout: TimeInterval = 10) async -> Bool {
        await runOnKeychainQueue(timeout: timeout, timedOutValue: false) { $0.delete(key) }
    }

    /// 在后台线程把一批 secret 读出来，装进内存 store 交给同步代码使用。
    ///
    /// 供刷新链路用：这里读不到就返回空值，让调用方走各自的降级路径，绝不为了等凭证
    /// 而卡住刷新。**有写权限的调用方不要用它** —— 它区分不了「没有」和「读不到」，
    /// 拿它的结果去决定删不删就是数据丢失，那种场景用 `lookupAsync`。
    public func prefetch(_ keys: [SecretKey], timeout: TimeInterval = 5) async -> InMemorySecretStore {
        let values: [SecretKey: String] = await runOnKeychainQueue(
            timeout: timeout, timedOutValue: [:]
        ) { store in
            var out: [SecretKey: String] = [:]
            for key in keys {
                if case .found(let value) = store.lookup(key) { out[key] = value }
            }
            return out
        }

        if values.isEmpty && !keys.isEmpty {
            // 可能是「本来就没配」，也可能是超时/授权失败。刷新链路对两者处置相同
            // （降级成未授权），所以这里只记一笔便于倒查，不改变行为。
            Log.lifecycle.notice("keychain prefetch 未取到任何 secret（未配置或读取失败）")
        }

        let store = InMemorySecretStore()
        for (key, value) in values { store.set(value, for: key) }
        return store
    }

    /// 一次后台读取一批 secret，逐键保留三态。超时时**全部**记为 `.unavailable`，
    /// 绝不把「没读到」伪装成「没有」—— 启动时的凭证加载 / 迁移靠它区分
    /// 「钥匙串里确实没有，可以把旧明文迁进去」与「读不到，什么都别动」。
    public func lookupAll(_ keys: [SecretKey], timeout: TimeInterval = 8) async -> [SecretKey: SecretLookup] {
        guard !keys.isEmpty else { return [:] }
        let unavailable = Dictionary(uniqueKeysWithValues: keys.map { ($0, SecretLookup.unavailable) })
        return await runOnKeychainQueue(timeout: timeout, timedOutValue: unavailable) { store in
            var out: [SecretKey: SecretLookup] = [:]
            for key in keys { out[key] = store.lookup(key) }
            return out
        }
    }

    /// 后台写入，调用方不必等待。**只在不关心结果时用**；需要「写失败即中止」
    /// 语义的调用方（例如设置页保存）请用 `setAsync`。
    public func setInBackground(_ value: String, for key: SecretKey) {
        let store = self
        Self.queue.async { _ = store.set(value, for: key) }
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

    /// 重写默认实现：`isUnavailable` 必须映射成 `.unavailable` 而不是 `.absent`，
    /// 否则单测覆盖到的是错误语义（正是这个 API 要防的那个 bug）。
    public func lookup(_ key: SecretKey) -> SecretLookup {
        if isUnavailable { return .unavailable }
        lock.lock(); defer { lock.unlock() }
        if let v = storage[key], !v.isEmpty { return .found(v) }
        return .absent
    }
}
