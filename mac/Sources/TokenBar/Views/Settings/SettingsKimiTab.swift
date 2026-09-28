import SwiftUI

/// 设置页 – KIMI (月之暗面) tab。
///
/// 输入状态随 tab 走：由本视图自持、从 settings 种子化；外部 settings 变化经
/// `.onChange` 反向同步（阈值不在同步之列，与原实现一致）；窗口复用重开
/// （openCount 递增）时重新种子化。
@MainActor
struct SettingsKimiTab: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared
    @Binding var statusAlertMessage: String?
    @Binding var showStatusAlert: Bool
    /// SettingsWindowRequest.openCount：窗口复用时重开递增，触发输入重新种子化
    var openCount: Int

    // KIMI State
    @State private var kimiKeyInput: String
    @State private var kimiEndpointInput: String
    @State private var kimiModelInput: String
    @State private var kimiThresholdInput: String
    @State private var isKimiKeyVisible: Bool = false

    init(refreshManager: RefreshManager,
         statusAlertMessage: Binding<String?>,
         showStatusAlert: Binding<Bool>,
         openCount: Int) {
        self.refreshManager = refreshManager
        _statusAlertMessage = statusAlertMessage
        _showStatusAlert = showStatusAlert
        self.openCount = openCount
        _kimiKeyInput = State(initialValue: refreshManager.settings.kimiApiKey)
        _kimiEndpointInput = State(initialValue: refreshManager.settings.kimiEndpoint)
        _kimiModelInput = State(initialValue: refreshManager.settings.kimiModel)
        _kimiThresholdInput = State(initialValue: SettingsValueFormat.thresholdString(refreshManager.settings.kimiBalanceAlertThreshold))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 24))
                    .foregroundColor(ProviderType.kimi.themeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.kimiTitle))
                        .font(.system(size: 15, weight: .bold))
                    Text(I18n(.kimiSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $refreshManager.settings.kimiEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: refreshManager.settings.kimiEnabled) { _ in
                        refreshManager.saveSettings()
                    }
            }

            Divider()

            // Status Card
            HStack {
                let isAuth = refreshManager.quotas[.kimi]?.isAuthorized == true
                Image(systemName: isAuth ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isAuth ? .green : .secondary)
                Text(isAuth ? I18n(.statusConnected) : I18n(.statusNotConnected))
                    .font(.system(size: 12, weight: .semibold))

                if let acc = refreshManager.quotas[.kimi]?.accountInfo {
                    Text("(\(acc))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            // KIMI API Key
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.apiKeyLabel))
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    if isKimiKeyVisible {
                        TextField("sk-...", text: $kimiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("sk-...", text: $kimiKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isKimiKeyVisible.toggle()
                    } label: {
                        Image(systemName: isKimiKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text(I18n(.hintKimiKey))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Endpoint & Model
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(I18n(.apiEndpointLabel))
                        .font(.system(size: 12, weight: .medium))
                    TextField("https://api.moonshot.cn/v1", text: $kimiEndpointInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(I18n(.defaultModelLabel))
                        .font(.system(size: 12, weight: .medium))
                    TextField("moonshot-v1-8k", text: $kimiModelInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
            }

            // Balance Alert Threshold
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.balanceThresholdLabel))
                    .font(.system(size: 12, weight: .medium))
                TextField("10", text: $kimiThresholdInput)
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
                    refreshManager.settings.kimiApiKey = kimiKeyInput
                    refreshManager.settings.kimiEndpoint = kimiEndpointInput
                    refreshManager.settings.kimiModel = kimiModelInput
                    refreshManager.settings.kimiBalanceAlertThreshold = SettingsValueFormat.parseThreshold(kimiThresholdInput, fallback: 10)
                    refreshManager.saveSettings()

                    Task {
                        await refreshManager.refreshKimi()
                        if refreshManager.quotas[.kimi]?.isAuthorized == true {
                            statusAlertMessage = I18n(.alertKimiSuccess)
                        } else {
                            statusAlertMessage = "\(I18n(.alertKimiFailed))\(refreshManager.quotas[.kimi]?.errorMessage ?? I18n(.alertUnknownError))"
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
        .onChange(of: refreshManager.settings.kimiApiKey) { kimiKeyInput = $0 }
        .onChange(of: refreshManager.settings.kimiEndpoint) { kimiEndpointInput = $0 }
        .onChange(of: refreshManager.settings.kimiModel) { kimiModelInput = $0 }
        .onChange(of: openCount) { _ in syncFromSettings() }
    }

    private func syncFromSettings() {
        kimiKeyInput = refreshManager.settings.kimiApiKey
        kimiEndpointInput = refreshManager.settings.kimiEndpoint
        kimiModelInput = refreshManager.settings.kimiModel
        kimiThresholdInput = SettingsValueFormat.thresholdString(refreshManager.settings.kimiBalanceAlertThreshold)
    }
}
