import Foundation
import Combine
import SwiftUI

@MainActor
public final class RefreshManager: ObservableObject {
    public static let shared = RefreshManager()

    @Published public var settings: AppSettings
    @Published public var quotas: [ProviderType: ProviderQuota] = [:]
    @Published public var customQuotas: [UUID: CustomProviderQuota] = [:]
    @Published public var isRefreshing: Bool = false
    @Published public var lastRefreshDate: Date? = nil

    private var refreshTimer: Timer?
    private let userDefaultsKey = "TokenBar_AppSettings"

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

        // Try initial load
        Task {
            await setupInitialData()
            startPeriodicTimer()
        }
    }

    public func saveSettings() {
        LocalizationManager.shared.setLanguage(settings.appLanguage)
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
        startPeriodicTimer()
    }

    public func startPeriodicTimer() {
        refreshTimer?.invalidate()
        let intervalSec = max(60, Double(settings.refreshIntervalMinutes * 60))
        refreshTimer = Timer.scheduledTimer(withTimeInterval: intervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAll()
            }
        }
    }

    private func setupInitialData() async {
        // Auto-detect local Claude if available
        if let localClaude = ClaudeService.shared.readLocalClaudeJson() {
            var quota = quotas[.claudeCode] ?? ProviderQuota(provider: .claudeCode)
            quota.isAuthorized = true
            quota.accountInfo = localClaude.account
            quota.fiveHourWindow = localClaude.fiveHour
            quota.weeklyWindow = localClaude.weekly
            quota.lastUpdated = Date()
            quotas[.claudeCode] = quota
        }

        // Auto-detect local Gemini if available
        let localGemini = GeminiService.shared.readLocalGeminiConfig()
        if localGemini.token != nil || localGemini.account != nil {
            var quota = quotas[.gemini] ?? ProviderQuota(provider: .gemini)
            quota.isAuthorized = true
            quota.accountInfo = localGemini.account
            quotas[.gemini] = quota
        }

        // Trigger first background refresh
        await refreshAll()
    }

    public func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshDate = Date()
        }

        await withTaskGroup(of: Void.self) { group in
            if settings.openAIEnabled {
                group.addTask { @MainActor in
                    await self.refreshOpenAI()
                }
            }
            if settings.claudeEnabled {
                group.addTask { @MainActor in
                    await self.refreshClaude()
                }
            }
            if settings.geminiEnabled {
                group.addTask { @MainActor in
                    await self.refreshGemini()
                }
            }
            if settings.deepseekEnabled {
                group.addTask { @MainActor in
                    await self.refreshDeepSeek()
                }
            }
            if settings.volcengineEnabled {
                group.addTask { @MainActor in
                    await self.refreshVolcengine()
                }
            }
            if settings.kimiEnabled {
                group.addTask { @MainActor in
                    await self.refreshKimi()
                }
            }
            if settings.glmEnabled {
                group.addTask { @MainActor in
                    await self.refreshGLM()
                }
            }
            if settings.aliyunEnabled {
                group.addTask { @MainActor in
                    await self.refreshAliyun()
                }
            }
            for config in self.settings.customProviders where config.isEnabled {
                group.addTask { @MainActor in
                    await self.refreshCustomProvider(config: config)
                }
            }
        }
    }

    public func refreshClaude() async {
        var quota = quotas[.claudeCode] ?? ProviderQuota(provider: .claudeCode)
        quota.isLoading = true
        quota.errorMessage = nil
        quotas[.claudeCode] = quota

        let hasClaudeToken = !settings.claudeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let localClaude = ClaudeService.shared.readLocalClaudeJson()
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
                }
            }
        }

        if !foundAuth {
            quota.isAuthorized = false
            if quota.errorMessage == nil {
                quota.errorMessage = I18n(.errMissingAnthropicAuth)
            }
        }

        quota.lastUpdated = Date()
        quota.isLoading = false
        quotas[.claudeCode] = quota
    }

    public func refreshGemini() async {
        var quota = quotas[.gemini] ?? ProviderQuota(provider: .gemini)
        quota.isLoading = true
        quota.errorMessage = nil
        quotas[.gemini] = quota

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
                quotas[.gemini] = quota
                return
            } catch {
                // If API Key failed, only fall back to OAuth/local if available
                let local = GeminiService.shared.readLocalGeminiConfig()
                let hasOAuth = !settings.geminiToken.isEmpty || local.account != nil || local.token != nil || local.refreshToken != nil
                if !hasOAuth {
                    quota.isAuthorized = false
                    quota.errorMessage = error.localizedDescription
                    quota.isLoading = false
                    quotas[.gemini] = quota
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
        }

        quota.isLoading = false
        quotas[.gemini] = quota
    }

    public func refreshGLM() async {
        var quota = quotas[.glm] ?? ProviderQuota(provider: .glm)
        quota.isLoading = true
        quota.errorMessage = nil
        quotas[.glm] = quota

        guard !settings.glmApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quota.isAuthorized = false
            quota.errorMessage = I18n(.errMissingGLMKey)
            quota.isLoading = false
            quotas[.glm] = quota
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
        }

        quota.isLoading = false
        quotas[.glm] = quota
    }

    public func refreshAliyun() async {
        var quota = quotas[.aliyunBailian] ?? ProviderQuota(provider: .aliyunBailian)
        quota.isLoading = true
        quota.errorMessage = nil
        quotas[.aliyunBailian] = quota

        do {
            let res = try await AliyunBailianService.shared.fetchQuota(
                apiKey: settings.aliyunApiKey,
                cookie: settings.aliyunCookie,
                endpoint: settings.aliyunEndpoint
            )
            quota.fiveHourWindow = res.fiveHour
            quota.weeklyWindow = res.weekly
            quota.accountInfo = res.account
            quota.isAuthorized = true
            quota.lastUpdated = Date()
        } catch {
            quota.isAuthorized = false
            quota.errorMessage = error.localizedDescription
        }

        quota.isLoading = false
        quotas[.aliyunBailian] = quota
    }

    public func importClaudeFromLocal() -> Bool {
        if let local = ClaudeService.shared.readLocalClaudeJson() {
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

    public func importGeminiFromLocal() -> Bool {
        let local = GeminiService.shared.readLocalGeminiConfig()
        if let token = local.token {
            settings.geminiToken = token
            saveSettings()
            Task { await refreshGemini() }
            return true
        }
        return false
    }

    public func refreshOpenAI() async {
        var quota = quotas[.openAI] ?? ProviderQuota(provider: .openAI)
        quota.isLoading = true
        quota.errorMessage = nil
        quotas[.openAI] = quota

        guard !settings.openAIApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quota.isAuthorized = false
            quota.errorMessage = I18n(.errMissingOpenAIKey)
            quota.isLoading = false
            quotas[.openAI] = quota
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
        }

        quota.isLoading = false
        quotas[.openAI] = quota
    }

    public func refreshDeepSeek() async {
        var quota = quotas[.deepseek] ?? ProviderQuota(provider: .deepseek)
        quota.isLoading = true
        quota.errorMessage = nil
        quotas[.deepseek] = quota

        guard !settings.deepseekApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quota.isAuthorized = false
            quota.errorMessage = I18n(.errMissingDeepSeekKey)
            quota.isLoading = false
            quotas[.deepseek] = quota
            return
        }

        do {
            let res = try await DeepSeekService.shared.fetchQuota(
                apiKey: settings.deepseekApiKey,
                endpoint: settings.deepseekEndpoint,
                model: settings.deepseekModel
            )
            quota.fiveHourWindow = res.fiveHour
            quota.weeklyWindow = res.weekly
            quota.accountInfo = res.account
            quota.isAuthorized = true
            quota.lastUpdated = Date()
        } catch {
            quota.isAuthorized = false
            quota.errorMessage = error.localizedDescription
        }

        quota.isLoading = false
        quotas[.deepseek] = quota
    }

    public func refreshVolcengine() async {
        var quota = quotas[.volcengine] ?? ProviderQuota(provider: .volcengine)
        quota.isLoading = true
        quota.errorMessage = nil
        quotas[.volcengine] = quota

        guard !settings.volcengineApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quota.isAuthorized = false
            quota.errorMessage = I18n(.errMissingVolcengineKey)
            quota.isLoading = false
            quotas[.volcengine] = quota
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
        }

        quota.isLoading = false
        quotas[.volcengine] = quota
    }

    public func refreshKimi() async {
        var quota = quotas[.kimi] ?? ProviderQuota(provider: .kimi)
        quota.isLoading = true
        quota.errorMessage = nil
        quotas[.kimi] = quota

        guard !settings.kimiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            quota.isAuthorized = false
            quota.errorMessage = I18n(.errMissingKimiKey)
            quota.isLoading = false
            quotas[.kimi] = quota
            return
        }

        do {
            let res = try await KimiService.shared.fetchQuota(
                apiKey: settings.kimiApiKey,
                endpoint: settings.kimiEndpoint,
                model: settings.kimiModel
            )
            quota.fiveHourWindow = res.fiveHour
            quota.weeklyWindow = res.weekly
            quota.accountInfo = res.account
            quota.isAuthorized = true
            quota.lastUpdated = Date()
        } catch {
            quota.isAuthorized = false
            quota.errorMessage = error.localizedDescription
        }

        quota.isLoading = false
        quotas[.kimi] = quota
    }

    public func refreshCustomProvider(config: CustomProviderConfig) async {
        var q = customQuotas[config.id] ?? CustomProviderQuota(
            configId: config.id,
            name: config.name,
            apiProtocol: config.apiProtocol,
            isEnabled: config.isEnabled
        )
        q.isLoading = true
        q.errorMessage = nil
        customQuotas[config.id] = q

        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            q.isAuthorized = false
            q.errorMessage = I18n(.errMissingCustomKey)
            q.isLoading = false
            customQuotas[config.id] = q
            return
        }

        do {
            let res = try await CustomProviderService.shared.fetchQuota(config: config)
            q.primaryWindow = res.primary
            q.secondaryWindow = res.secondary
            q.accountInfo = res.account
            q.isAuthorized = true
            q.lastUpdated = Date()
        } catch {
            q.isAuthorized = false
            q.errorMessage = error.localizedDescription
        }

        q.isLoading = false
        customQuotas[config.id] = q
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
        customQuotas.removeValue(forKey: id)
        saveSettings()
    }
}
