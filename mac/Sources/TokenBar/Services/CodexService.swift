import Foundation
import Darwin

/// Read-only account RPCs through the official Codex app-server. Codex owns credentials
/// and token refresh; TokenBar never reads or stores its OAuth tokens.
public final class CodexService: @unchecked Sendable {
    public static let shared = CodexService()

    public func fetchQuota(executablePath: String = "") async throws -> (TokenWindow?, TokenWindow?, String?) {
        let isZh = LocalizationManager.shared.effectiveLanguage == "zh"
        return try await Task.detached {
            try Self.query(executablePath: executablePath, isZh: isZh)
        }.value
    }

    static func resolveExecutable(_ configured: String) throws -> String {
        let fm = FileManager.default
        let explicit = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            let path = NSString(string: explicit).expandingTildeInPath
            guard path.hasPrefix("/"), fm.isExecutableFile(atPath: path) else {
                throw error("Codex 路径无效，请填写可执行文件的绝对路径", "Invalid Codex path; enter an absolute executable path")
            }
            return path
        }
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { "\($0)/codex" }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                       "/Applications/Codex.app/Contents/Resources/codex"]
        let extensions = "\(home)/.vscode/extensions"
        for folder in ((try? fm.contentsOfDirectory(atPath: extensions)) ?? []).sorted().reversed()
            where folder.hasPrefix("openai.chatgpt-") {
            #if arch(arm64)
            candidates.append("\(extensions)/\(folder)/bin/macos-aarch64/codex")
            #else
            candidates.append("\(extensions)/\(folder)/bin/macos-x86_64/codex")
            #endif
        }
        guard let path = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw error("未找到 Codex，请安装 Codex CLI 或填写可执行文件路径", "Codex not found; install Codex CLI or enter its executable path")
        }
        return path
    }

    static func query(executablePath: String, isZh: Bool, timeoutSeconds: TimeInterval = 20) throws -> (TokenWindow?, TokenWindow?, String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try resolveExecutable(executablePath))
        process.arguments = ["app-server"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        var pending = Data()
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func response(_ id: Int) throws -> [String: Any] {
            while true {
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending.prefix(upTo: newline)
                    pending.removeSubrange(...newline)
                    guard let json = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                          json["id"] as? Int == id else { continue }
                    if json["error"] != nil {
                        // RPC diagnostics may contain account details. Keep UI/log errors generic.
                        throw error("Codex 查询失败，请确认已用 ChatGPT 订阅账号登录，并更新 Codex 后重试", "Codex query failed; sign in with your ChatGPT subscription and update Codex", isZh: isZh)
                    }
                    guard let result = json["result"] as? [String: Any] else { throw URLError(.cannotParseResponse) }
                    return result
                }
                let chunk = output.fileHandleForReading.availableData
                guard !chunk.isEmpty else {
                    throw error("Codex 查询超时或进程退出，请检查登录状态及网络", "Codex timed out or exited; check your login and network", isZh: isZh)
                }
                pending.append(chunk)
                guard pending.count <= 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
            }
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "tokenbar", "version": "1.0"]]])
        _ = try response(1)
        try send(["method": "initialized", "params": [:]])
        try send(["id": 2, "method": "account/read", "params": ["refreshToken": false]])
        let accountResult = try response(2)
        guard let account = accountResult["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
            throw error("请先在 Codex 中使用 ChatGPT 订阅账号登录（codex login）", "Sign in to Codex with your ChatGPT subscription (codex login)", isZh: isZh)
        }
        try send(["id": 3, "method": "account/rateLimits/read"])
        let result = try response(3)
        let windows = try parseRateLimits(result)
        let plan = account["planType"] as? String ?? "ChatGPT"
        return (windows.0, windows.1, "Codex · \(plan)")
    }

    static func parseRateLimits(_ result: [String: Any]) throws -> (TokenWindow?, TokenWindow?) {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        let limits = buckets?["codex"] as? [String: Any] ?? result["rateLimits"] as? [String: Any]
        guard let limits else { throw URLError(.cannotParseResponse) }
        func window(_ key: String) throws -> TokenWindow? {
            guard let value = limits[key], !(value is NSNull) else { return nil }
            guard let raw = value as? [String: Any],
                  let used = raw["usedPercent"] as? NSNumber,
                  let duration = raw["windowDurationMins"] as? NSNumber,
                  let reset = raw["resetsAt"] as? NSNumber,
                  CFGetTypeID(used) != CFBooleanGetTypeID(),
                  CFGetTypeID(duration) != CFBooleanGetTypeID(),
                  CFGetTypeID(reset) != CFBooleanGetTypeID(),
                  used.doubleValue.isFinite, duration.doubleValue.isFinite, reset.doubleValue.isFinite,
                  duration.doubleValue > 0, duration.doubleValue <= 525_600,
                  reset.doubleValue > 0, reset.doubleValue < 253_402_300_800 else {
                throw URLError(.cannotParseResponse)
            }
            let end = Date(timeIntervalSince1970: reset.doubleValue)
            let title: WindowTitle = duration.doubleValue == 300 ? .fiveHour
                : duration.doubleValue == 10_080 ? .weekly : .custom("Codex (\(duration.intValue) min)")
            return TokenWindow(title: title, usedPercentage: used.doubleValue,
                               startTime: end.addingTimeInterval(-duration.doubleValue * 60), endTime: end)
        }
        let primary = try window("primary"), secondary = try window("secondary")
        guard primary != nil || secondary != nil else {
            throw error("Codex 未返回订阅额度窗口，请稍后重试", "Codex returned no subscription quota windows; retry later")
        }
        return (primary, secondary)
    }

    private static func error(_ zh: String, _ en: String, isZh: Bool? = nil) -> NSError {
        NSError(domain: "CodexService", code: 1, userInfo: [NSLocalizedDescriptionKey:
            (isZh ?? (LocalizationManager.shared.effectiveLanguage == "zh")) ? zh : en])
    }
}
