import SwiftUI

/// 设置页 – 火山方舟 (字节跳动) tab。
///
/// 输入状态随 tab 走：由本视图自持、从 settings 种子化；外部 settings 变化经
/// `.onChange` 反向同步；窗口复用重开（openCount 递增）时重新种子化。
@MainActor
struct SettingsVolcengineTab: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared
    @Binding var statusAlertMessage: String?
    @Binding var showStatusAlert: Bool
    /// SettingsWindowRequest.openCount：窗口复用时重开递增，触发输入重新种子化
    var openCount: Int

    // Volcengine State
    @State private var volcengineKeyInput: String
    @State private var volcengineEndpointInput: String
    @State private var volcengineModelInput: String
    @State private var isVolcengineKeyVisible: Bool = false

    init(refreshManager: RefreshManager,
         statusAlertMessage: Binding<String?>,
         showStatusAlert: Binding<Bool>,
         openCount: Int) {
        self.refreshManager = refreshManager
        _statusAlertMessage = statusAlertMessage
        _showStatusAlert = showStatusAlert
        self.openCount = openCount
        _volcengineKeyInput = State(initialValue: refreshManager.settings.volcengineApiKey)
        _volcengineEndpointInput = State(initialValue: refreshManager.settings.volcengineEndpoint)
        _volcengineModelInput = State(initialValue: refreshManager.settings.volcengineModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "flame.fill")
                    .font(.system(size: 24))
                    .foregroundColor(ProviderType.volcengine.themeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.volcengineTitle))
                        .font(.system(size: 15, weight: .bold))
                    Text(I18n(.volcengineSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $refreshManager.settings.volcengineEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: refreshManager.settings.volcengineEnabled) { _ in
                        refreshManager.saveSettings()
                    }
            }

            Divider()

            // Status Card
            HStack {
                let isAuth = refreshManager.quotas[.volcengine]?.isAuthorized == true
                Image(systemName: isAuth ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isAuth ? .green : .secondary)
                Text(isAuth ? I18n(.statusConnected) : I18n(.statusNotConnected))
                    .font(.system(size: 12, weight: .semibold))

                if let acc = refreshManager.quotas[.volcengine]?.accountInfo {
                    Text("(\(acc))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            // Volcengine API Key
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.apiKeyLabel))
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    if isVolcengineKeyVisible {
                        TextField(I18n(.placeholderApiKeyVolcengine), text: $volcengineKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(I18n(.placeholderApiKeyVolcengine), text: $volcengineKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isVolcengineKeyVisible.toggle()
                    } label: {
                        Image(systemName: isVolcengineKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text(I18n(.hintVolcengineKey))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Endpoint & Endpoint ID
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(I18n(.apiEndpointLabel))
                        .font(.system(size: 12, weight: .medium))
                    TextField("https://ark.cn-beijing.volces.com/api/v3", text: $volcengineEndpointInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(I18n(.labelVolcengineEndpointId))
                        .font(.system(size: 12, weight: .medium))
                    TextField("ep-xxxxxxxx-xxxx", text: $volcengineModelInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
            }

            // Save & Test Button
            HStack {
                Button {
                    refreshManager.settings.volcengineApiKey = volcengineKeyInput
                    refreshManager.settings.volcengineEndpoint = volcengineEndpointInput
                    refreshManager.settings.volcengineModel = volcengineModelInput
                    refreshManager.saveSettings()

                    Task {
                        await refreshManager.refreshVolcengine()
                        if refreshManager.quotas[.volcengine]?.isAuthorized == true {
                            statusAlertMessage = I18n(.alertVolcengineSuccess)
                        } else {
                            statusAlertMessage = "\(I18n(.alertVolcengineFailed))\(refreshManager.quotas[.volcengine]?.errorMessage ?? I18n(.alertUnknownError))"
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
        .onChange(of: refreshManager.settings.volcengineApiKey) { volcengineKeyInput = $0 }
        .onChange(of: refreshManager.settings.volcengineEndpoint) { volcengineEndpointInput = $0 }
        .onChange(of: refreshManager.settings.volcengineModel) { volcengineModelInput = $0 }
        .onChange(of: openCount) { _ in syncFromSettings() }
    }

    private func syncFromSettings() {
        volcengineKeyInput = refreshManager.settings.volcengineApiKey
        volcengineEndpointInput = refreshManager.settings.volcengineEndpoint
        volcengineModelInput = refreshManager.settings.volcengineModel
    }
}
