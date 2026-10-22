import Foundation

/// 每次只保留一个到期重试。冷却期间反复点击刷新不延后已安排的重试。
@MainActor
final class GeminiRetryScheduler {
    private var task: Task<Void, Never>?
    private(set) var deadline: Date?

    func schedule(
        at date: Date,
        ready: @escaping @MainActor () -> Bool = { true },
        operation: @escaping @MainActor () async -> Void
    ) {
        if let deadline, deadline <= date { return }
        cancel()
        deadline = date
        task = Task { @MainActor [weak self] in
            do {
                // 按截止时间等待；睡眠唤醒或提前返回也不能提前越过冷却。
                while date > Date() {
                    try await Task.sleep(nanoseconds: UInt64(max(0, date.timeIntervalSinceNow) * 1_000_000_000))
                }
                while !ready() {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try Task.checkCancellation()
            } catch { return }
            guard let self else { return }
            self.deadline = nil
            self.task = nil
            await operation()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        deadline = nil
    }

    deinit { task?.cancel() }
}
