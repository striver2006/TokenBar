import SwiftUI

/// 设置页 – 显示排序 tab。无输入状态，全部直接读写 settings.providerOrder。
@MainActor
struct SettingsOrderTab: View {
    @ObservedObject var refreshManager: RefreshManager
    @ObservedObject private var i18n = LocalizationManager.shared

    init(refreshManager: RefreshManager) {
        self.refreshManager = refreshManager
    }

    var body: some View {
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
        SettingsOrdering.enabledOrderKeys(in: refreshManager.settings)
    }

    private func orderDisplayName(for key: String) -> String {
        SettingsOrdering.displayName(for: key, in: refreshManager.settings)
    }

    private func orderRow(key: String, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            if let type = ProviderOrdering.parseProviderType(key) {
                ProviderLogoView(provider: type, size: 12)
                    .frame(width: 20)
            } else if let logo = ProviderLogo.presetLogo(forName: orderDisplayName(for: key)) {
                SVGPathShape(data: logo.paths)
                    .fill(logo.color)
                    .frame(width: 12, height: 12)
                    .frame(width: 20)
            } else {
                Image(systemName: "network")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                    .frame(width: 20)
            }
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
}
