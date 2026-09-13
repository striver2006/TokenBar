import Foundation

/// actor：这里有多个可变缓存字段（token 缓存与过期时间、候选 client 列表、刷新失败冷却），
/// 以前是普通 class 且方法全是 nonisolated async——MainActor 上的 refreshGemini 与设置页
/// 「测试」按钮可以并发进入，`antigravityClientCandidates` 的 removeAll / insert 就是数组的
/// 并发读写。actor 让这些状态天然串行化，公开方法本来就都是 async，调用方无需改动。
public actor GeminiService {
    public static let shared = GeminiService()

    private var googleClientId: String {
        return ProcessInfo.processInfo.environment["GOOGLE_CLIENT_ID"] ?? ""
    }
    private var googleClientSecrets: [String] {
        if let envSecret = ProcessInfo.processInfo.environment["GOOGLE_CLIENT_SECRET"], !envSecret.isEmpty {
            return [envSecret]
        }
        return []
    }

    // Antigravity (Google Code Assist) quota backend endpoints.
    // Antigravity uses daily-cloudcode-pa.googleapis.com for actual user quota tracking;
    // cloudcode-pa.googleapis.com is kept as fallback.
    private static let cloudCodeEndpoints = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
    ]

    // The OAuth client pair used for token refresh is the public "installed app" client that
    // Google ships inside the agy CLI / Antigravity IDE binaries. Nothing is embedded here:
    // candidates are discovered at runtime from the local installation (or the
    // ANTIGRAVITY_CLIENT_ID / ANTIGRAVITY_CLIENT_SECRET environment variables), and the
    // pair that successfully refreshes the stored token is cached for the session.
    private static let clientIdRegex = try! NSRegularExpression(pattern: "[0-9]{6,}-[a-z0-9]{10,}\\.apps\\.googleusercontent\\.com")
    private static let clientSecretRegex = try! NSRegularExpression(pattern: "GOCSPX-[A-Za-z0-9_-]{28}")

    private var antigravityClientCandidates: [(id: String, secret: String)]?

    /// 自有钥匙串里持久化的「上次刷成功的 client 配对」，`id|secret` 格式。
    /// 以前只在内存缓存：每次启动都要重扫几百 MB 的 agy 二进制才能拿回配对；
    /// 持久化后二进制被移动/更新也不影响既有 refresh_token 的刷新。
    private static let clientPairKey = SecretKey(account: "geminiAntigravityClient")

    private func getAntigravityClientCandidates() async -> [(id: String, secret: String)] {
        if let cached = antigravityClientCandidates {
            return cached
        }

        var list: [(id: String, secret: String)] = []
        let env = ProcessInfo.processInfo.environment
        if let envId = env["ANTIGRAVITY_CLIENT_ID"], !envId.isEmpty,
           let envSecret = env["ANTIGRAVITY_CLIENT_SECRET"], !envSecret.isEmpty {
            list.append((envId, envSecret))
            antigravityClientCandidates = list
            return list
        }

        // 持久化的工作配对最优先：它和已存的 refresh_token 是验证过能配对的
        if let persisted = await loadPersistedClient() {
            list.append(persisted)
        }

        // Legacy override: TokenBar's own web-login client (GOOGLE_CLIENT_ID/SECRET).
        if !googleClientId.isEmpty {
            for secret in googleClientSecrets {
                list.append((googleClientId, secret))
            }
        }

        // 扫描几百 MB 的二进制是重 IO，放到独立任务上跑，不占 actor 执行器
        let scanned = await Task.detached(priority: .utility) { Self.scanInstalledBinaries() }.value
        for id in scanned.ids {
            for secret in scanned.secrets {
                guard list.count < 8 else { break }
                list.append((id, secret))
            }
        }

        antigravityClientCandidates = list
        return list
    }

    private func loadPersistedClient() async -> (id: String, secret: String)? {
        guard case .found(let raw) = await KeychainSecretStore.shared.lookupAsync(Self.clientPairKey, timeout: 3) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (id: String(parts[0]), secret: String(parts[1]))
    }

    private func persistWorkingClient(_ client: (id: String, secret: String)) async {
        await KeychainSecretStore.shared.setAsync("\(client.id)|\(client.secret)", for: Self.clientPairKey)
    }

    private static func scanInstalledBinaries() -> (ids: Set<String>, secrets: Set<String>) {
        var ids = Set<String>()
        var secrets = Set<String>()
        let home = FileManager.default.homeDirectoryForCurrentUser
        var targets = [
            home.appendingPathComponent(".gemini/bin/agy").path,
            "/usr/local/bin/agy",
            "/opt/homebrew/bin/agy"
        ]
        let languageServerDir = "/Applications/Antigravity.app/Contents/Resources/bin"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: languageServerDir) {
            for name in names where name.hasPrefix("language_server") {
                targets.append((languageServerDir as NSString).appendingPathComponent(name))
            }
        }
        // Antigravity 更新后的新落点：~/.gemini/antigravity*/（antigravity-cli 等变体）。
        // 只挑可执行文件，最多补 4 个，避免把整个目录树都扫一遍。
        let geminiDir = home.appendingPathComponent(".gemini").path
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: geminiDir) {
            var extra = 0
            for entry in entries where entry.hasPrefix("antigravity") {
                guard extra < 4 else { break }
                let dir = (geminiDir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                      let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
                for file in files {
                    let path = (dir as NSString).appendingPathComponent(file)
                    guard FileManager.default.isExecutableFile(atPath: path) else { continue }
                    targets.append(path)
                    extra += 1
                    if extra >= 4 { break }
                }
            }
        }
        for target in targets {
            if !ids.isEmpty && !secrets.isEmpty { break }
            if FileManager.default.fileExists(atPath: target) {
                scanFileForClientPatterns(target, ids: &ids, secrets: &secrets)
            }
        }
        return (ids, secrets)
    }

    /// Scans a large binary in overlapping chunks for the embedded OAuth client patterns.
    private static func scanFileForClientPatterns(_ path: String, ids: inout Set<String>, secrets: inout Set<String>) {
        let chunkSize = 4 * 1024 * 1024
        let overlap = 1024
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        var carryOver = Data()
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            let data = carryOver + chunk
            if let text = String(data: data, encoding: .isoLatin1) {
                Self.extractMatches(text, regex: Self.clientIdRegex, into: &ids)
                Self.extractMatches(text, regex: Self.clientSecretRegex, into: &secrets)
            }
            carryOver = data.suffix(overlap)
            if chunk.count < chunkSize { break }
        }
    }

    private static func extractMatches(_ text: String, regex: NSRegularExpression, into set: inout Set<String>) {
        let nsText = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            set.insert(nsText.substring(with: match.range))
        }
    }

    // Refreshed access tokens are short-lived (~1h); cache in memory instead of refreshing on every poll.
    private var cachedAccessToken: String?
    private var cachedAccessTokenExpiry = Date.distantPast

    /// 上一次令牌刷新整体失败的时刻。候选逐个试是个昂贵操作（最坏 3 次网络往返），
    /// 凭证真的失效时每轮刷新都重试一遍纯属浪费，冷却期内直接放弃。
    /// 与 AliyunBailianService.TokenCoordinator 的 failureCooldown 是同一套思路。
    private var lastTokenRefreshFailure: Date?
    private static let tokenRefreshCooldown: TimeInterval = 120
    /// 单个候选的请求超时；候选循环的总预算见 refreshGoogleAccessToken
    private static let tokenRequestTimeout: TimeInterval = 8
    private static let tokenRefreshBudget: TimeInterval = 20
    /// 最多试几个 client 候选。曾经是全部 8 个 × 默认 60s 超时 = 单次刷新可以挂 8 分钟，
    /// 把 RefreshManager 的刷新闸门占死，导致定时刷新整体停摆，所以砍到 3。
    /// 但候选是 2 id × 2 secret 的笛卡尔积、Set 遍历序不定，砍到 3 会随机漏掉唯一
    /// 能用的那组配对（2026-09-13 断链演练实测踩中）。现在单请求 8s 超时 + 整循环
    /// 20s 硬预算已经把最坏耗时钉死，限额放宽到覆盖全部组合，由预算兜底。
    private static let tokenClientCandidateLimit = 8

    private struct QuotaAuthError: Error {}

    private var isZh: Bool { LocalizationManager.shared.effectiveLanguage == "zh" }

    // MARK: - 失败阶段

    /// Gemini 凭证链失败的具体阶段。此前只有一个 `keychainDenied` 布尔：只要外来钥匙串
    /// 读不到，**任何**环节的失败（refresh_token 被 Antigravity 轮换、配额接口 401、
    /// 刷新冷却中……）都显示成「钥匙串授权被拒」，把用户反复引向实际上无效的重新授权。
    /// 现在按真实阶段选文案，每个阶段对应一个确实有用的恢复动作。
    public enum CredentialStage: Equatable, Sendable {
        /// 外来条目被 ACL 拒（-25293/-25308），且本地没有任何其它凭证来源——
        /// 唯一活数据源被挡，去设置页授权一次即可永久恢复
        case keychainACL
        /// 哪里都没有凭证（未登录、未安装 Antigravity）
        case noCredentials
        /// refresh_token 存在但 Google 判 invalid_grant——已被 Antigravity 重新登录轮换
        case refreshTokenDead
        /// 刷新刚失败过、处于冷却期（瞬态，下轮自动重试）
        case refreshTokenCooldown
        /// token 端点网络不可达
        case tokenRefreshUnreachable
        /// 扫描出的 client id/secret 全部配不上（Antigravity 组件更新过）；
        /// 重启 TokenBar 触发重扫，或用 Google 账号登录绕开
        case clientMismatch
        /// 换到了 access token，但配额接口 401/403（scope 不足或协议变更）
        case quotaRejected
        /// TokenBar 自己的 Google 登录凭证被判无效（被重新授权吊销）
        case ownLoginRevoked
    }

    /// 带阶段的凭证错误。`errorDescription` 直接产出用户文案。
    public struct CredentialError: LocalizedError, Sendable {
        public let stage: CredentialStage
        public init(_ stage: CredentialStage) { self.stage = stage }

        public var errorDescription: String? {
            let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
            return GeminiService.credentialFailureMessage(stage, isZh: isZh)
        }
    }

    /// 凭证拿不到时的用户文案，按失败阶段分流——每个阶段的恢复动作不同：
    /// - keychainACL：去设置页点「读取本地 Gemini 配置」→ 系统弹窗选「始终允许」。
    ///   在 Antigravity 重新登录**无效**——重建的条目 ACL 依然不含 TokenBar。
    /// - refreshTokenDead：Google 已判 invalid_grant，重试无用；推荐直接用 Google 账号登录。
    /// - 其余阶段同理，见各 case 注释。
    static func credentialFailureMessage(_ stage: CredentialStage, isZh: Bool) -> String {
        switch stage {
        case .keychainACL:
            return isZh
                ? "Gemini 钥匙串授权被拒：请到 设置 → Gemini 点「读取本地 Gemini 配置」，并在系统弹窗中选「始终允许」"
                : "Gemini keychain access denied. Open Settings → Gemini, click \"Read Local Gemini Credentials\" and choose \"Always Allow\" in the system prompt"
        case .noCredentials:
            return isZh
                ? "未找到 Gemini 凭证：请在 设置 → Gemini 用 Google 账号登录，或先在 Antigravity 中登录"
                : "No Gemini credentials found. Sign in with your Google account in Settings → Gemini, or log in via Antigravity first"
        case .refreshTokenDead:
            return isZh
                ? "Gemini 凭证已失效（Antigravity 重新登录会轮换 refresh_token）。推荐在 设置 → Gemini 直接用 Google 账号登录，一次登录不再依赖本地文件"
                : "Gemini credentials are no longer valid (Antigravity re-logins rotate the refresh_token). Sign in with your Google account in Settings → Gemini for a login that no longer depends on local files"
        case .refreshTokenCooldown:
            return isZh
                ? "Gemini 令牌刷新冷却中，稍后自动重试"
                : "Gemini token refresh is cooling down; it will retry automatically"
        case .tokenRefreshUnreachable:
            return isZh
                ? "无法连接 Google 账号服务，请检查网络后稍候重试"
                : "Cannot reach Google's account service; check the network and retry later"
        case .clientMismatch:
            return isZh
                ? "本地 OAuth 客户端配对失效（Antigravity 组件更新过）：请重启 TokenBar 重新扫描，或在 设置 → Gemini 用 Google 账号登录"
                : "Local OAuth client pairing is broken (Antigravity components updated). Restart TokenBar to rescan, or sign in with your Google account in Settings → Gemini"
        case .quotaRejected:
            return isZh
                ? "额度接口拒绝了访问令牌（权限不足或接口协议变更），请尝试重新登录"
                : "The quota API rejected the access token (insufficient scopes or a protocol change). Try signing in again"
        case .ownLoginRevoked:
            return isZh
                ? "TokenBar 的 Google 登录已失效（可能被重新授权吊销），请到 设置 → Gemini 重新登录"
                : "TokenBar's Google sign-in was revoked (possibly by a re-consent). Please sign in again in Settings → Gemini"
        }
    }

    // MARK: - 令牌刷新

    /// 一次 refresh_token 刷新的结构化结果。`String?` 时代调用方只知道「没成」，
    /// 分不清「凭证死了（重试无用）」「网络不通（重试有用）」「冷却中（本轮跳过）」。
    public enum TokenRefreshOutcome: Equatable, Sendable {
        case success(accessToken: String, expiresIn: TimeInterval)
        /// Google 判 invalid_grant：refresh_token 已被轮换/吊销，重试无用
        case invalidGrant
        /// 上一轮刚失败，冷却期内直接放弃
        case cooldown
        /// token 端点网络不可达 / 全部候选超时
        case unreachable
        /// 候选都被判 invalid_client / unauthorized_client——本地扫描出的 id/secret
        /// 配不上（Antigravity 更换二进制后常见），不是网络问题也不是凭证失效
        case clientMismatch
        /// 一个候选都没有（env 未配、本地无 agy/Antigravity、且无持久化配对）
        case noCandidates

        var accessToken: String? {
            if case .success(let token, _) = self { return token }
            return nil
        }
    }

    // MARK: - 本地凭证

    /// `~/.gemini` 下三个回退文件的解析结果
    struct LocalGeminiFiles {
        var jetskiToken: String?
        var jetskiRefreshToken: String?
        var jetskiExpiry: Date?
        var oauthToken: String?
        var oauthRefreshToken: String?
        var account: String?
    }

    /// Antigravity 在 login.keychain 里的凭证条目（go-keyring 写入）。
    /// 这是**唯一持续更新**的数据源：Antigravity 每次刷新 access token 都原地更新它
    /// （`cdat` 不变、`mdat` 每小时变），而 `~/.gemini/jetski-standalone-oauth-token`
    /// 实测会停在几天前的旧 token 上。
    private static let antigravityKeychainService = "gemini"
    private static let antigravityKeychainAccount = "antigravity"

    struct KeychainCredentials: Equatable {
        var token: String?
        var refreshToken: String?
        var expiry: Date?
    }

    /// 以 TokenBar 自身签名身份读 Antigravity 的条目。
    ///
    /// 刷新链路传 `allowInteraction: false`：ACL 里还没有 TokenBar 时立刻拿到
    /// `.unavailable`，**绝不弹框**；用户在设置页点「读取本地 Gemini 配置」时传 true，
    /// 系统弹一次授权框、点「始终允许」后 TokenBar 进入该条目的 ACL，此后永久静默。
    /// 构建已固定开发者证书签名（Scripts/build_app.sh），ACL 按 designated requirement
    /// 匹配，重新编译不会失配。
    ///
    /// `denied` 只在 OSStatus 是 -25293/-25308（真正的 ACL 拒）时为 true。以前任何
    /// `.unavailable`（含超时、securityd 异常）都算「被拒」，把瞬态故障也引向重新授权。
    private func readAntigravityKeychain(allowInteraction: Bool) async -> (credentials: KeychainCredentials?, denied: Bool) {
        let result = await KeychainSecretStore.shared.readForeignDetailedAsync(
            service: Self.antigravityKeychainService,
            account: Self.antigravityKeychainAccount,
            allowInteraction: allowInteraction
        )
        guard case .found(let raw) = result.lookup, let payload = Self.decodeKeychainPayload(raw) else {
            // ACL 拒（典型 status=-25293）的恢复动作是去设置页重新授权，与「凭证真失效、
            // 去 Antigravity 重登」完全不同；其它 `.unavailable` 原因则两个动作都没用，
            // 由后续失败阶段决定文案，不在这里抢答。
            return (nil, result.lookup == .unavailable && result.isACLDenied)
        }
        return (KeychainCredentials(
            token: payload["access_token"] as? String,
            refreshToken: payload["refresh_token"] as? String,
            expiry: Self.parseServerDate(payload["expiry"])
        ), false)
    }

    /// 解 go-keyring 写入的值：JSON 外面再包一层 `go-keyring-base64:` 前缀的 base64。
    /// 返回内层 `token` 字典（含 access_token / refresh_token / expiry）。
    static func decodeKeychainPayload(_ raw: String) -> [String: Any]? {
        let jsonString: String
        if raw.hasPrefix("go-keyring-base64:") {
            let b64 = String(raw.dropFirst("go-keyring-base64:".count))
            guard let dec = Data(base64Encoded: b64), let s = String(data: dec, encoding: .utf8) else {
                Log.provider.error("provider=gemini 钥匙串 base64 解码失败")
                return nil
            }
            jsonString = s
        } else {
            jsonString = raw
        }
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let tokDict = json["token"] as? [String: Any] else {
            Log.provider.error("provider=gemini 钥匙串内容格式不符")
            return nil
        }
        return tokDict
    }

    /// 三层来源的合并规则，抽成纯函数以便单测：
    /// 钥匙串（活数据）> `~/.gemini` 文件（可能陈旧）> 自有条目里的 refresh_token 快照。
    /// 钥匙串有 access_token 时连 expiry 一起用它的；缺的字段逐个从文件补。
    static func mergeCredentials(
        keychain: KeychainCredentials?,
        files: LocalGeminiFiles,
        storedRefreshToken: String?
    ) -> (token: String?, refreshToken: String?, expiry: Date?) {
        var token = keychain?.token
        var refreshToken = keychain?.refreshToken
        var expiry = keychain?.expiry

        if token == nil {
            token = files.jetskiToken
            expiry = files.jetskiExpiry
        }
        if refreshToken == nil { refreshToken = files.jetskiRefreshToken }

        if token == nil { token = files.oauthToken }
        if refreshToken == nil { refreshToken = files.oauthRefreshToken }

        if refreshToken == nil, let stored = storedRefreshToken, !stored.isEmpty { refreshToken = stored }

        return (token, refreshToken, expiry)
    }

    /// Read local Gemini credentials: Antigravity keychain entry + ~/.gemini files.
    ///
    /// - Parameter allowKeychainInteraction: 只有设置页的显式按钮传 true。刷新链路必须是
    ///   false——授权框弹出会让 securityd 那次调用无限期挂起，而且每轮刷新弹一次就是
    ///   这个 Bug 本身。
    /// - Parameter storedRefreshToken: TokenBar 自有钥匙串条目里的 refresh_token 快照，
    ///   前两层都没有时兜底，避免 Antigravity 卸载后额度失联。
    public func readLocalGeminiConfig(
        storedRefreshToken: String? = nil,
        allowKeychainInteraction: Bool = false
    ) async -> (token: String?, refreshToken: String?, account: String?, expiry: Date?, keychainDenied: Bool) {
        let keychain = await readAntigravityKeychain(allowInteraction: allowKeychainInteraction)
        let files = await Self.readLocalGeminiFiles()
        let merged = Self.mergeCredentials(keychain: keychain.credentials, files: files, storedRefreshToken: storedRefreshToken)
        Log.provider.debug("provider=gemini 凭证来源 keychain=\(keychain.credentials != nil, privacy: .public) file=\(files.jetskiToken != nil, privacy: .public)")
        return (merged.token, merged.refreshToken, files.account, merged.expiry, keychain.denied)
    }

    /// 在后台队列读 `~/.gemini` 下的三个文件。都是本地小文件，没有超时看门狗的必要，
    /// 但同样不该占着主线程。
    private static func readLocalGeminiFiles() async -> LocalGeminiFiles {
        await withCheckedContinuation { (continuation: CheckedContinuation<LocalGeminiFiles, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: parseLocalGeminiFiles(homeDir: FileManager.default.homeDirectoryForCurrentUser))
            }
        }
    }

    // MARK: - 自有 Google 登录（loopback OAuth）

    /// TokenBar 自己通过 Google 账号登录换来的 refresh_token，存在**自己的**钥匙串条目里。
    /// 与外来 Antigravity 条目的根本区别：ACL 归 TokenBar 所有，永远不需要系统授权框；
    /// Antigravity 重登轮换 token、条目重建重置 ACL，都影响不到它。
    private static let ownRefreshTokenKey = SecretKey(account: "geminiOwnRefreshToken")

    private var ownRefreshTokenCache: String?
    private var ownRefreshTokenLoaded = false
    /// 登录成功时记下的账号（来自 id_token / userinfo），自有路径显示用
    private var ownAccountHint: String?
    /// 一次登录流程中「授权 URL 用的 client」必须和「换 code 的 client」完全一致，
    /// 否则 code 会被 Google 拒收；pendingLoginClient 在 prepare 与 exchange 之间钉住它。
    private var pendingLoginClient: (id: String, secret: String)?

    /// 读取自有登录凭证。钥匙串暂时读不到时不置 loaded——下一轮刷新自然重试。
    public func loadOwnRefreshToken() async -> String? {
        if ownRefreshTokenLoaded { return ownRefreshTokenCache }
        switch await KeychainSecretStore.shared.lookupAsync(Self.ownRefreshTokenKey) {
        case .found(let value):
            ownRefreshTokenCache = value
            ownRefreshTokenLoaded = true
            return value
        case .absent:
            ownRefreshTokenCache = nil
            ownRefreshTokenLoaded = true
            return nil
        case .unavailable:
            return nil
        }
    }

    /// 自有登录是否处于有效状态（设置页展示 / 失效后自愈用）
    public func hasOwnLogin() async -> Bool {
        guard let token = await loadOwnRefreshToken() else { return false }
        return !token.isEmpty
    }

    private func clearOwnRefreshToken() {
        ownRefreshTokenCache = nil
        ownRefreshTokenLoaded = true
        Task { await KeychainSecretStore.shared.deleteAsync(Self.ownRefreshTokenKey) }
    }

    /// 「退出登录」：清自有凭证与账号提示，回到本地凭证链路。
    public func clearOwnLogin() async {
        clearOwnRefreshToken()
        ownAccountHint = nil
        await KeychainSecretStore.shared.deleteAsync(Self.ownRefreshTokenKey)
    }

    /// 一次 Google 登录的全部前置信息：授权页 URL + loopback 端口。
    public struct GoogleLoginPlan: Sendable {
        public let authorizeURL: URL
        public let redirectPort: Int
    }

    /// 与 Antigravity 凭证完全相同的 scope 集合（从 agy 刷出的 token 实测得到），
    /// 保证自有登录换出的 access token 对配额接口有同等权限。
    public static let loginScopes = [
        "openid",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/cclog",
        "https://www.googleapis.com/auth/aicode",
        "https://www.googleapis.com/auth/experimentsandconfigs",
    ]

    /// 构造授权页 URL（loopback 重定向，随机端口）。本地找不到任何 OAuth client 时返回 nil。
    public func prepareGoogleLogin() async -> GoogleLoginPlan? {
        guard let client = await getAntigravityClientCandidates().first else { return nil }
        pendingLoginClient = client
        let port = Int.random(in: 21000...60000)

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: "http://localhost:\(port)"),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.loginScopes.joined(separator: " ")),
            // access_type=offline + prompt=consent 确保 Google 一定下发 refresh_token
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = comps.url else {
            pendingLoginClient = nil
            return nil
        }
        return GoogleLoginPlan(authorizeURL: url, redirectPort: port)
    }

    /// 用授权码换 token 并落库。`redirectPort` 必须与 `prepareGoogleLogin` 返回的一致。
    public func exchangeGoogleLoginCode(code: String, redirectPort: Int) async throws -> (account: String, refreshToken: String) {
        guard let tokenUrl = URL(string: "https://oauth2.googleapis.com/token") else {
            throw CredentialError(.tokenRefreshUnreachable)
        }
        let client: (id: String, secret: String)?
        if let pending = pendingLoginClient {
            client = pending
        } else {
            client = await getAntigravityClientCandidates().first
        }
        guard let client else { throw CredentialError(.noCredentials) }

        var request = URLRequest(url: tokenUrl)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = [
            "client_id": client.id,
            "client_secret": client.secret,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": "http://localhost:\(redirectPort)"
        ]
        let bodyString = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await HTTPClient.data(for: request)
        } catch {
            throw CredentialError(.tokenRefreshUnreachable)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            Log.provider.error("provider=gemini Google 登录 code 交换失败: \(detail, privacy: .public)")
            throw CredentialError(.ownLoginRevoked)
        }

        pendingLoginClient = nil
        await persistWorkingClient(client)
        ownRefreshTokenCache = refreshToken
        ownRefreshTokenLoaded = true
        let accessToken = json["access_token"] as? String
        if let accessToken {
            cachedAccessToken = accessToken
            let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
            cachedAccessTokenExpiry = Date().addingTimeInterval(max(60, expiresIn - 120))
        }
        if let idEmail = Self.emailFromIDToken(json["id_token"] as? String) {
            ownAccountHint = idEmail
        } else if let accessToken {
            ownAccountHint = await fetchUserInfo(token: accessToken)
        }
        let account = ownAccountHint ?? "Google Account"
        return (account, refreshToken)
    }

    /// 从 Google id_token（JWT）里解出 email。不做签名校验：token 是刚从 Google 的
    /// TLS 响应体里拿到的，中间没有不可信环节；这里只是展示账号，不是鉴权依据。
    static func emailFromIDToken(_ idToken: String?) -> String? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    /// 纯解析：给定 home 目录读三个文件。抽出来是为了让单测用临时目录喂 fixture，
    /// 而不是依赖开发者机器上真实的 ~/.gemini。
    static func parseLocalGeminiFiles(homeDir: URL) -> LocalGeminiFiles {
                let jetskiTokenPath = homeDir.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
                let oauthCredsPath = homeDir.appendingPathComponent(".gemini/oauth_creds.json")
                let accountsPath = homeDir.appendingPathComponent(".gemini/google_accounts.json")

                var result = LocalGeminiFiles()

                // 1. jetski-standalone-oauth-token
                if let data = try? Data(contentsOf: jetskiTokenPath),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tokDict = json["token"] as? [String: Any] {
                    result.jetskiToken = tokDict["access_token"] as? String
                    result.jetskiRefreshToken = tokDict["refresh_token"] as? String
                    result.jetskiExpiry = Self.parseServerDate(tokDict["expiry"])
                }

                // 2. oauth_creds.json
                if let data = try? Data(contentsOf: oauthCredsPath),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    result.oauthToken = json["access_token"] as? String
                    result.oauthRefreshToken = json["refresh_token"] as? String
                }

                // 3. Read Google account email
                if let data = try? Data(contentsOf: accountsPath),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let active = json["active"] as? String, !active.isEmpty {
                        result.account = active
                    } else if let old = json["old"] as? [String], let first = old.first, !first.isEmpty {
                        result.account = first
                    }
                }

                return result
    }

    /// Parses ISO-8601 strings (with or without fractional seconds) or epoch seconds into a Date.
    private static func parseServerDate(_ any: Any?) -> Date? {
        if let s = any as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fractional.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            return plain.date(from: s)
        }
        if let n = any as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue)
        }
        return nil
    }

    /// Refresh Google OAuth access token using refresh_token.
    /// Tries every discovered OAuth client pair until one is accepted (the binaries contain
    /// more than one client); on success the pair is moved to the front, persisted to the
    /// keychain, and the token is cached in memory for its lifetime (~1h).
    public func refreshGoogleAccessToken(refreshToken: String) async -> TokenRefreshOutcome {
        guard let tokenUrl = URL(string: "https://oauth2.googleapis.com/token") else { return .unreachable }

        if let last = lastTokenRefreshFailure,
           Date().timeIntervalSince(last) < Self.tokenRefreshCooldown {
            Log.provider.info("gemini token 刷新处于冷却期，跳过本轮")
            return .cooldown
        }

        let candidates = await getAntigravityClientCandidates().prefix(Self.tokenClientCandidateLimit)
        if candidates.isEmpty { return .noCandidates }

        // 整个候选循环的硬预算：任何一个候选慢下来都不能让整轮刷新失控。
        let deadline = Date().addingTimeInterval(Self.tokenRefreshBudget)
        var sawInvalidGrant = false
        var sawClientRejection = false
        var sawTransportError = false

        for client in candidates {
            if Date() >= deadline {
                Log.provider.error("gemini token 刷新超出 \(Self.tokenRefreshBudget, format: .fixed(precision: 0))s 预算，放弃剩余候选")
                break
            }

            var request = URLRequest(url: tokenUrl)
            request.httpMethod = "POST"
            request.timeoutInterval = Self.tokenRequestTimeout
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let params = [
                "client_id": client.id,
                "client_secret": client.secret,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ]

            let bodyString = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }.joined(separator: "&")
            request.httpBody = bodyString.data(using: .utf8)

            do {
                let (data, response) = try await HTTPClient.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                if http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let newAccessToken = json["access_token"] as? String {
                    let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
                    // Cache the working pair first so later refreshes skip the trial-and-error.
                    antigravityClientCandidates?.removeAll { $0.id == client.id && $0.secret == client.secret }
                    antigravityClientCandidates?.insert(client, at: 0)
                    await persistWorkingClient(client)
                    cachedAccessToken = newAccessToken
                    cachedAccessTokenExpiry = Date().addingTimeInterval(max(60, expiresIn - 120))
                    lastTokenRefreshFailure = nil
                    // 不再写回 ~/.gemini/jetski-standalone-oauth-token：那是 Antigravity 的文件，
                    // 非原子写会在它并发写入时留下截断 JSON、还会把 0600 改成 umask 默认权限
                    // （与 ARCH 5.1 对 ~/.bailian/config.json「只读不写回」是同一条规矩）。
                    // 内存缓存 cachedAccessToken 已经覆盖了「下次刷新不用重签」的需求。
                    return .success(accessToken: newAccessToken, expiresIn: expiresIn)
                }
                // 非 200：解析错误体区分「凭证死了」「配对错了」「网络不通」。
                // invalid_grant 是 refresh_token 级的判决（已被轮换/吊销），换候选也救不回来，
                // 但仍让循环跑完——万一有别的 client 真的认它；invalid_client /
                // unauthorized_client 只是当前配对不对，直接试下一个。
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let code = json["error"] as? String {
                    if code == "invalid_grant" { sawInvalidGrant = true }
                    if code == "invalid_client" || code == "unauthorized_client" { sawClientRejection = true }
                    Log.provider.error("gemini token 刷新候选被拒 code=\(code, privacy: .public) status=\(http.statusCode, privacy: .public)")
                }
            } catch {
                sawTransportError = true
                continue
            }
        }
        lastTokenRefreshFailure = Date()
        if sawInvalidGrant {
            Log.provider.error("gemini token 刷新失败：refresh_token 已被判 invalid_grant（被轮换或吊销）")
            return .invalidGrant
        }
        if sawClientRejection && !sawTransportError {
            Log.provider.error("gemini token 刷新失败：全部候选的 id/secret 配不上（Antigravity 组件更新过）")
            return .clientMismatch
        }
        Log.provider.error("gemini token 刷新失败：所有候选都没能换到 access token")
        return .unreachable
    }

    /// Fetch Gemini usage quota and window limits from the Antigravity (Google Code Assist)
    /// quota API — the same source the Antigravity IDE's usage panel displays.
    /// 返回值里带上本轮用到的 refresh_token，调用方据此把它落进自有钥匙串条目做快照。
    ///
    /// 凭证优先级：**TokenBar 自己的 Google 登录**（`geminiOwnRefreshToken`）> 外来
    /// Antigravity 钥匙串条目 > `~/.gemini` 文件 > 快照。自有登录走通时完全不碰外来
    /// 钥匙串——ACL 授权丢失、Antigravity 重登轮换 token 都与它无关，这是「一劳永逸」
    /// 的那条路；自有凭证被判 invalid_grant 时清掉并当场落到旧链路，额度尽量不失联。
    public func fetchQuota(token: String?, storedRefreshToken: String? = nil) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?, refreshToken: String?) {
        if let own = await loadOwnRefreshToken(), !own.isEmpty {
            do {
                return try await fetchQuotaWithOwnCredential(own)
            } catch let error as CredentialError where error.stage == .ownLoginRevoked {
                clearOwnRefreshToken()
                // 落到下面的本地链路；若本地链路也失败，最终错误按它的阶段报
            }
        }

        let local = await readLocalGeminiConfig(storedRefreshToken: storedRefreshToken)
        let refreshToken = local.refreshToken
        var detectedAccount = local.account

        // Resolve an access token: cached refresh result > valid local token (keychain/jetski) > explicit setting (if valid) > refreshed.
        let accessToken: String
        if let cached = cachedAccessToken, Date() < cachedAccessTokenExpiry {
            accessToken = cached
        } else if let localToken = local.token, local.expiry != nil && local.expiry! > Date().addingTimeInterval(120) {
            accessToken = localToken
        } else if let explicitToken = token, !explicitToken.isEmpty, local.expiry == nil || local.expiry! > Date().addingTimeInterval(120) {
            accessToken = explicitToken
        } else if let refreshToken {
            switch await refreshGoogleAccessToken(refreshToken: refreshToken) {
            case .success(let refreshed, _): accessToken = refreshed
            case .invalidGrant: throw CredentialError(.refreshTokenDead)
            case .cooldown: throw CredentialError(.refreshTokenCooldown)
            case .unreachable: throw CredentialError(.tokenRefreshUnreachable)
            case .clientMismatch: throw CredentialError(.clientMismatch)
            case .noCandidates: throw CredentialError(.noCredentials)
            }
        } else if let stored = (token?.isEmpty == false ? token : local.token) {
            // No expiry info and no refresh token: try it, auth errors surface a clear message below.
            accessToken = stored
        } else {
            // 什么凭证都没有。此时若外来钥匙串被 ACL 拒，说明唯一活数据源被挡——
            // 指引去设置页授权；否则就是真的没配置过。
            throw CredentialError(local.keychainDenied ? .keychainACL : .noCredentials)
        }

        let (fiveHour, weekly) = try await legacyQuotaWithAuthRetry(accessToken, refreshToken: refreshToken)

        if detectedAccount == nil {
            detectedAccount = await fetchUserInfo(token: accessToken)
        }

        return (fiveHour, weekly, detectedAccount ?? (isZh ? "Google 账号" : "Google Account"), refreshToken)
    }

    /// 自有登录凭证的完整路径：刷新 → 配额 → 账号，任何一环失败都按阶段抛 `CredentialError`。
    private func fetchQuotaWithOwnCredential(_ refreshToken: String) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?, refreshToken: String?) {
        let accessToken: String
        if let cached = cachedAccessToken, Date() < cachedAccessTokenExpiry {
            accessToken = cached
        } else {
            switch await refreshGoogleAccessToken(refreshToken: refreshToken) {
            case .success(let refreshed, _): accessToken = refreshed
            case .invalidGrant: throw CredentialError(.ownLoginRevoked)
            case .cooldown: throw CredentialError(.refreshTokenCooldown)
            case .unreachable: throw CredentialError(.tokenRefreshUnreachable)
            case .clientMismatch: throw CredentialError(.clientMismatch)
            case .noCandidates: throw CredentialError(.noCredentials)
            }
        }

        do {
            let (fiveHour, weekly) = try await fetchAntigravityQuota(accessToken: accessToken)
            if ownAccountHint == nil, let fetched = await fetchUserInfo(token: accessToken) {
                ownAccountHint = fetched
            }
            let account = ownAccountHint ?? (isZh ? "Google 账号" : "Google Account")
            return (fiveHour, weekly, account, refreshToken)
        } catch is QuotaAuthError {
            // 缓存的 token 刚好跨过过期线：强制刷新一次再试；仍被拒才判 quotaRejected。
            cachedAccessToken = nil
            cachedAccessTokenExpiry = .distantPast
            switch await refreshGoogleAccessToken(refreshToken: refreshToken) {
            case .success(let refreshed, _):
                do {
                    let (fiveHour, weekly) = try await fetchAntigravityQuota(accessToken: refreshed)
                    if ownAccountHint == nil, let fetched = await fetchUserInfo(token: refreshed) {
                        ownAccountHint = fetched
                    }
                    let account = ownAccountHint ?? (isZh ? "Google 账号" : "Google Account")
                    return (fiveHour, weekly, account, refreshToken)
                } catch is QuotaAuthError {
                    throw CredentialError(.quotaRejected)
                }
            case .invalidGrant: throw CredentialError(.ownLoginRevoked)
            case .cooldown: throw CredentialError(.refreshTokenCooldown)
            case .unreachable: throw CredentialError(.tokenRefreshUnreachable)
            case .clientMismatch: throw CredentialError(.clientMismatch)
            case .noCandidates: throw CredentialError(.noCredentials)
            }
        }
    }

    /// Fetches quota; on auth rejection refreshes the token (when possible) and retries once.
    private func legacyQuotaWithAuthRetry(_ accessToken: String, refreshToken: String?) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?) {
        do {
            return try await fetchAntigravityQuota(accessToken: accessToken)
        } catch is QuotaAuthError {
            guard let refreshToken else { throw CredentialError(.quotaRejected) }
            switch await refreshGoogleAccessToken(refreshToken: refreshToken) {
            case .success(let refreshed, _):
                do {
                    return try await fetchAntigravityQuota(accessToken: refreshed)
                } catch is QuotaAuthError {
                    throw CredentialError(.quotaRejected)
                }
            case .invalidGrant: throw CredentialError(.refreshTokenDead)
            case .cooldown: throw CredentialError(.refreshTokenCooldown)
            case .unreachable: throw CredentialError(.tokenRefreshUnreachable)
            case .clientMismatch: throw CredentialError(.clientMismatch)
            case .noCandidates: throw CredentialError(.noCredentials)
            }
        }
    }

    /// Maps the "Gemini Models" group's weekly / 5-hour buckets of retrieveUserQuotaSummary to TokenWindows.
    private func fetchAntigravityQuota(accessToken: String) async throws -> (TokenWindow?, TokenWindow?) {
        let summary = try await postCloudCode(accessToken: accessToken, path: "/v1internal:retrieveUserQuotaSummary")

        var fiveHour: TokenWindow? = nil
        var weekly: TokenWindow? = nil

        if let groups = summary["groups"] as? [[String: Any]] {
            for group in groups {
                guard let groupName = group["displayName"] as? String,
                      groupName.lowercased().contains("gemini") else { continue }
                if let buckets = group["buckets"] as? [[String: Any]] {
                    for bucket in buckets {
                        if let (window, isWeekly) = parseQuotaBucket(bucket) {
                            if isWeekly { weekly = window } else { fiveHour = window }
                        }
                    }
                }
                break
            }
        }

        if fiveHour == nil && weekly == nil {
            // Older/alternative response shape: fall back to per-model quota and aggregate the gemini family.
            (fiveHour, weekly) = try await fetchAntigravityModelsFallback(accessToken: accessToken)
        }

        guard fiveHour != nil || weekly != nil else {
            throw NSError(domain: "GeminiService", code: 0, userInfo: [NSLocalizedDescriptionKey: isZh ? "Antigravity 额度响应中未找到 Gemini 配额数据" : "No Gemini quota data found in the Antigravity response"])
        }
        return (fiveHour, weekly)
    }

    private func postCloudCode(accessToken: String, path: String) async throws -> [String: Any] {
        var lastError: Error?
        for base in Self.cloudCodeEndpoints {
            guard let url = URL(string: base + path) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue("antigravity", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("{}".utf8)
            req.timeoutInterval = 15

            do {
                let (data, resp) = try await HTTPClient.data(for: req)
                guard let http = resp as? HTTPURLResponse else { continue }
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw QuotaAuthError()
                }
                guard (200..<300).contains(http.statusCode) else {
                    let raw = String(data: data.prefix(300), encoding: .utf8) ?? ""
                    lastError = NSError(domain: "GeminiService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: isZh ? "Antigravity 额度接口响应异常 (\(http.statusCode)): \(raw)" : "Antigravity quota API error (\(http.statusCode)): \(raw)"])
                    continue
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    lastError = NSError(domain: "GeminiService", code: 0, userInfo: [NSLocalizedDescriptionKey: isZh ? "Antigravity 额度响应解析失败" : "Failed to parse the Antigravity quota response"])
                    continue
                }
                return json
            } catch is QuotaAuthError {
                throw QuotaAuthError()
            } catch {
                lastError = error
                continue
            }
        }
        if let lastError = lastError {
            throw lastError
        }
        throw URLError(.badServerResponse)
    }

    /// Maps one quota bucket ({window/bucketId, remainingFraction, resetTime}) to a TokenWindow.
    private func parseQuotaBucket(_ bucket: [String: Any]) -> (window: TokenWindow, isWeekly: Bool)? {
        var kind = (bucket["window"] as? String) ?? ""
        if kind.isEmpty { kind = (bucket["bucketId"] as? String) ?? "" }
        if kind.isEmpty { kind = (bucket["displayName"] as? String) ?? "" }
        kind = kind.lowercased()

        let isWeekly = kind.contains("week")
        let isFiveHour = !isWeekly && (kind.contains("5h") || kind.contains("five") || kind.contains("hour"))
        guard isWeekly || isFiveHour else { return nil }

        let remainingFraction: Double?
        if let n = bucket["remainingFraction"] as? NSNumber {
            remainingFraction = n.doubleValue
        } else if let rem = bucket["remaining"] as? [String: Any],
                  let n = rem["remainingFraction"] as? NSNumber {
            remainingFraction = n.doubleValue
        } else {
            return nil
        }

        let span: TimeInterval = isWeekly ? 7 * 86400 : 5 * 3600
        // While idle the API keeps the last reset anchor; roll forward so the countdown stays positive.
        var end = Self.parseServerDate(bucket["resetTime"]) ?? Date().addingTimeInterval(span)
        while end <= Date() { end = end.addingTimeInterval(span) }

        let usedPct = min(max((1.0 - remainingFraction!) * 100.0, 0.0), 100.0)
        let window = TokenWindow(
            title: isWeekly ? "每周额度" : "5小时额度",
            usedPercentage: usedPct,
            startTime: end.addingTimeInterval(-span),
            endTime: end,
            unit: "%",
            isIdle: remainingFraction! >= 0.999
        )
        return (window, isWeekly)
    }

    /// Fallback via fetchAvailableModels: aggregates the most-constrained gemini model into a 5h window.
    private func fetchAntigravityModelsFallback(accessToken: String) async throws -> (TokenWindow?, TokenWindow?) {
        let response = try await postCloudCode(accessToken: accessToken, path: "/v1internal:fetchAvailableModels")
        guard let models = response["models"] as? [String: Any] else { return (nil, nil) }

        var minRemaining: Double?
        var reset: Date?
        for (key, value) in models {
            guard key.lowercased().hasPrefix("gemini"),
                  let info = value as? [String: Any],
                  let quota = info["quotaInfo"] as? [String: Any],
                  let n = quota["remainingFraction"] as? NSNumber else { continue }
            let fraction = n.doubleValue
            if minRemaining == nil || fraction < minRemaining! {
                minRemaining = fraction
                reset = Self.parseServerDate(quota["resetTime"])
            }
        }
        guard let remaining = minRemaining else { return (nil, nil) }

        let span: TimeInterval = 5 * 3600
        var end = reset ?? Date().addingTimeInterval(span)
        while end <= Date() { end = end.addingTimeInterval(span) }

        let window = TokenWindow(
            title: "5小时额度",
            usedPercentage: min(max((1.0 - remaining) * 100.0, 0.0), 100.0),
            startTime: end.addingTimeInterval(-span),
            endTime: end,
            unit: "%",
            isIdle: remaining >= 0.999
        )
        return (window, nil)
    }

    private func fetchUserInfo(token: String) async -> String? {
        guard let userUrl = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo") else { return nil }
        var req = URLRequest(url: userUrl)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 6

        guard let (data, resp) = try? await HTTPClient.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let userJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return userJson["email"] as? String ?? userJson["name"] as? String
    }

    /// Fetch Gemini usage quota and test connection using Google AI Studio API Key
    public func fetchQuotaWithApiKey(apiKey: String, endpoint: String) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        guard !trimmedKey.isEmpty else {
            throw NSError(domain: "GeminiService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "请输入有效的 Google AI Studio API Key" : "Please enter a valid Google AI Studio API Key"])
        }

        var cleanBase = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanBase.isEmpty {
            cleanBase = "https://generativelanguage.googleapis.com"
        }
        while cleanBase.hasSuffix("/") {
            cleanBase.removeLast()
        }

        let urlString: String
        if cleanBase.hasSuffix("/v1beta") || cleanBase.hasSuffix("/v1") {
            urlString = "\(cleanBase)/models?pageSize=50"
        } else {
            urlString = "\(cleanBase)/v1beta/models?pageSize=50"
        }

        guard let url = URL(string: urlString) else {
            throw NSError(domain: "GeminiService", code: 400, userInfo: [NSLocalizedDescriptionKey: isZh ? "无效的 Gemini API 终端地址" : "Invalid Gemini API endpoint address"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        let (data, response) = try await HTTPClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if http.statusCode != 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errObj = json["error"] as? [String: Any],
               let msg = errObj["message"] as? String {
                throw NSError(domain: "GeminiService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: isZh ? "Gemini API 错误: \(msg)" : "Gemini API error: \(msg)"])
            }
            let rawMsg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "GeminiService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: isZh ? "Gemini API 响应异常 (\(http.statusCode)): \(rawMsg)" : "Gemini API response error (\(http.statusCode)): \(rawMsg)"])
        }

        var modelCount = 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = json["models"] as? [[String: Any]] {
            modelCount = models.count
        }

        // Check rate limit headers if returned
        var rpmWindow: TokenWindow? = nil
        let limitReqsStr = http.value(forHTTPHeaderField: "x-ratelimit-limit-requests") ?? http.value(forHTTPHeaderField: "x-ratelimit-limit-rpm")
        let remainingReqsStr = http.value(forHTTPHeaderField: "x-ratelimit-remaining-requests") ?? http.value(forHTTPHeaderField: "x-ratelimit-remaining-rpm")

        if let limitReqs = Double(limitReqsStr ?? ""),
           let remReqs = Double(remainingReqsStr ?? ""),
           limitReqs > 0 {
            let used = max(0.0, limitReqs - remReqs)
            let usedPct = min(max((used / limitReqs) * 100.0, 0.0), 100.0)
            let now = Date()
            rpmWindow = TokenWindow(
                title: "RPM 速率配额",
                usedPercentage: usedPct,
                startTime: now,
                endTime: now.addingTimeInterval(60),
                usedAmount: used,
                totalLimit: limitReqs,
                unit: "req/min",
                isIdle: used == 0.0
            )
        }

        // API Key 模式只能探测连通性与模型清单，拿不到真实的 5 小时 / 每周额度。
        // 以前用「当前小时 / 5」拼出 5 小时起止、再无条件给一条 0% 的每周窗口，都是没有数据来源的假数据。
        let fiveHour = rpmWindow ?? TokenWindow.status(title: "API 连接正常")
        let weekly = TokenWindow.status(title: modelCount > 0 ? "可用模型 (\(modelCount)个)" : "AI Studio 配额")

        let maskedKey: String
        if trimmedKey.count > 8 {
            let prefix = String(trimmedKey.prefix(6))
            let suffix = String(trimmedKey.suffix(4))
            maskedKey = "\(prefix)...\(suffix)"
        } else {
            maskedKey = "AI Studio Key"
        }

        let accountDisplay = "AI Studio (\(maskedKey))"
        return (fiveHour, weekly, accountDisplay)
    }
}
