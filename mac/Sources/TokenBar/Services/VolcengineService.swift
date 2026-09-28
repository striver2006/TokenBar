import Foundation

public final class VolcengineService: @unchecked Sendable {
    public static let shared = VolcengineService()

    public init() {}

    /// 401/429/非2xx 文案（429 固定文案不解析 JSON；失败文案带状态码；snippet 截 100）
    static let errorMessages = ProviderErrorMessages(
        unauthorized: (zh: "火山方舟 API Key 无效或未授权 (HTTP 401)", en: "Volcengine Ark API Key is invalid or unauthorized (HTTP 401)"),
        rateLimited: (zh: "火山方舟并发或速率超限 (HTTP 429)", en: "Volcengine Ark concurrency or rate limit exceeded (HTTP 429)"),
        rateLimitUsesJSONDetail: false,
        snippetLength: 100,
        failure: { code, snippet, isZh in
            isZh ? "火山方舟响应异常 (\(code)): \(snippet)" : "Volcengine Ark response error (\(code)): \(snippet)"
        }
    )

    public func fetchQuota(
        apiKey: String,
        endpoint: String = "https://ark.cn-beijing.volces.com/api/v3",
        model: String = ""
    ) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
            throw NSError(domain: "VolcengineService", code: 400, userInfo: [NSLocalizedDescriptionKey: isZh ? "请输入火山方舟 API Key" : "Please enter Volcengine Ark API Key"])
        }

        let baseEndpoint = normalizeEndpoint(endpoint, fallback: "https://ark.cn-beijing.volces.com/api/v3")

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

        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        try throwForStatus(httpResp, data: data, domain: "VolcengineService", messages: Self.errorMessages)

        var primaryWindow: TokenWindow? = nil
        let secondaryWindow: TokenWindow? = nil

        primaryWindow = RateLimitWindowBuilder.build(
            response: httpResp,
            limitHeader: "x-ratelimit-limit-tokens",
            remainingHeader: "x-ratelimit-remaining-tokens",
            reset: .header("x-ratelimit-reset-tokens", fallback: "1s"),
            title: .tpmRate,
            unit: "tokens"
        )

        var modelCount = 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataArr = json["data"] as? [[String: Any]] {
            modelCount = dataArr.count
        }

        if primaryWindow == nil {
            primaryWindow = TokenWindow.status(title: .connected(subject: "接入点"))
        }

        let keySuffix = keySuffixMask(cleanKey)
        let modelLabel = !model.isEmpty ? model : (isZh ? "模型数: \(modelCount)" : "\(modelCount) models")
        let account = isZh ? "火山方舟 (\(modelLabel) • 尾号 \(keySuffix))" : "Volcengine Ark (\(modelLabel) • ...\(keySuffix))"

        return (primaryWindow, secondaryWindow, account)
    }
}
