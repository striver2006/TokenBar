import Foundation

/// 一次性 resume 守卫：超时与完成两条路只允许一条恢复 continuation。
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var cont: CheckedContinuation<T, Never>?

    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }

    func resume(_ value: T) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// 在 `seconds` 内等待 `operation` 完成。
///
/// - 返回 `true`：按时完成；`false`：超时（operation 已被 cancel）。
///
/// 刻意**没有**用 `withTaskGroup` 竞速那种写法：`group.cancelAll()` 之后从 group
/// body 返回时，运行时会隐式 await 剩余子任务，所以对不响应取消的操作（例如
/// `Process.waitUntilExit`）完全无效，超时会假装生效但实际照样卡住。这里用非结构化
/// Task，超时分支能真正放弃等待。
///
/// 代价是被放弃的 operation 可能还在后台跑完并写回状态。由于调用方 RefreshManager
/// 是 `@MainActor`，写入是串行的，最坏情况只是迟到的写入覆盖一次，可以接受。
///
/// `URLSession` 的请求响应 Task 取消（抛 `URLError(.cancelled)`），所以网络路径会
/// 被真正掐断；不可取消的子进程路径必须自己带看门狗，见 `AliyunBailianService.fetchViaCLI`。
@discardableResult
public func withTimeout(
    seconds: TimeInterval,
    label: String = "",
    operation: @escaping @Sendable @MainActor () async -> Void
) async -> Bool {
    let scheduled = DispatchTime.now()
    let work = Task { @MainActor in
        if !label.isEmpty {
            let waited = Double(DispatchTime.now().uptimeNanoseconds - scheduled.uptimeNanoseconds) / 1_000_000
            Log.provider.debug("provider=\(label, privacy: .public) body enter (排队 \(waited, format: .fixed(precision: 0))ms)")
        }
        await operation()
    }

    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        let gate = ResumeOnce<Bool>(cont)

        // 哨兵必须在正常完成时被取消：否则每轮每个厂商都会留下一个睡满 25~35 秒的 Task，
        // 1 分钟刷新间隔下常驻十几个悬挂任务。Task.sleep 响应取消，cancel 后立即退出。
        let sleeper = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return // 被取消：操作已按时完成
            }
            if !label.isEmpty {
                let fired = Double(DispatchTime.now().uptimeNanoseconds - scheduled.uptimeNanoseconds) / 1_000_000
                Log.provider.debug("provider=\(label, privacy: .public) 超时哨兵在 \(fired, format: .fixed(precision: 0))ms 触发")
            }
            guard !work.isCancelled else { return }
            work.cancel()
            gate.resume(false)
        }
        Task {
            await work.value
            sleeper.cancel()
            gate.resume(true)
        }
    }
}
