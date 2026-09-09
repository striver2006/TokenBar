import SwiftUI

@MainActor
/// AccessKey Secret 输入框的读取状态。
///
/// `.unavailable` 存在的意义：此时输入框为空**只代表这一轮没读到**，不代表钥匙串里
/// 没有。把它当成「用户想清空」去执行删除，就会抹掉真实存在的账号级长期凭证。
enum SecretFieldState {
    case loading
    case ready
    case unavailable
}

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
    @State private var deepseekThresholdInput: String = "10"
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
    @State private var kimiThresholdInput: String = "10"
    @State private var isKimiKeyVisible: Bool = false

    // OpenRouter State
    @State private var openRouterKeyInput: String = ""
    @State private var openRouterEndpointInput: String = "https://openrouter.ai/api/v1"
    @State private var openRouterThresholdInput: String = "5"
    @State private var isOpenRouterKeyVisible: Bool = false

    // GLM State
    @State private var glmKeyInput: String = ""
    @State private var glmEndpointInput: String = "https://open.bigmodel.cn/api/v1"
    @State private var isKeyVisible: Bool = false

    // Aliyun State
    @State private var aliyunKeyInput: String = ""
    @State private var aliyunEndpointInput: String = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
    @State private var isAliyunKeyVisible: Bool = false
    @State private var aliyunCookieInput: String = ""
    // 方式一：OpenAPI AccessKey
    @State private var aliyunAKIdInput: String = ""
    @State private var aliyunAKSecretInput: String = ""
    @State private var isAliyunAKSecretVisible: Bool = false
    /// 钥匙串读取状态。init 里 await 不了，所以初值必然是 .loading，由 .task 推进。
    /// `.unavailable` 是关键态：此时输入框内容**不可信**，禁止据此推断「用户想删」。
    @State private var aliyunSecretState: SecretFieldState = .loading
    /// 保存按钮的在途标记：写钥匙串现在是 async，不挡住会重入
    @State private var isSavingAliyunAK: Bool = false
    @State private var aliyunRegionInput: String = "cn-beijing"
    @State private var aliyunSiteInput: String = "domestic"
    @State private var aliyunSwitchAgentInput: String = ""
    @State private var aliyunReuseCLIInput: Bool = true
    @State private var aliyunBalanceThresholdInput: String = "10"

    // Custom Providers State
    @State private var isAddingProvider: Bool = false
    @State private var editingProviderId: UUID? = nil
    @State private var customNameInput: String = ""
    @State private var customProtocolInput: ApiProtocol = .openAIChat
    @State private var customKeyInput: String = ""
    @State private var customEndpointInput: String = "http://localhost:3000/v1"
    @State private var customModelInput: String = ""
    @State private var customThresholdInput: String = ""
    @State private var customCookieInput: String = ""
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
        _deepseekThresholdInput = State(initialValue: thresholdString(refreshManager.settings.deepseekBalanceAlertThreshold))
        _volcengineKeyInput = State(initialValue: refreshManager.settings.volcengineApiKey)
        _volcengineEndpointInput = State(initialValue: refreshManager.settings.volcengineEndpoint)
        _volcengineModelInput = State(initialValue: refreshManager.settings.volcengineModel)
        _kimiKeyInput = State(initialValue: refreshManager.settings.kimiApiKey)
        _kimiEndpointInput = State(initialValue: refreshManager.settings.kimiEndpoint)
        _kimiModelInput = State(initialValue: refreshManager.settings.kimiModel)
        _kimiThresholdInput = State(initialValue: thresholdString(refreshManager.settings.kimiBalanceAlertThreshold))
        _openRouterKeyInput = State(initialValue: refreshManager.settings.openRouterApiKey)
        _openRouterEndpointInput = State(initialValue: refreshManager.settings.openRouterEndpoint)
        _openRouterThresholdInput = State(initialValue: thresholdString(refreshManager.settings.openRouterBalanceAlertThreshold))
        _glmKeyInput = State(initialValue: refreshManager.settings.glmApiKey)
        _glmEndpointInput = State(initialValue: refreshManager.settings.glmEndpoint)
        _aliyunKeyInput = State(initialValue: refreshManager.settings.aliyunApiKey)
        _aliyunEndpointInput = State(initialValue: refreshManager.settings.aliyunEndpoint)
        _aliyunCookieInput = State(initialValue: refreshManager.settings.aliyunCookie)
        _aliyunAKIdInput = State(initialValue: refreshManager.settings.aliyunAccessKeyId)
        // Secret 只从钥匙串读，而钥匙串必须在后台线程读（SecItemCopyMatching 会阻塞
        // 主线程，弹授权框时更是无限期）。init 里 await 不了，所以这里只留空 + 标 .loading，
        // 真值由 body 的 .task 异步补上。绝不退回明文。
        _aliyunAKSecretInput = State(initialValue: "")
        _aliyunRegionInput = State(initialValue: refreshManager.settings.aliyunConsoleRegion)
        _aliyunSiteInput = State(initialValue: refreshManager.settings.aliyunConsoleSite)
        _aliyunSwitchAgentInput = State(
            initialValue: refreshManager.settings.aliyunConsoleSwitchAgent > 0
                ? String(refreshManager.settings.aliyunConsoleSwitchAgent) : "")
        _aliyunReuseCLIInput = State(initialValue: refreshManager.settings.aliyunReuseCLIConfig)
        _aliyunBalanceThresholdInput = State(
            initialValue: String(format: "%g", refreshManager.settings.aliyunBalanceAlertThreshold))
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
                    case .openRouter:
                        openRouterSettingsView
                    case .glm:
                        glmSettingsView
                    case .aliyun:
                        aliyunSettingsView
                    case .custom:
                        customProvidersSettingsView
                    case .displayOrder:
                        displayOrderSettingsView
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
        .task {
            // 钥匙串读取放 .task 而不是 onAppear 里再开 Task：随 view 生命周期自动取消，
            // 不会在窗口已经关掉后回来写 @State。SwiftUI 保证 .onAppear 先于 .task 体执行，
            // 所以 syncFromSettings() 一定已经把明文字段填好了，两者之间没有竞争。
            //
            // 前提：MenuBarController.openSettings 每次都重建 NSHostingView
            // （MenuBarController.swift:459/473），是全新 view identity，所以这个 .task
            // 每次打开设置窗口都会重跑。若将来改成复用 hosting view 只做显隐，无 id: 的
            // .task 只在首次插入时触发一次，第二次打开就读不到最新的 Secret —— 那时必须
            // 换成 .task(id:) 或回到 .onAppear + Task。
            await loadAliyunSecretFromKeychain()
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
        .onChange(of: refreshManager.settings.openRouterApiKey) { openRouterKeyInput = $0 }
        .onChange(of: refreshManager.settings.openRouterEndpoint) { openRouterEndpointInput = $0 }
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
        deepseekThresholdInput = thresholdString(refreshManager.settings.deepseekBalanceAlertThreshold)
        volcengineKeyInput = refreshManager.settings.volcengineApiKey
        volcengineEndpointInput = refreshManager.settings.volcengineEndpoint
        volcengineModelInput = refreshManager.settings.volcengineModel
        kimiKeyInput = refreshManager.settings.kimiApiKey
        kimiEndpointInput = refreshManager.settings.kimiEndpoint
        kimiModelInput = refreshManager.settings.kimiModel
        kimiThresholdInput = thresholdString(refreshManager.settings.kimiBalanceAlertThreshold)
        openRouterKeyInput = refreshManager.settings.openRouterApiKey
        openRouterEndpointInput = refreshManager.settings.openRouterEndpoint
        openRouterThresholdInput = thresholdString(refreshManager.settings.openRouterBalanceAlertThreshold)
        glmKeyInput = refreshManager.settings.glmApiKey
        glmEndpointInput = refreshManager.settings.glmEndpoint
        aliyunKeyInput = refreshManager.settings.aliyunApiKey
        aliyunEndpointInput = refreshManager.settings.aliyunEndpoint
        aliyunCookieInput = refreshManager.settings.aliyunCookie
        aliyunAKIdInput = refreshManager.settings.aliyunAccessKeyId
        // Secret 不在这里读 —— 它必须走后台线程，见 loadAliyunSecretFromKeychain()
        aliyunRegionInput = refreshManager.settings.aliyunConsoleRegion
        aliyunSiteInput = refreshManager.settings.aliyunConsoleSite
        aliyunSwitchAgentInput = refreshManager.settings.aliyunConsoleSwitchAgent > 0
            ? String(refreshManager.settings.aliyunConsoleSwitchAgent) : ""
        aliyunReuseCLIInput = refreshManager.settings.aliyunReuseCLIConfig
        aliyunBalanceThresholdInput = String(
            format: "%g", refreshManager.settings.aliyunBalanceAlertThreshold)
    }

    /// 从钥匙串加载 AccessKey Secret。只在后台线程读，**读不到时不清空输入框**。
    ///
    /// 「读不到就清空」看着无害，实则是数据丢失的起点：清空 → 用户点保存 →
    /// 走 delete 分支 → 钥匙串里真实存在的 Secret 被抹掉。所以 `.unavailable`
    /// 下只改状态、不动内容，并由 saveAliyunAccessKeyAndTest() 跳过删除。
    private func loadAliyunSecretFromKeychain() async {
        aliyunSecretState = .loading
        let before = aliyunAKSecretInput   // 挂起前快照，防止盖掉用户这期间的输入

        let result = await KeychainSecretStore.shared.lookupAsync(.aliyunAccessKeySecret)

        // 正常路径下输入框在 loading 期间是 disabled 的，这里是双保险
        let untouched = (aliyunAKSecretInput == before)

        switch result {
        case .found(let secret):
            if untouched { aliyunAKSecretInput = secret }
            aliyunSecretState = .ready
        case .absent:
            if untouched { aliyunAKSecretInput = "" }
            aliyunSecretState = .ready
        case .unavailable:
            aliyunSecretState = .unavailable
            Log.lifecycle.error("设置页读取 AccessKey Secret 失败（超时或钥匙串不可用），已进入保护模式：不清空、不删除")
        }
    }

    /// 阈值显示：整数值省略小数位
    private func thresholdString(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(value)
    }

    /// 阈值解析：非法输入回退到默认值
    private func parseThreshold(_ text: String, fallback: Double) -> Double {
        if let v = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), v >= 0 {
            return v
        }
        return fallback
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
                    refreshManager.settings.deepseekBalanceAlertThreshold = parseThreshold(deepseekThresholdInput, fallback: 10)
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
                    refreshManager.settings.kimiBalanceAlertThreshold = parseThreshold(kimiThresholdInput, fallback: 10)
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

    // MARK: - 6.5 OpenRouter Tab
    private var openRouterSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 24))
                    .foregroundColor(ProviderType.openRouter.themeColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n(.openRouterTitle))
                        .font(.system(size: 15, weight: .bold))
                    Text(I18n(.openRouterSubtitle))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $refreshManager.settings.openRouterEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: refreshManager.settings.openRouterEnabled) { _ in
                        refreshManager.saveSettings()
                    }
            }

            Divider()

            // Status Card
            HStack {
                let isAuth = refreshManager.quotas[.openRouter]?.isAuthorized == true
                Image(systemName: isAuth ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isAuth ? .green : .secondary)
                Text(isAuth ? I18n(.statusConnected) : I18n(.statusNotConnected))
                    .font(.system(size: 12, weight: .semibold))

                if let acc = refreshManager.quotas[.openRouter]?.accountInfo {
                    Text("(\(acc))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(10)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(8)

            // OpenRouter API Key
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.apiKeyLabel))
                    .font(.system(size: 12, weight: .medium))

                HStack {
                    if isOpenRouterKeyVisible {
                        TextField("sk-or-...", text: $openRouterKeyInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("sk-or-...", text: $openRouterKeyInput)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        isOpenRouterKeyVisible.toggle()
                    } label: {
                        Image(systemName: isOpenRouterKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                Text(I18n(.hintOpenRouterKey))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Endpoint
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.apiEndpointLabel))
                    .font(.system(size: 12, weight: .medium))
                TextField("https://openrouter.ai/api/v1", text: $openRouterEndpointInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            // Balance Alert Threshold
            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.balanceThresholdLabel))
                    .font(.system(size: 12, weight: .medium))
                TextField("5", text: $openRouterThresholdInput)
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
                    refreshManager.settings.openRouterApiKey = openRouterKeyInput
                    refreshManager.settings.openRouterEndpoint = openRouterEndpointInput
                    refreshManager.settings.openRouterBalanceAlertThreshold = parseThreshold(openRouterThresholdInput, fallback: 5)
                    refreshManager.saveSettings()

                    Task {
                        await refreshManager.refreshOpenRouter()
                        if refreshManager.quotas[.openRouter]?.isAuthorized == true {
                            statusAlertMessage = "\(I18n(.openRouterTitle)) ✓ \(refreshManager.quotas[.openRouter]?.accountInfo ?? "")"
                        } else {
                            statusAlertMessage = "OpenRouter: \(refreshManager.quotas[.openRouter]?.errorMessage ?? I18n(.alertUnknownError))"
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
    //
    // 三张方式卡片，顺序即通道优先级：
    //   方式一 AccessKey（推荐，多机并发）→ 方式二 CLI（备用）→ 方式三 Cookie（兜底）
    private var aliyunSettingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                aliyunHeader
                Divider()
                aliyunStatusCard
                aliyunAccessKeyCard
                aliyunCLICard
                aliyunCookieCard
                Spacer(minLength: 8)
            }
            .padding(.trailing, 4)
        }
    }

    private var aliyunHeader: some View {
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
    }

    private var aliyunStatusCard: some View {
        HStack {
            let isAuth = refreshManager.quotas[.aliyunBailian]?.isAuthorized == true
            Image(systemName: isAuth ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isAuth ? .green : .secondary)
            Text(isAuth ? I18n(.statusConnected) : I18n(.statusNotConnected))
                .font(.system(size: 12, weight: .semibold))

            // accountInfo 里带着实际生效的通道名，便于排障
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
    }

    // MARK: 方式一：OpenAPI AccessKey

    private var aliyunAccessKeyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal.fill")
                    .foregroundColor(.accentColor)
                Text(I18n(.aliyunMethodAKTitle))
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(I18n(.aliyunMethodAKDesc))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                if let url = URL(string: "https://ram.console.aliyun.com/manage/ak") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.up.forward.square")
                    Text(I18n(.btnAliyunOpenRAMConsole))
                }
            }
            .buttonStyle(.bordered)

            DisclosureGroup(I18n(.aliyunRAMHowToTitle)) {
                Text(I18n(.aliyunRAMHowToSteps))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .font(.system(size: 11))

            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.labelAliyunAccessKeyId))
                    .font(.system(size: 12, weight: .medium))
                TextField(I18n(.placeholderAliyunAccessKeyId), text: $aliyunAKIdInput)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.labelAliyunAccessKeySecret))
                    .font(.system(size: 12, weight: .medium))
                HStack {
                    if isAliyunAKSecretVisible {
                        TextField(I18n(.placeholderAliyunAccessKeySecret), text: $aliyunAKSecretInput)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(I18n(.placeholderAliyunAccessKeySecret), text: $aliyunAKSecretInput)
                            .textFieldStyle(.roundedBorder)
                    }
                    if aliyunSecretState == .loading {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 16, height: 16)
                    }
                    Button {
                        isAliyunAKSecretVisible.toggle()
                    } label: {
                        Image(systemName: isAliyunAKSecretVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                // 读取期间禁止编辑：这几百毫秒里输入的内容会被读回来的值盖掉，
                // 与其打补丁不如不让用户白打字。最坏 5 秒（lookupAsync 超时）。
                .disabled(aliyunSecretState == .loading)

                if aliyunSecretState == .loading {
                    Text(I18n(.hintAliyunSecretLoading))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                } else if aliyunSecretState == .unavailable {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text(I18n(.warnAliyunSecretUnreadable))
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(I18n(.btnRetryReadKeychain)) {
                            Task { await loadAliyunSecretFromKeychain() }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 10))
                    }
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(I18n(.labelAliyunConsoleRegion))
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: $aliyunRegionInput) {
                        Text("cn-beijing（中国大陆）").tag("cn-beijing")
                        Text("ap-southeast-1（新加坡）").tag("ap-southeast-1")
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(I18n(.labelAliyunConsoleSite))
                        .font(.system(size: 12, weight: .medium))
                    Picker("", selection: $aliyunSiteInput) {
                        Text("domestic（aliyun.com）").tag("domestic")
                        Text("international（alibabacloud.com）").tag("international")
                    }
                    .labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.labelAliyunBalanceThreshold))
                    .font(.system(size: 12, weight: .medium))
                TextField("10", text: $aliyunBalanceThresholdInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            DisclosureGroup(I18n(.aliyunAdvancedTitle)) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(I18n(.labelAliyunSwitchAgent))
                            .font(.system(size: 11, weight: .medium))
                        TextField("", text: $aliyunSwitchAgentInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        Text(I18n(.hintAliyunSwitchAgent))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle(I18n(.toggleAliyunReuseCLIConfig), isOn: $aliyunReuseCLIInput)
                        .font(.system(size: 11))
                    Text(I18n(.hintAliyunReuseCLIConfig))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .font(.system(size: 11))

            Button {
                saveAliyunAccessKeyAndTest()
            } label: {
                HStack {
                    if isSavingAliyunAK {
                        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "checkmark.shield")
                    }
                    Text(I18n(.btnAliyunSaveAndTestAK))
                }
            }
            .buttonStyle(.borderedProminent)
            // loading 期间禁用是必须的：此时输入框内容还没被钥匙串的值覆盖，
            // 拿它去保存等于用一个半成品状态做写/删决策。
            .disabled(aliyunSecretState == .loading || isSavingAliyunAK)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.06))
        .cornerRadius(8)
    }

    /// 保存 AccessKey 并立即验证。
    ///
    /// 三条不可退让的语义：
    /// 1. Secret **只**写钥匙串 —— 写不进去就如实报错并中止，绝不降级成明文存进
    ///    AppSettings；连 akId 等明文字段也一并不写，避免「id 更新了、secret 还是老的」错配。
    /// 2. 钥匙串**读不到**时不执行删除 —— 输入框为空只代表「这一轮没读到」，不代表
    ///    「用户想清空」，照删会抹掉真实存在的账号级长期凭证。数据丢失 > UI 卡顿。
    /// 3. 删除失败同样中止 —— 否则 akId 更新了而旧 secret 还留在钥匙串里，
    ///    刷新会拿着用户以为已经删掉的凭证继续跑。
    private func saveAliyunAccessKeyAndTest() {
        // 按钮已 disabled，这里是防重入 / 防将来有人绕过 UI 调用的双保险
        guard aliyunSecretState != .loading, !isSavingAliyunAK else { return }

        let akId = aliyunAKIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = SecretSaveAction.resolve(
            input: aliyunAKSecretInput,
            storeReadable: aliyunSecretState != .unavailable
        )

        isSavingAliyunAK = true
        // struct 是 @MainActor，Task 继承同一隔离域，await 之后写 @State 安全
        Task {
            defer { isSavingAliyunAK = false }

            var noticePrefix = ""
            switch action {
            case .write(let secret):
                guard await KeychainSecretStore.shared.setAsync(secret, for: .aliyunAccessKeySecret) else {
                    statusAlertMessage = I18n(.alertAliyunSecretStoreFailed)
                    showStatusAlert = true
                    return                                    // ← 语义 1：明文字段一并不写
                }
                aliyunSecretState = .ready                     // 刚写成功，说明钥匙串通了

            case .delete:
                guard await KeychainSecretStore.shared.deleteAsync(.aliyunAccessKeySecret) else {
                    statusAlertMessage = I18n(.alertAliyunSecretDeleteFailed)
                    showStatusAlert = true
                    return                                    // ← 语义 3
                }

            case .keepExisting:
                // ← 语义 2：读不到 + 输入框空，绝不删。其余明文设置照常保存，
                //   提示拼进最终 alert，避免和刷新结果抢同一个 alert 槽位。
                noticePrefix = I18n(.alertAliyunSecretKeptUnreadable) + "\n\n"
                Log.lifecycle.notice("设置页保存：钥匙串读不到且输入框为空，已跳过删除以保护现有 Secret")
            }

            refreshManager.settings.aliyunAccessKeyId = akId
            refreshManager.settings.aliyunConsoleRegion = aliyunRegionInput
            refreshManager.settings.aliyunConsoleSite = aliyunSiteInput
            refreshManager.settings.aliyunConsoleSwitchAgent =
                Int(aliyunSwitchAgentInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            refreshManager.settings.aliyunReuseCLIConfig = aliyunReuseCLIInput
            refreshManager.settings.aliyunBalanceAlertThreshold =
                Double(aliyunBalanceThresholdInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 10
            refreshManager.saveSettings()

            await refreshManager.refreshAliyun()
            let quota = refreshManager.quotas[.aliyunBailian]
            if quota?.isAuthorized == true {
                let channel = quota?.accountInfo ?? ""
                statusAlertMessage =
                    noticePrefix + "\(I18n(.alertAliyunSuccess))\(channel.isEmpty ? "" : "\n\(channel)")"
            } else {
                statusAlertMessage =
                    noticePrefix + "\(I18n(.alertAliyunFailed))\(quota?.errorMessage ?? "")"
            }
            showStatusAlert = true
        }
    }

    // MARK: 方式二：百炼 CLI（备用）

    private var aliyunCLICard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18n(.aliyunMethodCLITitle))
                .font(.system(size: 12, weight: .semibold))
            Text(I18n(.aliyunMethodCLIDesc))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                // 终端拉起结果由服务层回调（主线程），失败时给出可手动执行的提示
                AliyunBailianService.openTerminalToLoginCLI { success, message in
                    statusAlertMessage = success
                        ? I18n(.alertAliyunCLIOpened)
                        : (message ?? I18n(.alertUnknownError))
                    showStatusAlert = true
                }
            } label: {
                HStack {
                    Image(systemName: "terminal")
                    Text(I18n(.btnAliyunTerminalCLI))
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    // MARK: 方式三：控制台 Cookie（兜底）

    private var aliyunCookieCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(I18n(.aliyunMethodCookieTitle))
                .font(.system(size: 12, weight: .semibold))
            Text(I18n(.aliyunMethodCookieDesc))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                WebLoginWindowController.show(provider: .aliyun) { cookie in
                    if let cookie = cookie, !cookie.isEmpty {
                        refreshManager.settings.aliyunCookie = cookie
                        aliyunCookieInput = cookie
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

            VStack(alignment: .leading, spacing: 6) {
                Text(I18n(.labelAliyunCookie))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                SecureField(I18n(.placeholderAliyunCookie), text: $aliyunCookieInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            Button {
                refreshManager.settings.aliyunCookie = aliyunCookieInput
                refreshManager.saveSettings()
                Task {
                    await refreshManager.refreshAliyun()
                    let quota = refreshManager.quotas[.aliyunBailian]
                    statusAlertMessage = quota?.isAuthorized == true
                        ? I18n(.alertAliyunSuccess)
                        : "\(I18n(.alertAliyunFailed))\(quota?.errorMessage ?? "")"
                    showStatusAlert = true
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise.circle")
                    Text(I18n(.btnAliyunSaveAndRefresh))
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
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
                        customThresholdInput = ""
                        customCookieInput = ""
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

                        VStack(alignment: .leading, spacing: 4) {
                            Text(I18n(.balanceThresholdLabel))
                                .font(.system(size: 11, weight: .medium))
                            TextField("10", text: $customThresholdInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(I18n(.consoleCookieLabel))
                                .font(.system(size: 11, weight: .medium))
                            TextField("Cookie", text: $customCookieInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            Text(I18n(.consoleCookieHint))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
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
                                    model: customModelInput,
                                    balanceAlertThreshold: Double(customThresholdInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                                    consoleCookie: customCookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                )
                                refreshManager.updateCustomProvider(updated)
                            } else {
                                let newConfig = CustomProviderConfig(
                                    name: finalName,
                                    isEnabled: true,
                                    apiKey: customKeyInput,
                                    endpoint: customEndpointInput,
                                    apiProtocol: customProtocolInput,
                                    model: customModelInput,
                                    balanceAlertThreshold: Double(customThresholdInput.trimmingCharacters(in: .whitespacesAndNewlines)),
                                    consoleCookie: customCookieInput.trimmingCharacters(in: .whitespacesAndNewlines)
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
                                customThresholdInput = config.balanceAlertThreshold.map { thresholdString($0) } ?? ""
                                customCookieInput = config.consoleCookie
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

    // MARK: - Display Order Tab
    private var displayOrderSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(I18n(.displayOrder))
                    .font(.system(size: 15, weight: .bold))
                Text(I18n(.displayOrderSubtitle))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                Text(I18n(.displayOrderHint))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button(I18n(.resetOrder)) {
                    resetProviderOrder()
                }
                .font(.system(size: 11))
            }

            if enabledOrderKeys.isEmpty {
                Text(I18n(.noEnabledProviders))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 6) {
                    ForEach(enabledOrderKeys.indices, id: \.self) { index in
                        orderRow(key: enabledOrderKeys[index], index: index, count: enabledOrderKeys.count)
                    }
                }
            }

            Spacer()
        }
    }

    /// 当前已启用厂商的显示顺序键（已按 providerOrder 排序，未列入的按默认顺序追加）。
    private var enabledOrderKeys: [String] {
        let settings = refreshManager.settings
        var keys: [String] = ProviderOrdering.defaultOrder.compactMap { key in
            guard let type = ProviderOrdering.parseProviderType(key), settings.isEnabled(type) else { return nil }
            return key
        }
        keys.append(contentsOf: settings.customProviders.filter(\.isEnabled).map { ProviderOrdering.customKey($0.id) })

        let order = settings.providerOrder
        return keys
            .enumerated()
            .sorted {
                let l = ProviderOrdering.sortIndex($0.element, order: order)
                let r = ProviderOrdering.sortIndex($1.element, order: order)
                return (l, $0.offset) < (r, $1.offset)
            }
            .map { $0.element }
    }

    private func orderDisplayName(for key: String) -> String {
        if let type = ProviderOrdering.parseProviderType(key) {
            return type.displayName
        }
        if let id = ProviderOrdering.parseCustomKey(key) {
            return refreshManager.settings.customProviders.first { $0.id == id }?.name ?? key
        }
        return key
    }

    private func orderRow(key: String, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ProviderOrdering.parseProviderType(key)?.iconName ?? "network")
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            Text(orderDisplayName(for: key))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button {
                moveOrderKey(at: index, offset: -1)
            } label: {
                Label(I18n(.moveUp), systemImage: "arrow.up")
                    .font(.system(size: 11))
            }
            .disabled(index == 0)

            Button {
                moveOrderKey(at: index, offset: 1)
            } label: {
                Label(I18n(.moveDown), systemImage: "arrow.down")
                    .font(.system(size: 11))
            }
            .disabled(index == count - 1)
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .cornerRadius(8)
    }

    private func moveOrderKey(at index: Int, offset: Int) {
        var keys = enabledOrderKeys
        let target = index + offset
        guard keys.indices.contains(index), keys.indices.contains(target) else { return }
        keys.swapAt(index, target)
        refreshManager.settings.providerOrder = keys
        refreshManager.saveSettings()
    }

    private func resetProviderOrder() {
        refreshManager.settings.providerOrder = []
        refreshManager.saveSettings()
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

            // 菜单栏额度摘要（开关 + 厂商 + 指标）
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(I18n(.menuBarQuotaTitle))
                            .font(.system(size: 13))
                        Text(I18n(.menuBarQuotaSubtitle))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $refreshManager.settings.menuBarQuotaEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: refreshManager.settings.menuBarQuotaEnabled) { enabled in
                            // 首次开启时默认选中第一个已启用厂商，省去再点一次
                            if enabled, refreshManager.settings.menuBarProviderKey.isEmpty {
                                refreshManager.settings.menuBarProviderKey = enabledOrderKeys.first ?? ""
                            }
                            refreshManager.saveSettings()
                        }
                }

                if refreshManager.settings.menuBarQuotaEnabled {
                    HStack {
                        Text(I18n(.menuBarProviderLabel))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $refreshManager.settings.menuBarProviderKey) {
                            Text(I18n(.menuBarNoProviderSelected)).tag("")
                            ForEach(enabledOrderKeys, id: \.self) { key in
                                Text(orderDisplayName(for: key)).tag(key)
                            }
                        }
                        .frame(width: 180)
                        .id(i18n.currentLanguage)
                        .onChange(of: refreshManager.settings.menuBarProviderKey) { _ in
                            refreshManager.saveSettings()
                        }
                    }

                    HStack {
                        Text(I18n(.menuBarMetricLabel))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Picker("", selection: $refreshManager.settings.menuBarMetric) {
                            ForEach(MenuBarMetric.allCases) { metric in
                                Text(metric.displayName).tag(metric)
                            }
                        }
                        .frame(width: 180)
                        .id(i18n.currentLanguage)
                        .onChange(of: refreshManager.settings.menuBarMetric) { _ in
                            refreshManager.saveSettings()
                        }
                    }
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
                Text("TokenBar v1.1.1 • \(I18n(.subtitle))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }
}
