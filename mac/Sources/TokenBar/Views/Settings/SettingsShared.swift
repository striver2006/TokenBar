import Foundation

/// 设置页各 tab 共用的纯函数辅助（原 SettingsView 私有方法，拆分时原样上提）。
enum SettingsValueFormat {
    /// 阈值显示：整数值省略小数位
    static func thresholdString(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    /// 阈值解析：非法输入回退到默认值
    static func parseThreshold(_ text: String, fallback: Double) -> Double {
        if let v = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), v >= 0 {
            return v
        }
        return fallback
    }
}

/// 「显示排序」与「通用」两个 tab 共用的厂商顺序推导
/// （原 SettingsView 的 enabledOrderKeys / orderDisplayName，拆分时原样上提）。
enum SettingsOrdering {
    /// 当前已启用厂商的显示顺序键（已按 providerOrder 排序，未列入的按默认顺序追加）。
    static func enabledOrderKeys(in settings: AppSettings) -> [String] {
        var keys: [String] = ProviderOrdering.defaultOrder.compactMap { key in
            guard let type = ProviderOrdering.parseProviderType(key), settings.isEnabled(type) else { return nil }
            return key
        }
        keys.append(contentsOf: settings.customProviders.filter(\.isEnabled).map { ProviderOrdering.customKey($0.id) })

        let order = settings.providerOrder
        return keys
            .enumerated()
            .sorted {
                let l = ProviderOrdering.sortIndex($0.element, order: order)
                let r = ProviderOrdering.sortIndex($1.element, order: order)
                return (l, $0.offset) < (r, $1.offset)
            }
            .map { $0.element }
    }

    static func displayName(for key: String, in settings: AppSettings) -> String {
        if let type = ProviderOrdering.parseProviderType(key) {
            return type.displayName
        }
        if let id = ProviderOrdering.parseCustomKey(key) {
            return settings.customProviders.first { $0.id == id }?.name ?? key
        }
        return key
    }
}
