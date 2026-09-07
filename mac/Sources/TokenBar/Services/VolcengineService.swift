import Foundation

public final class VolcengineService: @unchecked Sendable {
    public static let shared = VolcengineService()

    public init() {}

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

        var baseEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseEndpoint.isEmpty {
            baseEndpoint = "https://ark.cn-beijing.volces.com/api/v3"
        }
        while baseEndpoint.hasSuffix("/") {
            baseEndpoint.removeLast()
        }

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

        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        if httpResp.statusCode == 401 {
            throw NSError(domain: "VolcengineService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "火山方舟 API Key 无效或未授权 (HTTP 401)" : "Volcengine Ark API Key is invalid or unauthorized (HTTP 401)"])
        }

        if httpResp.statusCode == 429 {
            throw NSError(domain: "VolcengineService", code: 429, userInfo: [NSLocalizedDescriptionKey: isZh ? "火山方舟并发或速率超限 (HTTP 429)" : "Volcengine Ark concurrency or rate limit exceeded (HTTP 429)"])
        }

        guard httpResp.statusCode >= 200 && httpResp.statusCode < 300 else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            throw NSError(domain: "VolcengineService", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: isZh ? "火山方舟响应异常 (\(httpResp.statusCode)): \(msg.prefix(100))" : "Volcengine Ark response error (\(httpResp.statusCode)): \(msg.prefix(100))"])
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
        let secondaryWindow: TokenWindow? = nil

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

        var modelCount = 0
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataArr = json["data"] as? [[String: Any]] {
            modelCount = dataArr.count
        }

        if primaryWindow == nil {
            primaryWindow = TokenWindow(
                title: "接入点连接正常",
                usedPercentage: 0.0,
                startTime: Date(),
                endTime: Date().addingTimeInterval(86400),
                unit: "%",
                isIdle: true
            )
        }

        let keySuffix = cleanKey.count > 6 ? String(cleanKey.suffix(4)) : cleanKey
        let modelLabel = !model.isEmpty ? model : (isZh ? "模型数: \(modelCount)" : "\(modelCount) models")
        let account = isZh ? "火山方舟 (\(modelLabel) • 尾号 \(keySuffix))" : "Volcengine Ark (\(modelLabel) • ...\(keySuffix))"

        return (primaryWindow, secondaryWindow, account)
    }
}
