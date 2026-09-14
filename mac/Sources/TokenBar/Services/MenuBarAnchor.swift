import Foundation

/// 菜单栏弹窗锚点解析。
///
/// macOS 26 起状态项托管在系统进程里，本进程缓存的 `NSStatusBarWindow.frame` 在显示器
/// 熄屏/唤醒重配置后可能过期，`NSPopover` 依据过期坐标会把弹窗定位到屏幕中央。
/// 这里用"触发弹窗时鼠标一定在图标上"这一事实校验缓存矩形，不可信时按鼠标位置推导
/// 兜底矩形。全部为纯函数，便于单测。
///
/// 鼠标不在图标上的场景（Dock / Finder reopen、第二实例唤醒）走 `resolveWithoutPointer`，
/// 改用"缓存矩形是否落在菜单栏带内"这一几何事实校验。
public enum MenuBarAnchor {

    public struct Resolution: Equatable {
        /// 弹窗应锚定的屏幕矩形（AppKit 坐标，原点左下）
        public let rect: NSRect
        /// 是否走了推导的兜底路径
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
    /// 缓存矩形不可信时，兜底锚点中心距屏幕右缘的余量。
    /// 必须大于弹窗半宽，否则 NSPopover 又会被夹到屏幕边缘 —— 那正是这次故障的观感。
    public static let defaultTrailingInset: CGFloat = 180
    /// 菜单栏带下边界的松弛量。
    /// 实测 macOS 26（3440×1440）：菜单栏带高 30，健康状态项窗口的 AppKit frame 是
    /// `(2661, 1410, 80, 30)` —— maxY 正好贴齐屏幕顶边，但窗口高度未必等于带高，
    /// 所以下边界要留余量。上边界与左右边界只留浮点容差：故障态正是从这三边越出去的。
    public static let defaultBandBottomSlack: CGFloat = 8
    /// 上边界与左右边界的浮点容差。留大了就会把越界的故障态放过去。
    public static let defaultBandEdgeEpsilon: CGFloat = 0.5

    /// 菜单栏高度 = 屏幕顶边 − 可见区顶边；≤0 说明菜单栏隐藏，用默认值
    static func menuBarHeight(screenFrame: NSRect, visibleFrame: NSRect, fallback: CGFloat) -> CGFloat {
        let height = screenFrame.maxY - visibleFrame.maxY
        return height <= 0 ? fallback : height
    }

    /// 矩形是否落在这块屏幕的菜单栏带内。
    ///
    /// 状态项健康与否、以及无鼠标时缓存矩形可不可信，用的都是这一个判据，几何定义只有一份。
    ///
    /// 越出屏幕顶边或左右边界的矩形不可能是正常布局，判定对这三边只留浮点容差 —— 实测故障态
    /// `(3332, 1417, 109, 24)` 正是 maxY 越顶、maxX = 3441 越右，
    /// 留 2pt 容差反而会把它放过去。下边界才需要松弛量。
    public static func isInMenuBarBand(
        _ rect: NSRect,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        defaultMenuBarHeight: CGFloat = defaultMenuBarHeight,
        bottomSlack: CGFloat = defaultBandBottomSlack
    ) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        guard rect.maxY <= screenFrame.maxY + defaultBandEdgeEpsilon,
              rect.minX >= screenFrame.minX - defaultBandEdgeEpsilon,
              rect.maxX <= screenFrame.maxX + defaultBandEdgeEpsilon else { return false }
        let barHeight = menuBarHeight(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            fallback: defaultMenuBarHeight
        )
        return rect.maxY >= screenFrame.maxY - barHeight - bottomSlack
    }

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
        let barHeight = menuBarHeight(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            fallback: defaultMenuBarHeight
        )

        // 3. 鼠标根本不在菜单栏带内（如从 Dock 重开触发）→ 无法推导，退回缓存
        let band = NSRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - barHeight - tolerance,
            width: screenFrame.width,
            height: barHeight + tolerance
        )
        if !band.contains(mouseLocation), let cached {
            return Resolution(rect: cached, isFallback: false)
        }

        // 4. 兜底：以鼠标 x 为中心、贴屏幕顶边、宽 = 缓存按钮宽、高 = 菜单栏高，水平夹在屏内
        let width = cached.map { $0.width } ?? defaultButtonWidth
        let minX = screenFrame.minX
        let maxX = max(screenFrame.maxX - width, minX)
        let x = min(max(mouseLocation.x - width / 2, minX), maxX)
        let rect = NSRect(x: x, y: screenFrame.maxY - barHeight, width: width, height: barHeight)
        return Resolution(rect: rect, isFallback: true)
    }

    /// 不依赖鼠标的锚点解析：`tb`（`open -a`）/ Dock reopen / 第二实例唤醒走这条。
    ///
    /// 这些场景鼠标不在图标上，`resolve` 的分支 3 会把缓存矩形原样放行 —— 缓存本身就是坏的时候
    /// 毫无防护。实测故障：状态项停在 `(3332, 1417, 109, 24)`（右边缘越出 3440 的屏幕），
    /// 弹窗按它定位后被 AppKit 夹到 `3440 − 346 = 3094`，贴死在屏幕右缘。
    ///
    /// - Parameters:
    ///   - trailingInset: 兜底锚点中心距屏幕右缘的余量
    ///   - trailingClusterMinX: 系统项簇（控制中心）最左边界；已知时把兜底锚点贴到它左侧，
    ///     那正是第三方图标该在的位置。查不到传 nil，回落到 `trailingInset`。
    public static func resolveWithoutPointer(
        cachedButtonRect: NSRect?,
        screenFrame: NSRect,
        visibleFrame: NSRect,
        defaultMenuBarHeight: CGFloat = defaultMenuBarHeight,
        bottomSlack: CGFloat = defaultBandBottomSlack,
        trailingInset: CGFloat = defaultTrailingInset,
        trailingClusterMinX: CGFloat? = nil
    ) -> Resolution {
        let barHeight = menuBarHeight(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            fallback: defaultMenuBarHeight
        )
        let cached = cachedButtonRect.flatMap {
            $0.isEmpty || $0.width <= 0 || $0.height <= 0 ? nil : $0
        }

        // 1. 缓存矩形落在本屏菜单栏带内 → 可信
        if let cached, isInMenuBarBand(
            cached,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            defaultMenuBarHeight: defaultMenuBarHeight,
            bottomSlack: bottomSlack
        ) {
            return Resolution(rect: cached, isFallback: false)
        }

        // 2. 兜底：贴屏幕顶边，水平放在系统项簇左侧或距右缘 trailingInset 处，夹在屏内
        let width = cached?.width ?? defaultButtonWidth
        let anchorMidX = trailingClusterMinX.map { $0 - width / 2 - 8 }
            ?? (screenFrame.maxX - trailingInset)
        let minX = screenFrame.minX
        let maxX = max(screenFrame.maxX - width, minX)
        let x = min(max(anchorMidX - width / 2, minX), maxX)
        let rect = NSRect(x: x, y: screenFrame.maxY - barHeight, width: width, height: barHeight)
        return Resolution(rect: rect, isFallback: true)
    }
}
