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

        let fallbackEndpoint = config.apiProtocol == .anthropic ? "https://api.anthropic.com/v1" : "https://api.deepseek.com/v1"
        let endpoint = normalizeEndpoint(config.endpoint, fallback: fallbackEndpoint)

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

        func useBalance(title: WindowTitle, amount: Double, currency: String, formatted: String) {
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
            if let balance = await ProviderBalance.fetchDeepSeekBalance(apiKey: apiKey) {
                useBalance(
                    title: .accountBalance,
                    amount: balance.amount,
                    currency: balance.currency,
                    formatted: String(format: "%@%.2f", balance.currency == "USD" ? "$" : "¥", balance.amount)
                )
            }
        } else if endpoint.contains("moonshot.cn") {
            if let balance = await ProviderBalance.fetchMoonshotBalance(apiKey: apiKey, balanceURL: "https://api.moonshot.cn/v1/users/me/balance", fallbackToCashBalance: false) {
                useBalance(title: .accountBalance, amount: balance, currency: "CNY", formatted: String(format: "¥%.2f", balance))
            }
        } else if endpoint.contains("siliconflow.cn") {
            if let balance = await fetchSiliconFlowBalance(apiKey: apiKey) {
                useBalance(title: .accountBalance, amount: balance, currency: "CNY", formatted: String(format: "¥%.2f", balance))
            }
        } else if endpoint.contains("xiaomimimo.com") {
            // 小米 MiMo：按量余额与 Token Plan 套餐用量都只接受控制台 Cookie；
            // 填了 Cookie 即自动开通两条通道，未填时保持纯 API Key 行为不变。
            let cookie = config.consoleCookie.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cookie.isEmpty {
                // 两个 Cookie 请求并发：串行最坏 10+10+10(/models)=30s，超出 25s 刷新预算
                // 会整卡误报「刷新超时」（对齐 KimiService.fetchCodingSubscription 的做法）。
                async let planTask = fetchMiMoTokenPlan(cookie: cookie)
                async let balanceTask = fetchMiMoBalance(cookie: cookie)

                if let plan = await planTask {
                    planWindow = TokenWindow(
                        title: .tokenPlan,
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

                if let balance = await balanceTask {
                    useBalance(
                        title: .accountBalance,
                        amount: balance.amount,
                        currency: balance.currency,
                        formatted: String(format: "%@%.2f", balance.currency == "USD" ? "$" : "¥", balance.amount)
                    )
                }
            }
        }

        // 2. Request /models to test connectivity and retrieve rate limits
        let modelsURLStr = modelsURLString(base: endpoint)
        guard let url = URL(string: modelsURLStr) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await HTTPClient.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        try throwForStatus(
            httpResp,
            data: data,
            domain: "CustomProviderService",
            messages: ProviderErrorMessages(
                unauthorized: (zh: "\(config.name) API Key 认证失败 (HTTP 401)，请核对密钥", en: "\(config.name) API Key authentication failed (HTTP 401). Please check the key"),
                rateLimited: (zh: "请求过于频繁或额度不足 (HTTP 429)", en: "Rate limit reached or quota insufficient (HTTP 429)"),
                rateLimitUsesJSONDetail: true,
                snippetLength: 100,
                failure: { code, snippet, isZh in
                    isZh ? "请求端点失败 (\(code)): \(snippet)" : "Endpoint request failed (\(code)): \(snippet)"
                }
            )
        )

        // 槽位优先级：订阅窗口（Token Plan 百分比）> 余额（金额）> 速率头
        var primaryWindow: TokenWindow? = planWindow ?? balanceWindow
        var secondaryWindow: TokenWindow? = planWindow != nil ? balanceWindow : nil

        if let rateWindow = RateLimitWindowBuilder.build(
            response: httpResp,
            limitHeader: "x-ratelimit-limit-tokens",
            remainingHeader: "x-ratelimit-remaining-tokens",
            reset: .header("x-ratelimit-reset-tokens", fallback: "1s"),
            title: .tpmRate,
            unit: "tokens"
        ) {
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
            primaryWindow = TokenWindow.status(title: .connected(subject: "接口"))
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
        let modelsURLStr = modelsURLString(base: endpoint)
        guard let url = URL(string: modelsURLStr) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let (data, response) = try await HTTPClient.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        try throwForStatus(
            httpResp,
            data: data,
            domain: "CustomProviderService",
            messages: ProviderErrorMessages(
                unauthorized: (zh: "\(config.name) Anthropic API Key 无效或未授权 (HTTP 401)", en: "\(config.name) Anthropic API Key invalid or unauthorized (HTTP 401)"),
                rateLimited: (zh: "Anthropic 接口请求已触发速率限制 (HTTP 429)", en: "Anthropic rate limit exceeded (HTTP 429)"),
                rateLimitUsesJSONDetail: true,
                snippetLength: 100,
                failure: { code, snippet, isZh in
                    isZh ? "Anthropic 兼容端点响应异常 (\(code)): \(snippet)" : "Anthropic compatible endpoint error (\(code)): \(snippet)"
                }
            )
        )

        var primaryWindow: TokenWindow? = nil
        var secondaryWindow: TokenWindow? = nil

        primaryWindow = RateLimitWindowBuilder.build(
            response: httpResp,
            limitHeader: "anthropic-ratelimit-tokens-limit",
            remainingHeader: "anthropic-ratelimit-tokens-remaining",
            reset: .header("anthropic-ratelimit-tokens-reset", fallback: "1s"),
            title: .tokenRate,
            unit: "tokens"
        )

        secondaryWindow = RateLimitWindowBuilder.build(
            response: httpResp,
            limitHeader: "anthropic-ratelimit-requests-limit",
            remainingHeader: "anthropic-ratelimit-requests-remaining",
            reset: .fixed(60),
            title: .rpmRate,
            unit: "req"
        )

        var modelCount = 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataArr = json["data"] as? [[String: Any]] {
            modelCount = dataArr.count
        }

        if primaryWindow == nil {
            primaryWindow = TokenWindow.status(title: .connected(subject: "Anthropic 协议"))
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
        guard let (data, resp) = try? await HTTPClient.data(for: req),
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
        guard let (data, resp) = try? await HTTPClient.data(for: req),
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
    // DeepSeek / Moonshot 余额查询已收敛到 ProviderBalance（ProviderShared.swift）

    private func fetchSiliconFlowBalance(apiKey: String) async -> Double? {
        guard let url = URL(string: "https://api.siliconflow.cn/v1/user/info") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (data, resp) = try? await HTTPClient.data(for: req),
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
