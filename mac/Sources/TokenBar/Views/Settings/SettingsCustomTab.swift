import SwiftUI

/// 设置页 – 国内 / 自定义厂商 tab。
///
/// 表单状态（新增/编辑卡片）不从 settings 种子化 —— 原实现里 syncFromSettings()
/// 也不碰它们，只在点「添加 / 编辑」时按需填充，这里保持一致。
@MainActor
struct SettingsCustomTab: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared
    @Binding var statusAlertMessage: String?
    @Binding var showStatusAlert: Bool

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

    init(refreshManager: RefreshManager,
         statusAlertMessage: Binding<String?>,
         showStatusAlert: Binding<Bool>) {
        self.refreshManager = refreshManager
        _statusAlertMessage = statusAlertMessage
        _showStatusAlert = showStatusAlert
    }

    var body: some View {
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
                                customThresholdInput = config.balanceAlertThreshold.map { SettingsValueFormat.thresholdString($0) } ?? ""
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
}
