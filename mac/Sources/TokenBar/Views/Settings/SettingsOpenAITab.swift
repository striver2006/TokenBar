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
    @State private var codexPathInput: String
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
        _codexPathInput = State(initialValue: refreshManager.settings.codexExecutablePath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "circle.hexagonpath.fill")
                    .font(.system(size: 24))
                    .foregroundColor(ProviderType.openAI.themeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenAI / Codex")
                        .font(.system(size: 15, weight: .bold))
                    Text(isZh ? "查询 API 速率限制或 Codex 订阅额度" : "Monitor API rate limits or Codex subscription quotas")
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

            Picker(isZh ? "查询模式" : "Quota mode", selection: $refreshManager.settings.openAIUseCodexSubscription) {
                Text("API").tag(false)
                Text(isZh ? "Codex 订阅" : "Codex subscription").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: refreshManager.settings.openAIUseCodexSubscription) { _ in
                refreshManager.saveSettings()
                Task { await refreshManager.refreshOpenAI() }
            }

            if refreshManager.settings.openAIUseCodexSubscription {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isZh ? "复用本机 Codex 的 ChatGPT 登录，查询订阅额度与重置时间。请先在 Codex 中登录订阅账号，或运行 codex login。" : "Uses your local Codex ChatGPT login to read subscription quotas and reset times. Sign in to Codex or run codex login first.")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Text(isZh ? "Codex 可执行文件路径（可选）" : "Codex executable path (optional)")
                        .font(.system(size: 12, weight: .medium))
                    TextField(isZh ? "留空自动检测" : "Leave empty to auto-detect", text: $codexPathInput)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
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

            }

            // Save & Test
            HStack {
                Button {
                    refreshManager.settings.openAIApiKey = openAIKeyInput
                    refreshManager.settings.openAIEndpoint = openAIEndpointInput
                    refreshManager.settings.openAIOrgId = openAIOrgInput
                    refreshManager.settings.codexExecutablePath = codexPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    refreshManager.saveSettings()

                    Task {
                        await refreshManager.refreshOpenAI()
                        if refreshManager.quotas[.openAI]?.isAuthorized == true
                            && refreshManager.quotas[.openAI]?.hadRefreshError == false {
                            statusAlertMessage = refreshManager.settings.openAIUseCodexSubscription
                                ? (isZh ? "Codex 订阅额度查询成功" : "Codex subscription quotas loaded")
                                : I18n(.alertOpenAISuccess)
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
        .onChange(of: refreshManager.settings.codexExecutablePath) { codexPathInput = $0 }
        .onChange(of: openCount) { _ in syncFromSettings() }
    }

    private var isZh: Bool { i18n.effectiveLanguage == "zh" }

    private func syncFromSettings() {
        codexPathInput = refreshManager.settings.codexExecutablePath
        openAIKeyInput = refreshManager.settings.openAIApiKey
        openAIEndpointInput = refreshManager.settings.openAIEndpoint
        openAIOrgInput = refreshManager.settings.openAIOrgId
    }
}
