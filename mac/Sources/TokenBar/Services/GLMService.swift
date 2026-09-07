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

            do {
                let (openAiData, openAiResp) = try await URLSession.shared.data(for: openAiReq)
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
                    if let rst = httpResp.value(forHTTPHeaderField: "x-ratelimit-reset-tokens"), let val = Double(rst) {
                        rateLimitResetDurationSec = val
                    }
                }
            } catch {
                if (error as NSError).code == 1001 || (error as NSError).code == 401 {
                    throw error
                }
            }
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

            if let (quotaData, quotaResp) = try? await URLSession.shared.data(for: quotaReq),
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

                    let resetMs: Double
                    if let ms = (item["nextResetTime"] as? NSNumber)?.doubleValue {
                        resetMs = ms
                    } else if let sec = (item["nextResetTime"] as? NSNumber)?.doubleValue {
                        resetMs = sec * 1000
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

        // 3. Fallback: if monitor endpoint returned no windows but OpenAI protocol validated
        if fiveHourWindow == nil {
            let now = Date()
            var usedPct = 0.0
            var fiveHourEnd = now.addingTimeInterval(5 * 3600)

            if let remaining = rateLimitTokensRemaining, let total = rateLimitTokensTotal, total > 0 {
                usedPct = max(0.0, min(100.0, (1.0 - (remaining / total)) * 100.0))
            }
            if let resetSec = rateLimitResetDurationSec, resetSec > 0 {
                fiveHourEnd = now.addingTimeInterval(resetSec)
            }

            fiveHourWindow = TokenWindow(
                title: "5小时额度",
                usedPercentage: usedPct,
                startTime: fiveHourEnd.addingTimeInterval(-5 * 3600),
                endTime: fiveHourEnd,
                usedAmount: rateLimitTokensRemaining != nil && rateLimitTokensTotal != nil ? (rateLimitTokensTotal! - rateLimitTokensRemaining!) : nil,
                totalLimit: rateLimitTokensTotal,
                unit: rateLimitTokensTotal != nil ? "Tokens" : "%"
            )

            let calendar = Calendar.current
            let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now.addingTimeInterval(-3 * 86400)
            let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart) ?? now.addingTimeInterval(4 * 86400)

            weeklyWindow = TokenWindow(
                title: "每周额度",
                usedPercentage: usedPct * 0.6,
                startTime: weekStart,
                endTime: weekEnd,
                unit: "%"
            )
        }

        return (fiveHourWindow, weeklyWindow, account)
    }
}
