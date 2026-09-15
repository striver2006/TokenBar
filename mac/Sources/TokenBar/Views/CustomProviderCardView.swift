import SwiftUI

public struct CustomProviderCardView: View {
    let quota: CustomProviderQuota
    let onConfigure: () -> Void
    let onRetry: () -> Void

    public init(
        quota: CustomProviderQuota,
        onConfigure: @escaping () -> Void,
        onRetry: @escaping () -> Void = {}
    ) {
        self.quota = quota
        self.onConfigure = onConfigure
        self.onRetry = onRetry
    }

    private var themeColor: Color {
        switch quota.apiProtocol {
        case .openAIChat:
            return Color(red: 0.1, green: 0.65, blue: 0.55) // Teal
        case .openAIResponses:
            return Color(red: 0.23, green: 0.72, blue: 0.53) // Emerald
        case .anthropic:
            return Color(red: 0.85, green: 0.45, blue: 0.28) // Terracotta
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: quota.apiProtocol == .anthropic ? "network" : "cpu.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(themeColor)
                    .frame(width: 22, height: 22)
                    .background(themeColor.opacity(0.12))
                    .cornerRadius(6)

                Text(quota.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(quota.apiProtocol.shortName)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(themeColor.opacity(0.12))
                    .foregroundColor(themeColor)
                    .cornerRadius(4)

                if let acc = quota.accountInfo, !acc.isEmpty {
                    Text(acc)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if quota.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                } else if quota.isAuthorized && !quota.hadRefreshError {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                } else {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                }
            }

            if !quota.isAuthorized && !quota.hadRefreshError {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 11))
                        Text(quota.errorMessage ?? I18n(.notAuthorized))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button(I18n(.configure)) {
                            onConfigure()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                }
                .padding(.vertical, 4)
            } else if quota.hadRefreshError && quota.primaryWindow == nil && quota.secondaryWindow == nil {
                // 已配置但刷新失败（多为开机网络未就绪）：显示错误 + 「重试」，而不是误导性的「去配置」
                HStack {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text(quota.errorMessage ?? I18n(.refreshErrorHint))
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                    Spacer()
                    Button(I18n(.retry)) {
                        onRetry()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                .padding(.vertical, 4)
            } else {
                if quota.primaryWindow == nil && quota.secondaryWindow == nil {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 11))
                        Text(quota.errorMessage ?? I18n(.serviceOperational))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    if let primary = quota.primaryWindow {
                        WindowQuotaRow(window: primary, badgeText: quota.apiProtocol.shortName)
                    }

                    if quota.primaryWindow != nil && quota.secondaryWindow != nil {
                        Divider()
                            .opacity(0.5)
                    }

                    if let secondary = quota.secondaryWindow {
                        WindowQuotaRow(window: secondary, badgeText: secondary.title.uppercased().contains("TPM") ? "TPM" : "RPM")
                    }
                }

                if quota.hadRefreshError {
                    // 本轮刷新失败但旧数据仍可参考：末尾叠一行小字提示，不打断余额展示
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 9))
                        Text(quota.errorMessage ?? I18n(.refreshErrorHint))
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                    .foregroundColor(.orange)
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.7))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
