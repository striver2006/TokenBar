import SwiftUI

/// 设置页 – Google Gemini tab。
///
/// 输入状态随 tab 走：由本视图自持、从 settings 种子化；外部 settings 变化经
/// `.onChange` 反向同步；窗口复用重开（openCount 递增）时重新种子化。
/// TokenBar 自有 Google 账号登录的编排（startGeminiGoogleLogin）随本 tab 一起拆分。
@MainActor
struct SettingsGeminiTab: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared
    @Binding var statusAlertMessage: String?
    @Binding var showStatusAlert: Bool
    /// SettingsWindowRequest.openCount：窗口复用时重开递增，触发输入重新种子化
    var openCount: Int

    // Gemini State
    @State private var geminiApiKeyInput: String
    @State private var geminiEndpointInput: String
    @State private var isGeminiKeyVisible: Bool = false
    @State private var geminiTokenInput: String

    init(refreshManager: RefreshManager,
         statusAlertMessage: Binding<String?>,
         showStatusAlert: Binding<Bool>,
         openCount: Int) {
        self.refreshManager = refreshManager
        _statusAlertMessage = statusAlertMessage
        _showStatusAlert = showStatusAlert
        self.openCount = openCount
        _geminiApiKeyInput = State(initialValue: refreshManager.settings.geminiApiKey)
        _geminiEndpointInput = State(initialValue: refreshManager.settings.geminiEndpoint)
        _geminiTokenInput = State(initialValue: refreshManager.settings.geminiToken)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundColor(ProviderType.gemini.themeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.geminiTitle))
                        .font(.system(size: 15, weight: .bold))
                    Text(I18n(.geminiSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $refreshManager.settings.geminiEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: refreshManager.settings.geminiEnabled) { _ in
                        refreshManager.saveSettings()
                    }
            }

            Divider()

            // Status Card
            HStack {
                let isAuth = refreshManager.quotas[.gemini]?.isAuthorized == true
                Image(systemName: isAuth ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isAuth ? .green : .secondary)
                Text(isAuth ? I18n(.statusConnected) : I18n(.statusNotConnected))
                    .font(.system(size: 12, weight: .semibold))

                if let acc = refreshManager.quotas[.gemini]?.accountInfo {
                    Text("(\(acc))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            // Method 1: Google AI Studio API Key
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(I18n(.methodGeminiApiKey))
                        .font(.system(size: 13, weight: .bold))
                    Text(I18n(.labelRecommendedLifetime))
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("API Key:")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 70, alignment: .leading)
                        HStack {
                            if isGeminiKeyVisible {
                                TextField("AIzaSy...", text: $geminiApiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                            } else {
                                SecureField("AIzaSy...", text: $geminiApiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12))
                            }
                            Button {
                                isGeminiKeyVisible.toggle()
                            } label: {
                                Image(systemName: isGeminiKeyVisible ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        Text(I18n(.labelApiEndpointColon))
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 70, alignment: .leading)
                        TextField("https://generativelanguage.googleapis.com", text: $geminiEndpointInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }

                    HStack {
                        Text(I18n(.labelGetKeyColon))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Link("aistudio.google.com/app/apikey", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                            .font(.system(size: 11))
                        Spacer()

                        Button(I18n(.saveAndTest)) {
                            refreshManager.settings.geminiApiKey = geminiApiKeyInput
                            refreshManager.settings.geminiEndpoint = geminiEndpointInput
                            refreshManager.saveSettings()
                            Task {
                                await refreshManager.refreshGemini()
                                if refreshManager.quotas[.gemini]?.isAuthorized == true {
                                    statusAlertMessage = I18n(.alertGeminiSuccess)
                                } else {
                                    statusAlertMessage = refreshManager.quotas[.gemini]?.errorMessage ?? I18n(.alertUnknownError)
                                }
                                showStatusAlert = true
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        if !geminiApiKeyInput.isEmpty {
                            Button(I18n(.clearKey)) {
                                geminiApiKeyInput = ""
                                refreshManager.settings.geminiApiKey = ""
                                refreshManager.saveSettings()
                                Task {
                                    await refreshManager.refreshGemini()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)

            // Method 2: Google Account Login (recommended) / Local Credentials
            VStack(alignment: .leading, spacing: 10) {
                Text(I18n(.methodGeminiOAuth))
                    .font(.system(size: 13, weight: .bold))

                // 首选：TokenBar 自己的 Google 账号登录。拿到的是存在自己钥匙串里的
                // refresh_token，不依赖 Antigravity 的钥匙串条目/本地文件——ACL 授权丢失、
                // Antigravity 重登轮换 token 都影响不到它。
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Button {
                            startGeminiGoogleLogin()
                        } label: {
                            HStack {
                                Image(systemName: "person.badge.key")
                                Text(refreshManager.settings.geminiOwnAccount.isEmpty
                                     ? I18n(.btnGoogleAccountLogin)
                                     : I18n(.btnGoogleRelogin))
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        if !refreshManager.settings.geminiOwnAccount.isEmpty {
                            Text("✓ \(refreshManager.settings.geminiOwnAccount)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Button(I18n(.btnLogoutGemini)) {
                                Task { await refreshManager.logoutGeminiOwnLogin() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Text(I18n(.labelGoogleLoginHint))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Divider()

                // 备用：本地 Antigravity 凭证（钥匙串条目 + ~/.gemini 文件）
                HStack(spacing: 12) {
                    Button {
                        // 读本地凭证会碰钥匙串（可能弹授权框），必须异步，否则点一下按钮
                        // 就把主线程占住了
                        Task {
                            let imported = await refreshManager.importGeminiFromLocal()
                            statusAlertMessage = imported
                                ? I18n(.alertGeminiLocalSuccess)
                                : I18n(.alertGeminiLocalNotFound)
                            showStatusAlert = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "desktopcomputer")
                            Text(I18n(.btnReadLocalGeminiConfig))
                        }
                    }
                    .buttonStyle(.bordered)
                }

                // Optional Manual Token
                VStack(alignment: .leading, spacing: 4) {
                    Text(I18n(.labelManualGeminiToken))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    HStack {
                        SecureField(I18n(.placeholderGeminiToken), text: $geminiTokenInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))

                        Button(I18n(.save)) {
                            refreshManager.settings.geminiToken = geminiTokenInput
                            refreshManager.saveSettings()
                            Task {
                                await refreshManager.refreshGemini()
                                statusAlertMessage = I18n(.alertGeminiTokenSaved)
                                showStatusAlert = true
                            }
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)

            Spacer()
        }
        .onChange(of: refreshManager.settings.geminiApiKey) { geminiApiKeyInput = $0 }
        .onChange(of: refreshManager.settings.geminiEndpoint) { geminiEndpointInput = $0 }
        .onChange(of: refreshManager.settings.geminiToken) { geminiTokenInput = $0 }
        .onChange(of: openCount) { _ in syncFromSettings() }
    }

    /// 发起 TokenBar 自己的 Google 账号登录：生成 loopback 授权 URL → 弹登录窗 →
    /// 拦截授权码 → 换 refresh_token 落自己的钥匙串条目。
    private func startGeminiGoogleLogin() {
        Task {
            guard let plan = await refreshManager.geminiGoogleLoginPlan() else {
                statusAlertMessage = I18n(.alertGeminiNoClient)
                showStatusAlert = true
                return
            }
            WebLoginWindowController.show(provider: .gemini, authorizeURL: plan.authorizeURL) { code in
                guard let code, !code.isEmpty else { return }
                Task { @MainActor in
                    let ok = await refreshManager.completeGeminiGoogleLogin(code: code, redirectPort: plan.redirectPort)
                    statusAlertMessage = ok ? I18n(.alertGeminiLoginSuccess) : I18n(.alertGeminiLoginFailed)
                    showStatusAlert = true
                }
            }
        }
    }

    private func syncFromSettings() {
        geminiApiKeyInput = refreshManager.settings.geminiApiKey
        geminiEndpointInput = refreshManager.settings.geminiEndpoint
        geminiTokenInput = refreshManager.settings.geminiToken
    }
}
