import Foundation

public final class DeepSeekService: @unchecked Sendable {
    public static let shared = DeepSeekService()

    public init() {}

    /// 401/429/非2xx 文案（429 固定文案不解析 JSON；失败文案不带状态码；snippet 截 100）
    static let errorMessages = ProviderErrorMessages(
        unauthorized: (zh: "DeepSeek API Key 无效或未授权 (HTTP 401)", en: "DeepSeek API Key is invalid or unauthorized (HTTP 401)"),
        rateLimited: (zh: "DeepSeek 请求达到速率限制或额度不足 (HTTP 429)", en: "DeepSeek rate limit reached or quota insufficient (HTTP 429)"),
        rateLimitUsesJSONDetail: false,
        snippetLength: 100,
        failure: { _, snippet, isZh in
            isZh ? "DeepSeek 接口异常: \(snippet)" : "DeepSeek API error: \(snippet)"
        }
    )

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

        let baseEndpoint = normalizeEndpoint(endpoint, fallback: "https://api.deepseek.com/v1")

        // 1. Fetch user balance
        let balance = await ProviderBalance.fetchDeepSeekBalance(apiKey: cleanKey)
        var balanceString: String? = nil
        if let bal = balance {
            balanceString = String(format: "%@%.2f", bal.currency == "USD" ? "$" : "¥", bal.amount)
        }

        // 2. Fetch models and rate limits via GET /models
        let modelsURLStr = modelsURLString(base: baseEndpoint)
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

        try throwForStatus(httpResp, data: data, domain: "DeepSeekService", messages: Self.errorMessages)

        var primaryWindow: TokenWindow? = nil
        var secondaryWindow: TokenWindow? = nil

        if let bal = balance {
            secondaryWindow = TokenWindow.balance(
                title: .accountAvailableBalance,
                amount: bal.amount,
                currency: bal.currency,
                warningThreshold: balanceAlertThreshold,
                criticalThreshold: balanceAlertThreshold / 2
            )
        }

        primaryWindow = RateLimitWindowBuilder.build(
            response: httpResp,
            limitHeader: "x-ratelimit-limit-tokens",
            remainingHeader: "x-ratelimit-remaining-tokens",
            reset: .header("x-ratelimit-reset-tokens", fallback: "1s"),
            title: .tpmRate,
            unit: "tokens"
        )

        if primaryWindow == nil && secondaryWindow == nil {
            primaryWindow = TokenWindow.status(title: .connected(subject: "DeepSeek"))
        }

        let keySuffix = keySuffixMask(cleanKey)
        let account = balanceString != nil ? (isZh ? "余额: \(balanceString!)" : "Balance: \(balanceString!)") : (isZh ? "已授权 (... \(keySuffix))" : "Authorized (... \(keySuffix))")

        return (primaryWindow, secondaryWindow, account)
    }
}
