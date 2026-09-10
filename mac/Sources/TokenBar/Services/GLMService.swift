import Foundation

public final class GLMService {
    public static let shared = GLMService()

    /// Fetch GLM quota utilizing OpenAI Response protocol and BigModel usage monitor API
    public func fetchQuota(
        apiKey: String,
        endpoint: String = "https://open.bigmodel.cn/api/v1"
    ) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        guard !cleanKey.isEmpty else {
            throw NSError(domain: "GLMService", code: 400, userInfo: [NSLocalizedDescriptionKey: isZh ? "API Key 不能为空" : "API Key cannot be empty"])
        }

        // Normalize OpenAI endpoint and Base Host
        let trimmedEndpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let baseHost: String
        let openAIEndpoint: String

        if trimmedEndpoint.hasSuffix("/api/v1") {
            openAIEndpoint = trimmedEndpoint
            baseHost = String(trimmedEndpoint.dropLast("/api/v1".count))
        } else if trimmedEndpoint.contains("/api/paas/v4") {
            baseHost = trimmedEndpoint.replacingOccurrences(of: "/api/paas/v4", with: "")
            openAIEndpoint = "\(baseHost)/api/v1"
        } else {
            baseHost = trimmedEndpoint
            openAIEndpoint = "\(trimmedEndpoint)/api/v1"
        }

        let keySuffix = cleanKey.count > 6 ? String(cleanKey.suffix(4)) : cleanKey
        let account = "GLM (...  \(keySuffix))"

        // 1. Verify OpenAI Response Protocol via GET /models
        var rateLimitTokensRemaining: Double? = nil
        var rateLimitTokensTotal: Double? = nil
        var rateLimitResetDurationSec: Double? = nil

