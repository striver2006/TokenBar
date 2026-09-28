import SwiftUI

/// 设置页 – GLM (智谱) tab。
///
/// 输入状态随 tab 走：由本视图自持、从 settings 种子化；外部 settings 变化经
/// `.onChange` 反向同步；窗口复用重开（openCount 递增）时重新种子化。
@MainActor
struct SettingsGLMTab: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared
    @Binding var statusAlertMessage: String?
    @Binding var showStatusAlert: Bool
    /// SettingsWindowRequest.openCount：窗口复用时重开递增，触发输入重新种子化
    var openCount: Int

    // GLM State
    @State private var glmKeyInput: String
    @State private var glmEndpointInput: String
    @State private var isKeyVisible: Bool = false

    init(refreshManager: RefreshManager,
         statusAlertMessage: Binding<String?>,
         showStatusAlert: Binding<Bool>,
         openCount: Int) {
        self.refreshManager = refreshManager
        _statusAlertMessage = statusAlertMessage
        _showStatusAlert = showStatusAlert
        self.openCount = openCount
        _glmKeyInput = State(initialValue: refreshManager.settings.glmApiKey)
        _glmEndpointInput = State(initialValue: refreshManager.settings.glmEndpoint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 24))
                    .foregroundColor(ProviderType.glm.themeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.glmTitle))
                        .font(.system(size: 15, weight: .bold))
                    Text(I18n(.glmSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $refreshManager.settings.glmEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: refreshManager.settings.glmEnabled) { _ in
                        refreshManager.saveSettings()
                    }
            }

            Divider()

            // Status Card
            HStack {
                let isAuth = refreshManager.quotas[.glm]?.isAuthorized == true
                Image(systemName: isAuth ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isAuth ? .green : .secondary)
                Text(isAuth ? I18n(.statusConnected) : I18n(.statusNotConnected))
                    .font(.system(size: 12, weight: .semibold))

                if let acc = refreshManager.quotas[.glm]?.accountInfo {
                    Text("(\(acc))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            // GLM API Key Field
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.apiKeyLabel))
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    if isKeyVisible {
                        TextField(I18n(.placeholderApiKeyGLM), text: $glmKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(I18n(.placeholderApiKeyGLM), text: $glmKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isKeyVisible.toggle()
                    } label: {
                        Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text(I18n(.hintGLMKey))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Platform Endpoint
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.glmProtocolTitle))
                    .font(.system(size: 12, weight: .medium))

                Picker("", selection: $glmEndpointInput) {
                    Text(I18n(.glmProtocolOpenAI)).tag("https://open.bigmodel.cn/api/v1")
                    Text(I18n(.glmProtocolPaas)).tag("https://open.bigmodel.cn/api/paas/v4")
                    Text(I18n(.glmProtocolInternational)).tag("https://api.z.ai/api/v1")
                }
                .pickerStyle(.radioGroup)
                .id(i18n.currentLanguage)

                HStack {
                    Text(I18n(.glmCustomEndpoint))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("https://open.bigmodel.cn/api/v1", text: $glmEndpointInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
                .padding(.top, 2)
            }

            // Save & Test Button
            HStack {
                Button {
                    refreshManager.settings.glmApiKey = glmKeyInput
                    refreshManager.settings.glmEndpoint = glmEndpointInput
                    refreshManager.saveSettings()

                    Task {
                        await refreshManager.refreshGLM()
                        if refreshManager.quotas[.glm]?.isAuthorized == true {
                            statusAlertMessage = I18n(.alertGLMSuccess)
                        } else {
                            statusAlertMessage = "\(I18n(.alertGLMFailed))\(refreshManager.quotas[.glm]?.errorMessage ?? I18n(.alertCheckKey))"
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
        .onChange(of: refreshManager.settings.glmApiKey) { glmKeyInput = $0 }
        .onChange(of: refreshManager.settings.glmEndpoint) { glmEndpointInput = $0 }
        .onChange(of: openCount) { _ in syncFromSettings() }
    }

    private func syncFromSettings() {
        glmKeyInput = refreshManager.settings.glmApiKey
        glmEndpointInput = refreshManager.settings.glmEndpoint
    }
}
