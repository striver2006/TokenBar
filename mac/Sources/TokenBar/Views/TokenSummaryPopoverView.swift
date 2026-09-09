import SwiftUI

@MainActor
public struct TokenSummaryPopoverView: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared
    let onOpenSettings: (SettingsTab) -> Void
    let onQuit: () -> Void

    @MainActor
    public init(
        onOpenSettings: @escaping (SettingsTab) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.init(refreshManager: .shared, onOpenSettings: onOpenSettings, onQuit: onQuit)
    }

    @MainActor
    public init(
        refreshManager: RefreshManager,
        onOpenSettings: @escaping (SettingsTab) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.refreshManager = refreshManager
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }

    // MARK: - 卡片显示顺序

    private enum PopoverCardEntryContent {
        case builtin(ProviderQuota)
        case custom(CustomProviderQuota)
    }

    private struct PopoverCardEntry: Identifiable {
        let key: String
        let content: PopoverCardEntryContent
        var id: String { key }
    }

    /// 已启用且有数据的厂商卡片，按 settings.providerOrder 排序；未列入的键按默认顺序追加在末尾。
    private var orderedCardEntries: [PopoverCardEntry] {
        let settings = refreshManager.settings
        var entries: [PopoverCardEntry] = []

        func appendBuiltin(_ type: ProviderType, isEnabled: Bool) {
            guard isEnabled, let quota = refreshManager.quotas[type] else { return }
            entries.append(PopoverCardEntry(key: ProviderOrdering.key(of: type), content: .builtin(quota)))
        }

        appendBuiltin(.openAI, isEnabled: settings.openAIEnabled)
        appendBuiltin(.claudeCode, isEnabled: settings.claudeEnabled)
        appendBuiltin(.gemini, isEnabled: settings.geminiEnabled)
        appendBuiltin(.deepseek, isEnabled: settings.deepseekEnabled)
        appendBuiltin(.volcengine, isEnabled: settings.volcengineEnabled)
        appendBuiltin(.kimi, isEnabled: settings.kimiEnabled)
        appendBuiltin(.openRouter, isEnabled: settings.openRouterEnabled)
        appendBuiltin(.glm, isEnabled: settings.glmEnabled)
        appendBuiltin(.aliyunBailian, isEnabled: settings.aliyunEnabled)

        for config in settings.customProviders where config.isEnabled {
            if let quota = refreshManager.customQuotas[config.id] {
                entries.append(PopoverCardEntry(key: ProviderOrdering.customKey(config.id), content: .custom(quota)))
            }
        }

        // Swift 的 sorted 非稳定排序，附加构造下标保证同序时保持默认顺序
        return entries
            .enumerated()
            .sorted {
                let l = ProviderOrdering.sortIndex($0.element.key, order: settings.providerOrder)
                let r = ProviderOrdering.sortIndex($1.element.key, order: settings.providerOrder)
                return (l, $0.offset) < (r, $1.offset)
            }
            .map { $0.element }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // App Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("TokenBar")
                            .font(.system(size: 13, weight: .bold))
                        Text(I18n(.subtitle))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button {
                    Task {
                        await refreshManager.refreshAll()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(Angle(degrees: refreshManager.isRefreshing ? 360 : 0))
                            .animation(refreshManager.isRefreshing ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: refreshManager.isRefreshing)
                        Text(refreshManager.isRefreshing ? I18n(.refreshing) : I18n(.refresh))
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(refreshManager.isRefreshing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.8))

            Divider()

            // Main Content: Provider Cards
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(orderedCardEntries) { entry in
                        switch entry.content {
                        case .builtin(let quota):
                            ProviderCardView(quota: quota, onConfigure: { onOpenSettings(quota.provider.settingsTab) })
                        case .custom(let quota):
                            CustomProviderCardView(quota: quota, onConfigure: { onOpenSettings(.custom) })
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 460)

            Divider()

            // Footer
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    if let lastUpdated = refreshManager.lastRefreshDate {
                        Text("\(I18n(.updatedAt))\(timeFormatter.string(from: lastUpdated))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    } else {
                        Text(I18n(.ready))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    // 只在"刷新过但没拿到新数据"时补一行。正常态视觉完全不变。
                    // 没有这行的话，全失败的轮次在界面上和"根本没刷新"长得一模一样。
                    if let attempt = refreshManager.lastAttemptDate,
                       refreshManager.lastRoundOutcome != .success {
                        Text("\(I18n(.attemptedAt))\(timeFormatter.string(from: attempt)) · \(I18n(.refreshFailedRound))")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }
                }

                Spacer()

                Button {
                    onOpenSettings(.general)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help(I18n(.openSettings))

                Button {
                    onQuit()
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.8))
                }
                .buttonStyle(.borderless)
                .help(I18n(.quitApp))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
        }
        .frame(width: 320)
    }
}
