import Foundation

// 各 Provider Service 之间复制粘贴的模板代码收敛到这里（doc/2026-09-28-优化建议v2-qwen.md #11）。
// 铁律：纯结构重构，所有用户可见行为（错误文案、窗口数值/unit/isIdle、账号字符串、日志）逐字节不变。
// 任何 provider 间的差异（措辞、状态码范围、snippet 截断长度、reset 头有无）一律参数化保留，不合并。

// MARK: - 端点与 URL

/// trim + 空则用 fallback + 去掉全部尾部斜杠。
/// 与各 Service 原内联块（OpenAI/DeepSeek/Kimi/Volcengine/OpenRouter/Claude/Gemini/CustomProvider）语义一致。
public func normalizeEndpoint(_ endpoint: String, fallback: String) -> String {
    var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty {
        base = fallback
    }
    while base.hasSuffix("/") {
        base.removeLast()
    }
    return base
}

/// GET /models 探活地址：已以 /models 结尾则不重复追加。
public func modelsURLString(base: String) -> String {
    base.hasSuffix("/models") ? base : "\(base)/models"
}

// MARK: - API Key 掩码

/// 账号栏「尾号」掩码：超过 6 位只保留末 4 位，否则原样返回。
public func keySuffixMask(_ key: String) -> String {
    key.count > 6 ? String(key.suffix(4)) : key
}

// MARK: - 速率限制窗口构造

/// 从 HTTPURLResponse 的三元头（limit / remaining / reset）构造速率窗口。
///
/// 覆盖既有 9 份块：OpenAI TPM+RPM、DeepSeek、Kimi、Volcengine、CustomProvider×2（x-ratelimit 前缀），
/// ClaudeService tokens+requests、CustomProvider Anthropic tokens（anthropic-ratelimit 前缀）。
/// 各家头名结构不同（x-ratelimit-limit-tokens vs anthropic-ratelimit-tokens-limit），故传完整头名而非拼前后缀。
///
/// 数值行为与原内联块逐一比对过，完全一致：
/// - limit / remaining 任一不可解析为 Double，或 limit <= 0 → nil
/// - used = max(0, limit - remaining)；usedPct = min(max(used/limit*100, 0), 100)
/// - startTime = now；endTime = now + duration；isIdle = used == 0
public enum RateLimitWindowBuilder {
    /// 窗口时长来源
    public enum ResetSource {
        /// 读 reset 头；缺头按 `fallback` 兜底，解析失败按 1s，并不小于 `minimum`
        /// （即原 `OpenAIService.parseDurationString(resetStr ?? "1s")` 语义）
        case header(String, fallback: String, minimum: TimeInterval = 0.1)
        /// 无 reset 头，固定窗长（Claude / CustomProvider-Anthropic requests 用 60s）
        case fixed(TimeInterval)
    }

    public static func build(
        response: HTTPURLResponse,
        limitHeader: String,
        remainingHeader: String,
        reset: ResetSource,
        title: WindowTitle,
        unit: String,
        now: Date = Date()
    ) -> TokenWindow? {
        guard let limit = Double(response.value(forHTTPHeaderField: limitHeader) ?? ""),
              let remaining = Double(response.value(forHTTPHeaderField: remainingHeader) ?? ""),
              limit > 0 else {
            return nil
        }
        let used = max(0.0, limit - remaining)
        let usedPct = min(max((used / limit) * 100.0, 0.0), 100.0)

        let duration: TimeInterval
        switch reset {
        case .header(let name, let fallback, let minimum):
            duration = RateLimitReset.parseOrDefault(response.value(forHTTPHeaderField: name) ?? fallback, minimum: minimum)
        case .fixed(let seconds):
            duration = seconds
        }

        return TokenWindow(
            title: title,
            usedPercentage: usedPct,
            startTime: now,
            endTime: now.addingTimeInterval(duration),
            usedAmount: used,
            totalLimit: limit,
            unit: unit,
            isIdle: used == 0.0
        )
    }
}

// MARK: - 401/429/非2xx 错误分类

