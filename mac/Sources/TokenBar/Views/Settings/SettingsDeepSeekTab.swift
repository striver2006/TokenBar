import SwiftUI

/// 设置页 – DeepSeek tab。
///
/// 输入状态随 tab 走：由本视图自持、从 settings 种子化；外部 settings 变化经
/// `.onChange` 反向同步（阈值不在同步之列，与原实现一致）；窗口复用重开
/// （openCount 递增）时重新种子化。
@MainActor
struct SettingsDeepSeekTab: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared
    @Binding var statusAlertMessage: String?
    @Binding var showStatusAlert: Bool
    /// SettingsWindowRequest.openCount：窗口复用时重开递增，触发输入重新种子化
    var openCount: Int

    // DeepSeek State
    @State private var deepseekKeyInput: String
    @State private var deepseekEndpointInput: String
    @State private var deepseekModelInput: String
    @State private var deepseekThresholdInput: String
    @State private var isDeepseekKeyVisible: Bool = false

    init(refreshManager: RefreshManager,
         statusAlertMessage: Binding<String?>,
         showStatusAlert: Binding<Bool>,
         openCount: Int) {
        self.refreshManager = refreshManager
        _statusAlertMessage = statusAlertMessage
        _showStatusAlert = showStatusAlert
        self.openCount = openCount
        _deepseekKeyInput = State(initialValue: refreshManager.settings.deepseekApiKey)
        _deepseekEndpointInput = State(initialValue: refreshManager.settings.deepseekEndpoint)
        _deepseekModelInput = State(initialValue: refreshManager.settings.deepseekModel)
        _deepseekThresholdInput = State(initialValue: SettingsValueFormat.thresholdString(refreshManager.settings.deepseekBalanceAlertThreshold))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 24))
                    .foregroundColor(ProviderType.deepseek.themeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.deepseekTitle))
                        .font(.system(size: 15, weight: .bold))
                    Text(I18n(.deepseekSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $refreshManager.settings.deepseekEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: refreshManager.settings.deepseekEnabled) { _ in
                        refreshManager.saveSettings()
                    }
            }

            Divider()

            // Status Card
            HStack {
                let isAuth = refreshManager.quotas[.deepseek]?.isAuthorized == true
                Image(systemName: isAuth ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isAuth ? .green : .secondary)
                Text(isAuth ? I18n(.statusConnected) : I18n(.statusNotConnected))
                    .font(.system(size: 12, weight: .semibold))

                if let acc = refreshManager.quotas[.deepseek]?.accountInfo {
                    Text("(\(acc))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            // DeepSeek API Key
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.apiKeyLabel))
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    if isDeepseekKeyVisible {
                        TextField("sk-...", text: $deepseekKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("sk-...", text: $deepseekKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isDeepseekKeyVisible.toggle()
                    } label: {
                        Image(systemName: isDeepseekKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text(I18n(.hintDeepSeekKey))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Endpoint & Model
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(I18n(.apiEndpointLabel))
                        .font(.system(size: 12, weight: .medium))
                    TextField("https://api.deepseek.com/v1", text: $deepseekEndpointInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(I18n(.defaultModelLabel))
                        .font(.system(size: 12, weight: .medium))
                    TextField("deepseek-chat", text: $deepseekModelInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
            }

            // Balance Alert Threshold
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.balanceThresholdLabel))
                    .font(.system(size: 12, weight: .medium))
                TextField("10", text: $deepseekThresholdInput)
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
                    refreshManager.settings.deepseekApiKey = deepseekKeyInput
                    refreshManager.settings.deepseekEndpoint = deepseekEndpointInput
                    refreshManager.settings.deepseekModel = deepseekModelInput
                    refreshManager.settings.deepseekBalanceAlertThreshold = SettingsValueFormat.parseThreshold(deepseekThresholdInput, fallback: 10)
                    refreshManager.saveSettings()

                    Task {
                        await refreshManager.refreshDeepSeek()
                        if refreshManager.quotas[.deepseek]?.isAuthorized == true {
                            statusAlertMessage = I18n(.alertDeepSeekSuccess)
                        } else {
                            statusAlertMessage = "\(I18n(.alertDeepSeekFailed))\(refreshManager.quotas[.deepseek]?.errorMessage ?? I18n(.alertUnknownError))"
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
        .onChange(of: refreshManager.settings.deepseekApiKey) { deepseekKeyInput = $0 }
        .onChange(of: refreshManager.settings.deepseekEndpoint) { deepseekEndpointInput = $0 }
        .onChange(of: refreshManager.settings.deepseekModel) { deepseekModelInput = $0 }
        .onChange(of: openCount) { _ in syncFromSettings() }
    }

    private func syncFromSettings() {
        deepseekKeyInput = refreshManager.settings.deepseekApiKey
        deepseekEndpointInput = refreshManager.settings.deepseekEndpoint
        deepseekModelInput = refreshManager.settings.deepseekModel
        deepseekThresholdInput = SettingsValueFormat.thresholdString(refreshManager.settings.deepseekBalanceAlertThreshold)
    }
}
