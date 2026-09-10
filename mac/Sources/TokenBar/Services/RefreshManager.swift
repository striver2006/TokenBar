import Foundation
import Combine
import SwiftUI
import UserNotifications

/// 一轮刷新的触发来源，只用于日志定位（"到底是定时器没响，还是每轮都失败"）
public enum RefreshTrigger: String {
    case initial   // App 启动首刷
    case timer     // 周期定时器
    case manual    // 菜单项 / 弹窗刷新按钮
    case wake      // 系统或显示器唤醒补刷
    case settings  // 设置变更后立即刷新
}

/// 一轮刷新的结果，用于让"刷新了但全失败"这个状态对用户可见
public enum RefreshRoundOutcome: Equatable {
    case none                    // 还没跑过
    case success                 // 至少一个厂商拿到了新数据
    case allFailed(count: Int)   // 参与的厂商全部没拿到新数据
}

@MainActor
public final class RefreshManager: ObservableObject {
    public static let shared = RefreshManager()

    @Published public var settings: AppSettings
    @Published public var quotas: [ProviderType: ProviderQuota] = [:]
    @Published public var customQuotas: [UUID: CustomProviderQuota] = [:]
    @Published public var isRefreshing: Bool = false
    /// 最近一次"真的拿到了新数据"的时刻。全失败的轮次不会推进它。
    @Published public var lastRefreshDate: Date? = nil
    /// 最近一次"发起过刷新"的时刻，无论成败都推进。
    /// 有了它，界面才能区分"没在刷新"和"刷新了但全失败"。
    @Published public var lastAttemptDate: Date? = nil
    /// 最近一轮的结果
    @Published public var lastRoundOutcome: RefreshRoundOutcome = .none
    /// 凭证写入 / 删除钥匙串失败时的提示（设置页横幅）；nil 表示一切正常
    @Published public var secretStoreError: String? = nil

    /// 上次与钥匙串对齐后的凭证快照：保存时据此算出哪些条目要写、哪些要删
    private var persistedSecrets: [SecretKey: String] = [:]
    /// 启动加载时读不到的键：保存时对它们的「空输入」只保留不删除（三态语义，见 SecretStore）
    private var unreadableSecretKeys: Set<SecretKey> = []
    /// 启动时的钥匙串加载是否已完成；未完成前 saveSettings 不会碰钥匙串
    private var secretsLoaded = false

    private var refreshTimer: Timer?
    /// 当前定时器生效的间隔，用于判断设置变更是否真的需要重建定时器
    private var activeIntervalMinutes: Int?
    private let userDefaultsKey = "TokenBar_AppSettings"

    /// 本轮刷新的开始时刻。闸门卡死时用它判断是否该强制抢占。
    private var refreshStartedAt: Date?
    /// 轮次代数。被抢占的旧轮次结束时不能把新轮次的闸门误清掉。
    private var refreshGeneration: UInt64 = 0
    /// 上一次定时器 fire 的时刻，用于在日志里暴露真实间隔（App Nap / 睡眠会拉长它）
    private var lastTimerFire: Date?

    /// 闸门抢占阈值。有了单厂商超时隔离后 refreshAll 最多约 35s 返回，
    /// 这里 90s 纯粹是兜底：防住 Process.waitUntilExit 这类不响应 Task 取消的路径。
    private static let gateStaleThreshold: TimeInterval = 90

    // 余额窗口的展示辅助状态（较上次差值 + 低余额提醒状态机），进程内有效
    private var lastBalanceValues: [String: Double] = [:]
    private var balanceAlertedKeys: Set<String> = []

    public init() {
        if let savedData = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: savedData) {
            self.settings = decoded
        } else {
            self.settings = AppSettings.defaultSettings
        }
        LocalizationManager.shared.setLanguage(self.settings.appLanguage)

        // Initialize empty quotas
        for type in ProviderType.allCases {
            quotas[type] = ProviderQuota(provider: type, isEnabled: true)
        }

        // Initialize custom provider quotas
        for config in settings.customProviders {
            customQuotas[config.id] = CustomProviderQuota(
                configId: config.id,
                name: config.name,
                apiProtocol: config.apiProtocol,
                isEnabled: config.isEnabled
            )
        }

        // 定时器必须先于首刷创建。以前是 `await setupInitialData()` 之后才建，
        // 首刷一旦挂起（某个厂商的请求没有超时），定时器根本不存在，
        // 整个进程生命周期里都不会有自动刷新。
        startPeriodicTimer()

