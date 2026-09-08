import Foundation

/// 纯本地余额历史记录：每次刷新成功后追加一条 (时间, 余额)，
/// 用于估算日均消耗并给出"预计可用 X 天"。
/// 文件位于 ~/Library/Application Support/TokenBar/balance_history.json，保留 30 天。
public final class BalanceHistoryStore: @unchecked Sendable {
    public static let shared = BalanceHistoryStore()

    private struct BalancePoint: Codable {
        var t: Date
        var v: Double
    }

    private let lock = NSLock()
    private let retentionDays = 30.0
    private let minSampleSpanDays = 1.0
    private let minSampleCount = 4

    private var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("TokenBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("balance_history.json")
    }

    private init() {}

    private func load() -> [String: [BalancePoint]] {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [BalancePoint]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func save(_ data: [String: [BalancePoint]]) {
        guard let url = fileURL,
              let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: url, options: .atomic)
    }

    /// 记录一次余额读数；同 provider 距上一条不足 30 分钟时覆盖上一条
    public func record(providerKey: String, value: Double) {
        guard !providerKey.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var data = load()
        let now = Date()
        var points = data[providerKey] ?? []

        if let last = points.last, now.timeIntervalSince(last.t) < 30 * 60 {
            points[points.count - 1] = BalancePoint(t: now, v: value)
        } else {
            points.append(BalancePoint(t: now, v: value))
        }

        let cutoff = now.addingTimeInterval(-retentionDays * 86400)
        points = points.filter { $0.t >= cutoff }
        if points.isEmpty {
            data.removeValue(forKey: providerKey)
        } else {
            data[providerKey] = points
        }
        save(data)
    }

    /// 基于近 7 天历史估算日均消耗，结合当前余额推算可用天数；样本不足返回 nil
    public func forecastDays(providerKey: String, currentAmount: Double) -> Double? {
        guard !providerKey.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }

        let points = load()[providerKey] ?? []
        guard points.count >= minSampleCount else { return nil }

        let windowStart = Date().addingTimeInterval(-7 * 86400)
        let samples = points.filter { $0.t >= windowStart }.sorted { $0.t < $1.t }
        guard samples.count >= minSampleCount,
              let first = samples.first,
              let last = samples.last else { return nil }

        let spanDays = last.t.timeIntervalSince(first.t) / 86400
        guard spanDays >= minSampleSpanDays else { return nil }

        let consumed = first.v - last.v
        guard consumed > 0 else { return nil } // 期间有过充值或无消耗，不给出预测

        let dailyBurn = consumed / spanDays
        guard dailyBurn > 0 else { return nil }

        return min(currentAmount / dailyBurn, 999)
    }

    /// 清除指定厂商（或全部）历史
    public func clear(providerKey: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var data = load()
        if let key = providerKey {
            data.removeValue(forKey: key)
        } else {
            data.removeAll()
        }
        save(data)
    }
}
