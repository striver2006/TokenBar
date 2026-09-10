import Foundation

/// 各厂商 `x-ratelimit-reset-*` 头的统一解析。
///
/// 网关返回的形状五花八门：OpenAI 是 Go duration（`20ms` / `1s` / `6m0s` / `1h2m`），
/// 部分中转站是纯秒数（`30`），也有直接给 unix 时间戳的（秒 `1710000000` 或毫秒 `1710000000000`）。
/// 以前各服务各写一份，且把时间戳当秒数会算出几十年后的重置时间。
/// 这里按量级区分：> 1e12 视为毫秒时间戳，> 1e9 视为秒时间戳，其余视为时长；结果统一 clamp 到 [0, 24h]。
public enum RateLimitReset {
    public static let maxSeconds: TimeInterval = 86400

    /// 返回距今的秒数；无法解析返回 nil（调用方自行决定兜底值，不要再假装是 1 秒）。
    public static func parse(_ raw: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw else { return nil }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean.isEmpty { return nil }

        if let direct = Double(clean) {
            if direct > 1e12 { return clamp(Date(timeIntervalSince1970: direct / 1000).timeIntervalSince(now)) }
            if direct > 1e9 { return clamp(Date(timeIntervalSince1970: direct).timeIntervalSince(now)) }
            return clamp(direct)
        }

        // Go duration：数字后跟单位，可多段拼接
        var total: TimeInterval = 0
        var number = ""
        var unit = ""
        var sawUnit = false
        func flush() -> Bool {
            guard let value = Double(number) else { return false }
            switch unit {
            case "ms": total += value / 1000
            case "s": total += value
            case "m": total += value * 60
            case "h": total += value * 3600
            case "d": total += value * 86400
            default: return false
            }
            sawUnit = true
            number = ""; unit = ""
            return true
        }
        for ch in clean {
            if ch.isNumber || ch == "." {
                if !unit.isEmpty { guard flush() else { return nil } }
                number.append(ch)
            } else if ch.isLetter {
                unit.append(ch)
            } else if ch == " " {
                continue
            } else {
                return nil
            }
        }
        if !number.isEmpty || !unit.isEmpty { guard flush() else { return nil } }
        return sawUnit ? clamp(total) : nil
    }

    private static func clamp(_ v: TimeInterval) -> TimeInterval {
        min(max(v, 0), maxSeconds)
    }
}
