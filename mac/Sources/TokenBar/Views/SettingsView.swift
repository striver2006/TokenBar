import SwiftUI

@MainActor
public struct SettingsView: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared

    @State private var selectedTab: SettingsTab = .openAI

    // OpenAI State
    @State private var openAIKeyInput: String = ""
    @State private var openAIEndpointInput: String = "https://api.openai.com/v1"
    @State private var openAIOrgInput: String = ""
    @State private var isOpenAIKeyVisible: Bool = false

    // Anthropic State (Merged Claude Code & Anthropic API)
    @State private var anthropicKeyInput: String = ""
    @State private var anthropicEndpointInput: String = "https://api.anthropic.com/v1"
    @State private var isAnthropicKeyVisible: Bool = false
    @State private var claudeTokenInput: String = ""

    // Gemini State
    @State private var geminiApiKeyInput: String = ""
    @State private var geminiEndpointInput: String = "https://generativelanguage.googleapis.com"
    @State private var isGeminiKeyVisible: Bool = false
    @State private var geminiTokenInput: String = ""

    // DeepSeek State
    @State private var deepseekKeyInput: String = ""
    @State private var deepseekEndpointInput: String = "https://api.deepseek.com/v1"
    @State private var deepseekModelInput: String = "deepseek-chat"
    @State private var isDeepseekKeyVisible: Bool = false

    // Volcengine State
    @State private var volcengineKeyInput: String = ""
    @State private var volcengineEndpointInput: String = "https://ark.cn-beijing.volces.com/api/v3"
    @State private var volcengineModelInput: String = ""
    @State private var isVolcengineKeyVisible: Bool = false

    // KIMI State
    @State private var kimiKeyInput: String = ""
    @State private var kimiEndpointInput: String = "https://api.moonshot.cn/v1"
    @State private var kimiModelInput: String = "moonshot-v1-8k"
    @State private var isKimiKeyVisible: Bool = false

    // GLM State
    @State private var glmKeyInput: String = ""
    @State private var glmEndpointInput: String = "https://open.bigmodel.cn/api/v1"
    @State private var isKeyVisible: Bool = false

    // Aliyun State
    @State private var aliyunKeyInput: String = ""
    @State private var aliyunEndpointInput: String = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
    @State private var isAliyunKeyVisible: Bool = false
    @State private var aliyunCookieInput: String = ""

    // Custom Providers State
    @State private var isAddingProvider: Bool = false
    @State private var editingProviderId: UUID? = nil
    @State private var customNameInput: String = ""
    @State private var customProtocolInput: ApiProtocol = .openAIChat
    @State private var customKeyInput: String = ""
    @State private var customEndpointInput: String = "http://localhost:3000/v1"
    @State private var customModelInput: String = ""
    @State private var isCustomKeyVisible: Bool = false

    @State private var statusAlertMessage: String? = nil
    @State private var showStatusAlert: Bool = false

    @MainActor
    public init() {
        self.init(refreshManager: .shared, initialTab: .openAI)
    }

    @MainActor
    public init(refreshManager: RefreshManager, initialTab: SettingsTab = .openAI) {
        self.refreshManager = refreshManager
        _selectedTab = State(initialValue: initialTab)
        _openAIKeyInput = State(initialValue: refreshManager.settings.openAIApiKey)
        _openAIEndpointInput = State(initialValue: refreshManager.settings.openAIEndpoint)
        _openAIOrgInput = State(initialValue: refreshManager.settings.openAIOrgId)
        _anthropicKeyInput = State(initialValue: refreshManager.settings.anthropicApiKey)
        _anthropicEndpointInput = State(initialValue: refreshManager.settings.anthropicEndpoint)
        _claudeTokenInput = State(initialValue: refreshManager.settings.claudeToken)
        _geminiApiKeyInput = State(initialValue: refreshManager.settings.geminiApiKey)
        _geminiEndpointInput = State(initialValue: refreshManager.settings.geminiEndpoint)
        _geminiTokenInput = State(initialValue: refreshManager.settings.geminiToken)
        _deepseekKeyInput = State(initialValue: refreshManager.settings.deepseekApiKey)
        _deepseekEndpointInput = State(initialValue: refreshManager.settings.deepseekEndpoint)
        _deepseekModelInput = State(initialValue: refreshManager.settings.deepseekModel)
        _volcengineKeyInput = State(initialValue: refreshManager.settings.volcengineApiKey)
        _volcengineEndpointInput = State(initialValue: refreshManager.settings.volcengineEndpoint)
        _volcengineModelInput = State(initialValue: refreshManager.settings.volcengineModel)
        _kimiKeyInput = State(initialValue: refreshManager.settings.kimiApiKey)
        _kimiEndpointInput = State(initialValue: refreshManager.settings.kimiEndpoint)
        _kimiModelInput = State(initialValue: refreshManager.settings.kimiModel)
        _glmKeyInput = State(initialValue: refreshManager.settings.glmApiKey)
        _glmEndpointInput = State(initialValue: refreshManager.settings.glmEndpoint)
        _aliyunKeyInput = State(initialValue: refreshManager.settings.aliyunApiKey)
        _aliyunEndpointInput = State(initialValue: refreshManager.settings.aliyunEndpoint)
        _aliyunCookieInput = State(initialValue: refreshManager.settings.aliyunCookie)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Dropdown Selector Bar
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text(I18n(.currentConfigItem))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Picker("", selection: $selectedTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 250)
                .id(i18n.currentLanguage)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))

            Divider()

            // Content Area
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case .openAI:
                        openAISettingsView
                    case .anthropic:
                        anthropicSettingsView
                    case .gemini:
                        geminiSettingsView
                    case .deepseek:
                        deepseekSettingsView
                    case .volcengine:
                        volcengineSettingsView
                    case .kimi:
                        kimiSettingsView
                    case .glm:
                        glmSettingsView
                    case .aliyun:
                        aliyunSettingsView
                    case .custom:
                        customProvidersSettingsView
                    case .general:
                        generalSettingsView
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 580, height: 520)
        .onAppear {
            syncFromSettings()
            MenuBarController.shared.updateSettingsTitle(tab: selectedTab)
        }
        .onChange(of: selectedTab) { newTab in
            MenuBarController.shared.updateSettingsTitle(tab: newTab)
        }
        .onChange(of: i18n.currentLanguage) { _ in
            MenuBarController.shared.updateSettingsTitle(tab: selectedTab)
        }
        .onChange(of: refreshManager.settings.openAIApiKey) { openAIKeyInput = $0 }
        .onChange(of: refreshManager.settings.openAIEndpoint) { openAIEndpointInput = $0 }
        .onChange(of: refreshManager.settings.openAIOrgId) { openAIOrgInput = $0 }
        .onChange(of: refreshManager.settings.anthropicApiKey) { anthropicKeyInput = $0 }
        .onChange(of: refreshManager.settings.anthropicEndpoint) { anthropicEndpointInput = $0 }
        .onChange(of: refreshManager.settings.claudeToken) { claudeTokenInput = $0 }
        .onChange(of: refreshManager.settings.geminiApiKey) { geminiApiKeyInput = $0 }
        .onChange(of: refreshManager.settings.geminiEndpoint) { geminiEndpointInput = $0 }
        .onChange(of: refreshManager.settings.geminiToken) { geminiTokenInput = $0 }
        .onChange(of: refreshManager.settings.deepseekApiKey) { deepseekKeyInput = $0 }
        .onChange(of: refreshManager.settings.deepseekEndpoint) { deepseekEndpointInput = $0 }
        .onChange(of: refreshManager.settings.deepseekModel) { deepseekModelInput = $0 }
        .onChange(of: refreshManager.settings.volcengineApiKey) { volcengineKeyInput = $0 }
        .onChange(of: refreshManager.settings.volcengineEndpoint) { volcengineEndpointInput = $0 }
        .onChange(of: refreshManager.settings.volcengineModel) { volcengineModelInput = $0 }
        .onChange(of: refreshManager.settings.kimiApiKey) { kimiKeyInput = $0 }
        .onChange(of: refreshManager.settings.kimiEndpoint) { kimiEndpointInput = $0 }
        .onChange(of: refreshManager.settings.kimiModel) { kimiModelInput = $0 }
        .onChange(of: refreshManager.settings.glmApiKey) { glmKeyInput = $0 }
        .onChange(of: refreshManager.settings.glmEndpoint) { glmEndpointInput = $0 }
        .onChange(of: refreshManager.settings.aliyunApiKey) { aliyunKeyInput = $0 }
        .onChange(of: refreshManager.settings.aliyunEndpoint) { aliyunEndpointInput = $0 }
        .onChange(of: refreshManager.settings.aliyunCookie) { aliyunCookieInput = $0 }
        .alert(isPresented: $showStatusAlert) {
            Alert(
                title: Text(I18n(.alertNotice)),
                message: Text(statusAlertMessage ?? ""),
                dismissButton: .default(Text(I18n(.alertOk)))
            )
        }
    }

    private func syncFromSettings() {
        openAIKeyInput = refreshManager.settings.openAIApiKey
        openAIEndpointInput = refreshManager.settings.openAIEndpoint
        openAIOrgInput = refreshManager.settings.openAIOrgId
        anthropicKeyInput = refreshManager.settings.anthropicApiKey
        anthropicEndpointInput = refreshManager.settings.anthropicEndpoint
        claudeTokenInput = refreshManager.settings.claudeToken
        geminiApiKeyInput = refreshManager.settings.geminiApiKey
        geminiEndpointInput = refreshManager.settings.geminiEndpoint
        geminiTokenInput = refreshManager.settings.geminiToken
        deepseekKeyInput = refreshManager.settings.deepseekApiKey
        deepseekEndpointInput = refreshManager.settings.deepseekEndpoint
        deepseekModelInput = refreshManager.settings.deepseekModel
        volcengineKeyInput = refreshManager.settings.volcengineApiKey
        volcengineEndpointInput = refreshManager.settings.volcengineEndpoint
        volcengineModelInput = refreshManager.settings.volcengineModel
        kimiKeyInput = refreshManager.settings.kimiApiKey
        kimiEndpointInput = refreshManager.settings.kimiEndpoint
        kimiModelInput = refreshManager.settings.kimiModel
        glmKeyInput = refreshManager.settings.glmApiKey
        glmEndpointInput = refreshManager.settings.glmEndpoint
        aliyunKeyInput = refreshManager.settings.aliyunApiKey
        aliyunEndpointInput = refreshManager.settings.aliyunEndpoint
        aliyunCookieInput = refreshManager.settings.aliyunCookie
    }

    // MARK: - 1. OpenAI Tab
    private var openAISettingsView: some View {
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
    }

    // MARK: - 2. Anthropic (Claude) Tab (Merged)
    private var anthropicSettingsView: some View {
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
                        if refreshManager.importClaudeFromLocal() {
                            statusAlertMessage = I18n(.alertClaudeLocalSuccess)
                        } else {
                            statusAlertMessage = I18n(.alertClaudeLocalNotFound)
                        }
                        showStatusAlert = true
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
    }

    // MARK: - 3. Google Gemini Tab
    private var geminiSettingsView: some View {
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

            // Method 2: OAuth Web Login / Local Credentials
            VStack(alignment: .leading, spacing: 10) {
                Text(I18n(.methodGeminiOAuth))
                    .font(.system(size: 13, weight: .bold))

                HStack(spacing: 12) {
                    Button {
                        WebLoginWindowController.show(provider: .gemini) { token in
                            if let token = token {
                                refreshManager.settings.geminiToken = token
                                refreshManager.saveSettings()
                                Task {
                                    await refreshManager.refreshGemini()
                                    statusAlertMessage = I18n(.alertGeminiWebSuccess)
                                    showStatusAlert = true
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text(I18n(.btnGoogleWebLogin))
                        }
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if refreshManager.importGeminiFromLocal() {
                            statusAlertMessage = I18n(.alertGeminiLocalSuccess)
                        } else {
                            statusAlertMessage = I18n(.alertGeminiLocalNotFound)
                        }
                        showStatusAlert = true
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
    }

    // MARK: - 4. DeepSeek Tab
    private var deepseekSettingsView: some View {
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

            // Save & Test Button
            HStack {
                Button {
                    refreshManager.settings.deepseekApiKey = deepseekKeyInput
                    refreshManager.settings.deepseekEndpoint = deepseekEndpointInput
                    refreshManager.settings.deepseekModel = deepseekModelInput
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
    }

    // MARK: - 5. 火山方舟 (字节跳动) Tab
    private var volcengineSettingsView: some View {
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
    }

    // MARK: - 6. KIMI (月之暗面) Tab
    private var kimiSettingsView: some View {
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

            // Save & Test Button
            HStack {
                Button {
                    refreshManager.settings.kimiApiKey = kimiKeyInput
                    refreshManager.settings.kimiEndpoint = kimiEndpointInput
                    refreshManager.settings.kimiModel = kimiModelInput
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
    }

    // MARK: - 7. GLM Tab
    private var glmSettingsView: some View {
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
    }

    // MARK: - 8. Aliyun Bailian Tab
    private var aliyunSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 24))
                    .foregroundColor(ProviderType.aliyunBailian.themeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.aliyunTitle))
                        .font(.system(size: 15, weight: .bold))
                    Text(I18n(.aliyunSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $refreshManager.settings.aliyunEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: refreshManager.settings.aliyunEnabled) { _ in
                        refreshManager.saveSettings()
                    }
            }

            Divider()

            // Status Card
            HStack {
                let isAuth = refreshManager.quotas[.aliyunBailian]?.isAuthorized == true
                Image(systemName: isAuth ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isAuth ? .green : .secondary)
                Text(isAuth ? I18n(.statusConnected) : I18n(.statusNotConnected))
                    .font(.system(size: 12, weight: .semibold))

                if let acc = refreshManager.quotas[.aliyunBailian]?.accountInfo {
                    Text("(\(acc))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            // Mechanism Note Card
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.accentColor)
                    Text(I18n(.aliyunQuotaNoticeTitle))
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(I18n(.aliyunQuotaNoticeDesc))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.06))
            .cornerRadius(8)

            // Auth Actions
            VStack(alignment: .leading, spacing: 8) {
                Text(I18n(.aliyunRecommendedAuthTitle))
                    .font(.system(size: 12, weight: .medium))

                HStack(spacing: 12) {
                    Button {
                        AliyunBailianService.openTerminalToLoginCLI()
                        statusAlertMessage = I18n(.alertAliyunCLIOpened)
                        showStatusAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "terminal")
                            Text(I18n(.btnAliyunTerminalCLI))
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        WebLoginWindowController.show(provider: .aliyun) { cookie in
                            if let cookie = cookie, !cookie.isEmpty {
                                refreshManager.settings.aliyunCookie = cookie
                                refreshManager.saveSettings()
                                Task {
                                    await refreshManager.refreshAliyun()
                                    statusAlertMessage = I18n(.alertAliyunWebSuccess)
                                    showStatusAlert = true
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text(I18n(.btnAliyunWebLogin))
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Aliyun API Key Field (Optional)
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.apiKeyLabel))
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    if isAliyunKeyVisible {
                        TextField(I18n(.placeholderApiKeyAliyun), text: $aliyunKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(I18n(.placeholderApiKeyAliyun), text: $aliyunKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isAliyunKeyVisible.toggle()
                    } label: {
                        Image(systemName: isAliyunKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text(I18n(.hintAliyunKey))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Platform Endpoint
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.apiEndpointLabel))
                    .font(.system(size: 12, weight: .medium))

                TextField("https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", text: $aliyunEndpointInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            // Manual Cookie (Advanced)
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.labelAliyunCookie))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                SecureField(I18n(.placeholderAliyunCookie), text: $aliyunCookieInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            // Save & Check Quota Button
            HStack {
                Button {
                    refreshManager.settings.aliyunApiKey = aliyunKeyInput
                    refreshManager.settings.aliyunEndpoint = aliyunEndpointInput
                    refreshManager.settings.aliyunCookie = aliyunCookieInput
                    refreshManager.saveSettings()

                    Task {
                        await refreshManager.refreshAliyun()
                        if refreshManager.quotas[.aliyunBailian]?.isAuthorized == true {
                            statusAlertMessage = I18n(.alertAliyunSuccess)
                        } else {
                            statusAlertMessage = "\(I18n(.alertAliyunFailed))\(refreshManager.quotas[.aliyunBailian]?.errorMessage ?? "bl auth login --console")"
                        }
                        showStatusAlert = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle")
                        Text(I18n(.btnAliyunSaveAndRefresh))
                    }
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }

            Spacer()
        }
    }

    // MARK: - 9. Domestic / Custom Providers Tab
    private var customProvidersSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "network")
                    .font(.system(size: 24))
                    .foregroundColor(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.customTitle))
                        .font(.system(size: 15, weight: .bold))
                    Text(I18n(.customSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()

                if !isAddingProvider {
                    Button {
                        if let first = DomesticProviderPreset.allPresets.first {
                            customNameInput = first.localizedName
                            customProtocolInput = first.apiProtocol
                            customEndpointInput = first.endpoint
                            customKeyInput = ""
                            customModelInput = first.defaultModel
                        } else {
                            customNameInput = I18n(.defaultCustomProviderName)
                            customProtocolInput = .openAIChat
                            customEndpointInput = "http://localhost:3000/v1"
                            customKeyInput = ""
                            customModelInput = "gpt-4o"
                        }
                        editingProviderId = nil
                        isAddingProvider = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text(I18n(.addProvider))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Divider()

            if isAddingProvider {
                // Inline Add / Edit Card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(editingProviderId == nil ? I18n(.addProvider) : I18n(.editProvider))
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                        Button(I18n(.close)) {
                            isAddingProvider = false
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }

                    // Presets quick fill
                    VStack(alignment: .leading, spacing: 6) {
                        Text(I18n(.quickFillPresets))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(DomesticProviderPreset.allPresets) { preset in
                                    Button {
                                        customNameInput = preset.localizedName
                                        customEndpointInput = preset.endpoint
                                        customProtocolInput = preset.apiProtocol
                                        customModelInput = preset.defaultModel
                                    } label: {
                                        Text(preset.localizedName.split(separator: " ").first ?? "")
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    // Form Fields
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(I18n(.providerNameLabel))
                                    .font(.system(size: 11, weight: .medium))
                                TextField(I18n(.placeholderCustomName), text: $customNameInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(I18n(.protocolTypeLabel))
                                    .font(.system(size: 11, weight: .medium))
                                Picker("", selection: $customProtocolInput) {
                                    ForEach(ApiProtocol.allCases) { proto in
                                        Text(proto.displayName).tag(proto)
                                    }
                                }
                                .pickerStyle(.menu)
                                .font(.system(size: 11))
                                .id(i18n.currentLanguage)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(I18n(.apiEndpointLabel))
                                .font(.system(size: 11, weight: .medium))
                            TextField("http://localhost:3000/v1", text: $customEndpointInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(I18n(.apiKeyLabel))
                                .font(.system(size: 11, weight: .medium))
                            HStack {
                                if isCustomKeyVisible {
                                    TextField("sk-...", text: $customKeyInput)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11))
                                } else {
                                    SecureField("sk-...", text: $customKeyInput)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11))
                                }
                                Button {
                                    isCustomKeyVisible.toggle()
                                } label: {
                                    Image(systemName: isCustomKeyVisible ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.borderless)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(I18n(.defaultModelLabel))
                                .font(.system(size: 11, weight: .medium))
                            TextField(I18n(.placeholderCustomModel), text: $customModelInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                    }

                    // Save / Cancel buttons
                    HStack(spacing: 10) {
                        Button {
                            let name = customNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            let finalName = name.isEmpty ? I18n(.fallbackCustomProviderName) : name

                            if let id = editingProviderId {
                                let updated = CustomProviderConfig(
                                    id: id,
                                    name: finalName,
                                    isEnabled: true,
                                    apiKey: customKeyInput,
                                    endpoint: customEndpointInput,
                                    apiProtocol: customProtocolInput,
                                    model: customModelInput
                                )
                                refreshManager.updateCustomProvider(updated)
                            } else {
                                let newConfig = CustomProviderConfig(
                                    name: finalName,
                                    isEnabled: true,
                                    apiKey: customKeyInput,
                                    endpoint: customEndpointInput,
                                    apiProtocol: customProtocolInput,
                                    model: customModelInput
                                )
                                refreshManager.addCustomProvider(newConfig)
                            }
                            isAddingProvider = false
                            statusAlertMessage = "\(finalName)\(I18n(.alertCustomSavedPrefix))"
                            showStatusAlert = true
                        } label: {
                            HStack {
                                Image(systemName: "checkmark")
                                Text(I18n(.saveAndConnect))
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button(I18n(.cancel)) {
                            isAddingProvider = false
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            }

            // List of configured providers
            if refreshManager.settings.customProviders.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text(I18n(.noCustomProviders))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text(I18n(.noCustomProvidersHint))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                VStack(spacing: 8) {
                    ForEach(refreshManager.settings.customProviders) { config in
                        HStack(spacing: 10) {
                            // Protocol icon / tag
                            Text(config.apiProtocol.shortName)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(config.apiProtocol == .anthropic ? Color.orange.opacity(0.15) : Color.teal.opacity(0.15))
                                .foregroundColor(config.apiProtocol == .anthropic ? Color.orange : Color.teal)
                                .cornerRadius(4)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(config.name)
                                        .font(.system(size: 12, weight: .bold))
                                    if let q = refreshManager.customQuotas[config.id], q.isAuthorized {
                                        Circle().fill(Color.green).frame(width: 6, height: 6)
                                        if let acc = q.accountInfo {
                                            Text(acc)
                                                .font(.system(size: 10))
                                                .foregroundColor(.secondary)
                                        }
                                    } else if let q = refreshManager.customQuotas[config.id], q.errorMessage != nil {
                                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                                    }
                                }

                                Text(config.endpoint)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            // Toggle
                            Toggle("", isOn: Binding(
                                get: { config.isEnabled },
                                set: { newVal in
                                    var updated = config
                                    updated.isEnabled = newVal
                                    refreshManager.updateCustomProvider(updated)
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)

                            // Edit Button
                            Button {
                                editingProviderId = config.id
                                customNameInput = config.name
                                customProtocolInput = config.apiProtocol
                                customEndpointInput = config.endpoint
                                customKeyInput = config.apiKey
                                customModelInput = config.model
                                isAddingProvider = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)

                            // Delete Button
                            Button {
                                refreshManager.removeCustomProvider(id: config.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundColor(.red.opacity(0.8))
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.03))
                        .cornerRadius(8)
                    }
                }
            }

            Spacer()
        }
    }

    // MARK: - 10. General Tab
    private var generalSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18n(.generalPreferencesTitle))
                .font(.system(size: 15, weight: .bold))

            Divider()

            // Language Selector
            HStack {
                Text(I18n(.interfaceLanguage))
                    .font(.system(size: 13))
                Spacer()
                Picker("", selection: $refreshManager.settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .frame(width: 180)
                .id(i18n.currentLanguage)
                .onChange(of: refreshManager.settings.appLanguage) { newLang in
                    refreshManager.saveSettings()
                }
            }

            // Refresh Interval
            HStack {
                Text(I18n(.refreshInterval))
                    .font(.system(size: 13))
                Spacer()
                Picker("", selection: $refreshManager.settings.refreshIntervalMinutes) {
                    Text(I18n(.refresh1Min)).tag(1)
                    Text(I18n(.refresh5Min)).tag(5)
                    Text(I18n(.refresh15Min)).tag(15)
                    Text(I18n(.refresh30Min)).tag(30)
                    Text(I18n(.refresh60Min)).tag(60)
                }
                .frame(width: 180)
                .id(i18n.currentLanguage)
                .onChange(of: refreshManager.settings.refreshIntervalMinutes) { _ in
                    refreshManager.saveSettings()
                }
            }

            // Hover preview
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.enableHoverTitle))
                        .font(.system(size: 13))
                    Text(I18n(.enableHoverSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $refreshManager.settings.enableHover)
                    .toggleStyle(.switch)
                    .onChange(of: refreshManager.settings.enableHover) { _ in
                        refreshManager.saveSettings()
                    }
            }

            // Launch at login
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.launchAtLoginTitle))
                        .font(.system(size: 13))
                    Text(I18n(.launchAtLoginSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $refreshManager.settings.launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: refreshManager.settings.launchAtLogin) { _ in
                        refreshManager.saveSettings()
                    }
            }

            Spacer()

            HStack {
                Spacer()
                Text("TokenBar v1.0.0 • \(I18n(.subtitle))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }
}
