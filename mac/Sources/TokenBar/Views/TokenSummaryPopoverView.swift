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
                    if refreshManager.settings.openAIEnabled,
                       let openai = refreshManager.quotas[.openAI] {
                        ProviderCardView(quota: openai, onConfigure: { onOpenSettings(.openAI) })
                    }

                    if refreshManager.settings.claudeEnabled,
                       let claude = refreshManager.quotas[.claudeCode] {
                        ProviderCardView(quota: claude, onConfigure: { onOpenSettings(.anthropic) })
                    }

                    if refreshManager.settings.geminiEnabled,
                       let gemini = refreshManager.quotas[.gemini] {
                        ProviderCardView(quota: gemini, onConfigure: { onOpenSettings(.gemini) })
                    }

                    if refreshManager.settings.deepseekEnabled,
                       let deepseek = refreshManager.quotas[.deepseek] {
                        ProviderCardView(quota: deepseek, onConfigure: { onOpenSettings(.deepseek) })
                    }

                    if refreshManager.settings.volcengineEnabled,
                       let volcengine = refreshManager.quotas[.volcengine] {
                        ProviderCardView(quota: volcengine, onConfigure: { onOpenSettings(.volcengine) })
                    }

                    if refreshManager.settings.kimiEnabled,
                       let kimi = refreshManager.quotas[.kimi] {
                        ProviderCardView(quota: kimi, onConfigure: { onOpenSettings(.kimi) })
                    }

                    if refreshManager.settings.glmEnabled,
                       let glm = refreshManager.quotas[.glm] {
                        ProviderCardView(quota: glm, onConfigure: { onOpenSettings(.glm) })
                    }

                    if refreshManager.settings.aliyunEnabled,
                       let aliyun = refreshManager.quotas[.aliyunBailian] {
                        ProviderCardView(quota: aliyun, onConfigure: { onOpenSettings(.aliyun) })
                    }

                    ForEach(refreshManager.settings.customProviders.filter { $0.isEnabled }) { config in
                        if let q = refreshManager.customQuotas[config.id] {
                            CustomProviderCardView(quota: q, onConfigure: { onOpenSettings(.custom) })
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 460)

            Divider()

            // Footer
            HStack {
                if let lastUpdated = refreshManager.lastRefreshDate {
                    Text("\(I18n(.updatedAt))\(timeFormatter.string(from: lastUpdated))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else {
                    Text(I18n(.ready))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
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
