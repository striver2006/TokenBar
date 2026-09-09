import Foundation

/// Token Plan 用量响应的解析。
///
/// 同一套解析要吃下三种嵌套形状：
/// 1. `bl --output json` 的扁平输出：`{"per1WeekPercentage":0.125,...}`
/// 2. Cookie 网关 `/data/api.json`：`{"data":{"data":{...}}}`
/// 3. Bearer 网关 `/cli/api.json`：`{"data":{"DataV2":{"data":{"data":{...}}}}}`
extension AliyunBailianService {

    static let quotaKeys = [
        "per1WeekPercentage", "per5HourPercentage",
        "per1WeekResetTime", "per5HourResetTime"
    ]

    // MARK: - 信封错误

    /// 剥壳之前先判信封层的错误。返回 nil 表示这是一个成功响应。
    static func detectEnvelopeError(_ root: [String: Any]) -> AliyunChannelError? {
        // CLI 的错误信封
        if let errorObj = root["error"] as? [String: Any] {
            let message = (errorObj["message"] as? String) ?? ""
            let hint = (errorObj["hint"] as? String) ?? ""
            if message.contains("not logged in") || hint.contains("auth login") || message.contains("NotLogined") {
                return .notLogined
            }
            return .cliFailed([message, hint].filter { !$0.isEmpty }.joined(separator: " — "))
        }

        // 网关的错误信封：判定落在顶层 data 上
        if let data = root["data"] as? [String: Any],
           (data["success"] as? Bool) == false {
            let code = Self.stringValue(data["errorCode"]) ?? ""
            let message = Self.stringValue(data["errorMsg"]) ?? ""
            if code.contains("NotLogined") { return .notLogined }
            if code.contains("Forbidden") || code.contains("NoPermission") || code.contains("RAM") {
                return .noPermission("\(code) \(message)".trimmed)
            }
            return .gatewayError(code: code.isEmpty ? "Unknown" : code, message: message)
        }

        return nil
    }

    // MARK: - 剥壳

    /// 官方 `bailian-cli-core` 的 unwrap 逻辑，外加一层 BFS 兜底。
    static func unwrapTokenPlanPayload(_ root: [String: Any]) -> [String: Any] {
        var payload = root
        if let data = root["data"] as? [String: Any] {
            if let dataV2 = data["DataV2"] as? [String: Any] {
                if let inner = dataV2["data"] as? [String: Any] {
                    payload = (inner["data"] as? [String: Any]) ?? inner
                } else {
                    payload = dataV2
                }
            } else {
                payload = (data["data"] as? [String: Any]) ?? data
            }
        }
        if hasAnyQuotaKey(payload) { return payload }

        // 官方 unwrap 只覆盖已知的三层。网关将来再加一层壳时，BFS 兜底能自愈。
        return firstDictContainingQuotaKeys(root, maxDepth: 6) ?? payload
    }

    static func hasAnyQuotaKey(_ dict: [String: Any]) -> Bool {
        quotaKeys.contains { dict[$0] != nil }
    }