        if let modelsUrl = URL(string: "\(openAIEndpoint)/models") {
            var openAiReq = URLRequest(url: modelsUrl)
            openAiReq.httpMethod = "GET"
            openAiReq.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
            openAiReq.setValue("application/json", forHTTPHeaderField: "Accept")
            openAiReq.timeoutInterval = 12

            do {
                let (openAiData, openAiResp) = try await HTTPClient.data(for: openAiReq)
                if let httpResp = openAiResp as? HTTPURLResponse {
                    if httpResp.statusCode == 401 || httpResp.statusCode == 403 {
                        throw NSError(domain: "GLMService", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: isZh ? "GLM API Key 无效或未授权" : "GLM API Key is invalid or unauthorized"])
                    }

                    // Check error body in case of 200 with code != 200
                    if let jsonObj = try? JSONSerialization.jsonObject(with: openAiData) as? [String: Any] {
                        if let code = jsonObj["code"] as? Int, code == 1001 {
                            let msg = jsonObj["msg"] as? String ?? (isZh ? "未收到有效 Authorization 参数" : "Valid Authorization parameter not received")
                            throw NSError(domain: "GLMService", code: 1001, userInfo: [NSLocalizedDescriptionKey: isZh ? "身份验证失败: \(msg)" : "Authentication failed: \(msg)"])
                        }
                    }

                    // Extract OpenAI RateLimit headers if available
                    if let rem = httpResp.value(forHTTPHeaderField: "x-ratelimit-remaining-tokens"), let val = Double(rem) {
                        rateLimitTokensRemaining = val
                    }
                    if let tot = httpResp.value(forHTTPHeaderField: "x-ratelimit-limit-tokens"), let val = Double(tot) {
                        rateLimitTokensTotal = val
                    }
                    if let rst = httpResp.value(forHTTPHeaderField: "x-ratelimit-reset-tokens"), let val = RateLimitReset.parse(rst) {
                        rateLimitResetDurationSec = val
                    }
                    if httpResp.statusCode >= 400 {
                        throw NSError(domain: "GLMService", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: isZh ? "GLM 接口返回 HTTP \(httpResp.statusCode)" : "GLM endpoint returned HTTP \(httpResp.statusCode)"])
                    }
                }
            }
            // 以前这里只重抛 401/1001，把 403、超时、DNS、TLS 全部吞掉再走 fallback，
            // 结果是断网也显示绿灯「已连接」。鉴权与网络错误必须上抛，让卡片如实显示错误。
        }

        // 2. Query BigModel Quota & 5-hour limit endpoint
        var fiveHourWindow: TokenWindow? = nil
        var weeklyWindow: TokenWindow? = nil

        if let quotaUrl = URL(string: "\(baseHost)/api/monitor/usage/quota/limit") {
            var quotaReq = URLRequest(url: quotaUrl)
            quotaReq.httpMethod = "GET"
            quotaReq.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
            quotaReq.setValue("application/json", forHTTPHeaderField: "Accept")
            quotaReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) TokenBar/1.0", forHTTPHeaderField: "User-Agent")
            quotaReq.timeoutInterval = 12

            if let (quotaData, quotaResp) = try? await HTTPClient.data(for: quotaReq),
               let httpResp = quotaResp as? HTTPURLResponse, httpResp.statusCode == 200,
               let rootJson = try? JSONSerialization.jsonObject(with: quotaData) as? [String: Any] {

                let limitsArray: [[String: Any]]
                if let dataObj = rootJson["data"] as? [String: Any], let limits = dataObj["limits"] as? [[String: Any]] {
                    limitsArray = limits
                } else if let limits = rootJson["limits"] as? [[String: Any]] {
                    limitsArray = limits
                } else {
                    limitsArray = []
                }

                for item in limitsArray {
                    let type = (item["type"] as? String)?.uppercased() ?? ""
                    let pct = (item["percentage"] as? NSNumber)?.doubleValue
                        ?? (item["utilization"] as? NSNumber)?.doubleValue
                        ?? 0.0

                    // 服务端可能给秒也可能给毫秒，按量级区分（> 1e12 视为毫秒）
                    let resetMs: Double
                    if let raw = (item["nextResetTime"] as? NSNumber)?.doubleValue, raw > 0 {
                        resetMs = raw > 1e12 ? raw : raw * 1000
                    } else {
                        resetMs = Date().addingTimeInterval(5 * 3600).timeIntervalSince1970 * 1000
                    }

                    let resetDate = Date(timeIntervalSince1970: resetMs / 1000.0)
                    let usedTokens = (item["used"] as? NSNumber)?.doubleValue
                    let totalTokens = (item["total"] as? NSNumber)?.doubleValue

                    if type.contains("TOKEN") || type.contains("5H") || type.contains("SESSION") || (fiveHourWindow == nil && !type.contains("WEEK")) {
                        let startTime = resetDate.addingTimeInterval(-5 * 3600)
                        fiveHourWindow = TokenWindow(
                            title: "5小时额度",
                            usedPercentage: pct,
                            startTime: startTime,
                            endTime: resetDate,
                            usedAmount: usedTokens,
                            totalLimit: totalTokens,
                            unit: totalTokens != nil ? "Tokens" : "%"
                        )
                    } else if type.contains("WEEK") || (weeklyWindow == nil && fiveHourWindow != nil) {
                        let startTime = resetDate.addingTimeInterval(-7 * 86400)
                        weeklyWindow = TokenWindow(
                            title: "每周额度",
                            usedPercentage: pct,
                            startTime: startTime,
                            endTime: resetDate,
                            usedAmount: usedTokens,
                            totalLimit: totalTokens,
                            unit: totalTokens != nil ? "Tokens" : "%"
                        )
                    }
                }
            }
        }

        // 3. Fallback：监控接口没有给窗口时，只用 /models 的 rate limit 头构造 5 小时窗口。
        // 拿不到头就退化为状态型窗口；每周额度没有任何数据来源，一律 nil——
        // 以前这里用 usedPct * 0.6 编造过一条每周进度条，对额度监控工具是最坏的一类错误。
        if fiveHourWindow == nil {
            if let remaining = rateLimitTokensRemaining, let total = rateLimitTokensTotal, total > 0 {
                let now = Date()
                let usedPct = max(0.0, min(100.0, (1.0 - (remaining / total)) * 100.0))
                let fiveHourEnd = now.addingTimeInterval(rateLimitResetDurationSec ?? 5 * 3600)
                fiveHourWindow = TokenWindow(
                    title: "5小时额度",
                    usedPercentage: usedPct,
                    startTime: fiveHourEnd.addingTimeInterval(-5 * 3600),
                    endTime: fiveHourEnd,
                    usedAmount: total - remaining,
                    totalLimit: total,
                    unit: "Tokens"
                )
            } else {
                fiveHourWindow = TokenWindow.status(title: "API 连接正常")
            }
        }

        return (fiveHourWindow, weeklyWindow, account)
    }
}
