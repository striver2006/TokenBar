import Foundation

public final class KimiService: @unchecked Sendable {
    public static let shared = KimiService()

    public init() {}

    /// 401/429/非2xx 文案（legacy 与 Kimi Code 订阅链路共用；429 固定文案；snippet 截 100）
    static let errorMessages = ProviderErrorMessages(
        unauthorized: (zh: "KIMI API Key 无效或未授权 (HTTP 401)", en: "KIMI API Key is invalid or unauthorized (HTTP 401)"),
        rateLimited: (zh: "KIMI 请求并发超限或额度不足 (HTTP 429)", en: "KIMI concurrency or quota limit exceeded (HTTP 429)"),
        rateLimitUsesJSONDetail: false,
        snippetLength: 100,
        failure: { code, snippet, isZh in
            isZh ? "KIMI 接口响应异常 (\(code)): \(snippet)" : "KIMI API response error (\(code)): \(snippet)"
        }
    )

    public func fetchQuota(
        apiKey: String,
        endpoint: String = "https://api.moonshot.cn/v1",
        model: String = "moonshot-v1-8k",
        balanceAlertThreshold: Double = 10
    ) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
            throw NSError(domain: "KimiService", code: 400, userInfo: [NSLocalizedDescriptionKey: isZh ? "请输入 KIMI / Moonshot API Key" : "Please enter KIMI / Moonshot API Key"])
        }

        // Kimi Code 订阅（sk-kimi- / JWT / coding 端点）走 /usages + /me 链路，
        // 其余保持下方 Moonshot 开放平台 legacy 逻辑不变
        if Self.isCodingSubscription(key: cleanKey, endpoint: endpoint) {
            return try await fetchCodingSubscription(apiKey: cleanKey, endpoint: endpoint)
        }

        let baseEndpoint = normalizeEndpoint(endpoint, fallback: "https://api.moonshot.cn/v1")

        // 1. Fetch user balance via /users/me/balance
        let balance = await fetchBalance(apiKey: cleanKey, baseEndpoint: baseEndpoint)
        var balanceString: String? = nil
        if let bal = balance {
            balanceString = String(format: "¥%.2f", bal)
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

        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        try throwForStatus(httpResp, data: data, domain: "KimiService", messages: Self.errorMessages)

        var primaryWindow: TokenWindow? = nil
        var secondaryWindow: TokenWindow? = nil

        if let bal = balance {
            secondaryWindow = TokenWindow.balance(
                title: .accountAvailableBalance,
                amount: bal,
                currency: "CNY",
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
            primaryWindow = TokenWindow.status(title: .connected(subject: "KIMI"))
        }

        let keySuffix = keySuffixMask(cleanKey)
        let account = balanceString != nil ? (isZh ? "余额: \(balanceString!)" : "Balance: \(balanceString!)") : (isZh ? "KIMI (尾号 \(keySuffix))" : "KIMI (... \(keySuffix))")

        return (primaryWindow, secondaryWindow, account)
    }

    /// 查询 Moonshot 账户余额（人民币），失败返回 nil
    private func fetchBalance(apiKey: String, baseEndpoint: String) async -> Double? {
        await ProviderBalance.fetchMoonshotBalance(
            apiKey: apiKey,
            balanceURL: "\(baseEndpoint)/users/me/balance",
            fallbackToCashBalance: true
        )
    }

    // MARK: - Kimi Code 订阅（/coding/v1）

    /// Kimi Code 订阅模式判定：sk-kimi- 前缀、JWT 形 Key（恰好两个 . 且无空白）、
    /// 或端点指向 coding 网关（api.kimi.com / api.kimi.ai / 含 /coding）
    static func isCodingSubscription(key: String, endpoint: String) -> Bool {
        if key.hasPrefix("sk-kimi-") { return true }
        if key.filter({ $0 == "." }).count == 2 && !key.contains(where: { $0.isWhitespace }) { return true }
        let ep = endpoint.lowercased()
        return ep.contains("api.kimi.com") || ep.contains("api.kimi.ai") || ep.contains("/coding")
    }

    /// 订阅模式 base：用户端点含 /coding 就用用户的；否则强制官方 coding 网关
    /// （用户填了订阅 Key 但端点还是默认 api.moonshot.cn 时也要能工作）
    static func codingSubscriptionBase(endpoint: String) -> String {
        // fallback 传空串：这里允许 trim 后为空（下面会兜底到官方 coding 网关），不做端点替换
        let base = normalizeEndpoint(endpoint, fallback: "")
        if !base.isEmpty && base.lowercased().contains("/coding") {
            return base
        }
        return "https://api.kimi.com/coding/v1"
    }

    /// limit / used / used_ratio 等字段：服务端一律给字符串数字，也兼容 JSON 数字
    static func numberValue(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// resetTime 解析：带纳秒小数（2026-09-26T11:52:30.018171Z）与不带小数（2026-09-26T11:52:29Z）都要支持
    static func parseISO8601(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// resetTime 字段可能是字符串（非字符串当作缺失）
    static func parseResetTime(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return parseISO8601(s)
    }

    /// window.duration 按 timeUnit 折算成秒；未知单位返回 nil
    static func windowSeconds(_ window: [String: Any]) -> Double? {
        guard let duration = numberValue(window["duration"]) else { return nil }
        switch (window["timeUnit"] as? String)?.uppercased() {
        case "TIME_UNIT_SECOND", "SECOND":
            return duration
        case "TIME_UNIT_MINUTE", "MINUTE":
            return duration * 60
        case "TIME_UNIT_HOUR", "HOUR":
            return duration * 3600
        default:
            return nil
        }
    }

    /// 纯解析 Kimi Code /usages 响应（便于 fixture 单测）。已知三种形状：
    /// 1. OAuth 新形状：{"limits":[{window,detail}], "usages":{"limit_5h":{used_ratio,...}, "limit_month_total":{...}}}
    /// 2. API Key 老套餐（7 天周限）：{"usage":{limit,used,resetTime}, "limits":[300 分钟窗]}
    /// 3. OAuth 旧形状（issue #3908）：{"data":{"quota":{"usages":{"limit5h":{usedRatio,resetAt}, "limit7d":{...}}}}}
    /// limit_month_code / extraUsage / parallel 等字段忽略。
    func parseCodingUsages(_ json: [String: Any]) -> (fiveHour: TokenWindow?, longWindow: TokenWindow?) {
        let now = Date()

        // usages 字典：顶层 usages，或旧形状嵌套在 data.quota 里
        var usages = json["usages"] as? [String: Any] ?? [:]
        if usages.isEmpty, let data = json["data"] as? [String: Any],
           let quota = data["quota"] as? [String: Any],
           let nested = quota["usages"] as? [String: Any] {
            usages = nested
        }

        var fiveHour: TokenWindow? = nil
        var longWindow: TokenWindow? = nil

        // 5 小时窗（按序取第一个命中）：
        // ① limits[] 中 window 折算为 18000 秒的项，用 detail 的 limit/used/resetTime（字符串数字）
        if let limits = json["limits"] as? [[String: Any]] {
            for item in limits {
                guard let window = item["window"] as? [String: Any],
                      let detail = item["detail"] as? [String: Any],
                      let seconds = Self.windowSeconds(window),
                      abs(seconds - 18000) < 1 else { continue }
                guard let limit = Self.numberValue(detail["limit"]), limit > 0,
                      let used = Self.numberValue(detail["used"]) else { continue }
                let reset = Self.parseResetTime(detail["resetTime"]) ?? now.addingTimeInterval(5 * 3600)
                fiveHour = TokenWindow(
                    title: .fiveHour,
                    usedPercentage: used / limit * 100,
                    startTime: now,
                    endTime: reset,
                    usedAmount: used,
                    totalLimit: limit,
                    unit: "次",
                    isIdle: used == 0
                )
                break
            }
        }

        // ② usages.limit_5h / limit5h（含 data.quota 嵌套形状）的 used_ratio(0..1)
        if fiveHour == nil,
           let entry = usages["limit_5h"] as? [String: Any] ?? usages["limit5h"] as? [String: Any],
           let ratio = Self.numberValue(entry["used_ratio"] ?? entry["usedRatio"]) {
            let reset = Self.parseResetTime(entry["reset_time"] ?? entry["resetAt"]) ?? now.addingTimeInterval(5 * 3600)
            fiveHour = TokenWindow(
                title: .fiveHour,
                usedPercentage: ratio * 100,
                startTime: now,
                endTime: reset,
                unit: "%",
                isIdle: ratio == 0
            )
        }

        // 长窗口（按序取第一个命中）：
        // ① usages.limit_month_total → 月度额度
        if let entry = usages["limit_month_total"] as? [String: Any],
           let ratio = Self.numberValue(entry["used_ratio"] ?? entry["usedRatio"]) {
            let reset = Self.parseResetTime(entry["reset_time"] ?? entry["resetAt"]) ?? now.addingTimeInterval(30 * 86400)
            longWindow = TokenWindow(
                title: .monthly,
                usedPercentage: ratio * 100,
                startTime: now,
                endTime: reset,
                unit: "%",
                isIdle: ratio == 0
            )
        }
        // ② 顶层 usage 对象（长窗口，老套餐 7 天周限）：resetTime 距今 ≥ 20 天视为月度，否则每周
        else if let usage = json["usage"] as? [String: Any],
                let limit = Self.numberValue(usage["limit"]), limit > 0,
                let used = Self.numberValue(usage["used"]) {
            let reset = Self.parseResetTime(usage["resetTime"]) ?? now.addingTimeInterval(7 * 86400)
            let title: WindowTitle = reset.timeIntervalSince(now) >= 20 * 86400 ? .monthly : .weekly
            longWindow = TokenWindow(
                title: title,
                usedPercentage: used / limit * 100,
                startTime: now,
                endTime: reset,
                usedAmount: used,
                totalLimit: limit,
                unit: "次",
                isIdle: used == 0
            )
        }
        // ③ usages.limit7d / limit_7d（含嵌套形状）→ 每周额度
        else if let entry = usages["limit7d"] as? [String: Any] ?? usages["limit_7d"] as? [String: Any],
                let ratio = Self.numberValue(entry["usedRatio"] ?? entry["used_ratio"]) {
            let reset = Self.parseResetTime(entry["resetAt"] ?? entry["reset_time"]) ?? now.addingTimeInterval(7 * 86400)
            longWindow = TokenWindow(
                title: .weekly,
                usedPercentage: ratio * 100,
                startTime: now,
                endTime: reset,
                unit: "%",
                isIdle: ratio == 0
            )
        }

        return (fiveHour, longWindow)
    }

    /// Kimi Code 订阅模式：并发请求 /usages（额度，超时 10s）与 /me（账号，超时 5s，失败容忍）。
    /// 无余额窗，忽略 balanceAlertThreshold。
    private func fetchCodingSubscription(apiKey: String, endpoint: String) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        let base = Self.codingSubscriptionBase(endpoint: endpoint)

        async let usagesTask = fetchCodingUsages(apiKey: apiKey, base: base)
        async let accountTask = fetchCodingAccount(apiKey: apiKey, base: base)

        let (data, response) = try await usagesTask
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        try throwForStatus(httpResp, data: data, domain: "KimiService", messages: Self.errorMessages)

        var fiveHour: TokenWindow? = nil
        var longWindow: TokenWindow? = nil
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let parsed = parseCodingUsages(json)
            fiveHour = parsed.fiveHour
            longWindow = parsed.longWindow
        }

        // 两种形状都没解析到任何窗口但 HTTP 200 → 保持现有兜底
        if fiveHour == nil && longWindow == nil {
            fiveHour = TokenWindow.status(title: .connected(subject: "KIMI"))
        }

        // /me 失败沿用现有「KIMI (尾号 xxxx)」逻辑
        let keySuffix = keySuffixMask(apiKey)
        let fallbackAccount = isZh ? "KIMI (尾号 \(keySuffix))" : "KIMI (... \(keySuffix))"
        let account = (await accountTask) ?? fallbackAccount

        return (fiveHour, longWindow, account)
    }

    private func makeCodingRequest(url: URL, apiKey: String, timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // 部分账号不带 UA 会 404，必须带 KimiCLI UA
        req.setValue("KimiCLI/1.0.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = timeout
        return req
    }

    private func fetchCodingUsages(apiKey: String, base: String) async throws -> (Data, URLResponse) {
        guard let url = URL(string: "\(base)/usages") else { throw URLError(.badURL) }
        return try await HTTPClient.data(for: makeCodingRequest(url: url, apiKey: apiKey, timeout: 10))
    }

    /// 查询 Kimi Code 账号信息（失败容忍，不阻塞额度展示）
    private func fetchCodingAccount(apiKey: String, base: String) async -> String? {
        guard let url = URL(string: "\(base)/me") else { return nil }
        guard let (data, resp) = try? await HTTPClient.data(for: makeCodingRequest(url: url, apiKey: apiKey, timeout: 5)),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nickname = json["nickname"] as? String, !nickname.isEmpty else {
            return nil
        }
        let level = (json["user_level_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return level.isEmpty ? nickname : "\(nickname) (\(level))"
    }
}
