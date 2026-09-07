import Foundation

public final class KimiService: @unchecked Sendable {
    public static let shared = KimiService()

    public init() {}

    public func fetchQuota(
        apiKey: String,
        endpoint: String = "https://api.moonshot.cn/v1",
        model: String = "moonshot-v1-8k"
    ) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw NSError(domain: "KimiService", code: 400, userInfo: [NSLocalizedDescriptionKey: "请输入 KIMI / Moonshot API Key"])
        }

        var baseEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseEndpoint.isEmpty {
            baseEndpoint = "https://api.moonshot.cn/v1"
        }
        while baseEndpoint.hasSuffix("/") {
            baseEndpoint.removeLast()
        }

        // 1. Fetch user balance via /users/me/balance
        let balanceString = await fetchBalance(apiKey: cleanKey, baseEndpoint: baseEndpoint)

        // 2. Fetch models and rate limits via GET /models
        let modelsURLStr = baseEndpoint.hasSuffix("/models") ? baseEndpoint : "\(baseEndpoint)/models"
        guard let url = URL(string: modelsURLStr) else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResp.statusCode == 401 {
            throw NSError(domain: "KimiService", code: 401, userInfo: [NSLocalizedDescriptionKey: "KIMI API Key 无效或未授权 (HTTP 401)"])
        }

        if httpResp.statusCode == 429 {
            throw NSError(domain: "KimiService", code: 429, userInfo: [NSLocalizedDescriptionKey: "KIMI 请求并发超限或额度不足 (HTTP 429)"])
        }

        guard httpResp.statusCode >= 200 && httpResp.statusCode < 300 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            throw NSError(domain: "KimiService", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "KIMI 接口响应异常 (\(httpResp.statusCode)): \(msg.prefix(100))"])
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

        let limitTokensStr = getHeader("x-ratelimit-limit-tokens")
        let remainingTokensStr = getHeader("x-ratelimit-remaining-tokens")
        let resetTokensStr = getHeader("x-ratelimit-reset-tokens")

        var primaryWindow: TokenWindow? = nil
        var secondaryWindow: TokenWindow? = nil

        if balanceString != nil {
            secondaryWindow = TokenWindow(
                title: "账户可用余额",
                usedPercentage: 0.0,
                startTime: Date(),
                endTime: Date().addingTimeInterval(30 * 86400),
                unit: "¥",
                isIdle: true
            )
        }

        if let limitTokens = Double(limitTokensStr ?? ""),
           let remainingTokens = Double(remainingTokensStr ?? ""),
           limitTokens > 0 {
            let used = max(0.0, limitTokens - remainingTokens)
            let usedPct = min(max((used / limitTokens) * 100.0, 0.0), 100.0)
            let duration = OpenAIService.shared.parseDurationString(resetTokensStr ?? "1s")
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

        if primaryWindow == nil && secondaryWindow == nil {
            primaryWindow = TokenWindow(
                title: "KIMI 连接正常",
                usedPercentage: 0.0,
                startTime: Date(),
                endTime: Date().addingTimeInterval(86400),
                unit: "%",
                isIdle: true
            )
        }

        let keySuffix = cleanKey.count > 6 ? String(cleanKey.suffix(4)) : cleanKey
        let account = balanceString != nil ? "余额: \(balanceString!)" : "KIMI (尾号 \(keySuffix))"

        return (primaryWindow, secondaryWindow, account)
    }

    private func fetchBalance(apiKey: String, baseEndpoint: String) async -> String? {
        let balanceURLStr = "\(baseEndpoint)/users/me/balance"
        guard let url = URL(string: balanceURLStr) else { return nil }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any] else {
            return nil
        }

        if let available = dataDict["available_balance"] as? Double {
            return String(format: "¥%.2f", available)
        } else if let availableStr = dataDict["available_balance"] as? String {
            return "¥\(availableStr)"
        } else if let cash = dataDict["cash_balance"] as? Double {
            return String(format: "¥%.2f", cash)
        }
        return nil
    }
}
