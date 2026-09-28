import AppKit
import SwiftUI

// MARK: - 配置项下拉框(NSPopUpButton)

/// macOS 原生菜单(SwiftUI Picker/Menu 的菜单项)只渲染文本与 SF Symbol,
/// 厂商 Logo 需渲染成 NSImage 后经 NSMenuItem.image 呈现,故用 NSPopUpButton
/// 替代 Picker。调用方保留 `.id(i18n.currentLanguage)`:标题在构建时烘进菜单项,
/// 语言切换需整体重建。非厂商 Tab(自定义/显示顺序/通用)自动回退 SF Symbol。
struct ProviderTabPicker: NSViewRepresentable {
    @Binding var selection: SettingsTab

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        rebuildMenu(of: button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        // 外部(初始定位 / 弹窗跳转请求)改变 selection 时同步选中项;
        // selectItem(at:) 不会触发 target-action,无回环。
        let index = SettingsTab.allCases.firstIndex(of: selection) ?? 0
        if button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }

    private func rebuildMenu(of button: NSPopUpButton) {
        button.menu?.removeAllItems()
        for tab in SettingsTab.allCases {
            let item = NSMenuItem(title: tab.title, action: nil, keyEquivalent: "")
            item.image = ProviderLogo.menuImage(for: tab)
            button.menu?.addItem(item)
        }
        button.selectItem(at: SettingsTab.allCases.firstIndex(of: selection) ?? 0)
    }

    final class Coordinator {
        var parent: ProviderTabPicker

        init(_ parent: ProviderTabPicker) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let tabs = SettingsTab.allCases
            let index = sender.indexOfSelectedItem
            if tabs.indices.contains(index) {
                parent.selection = tabs[index]
            }
        }
    }
}
