import Foundation

public final class GeminiService {
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

    private func getAntigravityClientCandidates() -> [(id: String, secret: String)] {
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
        for id in ids {
            for secret in secrets {
                guard list.count < 8 else { break }
                list.append((id, secret))
            }
        }

        antigravityClientCandidates = list
        return list
    }

    /// Scans a large binary in overlapping chunks for the embedded OAuth client patterns.
    private func scanFileForClientPatterns(_ path: String, ids: inout Set<String>, secrets: inout Set<String>) {
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

    private struct QuotaAuthError: Error {}

    private var isZh: Bool { LocalizationManager.shared.effectiveLanguage == "zh" }

    /// Read Antigravity credentials from macOS Keychain (service: "gemini", account: "antigravity")
    private func readKeychainToken() -> (token: String?, refreshToken: String?, expiry: Date?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return (nil, nil, nil) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return (nil, nil, nil)
            }
            let jsonString: String
            if raw.hasPrefix("go-keyring-base64:") {
                let b64 = String(raw.dropFirst("go-keyring-base64:".count))
                guard let dec = Data(base64Encoded: b64), let s = String(data: dec, encoding: .utf8) else {
                    return (nil, nil, nil)
                }
                jsonString = s
            } else {
                jsonString = raw
            }
            guard let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let tokDict = json["token"] as? [String: Any] else {
                return (nil, nil, nil)
            }
            let token = tokDict["access_token"] as? String
            let refreshToken = tokDict["refresh_token"] as? String
            let expiry = parseServerDate(tokDict["expiry"])
            return (token, refreshToken, expiry)
        } catch {
            return (nil, nil, nil)
        }
    }

    /// Read local Gemini config from macOS Keychain and ~/.gemini
    public func readLocalGeminiConfig() -> (token: String?, refreshToken: String?, account: String?, expiry: Date?) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let jetskiTokenPath = homeDir.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        let oauthCredsPath = homeDir.appendingPathComponent(".gemini/oauth_creds.json")
        let accountsPath = homeDir.appendingPathComponent(".gemini/google_accounts.json")

        var token: String? = nil
        var refreshToken: String? = nil
        var account: String? = nil
        var expiry: Date? = nil

        // 0. Check macOS Keychain first (most up-to-date token managed by Antigravity)
        let kc = readKeychainToken()
        if kc.token != nil || kc.refreshToken != nil {
            token = kc.token
            refreshToken = kc.refreshToken
            expiry = kc.expiry
        }

        // 1. Check jetski-standalone-oauth-token (fallback/merge if keychain was empty)
        if FileManager.default.fileExists(atPath: jetskiTokenPath.path) {
            do {
                let data = try Data(contentsOf: jetskiTokenPath)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tokDict = json["token"] as? [String: Any] {
                    if token == nil {
                        token = tokDict["access_token"] as? String
                    }
                    if refreshToken == nil {
                        refreshToken = tokDict["refresh_token"] as? String
                    }
                    if expiry == nil {
                        expiry = parseServerDate(tokDict["expiry"])
                    }
                }
            } catch {}
        }

        // 2. Fallback to oauth_creds.json
        if (token == nil || refreshToken == nil) && FileManager.default.fileExists(atPath: oauthCredsPath.path) {
            do {
                let data = try Data(contentsOf: oauthCredsPath)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if token == nil {
                        token = json["access_token"] as? String
                    }
                    if refreshToken == nil {
                        refreshToken = json["refresh_token"] as? String
                    }
                }
            } catch {}
        }

        // 3. Read Google account email
        if FileManager.default.fileExists(atPath: accountsPath.path) {
            do {
                let data = try Data(contentsOf: accountsPath)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let active = json["active"] as? String, !active.isEmpty {
                        account = active
                    } else if let old = json["old"] as? [String], let first = old.first, !first.isEmpty {
                        account = first
                    }
                }
            } catch {}
        }

        return (token, refreshToken, account, expiry)
    }

    /// Parses ISO-8601 strings (with or without fractional seconds) or epoch seconds into a Date.
    private func parseServerDate(_ any: Any?) -> Date? {
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

        for client in getAntigravityClientCandidates() {
            var request = URLRequest(url: tokenUrl)
            request.httpMethod = "POST"
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
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let newAccessToken = json["access_token"] as? String {
                    let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
                    // Cache the working pair first so later refreshes skip the trial-and-error.
                    antigravityClientCandidates?.removeAll { $0.id == client.id && $0.secret == client.secret }
                    antigravityClientCandidates?.insert(client, at: 0)
                    cachedAccessToken = newAccessToken
                    cachedAccessTokenExpiry = Date().addingTimeInterval(max(60, expiresIn - 120))
                    // Update local jetski cache if possible
                    updateLocalAccessToken(newAccessToken)
                    return newAccessToken
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private func updateLocalAccessToken(_ newToken: String) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let jetskiTokenPath = homeDir.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        guard FileManager.default.fileExists(atPath: jetskiTokenPath.path),
              var dataDict = try? JSONSerialization.jsonObject(with: Data(contentsOf: jetskiTokenPath)) as? [String: Any],
              var tokDict = dataDict["token"] as? [String: Any] else { return }

        tokDict["access_token"] = newToken
        dataDict["token"] = tokDict
        if let newData = try? JSONSerialization.data(withJSONObject: dataDict, options: .prettyPrinted) {
            try? newData.write(to: jetskiTokenPath)
        }
    }

    /// Fetch Gemini usage quota and window limits from the Antigravity (Google Code Assist)
    /// quota API — the same source the Antigravity IDE's usage panel displays.
    public func fetchQuota(token: String?) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        let local = readLocalGeminiConfig()
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
                throw NSError(domain: "GeminiService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "Google 凭证刷新失败，请重新运行 agy 登录或在设置中更新凭证" : "Failed to refresh Google credentials. Please log in again via agy or update credentials in Settings"])
            }
            accessToken = refreshed
        } else if let stored = (token?.isEmpty == false ? token : local.token) {
            // No expiry info and no refresh token: try it, auth errors surface a clear message below.
            accessToken = stored
        } else {
            throw NSError(domain: "GeminiService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "请在设置中通过网站登录授权 Gemini" : "Please authorize Gemini via web login in settings"])
        }

        let (fiveHour, weekly) = try await fetchQuotaWithAuthRetry(accessToken, refreshToken: refreshToken)

        if detectedAccount == nil {
            detectedAccount = await fetchUserInfo(token: accessToken)
        }

        return (fiveHour, weekly, detectedAccount ?? (isZh ? "Google 账号" : "Google Account"))
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
                let (data, resp) = try await URLSession.shared.data(for: req)
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
        var end = parseServerDate(bucket["resetTime"]) ?? Date().addingTimeInterval(span)
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
                reset = parseServerDate(quota["resetTime"])
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

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
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

        let (data, response) = try await URLSession.shared.data(for: request)
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

        let now = Date()
        let calendar = Calendar.current
        let currentHour = calendar.component(.hour, from: now)
        let slotIndex = currentHour / 5
        let startOfSlotHour = slotIndex * 5
        let windowStart = calendar.date(bySettingHour: startOfSlotHour, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(-2 * 3600)
        let windowEnd = windowStart.addingTimeInterval(5 * 3600)

        let fiveHour = rpmWindow ?? TokenWindow(
            title: "API 连接正常",
            usedPercentage: 0.0,
            startTime: windowStart,
            endTime: windowEnd,
            unit: "%",
            isIdle: true
        )

        let weekComponents = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let weekStart = calendar.date(from: weekComponents) ?? now.addingTimeInterval(-3 * 86400)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? now.addingTimeInterval(4 * 86400)

        let weekly = TokenWindow(
            title: modelCount > 0 ? "可用模型 (\(modelCount)个)" : "AI Studio 配额",
            usedPercentage: 0.0,
            startTime: weekStart,
            endTime: weekEnd,
            unit: "%",
            isIdle: true
        )

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
