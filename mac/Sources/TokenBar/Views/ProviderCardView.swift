import SwiftUI

public struct ProviderCardView: View {
    let quota: ProviderQuota
    let onConfigure: () -> Void

    public init(quota: ProviderQuota, onConfigure: @escaping () -> Void) {
        self.quota = quota
        self.onConfigure = onConfigure
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: quota.provider.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(quota.provider.themeColor)
                    .frame(width: 22, height: 22)
                    .background(quota.provider.themeColor.opacity(0.12))
                    .cornerRadius(6)

                Text(quota.provider.displayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

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
                } else if quota.isAuthorized {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                } else {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                }
            }

            if !quota.isAuthorized {
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 11))
                        Text(quota.errorMessage ?? I18n(.notAuthorized))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(I18n(.configure)) {
                            onConfigure()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                }
                .padding(.vertical, 4)
            } else {
                if quota.fiveHourWindow == nil && quota.weeklyWindow == nil && quota.balanceWindow == nil {
                    HStack {
                        Image(systemName: "hourglass")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        Text(quota.errorMessage ?? I18n(.syncingData))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                } else {
                    // 5-Hour Window Section
                    if let fiveHour = quota.fiveHourWindow {
                        WindowQuotaRow(window: fiveHour, badgeText: I18n(.fiveHourWindow))
                    }

                    if quota.fiveHourWindow != nil && quota.weeklyWindow != nil
                        && quota.balanceWindow == nil {
                        Divider()
                            .opacity(0.5)
                    }

                    // Balance Section（与时间窗口并存，例如百炼的账户现金余额）
                    if let balance = quota.balanceWindow {
                        if quota.fiveHourWindow != nil {
                            Divider()
                                .opacity(0.5)
                        }
                        WindowQuotaRow(window: balance, badgeText: I18n(.menuBarMetricBalance))
                    }

                    if quota.balanceWindow != nil && quota.weeklyWindow != nil {
                        Divider()
                            .opacity(0.5)
                    }

                    // Weekly Window Section
                    if let weekly = quota.weeklyWindow {
                        WindowQuotaRow(window: weekly, badgeText: I18n(.weeklyWindow))
                    }
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

struct WindowQuotaRow: View {
    let window: TokenWindow
    let badgeText: String

    private var effectiveBadge: String {
        window.isBalance ? I18n(.balanceBadge) : badgeText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Row 1: Title & Percentage / Balance
            HStack {
                Text(effectiveBadge)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08))
                    .cornerRadius(4)

                Text(window.localizedTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)

                Spacer()

                if window.isStatus {
                    // 状态型窗口：只有连通性，没有额度数字，显示一个状态点即可
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(I18n(.apiConnectedTitle))
                } else if window.isBalance {
                    // 余额窗口：直接显示金额，而不是"剩余 X%"
                    Text(window.balanceFormatted)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(window.statusColor)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(I18n(.remaining))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text(String(format: "%.0f%%", window.remainingPercentage))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(window.statusColor)
                    }
                }
            }

            if window.isStatus {
                EmptyView()
            } else if window.isBalance {
                // 余额窗口没有进度条与时间窗口概念：展示较上次变化与预计可用天数
                HStack {
                    let deltaText = window.balanceDeltaFormatted
                    if !deltaText.isEmpty {
                        Text(String(format: I18n(.balanceVsLast), deltaText))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if let days = window.forecastDays {
                        Text(String(format: I18n(.forecastDays), days))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    } else {
                        Text(I18n(.forecastCollecting))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                // Row 2: Progress Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.1))
                            .frame(height: 6)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [window.statusColor.opacity(0.8), window.statusColor],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(4, geo.size.width * CGFloat(window.remainingPercentage / 100.0)), height: 6)
                    }
                }
                .frame(height: 6)

                // Row 3: Time Range & Reset Countdown
                HStack {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                            .font(.system(size: 9))
                        Text(window.timeRangeFormatted)
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)

                    Spacer()

                    Text(window.timeRemainingFormatted)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(window.isExpired ? .red : .secondary)
                }
            }
        }
    }
}
