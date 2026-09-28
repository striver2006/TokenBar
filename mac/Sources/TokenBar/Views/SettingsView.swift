import AppKit
import SwiftUI

/// 偏好设置窗口的外壳：tab 下拉框 + 钥匙串故障横幅 + 内容区路由 + 全局 alert。
///
/// 各 tab 的输入状态与保存编排已拆分到 Views/Settings/ 下的子视图；本层只保留
/// 跨 tab 共享的状态：
/// - `selectedTab`（tab 路由，窗口复用时由 SettingsWindowRequest 驱动）
/// - `statusAlertMessage` / `showStatusAlert`（alert 挂在根视图上，所有 tab 经
///   Binding 写入同一个槽位）
/// - 语言观察（ProviderTabPicker 的 `.id(i18n.currentLanguage)` 与窗口标题刷新）
public struct SettingsView: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared

    @State private var selectedTab: SettingsTab = .openAI
    /// 由 MenuBarController 持有；窗口复用时通过它接收切 tab / 重新加载请求
    @ObservedObject private var request: SettingsWindowRequest

    // 跨 tab 共享的状态提示（所有 tab 的保存/测试按钮都写这两个字段）
    @State private var statusAlertMessage: String? = nil
    @State private var showStatusAlert: Bool = false

    @MainActor
    public init() {
        self.init(refreshManager: .shared, initialTab: .openAI)
    }

    @MainActor
    public init(refreshManager: RefreshManager, initialTab: SettingsTab = .openAI, request: SettingsWindowRequest? = nil) {
        self.refreshManager = refreshManager
        self.request = request ?? SettingsWindowRequest()
        _selectedTab = State(initialValue: initialTab)
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

                ProviderTabPicker(selection: $selectedTab)
                    .frame(width: 250)
                    .id(i18n.currentLanguage)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))

            Divider()

            if let secretError = refreshManager.secretStoreError {
                // 钥匙串不可用 / 写入失败：所有厂商的 Key 都受影响，横幅放在所有 tab 之上
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text(secretError)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
                Divider()
            }

            // Content Area
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case .openAI:
                        SettingsOpenAITab(refreshManager: refreshManager,
                                          statusAlertMessage: $statusAlertMessage,
                                          showStatusAlert: $showStatusAlert,
                                          openCount: request.openCount)
                    case .anthropic:
                        SettingsAnthropicTab(refreshManager: refreshManager,
                                             statusAlertMessage: $statusAlertMessage,
                                             showStatusAlert: $showStatusAlert,
                                             openCount: request.openCount)
                    case .gemini:
                        SettingsGeminiTab(refreshManager: refreshManager,
                                          statusAlertMessage: $statusAlertMessage,
                                          showStatusAlert: $showStatusAlert,
                                          openCount: request.openCount)
                    case .deepseek:
                        SettingsDeepSeekTab(refreshManager: refreshManager,
                                            statusAlertMessage: $statusAlertMessage,
                                            showStatusAlert: $showStatusAlert,
                                            openCount: request.openCount)
                    case .volcengine:
                        SettingsVolcengineTab(refreshManager: refreshManager,
                                              statusAlertMessage: $statusAlertMessage,
                                              showStatusAlert: $showStatusAlert,
                                              openCount: request.openCount)
                    case .kimi:
                        SettingsKimiTab(refreshManager: refreshManager,
                                        statusAlertMessage: $statusAlertMessage,
                                        showStatusAlert: $showStatusAlert,
                                        openCount: request.openCount)
                    case .openRouter:
                        SettingsOpenRouterTab(refreshManager: refreshManager,
                                              statusAlertMessage: $statusAlertMessage,
                                              showStatusAlert: $showStatusAlert,
                                              openCount: request.openCount)
                    case .glm:
                        SettingsGLMTab(refreshManager: refreshManager,
                                       statusAlertMessage: $statusAlertMessage,
                                       showStatusAlert: $showStatusAlert,
                                       openCount: request.openCount)
                    case .aliyun:
                        SettingsAliyunTab(refreshManager: refreshManager,
                                          statusAlertMessage: $statusAlertMessage,
                                          showStatusAlert: $showStatusAlert,
                                          openCount: request.openCount)
                    case .custom:
                        SettingsCustomTab(refreshManager: refreshManager,
                                          statusAlertMessage: $statusAlertMessage,
                                          showStatusAlert: $showStatusAlert)
                    case .displayOrder:
                        SettingsOrderTab(refreshManager: refreshManager)
                    case .general:
                        SettingsGeneralTab(refreshManager: refreshManager)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 580, height: 520)
        .onAppear {
            MenuBarController.shared.updateSettingsTitle(tab: selectedTab)
        }
        .task(id: request.openCount) {
            // 设置窗口的 hosting view 是复用的（MenuBarController.openSettings），
            // 重开请求（openCount 递增）到达时本层只负责切 tab。各 tab 输入的重新
            // 种子化与钥匙串 Secret 重读由子视图自己响应下传的 openCount：
            // 厂商 tab 用 .onChange(of: openCount)，阿里云 tab 用 .task(id: openCount)
            // （随 view 生命周期自动取消，不会在窗口已经关掉后回来写 @State）。
            // 语义与原父层 syncFromSettings() + loadAliyunSecretFromKeychain() 一致。
            if request.openCount > 0 {
                selectedTab = request.tab
            }
        }
        .onChange(of: selectedTab) { newTab in
            MenuBarController.shared.updateSettingsTitle(tab: newTab)
        }
        .onChange(of: i18n.currentLanguage) { _ in
            MenuBarController.shared.updateSettingsTitle(tab: selectedTab)
        }
        .alert(isPresented: $showStatusAlert) {
            Alert(
                title: Text(I18n(.alertNotice)),
                message: Text(statusAlertMessage ?? ""),
                dismissButton: .default(Text(I18n(.alertOk)))
            )
        }
    }
}
