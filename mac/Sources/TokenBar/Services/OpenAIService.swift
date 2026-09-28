import Foundation

public final class OpenAIService: @unchecked Sendable {
    public static let shared = OpenAIService()

    public init() {}

    /// 401/429/非2xx 文案（唯一 429 解析 JSON detail 且 snippet 截 120 的简单厂商）
    static let errorMessages = ProviderErrorMessages(
        unauthorized: (zh: "OpenAI API Key 无效或已过期 (HTTP 401)", en: "OpenAI API Key is invalid or expired (HTTP 401)"),
        rateLimited: (zh: "请求过于频繁或额度已耗尽 (HTTP 429)", en: "Rate limit reached or quota exhausted (HTTP 429)"),
        rateLimitUsesJSONDetail: true,
        snippetLength: 120,
        failure: { code, snippet, isZh in
            isZh ? "OpenAI 接口请求失败 (\(code)): \(snippet)" : "OpenAI request failed (\(code)): \(snippet)"
        }
    )

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

        let baseEndpoint = normalizeEndpoint(endpoint, fallback: "https://api.openai.com/v1")
        let targetURLString = modelsURLString(base: baseEndpoint)

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
        try throwForStatus(httpResp, data: data, domain: "OpenAIService", messages: Self.errorMessages)

        let orgHeader = httpResp.value(forHTTPHeaderField: "openai-organization")

        // 1. Tokens Rate Limit Window (TPM)
        let primaryWindow = RateLimitWindowBuilder.build(
            response: httpResp,
            limitHeader: "x-ratelimit-limit-tokens",
            remainingHeader: "x-ratelimit-remaining-tokens",
            reset: .header("x-ratelimit-reset-tokens", fallback: "1s"),
            title: .tpmRemaining,
            unit: "tokens"
        )

        // 2. Requests Rate Limit Window (RPM)
        let secondaryWindow = RateLimitWindowBuilder.build(
            response: httpResp,
            limitHeader: "x-ratelimit-limit-requests",
            remainingHeader: "x-ratelimit-remaining-requests",
            reset: .header("x-ratelimit-reset-requests", fallback: "1s"),
            title: .rpmRequest,
            unit: "req"
        )

        // If no rate limit headers are exposed by the gateway, show connected status
        var modelCount = 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataArr = json["data"] as? [[String: Any]] {
            modelCount = dataArr.count
        }

        var resolvedPrimary = primaryWindow
        if resolvedPrimary == nil {
            resolvedPrimary = TokenWindow.status(title: .connected())
        }

        var accountInfo = orgHeader ?? organizationId
        if accountInfo == nil || accountInfo?.isEmpty == true {
            accountInfo = modelCount > 0 ? (isZh ? "OpenAI (可用模型: \(modelCount)个)" : "OpenAI (\(modelCount) models available)") : "OpenAI API"
        }

        return (resolvedPrimary, secondaryWindow, accountInfo)
    }

    /// 兼容旧调用：委托给 `RateLimitReset.parseOrDefault`（无法解析按 1 秒兜底，最小 0.1 秒）。
    public func parseDurationString(_ str: String) -> TimeInterval {
        RateLimitReset.parseOrDefault(str)
    }
}