/// 各 provider 的错误文案差异盘点（措辞、429 是否解析 JSON detail、snippet 截断长度、
/// 非 2xx 文案是否带状态码都不同），全部参数化保留：
/// - OpenAI：429 解析 error.message；snippet 120；失败文案带 code
/// - DeepSeek / Claude：429 固定文案；snippet 100；失败文案不带 code
/// - Kimi / Volcengine：429 固定文案；snippet 100；失败文案带 code
/// - CustomProvider（OpenAI 兼容 & Anthropic 兼容）：429 解析 error.message；snippet 100；失败文案带 code
/// GLM（401/403 合并 + 1001 体内码）、Gemini（非 200 一律解析 error.message 且不截断）、
/// OpenRouter（无状态码分类主链路）形状不同，不走这里，保留各自实现。
public struct ProviderErrorMessages {
    /// 401 文案
    public var unauthorized: (zh: String, en: String)
    /// 429 文案（`rateLimitUsesJSONDetail` 命中时被响应体 error.message 整体替换）
    public var rateLimited: (zh: String, en: String)
    /// 429 是否解析响应 JSON 的 error.message 覆盖文案
    public var rateLimitUsesJSONDetail: Bool
    /// 非 2xx 响应体 snippet 截断长度（现状只有 100 / 120 两种）
    public var snippetLength: Int
    /// 非 2xx 文案组装：(statusCode, 已截断的响应体, isZh)。
    /// 响应体不可解码时 snippet 的兜底为 "HTTP <code>"（截断前），与各原实现一致。
    public var failure: (_ code: Int, _ snippet: String, _ isZh: Bool) -> String

    public init(
        unauthorized: (zh: String, en: String),
        rateLimited: (zh: String, en: String),
        rateLimitUsesJSONDetail: Bool,
        snippetLength: Int,
        failure: @escaping (_ code: Int, _ snippet: String, _ isZh: Bool) -> String
    ) {
        self.unauthorized = unauthorized
        self.rateLimited = rateLimited
        self.rateLimitUsesJSONDetail = rateLimitUsesJSONDetail
        self.snippetLength = snippetLength
        self.failure = failure
    }
}

/// 401 / 429 / 非 2xx 统一分类抛错；2xx 时直接返回。
public func throwForStatus(
    _ httpResp: HTTPURLResponse,
    data: Data,
    domain: String,
    messages: ProviderErrorMessages
) throws {
    let isZh = LocalizationManager.shared.effectiveLanguage == "zh"

    if httpResp.statusCode == 401 {
        throw NSError(
            domain: domain,
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: isZh ? messages.unauthorized.zh : messages.unauthorized.en]
        )
    }

    if httpResp.statusCode == 429 {
        var msg = isZh ? messages.rateLimited.zh : messages.rateLimited.en
        if messages.rateLimitUsesJSONDetail,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = json["error"] as? [String: Any],
           let errDetail = err["message"] as? String {
            msg = errDetail
        }
        throw NSError(domain: domain, code: 429, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    guard httpResp.statusCode >= 200 && httpResp.statusCode < 300 else {
        let body = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
        let snippet = String(body.prefix(messages.snippetLength))
        throw NSError(
            domain: domain,
            code: httpResp.statusCode,
            userInfo: [NSLocalizedDescriptionKey: messages.failure(httpResp.statusCode, snippet, isZh)]
        )
    }
}

// MARK: - 余额查询

/// 跨 Service 重复的余额查询实现（DeepSeekService.fetchBalance ≡ CustomProviderService.fetchDeepSeekBalance；
/// KimiService.fetchBalance ≈ CustomProviderService.fetchMoonshotBalance，差异只在端点与 cash_balance 兜底）。
public enum ProviderBalance {
    /// DeepSeek `/user/balance`：balance_infos 首条的 total_balance（字符串或数字），currency 默认 CNY；失败返回 nil
    public static func fetchDeepSeekBalance(apiKey: String) async -> (amount: Double, currency: String)? {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (data, resp) = try? await HTTPClient.data(for: req),
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

    /// Moonshot 余额：`data.available_balance`（数字或数字字符串）。
    /// - Parameters:
    ///   - balanceURL: 完整余额端点（Kimi 用用户 baseEndpoint 拼 `/users/me/balance`；CustomProvider 固定官方端点）
    ///   - fallbackToCashBalance: available_balance 缺失/不可解析时是否兜底 `cash_balance`
    ///     （Kimi legacy 链路兜底，CustomProvider 不兜底——保留原差异）
    public static func fetchMoonshotBalance(apiKey: String, balanceURL: String, fallbackToCashBalance: Bool) async -> Double? {
        guard let url = URL(string: balanceURL) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5

        guard let (data, resp) = try? await HTTPClient.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any] else {
            return nil
        }

        if let available = (dataDict["available_balance"] as? NSNumber)?.doubleValue {
            return available
        }
        if let availableStr = dataDict["available_balance"] as? String, let parsed = Double(availableStr) {
            return parsed
        }
        if fallbackToCashBalance, let cash = (dataDict["cash_balance"] as? NSNumber)?.doubleValue {
            return cash
        }
        return nil
    }
}
