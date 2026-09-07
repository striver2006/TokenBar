import Foundation

public final class CustomProviderService: @unchecked Sendable {
    public static let shared = CustomProviderService()

    public init() {}

    /// Fetch quota, rate limits, or balance for a custom/domestic provider
    public func fetchQuota(config: CustomProviderConfig) async throws -> (primary: TokenWindow?, secondary: TokenWindow?, account: String?) {
        let trimmedKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
            throw NSError(
                domain: "CustomProviderService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: isZh ? "请在配置中填入 \(config.name) 的 API KEY" : "Please enter the API KEY for \(config.name)"]
            )
        }

        var endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.isEmpty {
            endpoint = config.apiProtocol == .anthropic ? "https://api.anthropic.com/v1" : "https://api.deepseek.com/v1"
        }
        while endpoint.hasSuffix("/") {
            endpoint.removeLast()
        }

        switch config.apiProtocol {
        case .openAIChat:
            return try await fetchOpenAICompatible(apiKey: trimmedKey, endpoint: endpoint, config: config, isResponseProtocol: false)
        case .openAIResponses:
            return try await fetchOpenAICompatible(apiKey: trimmedKey, endpoint: endpoint, config: config, isResponseProtocol: true)
        case .anthropic:
            return try await fetchAnthropicCompatible(apiKey: trimmedKey, endpoint: endpoint, config: config)
        }
    }

    // MARK: - OpenAI-Compatible Protocol Handler
    private func fetchOpenAICompatible(
        apiKey: String,
        endpoint: String,
        config: CustomProviderConfig,
        isResponseProtocol: Bool = false
    ) async throws -> (primary: TokenWindow?, secondary: TokenWindow?, account: String?) {
        // 1. Check for vendor-specific balance API first if applicable
        var balanceAccountInfo: String? = nil
        var balanceWindow: TokenWindow? = nil

        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        if endpoint.contains("deepseek.com") {
            if let balance = await fetchDeepSeekBalance(apiKey: apiKey) {
                balanceAccountInfo = isZh ? "余额: \(balance)" : "Balance: \(balance)"
                balanceWindow = TokenWindow(
                    title: "账户余额",
                    usedPercentage: 0.0,
                    startTime: Date(),
                    endTime: Date().addingTimeInterval(30 * 86400),
                    unit: "¥",
                    isIdle: true
                )
            }
        } else if endpoint.contains("moonshot.cn") {
            if let balance = await fetchMoonshotBalance(apiKey: apiKey) {
                balanceAccountInfo = isZh ? "余额: \(balance)" : "Balance: \(balance)"
                balanceWindow = TokenWindow(
                    title: "账户余额",
                    usedPercentage: 0.0,
                    startTime: Date(),
                    endTime: Date().addingTimeInterval(30 * 86400),
                    unit: "¥",
                    isIdle: true
                )
            }
        } else if endpoint.contains("siliconflow.cn") {
            if let balance = await fetchSiliconFlowBalance(apiKey: apiKey) {
                balanceAccountInfo = isZh ? "余额: \(balance)" : "Balance: \(balance)"
                balanceWindow = TokenWindow(
                    title: "账户余额",
                    usedPercentage: 0.0,
                    startTime: Date(),
                    endTime: Date().addingTimeInterval(30 * 86400),
                    unit: "¥",
                    isIdle: true
                )
            }
        }

        // 2. Request /models to test connectivity and retrieve rate limits
        let modelsURLString = endpoint.hasSuffix("/models") ? endpoint : "\(endpoint)/models"
        guard let url = URL(string: modelsURLString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResp.statusCode == 401 {
            throw NSError(
                domain: "CustomProviderService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: isZh ? "\(config.name) API Key 认证失败 (HTTP 401)，请核对密钥" : "\(config.name) API Key authentication failed (HTTP 401). Please check the key"]
            )
        }

        if httpResp.statusCode == 429 {
            var msg = isZh ? "请求过于频繁或额度不足 (HTTP 429)" : "Rate limit reached or quota insufficient (HTTP 429)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let detail = err["message"] as? String {
                msg = detail
            }
            throw NSError(domain: "CustomProviderService", code: 429, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        guard httpResp.statusCode >= 200 && httpResp.statusCode < 300 else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            throw NSError(
                domain: "CustomProviderService",
                code: httpResp.statusCode,
                userInfo: [NSLocalizedDescriptionKey: isZh ? "请求端点失败 (\(httpResp.statusCode)): \(errorText.prefix(100))" : "Endpoint request failed (\(httpResp.statusCode)): \(errorText.prefix(100))"]
            )
        }

        // Inspect headers for rate limits
        let allHeaders = httpResp.allHeaderFields
        func getHeader(_ name: String) -> String? {
            let lower = name.lowercased()
            for (k, v) in allHeaders {
                if let key = k as? String, key.lowercased() == lower {
                    return String(describing: v)
                }
            }
            return nil
        }

        let limitTokensStr = getHeader("x-ratelimit-limit-tokens")
        let remainingTokensStr = getHeader("x-ratelimit-remaining-tokens")
        let resetTokensStr = getHeader("x-ratelimit-reset-tokens")

        var primaryWindow: TokenWindow? = balanceWindow
        var secondaryWindow: TokenWindow? = nil

        if let limitTokens = Double(limitTokensStr ?? ""),
           let remainingTokens = Double(remainingTokensStr ?? ""),
           limitTokens > 0 {
            let used = max(0.0, limitTokens - remainingTokens)
            let usedPct = min(max((used / limitTokens) * 100.0, 0.0), 100.0)
            let duration = OpenAIService.shared.parseDurationString(resetTokensStr ?? "1s")
            let now = Date()

            let rateWindow = TokenWindow(
                title: "TPM 速率配额",
                usedPercentage: usedPct,
                startTime: now,
                endTime: now.addingTimeInterval(duration),
                usedAmount: used,
                totalLimit: limitTokens,
                unit: "tokens",
                isIdle: used == 0.0
            )

            if primaryWindow == nil {
                primaryWindow = rateWindow
            } else {
                secondaryWindow = rateWindow
            }
        }

        var modelCount = 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataArr = json["data"] as? [[String: Any]] {
            modelCount = dataArr.count
        }

        if primaryWindow == nil {
            primaryWindow = TokenWindow(
                title: "接口连接正常",
                usedPercentage: 0.0,
                startTime: Date(),
                endTime: Date().addingTimeInterval(86400),
                unit: "%",
                isIdle: true
            )
        }

        let account = balanceAccountInfo ?? (modelCount > 0 ? (isZh ? "可用模型: \(modelCount)个" : "\(modelCount) models available") : (isZh ? "已连接" : "Connected"))
        return (primaryWindow, secondaryWindow, account)
    }

    // MARK: - Anthropic-Compatible Protocol Handler
    private func fetchAnthropicCompatible(
        apiKey: String,
        endpoint: String,
        config: CustomProviderConfig
    ) async throws -> (primary: TokenWindow?, secondary: TokenWindow?, account: String?) {
        let modelsURLString = endpoint.hasSuffix("/models") ? endpoint : "\(endpoint)/models"
        guard let url = URL(string: modelsURLString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        if httpResp.statusCode == 401 {
            throw NSError(
                domain: "CustomProviderService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: isZh ? "\(config.name) Anthropic API Key 无效或未授权 (HTTP 401)" : "\(config.name) Anthropic API Key invalid or unauthorized (HTTP 401)"]
            )
        }

        if httpResp.statusCode == 429 {
            var msg = isZh ? "Anthropic 接口请求已触发速率限制 (HTTP 429)" : "Anthropic rate limit exceeded (HTTP 429)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let detail = err["message"] as? String {
                msg = detail
            }
            throw NSError(domain: "CustomProviderService", code: 429, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        guard httpResp.statusCode >= 200 && httpResp.statusCode < 300 else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            throw NSError(
                domain: "CustomProviderService",
                code: httpResp.statusCode,
                userInfo: [NSLocalizedDescriptionKey: isZh ? "Anthropic 兼容端点响应异常 (\(httpResp.statusCode)): \(errorText.prefix(100))" : "Anthropic compatible endpoint error (\(httpResp.statusCode)): \(errorText.prefix(100))"]
            )
        }

        let allHeaders = httpResp.allHeaderFields
        func getHeader(_ name: String) -> String? {
            let lower = name.lowercased()
            for (k, v) in allHeaders {
                if let key = k as? String, key.lowercased() == lower {
                    return String(describing: v)
                }
            }
            return nil
        }

        let tokenLimitStr = getHeader("anthropic-ratelimit-tokens-limit")
        let tokenRemainingStr = getHeader("anthropic-ratelimit-tokens-remaining")
        let tokenResetStr = getHeader("anthropic-ratelimit-tokens-reset")

        let reqLimitStr = getHeader("anthropic-ratelimit-requests-limit")
        let reqRemainingStr = getHeader("anthropic-ratelimit-requests-remaining")

        var primaryWindow: TokenWindow? = nil
        var secondaryWindow: TokenWindow? = nil

        if let limit = Double(tokenLimitStr ?? ""),
           let remaining = Double(tokenRemainingStr ?? ""),
           limit > 0 {
            let used = max(0.0, limit - remaining)
            let usedPct = min(max((used / limit) * 100.0, 0.0), 100.0)
            let duration = OpenAIService.shared.parseDurationString(tokenResetStr ?? "1s")
            let now = Date()

            primaryWindow = TokenWindow(
                title: "Token 速率配额",
                usedPercentage: usedPct,
                startTime: now,
                endTime: now.addingTimeInterval(duration),
                usedAmount: used,
                totalLimit: limit,
                unit: "tokens",
                isIdle: used == 0.0
            )
        }

        if let reqLimit = Double(reqLimitStr ?? ""),
           let reqRemaining = Double(reqRemainingStr ?? ""),
           reqLimit > 0 {
            let used = max(0.0, reqLimit - reqRemaining)
            let usedPct = min(max((used / reqLimit) * 100.0, 0.0), 100.0)

            secondaryWindow = TokenWindow(
                title: "RPM 速率配额",
                usedPercentage: usedPct,
                startTime: Date(),
                endTime: Date().addingTimeInterval(60),
                usedAmount: used,
                totalLimit: reqLimit,
                unit: "req",
                isIdle: used == 0.0
            )
        }

        var modelCount = 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataArr = json["data"] as? [[String: Any]] {
            modelCount = dataArr.count
        }

        if primaryWindow == nil {
            primaryWindow = TokenWindow(
                title: "Anthropic 协议连接正常",
                usedPercentage: 0.0,
                startTime: Date(),
                endTime: Date().addingTimeInterval(86400),
                unit: "%",
                isIdle: true
            )
        }

        let account = modelCount > 0 ? (isZh ? "已接入 (模型数: \(modelCount))" : "Connected (\(modelCount) models)") : (isZh ? "Anthropic 兼容协议" : "Anthropic Compatible Protocol")
        return (primaryWindow, secondaryWindow, account)
    }

    // MARK: - Vendor Specific Balance Probing
    private func fetchDeepSeekBalance(apiKey: String) async -> String? {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = json["balance_infos"] as? [[String: Any]],
              let first = infos.first,
              let balance = first["total_balance"] as? String else {
            return nil
        }
        let currency = (first["currency"] as? String) ?? "CNY"
        return "\(currency == "CNY" ? "¥" : "$")\(balance)"
    }

    private func fetchMoonshotBalance(apiKey: String) async -> String? {
        guard let url = URL(string: "https://api.moonshot.cn/v1/users/me/balance") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let available = (dataObj["available_balance"] as? NSNumber)?.doubleValue else {
            return nil
        }
        return String(format: "¥%.2f", available)
    }

    private func fetchSiliconFlowBalance(apiKey: String) async -> String? {
        guard let url = URL(string: "https://api.siliconflow.cn/v1/user/info") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let balance = dataObj["balance"] as? String else {
            return nil
        }
        return "¥\(balance)"
    }
}
