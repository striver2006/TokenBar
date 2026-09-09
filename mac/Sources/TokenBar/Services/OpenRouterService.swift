import Foundation

/// OpenRouter（LLM 聚合平台，纯按量扣费，美元结算）。
/// 优先 GET /credits 查询账户余额（需 Management Key）；
/// 403/401 权限不足时回退 GET /key：普通 Key 也能拿到自身用量与限额。
public final class OpenRouterService: @unchecked Sendable {
    public static let shared = OpenRouterService()

    public init() {}

    public func fetchQuota(
        apiKey: String,
        endpoint: String = "https://openrouter.ai/api/v1",
        balanceAlertThreshold: Double = 5
    ) async throws -> (primary: TokenWindow?, secondary: TokenWindow?, account: String?) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        guard !cleanKey.isEmpty else {
            throw NSError(domain: "OpenRouterService", code: 400, userInfo: [NSLocalizedDescriptionKey: isZh ? "请输入 OpenRouter API Key" : "Please enter OpenRouter API Key"])
        }

        var baseEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseEndpoint.isEmpty {
            baseEndpoint = "https://openrouter.ai/api/v1"
        }
        while baseEndpoint.hasSuffix("/") {
            baseEndpoint.removeLast()
        }

        // 1. 账户余额（Management Key 专属；普通 Key 会收到 403）
        var accountBalance: Double? = nil
        var creditsUnauthorized = false
        if let url = URL(string: "\(baseEndpoint)/credits") {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 10
            if let (data, resp) = try? await HTTPClient.data(for: req),
               let http = resp as? HTTPURLResponse {
                if http.statusCode == 401 {
                    creditsUnauthorized = true
                } else if (200..<300).contains(http.statusCode),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let dataDict = json["data"] as? [String: Any],
                          let credits = (dataDict["total_credits"] as? NSNumber)?.doubleValue,
                          let usage = (dataDict["total_usage"] as? NSNumber)?.doubleValue {
                    accountBalance = max(0, credits - usage)
                }
            }
        }

        // 2. 当前 Key 的用量与限额（普通 Key 即可访问）
        var keyLabel: String? = nil
        var keyUsage: Double? = nil
        var keyLimit: Double? = nil
        var keyRemaining: Double? = nil
        var keyFetched = false
        var keyAuthFailed = false
        if let url = URL(string: "\(baseEndpoint)/key") {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 10
            if let (data, resp) = try? await HTTPClient.data(for: req),
               let http = resp as? HTTPURLResponse {
                if http.statusCode == 401 || http.statusCode == 403 {
                    keyAuthFailed = true
                } else if (200..<300).contains(http.statusCode),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let dataDict = json["data"] as? [String: Any] {
                    keyFetched = true
                    keyLabel = dataDict["label"] as? String
                    keyUsage = (dataDict["usage"] as? NSNumber)?.doubleValue
                    if let limit = (dataDict["limit"] as? NSNumber)?.doubleValue, limit > 0 {
                        keyLimit = limit
                    }
                    keyRemaining = (dataDict["limit_remaining"] as? NSNumber)?.doubleValue
                }
            }
        }

        if accountBalance == nil && !keyFetched {
            if creditsUnauthorized || keyAuthFailed {
                throw NSError(domain: "OpenRouterService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "OpenRouter API Key 无效或未授权 (HTTP 401/403)" : "OpenRouter API Key is invalid or unauthorized (HTTP 401/403)"])
            }
            throw NSError(domain: "OpenRouterService", code: 502, userInfo: [NSLocalizedDescriptionKey: isZh ? "OpenRouter 接口异常，余额与 Key 信息均不可用" : "OpenRouter API error: neither credits nor key info is available"])
        }

        // 3. 组装窗口：余额为主窗口。OpenRouter 的 Key 上限是累计消费上限
        //    （不按周期重置），无周期语义，故不展示为时间窗口。
        var balanceWindow: TokenWindow? = nil
        if let balance = accountBalance {
            balanceWindow = TokenWindow.balance(
                title: "账户可用余额",
                amount: balance,
                currency: "USD",
                warningThreshold: balanceAlertThreshold,
                criticalThreshold: balanceAlertThreshold / 2
            )
        } else if let limit = keyLimit {
            // 无权限查账户余额，但 Key 有上限：以 Key 剩余额度充当余额展示
            let remaining = max(0, keyRemaining ?? (limit - (keyUsage ?? 0)))
            balanceWindow = TokenWindow.balance(
                title: "Key 可用额度",
                amount: remaining,
                currency: "USD",
                warningThreshold: balanceAlertThreshold,
                criticalThreshold: balanceAlertThreshold / 2
            )
        }

        if balanceWindow == nil {
            balanceWindow = TokenWindow(
                title: "OpenRouter 连接正常",
                usedPercentage: 0.0,
                startTime: Date(),
                endTime: Date().addingTimeInterval(86400),
                unit: "%",
                isIdle: true
            )
        }

        // 4. 卡片头部账号信息
        var account: String
        if let balance = accountBalance {
            account = isZh ? String(format: "余额: $%.2f", balance) : String(format: "Balance: $%.2f", balance)
        } else if let usage = keyUsage {
            let labelPart = keyLabel.map { " · \($0)" } ?? ""
            account = isZh
                ? String(format: "Key 有效%@ (已用 $%.2f)", labelPart, usage)
                : String(format: "Key valid%@ (used $%.2f)", labelPart, usage)
        } else {
            account = isZh ? "Key 有效" : "Key valid"
        }

        return (balanceWindow, nil, account)
    }
}