        Task { @MainActor [weak self] in
            // 凭证必须先于首刷从钥匙串读进内存，否则首轮全部厂商都会被判成未配置
            await self?.loadSecretsFromKeychain()
            await self?.setupInitialData()
        }
    }

    // MARK: - 凭证与钥匙串

    /// 启动时把全部凭证从钥匙串读进 `settings`，并把 plist 里的旧明文一次性迁进钥匙串。
    ///
    /// 三态处理（`AppSecrets.loadAction`）：
    /// - found：以钥匙串为准；
    /// - absent + 旧明文非空：迁移（写入钥匙串）；
    /// - unavailable：保留内存里的旧明文，什么都不写不删，`secretsInKeychain` 保持 false，
    ///   这样接下来任何一次 saveSettings 仍会把明文写回 plist —— 在安全存储可用之前
    ///   绝不丢用户凭证。全部键都可信且迁移都成功后才置 true 并重写 plist 把明文清掉。
    public func loadSecretsFromKeychain() async {
        let keys = AppSecrets.keys(for: settings)
        let lookups = await KeychainSecretStore.shared.lookupAll(keys)
        let legacy = AppSecrets.extract(from: settings)

        var loaded: [SecretKey: String] = [:]
        var toMigrate: [SecretKey: String] = [:]
        var unreadable: Set<SecretKey> = []
        for key in keys {
            switch AppSecrets.loadAction(lookup: lookups[key] ?? .unavailable, legacy: legacy[key] ?? "") {
            case .useStored(let v): loaded[key] = v
            case .migrate(let v): toMigrate[key] = v
            case .none: break
            case .keepLegacy: unreadable.insert(key)
            }
        }

        var migrationFailed = false
        for (key, value) in toMigrate {
            if await KeychainSecretStore.shared.setAsync(value, for: key) {
                loaded[key] = value
            } else {
                migrationFailed = true
                Log.lifecycle.error("凭证迁移写入钥匙串失败 account=\(key.account, privacy: .public)")
            }
        }

        AppSecrets.apply(loaded, to: &settings)
        persistedSecrets = loaded
        unreadableSecretKeys = unreadable
        secretsLoaded = true

        let allTrustworthy = unreadable.isEmpty && !migrationFailed
        if allTrustworthy != settings.secretsInKeychain || !toMigrate.isEmpty {
            settings.secretsInKeychain = allTrustworthy
            // 迁移成功后重写一次 plist，把明文清掉；失败则保持明文落盘，下次启动重试
            persistSettingsToDefaults()
        }
        Log.lifecycle.notice("凭证加载完成：loaded=\(loaded.count) migrated=\(toMigrate.count) unreadable=\(unreadable.count) secretsInKeychain=\(allTrustworthy)")
        if !allTrustworthy {
            secretStoreError = I18n(.warnSecretStoreUnavailable)
        }
    }

    /// 把内存里变更过的凭证同步到钥匙串。失败时不降级明文：保留内存值、置 `secretStoreError`
    /// 提示用户，并把 `secretsInKeychain` 打回 false 让 plist 继续兜底，避免丢凭证。
    private func syncSecretsToKeychain() {
        guard secretsLoaded else { return }
        let current = AppSecrets.extract(from: settings)
        let keys = Set(current.keys).union(persistedSecrets.keys)

        var writes: [SecretKey: String] = [:]
        var deletes: Set<SecretKey> = []
        for key in keys {
            switch AppSecrets.saveAction(
                current: current[key],
                previous: persistedSecrets[key],
                storeReadable: !unreadableSecretKeys.contains(key)
            ) {
            case .write(let v): writes[key] = v
            case .delete: deletes.insert(key)
            case .keepExisting, .unchanged: break
            }
        }
        guard !writes.isEmpty || !deletes.isEmpty else { return }

        Task { @MainActor in
            var failed = false
            for (key, value) in writes {
                if await KeychainSecretStore.shared.setAsync(value, for: key) {
                    persistedSecrets[key] = value
                    unreadableSecretKeys.remove(key)
                } else {
                    failed = true
                    Log.lifecycle.error("凭证写入钥匙串失败 account=\(key.account, privacy: .public)")
                }
            }
            for key in deletes {
                if await KeychainSecretStore.shared.deleteAsync(key) {
                    persistedSecrets.removeValue(forKey: key)
                } else {
                    failed = true
                    Log.lifecycle.error("凭证从钥匙串删除失败 account=\(key.account, privacy: .public)")
                }
            }
            if failed {
                secretStoreError = I18n(.warnSecretStoreWriteFailed)
                if settings.secretsInKeychain {
                    settings.secretsInKeychain = false
                    persistSettingsToDefaults()
                }
            } else if secretStoreError != nil, unreadableSecretKeys.isEmpty {
                secretStoreError = nil
                if !settings.secretsInKeychain {
                    settings.secretsInKeychain = true
                    persistSettingsToDefaults()
                }
            }
        }
    }

    private func persistSettingsToDefaults() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    public func saveSettings() {
        LocalizationManager.shared.setLanguage(settings.appLanguage)
        persistSettingsToDefaults()
        syncSecretsToKeychain()
        // 只有间隔真的变了才重建定时器：设置页里切厂商开关、改语言等都会走到这里，
        // 每次都 invalidate 会把计时相位打回零，间隔较长时可能永远刷不到。
        if activeIntervalMinutes != settings.refreshIntervalMinutes {
            startPeriodicTimer()
        }
    }

    public func startPeriodicTimer() {
        refreshTimer?.invalidate()
        let intervalSec = max(60, Double(settings.refreshIntervalMinutes * 60))
        // 注册到 .common 而非默认的 .default —— 否则右键菜单打开、状态项拖拽等
        // 进入 .eventTracking 的交互期间定时器会被暂停。
        let timer = Timer(timeInterval: intervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 距上次 fire 的真实间隔是判断"定时器是否被 App Nap / 睡眠拉长"的关键指标
                if let previous = self.lastTimerFire {
                    let gap = Date().timeIntervalSince(previous)
                    Log.timer.notice("timer fired，距上次 \(gap, format: .fixed(precision: 1))s")
                } else {
                    Log.timer.notice("timer fired（本定时器首次触发）")
                }
                self.lastTimerFire = Date()
                await self.refreshAll(trigger: .timer)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        activeIntervalMinutes = settings.refreshIntervalMinutes
        lastTimerFire = nil
        Log.timer.notice("定时器已创建：interval=\(Int(intervalSec), privacy: .public)s")
    }

    /// 数据过期时才刷新，用于系统唤醒这类"可能已经错过若干个周期"的补刷场景
    public func refreshIfStale(olderThan seconds: TimeInterval) async {
        // 唤醒时 screensDidWake 与 didWake 两条通知会先后到达，60 秒内只认一次。
        if let attempt = lastAttemptDate, Date().timeIntervalSince(attempt) < 60 {
            Log.lifecycle.debug("跳过唤醒补刷：刚刚已尝试过")
            return
        }
        // 数据还新鲜就不打扰。注意判据是 lastRefreshDate（最近一次真的拿到数据），
        // 全失败轮次不会推进它，所以补刷不会被"刷过但没成功"骗过去。
        if let last = lastRefreshDate, Date().timeIntervalSince(last) < seconds { return }
        let age = lastRefreshDate.map { Date().timeIntervalSince($0) } ?? -1
        Log.lifecycle.notice("唤醒补刷，dataAge=\(age, format: .fixed(precision: 0))s")
        await refreshAll(trigger: .wake)
    }

    private func setupInitialData() async {
        // Auto-detect local Claude if available
        if let localClaude = await ClaudeService.shared.readLocalClaudeJson() {
            var quota = quotas[.claudeCode] ?? ProviderQuota(provider: .claudeCode)
            quota.isAuthorized = true
            quota.accountInfo = localClaude.account
            quota.fiveHourWindow = localClaude.fiveHour
            quota.weeklyWindow = localClaude.weekly
            quota.lastUpdated = Date()
            quotas[.claudeCode] = quota
        }

        // Auto-detect local Gemini if available
        let localGemini = await GeminiService.shared.readLocalGeminiConfig()
        if localGemini.token != nil || localGemini.account != nil {
            var quota = quotas[.gemini] ?? ProviderQuota(provider: .gemini)
            quota.isAuthorized = true
            quota.accountInfo = localGemini.account
            quotas[.gemini] = quota
        }

        // Trigger first background refresh
        await refreshAll(trigger: .initial)
    }

    public func refreshAll(trigger: RefreshTrigger = .manual) async {
        if isRefreshing {
            let elapsed = refreshStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            if elapsed > Self.gateStaleThreshold {
                // 上一轮卡死了。以前这里只是 return，于是每一次 tick 和每一次手动
                // 刷新都被静默丢弃，界面上完全没有痕迹 —— 这正是"定时刷新彻底停摆"
                // 的成因。现在抢占，并留一条会落盘的 error 供事后回溯。
                Log.refresh.error("闸门被卡住 \(elapsed, format: .fixed(precision: 1))s，强制抢占；trigger=\(trigger.rawValue, privacy: .public)")
            } else {
                Log.refresh.debug("跳过本次刷新：上一轮进行中 \(elapsed, format: .fixed(precision: 1))s；trigger=\(trigger.rawValue, privacy: .public)")
                return
            }
        }

        refreshGeneration &+= 1
        let myGeneration = refreshGeneration
        isRefreshing = true
        refreshStartedAt = Date()
        lastAttemptDate = Date()
        let roundStart = DispatchTime.now()
        defer {
            // 只有仍然是"当前那一轮"才收闸门；被抢占的旧轮次结束时什么都不做，
            // 否则会把接替它的新轮次的闸门提前打开。
            if myGeneration == refreshGeneration {
                isRefreshing = false
                refreshStartedAt = nil
            }
        }

        let enabledNames = enabledProviderNames()
        Log.refresh.notice("round begin trigger=\(trigger.rawValue, privacy: .public) providers=\(enabledNames, privacy: .public)")

        // 各刷新方法只在成功拿到数据时才推进自己的 lastUpdated，据此判断本轮是否有实际收获
        let updatedBefore = latestQuotaUpdate()

        await withTaskGroup(of: Void.self) { group in
            if settings.openAIEnabled {
                group.addTask { @MainActor in
                    await self.runProvider("openai", key: .builtin(.openAI)) { await self.refreshOpenAI() }
                }
            }
            if settings.claudeEnabled {
                group.addTask { @MainActor in
                    await self.runProvider("claude", key: .builtin(.claudeCode)) { await self.refreshClaude() }
                }
            }
            if settings.geminiEnabled {
                group.addTask { @MainActor in
                    await self.runProvider("gemini", key: .builtin(.gemini)) { await self.refreshGemini() }
                }
            }
            if settings.deepseekEnabled {
                group.addTask { @MainActor in
                    await self.runProvider("deepseek", key: .builtin(.deepseek)) { await self.refreshDeepSeek() }
                }
            }
            if settings.volcengineEnabled {
                group.addTask { @MainActor in
                    await self.runProvider("volcengine", key: .builtin(.volcengine)) { await self.refreshVolcengine() }
                }
            }
            if settings.kimiEnabled {
                group.addTask { @MainActor in
                    await self.runProvider("kimi", key: .builtin(.kimi)) { await self.refreshKimi() }
                }
            }
            if settings.openRouterEnabled {
                group.addTask { @MainActor in
                    await self.runProvider("openrouter", key: .builtin(.openRouter)) { await self.refreshOpenRouter() }
                }
            }
            if settings.glmEnabled {
                group.addTask { @MainActor in
                    await self.runProvider("glm", key: .builtin(.glm)) { await self.refreshGLM() }
                }
            }
            if settings.aliyunEnabled {
                group.addTask { @MainActor in
                    await self.runProvider("aliyun", key: .builtin(.aliyunBailian)) { await self.refreshAliyun() }
                }
            }
            for config in self.settings.customProviders where config.isEnabled {
                group.addTask { @MainActor in
                    await self.runProvider("custom", key: .custom(config.id)) {
                        await self.refreshCustomProvider(config: config)
                    }
                }
            }
        }

        // 全部厂商都失败时不推进时间戳，避免弹窗上显示"刚刚更新"却是一屏旧数据
        let after = latestQuotaUpdate()
        let advanced = after != nil && after != updatedBefore
        if advanced, let after {
            lastRefreshDate = after
        }

        lastRoundOutcome = advanced ? .success : .allFailed(count: max(1, enabledNames.split(separator: ",").count))

        let ms = Double(DispatchTime.now().uptimeNanoseconds - roundStart.uptimeNanoseconds) / 1_000_000
        Log.refresh.notice("round end in \(ms, format: .fixed(precision: 0))ms, advanced=\(advanced, privacy: .public)")

        // 定时器自愈：Timer 被 invalidate 或从未建立时，这里是最后一道防线。
        if refreshTimer?.isValid != true {
            Log.timer.error("定时器已失效，重建")
            startPeriodicTimer()
        }
    }

    /// 按轮次代数门控的写回：被闸门抢占的旧轮次在新轮次开始后仍会跑完，它的结果
    /// （常常是失败态或过期数据）不能再覆盖新轮次刚写入的状态。`gen` 由各 refresh
    /// 方法在入口处捕获；不在任何轮次内的独立刷新（设置页保存后触发）也走这里——
    /// 若期间恰好开始了新一轮，丢弃它的写入是安全的，新一轮会重新刷到该厂商。
    private func commit(_ quota: ProviderQuota, for type: ProviderType, gen: UInt64) {
        guard gen == refreshGeneration else {
            Log.refresh.debug("丢弃过期轮次结果 provider=\(type.rawValue, privacy: .public) gen=\(gen) current=\(self.refreshGeneration)")
            return
        }
        quotas[type] = quota
    }

    private func commitCustom(_ quota: CustomProviderQuota, for id: UUID, gen: UInt64) {
        guard gen == refreshGeneration else {
            Log.refresh.debug("丢弃过期轮次结果 provider=custom gen=\(gen) current=\(self.refreshGeneration)")
            return
        }
        customQuotas[id] = quota
    }

    /// 定位一个厂商的额度条目，供超时收尾时把卡片从"加载中"拨回错误态
    private enum ProviderKey {
        case builtin(ProviderType)
        case custom(UUID)
    }

    /// 各厂商单轮的时间预算（秒）。
    /// 百炼最宽：AK 签发 + 网关查询 + NotLogined 重试一次 + 账户余额，是链路最长的。
    /// Gemini 次之：token 刷新循环最多 20s + cloudcode 两个 endpoint。
    private static func budget(for name: String) -> TimeInterval {
        switch name {
        case "aliyun": return 35
        case "gemini": return 30
        default:       return 25
        }
    }

    /// 给单个厂商的刷新套一层独立超时。
    ///
    /// 这是"一个厂商挂起就拖垮整轮刷新"的解药：`withTaskGroup` 会等待全部子任务，
    /// 以前任何一个厂商卡住都会让 refreshAll 永不返回，闸门被占死，之后每一次
    /// 定时 tick 和手动刷新都被静默丢弃。
    private func runProvider(
        _ name: String,
        key: ProviderKey? = nil,
        _ body: @escaping @Sendable @MainActor () async -> Void
    ) async {
        let start = DispatchTime.now()
        let finished = await withTimeout(seconds: Self.budget(for: name), label: name, operation: body)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

        if finished {
            Log.provider.info("provider=\(name, privacy: .public) done in \(ms, format: .fixed(precision: 0))ms")
            return
        }

        Log.provider.error("provider=\(name, privacy: .public) TIMEOUT after \(ms, format: .fixed(precision: 0))ms，已放弃本轮")
        // 被放弃的厂商，其 isLoading 会停在 true（卡片一直转圈），这里补一次收尾。
        finishTimedOutProvider(key: key, name: name)
    }

    private func finishTimedOutProvider(key: ProviderKey?, name: String) {
        let message = I18n(.errRefreshTimeout)
        switch key {
        case .builtin(let type):
            if var quota = quotas[type] {
                quota.isLoading = false
                quota.errorMessage = message
                quotas[type] = quota
            }
        case .custom(let id):
            if var quota = customQuotas[id] {
                quota.isLoading = false
                quota.errorMessage = message
                customQuotas[id] = quota
            }
        case .none:
            break
        }
    }

    /// 本轮参与刷新的厂商名，只用于日志（都是固定标识，不含任何凭证）
    private func enabledProviderNames() -> String {
        var names: [String] = []
        if settings.openAIEnabled { names.append("openai") }
        if settings.claudeEnabled { names.append("claude") }
        if settings.geminiEnabled { names.append("gemini") }
        if settings.deepseekEnabled { names.append("deepseek") }
        if settings.volcengineEnabled { names.append("volcengine") }
        if settings.kimiEnabled { names.append("kimi") }
        if settings.openRouterEnabled { names.append("openrouter") }
        if settings.glmEnabled { names.append("glm") }
        if settings.aliyunEnabled { names.append("aliyun") }
        let customCount = settings.customProviders.filter(\.isEnabled).count
        if customCount > 0 { names.append("custom×\(customCount)") }
        return names.joined(separator: ",")
    }

    /// 所有厂商中最近一次成功更新的时间
    private func latestQuotaUpdate() -> Date? {
        let providerDates = quotas.values.compactMap(\.lastUpdated)
        let customDates = customQuotas.values.compactMap(\.lastUpdated)
        return (providerDates + customDates).max()
    }

    public func refreshClaude() async {
        let gen = refreshGeneration
        var quota = quotas[.claudeCode] ?? ProviderQuota(provider: .claudeCode)
        quota.isLoading = true
        quota.errorMessage = nil
        commit(quota, for: .claudeCode, gen: gen)

        let hasClaudeToken = !settings.claudeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let localClaude = await ClaudeService.shared.readLocalClaudeJson()
        let hasAnthropicKey = !settings.anthropicApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var foundAuth = false

        // 1. If Claude Code (OAuth token or local credentials) is present
        if hasClaudeToken {
            do {
                let res = try await ClaudeService.shared.fetchRemoteUsage(token: settings.claudeToken)
                quota.fiveHourWindow = res.fiveHour
                quota.weeklyWindow = res.weekly
                quota.isAuthorized = true
                if let acc = res.account { quota.accountInfo = acc }
                foundAuth = true
            } catch {
                if let local = localClaude {
                    quota.fiveHourWindow = local.fiveHour
                    quota.weeklyWindow = local.weekly
                    quota.isAuthorized = true
                    if let acc = local.account { quota.accountInfo = acc }
                    foundAuth = true
                } else {
                    quota.errorMessage = error.localizedDescription
                    Log.provider.error("provider=claude failed: \(error.localizedDescription)")
                }
            }
        } else if let local = localClaude {
            quota.fiveHourWindow = local.fiveHour
            quota.weeklyWindow = local.weekly
            quota.isAuthorized = true
            if let acc = local.account { quota.accountInfo = acc }
            foundAuth = true
        }

        // 2. If Anthropic API Key is present
        if hasAnthropicKey {
            do {
                let res = try await ClaudeService.shared.fetchAnthropicQuota(
                    apiKey: settings.anthropicApiKey,
                    endpoint: settings.anthropicEndpoint
                )
                if quota.fiveHourWindow == nil {
                    quota.fiveHourWindow = res.primary
                }
                if quota.weeklyWindow == nil {
                    quota.weeklyWindow = res.secondary
                }
                if let acc = res.account {
                    if let prev = quota.accountInfo, !prev.isEmpty {
                        quota.accountInfo = "\(prev) • \(acc)"
                    } else {
                        quota.accountInfo = acc
                    }
                }
                quota.isAuthorized = true
                foundAuth = true
            } catch {
                if !foundAuth {
                    quota.errorMessage = error.localizedDescription
                    Log.provider.error("provider=claude failed: \(error.localizedDescription)")
                }
            }
        }

        if !foundAuth {
            quota.isAuthorized = false
            if quota.errorMessage == nil {
                quota.errorMessage = I18n(.errMissingAnthropicAuth)
            }
        }

        // 与其他厂商对齐：只有真的拿到数据才算一次成功更新
        if foundAuth {
            quota.lastUpdated = Date()
        }
        quota.isLoading = false
        commit(quota, for: .claudeCode, gen: gen)
    }

    public func refreshGemini() async {
        let gen = refreshGeneration
        var quota = quotas[.gemini] ?? ProviderQuota(provider: .gemini)
        quota.isLoading = true
        quota.errorMessage = nil
        commit(quota, for: .gemini, gen: gen)

        let hasApiKey = !settings.geminiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // 1. Prioritize Google AI Studio API Key if configured
        if hasApiKey {
            do {
                let res = try await GeminiService.shared.fetchQuotaWithApiKey(
                    apiKey: settings.geminiApiKey,
                    endpoint: settings.geminiEndpoint
                )
                quota.fiveHourWindow = res.fiveHour
                quota.weeklyWindow = res.weekly
                quota.isAuthorized = true
                quota.accountInfo = res.account
                quota.lastUpdated = Date()
                quota.isLoading = false
                commit(quota, for: .gemini, gen: gen)
                return
            } catch {
                // If API Key failed, only fall back to OAuth/local if available
                let local = await GeminiService.shared.readLocalGeminiConfig()
                let hasOAuth = !settings.geminiToken.isEmpty || local.account != nil || local.token != nil || local.refreshToken != nil
                if !hasOAuth {
                    quota.isAuthorized = false
                    quota.errorMessage = error.localizedDescription
                    Log.provider.error("provider=gemini failed: \(error.localizedDescription)")
                    quota.isLoading = false
                    commit(quota, for: .gemini, gen: gen)
                    return
                }
            }
        }

        // 2. OAuth Web Login / Local Credentials Fallback
        do {
            let res = try await GeminiService.shared.fetchQuota(token: settings.geminiToken)
            quota.fiveHourWindow = res.fiveHour
            quota.weeklyWindow = res.weekly
            quota.isAuthorized = true
            if let acc = res.account { quota.accountInfo = acc }
            quota.lastUpdated = Date()
        } catch {
            quota.isAuthorized = false
            quota.errorMessage = error.localizedDescription
            Log.provider.error("provider=gemini failed: \(error.localizedDescription)")
        }

        quota.isLoading = false
        commit(quota, for: .gemini, gen: gen)
    }

    public func refreshGLM() async {
        let gen = refreshGeneration
        var quota = quotas[.glm] ?? ProviderQuota(provider: .glm)
        quota.isLoading = true
        quota.errorMessage = nil
        commit(quota, for: .glm, gen: gen)

        guard !settings.glmApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quota.isAuthorized = false
            quota.errorMessage = I18n(.errMissingGLMKey)
            quota.isLoading = false
            commit(quota, for: .glm, gen: gen)
            return
        }

        do {
            let res = try await GLMService.shared.fetchQuota(
                apiKey: settings.glmApiKey,
                endpoint: settings.glmEndpoint
            )
            quota.fiveHourWindow = res.fiveHour
            quota.weeklyWindow = res.weekly
            quota.accountInfo = res.account
            quota.isAuthorized = true
            quota.lastUpdated = Date()
        } catch {
            quota.errorMessage = error.localizedDescription
            Log.provider.error("provider=glm failed: \(error.localizedDescription)")
        }

        quota.isLoading = false
        commit(quota, for: .glm, gen: gen)
    }

    public func refreshAliyun() async {
        let gen = refreshGeneration
        var quota = quotas[.aliyunBailian] ?? ProviderQuota(provider: .aliyunBailian)
        quota.isLoading = true
        quota.errorMessage = nil
        commit(quota, for: .aliyunBailian, gen: gen)

        do {
            // 钥匙串必须在后台线程读。同步的 SecItemCopyMatching 一旦在 MainActor 上
            // 卡住（授权框、钥匙串锁定、securityd 繁忙），主线程冻结会让所有 provider
            // 的刷新任务一起停摆，超时哨兵也恢复不了 —— 就是"定时刷新整体不动"的成因。
            let prefetched = await KeychainSecretStore.shared.prefetch(
                [.aliyunAccessKeySecret, .aliyunConsoleAccessToken]
            )
            // ~/.bailian/config.json 同样在后台读；传空配置而非 nil，避免 resolveCredentials
            // 在主线程上再同步读一次盘
            let cliConfig = settings.aliyunReuseCLIConfig
                ? (await BailianCLIConfig.loadFromDiskAsync() ?? BailianCLIConfig())
                : BailianCLIConfig()
            let credentials = AliyunBailianService.resolveCredentials(
                settings: settings,
                secretStore: prefetched,
                cliConfig: cliConfig
            )
            let res = try await AliyunBailianService.shared.fetchQuota(credentials: credentials)

            // 新签发的控制台令牌落进安全存储，下次刷新直接复用，避免重复签发。
            // 写入同样不能阻塞主线程，交给后台队列。
            if let refreshed = res.refreshedToken, !refreshed.isEmpty {
                KeychainSecretStore.shared.setInBackground(refreshed, for: .aliyunConsoleAccessToken)
            }

            quota.fiveHourWindow = res.fiveHour
            quota.weeklyWindow = res.weekly
            quota.accountInfo = res.account
            quota.isAuthorized = true
            // 网关成功但没返回窗口数据时，用 note 说明「可能不限量」，
            // 而不是让卡片停在「同步中」——但仍算已授权，不是失败态
            quota.errorMessage = res.note
            quota.lastUpdated = Date()

            // 账户现金余额与额度相互独立：需要 AK/SK 且额外的 bss:DescribeAcccount 权限，
            // 查不到时静默跳过，不能连累已经拿到的额度数据
            if credentials.hasAccessKey,
               let balance = try? await AliyunBailianService.shared.fetchAccountBalance(credentials) {
                let window = TokenWindow.balance(
                    title: I18n(.menuBarMetricBalance),
                    amount: balance.amount,
                    currency: balance.currency,
                    warningThreshold: settings.aliyunBalanceAlertThreshold,
                    criticalThreshold: settings.aliyunBalanceAlertThreshold / 2
                )
                quota.balanceWindow = await processBalance(
                    providerKey: "aliyun",
                    displayName: ProviderType.aliyunBailian.displayName,
                    window: window,
                    threshold: settings.aliyunBalanceAlertThreshold
                )
            } else {
                quota.balanceWindow = nil
            }
        } catch {
            quota.isAuthorized = false
            quota.errorMessage = error.localizedDescription
            Log.provider.error("provider=aliyun failed: \(error.localizedDescription)")
        }

        quota.isLoading = false
        commit(quota, for: .aliyunBailian, gen: gen)
    }

    public func importClaudeFromLocal() async -> Bool {
        if let local = await ClaudeService.shared.readLocalClaudeJson() {
            var quota = quotas[.claudeCode] ?? ProviderQuota(provider: .claudeCode)
            quota.isAuthorized = true
            quota.accountInfo = local.account
            quota.fiveHourWindow = local.fiveHour
            quota.weeklyWindow = local.weekly
            quota.lastUpdated = Date()
            quotas[.claudeCode] = quota
            return true
        }
        return false
    }

    /// async 是因为它要读钥匙串（可能弹授权框）—— 调用方 SettingsView 用 Task 包起来，
    /// 别让按钮点击把主线程占住。
    public func importGeminiFromLocal() async -> Bool {
        let local = await GeminiService.shared.readLocalGeminiConfig()
        if let token = local.token {
            settings.geminiToken = token
            saveSettings()
            Task { await refreshGemini() }
            return true
        }
        return false
    }

    public func refreshOpenAI() async {
        let gen = refreshGeneration
        var quota = quotas[.openAI] ?? ProviderQuota(provider: .openAI)
        quota.isLoading = true
        quota.errorMessage = nil
        commit(quota, for: .openAI, gen: gen)

        guard !settings.openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quota.isAuthorized = false
            quota.errorMessage = I18n(.errMissingOpenAIKey)
            quota.isLoading = false
            commit(quota, for: .openAI, gen: gen)
            return
        }

        do {
            let res = try await OpenAIService.shared.fetchQuota(
                apiKey: settings.openAIApiKey,
                endpoint: settings.openAIEndpoint,
                organizationId: settings.openAIOrgId
            )
            quota.fiveHourWindow = res.primary
            quota.weeklyWindow = res.secondary
            quota.accountInfo = res.account
            quota.isAuthorized = true
            quota.lastUpdated = Date()
        } catch {
            quota.isAuthorized = false
            quota.errorMessage = error.localizedDescription
            Log.provider.error("provider=openai failed: \(error.localizedDescription)")
        }

        quota.isLoading = false
        commit(quota, for: .openAI, gen: gen)
    }

    public func refreshDeepSeek() async {
        let gen = refreshGeneration
        var quota = quotas[.deepseek] ?? ProviderQuota(provider: .deepseek)
        quota.isLoading = true
        quota.errorMessage = nil
        commit(quota, for: .deepseek, gen: gen)

        guard !settings.deepseekApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quota.isAuthorized = false
            quota.errorMessage = I18n(.errMissingDeepSeekKey)
            quota.isLoading = false
            commit(quota, for: .deepseek, gen: gen)
            return
        }

        do {
            let res = try await DeepSeekService.shared.fetchQuota(
                apiKey: settings.deepseekApiKey,
                endpoint: settings.deepseekEndpoint,
                model: settings.deepseekModel,
                balanceAlertThreshold: settings.deepseekBalanceAlertThreshold
            )
            quota.fiveHourWindow = res.fiveHour
            quota.weeklyWindow = res.weekly
            quota.accountInfo = res.account
            quota.isAuthorized = true
            quota.lastUpdated = Date()

            quota.weeklyWindow = await processBalance(
                providerKey: "deepseek",
                displayName: ProviderType.deepseek.displayName,
                window: quota.weeklyWindow,
                threshold: settings.deepseekBalanceAlertThreshold
            )
        } catch {
            quota.isAuthorized = false
            quota.errorMessage = error.localizedDescription
            Log.provider.error("provider=deepseek failed: \(error.localizedDescription)")
        }

        quota.isLoading = false
        commit(quota, for: .deepseek, gen: gen)
    }

    public func refreshOpenRouter() async {
        let gen = refreshGeneration
        var quota = quotas[.openRouter] ?? ProviderQuota(provider: .openRouter)
        quota.isLoading = true
        quota.errorMessage = nil
        commit(quota, for: .openRouter, gen: gen)

        guard !settings.openRouterApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quota.isAuthorized = false
            quota.errorMessage = I18n(.errMissingOpenRouterKey)
            quota.isLoading = false
            commit(quota, for: .openRouter, gen: gen)
            return
        }

        do {
            let res = try await OpenRouterService.shared.fetchQuota(
                apiKey: settings.openRouterApiKey,
                endpoint: settings.openRouterEndpoint,
                balanceAlertThreshold: settings.openRouterBalanceAlertThreshold
            )
            quota.fiveHourWindow = res.primary
            quota.weeklyWindow = res.secondary
            quota.accountInfo = res.account
            quota.isAuthorized = true
            quota.lastUpdated = Date()

            quota.fiveHourWindow = await processBalance(
                providerKey: "openrouter",
                displayName: ProviderType.openRouter.displayName,
                window: quota.fiveHourWindow,
                threshold: settings.openRouterBalanceAlertThreshold
            )
        } catch {
            quota.isAuthorized = false
            quota.errorMessage = error.localizedDescription
            Log.provider.error("provider=openrouter failed: \(error.localizedDescription)")
        }

        quota.isLoading = false
        commit(quota, for: .openRouter, gen: gen)
    }

    public func refreshVolcengine() async {
        let gen = refreshGeneration
        var quota = quotas[.volcengine] ?? ProviderQuota(provider: .volcengine)
        quota.isLoading = true
        quota.errorMessage = nil
        commit(quota, for: .volcengine, gen: gen)

        guard !settings.volcengineApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quota.isAuthorized = false
            quota.errorMessage = I18n(.errMissingVolcengineKey)
            quota.isLoading = false
            commit(quota, for: .volcengine, gen: gen)
            return
        }

        do {
            let res = try await VolcengineService.shared.fetchQuota(
                apiKey: settings.volcengineApiKey,
                endpoint: settings.volcengineEndpoint,
                model: settings.volcengineModel
            )
            quota.fiveHourWindow = res.fiveHour
            quota.weeklyWindow = res.weekly
            quota.accountInfo = res.account
            quota.isAuthorized = true
            quota.lastUpdated = Date()
        } catch {
            quota.isAuthorized = false
            quota.errorMessage = error.localizedDescription
            Log.provider.error("provider=volcengine failed: \(error.localizedDescription)")
        }

        quota.isLoading = false
        commit(quota, for: .volcengine, gen: gen)
    }

    public func refreshKimi() async {
        let gen = refreshGeneration
        var quota = quotas[.kimi] ?? ProviderQuota(provider: .kimi)
        quota.isLoading = true
        quota.errorMessage = nil
        commit(quota, for: .kimi, gen: gen)

        guard !settings.kimiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quota.isAuthorized = false
            quota.errorMessage = I18n(.errMissingKimiKey)
            quota.isLoading = false
            commit(quota, for: .kimi, gen: gen)
            return
        }

        do {
            let res = try await KimiService.shared.fetchQuota(
                apiKey: settings.kimiApiKey,
                endpoint: settings.kimiEndpoint,
                model: settings.kimiModel,
                balanceAlertThreshold: settings.kimiBalanceAlertThreshold
            )
            quota.fiveHourWindow = res.fiveHour
            quota.weeklyWindow = res.weekly
            quota.accountInfo = res.account
            quota.isAuthorized = true
            quota.lastUpdated = Date()

            quota.weeklyWindow = await processBalance(
                providerKey: "kimi",
                displayName: ProviderType.kimi.displayName,
                window: quota.weeklyWindow,
                threshold: settings.kimiBalanceAlertThreshold
            )
        } catch {
            quota.isAuthorized = false
            quota.errorMessage = error.localizedDescription
            Log.provider.error("provider=kimi failed: \(error.localizedDescription)")
        }

        quota.isLoading = false
        commit(quota, for: .kimi, gen: gen)
    }

    public func refreshCustomProvider(config: CustomProviderConfig) async {
        let gen = refreshGeneration
        var q = customQuotas[config.id] ?? CustomProviderQuota(
            configId: config.id,
            name: config.name,
            apiProtocol: config.apiProtocol,
            isEnabled: config.isEnabled
        )
        q.isLoading = true
        q.errorMessage = nil
        commitCustom(q, for: config.id, gen: gen)

        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            q.isAuthorized = false
            q.errorMessage = I18n(.errMissingCustomKey)
            q.isLoading = false
            commitCustom(q, for: config.id, gen: gen)
            return
        }

        do {
            let res = try await CustomProviderService.shared.fetchQuota(config: config)
            q.primaryWindow = res.primary
            q.secondaryWindow = res.secondary
            q.accountInfo = res.account
            q.isAuthorized = true
            q.lastUpdated = Date()

            // 余额窗口可能在主槽位（纯余额厂商）或副槽位（MiMo 等订阅+余额双通道厂商）
            let balanceIsPrimary = q.primaryWindow?.isBalance == true
            let balanceWin: TokenWindow? = balanceIsPrimary
                ? q.primaryWindow
                : (q.secondaryWindow?.isBalance == true ? q.secondaryWindow : nil)

            if let updated = await processBalance(
                providerKey: "custom:\(config.id.uuidString)",
                displayName: config.name,
                window: balanceWin,
                threshold: config.balanceAlertThreshold ?? 10
            ) {
                if balanceIsPrimary {
                    q.primaryWindow = updated
                } else {
                    q.secondaryWindow = updated
                }
            }
        } catch {
            q.isAuthorized = false
            q.errorMessage = error.localizedDescription
            Log.provider.error("provider=custom failed: \(error.localizedDescription)")
        }

        q.isLoading = false
        commitCustom(q, for: config.id, gen: gen)
    }

    /// 余额窗口刷新成功后的统一处理：
    /// 1) 记录与上次刷新的差值；2) 写入本地历史并计算"预计可用天数"；
    /// 3) 低余额时发送一次系统通知，恢复到阈值 1.2 倍以上后重新武装。
    /// TokenWindow 是值类型，返回修改后的窗口由调用方回写到 quota。
    @discardableResult
    private func processBalance(providerKey: String, displayName: String, window: TokenWindow?, threshold: Double) async -> TokenWindow? {
        guard var window = window, window.isBalance, let amount = window.balanceAmount else {
            return window
        }

        if let prev = lastBalanceValues[providerKey] {
            window.lastDelta = amount - prev
        }
        lastBalanceValues[providerKey] = amount

        // 历史落盘与预测在 BalanceHistoryStore actor 上完成，不占主线程
        window.forecastDays = await BalanceHistoryStore.shared.recordAndForecast(providerKey: providerKey, value: amount)

        guard threshold > 0 else { return window }

        var shouldNotify = false
        if amount < threshold {
            if !balanceAlertedKeys.contains(providerKey) {
                balanceAlertedKeys.insert(providerKey)
                shouldNotify = true
            }
        } else if amount >= threshold * 1.2 {
            balanceAlertedKeys.remove(providerKey)
        }

        if shouldNotify {
            postLowBalanceNotification(displayName: displayName, balance: window.balanceFormatted)
        }

        return window
    }

    private func postLowBalanceNotification(displayName: String, balance: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = I18n(.lowBalanceTitle)
        content.body = String(format: I18n(.lowBalanceBody), displayName, balance)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "low-balance-\(displayName)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            center.add(request)
        }
    }

    public func addCustomProvider(_ config: CustomProviderConfig) {
        settings.customProviders.append(config)
        customQuotas[config.id] = CustomProviderQuota(
            configId: config.id,
            name: config.name,
            apiProtocol: config.apiProtocol,
            isEnabled: config.isEnabled
        )
        saveSettings()
        Task {
            await refreshCustomProvider(config: config)
        }
    }

    public func updateCustomProvider(_ config: CustomProviderConfig) {
        if let idx = settings.customProviders.firstIndex(where: { $0.id == config.id }) {
            settings.customProviders[idx] = config
            saveSettings()
            Task {
                await refreshCustomProvider(config: config)
            }
        }
    }

    public func removeCustomProvider(id: UUID) {
        settings.customProviders.removeAll(where: { $0.id == id })
        // 厂商没了，它的钥匙串条目也一起清掉（saveSettings 的差异同步会看到这两个键从有变无）
        customQuotas.removeValue(forKey: id)
        lastBalanceValues.removeValue(forKey: "custom:\(id.uuidString)")
        balanceAlertedKeys.remove("custom:\(id.uuidString)")
        Task { await BalanceHistoryStore.shared.clear(providerKey: "custom:\(id.uuidString)") }
        saveSettings()
    }
}
