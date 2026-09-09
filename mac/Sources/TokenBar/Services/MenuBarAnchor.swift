import Foundation

/// 菜单栏弹窗锚点解析。
///
/// macOS 26 起状态项托管在系统进程里，本进程缓存的 `NSStatusBarWindow.frame` 在显示器
/// 熄屏/唤醒重配置后可能过期，`NSPopover` 依据过期坐标会把弹窗定位到屏幕中央。
/// 这里用"触发弹窗时鼠标一定在图标上"这一事实校验缓存矩形，不可信时按鼠标位置推导
/// 兜底矩形。全部为纯函数，便于单测。
public enum MenuBarAnchor {

    public struct Resolution: Equatable {
        /// 弹窗应锚定的屏幕矩形（AppKit 坐标，原点左下）
        public let rect: NSRect
        /// 是否走了鼠标推导的兜底路径
        public let isFallback: Bool

        public init(rect: NSRect, isFallback: Bool) {
            self.rect = rect
            self.isFallback = isFallback
        }
    }

    /// 鼠标允许略微越出按钮矩形的容差（pt）
    public static let defaultTolerance: CGFloat = 2
    /// 菜单栏隐藏（全屏 / 自动隐藏）时算不出高度，用这个兜底
    public static let defaultMenuBarHeight: CGFloat = 24
    /// 缓存矩形不可用时的默认按钮宽度
    public static let defaultButtonWidth: CGFloat = 28

    /// - Parameters:
    ///   - cachedButtonRect: 由 `button.window.convertToScreen` 算出的按钮屏幕矩形；`button.window` 为 nil 时传 nil
    ///   - mouseLocation: `NSEvent.mouseLocation`
    ///   - screenFrame: 鼠标所在 `NSScreen.frame`
    ///   - visibleFrame: 同一屏幕的 `visibleFrame`（顶部不含菜单栏）
    public static func resolve(
        cachedButtonRect: NSRect?,
        mouseLocation: NSPoint,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        tolerance: CGFloat = defaultTolerance,
        defaultMenuBarHeight: CGFloat = defaultMenuBarHeight
    ) -> Resolution {
        let cached = cachedButtonRect.flatMap { $0.isEmpty ? nil : $0 }

        // 1. 缓存矩形（外扩容差后）包含鼠标 → 可信，走原路径
        if let cached, cached.insetBy(dx: -tolerance, dy: -tolerance).contains(mouseLocation) {
            return Resolution(rect: cached, isFallback: false)
        }

        // 2. 菜单栏高度 = 屏幕顶边 − 可见区顶边；≤0 说明菜单栏隐藏，用默认值
        var menuBarHeight = screenFrame.maxY - visibleFrame.maxY
        if menuBarHeight <= 0 {
            menuBarHeight = defaultMenuBarHeight
        }

        // 3. 鼠标根本不在菜单栏带内（如从 Dock 重开触发）→ 无法推导，退回缓存
        let band = NSRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - menuBarHeight - tolerance,
            width: screenFrame.width,
            height: menuBarHeight + tolerance
        )
        if !band.contains(mouseLocation), let cached {
            return Resolution(rect: cached, isFallback: false)
        }

        // 4. 兜底：以鼠标 x 为中心、贴屏幕顶边、宽 = 缓存按钮宽、高 = 菜单栏高，水平夹在屏内
        let width = cached.map { $0.width } ?? defaultButtonWidth
        let minX = screenFrame.minX
        let maxX = max(screenFrame.maxX - width, minX)
        let x = min(max(mouseLocation.x - width / 2, minX), maxX)
        let rect = NSRect(x: x, y: screenFrame.maxY - menuBarHeight, width: width, height: menuBarHeight)
        return Resolution(rect: rect, isFallback: true)
    }
}
