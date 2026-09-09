import Foundation

public final class ClaudeService {
    public static let shared = ClaudeService()

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let isoFormatterNoFrac: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func parseDate(_ dateStr: String) -> Date? {
        if let date = isoFormatter.date(from: dateStr) {
            return date
        }
        return isoFormatterNoFrac.date(from: dateStr)
    }

    /// Read locally cached usage and account info from ~/.claude.json if present
    public func readLocalClaudeJson() -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?)? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let claudeJsonUrl = homeDir.appendingPathComponent(".claude.json")

        guard FileManager.default.fileExists(atPath: claudeJsonUrl.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: claudeJsonUrl)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            var accountEmail: String? = nil
            if let oauthAccount = json["oauthAccount"] as? [String: Any] {
                accountEmail = oauthAccount["emailAddress"] as? String ?? oauthAccount["displayName"] as? String
            }

            guard let cached = json["cachedUsageUtilization"] as? [String: Any],
                  let utilization = cached["utilization"] as? [String: Any] else {
                // If account is logged in but no cached utilization yet, create clean initial 5h window
                let now = Date()
                let fiveHour = TokenWindow(
                    title: "5小时额度",
                    usedPercentage: 0.0,
                    startTime: now,
                    endTime: now.addingTimeInterval(5 * 3600),
                    unit: "%",
                    isIdle: true
                )
                return (fiveHour, nil, accountEmail)
            }

            var fiveHourWindow: TokenWindow? = nil
            var weeklyWindow: TokenWindow? = nil

            // 1. Parse 5-hour session window
            if let fiveHour = utilization["five_hour"] as? [String: Any] {
                let util = (fiveHour["utilization"] as? NSNumber)?.doubleValue ?? 0.0
                let resetsAtStr = fiveHour["resets_at"] as? String

                if let str = resetsAtStr, let resetsAt = parseDate(str) {
                    if resetsAt > Date() {
                        let startTime = resetsAt.addingTimeInterval(-5 * 3600)
                        fiveHourWindow = TokenWindow(
                            title: "5小时额度",
                            usedPercentage: util,
                            startTime: startTime,
                            endTime: resetsAt,
                            unit: "%",
                            isIdle: false
                        )
                    } else {
                        // Previous 5h window has passed reset time -> resets to 0% used (100% remaining)
                        let now = Date()
                        fiveHourWindow = TokenWindow(
                            title: "5小时额度",
                            usedPercentage: 0.0,
                            startTime: now,
                            endTime: now.addingTimeInterval(5 * 3600),
                            unit: "%",
                            isIdle: true
                        )
                    }
                } else {
                    // resets_at is null: session is currently idle/reset, 100% quota available!
                    let now = Date()
                    fiveHourWindow = TokenWindow(
                        title: "5小时额度",
                        usedPercentage: util,
                        startTime: now,
                        endTime: now.addingTimeInterval(5 * 3600),
                        unit: "%",
                        isIdle: true
                    )
                }
            }

            // Fallback from limits array if fiveHourWindow is still nil
            if fiveHourWindow == nil,
               let limits = utilization["limits"] as? [[String: Any]],
               let session = limits.first(where: { ($0["kind"] as? String) == "session" || ($0["group"] as? String) == "session" }) {
                let pct = (session["percent"] as? NSNumber)?.doubleValue ?? 0.0
                let now = Date()
                fiveHourWindow = TokenWindow(
                    title: "5小时额度",
                    usedPercentage: pct,
                    startTime: now,
                    endTime: now.addingTimeInterval(5 * 3600),
                    unit: "%",
                    isIdle: pct == 0.0
                )
            }

            // Guarantee 5-hour window exists for Claude Code
            if fiveHourWindow == nil {
                let now = Date()
                fiveHourWindow = TokenWindow(
                    title: "5小时额度",
                    usedPercentage: 0.0,
                    startTime: now,
                    endTime: now.addingTimeInterval(5 * 3600),
                    unit: "%",
                    isIdle: true
                )
            }

            // 2. Parse 7-day weekly window
            if let sevenDay = utilization["seven_day"] as? [String: Any] {
                let util = (sevenDay["utilization"] as? NSNumber)?.doubleValue ?? 0.0
                let resetsAtStr = sevenDay["resets_at"] as? String
                if let str = resetsAtStr, let resetsAt = parseDate(str) {
                    let startTime = resetsAt.addingTimeInterval(-7 * 86400)
                    weeklyWindow = TokenWindow(
                        title: "每周额度",
                        usedPercentage: util,
                        startTime: startTime,
                        endTime: resetsAt,
                        unit: "%",
                        isIdle: false
                    )
                }
            }

            if weeklyWindow == nil,
               let limits = utilization["limits"] as? [[String: Any]],
               let weekly = limits.first(where: { ($0["kind"] as? String) == "weekly_all" || ($0["group"] as? String) == "weekly" }) {
                let pct = (weekly["percent"] as? NSNumber)?.doubleValue ?? 0.0
                let resetsAtStr = weekly["resets_at"] as? String
                let now = Date()
                let resetsAt = resetsAtStr != nil ? (parseDate(resetsAtStr!) ?? now.addingTimeInterval(7 * 86400)) : now.addingTimeInterval(7 * 86400)
                let startTime = resetsAt.addingTimeInterval(-7 * 86400)
                weeklyWindow = TokenWindow(
                    title: "每周额度",
                    usedPercentage: pct,
                    startTime: startTime,
                    endTime: resetsAt,
                    unit: "%",
                    isIdle: false
                )
            }

            return (fiveHourWindow, weeklyWindow, accountEmail)
        } catch {
            return nil
        }
    }

    /// Fetch latest usage statistics from Anthropic OAuth usage API
    public func fetchRemoteUsage(token: String) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.263", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        let (data, response) = try await HTTPClient.data(for: request)

        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResp.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            throw NSError(domain: "ClaudeService", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        var fiveHourWindow: TokenWindow? = nil
        var weeklyWindow: TokenWindow? = nil

        // 1. Parse 5-hour session window
        if let fiveHour = json["five_hour"] as? [String: Any] {
            let util = (fiveHour["utilization"] as? NSNumber)?.doubleValue ?? 0.0
            let resetsAtStr = fiveHour["resets_at"] as? String

            if let str = resetsAtStr, let resetsAt = parseDate(str) {
                if resetsAt > Date() {
                    let startTime = resetsAt.addingTimeInterval(-5 * 3600)
                    fiveHourWindow = TokenWindow(
                        title: "5小时额度",
                        usedPercentage: util,
                        startTime: startTime,
                        endTime: resetsAt,
                        unit: "%",
                        isIdle: false
                    )
                } else {
                    let now = Date()
                    fiveHourWindow = TokenWindow(
                        title: "5小时额度",
                        usedPercentage: 0.0,
                        startTime: now,
                        endTime: now.addingTimeInterval(5 * 3600),
                        unit: "%",
                        isIdle: true
                    )
                }
            } else {
                let now = Date()
                fiveHourWindow = TokenWindow(
                    title: "5小时额度",
                    usedPercentage: util,
                    startTime: now,
                    endTime: now.addingTimeInterval(5 * 3600),
                    unit: "%",
                    isIdle: true
                )
            }
        }

        if fiveHourWindow == nil {
            let now = Date()
            fiveHourWindow = TokenWindow(
                title: "5小时额度",
                usedPercentage: 0.0,
                startTime: now,
                endTime: now.addingTimeInterval(5 * 3600),
                unit: "%",
                isIdle: true
            )
        }

        // 2. Parse 7-day weekly window
        if let sevenDay = json["seven_day"] as? [String: Any] {
            let util = (sevenDay["utilization"] as? NSNumber)?.doubleValue ?? 0.0
            let resetsAtStr = sevenDay["resets_at"] as? String
            if let str = resetsAtStr, let resetsAt = parseDate(str) {
                let startTime = resetsAt.addingTimeInterval(-7 * 86400)
                weeklyWindow = TokenWindow(
                    title: "每周额度",
                    usedPercentage: util,
                    startTime: startTime,
                    endTime: resetsAt,
                    unit: "%",
                    isIdle: false
                )
            }
        }

        return (fiveHourWindow, weeklyWindow, nil)
    }

    /// Fetch usage / rate limits using Anthropic API key via GET /v1/models
    public func fetchAnthropicQuota(
        apiKey: String,
        endpoint: String = "https://api.anthropic.com/v1"
    ) async throws -> (primary: TokenWindow?, secondary: TokenWindow?, account: String?) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        guard !cleanKey.isEmpty else {
            throw NSError(domain: "ClaudeService", code: 400, userInfo: [NSLocalizedDescriptionKey: isZh ? "请输入 Anthropic API Key" : "Please enter Anthropic API Key"])
        }

        var baseEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseEndpoint.isEmpty {
            baseEndpoint = "https://api.anthropic.com/v1"
        }
        while baseEndpoint.hasSuffix("/") {
            baseEndpoint.removeLast()
        }

        let modelsURLStr = baseEndpoint.hasSuffix("/models") ? baseEndpoint : "\(baseEndpoint)/models"
        guard let url = URL(string: modelsURLStr) else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(cleanKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        let (data, response) = try await HTTPClient.data(for: req)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResp.statusCode == 401 {
            throw NSError(domain: "ClaudeService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "Anthropic API Key 无效或未授权 (HTTP 401)" : "Anthropic API Key is invalid or unauthorized (HTTP 401)"])
        }

        if httpResp.statusCode == 429 {
            throw NSError(domain: "ClaudeService", code: 429, userInfo: [NSLocalizedDescriptionKey: isZh ? "Anthropic 请求频率或额度超限 (HTTP 429)" : "Anthropic rate limit or quota exceeded (HTTP 429)"])
        }

        guard httpResp.statusCode >= 200 && httpResp.statusCode < 300 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            throw NSError(domain: "ClaudeService", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: isZh ? "Anthropic 接口响应异常: \(msg.prefix(100))" : "Anthropic API response error: \(msg.prefix(100))"])
        }

        let allHeaders = httpResp.allHeaderFields
        func getHeader(_ name: String) -> String? {
            let target = name.lowercased()
            for (k, v) in allHeaders {
                if let keyStr = k as? String, keyStr.lowercased() == target {
                    return String(describing: v)
                }
            }
            return nil
        }

        let limitTokensStr = getHeader("anthropic-ratelimit-tokens-limit")
        let remainingTokensStr = getHeader("anthropic-ratelimit-tokens-remaining")

        let limitReqsStr = getHeader("anthropic-ratelimit-requests-limit")
        let remainingReqsStr = getHeader("anthropic-ratelimit-requests-remaining")

        var primaryWindow: TokenWindow? = nil
        var secondaryWindow: TokenWindow? = nil

        if let limitTokens = Double(limitTokensStr ?? ""),
           let remainingTokens = Double(remainingTokensStr ?? ""),
           limitTokens > 0 {
            let used = max(0.0, limitTokens - remainingTokens)
            let usedPct = min(max((used / limitTokens) * 100.0, 0.0), 100.0)
            let duration: TimeInterval = 60
            let now = Date()

            primaryWindow = TokenWindow(
                title: "TPM 速率配额",
                usedPercentage: usedPct,
                startTime: now,
                endTime: now.addingTimeInterval(duration),
                usedAmount: used,
                totalLimit: limitTokens,
                unit: "tokens",
                isIdle: used == 0.0
            )
        }

        if let limitReqs = Double(limitReqsStr ?? ""),
           let remainingReqs = Double(remainingReqsStr ?? ""),
           limitReqs > 0 {
            let used = max(0.0, limitReqs - remainingReqs)
            let usedPct = min(max((used / limitReqs) * 100.0, 0.0), 100.0)
            let now = Date()

            secondaryWindow = TokenWindow(
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

        if primaryWindow == nil && secondaryWindow == nil {
            primaryWindow = TokenWindow(
                title: "Anthropic API 连接正常",
                usedPercentage: 0.0,
                startTime: Date(),
                endTime: Date().addingTimeInterval(86400),
                unit: "%",
                isIdle: true
            )
        }

        let keySuffix = cleanKey.count > 6 ? String(cleanKey.suffix(4)) : cleanKey
        let account = isZh ? "Anthropic API (尾号 \(keySuffix))" : "Anthropic API (... \(keySuffix))"

        return (primaryWindow, secondaryWindow, account)
    }
}
