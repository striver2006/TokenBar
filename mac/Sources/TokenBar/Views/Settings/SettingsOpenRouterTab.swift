import SwiftUI

/// 设置页 – OpenRouter tab。
///
/// 输入状态随 tab 走：由本视图自持、从 settings 种子化；外部 settings 变化经
/// `.onChange` 反向同步（阈值不在同步之列，与原实现一致）；窗口复用重开
/// （openCount 递增）时重新种子化。
@MainActor
struct SettingsOpenRouterTab: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared
    @Binding var statusAlertMessage: String?
    @Binding var showStatusAlert: Bool
    /// SettingsWindowRequest.openCount：窗口复用时重开递增，触发输入重新种子化
    var openCount: Int

    // OpenRouter State
    @State private var openRouterKeyInput: String
    @State private var openRouterEndpointInput: String
    @State private var openRouterThresholdInput: String
    @State private var isOpenRouterKeyVisible: Bool = false

    init(refreshManager: RefreshManager,
         statusAlertMessage: Binding<String?>,
         showStatusAlert: Binding<Bool>,
         openCount: Int) {
        self.refreshManager = refreshManager
        _statusAlertMessage = statusAlertMessage
        _showStatusAlert = showStatusAlert
        self.openCount = openCount
        _openRouterKeyInput = State(initialValue: refreshManager.settings.openRouterApiKey)
        _openRouterEndpointInput = State(initialValue: refreshManager.settings.openRouterEndpoint)
        _openRouterThresholdInput = State(initialValue: SettingsValueFormat.thresholdString(refreshManager.settings.openRouterBalanceAlertThreshold))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 24))
                    .foregroundColor(ProviderType.openRouter.themeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.openRouterTitle))
                        .font(.system(size: 15, weight: .bold))
                    Text(I18n(.openRouterSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $refreshManager.settings.openRouterEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: refreshManager.settings.openRouterEnabled) { _ in
                        refreshManager.saveSettings()
                    }
            }

            Divider()

            // Status Card
            HStack {
                let isAuth = refreshManager.quotas[.openRouter]?.isAuthorized == true
                Image(systemName: isAuth ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isAuth ? .green : .secondary)
                Text(isAuth ? I18n(.statusConnected) : I18n(.statusNotConnected))
                    .font(.system(size: 12, weight: .semibold))

                if let acc = refreshManager.quotas[.openRouter]?.accountInfo {
                    Text("(\(acc))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            // OpenRouter API Key
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.apiKeyLabel))
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    if isOpenRouterKeyVisible {
                        TextField("sk-or-...", text: $openRouterKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("sk-or-...", text: $openRouterKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isOpenRouterKeyVisible.toggle()
                    } label: {
                        Image(systemName: isOpenRouterKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text(I18n(.hintOpenRouterKey))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Endpoint
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.apiEndpointLabel))
                    .font(.system(size: 12, weight: .medium))
                TextField("https://openrouter.ai/api/v1", text: $openRouterEndpointInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            // Balance Alert Threshold
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.balanceThresholdLabel))
                    .font(.system(size: 12, weight: .medium))
                TextField("5", text: $openRouterThresholdInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 120)
                Text(I18n(.balanceThresholdHint))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Save & Test Button
            HStack {
                Button {
                    refreshManager.settings.openRouterApiKey = openRouterKeyInput
                    refreshManager.settings.openRouterEndpoint = openRouterEndpointInput
                    refreshManager.settings.openRouterBalanceAlertThreshold = SettingsValueFormat.parseThreshold(openRouterThresholdInput, fallback: 5)
                    refreshManager.saveSettings()

                    Task {
                        await refreshManager.refreshOpenRouter()
                        if refreshManager.quotas[.openRouter]?.isAuthorized == true {
                            statusAlertMessage = "\(I18n(.openRouterTitle)) ✓ \(refreshManager.quotas[.openRouter]?.accountInfo ?? "")"
                        } else {
                            statusAlertMessage = "OpenRouter: \(refreshManager.quotas[.openRouter]?.errorMessage ?? I18n(.alertUnknownError))"
                        }
                        showStatusAlert = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "checkmark.shield")
                        Text(I18n(.saveAndTest))
                    }
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }

            Spacer()
        }
        .onChange(of: refreshManager.settings.openRouterApiKey) { openRouterKeyInput = $0 }
        .onChange(of: refreshManager.settings.openRouterEndpoint) { openRouterEndpointInput = $0 }
        .onChange(of: openCount) { _ in syncFromSettings() }
    }

    private func syncFromSettings() {
        openRouterKeyInput = refreshManager.settings.openRouterApiKey
        openRouterEndpointInput = refreshManager.settings.openRouterEndpoint
        openRouterThresholdInput = SettingsValueFormat.thresholdString(refreshManager.settings.openRouterBalanceAlertThreshold)
    }
}
