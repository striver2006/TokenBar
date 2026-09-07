import Foundation

public final class OpenAIService: @unchecked Sendable {
    public static let shared = OpenAIService()

    public init() {}

    /// Fetches OpenAI quota and rate limits
    public func fetchQuota(
        apiKey: String,
        endpoint: String = "https://api.openai.com/v1",
        organizationId: String? = nil
    ) async throws -> (primary: TokenWindow?, secondary: TokenWindow?, account: String?) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
            throw NSError(
                domain: "OpenAIService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: isZh ? "请输入 OpenAI API Key" : "Please enter OpenAI API Key"]
            )
        }

        var baseEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseEndpoint.isEmpty {
            baseEndpoint = "https://api.openai.com/v1"
        }
        while baseEndpoint.hasSuffix("/") {
            baseEndpoint.removeLast()
        }

        let targetURLString: String
        if baseEndpoint.hasSuffix("/models") {
            targetURLString = baseEndpoint
        } else {
            targetURLString = "\(baseEndpoint)/models"
        }

        guard let url = URL(string: targetURLString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let org = organizationId?.trimmingCharacters(in: .whitespacesAndNewlines), !org.isEmpty {
            request.setValue(org, forHTTPHeaderField: "OpenAI-Organization")
        }
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        if httpResp.statusCode == 401 {
            throw NSError(
                domain: "OpenAIService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: isZh ? "OpenAI API Key 无效或已过期 (HTTP 401)" : "OpenAI API Key is invalid or expired (HTTP 401)"]
            )
        }

        if httpResp.statusCode == 429 {
            var msg = isZh ? "请求过于频繁或额度已耗尽 (HTTP 429)" : "Rate limit reached or quota exhausted (HTTP 429)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let errDetail = err["message"] as? String {
                msg = errDetail
            }
            throw NSError(domain: "OpenAIService", code: 429, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        guard httpResp.statusCode >= 200 && httpResp.statusCode < 300 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            throw NSError(
                domain: "OpenAIService",
                code: httpResp.statusCode,
                userInfo: [NSLocalizedDescriptionKey: isZh ? "OpenAI 接口请求失败 (\(httpResp.statusCode)): \(errorMsg.prefix(120))" : "OpenAI request failed (\(httpResp.statusCode)): \(errorMsg.prefix(120))"]
            )
        }

        // Parse rate limits from headers
        let allHeaders = httpResp.allHeaderFields

        func getHeader(_ name: String) -> String? {
            let lowerTarget = name.lowercased()
            for (k, v) in allHeaders {
                if let keyStr = k as? String, keyStr.lowercased() == lowerTarget {
                    return String(describing: v)
                }
            }
            return nil
        }

        let limitTokensStr = getHeader("x-ratelimit-limit-tokens")
        let remainingTokensStr = getHeader("x-ratelimit-remaining-tokens")
        let resetTokensStr = getHeader("x-ratelimit-reset-tokens")

        let limitReqStr = getHeader("x-ratelimit-limit-requests")
        let remainingReqStr = getHeader("x-ratelimit-remaining-requests")
        let resetReqStr = getHeader("x-ratelimit-reset-requests")

        let orgHeader = getHeader("openai-organization")

        var primaryWindow: TokenWindow? = nil
        var secondaryWindow: TokenWindow? = nil

        // 1. Tokens Rate Limit Window (TPM)
        if let limitTokens = Double(limitTokensStr ?? ""),
           let remainingTokens = Double(remainingTokensStr ?? ""),
           limitTokens > 0 {
            let used = max(0.0, limitTokens - remainingTokens)
            let usedPct = min(max((used / limitTokens) * 100.0, 0.0), 100.0)

            let duration = parseDurationString(resetTokensStr ?? "1s")
            let now = Date()
            let resetDate = now.addingTimeInterval(duration)

            primaryWindow = TokenWindow(
                title: "TPM 速率剩余",
                usedPercentage: usedPct,
                startTime: now,
                endTime: resetDate,
                usedAmount: used,
                totalLimit: limitTokens,
                unit: "tokens",
                isIdle: used == 0.0
            )
        }

        // 2. Requests Rate Limit Window (RPM)
        if let limitReq = Double(limitReqStr ?? ""),
           let remainingReq = Double(remainingReqStr ?? ""),
           limitReq > 0 {
            let used = max(0.0, limitReq - remainingReq)
            let usedPct = min(max((used / limitReq) * 100.0, 0.0), 100.0)

            let duration = parseDurationString(resetReqStr ?? "1s")
            let now = Date()
            let resetDate = now.addingTimeInterval(duration)

            secondaryWindow = TokenWindow(
                title: "RPM 请求速率",
                usedPercentage: usedPct,
                startTime: now,
                endTime: resetDate,
                usedAmount: used,
                totalLimit: limitReq,
                unit: "req",
                isIdle: used == 0.0
            )
        }

        // If no rate limit headers are exposed by the gateway, show connected status
        var modelCount = 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataArr = json["data"] as? [[String: Any]] {
            modelCount = dataArr.count
        }

        if primaryWindow == nil {
            primaryWindow = TokenWindow(
                title: "API 连接状态",
                usedPercentage: 0.0,
                startTime: Date(),
                endTime: Date().addingTimeInterval(86400),
                unit: "%",
                isIdle: true
            )
        }

        var accountInfo = orgHeader ?? organizationId
        if accountInfo == nil || accountInfo?.isEmpty == true {
            accountInfo = modelCount > 0 ? (isZh ? "OpenAI (可用模型: \(modelCount)个)" : "OpenAI (\(modelCount) models available)") : "OpenAI API"
        }

        return (primaryWindow, secondaryWindow, accountInfo)
    }

    /// Parse duration strings like "20ms", "500ms", "1s", "1m30s", "2m0s", "1h"
    public func parseDurationString(_ str: String) -> TimeInterval {
        let clean = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return 1.0 }

        if clean.hasSuffix("ms") {
            let numStr = clean.replacingOccurrences(of: "ms", with: "")
            if let ms = Double(numStr) {
                return max(0.1, ms / 1000.0)
            }
        }

        var totalSeconds: TimeInterval = 0.0
        var currentNumber = ""

        for char in clean {
            if char.isNumber || char == "." {
                currentNumber.append(char)
            } else if char == "h" {
                if let val = Double(currentNumber) {
                    totalSeconds += val * 3600
                }
                currentNumber = ""
            } else if char == "m" && !clean.contains("ms") {
                if let val = Double(currentNumber) {
                    totalSeconds += val * 60
                }
                currentNumber = ""
            } else if char == "s" {
                if let val = Double(currentNumber) {
                    totalSeconds += val
                }
                currentNumber = ""
            }
        }

        if totalSeconds > 0 {
            return totalSeconds
        }

        // Fallback: parse direct double
        if let direct = Double(clean) {
            return direct
        }

        return 1.0
    }
}