    /// 广度优先找第一个含额度字段的字典，限制深度避免病态输入下遍历过久。
    static func firstDictContainingQuotaKeys(_ root: [String: Any], maxDepth: Int) -> [String: Any]? {
        var queue: [(dict: [String: Any], depth: Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (current, depth) = queue.removeFirst()
            if hasAnyQuotaKey(current) { return current }
            guard depth < maxDepth else { continue }
            for value in current.values {
                if let child = value as? [String: Any] {
                    queue.append((child, depth + 1))
                } else if let array = value as? [Any] {
                    for element in array {
                        if let child = element as? [String: Any] { queue.append((child, depth + 1)) }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - 宽松取值

    /// NSNumber / Double / Int / 数字字符串都吃；null 与非数字返回 nil（而不是抛错）。
    static func doubleValue(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber:
            // JSON 里的 true/false 也会被桥接成 NSNumber，这里要排除掉
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        case let d as Double: return d
        case let i as Int:    return Double(i)
        case let s as String: return Double(s.trimmed)
        default: return nil
        }
    }

    static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    // MARK: - 主解析

    static func parseTokenPlanResponse(
        _ data: Data,
        accountLabel: String,
        channel: AliyunChannel
    ) throws -> AliyunQuotaResult {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw AliyunChannelError.unexpectedFormat(String(raw))
        }

        if let envelopeError = detectEnvelopeError(root) { throw envelopeError }

        let payload = unwrapTokenPlanPayload(root)
        let weekly = makeWindow(
            titleZh: "7天周期额度",
            percentage: doubleValue(payload["per1WeekPercentage"]),
            resetMilliseconds: doubleValue(payload["per1WeekResetTime"]),
            duration: 7 * 86400
        )
        let fiveHour = makeWindow(
            titleZh: "5小时额度",
            percentage: doubleValue(payload["per5HourPercentage"]),
            resetMilliseconds: doubleValue(payload["per5HourResetTime"]),
            duration: 5 * 3600
        )

        // 两个窗口都没数据**不是错误** —— 官方 CLI 在这种情况下显示「该窗口可能不限量」。
        // 只要信封层是成功的，就照样算已授权，把说明放进 note。
        var note: String? = nil
        if weekly == nil && fiveHour == nil {
            let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
            note = isZh
                ? "本周期未返回限额数据（该窗口可能不限量），可在百炼 Token Plan 控制台核对。"
                : "No quota figures returned for this period (the window may be unlimited). Check the Bailian Token Plan console."
        }

        return AliyunQuotaResult(
            fiveHour: fiveHour,
            weekly: weekly,
            account: accountLabel,
            note: note,
            channel: channel
        )
    }

    /// 百分比是 0~1 的小数，重置时间是 epoch 毫秒。
    static func makeWindow(
        titleZh: String,
        percentage: Double?,
        resetMilliseconds: Double?,
        duration: TimeInterval
    ) -> TokenWindow? {
        guard let percentage else { return nil }
        let usedPct = min(max(percentage * 100.0, 0.0), 100.0)
        let resetDate: Date = (resetMilliseconds.map { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000.0) : nil } ?? nil)
            ?? Date().addingTimeInterval(duration)

        return TokenWindow(
            title: titleZh,
            usedPercentage: usedPct,
            startTime: resetDate.addingTimeInterval(-duration),
            endTime: resetDate,
            unit: "%",
            isIdle: usedPct == 0.0
        )
    }
}

// MARK: - 凭证装配

extension AliyunBailianService {
    /// 从设置项、安全存储和本机 `bl` 配置装配出一次查询所需的凭证。
    ///
    /// AccessKey Secret 与控制台令牌**只**来自 SecretStore —— 刻意不在 AppSettings 里留明文回退位，
    /// 安全存储写不进去时宁可如实报错，也不把账号级长期凭证落到明文配置里。
    ///
    /// 本机若已 `bl auth login`，在允许复用的前提下：
    /// - 借用它的控制台令牌，省掉一次多余的签发；
    /// - 借用它的 AK/SK（`bl auth login --open-api` 存的），让老用户零配置即可自愈。
    /// 借来的凭证只在内存里用，绝不写回 `~/.bailian/config.json`。
    /// - Parameter secretStore: **必须**传入已经在后台读好的内存快照
    ///   （`KeychainSecretStore.prefetch(_:)` 的返回值）。刻意不给默认值：
    ///   直接传 `KeychainSecretStore.shared` 会让这个同步函数在调用线程上阻塞等
    ///   securityd，在 MainActor 上就是全局刷新停摆（commit 6f332a3）。
    ///   默认值会把最危险的选项做成打字最少的选项。
    public static func resolveCredentials(
        settings: AppSettings,
        secretStore: SecretStoring,
        cliConfig: BailianCLIConfig? = nil
    ) -> AliyunCredentials {
        let reusable = settings.aliyunReuseCLIConfig
            ? (cliConfig ?? BailianCLIConfig.loadFromDisk())
            : nil

        var credentials = AliyunCredentials(
            accessKeyId: settings.aliyunAccessKeyId.trimmed,
            accessKeySecret: secretStore.get(.aliyunAccessKeySecret)?.trimmed ?? "",
            consoleAccessToken: secretStore.get(.aliyunConsoleAccessToken)?.trimmed ?? "",
            cookie: settings.aliyunCookie.trimmed,
            consoleRegion: settings.aliyunConsoleRegion.trimmed.isEmpty
                ? "cn-beijing" : settings.aliyunConsoleRegion.trimmed,
            consoleSite: settings.aliyunConsoleSite.trimmed.isEmpty
                ? "domestic" : settings.aliyunConsoleSite.trimmed,
            consoleSwitchAgent: settings.aliyunConsoleSwitchAgent
        )

        guard let reusable else { return credentials }

        // 用户没配 AK/SK，但本机 bl 配过 —— 直接借用，两者缺一不可才算数
        if !credentials.hasAccessKey,
           let id = reusable.accessKeyId, let secret = reusable.accessKeySecret {
            credentials.accessKeyId = id
            credentials.accessKeySecret = secret
        }
        if !credentials.hasConsoleToken, let token = reusable.accessToken {
            credentials.consoleAccessToken = token
        }
        // 代操作 UID 用户没填时才借用（bl 登录企业账号时会带上）
        if credentials.consoleSwitchAgent == 0, let agent = reusable.consoleSwitchAgent {
            credentials.consoleSwitchAgent = agent
        }
        return credentials
    }
}

// MARK: - 账户现金余额（BSS OpenAPI QueryAccountBalance）

/// 与额度查询相互独立：复用同一对 AK/SK 与同一套 V3 签名，但失败不影响额度通道。
public struct AliyunAccountBalance: Equatable, Sendable {
    /// 可用现金余额（优先 AvailableCashAmount，缺失时回落 AvailableAmount）。
    public let amount: Double
    public let currency: String
}

extension AliyunBailianService {
    /// 阿里云返回的金额是字符串，且可能带千分位逗号与货币符号。
    static func parseAmount(_ any: Any?) -> Double? {
        guard let text = stringValue(any) else { return doubleValue(any) }
        let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    static func parseAccountBalance(_ data: Data) throws -> AliyunAccountBalance {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw AliyunChannelError.unexpectedFormat(String(raw))
        }
        if (root["Success"] as? Bool) == false {
            throw classifyOpenAPIError(
                status: 200,
                code: (root["Code"] as? String) ?? "",
                message: (root["Message"] as? String) ?? "",
                raw: data)
        }
        guard let payload = root["Data"] as? [String: Any] else {
            throw AliyunChannelError.unexpectedFormat("QueryAccountBalance 响应缺少 Data")
        }
        guard let amount = parseAmount(payload["AvailableCashAmount"])
                ?? parseAmount(payload["AvailableAmount"]) else {
            throw AliyunChannelError.unexpectedFormat("QueryAccountBalance 响应缺少可用余额字段")
        }
        return AliyunAccountBalance(
            amount: amount,
            currency: stringValue(payload["Currency"]) ?? "CNY"
        )
    }

    /// 查询阿里云账户现金余额。需要 RAM 权限 `bss:DescribeAcccount`（只读；官方文档就是这个拼写）。
    public func fetchAccountBalance(_ credentials: AliyunCredentials) async throws -> AliyunAccountBalance {
        guard credentials.hasAccessKey else { throw AliyunChannelError.missingCredentials }

        let headers = AliyunSigner.signedHeaders(
            host: Self.balanceHost,
            pathname: "/",
            method: "POST",
            action: Self.balanceAction,
            version: Self.balanceVersion,
            accessKeyId: credentials.accessKeyId.trimmed,
            accessKeySecret: credentials.accessKeySecret.trimmed
        )

        var request = URLRequest(url: URL(string: "https://\(Self.balanceHost)/")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        for (key, value) in headers where key != "host" {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await HTTPClient.data(for: request)
        } catch {
            throw AliyunChannelError.network(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            throw Self.classifyOpenAPIError(
                status: status,
                code: (json["Code"] as? String) ?? "",
                message: (json["Message"] as? String) ?? "",
                raw: data)
        }
        return try Self.parseAccountBalance(data)
    }
}
