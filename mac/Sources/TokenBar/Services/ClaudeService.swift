import Foundation

/// `@unchecked Sendable`：仅有的存储属性是两个 ISO8601DateFormatter（Apple 文档保证线程安全），
/// 需要它是为了把 `~/.claude.json` 的读取放到后台线程。
public final class ClaudeService: @unchecked Sendable {
    public static let shared = ClaudeService()

    /// fetchAnthropicQuota 的 401/429/非2xx 文案（429 固定文案不解析 JSON；失败文案不带状态码；snippet 截 100）
    static let anthropicErrorMessages = ProviderErrorMessages(
        unauthorized: (zh: "Anthropic API Key 无效或未授权 (HTTP 401)", en: "Anthropic API Key is invalid or unauthorized (HTTP 401)"),
        rateLimited: (zh: "Anthropic 请求频率或额度超限 (HTTP 429)", en: "Anthropic rate limit or quota exceeded (HTTP 429)"),
        rateLimitUsesJSONDetail: false,
        snippetLength: 100,
        failure: { _, snippet, isZh in
            isZh ? "Anthropic 接口响应异常: \(snippet)" : "Anthropic API response error: \(snippet)"
        }
    )

    private let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let isoFormatterNoFrac: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func parseDate(_ dateStr: String) -> Date? {
        if let date = isoFormatter.date(from: dateStr) {
            return date
        }
        return isoFormatterNoFrac.date(from: dateStr)
    }

    /// `~/.claude.json` 的解析结果。`fetchedAt` 是 Claude Code 写入 `cachedUsageUtilization`
    /// 时记下的 `fetchedAtMs`：这份缓存只在 Claude Code 自己查用量（`/usage`、桌面端 `get_usage`）
    /// 时才更新，可能比 TokenBar 的刷新时刻旧几个小时，展示时必须带上它。
    public typealias LocalClaudeSnapshot = (
        fiveHour: TokenWindow?, weekly: TokenWindow?, scopedWeekly: TokenWindow?,
        account: String?, fetchedAt: Date?
    )

    /// Read locally cached usage and account info from ~/.claude.json if present.
    ///
    /// async：重度 Claude Code 用户的 `~/.claude.json` 常有数 MB（history / projects），
    /// 在 MainActor 上同步全量解析是每轮刷新都能感知的卡顿，与 GeminiService.readLocalGeminiFiles
    /// 同样挪到后台线程。
    public func readLocalClaudeJson() async -> LocalClaudeSnapshot? {
        await Task.detached(priority: .userInitiated) { self.readLocalClaudeJsonSync() }.value
    }

    /// 同步实现，只应在后台线程调用
    func readLocalClaudeJsonSync() -> LocalClaudeSnapshot? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let claudeJsonUrl = homeDir.appendingPathComponent(".claude.json")

