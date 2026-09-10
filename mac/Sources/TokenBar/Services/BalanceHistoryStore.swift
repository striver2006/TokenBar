import Foundation

/// 纯本地余额历史记录：每次刷新成功后追加一条 (时间, 余额)，
/// 用于估算日均消耗并给出"预计可用 X 天"。
/// 文件位于 ~/Library/Application Support/TokenBar/balance_history.json，保留 30 天。
///
/// actor 而非 NSLock：以前 record / forecastDays 各自同步 load 一次全量 JSON、record 再
/// atomic write 一次，全部跑在 MainActor 上且持锁跨越磁盘 IO——磁盘一慢，整条刷新链路
/// 和 UI 一起冻结（与 ARCH 2.2.1 第 2 条同理）。现在内存里常驻一份，磁盘只在首次访问时
/// 读一次、每次写入时落一次，都在 actor 自己的执行器上。
public actor BalanceHistoryStore {
    public static let shared = BalanceHistoryStore()

    private struct BalancePoint: Codable {
        var t: Date
        var v: Double
    }

    private let retentionDays = 30.0
    private let minSampleSpanDays = 1.0
    private let minSampleCount = 4

    /// 内存副本；nil 表示还没从磁盘加载过
    private var cache: [String: [BalancePoint]]?

    private var fileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("TokenBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("balance_history.json")
    }

    private init() {}

    private func loaded() -> [String: [BalancePoint]] {
        if let cache { return cache }
        var data: [String: [BalancePoint]] = [:]
        if let url = fileURL, let raw = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [BalancePoint]].self, from: raw) {
            data = decoded
        }
        cache = data
        return data
    }

    private func persist(_ data: [String: [BalancePoint]]) {
        cache = data
        guard let url = fileURL,
              let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: url, options: .atomic)
    }

    /// 记录一次余额读数；同 provider 距上一条不足 30 分钟时覆盖上一条
    public func record(providerKey: String, value: Double) {
        guard !providerKey.isEmpty else { return }

        var data = loaded()
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
        persist(data)
    }

    /// 基于近 7 天历史估算日均消耗，结合当前余额推算可用天数；样本不足返回 nil
    public func forecastDays(providerKey: String, currentAmount: Double) -> Double? {
        guard !providerKey.isEmpty else { return nil }

        let points = loaded()[providerKey] ?? []
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

    /// 记录读数并返回预计可用天数，一次 actor 跳转完成两件事
    public func recordAndForecast(providerKey: String, value: Double) -> Double? {
        record(providerKey: providerKey, value: value)
        return forecastDays(providerKey: providerKey, currentAmount: value)
    }

    /// 清除指定厂商（或全部）历史
    public func clear(providerKey: String? = nil) {
        var data = loaded()
        if let key = providerKey {
            data.removeValue(forKey: key)
        } else {
            data.removeAll()
        }
        persist(data)
    }
}
