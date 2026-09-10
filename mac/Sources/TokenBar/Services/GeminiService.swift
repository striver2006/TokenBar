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
    /// 把 RefreshManager 的刷新闸门占死，导致定时刷新整体停摆。
    private static let tokenClientCandidateLimit = 3

    private struct QuotaAuthError: Error {}

    private var isZh: Bool { LocalizationManager.shared.effectiveLanguage == "zh" }

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
    private func readAntigravityKeychain(allowInteraction: Bool) async -> KeychainCredentials? {
        let lookup = await KeychainSecretStore.shared.readForeignAsync(
            service: Self.antigravityKeychainService,
            account: Self.antigravityKeychainAccount,
            allowInteraction: allowInteraction
        )
        guard case .found(let raw) = lookup, let payload = Self.decodeKeychainPayload(raw) else {
            return nil
        }
        return KeychainCredentials(
            token: payload["access_token"] as? String,
            refreshToken: payload["refresh_token"] as? String,
            expiry: Self.parseServerDate(payload["expiry"])
        )
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
    ) async -> (token: String?, refreshToken: String?, account: String?, expiry: Date?) {
        let keychain = await readAntigravityKeychain(allowInteraction: allowKeychainInteraction)
        let files = await Self.readLocalGeminiFiles()
        let merged = Self.mergeCredentials(keychain: keychain, files: files, storedRefreshToken: storedRefreshToken)
        Log.provider.debug("provider=gemini 凭证来源 keychain=\(keychain != nil, privacy: .public) file=\(files.jetskiToken != nil, privacy: .public)")
        return (merged.token, merged.refreshToken, files.account, merged.expiry)
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
    /// more than one client); on success the pair is moved to the front and the token is
    /// cached in memory for its lifetime (~1h).
    public func refreshGoogleAccessToken(refreshToken: String) async -> String? {
        guard let tokenUrl = URL(string: "https://oauth2.googleapis.com/token") else { return nil }

        if let last = lastTokenRefreshFailure,
           Date().timeIntervalSince(last) < Self.tokenRefreshCooldown {
            Log.provider.info("gemini token 刷新处于冷却期，跳过本轮")
            return nil
        }

        // 整个候选循环的硬预算：任何一个候选慢下来都不能让整轮刷新失控。
        let deadline = Date().addingTimeInterval(Self.tokenRefreshBudget)

        for client in await getAntigravityClientCandidates().prefix(Self.tokenClientCandidateLimit) {
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
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let newAccessToken = json["access_token"] as? String {
                    let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
                    // Cache the working pair first so later refreshes skip the trial-and-error.
                    antigravityClientCandidates?.removeAll { $0.id == client.id && $0.secret == client.secret }
                    antigravityClientCandidates?.insert(client, at: 0)
                    cachedAccessToken = newAccessToken
                    cachedAccessTokenExpiry = Date().addingTimeInterval(max(60, expiresIn - 120))
                    lastTokenRefreshFailure = nil
                    // 不再写回 ~/.gemini/jetski-standalone-oauth-token：那是 Antigravity 的文件，
                    // 非原子写会在它并发写入时留下截断 JSON、还会把 0600 改成 umask 默认权限
                    // （与 ARCH 5.1 对 ~/.bailian/config.json「只读不写回」是同一条规矩）。
                    // 内存缓存 cachedAccessToken 已经覆盖了「下次刷新不用重签」的需求。
                    return newAccessToken
                }
            } catch {
                continue
            }
        }
        lastTokenRefreshFailure = Date()
        Log.provider.error("gemini token 刷新失败：所有候选都没能换到 access token")
        return nil
    }

    /// Fetch Gemini usage quota and window limits from the Antigravity (Google Code Assist)
    /// quota API — the same source the Antigravity IDE's usage panel displays.
    /// 返回值里带上本轮用到的 refresh_token，调用方据此把它落进自有钥匙串条目做快照。
    public func fetchQuota(token: String?, storedRefreshToken: String? = nil) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?, refreshToken: String?) {
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
            guard let refreshed = await refreshGoogleAccessToken(refreshToken: refreshToken) else {
                throw NSError(domain: "GeminiService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "Gemini 凭证已失效，请在 Antigravity 中重新登录，或在设置中填入 Token" : "Gemini credentials expired. Log in again in Antigravity, or enter a token in Settings"])
            }
            accessToken = refreshed
        } else if let stored = (token?.isEmpty == false ? token : local.token) {
            // No expiry info and no refresh token: try it, auth errors surface a clear message below.
            accessToken = stored
        } else {
            throw NSError(domain: "GeminiService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "未找到 Gemini 凭证，请在 Antigravity 中登录，或在设置中通过网站登录授权" : "No Gemini credentials found. Log in via Antigravity, or authorize via web login in Settings"])
        }

        let (fiveHour, weekly) = try await fetchQuotaWithAuthRetry(accessToken, refreshToken: refreshToken)

        if detectedAccount == nil {
            detectedAccount = await fetchUserInfo(token: accessToken)
        }

        return (fiveHour, weekly, detectedAccount ?? (isZh ? "Google 账号" : "Google Account"), refreshToken)
    }

    /// Fetches quota; on auth rejection refreshes the token (when possible) and retries once.
    private func fetchQuotaWithAuthRetry(_ accessToken: String, refreshToken: String?) async throws -> (TokenWindow?, TokenWindow?) {
        do {
            return try await fetchAntigravityQuota(accessToken: accessToken)
        } catch is QuotaAuthError {
            guard let refreshToken,
                  let refreshed = await refreshGoogleAccessToken(refreshToken: refreshToken) else {
                throw NSError(domain: "GeminiService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "Antigravity 凭证无效或已过期，请重新运行 agy 登录或在设置中更新凭证" : "Antigravity credentials are invalid or expired. Please log in again via agy or update credentials in Settings"])
            }
            return try await fetchAntigravityQuota(accessToken: refreshed)
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
