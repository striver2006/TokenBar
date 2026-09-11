import AppKit
import Darwin
import Foundation

/// 跨进程排他锁，基于 flock。
///
/// 为什么用 flock 而不是按 bundle ID 查 NSRunningApplication：开发构建
/// （mac/build/TokenBar.app）和正式安装版（/Applications/TokenBar.app）
/// 共用同一个 bundle ID，两者能同时跑出两个菜单栏图标；flock 按文件加锁，
/// 只要落到同一个锁文件就拦得住，不依赖进程注册时机。锁随进程退出（含崩溃）
/// 由内核自动释放，不存在残留死锁。
final class ProcessSingletonLock {
    private var fd: Int32 = -1

    /// 在指定目录下尝试获取 `fileName` 的排他锁。
    /// - Returns: false 表示锁已被另一个进程持有。fd 由本对象持有到进程结束，无需显式解锁。
    init(directory: URL, fileName: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(fileName).path
        let newFD = open(path, O_RDWR | O_CREAT, 0o644)
        guard newFD >= 0 else {
            // 连锁文件都建不了（目录不可写等），退化为不拦截，别让应用起不来
            return
        }
        if flock(newFD, LOCK_EX | LOCK_NB) == 0 {
            fd = newFD
        } else {
            close(newFD)
        }
    }

    var isLocked: Bool { fd >= 0 }

    deinit {
        if fd >= 0 { close(fd) }
    }
}

/// 单实例守卫：第二个实例启动时唤醒已运行的实例（弹出面板）后自行退出，
/// 与 Windows 端 App.xaml.cs 的 Mutex 方案行为对齐。
enum SingleInstanceGuard {
    /// 已运行实例收到该分布式通知后弹出面板。object 用 bundle ID 过滤，
    /// 避免误响应其他应用的同名通知。
    static let activateNotificationName = "com.tokenbar.mac.activateExistingInstance"

    private static var lock: ProcessSingletonLock?

    /// 尝试成为唯一实例。必须在 NSApplication 启动前调用。
    /// - Returns: false 表示已有实例在运行，调用方应唤醒它并退出。
    @discardableResult
    static func tryBecomeOnlyInstance() -> Bool {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let newLock = ProcessSingletonLock(directory: directory.appendingPathComponent("TokenBar", isDirectory: true),
                                           fileName: "singleton.lock")
        lock = newLock
        return newLock.isLocked
    }

    /// 唤醒已运行的实例：发分布式通知让它弹出面板，再尽力把它带到前台。
    static func activateExistingInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(activateNotificationName),
            object: Bundle.main.bundleIdentifier,
            userInfo: nil,
            deliverImmediately: true
        )
        let ownPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.processIdentifier != ownPID }?
            .activate()
        Log.lifecycle.notice("检测到已有 TokenBar 实例，已唤醒并退出当前进程")
    }
}
