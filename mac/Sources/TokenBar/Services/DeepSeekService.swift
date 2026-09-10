import Foundation

public final class DeepSeekService: @unchecked Sendable {
    public static let shared = DeepSeekService()

    public init() {}

    public func fetchQuota(
        apiKey: String,
        endpoint: String = "https://api.deepseek.com/v1",
        model: String = "deepseek-chat",
        balanceAlertThreshold: Double = 10
    ) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        guard !cleanKey.isEmpty else {
            throw NSError(domain: "DeepSeekService", code: 400, userInfo: [NSLocalizedDescriptionKey: isZh ? "请输入 DeepSeek API Key" : "Please enter DeepSeek API Key"])
        }

        var baseEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseEndpoint.isEmpty {
            baseEndpoint = "https://api.deepseek.com/v1"
        }
        while baseEndpoint.hasSuffix("/") {
            baseEndpoint.removeLast()
        }

        // 1. Fetch user balance
        let balance = await fetchBalance(apiKey: cleanKey)
        var balanceString: String? = nil
        if let bal = balance {
            balanceString = String(format: "%@%.2f", bal.currency == "USD" ? "$" : "¥", bal.amount)
        }

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

        let (data, response) = try await HTTPClient.data(for: req)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResp.statusCode == 401 {
            throw NSError(domain: "DeepSeekService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "DeepSeek API Key 无效或未授权 (HTTP 401)" : "DeepSeek API Key is invalid or unauthorized (HTTP 401)"])
        }

        if httpResp.statusCode == 429 {
            throw NSError(domain: "DeepSeekService", code: 429, userInfo: [NSLocalizedDescriptionKey: isZh ? "DeepSeek 请求达到速率限制或额度不足 (HTTP 429)" : "DeepSeek rate limit reached or quota insufficient (HTTP 429)"])
        }

        guard httpResp.statusCode >= 200 && httpResp.statusCode < 300 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            throw NSError(domain: "DeepSeekService", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: isZh ? "DeepSeek 接口异常: \(msg.prefix(100))" : "DeepSeek API error: \(msg.prefix(100))"])
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

        if let bal = balance {
            secondaryWindow = TokenWindow.balance(
                title: "账户可用余额",
                amount: bal.amount,
                currency: bal.currency,
                warningThreshold: balanceAlertThreshold,
                criticalThreshold: balanceAlertThreshold / 2
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
            primaryWindow = TokenWindow.status(title: "DeepSeek 连接正常")
        }

        let keySuffix = cleanKey.count > 6 ? String(cleanKey.suffix(4)) : cleanKey
        let account = balanceString != nil ? (isZh ? "余额: \(balanceString!)" : "Balance: \(balanceString!)") : (isZh ? "已授权 (... \(keySuffix))" : "Authorized (... \(keySuffix))")

        return (primaryWindow, secondaryWindow, account)
    }

    /// 查询 DeepSeek 账户余额，返回 (金额, 币种)；失败返回 nil
    private func fetchBalance(apiKey: String) async -> (amount: Double, currency: String)? {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (data, resp) = try? await HTTPClient.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = json["balance_infos"] as? [[String: Any]],
              let first = infos.first else {
            return nil
        }

        var totalValue: Double? = nil
        if let totalStr = first["total_balance"] as? String {
            totalValue = Double(totalStr)
        } else if let totalNum = first["total_balance"] as? NSNumber {
            totalValue = totalNum.doubleValue
        }
        guard let amount = totalValue else { return nil }

        let currency = (first["currency"] as? String) ?? "CNY"
        return (amount, currency)
    }
}
