import AppKit
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

/// 设置页 – 阿里云百炼 tab。
///
/// 三张方式卡片，顺序即通道优先级：
///   方式一 AccessKey（推荐，多机并发）→ 方式二 CLI（备用）→ 方式三 Cookie（兜底）
///
/// 输入状态随 tab 走：由本视图自持、从 settings 种子化；AccessKey Secret 例外，
/// 它只能从钥匙串后台读取，由 `.task(id: openCount)` 在视图插入与窗口每次重开时加载
/// （与原 SettingsView 在父层 `.task(id: request.openCount)` 的时机一致）。
@MainActor
struct SettingsAliyunTab: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared
    @Binding var statusAlertMessage: String?
    @Binding var showStatusAlert: Bool
    /// SettingsWindowRequest.openCount：窗口复用时重开递增，触发输入重新种子化 + 钥匙串重读
    var openCount: Int

    // Aliyun State
    @State private var aliyunKeyInput: String
    @State private var aliyunEndpointInput: String
    @State private var isAliyunKeyVisible: Bool = false
    @State private var aliyunCookieInput: String
    // 方式一：OpenAPI AccessKey
    @State private var aliyunAKIdInput: String
    @State private var aliyunAKSecretInput: String
    @State private var isAliyunAKSecretVisible: Bool = false
    /// 钥匙串读取状态。init 里 await 不了，所以初值必然是 .loading，由 .task 推进。
    /// `.unavailable` 是关键态：此时输入框内容**不可信**，禁止据此推断「用户想删」。
    @State private var aliyunSecretState: SecretFieldState = .loading
    /// 保存按钮的在途标记：写钥匙串现在是 async，不挡住会重入
    @State private var isSavingAliyunAK: Bool = false
    @State private var aliyunRegionInput: String
    @State private var aliyunSiteInput: String
    @State private var aliyunSwitchAgentInput: String
    @State private var aliyunReuseCLIInput: Bool
    @State private var aliyunBalanceThresholdInput: String

    init(refreshManager: RefreshManager,
         statusAlertMessage: Binding<String?>,
         showStatusAlert: Binding<Bool>,
         openCount: Int) {
        self.refreshManager = refreshManager
        _statusAlertMessage = statusAlertMessage
        _showStatusAlert = showStatusAlert
        self.openCount = openCount
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

    var body: some View {
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
        .onChange(of: refreshManager.settings.aliyunApiKey) { aliyunKeyInput = $0 }
        .onChange(of: refreshManager.settings.aliyunEndpoint) { aliyunEndpointInput = $0 }
        .onChange(of: refreshManager.settings.aliyunCookie) { aliyunCookieInput = $0 }
        .task(id: openCount) {
            // 钥匙串读取放 .task 而不是 onAppear 里再开 Task：随 view 生命周期自动取消，
            // 不会在窗口已经关掉后回来写 @State。
            //
            // id 绑定 openCount：设置窗口的 hosting view 是复用的（MenuBarController.openSettings），
            // 无 id 的 .task 只在首次插入时跑一次，第二次打开就读不到最新的 Secret。
            // 每次打开窗口 openCount 递增，这里随之重跑；首次插入时 openCount 为初值也会跑一次。
            syncFromSettings()
            await loadAliyunSecretFromKeychain()
        }
    }

    private func syncFromSettings() {
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
        Log.lifecycle.notice("设置页开始读取 AccessKey Secret")
        aliyunSecretState = .loading
        let before = aliyunAKSecretInput   // 挂起前快照，防止盖掉用户这期间的输入

        let started = DispatchTime.now()
        let result = await KeychainSecretStore.shared.lookupAsync(.aliyunAccessKeySecret)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000

        // 正常路径下输入框在 loading 期间是 disabled 的，这里是双保险
        let untouched = (aliyunAKSecretInput == before)

        switch result {
        case .found(let secret):
            if untouched { aliyunAKSecretInput = secret }
            aliyunSecretState = .ready
            Log.lifecycle.notice("设置页读取 AccessKey Secret：found（\(ms, format: .fixed(precision: 0))ms）")
        case .absent:
            if untouched { aliyunAKSecretInput = "" }
            aliyunSecretState = .ready
            Log.lifecycle.notice("设置页读取 AccessKey Secret：absent —— 钥匙串里确实没有（\(ms, format: .fixed(precision: 0))ms）")
        case .unavailable:
            aliyunSecretState = .unavailable
            Log.lifecycle.error("设置页读取 AccessKey Secret：unavailable（\(ms, format: .fixed(precision: 0))ms），已进入保护模式：不清空、不删除")
        }
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
                    // 做成整块横幅而不是一行文字：这段文案很长，若和按钮挤在同一个
                    // HStack 里，窗口宽度不够时会被压缩到几乎看不见 —— 而这条提示
                    // 恰恰是用户判断「输入框为空是否等于没有凭证」的唯一依据。
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                            Text(I18n(.warnAliyunSecretUnreadable))
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button(I18n(.btnRetryReadKeychain)) {
                            Task { await loadAliyunSecretFromKeychain() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.orange.opacity(0.45), lineWidth: 1)
                    )
                    .cornerRadius(6)
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
}
