import SwiftUI

/// 设置页 – 通用 tab。无输入状态，控件直接经 savingBinding 读写 settings。
@MainActor
struct SettingsGeneralTab: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared

    init(refreshManager: RefreshManager) {
        self.refreshManager = refreshManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18n(.generalPreferencesTitle))
                .font(.system(size: 15, weight: .bold))

            Divider()

            // Language Selector
            HStack {
                Text(I18n(.interfaceLanguage))
                    .font(.system(size: 13))
                Spacer()
                Picker("", selection: savingBinding(\.appLanguage)) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .frame(width: 180)
                .id(i18n.currentLanguage)
            }

            // Refresh Interval
            HStack {
                Text(I18n(.refreshInterval))
                    .font(.system(size: 13))
                Spacer()
                Picker("", selection: savingBinding(\.refreshIntervalMinutes)) {
                    Text(I18n(.refresh1Min)).tag(1)
                    Text(I18n(.refresh5Min)).tag(5)
                    Text(I18n(.refresh15Min)).tag(15)
                    Text(I18n(.refresh30Min)).tag(30)
                    Text(I18n(.refresh60Min)).tag(60)
                }
                .frame(width: 180)
                .id(i18n.currentLanguage)
            }

            // 菜单栏额度摘要（开关 + 厂商 + 指标）
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(I18n(.menuBarQuotaTitle))
                            .font(.system(size: 13))
                        Text(I18n(.menuBarQuotaSubtitle))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { refreshManager.settings.menuBarQuotaEnabled },
                        set: { enabled in
                            guard refreshManager.settings.menuBarQuotaEnabled != enabled else { return }
                            refreshManager.settings.menuBarQuotaEnabled = enabled
                            // 首次开启时默认选中第一个已启用厂商，省去再点一次
                            if enabled, refreshManager.settings.menuBarProviderKey.isEmpty {
                                refreshManager.settings.menuBarProviderKey = enabledOrderKeys.first ?? ""
                            }
                            refreshManager.saveSettings()
                        }
                    ))
                        .toggleStyle(.switch)
                }

                if refreshManager.settings.menuBarQuotaEnabled {
                    HStack {
                        Text(I18n(.menuBarProviderLabel))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: savingBinding(\.menuBarProviderKey)) {
                            Text(I18n(.menuBarNoProviderSelected)).tag("")
                            ForEach(enabledOrderKeys, id: \.self) { key in
                                Text(orderDisplayName(for: key)).tag(key)
                            }
                        }
                        .frame(width: 180)
                        .id(i18n.currentLanguage)
                    }

                    HStack {
                        Text(I18n(.menuBarMetricLabel))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: savingBinding(\.menuBarMetric)) {
                            ForEach(MenuBarMetric.allCases) { metric in
                                Text(metric.displayName).tag(metric)
                            }
                        }
                        .frame(width: 180)
                        .id(i18n.currentLanguage)
                    }
                }
            }

            // Hover preview
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.enableHoverTitle))
                        .font(.system(size: 13))
                    Text(I18n(.enableHoverSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: savingBinding(\.enableHover))
                    .toggleStyle(.switch)
            }

            // Launch at login
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.launchAtLoginTitle))
                        .font(.system(size: 13))
                    Text(I18n(.launchAtLoginSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: savingBinding(\.launchAtLogin))
                    .toggleStyle(.switch)
            }

            Spacer()

            HStack {
                Spacer()
                Text("TokenBar v\(AppInfo.version) • \(I18n(.subtitle))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    /// 直接改 `AppSettings` 的控件专用绑定：选中即写入并**立刻保存**。
    ///
    /// **不要退回「绑定 settings + 紧随其后的 `.onChange` 里调 saveSettings()」那种写法。**
    /// 那会让「存盘 + 重建定时器」变成依赖 SwiftUI 渲染差分时机的副作用，而通用设置里这几个
    /// Picker 上还叠了 `.id(i18n.currentLanguage)`：视图标识一旦重建，`onChange` 的基线会被
    /// 重置成新值、通知被吞掉。于是新值进了内存却没落盘、定时器也没按新间隔重建，界面上没有
    /// 任何痕迹。真实故障：刷新间隔从 5 分钟改成 1 分钟后仍按 5 分钟跑了近 3 小时，直到下一次
    /// 别的设置触发 saveSettings 才被顺带应用（日志里表现为那段时间完全没有「定时器已创建」）。
    @MainActor
    private func savingBinding<T: Equatable>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { refreshManager.settings[keyPath: keyPath] },
            set: { newValue in
                guard refreshManager.settings[keyPath: keyPath] != newValue else { return }
                refreshManager.settings[keyPath: keyPath] = newValue
                refreshManager.saveSettings()
            }
        )
    }

    /// 当前已启用厂商的显示顺序键（与「显示排序」tab 共用同一推导）。
    private var enabledOrderKeys: [String] {
        SettingsOrdering.enabledOrderKeys(in: refreshManager.settings)
    }

    private func orderDisplayName(for key: String) -> String {
        SettingsOrdering.displayName(for: key, in: refreshManager.settings)
    }
}
