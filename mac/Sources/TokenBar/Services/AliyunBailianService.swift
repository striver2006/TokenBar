import Foundation
import AppKit

public final class AliyunBailianService: @unchecked Sendable {
    public static let shared = AliyunBailianService()

    /// Opens macOS Terminal to run `bl auth login --console`
    public static func openTerminalToLoginCLI() {
        let script = "tell application \"Terminal\" to do script \"bl auth login --console\""
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }

    /// Fetch Aliyun Bailian Token Plan quota.
    /// Priority:
    /// 1. Official Bailian CLI (`bl usage token-plan ...`)
    /// 2. Bailian Console Web API (via Session Cookie)
    public func fetchQuota(
        apiKey: String? = nil,
        cookie: String? = nil,
        endpoint: String = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
    ) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        var cliError: Error? = nil

        // 1. Try official Bailian CLI (`bl`)
        do {
            return try await fetchViaCLI()
        } catch {
            cliError = error
        }

        // 2. Try Console Web Cookie if available
        if let cookie = cookie?.trimmingCharacters(in: .whitespacesAndNewlines), !cookie.isEmpty {
            do {
                return try await fetchViaConsole(cookie: cookie)
            } catch {
                throw error
            }
        }

        // 3. If neither worked, provide clear, accurate guidance
        if let err = cliError {
            throw err
        }

        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        throw NSError(
            domain: "AliyunBailianService",
            code: 400,
            userInfo: [NSLocalizedDescriptionKey: isZh ? "百炼兼容 OpenAI 接口仅用于模型对话，不支持配额查询。请在终端登录百炼 CLI (`bl auth login --console`) 或使用网页登录授权获取 7天 与 5小时额度。" : "Aliyun Bailian OpenAI-compatible endpoint only supports chat, not quota queries. Please run `bl auth login --console` in terminal or configure web cookies to monitor 7-day and 5-hour quotas."]
        )
    }

    /// Fetch Token Plan quota via official Bailian CLI (`bl`)
    public func fetchViaCLI() async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        let blCandidates = [
            "/opt/homebrew/bin/bl",
            "/usr/local/bin/bl",
            "/usr/bin/bl"
        ]
        var resolvedPath: String? = nil
        for candidate in blCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                resolvedPath = candidate
                break
            }
        }
        if resolvedPath == nil {
            let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
            for dir in envPath.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("bl").path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    resolvedPath = candidate
                    break
                }
            }
        }

        guard let blBinary = resolvedPath else {
            let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
            throw NSError(
                domain: "AliyunBailianService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: isZh ? "未检测到百炼 CLI ('bl')。可在终端通过 npm install -g @modelstudio/cli 安装，或使用网页登录授权。" : "Bailian CLI ('bl') not detected. Install via npm install -g @modelstudio/cli in terminal, or configure web cookies."]
            )
        }

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
                    if let res = try? self.parseTokenPlanJSON(data, accountLabel: isZh ? "百炼 CLI (cn-beijing)" : "Bailian CLI (cn-beijing)") {
                        continuation.resume(returning: res)
                        return
                    }

                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errorObj = json["error"] as? [String: Any],
                       let msg = errorObj["message"] as? String {
                        let hint = errorObj["hint"] as? String ?? (isZh ? "请运行 bl auth login --console 登录" : "Please run bl auth login --console to login")
                        continuation.resume(throwing: NSError(
                            domain: "AliyunBailianService",
                            code: 401,
                            userInfo: [NSLocalizedDescriptionKey: "\(msg) (\(hint))"]
                        ))
                        return
                    }

                    let raw = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(throwing: NSError(
                        domain: "AliyunBailianService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: isZh ? "CLI 返回格式不符合预期: \(raw.prefix(200))" : "CLI returned unexpected format: \(raw.prefix(200))"]
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fetch Token Plan quota via Bailian Console Web API
    public func fetchViaConsole(cookie: String) async throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        guard let url = URL(string: "https://bailian-cs.console.aliyun.com/data/api.json?action=BroadScopeAspnGateway&product=sfm_bailian&api=zeldaHttp.apikeyMgr.%2Ftokenplan%2Fpersonal%2Fapi%2Fv2%2Fusage&_v=undefined") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://bailian.console.aliyun.com", forHTTPHeaderField: "Origin")
        request.setValue("https://bailian.console.aliyun.com/cn-beijing?tab=plan", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.timeoutInterval = 10

        let traceId = UUID().uuidString.lowercased()
        let cornerstoneParams: [String: Any] = [
            "feTraceId": traceId,
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

        let paramsJSON = (try? JSONSerialization.data(withJSONObject: cornerstoneParams)) ?? Data()
        let paramsString = String(data: paramsJSON, encoding: .utf8) ?? "{}"

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "params", value: paramsString),
            URLQueryItem(name: "region", value: "cn-beijing")
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        if httpResp.statusCode == 401 || httpResp.statusCode == 403 {
            throw NSError(domain: "AliyunBailianService", code: 401, userInfo: [NSLocalizedDescriptionKey: isZh ? "控制台 Cookie 已失效，请重新登录授权" : "Console Cookie expired. Please log in and authorize again"])
        }

        return try parseTokenPlanJSON(data, accountLabel: isZh ? "控制台网页授权" : "Console Web Auth")
    }

    /// Parse Bailian 7-day and 5-hour Token Plan JSON response
    public func parseTokenPlanJSON(_ data: Data, accountLabel: String) throws -> (fiveHour: TokenWindow?, weekly: TokenWindow?, account: String?) {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AliyunBailianService", code: -1, userInfo: [NSLocalizedDescriptionKey: isZh ? "无法解析百炼配额响应数据" : "Unable to parse Bailian quota response data"])
        }

        if let errorObj = json["error"] as? [String: Any] {
            let msg = errorObj["message"] as? String ?? (isZh ? "未知错误" : "Unknown error")
            let hint = errorObj["hint"] as? String ?? (isZh ? "请运行 bl auth login --console 登录" : "Please run bl auth login --console to login")
            throw NSError(domain: "AliyunBailianService", code: 401, userInfo: [NSLocalizedDescriptionKey: "\(msg) (\(hint))"])
        }

        var payload = json
        if let dataObj = json["data"] as? [String: Any] {
            payload = dataObj
        }

        let per1WeekPctVal = (payload["per1WeekPercentage"] as? NSNumber)?.doubleValue
        let per1WeekResetMs = (payload["per1WeekResetTime"] as? NSNumber)?.doubleValue
        let per5HourPctVal = (payload["per5HourPercentage"] as? NSNumber)?.doubleValue
        let per5HourResetMs = (payload["per5HourResetTime"] as? NSNumber)?.doubleValue

        guard per1WeekPctVal != nil || per5HourPctVal != nil else {
            throw NSError(domain: "AliyunBailianService", code: -2, userInfo: [NSLocalizedDescriptionKey: isZh ? "返回数据中未包含 7天或5小时配额字段" : "Response data missing 7-day or 5-hour quota fields"])
        }

        var weeklyWindow: TokenWindow? = nil
        if let weekPct = per1WeekPctVal {
            let usedPct = min(max(weekPct * 100.0, 0.0), 100.0)
            let resetDate: Date
            if let ms = per1WeekResetMs, ms > 0 {
                resetDate = Date(timeIntervalSince1970: ms / 1000.0)
            } else {
                resetDate = Date().addingTimeInterval(7 * 86400)
            }
            let startDate = resetDate.addingTimeInterval(-7 * 86400)

            weeklyWindow = TokenWindow(
                title: "7天周期额度",
                usedPercentage: usedPct,
                startTime: startDate,
                endTime: resetDate,
                unit: "%",
                isIdle: usedPct == 0.0
            )
        }

        var fiveHourWindow: TokenWindow? = nil
        if let fivePct = per5HourPctVal {
            let usedPct = min(max(fivePct * 100.0, 0.0), 100.0)
            let resetDate: Date
            if let ms = per5HourResetMs, ms > 0 {
                resetDate = Date(timeIntervalSince1970: ms / 1000.0)
            } else {
                resetDate = Date().addingTimeInterval(5 * 3600)
            }
            let startDate = resetDate.addingTimeInterval(-5 * 3600)

            fiveHourWindow = TokenWindow(
                title: "5小时额度",
                usedPercentage: usedPct,
                startTime: startDate,
                endTime: resetDate,
                unit: "%",
                isIdle: usedPct == 0.0
            )
        }

        return (fiveHourWindow, weeklyWindow, accountLabel)
    }
}
