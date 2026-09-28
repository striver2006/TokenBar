import SwiftUI

/// 设置页 – OpenAI tab。
///
/// 输入状态随 tab 走：由本视图自持、从 settings 种子化；外部 settings 变化经
/// `.onChange` 反向同步（沿用原 SettingsView 的 25 条同步中属于本 tab 的 3 条）；
/// 窗口复用重开（openCount 递增）时重新种子化，等价于原 syncFromSettings()。
@MainActor
struct SettingsOpenAITab: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared
    @Binding var statusAlertMessage: String?
    @Binding var showStatusAlert: Bool
    /// SettingsWindowRequest.openCount：窗口复用时重开递增，触发输入重新种子化
    var openCount: Int

    // OpenAI State
    @State private var openAIKeyInput: String
    @State private var openAIEndpointInput: String
    @State private var openAIOrgInput: String
    @State private var isOpenAIKeyVisible: Bool = false

    init(refreshManager: RefreshManager,
         statusAlertMessage: Binding<String?>,
         showStatusAlert: Binding<Bool>,
         openCount: Int) {
        self.refreshManager = refreshManager
        _statusAlertMessage = statusAlertMessage
        _showStatusAlert = showStatusAlert
        self.openCount = openCount
        _openAIKeyInput = State(initialValue: refreshManager.settings.openAIApiKey)
        _openAIEndpointInput = State(initialValue: refreshManager.settings.openAIEndpoint)
        _openAIOrgInput = State(initialValue: refreshManager.settings.openAIOrgId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "circle.hexagonpath.fill")
                    .font(.system(size: 24))
                    .foregroundColor(ProviderType.openAI.themeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.openAITitle))
                        .font(.system(size: 15, weight: .bold))
                    Text(I18n(.openAISubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $refreshManager.settings.openAIEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: refreshManager.settings.openAIEnabled) { _ in
                        refreshManager.saveSettings()
                    }
            }

            Divider()

            // Status Card
            HStack {
                let isAuth = refreshManager.quotas[.openAI]?.isAuthorized == true
                Image(systemName: isAuth ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isAuth ? .green : .secondary)
                Text(isAuth ? I18n(.statusConnected) : I18n(.statusNotConnected))
                    .font(.system(size: 12, weight: .semibold))

                if let acc = refreshManager.quotas[.openAI]?.accountInfo {
                    Text("(\(acc))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            // OpenAI API Key
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.apiKeyLabel))
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    if isOpenAIKeyVisible {
                        TextField(I18n(.placeholderApiKeyOpenAI), text: $openAIKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(I18n(.placeholderApiKeyOpenAI), text: $openAIKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isOpenAIKeyVisible.toggle()
                    } label: {
                        Image(systemName: isOpenAIKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text(I18n(.hintOpenAIKey))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Endpoint
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.apiEndpointLabel))
                    .font(.system(size: 12, weight: .medium))

                TextField("https://api.openai.com/v1", text: $openAIEndpointInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                Text(I18n(.hintOpenAIEndpoint))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Organization ID (Optional)
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.orgIdLabel))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                TextField(I18n(.placeholderOrgId), text: $openAIOrgInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            // Save & Test
            HStack {
                Button {
                    refreshManager.settings.openAIApiKey = openAIKeyInput
                    refreshManager.settings.openAIEndpoint = openAIEndpointInput
                    refreshManager.settings.openAIOrgId = openAIOrgInput
                    refreshManager.saveSettings()

                    Task {
                        await refreshManager.refreshOpenAI()
                        if refreshManager.quotas[.openAI]?.isAuthorized == true {
                            statusAlertMessage = I18n(.alertOpenAISuccess)
                        } else {
                            statusAlertMessage = "\(I18n(.alertOpenAIFailed))\(refreshManager.quotas[.openAI]?.errorMessage ?? I18n(.alertUnknownError))"
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
        .onChange(of: refreshManager.settings.openAIApiKey) { openAIKeyInput = $0 }
        .onChange(of: refreshManager.settings.openAIEndpoint) { openAIEndpointInput = $0 }
        .onChange(of: refreshManager.settings.openAIOrgId) { openAIOrgInput = $0 }
        .onChange(of: openCount) { _ in syncFromSettings() }
    }

    private func syncFromSettings() {
        openAIKeyInput = refreshManager.settings.openAIApiKey
        openAIEndpointInput = refreshManager.settings.openAIEndpoint
        openAIOrgInput = refreshManager.settings.openAIOrgId
    }
}
