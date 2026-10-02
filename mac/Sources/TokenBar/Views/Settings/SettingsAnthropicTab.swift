import SwiftUI

/// 设置页 – Anthropic (Claude) tab（合并 Claude Code 与 Anthropic API）。
///
/// 输入状态随 tab 走：由本视图自持、从 settings 种子化；外部 settings 变化经
/// `.onChange` 反向同步；窗口复用重开（openCount 递增）时重新种子化。
@MainActor
struct SettingsAnthropicTab: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared
    @Binding var statusAlertMessage: String?
    @Binding var showStatusAlert: Bool
    /// SettingsWindowRequest.openCount：窗口复用时重开递增，触发输入重新种子化
    var openCount: Int

    // Anthropic State (Merged Claude Code & Anthropic API)
    @State private var anthropicKeyInput: String
    @State private var anthropicEndpointInput: String
    @State private var isAnthropicKeyVisible: Bool = false
    @State private var claudeTokenInput: String

    init(refreshManager: RefreshManager,
         statusAlertMessage: Binding<String?>,
         showStatusAlert: Binding<Bool>,
         openCount: Int) {
        self.refreshManager = refreshManager
        _statusAlertMessage = statusAlertMessage
        _showStatusAlert = showStatusAlert
        self.openCount = openCount
        _anthropicKeyInput = State(initialValue: refreshManager.settings.anthropicApiKey)
        _anthropicEndpointInput = State(initialValue: refreshManager.settings.anthropicEndpoint)
        _claudeTokenInput = State(initialValue: refreshManager.settings.claudeToken)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 24))
                    .foregroundColor(ProviderType.claudeCode.themeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.anthropicTitle))
                        .font(.system(size: 15, weight: .bold))
                    Text(I18n(.anthropicSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $refreshManager.settings.claudeEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: refreshManager.settings.claudeEnabled) { _ in
                        refreshManager.saveSettings()
                    }
            }

            Divider()

            // Status Card
            HStack {
                let isAuth = refreshManager.quotas[.claudeCode]?.isAuthorized == true
                Image(systemName: isAuth ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isAuth ? .green : .secondary)
                Text(isAuth ? I18n(.statusConnected) : I18n(.statusNotConnected))
                    .font(.system(size: 12, weight: .semibold))

                if let acc = refreshManager.quotas[.claudeCode]?.accountInfo {
                    Text("(\(acc))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            // Section 1: Anthropic API Key
            VStack(alignment: .leading, spacing: 8) {
                Text(I18n(.methodAnthropicKey))
                    .font(.system(size: 12, weight: .bold))

                HStack {
                    if isAnthropicKeyVisible {
                        TextField("sk-ant-...", text: $anthropicKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("sk-ant-...", text: $anthropicKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isAnthropicKeyVisible.toggle()
                    } label: {
                        Image(systemName: isAnthropicKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Text(I18n(.labelApiEndpointColon))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextField("https://api.anthropic.com/v1", text: $anthropicEndpointInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                HStack {
                    Button {
                        refreshManager.settings.anthropicApiKey = anthropicKeyInput
                        refreshManager.settings.anthropicEndpoint = anthropicEndpointInput
                        refreshManager.saveSettings()

                        Task {
                            await refreshManager.refreshClaude()
                            if refreshManager.quotas[.claudeCode]?.isAuthorized == true {
                                statusAlertMessage = I18n(.alertAnthropicSuccess)
                            } else {
                                statusAlertMessage = "\(I18n(.alertAnthropicFailed))\(refreshManager.quotas[.claudeCode]?.errorMessage ?? I18n(.alertCheckKey))"
                            }
                            showStatusAlert = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield")
                            Text(I18n(.saveAndTest))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text(I18n(.hintAnthropicKey))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.02))
            .cornerRadius(8)

            // Section 2: Claude Code Subscription (Web OAuth / Local)
            VStack(alignment: .leading, spacing: 8) {
                Text(I18n(.methodClaudeSubscription))
                    .font(.system(size: 12, weight: .bold))

                HStack(spacing: 12) {
                    Button {
                        WebLoginWindowController.show(provider: .claude) { token in
                            if let token = token {
                                refreshManager.settings.claudeToken = token
                                refreshManager.saveSettings()
                                Task {
                                    await refreshManager.refreshClaude()
                                    statusAlertMessage = I18n(.alertClaudeWebSuccess)
                                    showStatusAlert = true
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text(I18n(.btnWebLoginRecommended))
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        // 读 Claude Code 凭证会碰钥匙串（首次弹授权框），必须异步，否则会占住主线程
                        Task {
                            switch await refreshManager.importClaudeFromLocal() {
                            case .live:
                                statusAlertMessage = I18n(.alertClaudeLocalLive)
                            case .cacheOnly(let keychainDenied):
                                statusAlertMessage = I18n(keychainDenied ? .alertClaudeLocalCacheDenied : .alertClaudeLocalCacheOnly)
                            case .notFound:
                                statusAlertMessage = I18n(.alertClaudeLocalNotFound)
                            }
                            showStatusAlert = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "terminal")
                            Text(I18n(.btnReadLocalCLIAuth))
                        }
                    }
                    .buttonStyle(.bordered)
                }

                // Optional Manual Token Input
                HStack {
                    SecureField(I18n(.placeholderClaudeManualToken), text: $claudeTokenInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))

                    Button(I18n(.save)) {
                        refreshManager.settings.claudeToken = claudeTokenInput
                        refreshManager.saveSettings()
                        Task {
                            await refreshManager.refreshClaude()
                            statusAlertMessage = I18n(.alertClaudeTokenSaved)
                            showStatusAlert = true
                        }
                    }
                    .controlSize(.small)
                }
                .padding(.top, 2)
            }
            .padding(10)
            .background(Color.primary.opacity(0.02))
            .cornerRadius(8)

            Spacer()
        }
        .onChange(of: refreshManager.settings.anthropicApiKey) { anthropicKeyInput = $0 }
        .onChange(of: refreshManager.settings.anthropicEndpoint) { anthropicEndpointInput = $0 }
        .onChange(of: refreshManager.settings.claudeToken) { claudeTokenInput = $0 }
        .onChange(of: openCount) { _ in syncFromSettings() }
    }

    private func syncFromSettings() {
        anthropicKeyInput = refreshManager.settings.anthropicApiKey
        anthropicEndpointInput = refreshManager.settings.anthropicEndpoint
        claudeTokenInput = refreshManager.settings.claudeToken
    }
}
