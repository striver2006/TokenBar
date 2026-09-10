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

        let (data, response) = try await HTTPClient.data(for: request)
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
            primaryWindow = TokenWindow.status(title: "API 连接状态")
        }

        var accountInfo = orgHeader ?? organizationId
        if accountInfo == nil || accountInfo?.isEmpty == true {
            accountInfo = modelCount > 0 ? (isZh ? "OpenAI (可用模型: \(modelCount)个)" : "OpenAI (\(modelCount) models available)") : "OpenAI API"
        }

        return (primaryWindow, secondaryWindow, accountInfo)
    }

    /// 兼容旧调用：委托给 `RateLimitReset.parse`，无法解析时按 1 秒兜底，
    /// 最小 0.1 秒（毫秒级重置对倒计时没有意义，沿用旧下限）。
    public func parseDurationString(_ str: String) -> TimeInterval {
        max(0.1, RateLimitReset.parse(str) ?? 1.0)
    }
}