        guard FileManager.default.fileExists(atPath: claudeJsonUrl.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: claudeJsonUrl)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return parseLocalClaudeJson(json)
        } catch {
            return nil
        }
    }

    /// 从 limits[] 里解析按模型圈定的周额度（如 Fable / Opus 专属周额度）。
    /// 条目形如 {kind: "weekly_scoped", percent: 42, resets_at: ..., scope: {model: {display_name: "Fable"}}}。
    /// display_name 缺失的条目给不出有意义的标题，跳过；取第一条匹配。
    private func parseScopedWeeklyLimit(_ limits: [[String: Any]]) -> TokenWindow? {
        for limit in limits where (limit["kind"] as? String) == "weekly_scoped" {
            guard let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let displayName = model["display_name"] as? String,
                  !displayName.isEmpty else {
                continue
            }
            let pct = (limit["percent"] as? NSNumber)?.doubleValue ?? 0.0
            let now = Date()
            let resetsAt = (limit["resets_at"] as? String).flatMap { parseDate($0) } ?? now.addingTimeInterval(7 * 86400)
            return TokenWindow(
                title: .custom(displayName),
                usedPercentage: pct,
                startTime: resetsAt.addingTimeInterval(-7 * 86400),
                endTime: resetsAt,
                unit: "%",
                isIdle: false
            )
        }
        return nil
    }

    /// 纯解析 `~/.claude.json` 的内容，不碰文件系统，便于用 fixture 单测
    public func parseLocalClaudeJson(_ json: [String: Any]) -> LocalClaudeSnapshot {
            var accountEmail: String? = nil
            if let oauthAccount = json["oauthAccount"] as? [String: Any] {
                accountEmail = oauthAccount["emailAddress"] as? String ?? oauthAccount["displayName"] as? String
            }

            guard let cached = json["cachedUsageUtilization"] as? [String: Any],
                  let utilization = cached["utilization"] as? [String: Any] else {
                // If account is logged in but no cached utilization yet, create clean initial 5h window
                let now = Date()
                let fiveHour = TokenWindow(
                    title: .fiveHour,
                    usedPercentage: 0.0,
                    startTime: now,
                    endTime: now.addingTimeInterval(5 * 3600),
                    unit: "%",
                    isIdle: true
                )
                return (fiveHour, nil, nil, accountEmail, nil)
            }

            let fetchedAt = (cached["fetchedAtMs"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }

            var fiveHourWindow: TokenWindow? = nil
            var weeklyWindow: TokenWindow? = nil
            var scopedWeeklyWindow: TokenWindow? = nil

            // 1. Parse 5-hour session window
            if let fiveHour = utilization["five_hour"] as? [String: Any] {
                let util = (fiveHour["utilization"] as? NSNumber)?.doubleValue ?? 0.0
                let resetsAtStr = fiveHour["resets_at"] as? String

                if let str = resetsAtStr, let resetsAt = parseDate(str) {
                    if resetsAt > Date() {
                        let startTime = resetsAt.addingTimeInterval(-5 * 3600)
                        fiveHourWindow = TokenWindow(
                            title: .fiveHour,
                            usedPercentage: util,
                            startTime: startTime,
                            endTime: resetsAt,
                            unit: "%",
                            isIdle: false
                        )
                    } else {
                        // Previous 5h window has passed reset time -> resets to 0% used (100% remaining)
                        let now = Date()
                        fiveHourWindow = TokenWindow(
                            title: .fiveHour,
                            usedPercentage: 0.0,
                            startTime: now,
                            endTime: now.addingTimeInterval(5 * 3600),
                            unit: "%",
                            isIdle: true
                        )
                    }
                } else {
                    // resets_at is null: session is currently idle/reset, 100% quota available!
                    let now = Date()
                    fiveHourWindow = TokenWindow(
                        title: .fiveHour,
                        usedPercentage: util,
                        startTime: now,
                        endTime: now.addingTimeInterval(5 * 3600),
                        unit: "%",
                        isIdle: true
                    )
                }
            }

            // Fallback from limits array if fiveHourWindow is still nil
            if fiveHourWindow == nil,
               let limits = utilization["limits"] as? [[String: Any]],
               let session = limits.first(where: { ($0["kind"] as? String) == "session" || ($0["group"] as? String) == "session" }) {
                let pct = (session["percent"] as? NSNumber)?.doubleValue ?? 0.0
                let now = Date()
                fiveHourWindow = TokenWindow(
                    title: .fiveHour,
                    usedPercentage: pct,
                    startTime: now,
                    endTime: now.addingTimeInterval(5 * 3600),
                    unit: "%",
                    isIdle: pct == 0.0
                )
            }

            // Guarantee 5-hour window exists for Claude Code
            if fiveHourWindow == nil {
                let now = Date()
                fiveHourWindow = TokenWindow(
                    title: .fiveHour,
                    usedPercentage: 0.0,
                    startTime: now,
                    endTime: now.addingTimeInterval(5 * 3600),
                    unit: "%",
                    isIdle: true
                )
            }

            // 2. Parse 7-day weekly window
            if let sevenDay = utilization["seven_day"] as? [String: Any] {
                let util = (sevenDay["utilization"] as? NSNumber)?.doubleValue ?? 0.0
                let resetsAtStr = sevenDay["resets_at"] as? String
                if let str = resetsAtStr, let resetsAt = parseDate(str) {
                    let startTime = resetsAt.addingTimeInterval(-7 * 86400)
                    weeklyWindow = TokenWindow(
                        title: .weekly,
                        usedPercentage: util,
                        startTime: startTime,
                        endTime: resetsAt,
                        unit: "%",
                        isIdle: false
                    )
                }
            }

            if weeklyWindow == nil,
               let limits = utilization["limits"] as? [[String: Any]],
               let weekly = limits.first(where: { ($0["kind"] as? String) == "weekly_all" || ($0["group"] as? String) == "weekly" }) {
                let pct = (weekly["percent"] as? NSNumber)?.doubleValue ?? 0.0
                let resetsAtStr = weekly["resets_at"] as? String
                let now = Date()
                let resetsAt = resetsAtStr != nil ? (parseDate(resetsAtStr!) ?? now.addingTimeInterval(7 * 86400)) : now.addingTimeInterval(7 * 86400)
                let startTime = resetsAt.addingTimeInterval(-7 * 86400)
                weeklyWindow = TokenWindow(
                    title: .weekly,
                    usedPercentage: pct,
                    startTime: startTime,
                    endTime: resetsAt,
                    unit: "%",
                    isIdle: false
                )
            }

            // 3. 按模型圈定的周额度（如 Fable）：weekly fallback 取 first(group == "weekly")
            // 仍命中 weekly_all，与此互不干扰
            if let limits = utilization["limits"] as? [[String: Any]] {
                scopedWeeklyWindow = parseScopedWeeklyLimit(limits)
            }

            return (fiveHourWindow, weeklyWindow, scopedWeeklyWindow, accountEmail, fetchedAt)
    }

    // MARK: - Claude Code 自己的 OAuth 凭证

    /// Claude Code 在 login.keychain 里的凭证条目。它自己只通过 `/usr/bin/security` 读写
    /// （`security -i` + `add-generic-password -U`），所以 `security` 永远在条目的信任列表里。
    static let claudeCodeKeychainService = "Claude Code-credentials"

    /// 条目的 account：Claude Code 取 `$USER`，不合 `[A-Za-z0-9._-]+` 时退成 "claude-code-user"
    static func claudeCodeKeychainAccount(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let user = environment["USER"] ?? NSUserName()
        let valid = user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        return valid ? user : "claude-code-user"
    }

    /// 解析 Claude Code 的凭证 JSON：`{"claudeAiOauth": {"accessToken", "refreshToken", "expiresAt"(毫秒), ...}}`。
    ///
    /// **只取 accessToken**。refreshToken 归 Claude Code 所有且每次使用都会轮换，TokenBar 拿它
    /// 换新 token 会让 Claude Code 手里那枚作废——它遇到 invalid_grant 会清空本地凭证，等于把用户登出。
    /// 所以 access token 过期后只能等 Claude Code 自己续期，期间退回本地缓存。
    static func parseClaudeCodeCredential(_ raw: String) -> ClaudeCodeCredential? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        let expiresAt = (oauth["expiresAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeCodeCredential(accessToken: token, expiresAt: expiresAt)
    }

    /// 读 Claude Code 的 OAuth 凭证：钥匙串优先，`~/.claude/.credentials.json` 兜底
    /// （钥匙串不可用时 Claude Code 会落到这个明文文件）。
    ///
    /// 钥匙串经 `/usr/bin/security find-generic-password -w` 读，与 Claude Code 自己读凭证的方式一致，
    /// 无需任何授权框。曾经用 SecItem 直读 +「始终允许」：实测授权撑不过一天 —— Claude Code 每次续期
    /// token 都会重写这个条目，TokenBar 随之失去访问权，此后每轮静默读都被拒（-25293），额度悄悄退回陈旧缓存。
    public func readClaudeCodeCredential() async -> ClaudeCodeCredential? {
        let account = Self.claudeCodeKeychainAccount()
        if let raw = await Self.runSecurityFindPassword(service: Self.claudeCodeKeychainService, account: account),
           let credential = Self.parseClaudeCodeCredential(Self.decodeSecurityPasswordOutput(raw)) {
            return credential
        }
        return await Task.detached(priority: .userInitiated) { () -> ClaudeCodeCredential? in
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            guard let data = try? Data(contentsOf: url),
                  let raw = String(data: data, encoding: .utf8) else { return nil }
            return Self.parseClaudeCodeCredential(raw)
        }.value
    }

    /// `security find-generic-password -w` 的输出还原成密码原文：内容可打印时它直接输出原文，
    /// 含不可打印字节时改输出十六进制。Claude Code 用 `-X <hex>` 写入，读回来两种形态都可能出现。
    static func decodeSecurityPasswordOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("{"),
              trimmed.count.isMultiple(of: 2),
              trimmed.range(of: "^[0-9A-Fa-f]+$", options: .regularExpression) != nil else {
            return trimmed
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return trimmed }
            bytes.append(byte)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8) ?? trimmed
    }

    /// 在后台跑 `/usr/bin/security find-generic-password -s <service> -a <account> -w`，返回 stdout；
    /// 条目不存在（退出码 44）、失败或超时返回 nil。Process 是同步阻塞调用，绝不能放在 MainActor 上
    /// （见 ARCH 2.2.1）；看门狗与「先读到 EOF 再 waitUntilExit」的顺序沿用 AliyunBailianService.fetchViaCLI。
    private static func runSecurityFindPassword(service: String, account: String, timeout: TimeInterval = 5) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    Log.provider.error("provider=claude 启动 security 失败: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }

                // 看门狗只负责杀进程，resume 路径始终唯一
                let watchdog = DispatchWorkItem {
                    guard process.isRunning else { return }
                    Log.provider.error("provider=claude security 读凭证超时 \(timeout, format: .fixed(precision: 0))s，terminate")
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()

                guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                    if process.terminationStatus != 44 {
                        Log.provider.notice("provider=claude security 读凭证失败 status=\(process.terminationStatus, privacy: .public)")
                    }
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: data, encoding: .utf8))
            }
        }
    }

    /// Fetch latest usage statistics from Anthropic OAuth usage API
    public func fetchRemoteUsage(token: String) async throws -> ClaudeRemoteUsage {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.263", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        let (data, response) = try await HTTPClient.data(for: request)

        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResp.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "HTTP \(httpResp.statusCode)"
            throw NSError(domain: "ClaudeService", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        var fiveHourWindow: TokenWindow? = nil
        var weeklyWindow: TokenWindow? = nil

        // 1. Parse 5-hour session window
        if let fiveHour = json["five_hour"] as? [String: Any] {
            let util = (fiveHour["utilization"] as? NSNumber)?.doubleValue ?? 0.0
            let resetsAtStr = fiveHour["resets_at"] as? String

            if let str = resetsAtStr, let resetsAt = parseDate(str) {
                if resetsAt > Date() {
                    let startTime = resetsAt.addingTimeInterval(-5 * 3600)
                    fiveHourWindow = TokenWindow(
                        title: .fiveHour,
                        usedPercentage: util,
                        startTime: startTime,
                        endTime: resetsAt,
                        unit: "%",
                        isIdle: false
                    )
                } else {
                    let now = Date()
                    fiveHourWindow = TokenWindow(
                        title: .fiveHour,
                        usedPercentage: 0.0,
                        startTime: now,
                        endTime: now.addingTimeInterval(5 * 3600),
                        unit: "%",
                        isIdle: true
                    )
                }
            } else {
                let now = Date()
                fiveHourWindow = TokenWindow(
                    title: .fiveHour,
                    usedPercentage: util,
                    startTime: now,
                    endTime: now.addingTimeInterval(5 * 3600),
                    unit: "%",
                    isIdle: true
                )
            }
        }

        if fiveHourWindow == nil {
            let now = Date()
            fiveHourWindow = TokenWindow(
                title: .fiveHour,
                usedPercentage: 0.0,
                startTime: now,
                endTime: now.addingTimeInterval(5 * 3600),
                unit: "%",
                isIdle: true
            )
        }

        // 2. Parse 7-day weekly window
        if let sevenDay = json["seven_day"] as? [String: Any] {
            let util = (sevenDay["utilization"] as? NSNumber)?.doubleValue ?? 0.0
            let resetsAtStr = sevenDay["resets_at"] as? String
            if let str = resetsAtStr, let resetsAt = parseDate(str) {
                let startTime = resetsAt.addingTimeInterval(-7 * 86400)
                weeklyWindow = TokenWindow(
                    title: .weekly,
                    usedPercentage: util,
                    startTime: startTime,
                    endTime: resetsAt,
                    unit: "%",
                    isIdle: false
                )
            }
        }

        // 3. 按模型圈定的周额度（如 Fable）：响应与 cachedUsageUtilization 同构，
        // 若暂未下发 limits 字段则自然为 nil，由调用方回落本地缓存
        let scopedWeeklyWindow = (json["limits"] as? [[String: Any]]).flatMap { parseScopedWeeklyLimit($0) }

        return (fiveHourWindow, weeklyWindow, scopedWeeklyWindow, nil)
    }

    /// Fetch usage / rate limits using Anthropic API key via GET /v1/models
    public func fetchAnthropicQuota(
        apiKey: String,
        endpoint: String = "https://api.anthropic.com/v1"
    ) async throws -> (primary: TokenWindow?, secondary: TokenWindow?, account: String?) {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        guard !cleanKey.isEmpty else {
            throw NSError(domain: "ClaudeService", code: 400, userInfo: [NSLocalizedDescriptionKey: isZh ? "请输入 Anthropic API Key" : "Please enter Anthropic API Key"])
        }

        let baseEndpoint = normalizeEndpoint(endpoint, fallback: "https://api.anthropic.com/v1")

        let modelsURLStr = modelsURLString(base: baseEndpoint)
        guard let url = URL(string: modelsURLStr) else {
            throw URLError(.badURL)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(cleanKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        let (data, response) = try await HTTPClient.data(for: req)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        try throwForStatus(httpResp, data: data, domain: "ClaudeService", messages: Self.anthropicErrorMessages)

        // Anthropic 不返回 reset 头，两个窗口都按固定 60s 计
        var primaryWindow: TokenWindow? = nil
        var secondaryWindow: TokenWindow? = nil

        primaryWindow = RateLimitWindowBuilder.build(
            response: httpResp,
            limitHeader: "anthropic-ratelimit-tokens-limit",
            remainingHeader: "anthropic-ratelimit-tokens-remaining",
            reset: .fixed(60),
            title: .tpmRate,
            unit: "tokens"
        )

        secondaryWindow = RateLimitWindowBuilder.build(
            response: httpResp,
            limitHeader: "anthropic-ratelimit-requests-limit",
            remainingHeader: "anthropic-ratelimit-requests-remaining",
            reset: .fixed(60),
            title: .rpmRate,
            unit: "req/min"
        )

        if primaryWindow == nil && secondaryWindow == nil {
            primaryWindow = TokenWindow.status(title: .connected(subject: "Anthropic API"))
        }

        let keySuffix = keySuffixMask(cleanKey)
        let account = isZh ? "Anthropic API (尾号 \(keySuffix))" : "Anthropic API (... \(keySuffix))"

        return (primaryWindow, secondaryWindow, account)
    }
}

/// `/api/oauth/usage` 的解析结果（account 目前恒为 nil，账号取自本地 `~/.claude.json`）
public typealias ClaudeRemoteUsage = (fiveHour: TokenWindow?, weekly: TokenWindow?, scopedWeekly: TokenWindow?, account: String?)

/// Claude Code 登录凭证里 TokenBar 用得上的部分
public struct ClaudeCodeCredential: Equatable, Sendable {
    public let accessToken: String
    /// nil：凭证里没有过期时间，视为可用（401 时自然退回缓存）
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    /// 离过期不足 60 秒就不用了：请求在途中过期只会换来一个 401
    public func isUsable(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > 60
    }
}
