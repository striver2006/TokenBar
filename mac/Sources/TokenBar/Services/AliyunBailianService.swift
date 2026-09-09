import Foundation
import AppKit

public final class AliyunBailianService: @unchecked Sendable {
    public static let shared = AliyunBailianService()

    /// 控制台网关上查询 Token Plan 用量的 API 名。
    static let tokenPlanUsageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    /// 用 AK/SK 换控制台令牌的 OpenAPI。
    static let generateTokenPath = "/modelstudio/cli/generateAccessToken"
    static let generateTokenAction = "GenerateCLIAccessToken"
    static let generateTokenVersion = "2026-02-10"
    /// 查询阿里云账户现金余额的 BSS OpenAPI。
    static let balanceHost = "business.aliyuncs.com"
    static let balanceAction = "QueryAccountBalance"
    static let balanceVersion = "2017-12-14"

    /// 待在终端执行的百炼 CLI 登录命令
    public static let cliLoginCommand = "bl auth login --console"

    private let tokenCoordinator = TokenCoordinator()
    private var isZh: Bool { LocalizationManager.shared.effectiveLanguage == "zh" }

    // MARK: - 终端登录（保留，作为备用通道的入口）

    /// 在「终端」中运行 `bl auth login --console`。
    ///
    /// 旧实现直接用 NSAppleScript 向 Terminal 发送 `do script`，这需要 TCC「自动化」授权，
    /// 而 Info.plist 缺少 NSAppleEventsUsageDescription 时系统会直接拒绝，错误又被忽略，
    /// 表现为"只打开了一个空终端、命令没执行"。
    /// 现改为写入一个临时 .command 脚本再用终端打开（无需任何授权），失败时才回退到 AppleScript。
    /// completion 固定在主线程回调：成功为 (true, nil)，失败为 (false, 已本地化的错误说明)。
    public static func openTerminalToLoginCLI(completion: @escaping (Bool, String?) -> Void = { _, _ in }) {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        let banner = isZh ? "TokenBar：正在登录阿里云百炼 CLI…" : "TokenBar: signing in to Aliyun Bailian CLI…"
        let missingHint = isZh
            ? "未检测到百炼 CLI (bl)，请先安装：npm install -g @modelstudio/cli"
            : "Bailian CLI (bl) not found. Install it first: npm install -g @modelstudio/cli"

        let script = """
        #!/bin/zsh
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        echo "\(banner)"
        if ! command -v bl >/dev/null 2>&1; then
          echo "\(missingHint)"
          exit 1
        fi
        echo "$ \(cliLoginCommand)"
        \(cliLoginCommand)
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenBar-bailian-login.command")

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            runLoginViaAppleScript(completion: completion)
            return
        }

        let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([scriptURL], withApplicationAt: terminalURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                if error == nil {
                    completion(true, nil)
                } else {
                    runLoginViaAppleScript(completion: completion)
                }
            }
        }
    }

    /// 回退方案：通过 AppleScript 驱动终端（首次会弹出「自动化」授权请求）。
    private static func runLoginViaAppleScript(completion: @escaping (Bool, String?) -> Void) {
        let run = {
            let source = """
            tell application "Terminal"
                activate
                do script "\(cliLoginCommand)"
            end tell
            """
            var scriptError: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&scriptError)

            if scriptError == nil {
                completion(true, nil)
                return
            }

            let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
            let detail = (scriptError?[NSAppleScript.errorMessage] as? String) ?? ""
            let message = isZh
                ? "无法自动打开终端\(detail.isEmpty ? "" : "（\(detail)）")。请手动在终端执行：\(cliLoginCommand)"
                : "Could not open Terminal automatically\(detail.isEmpty ? "" : " (\(detail))"). Please run manually in Terminal: \(cliLoginCommand)"
            completion(false, message)
        }

        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    // MARK: - 通道编排

    /// 依据手上的凭证决定要依次尝试哪些通道。纯函数，便于单测。
    ///
    /// 有 AK/SK 时不单独跑 `.consoleToken` —— `.accessKey` 内部本来就会先用缓存令牌，
    /// 只有拿不到或遇到 NotLogined 才签发新的。
    public static func plannedChannels(for credentials: AliyunCredentials) -> [AliyunChannel] {
        var channels: [AliyunChannel] = []
        if credentials.hasAccessKey {
            channels.append(.accessKey)
        } else if credentials.hasConsoleToken {
            channels.append(.consoleToken)
        }
        channels.append(.cli)
        if credentials.hasCookie {
            channels.append(.cookie)
        }
        return channels
    }

    /// 按优先级依次尝试各通道；全部失败时抛出一条聚合了每级失败原因的错误。
    public func fetchQuota(credentials: AliyunCredentials) async throws -> AliyunQuotaResult {
        let channels = Self.plannedChannels(for: credentials)
        var failures: [(AliyunChannel, String)] = []

        for channel in channels {
            do {
                switch channel {
                case .accessKey:
                    return try await fetchViaAccessKey(credentials)
                case .consoleToken:
                    return try await fetchViaConsoleToken(credentials)
                case .cli:
                    return try await fetchViaCLI()
                case .cookie:
                    return try await fetchViaCookie(credentials)
                }
            } catch {
                failures.append((channel, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }

        throw Self.aggregateError(failures: failures, credentials: credentials)
    }

    /// 把各通道的失败原因拼成一条对用户有指导意义的错误。
    static func aggregateError(
        failures: [(AliyunChannel, String)],
        credentials: AliyunCredentials
    ) -> Error {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        guard !failures.isEmpty else { return AliyunChannelError.missingCredentials }

        let header = isZh ? "百炼额度获取失败：" : "Could not read Bailian quota:"
        let lines = failures.map { "· \($0.0.displayName)：\($0.1)" }
        var message = ([header] + lines).joined(separator: "\n")

        if !credentials.hasAccessKey {
            message += "\n" + (isZh
                ? "建议在设置中填写 AccessKey ID / Secret —— 这是唯一支持多台设备同时在线的方式。"
                : "Add an AccessKey ID / Secret in Settings — it is the only option that keeps several machines online at once.")
        }
        return NSError(domain: "AliyunBailianService", code: 401,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - 通道 1：AK/SK 原生（含失效自愈）

    /// 先用缓存令牌打网关；遇到 NotLogined 才用 AK/SK 换新令牌并**重试一次**。
    ///
    /// 三重防失控：直线代码不自我调用（最多 2 次网关 + 2 次签名）；
    /// `TokenCoordinator` 串行化签发，避免定时刷新与设置页「测试」按钮并发各签一个；
    /// 签发失败后 30 秒内复用上次错误，避免 AK 填错时反复打 OpenAPI。
    func fetchViaAccessKey(_ credentials: AliyunCredentials) async throws -> AliyunQuotaResult {
        var token = credentials.consoleAccessToken.trimmed
        var refreshedToken: String? = nil
        var freshlyIssued = false

        if token.isEmpty {
            token = try await tokenCoordinator.issue(using: credentials) { [weak self] in
                guard let self else { throw AliyunChannelError.missingCredentials }
                return try await self.generateConsoleAccessToken(credentials)
            }
            refreshedToken = token
            freshlyIssued = true
        }

        do {
            var result = try await queryTokenPlan(token: token, credentials: credentials, channel: .accessKey)
            result.refreshedToken = refreshedToken
            return result
        } catch AliyunChannelError.notLogined {
            // 刚换的令牌仍被判未登录 → 不是过期问题，直接抛，避免死循环
            if freshlyIssued { throw AliyunChannelError.notLoginedAfterRefresh }

            let newToken = try await tokenCoordinator.issue(using: credentials, force: true) { [weak self] in
                guard let self else { throw AliyunChannelError.missingCredentials }
                return try await self.generateConsoleAccessToken(credentials)
            }
            var result = try await queryTokenPlan(token: newToken, credentials: credentials, channel: .accessKey)
            result.refreshedToken = newToken
            return result
        }
    }

    /// 通道 2：只有现成令牌、没有 AK/SK —— 无法自愈，失败即降级。
    func fetchViaConsoleToken(_ credentials: AliyunCredentials) async throws -> AliyunQuotaResult {
        try await queryTokenPlan(
            token: credentials.consoleAccessToken.trimmed,
            credentials: credentials,
            channel: .consoleToken
        )
    }

    /// 用 AK/SK 调 `GenerateCLIAccessToken` 换一枚控制台令牌。
    func generateConsoleAccessToken(_ credentials: AliyunCredentials) async throws -> String {
        let host = Self.openAPIHost(region: credentials.consoleRegion)
        // 官方 CLI 在这里发的是**空 body、空 query**，签名必须完全一致
        let headers = AliyunSigner.signedHeaders(
            host: host,
            pathname: Self.generateTokenPath,
            method: "POST",
            action: Self.generateTokenAction,
            version: Self.generateTokenVersion,
            accessKeyId: credentials.accessKeyId.trimmed,
            accessKeySecret: credentials.accessKeySecret.trimmed
        )

        var request = URLRequest(url: URL(string: "https://\(host)\(Self.generateTokenPath)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        for (key, value) in headers where key != "host" {
            // host 交给 URLSession 自动填，手动设会被忽略甚至重复
            request.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AliyunChannelError.network(error.localizedDescription)
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let code = (json["Code"] as? String) ?? ""
        let message = (json["Message"] as? String) ?? ""

        if let token = (json["cliAccessToken"] as? String)?.trimmed,
           !token.isEmpty, status == 200, (json["Success"] as? Bool) != false {
            return token
        }
        throw Self.classifyOpenAPIError(status: status, code: code, message: message, raw: data)
    }

    /// 把 OpenAPI 的错误码翻译成可操作的分类。
    static func classifyOpenAPIError(status: Int, code: String, message: String, raw: Data) -> AliyunChannelError {
        let detail = message.isEmpty
            ? String(data: raw, encoding: .utf8)?.prefix(200).description ?? ""
            : message
        let joined = "\(code) \(message)"

        if code.contains("SignatureDoesNotMatch") || joined.contains("SignatureDoesNotMatch") {
            return .signatureMismatch(detail)
        }
        if code.contains("InvalidAccessKeyId") || code.contains("AccessKeyId.NotFound") {
            return .invalidAccessKey(detail)
        }
        if code.contains("Forbidden") || code.contains("NoPermission") || code.hasPrefix("NoPermission")
            || code.contains("RAM") || status == 403 {
            return .noPermission(detail)
        }
        return .gatewayError(code: code.isEmpty ? "HTTP \(status)" : code, message: detail)
    }

    // MARK: - 控制台网关（Bearer）

    /// `GenerateCLIAccessToken` 所在的 OpenAPI 域名。
    public static func openAPIHost(region: String) -> String {
        region.trimmed == "ap-southeast-1"
            ? "modelstudio.ap-southeast-1.aliyuncs.com"
            : "modelstudio.cn-beijing.aliyuncs.com"
    }

    /// 控制台网关的站点路由；未知 region 回落到 cn-beijing 那一档（保留 site）。
    public static func gatewayRoute(region: String, site: String) -> AliyunConsoleGatewayRoute {
        let isIntlSite = site.trimmed == "international"
        switch region.trimmed {
        case "ap-southeast-1":
            return AliyunConsoleGatewayRoute(
                host: isIntlSite ? "bailian-singapore-cs.alibabacloud.com" : "modelstudio-cs.console.aliyun.com",
                action: "IntlBroadScopeAspnGateway"
            )
        default:
            return AliyunConsoleGatewayRoute(
                host: isIntlSite ? "bailian-cs.console.alibabacloud.com" : "bailian-cs.console.aliyun.com",
                action: "BroadScopeAspnGateway"
            )
        }
    }

    /// 网关请求体里的 `params` JSON。
    public static func gatewayParamsJSON(api: String, switchAgent: Int?) -> String {
        var cornerstone: [String: Any] = [
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "switchUserType": 3,
            "consoleSite": "BAILIAN_ALIYUN"
        ]
        if let switchAgent { cornerstone["switchAgent"] = switchAgent }

        let payload: [String: Any] = [
            "Api": api,
            "V": "1.0",
            "Data": ["cornerstoneParam": cornerstone]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// 以 Bearer 令牌调控制台网关查 Token Plan 用量。
    func queryTokenPlan(
        token: String,
        credentials: AliyunCredentials,
        channel: AliyunChannel
    ) async throws -> AliyunQuotaResult {
        guard !token.isEmpty else { throw AliyunChannelError.notLogined }

        let route = Self.gatewayRoute(region: credentials.consoleRegion, site: credentials.consoleSite)
        let api = Self.tokenPlanUsageAPI
        let urlString = "https://\(route.host)/cli/api.json?action=\(route.action)"
            + "&product=sfm_bailian&api=\(AliyunSigner.percentEncode(api))"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Self.formBody([
            "params": Self.gatewayParamsJSON(api: api, switchAgent: credentials.switchAgentOrNil),
            "region": credentials.consoleRegion.trimmed
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AliyunChannelError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw AliyunChannelError.notLogined
        }

        let label = isZh
            ? "\(channel.displayName)（\(credentials.consoleRegion.trimmed)）"
            : "\(channel.displayName) (\(credentials.consoleRegion.trimmed))"
        return try Self.parseTokenPlanResponse(data, accountLabel: label, channel: channel)
    }

    /// `application/x-www-form-urlencoded` 请求体。
    ///
    /// 刻意不用 `URLComponents.percentEncodedQuery` —— 它的 query 允许集不转义 `& + =`，
    /// 一旦 params JSON 里出现这些字符就会把表单体拆坏。
    static func formBody(_ fields: [String: String]) -> Data {
        fields
            .sorted { $0.key < $1.key }
            .map { "\(AliyunSigner.percentEncode($0.key))=\(AliyunSigner.percentEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    // MARK: - 通道 3：官方 CLI

    public func fetchViaCLI() async throws -> AliyunQuotaResult {
        guard let blBinary = Self.locateBLBinary() else { throw AliyunChannelError.cliNotFound }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: blBinary)
                process.arguments = [
                    "usage", "token-plan",
                    "--console-region", "cn-beijing",
                    "--console-site", "domestic",
                    "--output", "json"
                ]

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
                    let label = isZh ? "百炼 CLI (cn-beijing)" : "Bailian CLI (cn-beijing)"
                    do {
                        let result = try Self.parseTokenPlanResponse(data, accountLabel: label, channel: .cli)
                        continuation.resume(returning: result)
                    } catch {
                        let raw = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
                        continuation.resume(throwing: (error as? AliyunChannelError)
                            ?? AliyunChannelError.cliFailed(String(raw)))
                    }
                } catch {
                    continuation.resume(throwing: AliyunChannelError.cliFailed(error.localizedDescription))
                }
            }
        }
    }

    static func locateBLBinary() -> String? {
        let candidates = ["/opt/homebrew/bin/bl", "/usr/local/bin/bl", "/usr/bin/bl"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in envPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("bl").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - 通道 4：控制台 Cookie（兜底）

    func fetchViaCookie(_ credentials: AliyunCredentials) async throws -> AliyunQuotaResult {
        let api = Self.tokenPlanUsageAPI
        let urlString = "https://bailian-cs.console.aliyun.com/data/api.json?action=BroadScopeAspnGateway"
            + "&product=sfm_bailian&api=\(AliyunSigner.percentEncode(api))&_v=undefined"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(credentials.cookie.trimmed, forHTTPHeaderField: "Cookie")
        request.setValue("https://bailian.console.aliyun.com", forHTTPHeaderField: "Origin")
        request.setValue("https://bailian.console.aliyun.com/cn-beijing?tab=plan", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        var cornerstone: [String: Any] = [
            "feTraceId": UUID().uuidString.lowercased(),
            "feURL": "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan",
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "switchUserType": 3,
            "domain": "bailian.console.aliyun.com",
            "consoleSite": "BAILIAN_ALIYUN",
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": "zh-CN"
        ]
        if let switchAgent = credentials.switchAgentOrNil { cornerstone["switchAgent"] = switchAgent }

        let paramsJSON = (try? JSONSerialization.data(withJSONObject: cornerstone))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        request.httpBody = Self.formBody(["params": paramsJSON, "region": "cn-beijing"])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AliyunChannelError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw AliyunChannelError.cookieExpired
        }

        let label = isZh ? "控制台网页授权" : "Console Web Auth"
        return try Self.parseTokenPlanResponse(data, accountLabel: label, channel: .cookie)
    }

    // MARK: - 令牌签发的串行化与节流

    /// 串行化令牌签发，并对连续失败做节流。
    private actor TokenCoordinator {
        private var cachedToken: String?
        private var lastFailure: (date: Date, error: Error)?
        private static let failureCooldown: TimeInterval = 30

        func issue(
            using credentials: AliyunCredentials,
            force: Bool = false,
            _ generate: @Sendable () async throws -> String
        ) async throws -> String {
            if !force, let cachedToken, !cachedToken.isEmpty { return cachedToken }

            // AK 填错时不要每轮刷新都去打 OpenAPI，30 秒内直接复用上次错误
            if let lastFailure, Date().timeIntervalSince(lastFailure.date) < Self.failureCooldown {
                throw lastFailure.error
            }

            do {
                let token = try await generate()
                cachedToken = token
                lastFailure = nil
                return token
            } catch {
                lastFailure = (Date(), error)
                throw error
            }
        }
    }
}
