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
                title: Text("提示"),
                message: Text(statusAlertMessage ?? ""),
                dismissButton: .default(Text("好的"))
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
                    Text("OpenAI API 授权")
                        .font(.system(size: 15, weight: .bold))
                    Text("配置官方或代理 API KEY，监控 TPM/RPM 速率限制与可用模型")
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
                Text(isAuth ? "已连接并可用" : "未授权连接")
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
                Text("OpenAI API KEY")
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    if isOpenAIKeyVisible {
                        TextField("sk-... 或 sk-proj-...", text: $openAIKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("sk-... 或 sk-proj-...", text: $openAIKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isOpenAIKeyVisible.toggle()
                    } label: {
                        Image(systemName: isOpenAIKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text("可在 OpenAI Platform (platform.openai.com) -> API Keys 中生成。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Endpoint
            VStack(alignment: .leading, spacing: 6) {
                Text("API 接入端点")
                    .font(.system(size: 12, weight: .medium))

                TextField("https://api.openai.com/v1", text: $openAIEndpointInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                Text("默认为官方接口，亦可配置中转反向代理地址。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Organization ID (Optional)
            VStack(alignment: .leading, spacing: 6) {
                Text("组织 ID (OpenAI-Organization, 可选)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                TextField("org-xxxxxxxx (选填)", text: $openAIOrgInput)
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
                            statusAlertMessage = "OpenAI 授权连接成功！已检测到接口状态与可用模型。"
                        } else {
                            statusAlertMessage = "OpenAI 连接失败: \(refreshManager.quotas[.openAI]?.errorMessage ?? "未知错误")"
                        }
                        showStatusAlert = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "checkmark.shield")
                        Text("保存并测试连接")
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
                    Text("Anthropic (Claude) 统一授权")
                        .font(.system(size: 15, weight: .bold))
                    Text("同时支持 Anthropic API Key (官方/代理) 与 Claude Code 订阅授权 (网页/本地)")
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
                Text(isAuth ? "已授权连接" : "未授权")
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
                Text("方式一：Anthropic API Key (官方或代理)")
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
                    Text("接入端点:")
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
                                statusAlertMessage = "Anthropic API Key 校验成功！"
                            } else {
                                statusAlertMessage = "校验失败: \(refreshManager.quotas[.claudeCode]?.errorMessage ?? "请核对Key")"
                            }
                            showStatusAlert = true
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield")
                            Text("保存并测试 API Key")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("可在 Anthropic Console (console.anthropic.com) 生成。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.02))
            .cornerRadius(8)

            // Section 2: Claude Code Subscription (Web OAuth / Local)
            VStack(alignment: .leading, spacing: 8) {
                Text("方式二：Claude Code 订阅 (监控 5小时与每周额度)")
                    .font(.system(size: 12, weight: .bold))

                HStack(spacing: 12) {
                    Button {
                        WebLoginWindowController.show(provider: .claude) { token in
                            if let token = token {
                                refreshManager.settings.claudeToken = token
                                refreshManager.saveSettings()
                                Task {
                                    await refreshManager.refreshClaude()
                                    statusAlertMessage = "Claude Code 网页登录授权成功！"
                                    showStatusAlert = true
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text("网站登录授权 (推荐)")
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        if refreshManager.importClaudeFromLocal() {
                            statusAlertMessage = "成功从 ~/.claude.json 读取并同步本地 Claude CLI 配额！"
                        } else {
                            statusAlertMessage = "未在本地找到 ~/.claude.json 配置文件，请先在终端运行 claude 进行登录，或使用上方网页登录授权。"
                        }
                        showStatusAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "terminal")
                            Text("读取本地 CLI 授权")
                        }
                    }
                    .buttonStyle(.bordered)
                }

                // Optional Manual Token Input
                HStack {
                    SecureField("手动输入 OAuth Token / Session (可选备用)", text: $claudeTokenInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))

                    Button("保存") {
                        refreshManager.settings.claudeToken = claudeTokenInput
                        refreshManager.saveSettings()
                        Task {
                            await refreshManager.refreshClaude()
                            statusAlertMessage = "Claude Token 已保存并刷新！"
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
                    Text("Google Gemini 授权")
                        .font(.system(size: 15, weight: .bold))
                    Text("支持 Google AI Studio API Key (永久有效) 或 Google 账号网页/本地凭证")
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
                Text(isAuth ? "已授权连接" : "未授权")
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
                    Text("方式一：Google AI Studio API Key")
                        .font(.system(size: 13, weight: .bold))
                    Text("(推荐，永久有效)")
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
                        Text("API 终端:")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 70, alignment: .leading)
                        TextField("https://generativelanguage.googleapis.com", text: $geminiEndpointInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }

                    HStack {
                        Text("获取密钥:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Link("aistudio.google.com/app/apikey", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                            .font(.system(size: 11))
                        Spacer()

                        Button("保存并测试连接") {
                            refreshManager.settings.geminiApiKey = geminiApiKeyInput
                            refreshManager.settings.geminiEndpoint = geminiEndpointInput
                            refreshManager.saveSettings()
                            Task {
                                await refreshManager.refreshGemini()
                                if refreshManager.quotas[.gemini]?.isAuthorized == true {
                                    statusAlertMessage = "Google AI Studio API 连接成功！"
                                } else {
                                    statusAlertMessage = refreshManager.quotas[.gemini]?.errorMessage ?? "连接失败"
                                }
                                showStatusAlert = true
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        if !geminiApiKeyInput.isEmpty {
                            Button("清除 Key") {
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
                Text("方式二：Google 账号网页登录 / 本地凭证 (OAuth)")
                    .font(.system(size: 13, weight: .bold))

                HStack(spacing: 12) {
                    Button {
                        WebLoginWindowController.show(provider: .gemini) { token in
                            if let token = token {
                                refreshManager.settings.geminiToken = token
                                refreshManager.saveSettings()
                                Task {
                                    await refreshManager.refreshGemini()
                                    statusAlertMessage = "Gemini 网站登录授权成功！"
                                    showStatusAlert = true
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text("Google 网站登录授权")
                        }
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if refreshManager.importGeminiFromLocal() {
                            statusAlertMessage = "已从 ~/.gemini/oauth_creds.json 读取本地凭证！"
                        } else {
                            statusAlertMessage = "未检测到本地 ~/.gemini 配置文件，请使用网页登录授权。"
                        }
                        showStatusAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "desktopcomputer")
                            Text("读取本地 Gemini 配置")
                        }
                    }
                    .buttonStyle(.bordered)
                }

                // Optional Manual Token
                VStack(alignment: .leading, spacing: 4) {
                    Text("手动设置 Gemini OAuth Access Token (可选)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    HStack {
                        SecureField("输入 Access Token", text: $geminiTokenInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))

                        Button("保存") {
                            refreshManager.settings.geminiToken = geminiTokenInput
                            refreshManager.saveSettings()
                            Task {
                                await refreshManager.refreshGemini()
                                statusAlertMessage = "Gemini Token 已保存！"
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
                    Text("DeepSeek (深度求索) 授权")
                        .font(.system(size: 15, weight: .bold))
                    Text("配置 DeepSeek API Key，自动查询账户可用余额与 TPM/RPM 速率限制")
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
                Text(isAuth ? "已连接" : "未授权")
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
                Text("DeepSeek API KEY")
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

                Text("可在 DeepSeek 开放平台 (platform.deepseek.com) -> API Keys 中生成。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Endpoint & Model
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("接入端点")
                        .font(.system(size: 12, weight: .medium))
                    TextField("https://api.deepseek.com/v1", text: $deepseekEndpointInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("默认模型")
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
                            statusAlertMessage = "DeepSeek 连接成功！已查询到账户状态与余额。"
                        } else {
                            statusAlertMessage = "DeepSeek 连接失败: \(refreshManager.quotas[.deepseek]?.errorMessage ?? "未知错误")"
                        }
                        showStatusAlert = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "checkmark.shield")
                        Text("保存并测试连接")
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
                    Text("火山方舟 (字节跳动) 授权")
                        .font(.system(size: 15, weight: .bold))
                    Text("配置火山引擎大模型服务平台 API Key (Bearer Token) 与推理接入点")
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
                Text(isAuth ? "已连接" : "未授权")
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
                Text("火山方舟 API KEY (Bearer Token)")
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    if isVolcengineKeyVisible {
                        TextField("sk-... 或 API Key", text: $volcengineKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("sk-... 或 API Key", text: $volcengineKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isVolcengineKeyVisible.toggle()
                    } label: {
                        Image(systemName: isVolcengineKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text("可在 火山引擎控制台 (console.volcengine.com/ark) -> API Key 管理中创建。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Endpoint & Endpoint ID
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("接入端点 (API v3)")
                        .font(.system(size: 12, weight: .medium))
                    TextField("https://ark.cn-beijing.volces.com/api/v3", text: $volcengineEndpointInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("接入点 ID (Endpoint ID, 选填)")
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
                            statusAlertMessage = "火山方舟连接成功！已确认接口可用。"
                        } else {
                            statusAlertMessage = "火山方舟连接失败: \(refreshManager.quotas[.volcengine]?.errorMessage ?? "未知错误")"
                        }
                        showStatusAlert = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "checkmark.shield")
                        Text("保存并测试连接")
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
                    Text("KIMI (月之暗面) 授权")
                        .font(.system(size: 15, weight: .bold))
                    Text("配置 Moonshot API Key，自动查询账户可用余额与模型速率限制")
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
                Text(isAuth ? "已连接" : "未授权")
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
                Text("KIMI / Moonshot API KEY")
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

                Text("可在 Moonshot 开放平台 (platform.moonshot.cn) -> API Key 管理中创建。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Endpoint & Model
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("接入端点")
                        .font(.system(size: 12, weight: .medium))
                    TextField("https://api.moonshot.cn/v1", text: $kimiEndpointInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("默认模型")
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
                            statusAlertMessage = "KIMI 连接成功！已查询到可用余额。"
                        } else {
                            statusAlertMessage = "KIMI 连接失败: \(refreshManager.quotas[.kimi]?.errorMessage ?? "未知错误")"
                        }
                        showStatusAlert = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "checkmark.shield")
                        Text("保存并测试连接")
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
                    Text("GLM 智谱清言 API 授权")
                        .font(.system(size: 15, weight: .bold))
                    Text("通过 BigModel 平台 API KEY 授权监控 5小时与每周配额")
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
                Text(isAuth ? "已授权连接" : "未授权")
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
                Text("GLM API KEY")
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    if isKeyVisible {
                        TextField("例如: 75f...your_api_key", text: $glmKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("例如: 75f...your_api_key", text: $glmKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isKeyVisible.toggle()
                    } label: {
                        Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text("可在 智谱开放平台 (open.bigmodel.cn) -> API Keys 中获取。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Platform Endpoint
            VStack(alignment: .leading, spacing: 6) {
                Text("接入协议与端点 (OpenAI Response 协议)")
                    .font(.system(size: 12, weight: .medium))

                Picker("", selection: $glmEndpointInput) {
                    Text("OpenAI Response 协议 (https://open.bigmodel.cn/api/v1)").tag("https://open.bigmodel.cn/api/v1")
                    Text("PaaS v4 协议 (https://open.bigmodel.cn/api/paas/v4)").tag("https://open.bigmodel.cn/api/paas/v4")
                    Text("国际站 (https://api.z.ai/api/v1)").tag("https://api.z.ai/api/v1")
                }
                .pickerStyle(.radioGroup)

                HStack {
                    Text("自定义端点:")
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
                            statusAlertMessage = "GLM API Key 校验成功，已成功拉取额度数据！"
                        } else {
                            statusAlertMessage = "GLM 校验失败: \(refreshManager.quotas[.glm]?.errorMessage ?? "请检查Key")"
                        }
                        showStatusAlert = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "checkmark.shield")
                        Text("保存并测试连接")
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
                    Text("阿里云百炼 (Token Plan) 授权")
                        .font(.system(size: 15, weight: .bold))
                    Text("监控 7 天周期额度与 5 小时额度")
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
                Text(isAuth ? "已授权连接" : "未授权")
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
                    Text("额度获取说明")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("阿里云百炼的 OpenAI 兼容端点（如 token-plan.../compatible-mode/v1）仅用于模型对话推理，并不提供配额查询接口。TokenBar 支持通过百炼官方 CLI (`bl`) 或控制台网页登录会话自动获取真实的 7 天周期额度 与 5 小时额度。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.06))
            .cornerRadius(8)

            // Auth Actions
            VStack(alignment: .leading, spacing: 8) {
                Text("推荐授权方式")
                    .font(.system(size: 12, weight: .medium))

                HStack(spacing: 12) {
                    Button {
                        AliyunBailianService.openTerminalToLoginCLI()
                        statusAlertMessage = "已为你打开终端并运行 bl auth login --console。\n登录成功后，请返回此处点击「保存并刷新检测额度」即可！"
                        showStatusAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "terminal")
                            Text("在终端登录百炼 CLI (推荐)")
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
                                    statusAlertMessage = "阿里云控制台网页登录授权成功！"
                                    showStatusAlert = true
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text("控制台网页登录授权")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Aliyun API Key Field (Optional)
            VStack(alignment: .leading, spacing: 6) {
                Text("Token Plan 专属 API KEY (可选)")
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    if isAliyunKeyVisible {
                        TextField("例如: sk-sp-xxxxxxxx", text: $aliyunKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("例如: sk-sp-xxxxxxxx", text: $aliyunKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isAliyunKeyVisible.toggle()
                    } label: {
                        Image(systemName: isAliyunKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text("百炼专属 API Key 通常以 sk-sp- 开头，供推理端点与工具使用。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Platform Endpoint
            VStack(alignment: .leading, spacing: 6) {
                Text("接入端点 (兼容 OpenAI 接口协议)")
                    .font(.system(size: 12, weight: .medium))

                TextField("https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", text: $aliyunEndpointInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            // Manual Cookie (Advanced)
            VStack(alignment: .leading, spacing: 6) {
                Text("控制台 Session Cookie (可选/备用)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                SecureField("通过网页登录会自动填入，亦可手动粘贴", text: $aliyunCookieInput)
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
                            statusAlertMessage = "百炼配额获取成功！已更新 7 天周期额度与 5 小时额度。"
                        } else {
                            statusAlertMessage = "百炼获取失败: \(refreshManager.quotas[.aliyunBailian]?.errorMessage ?? "请在终端执行 bl auth login --console 或使用网页登录")"
                        }
                        showStatusAlert = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise.circle")
                        Text("保存并刷新检测额度")
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
                    Text("国内厂商 / 自定义接口")
                        .font(.system(size: 15, weight: .bold))
                    Text("支持 OpenAI Chat Completions、OpenAI Response 或 Anthropic 协议")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()

                if !isAddingProvider {
                    Button {
                        if let first = DomesticProviderPreset.allPresets.first {
                            customNameInput = first.name
                            customProtocolInput = first.apiProtocol
                            customEndpointInput = first.endpoint
                            customKeyInput = ""
                            customModelInput = first.defaultModel
                        } else {
                            customNameInput = "OpenAI 兼容代理"
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
                            Text("添加新厂商")
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
                        Text(editingProviderId == nil ? "添加模型厂商" : "编辑模型厂商")
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                        Button("关闭") {
                            isAddingProvider = false
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }

                    // Presets quick fill
                    VStack(alignment: .leading, spacing: 6) {
                        Text("快捷预填常用国内厂商:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(DomesticProviderPreset.allPresets) { preset in
                                    Button {
                                        customNameInput = preset.name
                                        customEndpointInput = preset.endpoint
                                        customProtocolInput = preset.apiProtocol
                                        customModelInput = preset.defaultModel
                                    } label: {
                                        Text(preset.name.split(separator: " ").first ?? "")
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
                                Text("厂商名称")
                                    .font(.system(size: 11, weight: .medium))
                                TextField("例如: OpenAI 兼容代理", text: $customNameInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("接口协议类型 (区分 OpenAI 两类协议)")
                                    .font(.system(size: 11, weight: .medium))
                                Picker("", selection: $customProtocolInput) {
                                    ForEach(ApiProtocol.allCases) { proto in
                                        Text(proto.displayName).tag(proto)
                                    }
                                }
                                .pickerStyle(.menu)
                                .font(.system(size: 11))
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("接入端点 (API Endpoint)")
                                .font(.system(size: 11, weight: .medium))
                            TextField("http://localhost:3000/v1", text: $customEndpointInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("API KEY")
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
                            Text("默认模型 (可选)")
                                .font(.system(size: 11, weight: .medium))
                            TextField("例如: deepseek-chat 或 claude-3-5-sonnet", text: $customModelInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }
                    }

                    // Save / Cancel buttons
                    HStack(spacing: 10) {
                        Button {
                            let name = customNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            let finalName = name.isEmpty ? "自定义厂商" : name

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
                            statusAlertMessage = "\(finalName) 已保存，正在检测连通性..."
                            showStatusAlert = true
                        } label: {
                            HStack {
                                Image(systemName: "checkmark")
                                Text("保存并连接")
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("取消") {
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
                    Text("暂未添加任何国内或自定义厂商")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("点击上方「＋ 添加新厂商」可添加硅基流动、MiniMax、通义千问等自定义端点。")
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
