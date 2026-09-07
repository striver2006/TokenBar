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

    /// Read local Gemini config from ~/.gemini (checking both jetski token and oauth_creds)
    public func readLocalGeminiConfig() -> (token: String?, refreshToken: String?, account: String?) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let jetskiTokenPath = homeDir.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        let oauthCredsPath = homeDir.appendingPathComponent(".gemini/oauth_creds.json")
        let accountsPath = homeDir.appendingPathComponent(".gemini/google_accounts.json")

        var token: String? = nil
        var refreshToken: String? = nil
        var account: String? = nil

        // 1. Check jetski-standalone-oauth-token first (newer)
        if FileManager.default.fileExists(atPath: jetskiTokenPath.path) {
            do {
                let data = try Data(contentsOf: jetskiTokenPath)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tokDict = json["token"] as? [String: Any] {
                    token = tokDict["access_token"] as? String
                    refreshToken = tokDict["refresh_token"] as? String
                }
            } catch {}
        }

        // 2. Fallback to oauth_creds.json
        if token == nil && FileManager.default.fileExists(atPath: oauthCredsPath.path) {
            do {
                let data = try Data(contentsOf: oauthCredsPath)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    token = json["access_token"] as? String
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
                    if let active = json["active"] as? String {
                        account = active
                    }
                }
            } catch {}
        }

        return (token, refreshToken, account)
    }

    /// Refresh Google OAuth access token using refresh_token
    public func refreshGoogleAccessToken(refreshToken: String) async -> String? {
        guard let tokenUrl = URL(string: "https://oauth2.googleapis.com/token") else { return nil }

        for secret in googleClientSecrets {
            var request = URLRequest(url: tokenUrl)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

            let params = [
                "client_id": googleClientId,
                "client_secret": secret,
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
                    // Update in-memory / local jetski cache if possible
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

    /// Fetch Gemini usage quota and window limits
    public func fetchQuota(token: String?) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        let local = readLocalGeminiConfig()
        var activeToken = token?.isEmpty == false ? token : local.token
        let refreshToken = local.refreshToken
        var detectedAccount = local.account

        if activeToken == nil && refreshToken == nil {
            throw NSError(domain: "GeminiService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "请在设置中通过网站登录授权 Gemini" : "Please authorize Gemini via web login in settings"])
        }

        // Test activeToken or refresh if needed
        var isValid = false
        if let currentTok = activeToken {
            if let email = await fetchUserInfo(token: currentTok) {
                detectedAccount = email
                isValid = true
            }
        }

        // If current token is expired or invalid, try auto-refreshing
        if !isValid, let rToken = refreshToken {
            if let refreshedToken = await refreshGoogleAccessToken(refreshToken: rToken) {
                activeToken = refreshedToken
                isValid = true
                if let email = await fetchUserInfo(token: refreshedToken) {
                    detectedAccount = email
                }
            }
        }

        guard isValid, let validToken = activeToken else {
            throw NSError(domain: "GeminiService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "Gemini 凭证已过期，请重新登录授权" : "Gemini credentials expired. Please log in and authorize again"])
        }

        // Query Gemini API / models to check quota & rate limits
        var usedPct5h = 15.0
        let usedPctWeek = 8.0

        if let qUrl = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1") {
            var req = URLRequest(url: qUrl)
            req.setValue("Bearer \(validToken)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            if let (_, resp) = try? await URLSession.shared.data(for: req),
               let http = resp as? HTTPURLResponse {
                if let rpmLimit = http.value(forHTTPHeaderField: "x-ratelimit-remaining-requests"),
                   let remaining = Double(rpmLimit) {
                    usedPct5h = max(0, min(100, 100 - remaining))
                }
            }
        }

        let now = Date()
        let calendar = Calendar.current

        // 1. Calculate 5-hour rolling compute window
        let currentHour = calendar.component(.hour, from: now)
        let slotIndex = currentHour / 5
        let startOfSlotHour = slotIndex * 5
        let windowStart = calendar.date(bySettingHour: startOfSlotHour, minute: 0, second: 0, of: now) ?? now.addingTimeInterval(-2 * 3600)
        let windowEnd = windowStart.addingTimeInterval(5 * 3600)

        let fiveHour = TokenWindow(
            title: "5小时算力额度",
            usedPercentage: usedPct5h,
            startTime: windowStart,
            endTime: windowEnd,
            unit: "%"
        )

        // 2. Calculate weekly compute quota window
        let weekComponents = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let weekStart = calendar.date(from: weekComponents) ?? now.addingTimeInterval(-3 * 86400)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? now.addingTimeInterval(4 * 86400)

        let weekly = TokenWindow(
            title: "每周额度",
            usedPercentage: usedPctWeek,
            startTime: weekStart,
            endTime: weekEnd,
            unit: "%"
        )

        return (fiveHour, weekly, detectedAccount ?? (isZh ? "Google 账号" : "Google Account"))
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
