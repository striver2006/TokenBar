import Foundation
import os

/// 全项目统一的日志出口。
///
/// 级别按 os_log 的落盘规则挑选，不是随手写的：
/// - `.notice` / `.error` 会持久化到系统日志，事后能用 `log show --last 1h` 回溯；
/// - `.info` / `.debug` 只驻内存缓冲，必须 `log stream` 现场盯着才看得到。
/// 因此"用户过几天来报障、我要能倒查"的事件（定时器 fire、每轮开始结束、
/// 厂商超时、闸门抢占）一律 notice/error；单次请求耗时这类高频细节用 info/debug。
///
/// 排查命令：
///     log stream --predicate 'subsystem == "com.tokenbar.mac"' --level debug --style compact
///     log show --last 1h --predicate 'subsystem == "com.tokenbar.mac"' --info --style compact
///
/// 隐私红线：Logger 对非字面量插值默认按 `<private>` 处理，这是安全的默认值。
/// 只有确定不敏感的值（厂商标识、耗时、HTTP 状态码、触发来源、间隔秒数）才标
/// `privacy: .public`。绝不记录 apiKey / token / accessKeySecret / Cookie /
/// refreshToken 及其任何片段、请求头、请求体；URL 只记 host + path，丢掉 query；
/// error.localizedDescription 保持 private —— 百炼的 aggregateError 会把服务端
/// 回显拼进去，可能带上账号信息。
public enum Log {
    public static let subsystem = "com.tokenbar.mac"

    /// 定时器生命周期：创建、fire、失效自愈
    public static let timer = Logger(subsystem: subsystem, category: "timer")
    /// 刷新轮次：开始、结束、闸门跳过与抢占
    public static let refresh = Logger(subsystem: subsystem, category: "refresh")
    /// 单厂商：耗时、成功、失败原因、超时
    public static let provider = Logger(subsystem: subsystem, category: "provider")
    /// 网络层细节
    public static let net = Logger(subsystem: subsystem, category: "net")
    /// App 生命周期、菜单栏、唤醒
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}

extension URL {
    /// 日志用的安全短名：只保留 host + path，丢掉可能带密钥的 query。
    var logSafeDescription: String {
        "\(host ?? "?")\(path)"
    }
}
