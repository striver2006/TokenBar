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
        var planAccountInfo: String? = nil
        var balanceWindow: TokenWindow? = nil
        var planWindow: TokenWindow? = nil

        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        let balanceThreshold = config.balanceAlertThreshold ?? 10

        func useBalance(title: String, amount: Double, currency: String, formatted: String) {
            balanceAccountInfo = isZh ? "余额: \(formatted)" : "Balance: \(formatted)"
            balanceWindow = TokenWindow.balance(
                title: title,
                amount: amount,
                currency: currency,
                warningThreshold: balanceThreshold,
                criticalThreshold: balanceThreshold / 2
            )
        }

        if endpoint.contains("deepseek.com") {
            if let balance = await fetchDeepSeekBalance(apiKey: apiKey) {
                useBalance(
                    title: "账户余额",
                    amount: balance.amount,
                    currency: balance.currency,
                    formatted: String(format: "%@%.2f", balance.currency == "USD" ? "$" : "¥", balance.amount)
                )
            }
        } else if endpoint.contains("moonshot.cn") {
            if let balance = await fetchMoonshotBalance(apiKey: apiKey) {
                useBalance(title: "账户余额", amount: balance, currency: "CNY", formatted: String(format: "¥%.2f", balance))
            }
        } else if endpoint.contains("siliconflow.cn") {
            if let balance = await fetchSiliconFlowBalance(apiKey: apiKey) {
                useBalance(title: "账户余额", amount: balance, currency: "CNY", formatted: String(format: "¥%.2f", balance))
            }
        } else if endpoint.contains("xiaomimimo.com") {
            // 小米 MiMo：按量余额与 Token Plan 套餐用量都只接受控制台 Cookie；
            // 填了 Cookie 即自动开通两条通道，未填时保持纯 API Key 行为不变。
            let cookie = config.consoleCookie.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cookie.isEmpty {
                if let plan = await fetchMiMoTokenPlan(cookie: cookie) {
                    planWindow = TokenWindow(
                        title: "Token Plan 额度",
                        usedPercentage: plan.usedPercent,
                        startTime: Date(),
                        endTime: Date().addingTimeInterval(30 * 86400),
                        usedAmount: plan.used,
                        totalLimit: plan.limit,
                        unit: "credits",
                        isIdle: plan.usedPercent <= 0
                    )
                    planAccountInfo = isZh
                        ? String(format: "套餐已用 %.1f%%", plan.usedPercent)
                        : String(format: "Plan used %.1f%%", plan.usedPercent)
                }

                if let balance = await fetchMiMoBalance(cookie: cookie) {
                    useBalance(
                        title: "账户余额",
                        amount: balance.amount,
                        currency: balance.currency,
                        formatted: String(format: "%@%.2f", balance.currency == "USD" ? "$" : "¥", balance.amount)
                    )
                }
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

        // 槽位优先级：订阅窗口（Token Plan 百分比）> 余额（金额）> 速率头
        var primaryWindow: TokenWindow? = planWindow ?? balanceWindow
        var secondaryWindow: TokenWindow? = planWindow != nil ? balanceWindow : nil

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
            } else if secondaryWindow == nil {
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

        let combinedInfo: String?
        if let plan = planAccountInfo, let bal = balanceAccountInfo {
            combinedInfo = "\(plan) · \(bal)"
        } else {
            combinedInfo = planAccountInfo ?? balanceAccountInfo
        }
        let account = combinedInfo ?? (modelCount > 0 ? (isZh ? "可用模型: \(modelCount)个" : "\(modelCount) models available") : (isZh ? "已连接" : "Connected"))
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

    // MARK: - Xiaomi MiMo Console (Cookie-only APIs)

    /// 查询小米 MiMo 按量余额（仅接受控制台 Cookie），失败返回 nil
    private func fetchMiMoBalance(cookie: String) async -> (amount: Double, currency: String)? {
        guard let url = URL(string: "https://platform.xiaomimimo.com/api/v1/balance") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("TokenBar/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let code = json["code"] as? Int, code != 0 { return nil }
        guard let dataDict = json["data"] as? [String: Any] else { return nil }

        var amount: Double? = nil
        if let balNum = (dataDict["balance"] as? NSNumber)?.doubleValue {
            amount = balNum
        } else if let balStr = dataDict["balance"] as? String {
            amount = Double(balStr)
        }
        guard let balance = amount else { return nil }
        let currency = (dataDict["currency"] as? String) ?? "CNY"
        return (balance, currency.isEmpty ? "CNY" : currency)
    }

    /// 查询小米 MiMo Token Plan 套餐用量（仅接受控制台 Cookie）。
    /// data.usage.items[] 优先取 plan_total_token，缺失取第一条；失败返回 nil。
    private func fetchMiMoTokenPlan(cookie: String) async -> (usedPercent: Double, used: Double, limit: Double)? {
        guard let url = URL(string: "https://platform.xiaomimimo.com/api/v1/tokenPlan/usage") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue("TokenBar/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let code = json["code"] as? Int, code != 0 { return nil }
        guard let dataDict = json["data"] as? [String: Any],
              let usage = dataDict["usage"] as? [String: Any],
              let items = usage["items"] as? [[String: Any]],
              !items.isEmpty else {
            return nil
        }

        let chosen = items.first { ($0["name"] as? String) == "plan_total_token" } ?? items.first
        guard let item = chosen else { return nil }

        func asDouble(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }

        let limit = asDouble(item["limit"]) ?? 0
        let used = asDouble(item["used"]) ?? 0
        let percent: Double
        if let p = asDouble(item["percent"]) {
            percent = p
        } else if limit > 0 {
            percent = used / limit * 100.0
        } else {
            return nil
        }

        return (min(max(percent, 0.0), 100.0), used, limit)
    }

    // MARK: - Vendor Specific Balance Probing
    private func fetchDeepSeekBalance(apiKey: String) async -> (amount: Double, currency: String)? {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
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

    private func fetchMoonshotBalance(apiKey: String) async -> Double? {
        guard let url = URL(string: "https://api.moonshot.cn/v1/users/me/balance") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else {
            return nil
        }
        if let available = (dataObj["available_balance"] as? NSNumber)?.doubleValue {
            return available
        }
        if let availableStr = dataObj["available_balance"] as? String, let parsed = Double(availableStr) {
            return parsed
        }
        return nil
    }

    private func fetchSiliconFlowBalance(apiKey: String) async -> Double? {
        guard let url = URL(string: "https://api.siliconflow.cn/v1/user/info") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else {
            return nil
        }
        if let balanceStr = dataObj["balance"] as? String, let parsed = Double(balanceStr) {
            return parsed
        }
        if let balanceNum = (dataObj["balance"] as? NSNumber)?.doubleValue {
            return balanceNum
        }
        return nil
    }
}
