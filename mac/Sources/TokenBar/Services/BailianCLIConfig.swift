import Foundation

/// 只读解析官方百炼 CLI (`bl`) 的配置文件 `~/.bailian/config.json`。
///
/// 用途：本机若已经用 `bl auth login` 登录过，TokenBar 可以直接复用其中的
/// 控制台 `access_token`（以及 AK/SK），省掉一次多余的 token 签发，
/// 也让老用户零配置即可看到额度。
///
/// **只读，绝不写回**：CLI 用 tmp + rename 原子替换整个文件，TokenBar 并发写
/// 会把 CLI 期间写入的其他字段（api_key、workspace_id、skill 状态等）整体覆盖掉。
/// token 再签发的成本极低，不值得为省这一次调用去冒写坏用户 CLI 配置的风险。
public struct BailianCLIConfig: Equatable {
    public var accessToken: String?
    public var accessKeyId: String?
    public var accessKeySecret: String?
    public var consoleRegion: String?
    public var consoleSite: String?
    /// 阿里云 UID 可能是 16 位；Swift 的 Int 在 64 位平台足够，Windows 端对应 long。
    public var consoleSwitchAgent: Int?

    public init(
        accessToken: String? = nil,
        accessKeyId: String? = nil,
        accessKeySecret: String? = nil,
        consoleRegion: String? = nil,
        consoleSite: String? = nil,
        consoleSwitchAgent: Int? = nil
    ) {
        self.accessToken = accessToken
        self.accessKeyId = accessKeyId
        self.accessKeySecret = accessKeySecret
        self.consoleRegion = consoleRegion
        self.consoleSite = consoleSite
        self.consoleSwitchAgent = consoleSwitchAgent
    }

    /// 配置文件所在目录：`BAILIAN_CONFIG_DIR` 优先，否则 `~/.bailian`。
    /// （与 CLI 内部的目录解析规则一致。）
    public static func configDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["BAILIAN_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bailian", isDirectory: true)
    }

    /// 读盘并解析；文件不存在或格式不对时返回 nil（不是错误，只是没有可复用的凭证）。
    public static func loadFromDisk(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BailianCLIConfig? {
        let url = configDirectory(environment: environment).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return parse(json: json)
    }

    /// 纯解析，不碰文件系统，便于单测。
    ///
    /// CLI 支持多 profile：顶层 `active_config` 指向某个 profile 名，该名对应的
    /// 顶层字段若是对象则为 profile 段。取值优先 profile 段，缺字段回落顶层。
    public static func parse(json: [String: Any]) -> BailianCLIConfig {
        var profile: [String: Any] = [:]
        if let activeName = json["active_config"] as? String,
           let section = json[activeName] as? [String: Any] {
            profile = section
        }

        func string(_ key: String) -> String? {
            let raw = (profile[key] as? String) ?? (json[key] as? String)
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        func int(_ key: String) -> Int? {
            if let n = (profile[key] as? NSNumber) ?? (json[key] as? NSNumber) { return n.intValue }
            if let s = string(key) { return Int(s) }
            return nil
        }

        return BailianCLIConfig(
            accessToken: string("access_token"),
            accessKeyId: string("access_key_id"),
            accessKeySecret: string("access_key_secret"),
            consoleRegion: string("console_region"),
            consoleSite: string("console_site"),
            consoleSwitchAgent: int("console_switch_agent")
        )
    }
}
