import Cocoa
import SwiftUI
import Combine

@MainActor
public final class MenuBarController: NSObject {
    public static let shared = MenuBarController()

    /// 弹窗锚点来源：`.pointer` 表示由悬停/点击触发（鼠标一定在图标上，可用于校验坐标），
    /// `.cached` 表示从 Dock / Finder 重开等鼠标不在图标上的场景，只能信任缓存坐标。
    public enum PopoverAnchorMode {
        case pointer
        case cached
    }

    private static let anchorFallbackEnabled = true
    /// 调试键：`defaults write com.tokenbar.mac TokenBarForceAnchorFallback -bool YES` 强制走兜底路径
    private static let forceFallbackDefaultsKey = "TokenBarForceAnchorFallback"

    private static let statusItemAutosaveName = "TokenBarStatusItem"

    private var statusItem: NSStatusItem?
    private var popover: NSPopover!
    private var hoverTimer: Timer?
    /// 唤醒示意弹窗的自动收回定时器（一次性）；用户点按状态项接管后取消
    private var autoDismissTimer: Timer?
    private var isPinnedByClick: Bool = false
    private var settingsWindow: NSWindow?
    private var trackingArea: NSTrackingArea?
    private var cancellables = Set<AnyCancellable>()

    /// 缓存坐标过期时用于挂载 NSPopover 的透明辅助面板（懒创建、复用）
    private var anchorPanel: NSPanel?
    /// 本次弹窗实际使用的锚点屏幕矩形；悬停期间的鼠标命中判断只认它
    private var currentAnchorRect: NSRect?
    private var lastShowUsedFallback = false
    /// 鼠标移动监听句柄，teardown 时必须移除；以前直接丢弃返回值，监听器随实例泄漏
    private var mouseMonitor: Any?
    /// 设置窗口的打开请求（切 tab / 重新读钥匙串），供复用的 SettingsView 观察
    private let settingsRequest = SettingsWindowRequest()

    /// 悬停展开 / 移出关闭的延迟，PRD 3.1
    static let hoverOpenDelay: TimeInterval = 0.15
    static let hoverCloseDelay: TimeInterval = 0.35

    private var didSetupOnce = false

    private override init() {
        super.init()
    }

    deinit {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    public func setup() {
        guard !didSetupOnce else { return }
        didSetupOnce = true

        buildPopover()
        installStatusItem()

        // 额度 / 设置任一变化后刷新菜单栏摘要文案（objectWillChange 早于赋值，故延到下一轮 runloop）
        RefreshManager.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemTitle()
            }
            .store(in: &cancellables)
        updateStatusItemTitle()

        observeWakeEvents()
    }

    // MARK: - 状态项的安装与重建

    /// 可重入：销毁旧状态项后重新安装。**这里不得出现任何订阅/监听注册**，
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.statusItemAutosaveName
        item.isVisible = true
        statusItem = item

        guard let button = item.button else {
            Log.lifecycle.error("状态项安装失败：button 为 nil")
            return
        }
        button.target = self
        button.action = #selector(statusBarButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyStatusItemContent()
        installHoverTracking(on: button)
        Log.lifecycle.notice(
            "状态项已安装：图标=\(button.image != nil ? "有" : "无", privacy: .public)")
    }

    /// 悬停追踪区直接挂在状态项按钮上，不再往按钮里塞子视图。
    ///
    /// `.inVisibleRect` 让 AppKit 跟着按钮 bounds 走，额度文案变宽变窄都不必重建追踪区。
    private func installHoverTracking(on button: NSStatusBarButton) {
        let area = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        button.addTrackingArea(area)
        trackingArea = area
    }

    // selector 必须显式写死。Swift 给 `mouseEntered(with:)` 自动合成的 @objc 名字是
    // `mouseEnteredWith:`（只有 override NSResponder 的同名方法才保留原名），而 AppKit
    // 向 NSTrackingArea 的 owner 发的是 `mouseEntered:` —— 对不上就静默收不到悬停事件，
    // 点击却照常工作，极难排查。
    @objc(mouseEntered:)
    func mouseEntered(with event: NSEvent) {
        handleHoverEntered()
    }

    @objc(mouseExited:)
    func mouseExited(with event: NSEvent) {
        handleHoverExited()
    }

    private func buildPopover() {
        // Setup Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let popoverContent = TokenSummaryPopoverView(
            refreshManager: .shared,
            onOpenSettings: { [weak self] tab in
                Task { @MainActor in
                    self?.openSettings(tab: tab)
                }
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )

        popover.contentViewController = NSHostingController(rootView: popoverContent)
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let currentEvent = NSApp.currentEvent
        if currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        // Left Click toggle
        cancelHoverTimer()
        // 用户点按图标即接管弹窗，不再按唤醒示意的节奏自动收回
        cancelAutoDismissTimer()

        if popover.isShown {
            if isPinnedByClick {
                closePopover()
            } else {
                // If it was open by hover, click now pins it
                isPinnedByClick = true
                removeMouseMonitor()
            }
        } else {
            isPinnedByClick = true
            showPopover()
        }
    }

    // MARK: - 悬停状态机

    /// 悬停定时器只有一个，展开与关闭共用；注册到 .common mode，
    /// 否则右键菜单 / 拖拽等 .eventTracking 期间会被暂停（与 RefreshManager 的定时器同理）。
    private func scheduleHover(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        cancelHoverTimer()
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            Task { @MainActor in action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func cancelHoverTimer() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    /// 鼠标已离开图标与浮窗，若未固定则延迟关闭
    private func scheduleHoverClose() {
        guard popover.isShown && !isPinnedByClick else { return }
        scheduleHover(after: Self.hoverCloseDelay) { [weak self] in
            guard let self, !self.isPinnedByClick else { return }
            self.closePopover()
        }
    }

    public func handleHoverEntered() {
        guard RefreshManager.shared.settings.enableHover else { return }
        if popover.isShown {
            // 从浮窗回到图标：取消待执行的关闭
            cancelHoverTimer()
            return
        }
        // Debounce before opening on hover
        scheduleHover(after: Self.hoverOpenDelay) { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.isPinnedByClick = false
            self.showPopover()
        }
    }

    public func handleHoverExited() {
        cancelHoverTimer()
        scheduleHoverClose()
    }

    /// 悬停态专用：光标在「图标 → 浮窗 → 桌面」路径上移动时的 mouseMoved 命中监听。
    /// 只在未 pin 的弹窗展开期间存在；pinned / 关闭态装着它纯属浪费 —— 每个事件
    /// 都要分配一个 Task 才能在守卫处早退，被第二实例唤醒的长跑弹窗会持续白白吃 CPU。
    private func installMouseMonitorIfNeeded() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMoved(event)
            }
            return event
        }
    }

    private func removeMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    /// 鼠标在本进程窗口内移动时的命中判断。
    /// 路径「图标 → 浮窗 → 桌面」：离开图标时安排了关闭，进入浮窗时取消它；再从浮窗移出到
    /// 桌面后，NSTrackingArea 只覆盖状态栏按钮、不会再报 exited，所以必须在这里重新安排关闭，
    /// 否则浮窗会一直挂着（以前正是缺了这个 else 分支）。
    private func handleMouseMoved(_ event: NSEvent) {
        guard popover.isShown && !isPinnedByClick else { return }

        let mouseLoc = NSEvent.mouseLocation
        let inAnchor = (currentAnchorRect ?? cachedButtonScreenRect())?.contains(mouseLoc) ?? false
        let inPopover = popover.contentViewController?.view.window?.frame.contains(mouseLoc) ?? false

        if inAnchor || inPopover {
            cancelHoverTimer()
        } else if hoverTimer == nil {
            scheduleHoverClose()
        }
    }

    /// 幂等地重刷状态项按钮的全部视觉内容（图标、字体、标题）。
    ///
    /// macOS 26 起状态项由系统进程托管渲染，长跑实例的按钮内容可能凭空丢失：
    /// 位置仍保留、仍可点击，但图标与文字不再绘制（表现为菜单栏一块空白）。
    /// setup() 的一次性赋值没有自愈能力，这里每次都重新构造 SF Symbol 并推一遍；
    /// 相同取值对系统侧幂等，无可见副作用。
    @discardableResult
    private func applyStatusItemContent() -> Bool {
        guard let button = statusItem?.button else {
            Log.lifecycle.error("状态项按钮不可用，内容重刷跳过")
            return false
        }

        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if let image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent", accessibilityDescription: "TokenBar")?.withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
        } else if let fallbackImage = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "TokenBar") {
            fallbackImage.isTemplate = true
            button.image = fallbackImage
        } else {
            Log.lifecycle.error("SF Symbol 加载失败：gauge 与 chart.bar.fill 均不可用，图标缺失")
        }

        // 等宽数字，避免额度百分比跳动时菜单栏宽度抖动
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        updateStatusItemTitle()
        return button.image != nil
    }

    /// 依据设置刷新菜单栏图标旁的额度摘要；未开启时只保留图标。
    public func updateStatusItemTitle() {
        guard let button = statusItem?.button else { return }

        let status = MenuBarStatus.resolve(
            settings: RefreshManager.shared.settings,
            quotas: RefreshManager.shared.quotas,
            customQuotas: RefreshManager.shared.customQuotas
        )

        if let status = status {
            if status.isStale {
                // 数据明显过期时变灰，宽度不变、不抖动。
                button.attributedTitle = NSAttributedString(
                    string: " " + status.title,
                    attributes: [
                        .foregroundColor: NSColor.tertiaryLabelColor,
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                    ]
                )
            } else {
                // attributedTitle 与 title 在 NSButton 上是两套状态，
                // 切回正常态必须显式清空前者，否则会一直发灰。
                button.attributedTitle = NSAttributedString(string: "")
                button.title = " " + status.title
            }
            button.imagePosition = .imageLeading
            button.toolTip = status.tooltip
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "TokenBar - \(I18n(.subtitle))"
        }
    }

    // MARK: - 弹窗定位

    /// 本进程缓存的状态项按钮屏幕矩形。macOS 26 起状态项托管在系统进程，
    /// 显示器熄屏/唤醒后这份缓存可能过期，调用方需自行校验。
    private func cachedButtonScreenRect() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    public func showPopover(anchor: PopoverAnchorMode = .pointer) {
        guard let statusItem, let button = statusItem.button else {
            Log.lifecycle.error("showPopover：状态项不可用")
            return
        }
        let cachedRect = cachedButtonScreenRect()
        let resolution = resolveAnchor(mode: anchor, cachedRect: cachedRect)
        currentAnchorRect = resolution.rect
        lastShowUsedFallback = resolution.isFallback

        if resolution.isFallback, let anchorView = prepareAnchorPanel(frame: resolution.rect) {
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        } else {
            // 正常路径不留辅助面板
            anchorPanel?.orderOut(nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        Log.lifecycle.notice(
            "弹窗锚点：mode=\(anchor == .pointer ? "pointer" : "cached", privacy: .public) path=\(resolution.isFallback ? "panel" : "button", privacy: .public) cached=\(Self.describe(cachedRect), privacy: .public) final=\(Self.describe(resolution.rect), privacy: .public)")
        popover.contentViewController?.view.window?.makeKey()

        if popover.isShown, !isPinnedByClick {
            installMouseMonitorIfNeeded()
        } else {
            // 展开失败或 pinned 场景：监听器没有存在的必要，装了就回收
            removeMouseMonitor()
        }
    }

    /// accessory 应用的 `NSScreen.main` 不可靠；`NSScreen.screens[0]` 恒为菜单栏所在屏
    private func menuBarScreen(preferring rect: NSRect?) -> NSScreen? {
        if let rect, let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            return screen
        }
        return NSScreen.screens.first
    }

    /// 兜底锚点距屏幕右缘要留够弹窗半宽，否则 NSPopover 又被夹到屏幕边上
    private var popoverTrailingInset: CGFloat {
        popover.contentSize.width / 2 + 26
    }

    private func resolveAnchor(mode: PopoverAnchorMode, cachedRect: NSRect?) -> MenuBarAnchor.Resolution {
        guard Self.anchorFallbackEnabled else {
            return MenuBarAnchor.Resolution(rect: cachedRect ?? .zero, isFallback: false)
        }

        switch mode {
        case .pointer:
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens.first else {
                return MenuBarAnchor.Resolution(rect: cachedRect ?? .zero, isFallback: false)
            }
            var resolution = MenuBarAnchor.resolve(
                cachedButtonRect: cachedRect,
                mouseLocation: mouse,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                defaultMenuBarHeight: NSStatusBar.system.thickness
            )
            if !resolution.isFallback, UserDefaults.standard.bool(forKey: Self.forceFallbackDefaultsKey) {
                // 调试：强制走兜底路径，用一个不含鼠标的矩形触发推导
                resolution = MenuBarAnchor.resolve(
                    cachedButtonRect: NSRect(x: -10_000, y: -10_000, width: cachedRect?.width ?? 0, height: 1),
                    mouseLocation: mouse,
                    screenFrame: screen.frame,
                    visibleFrame: screen.visibleFrame,
                    defaultMenuBarHeight: NSStatusBar.system.thickness
                )
            }
            if !resolution.isFallback {
                // 二次几何校验：resolve 的分支 3（鼠标不在菜单栏带内）会把坏缓存原样放行
                resolution = resolveWithoutPointer(cachedRect: resolution.rect, on: screen)
            }
            return resolution

        case .cached:
            // tb / Dock reopen / 第二实例唤醒：鼠标不在图标上，只能靠几何校验
            guard let screen = menuBarScreen(preferring: cachedRect) else {
                return MenuBarAnchor.Resolution(rect: cachedRect ?? .zero, isFallback: false)
            }
            return resolveWithoutPointer(cachedRect: cachedRect, on: screen)
        }
    }

    private func resolveWithoutPointer(cachedRect: NSRect?, on screen: NSScreen) -> MenuBarAnchor.Resolution {
        MenuBarAnchor.resolveWithoutPointer(
            cachedButtonRect: cachedRect,
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            defaultMenuBarHeight: NSStatusBar.system.thickness,
            trailingInset: popoverTrailingInset,
            trailingClusterMinX: systemItemsLeadingX(on: screen)
        )
    }

    /// 系统项簇（控制中心）在菜单栏上的最左边界。
    /// macOS 26 实测：控制中心持有一批 layer-25 的 onscreen 窗口，连续铺满菜单栏右侧
    /// （本机 2703 → 3440），第三方图标就排在它左边。查不到返回 nil，调用方回落到纯几何算法。
    private func systemItemsLeadingX(on screen: NSScreen) -> CGFloat? {
        // CG 坐标原点在主屏左上，跨屏换算容易出错，只在菜单栏主屏上启用这条增强
        guard screen === NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        // 自己的状态项窗口也可能出现在这一排里，算进去会让兜底锚点跟着跑偏
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var leading: CGFloat?
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 25,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 0, height > 0,
                  y <= 2, height <= 40,                       // 只认贴着菜单栏那一排
                  x >= screen.frame.minX, x < screen.frame.maxX
            else { continue }
            leading = min(leading ?? x, x)
        }
        return leading
    }

    /// 透明、穿透点击、贴在菜单栏上的辅助面板，仅在缓存坐标不可信时作为 NSPopover 的定位视图。
    private func prepareAnchorPanel(frame: NSRect) -> NSView? {
        let panel: NSPanel
        if let existing = anchorPanel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            // 面板叠在状态项正上方，点击必须穿透到真正的状态按钮
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            // NSPanel 默认失活即隐藏，那样挂在它上面的弹窗会一起消失
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isExcludedFromWindowsMenu = true
            panel.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
            anchorPanel = panel
        }
        panel.setFrame(frame, display: false)
        // 必须先可见，NSPopover 才能把自己挂成它的子窗口；accessory 应用用 orderFront(nil) 可能不生效
        panel.orderFrontRegardless()
        return panel.contentView
    }

    public func closePopover() {
        popover.performClose(nil)
        isPinnedByClick = false
    }

    /// 唤醒示意弹窗的自动收回：第二实例唤醒时弹出的面板没有自然关闭时机
    /// （.transient 只在用户点击其他应用时关闭），pin 着一直开会把「弹窗打开期间」
    /// 的每帧成本从秒级拉长为无限期。到点仍开着就收回。
    private func scheduleAutoDismiss(after delay: TimeInterval) {
        cancelAutoDismissTimer()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                Log.lifecycle.debug("唤醒弹窗到期自动收回")
                self.closePopover()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoDismissTimer = timer
    }

    private func cancelAutoDismissTimer() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    /// - Parameter autoDismiss: 非 nil 时（第二实例唤醒路径）弹窗在指定秒数后自动收回；
    ///   Dock / Finder reopen 是用户主动行为、用户在场，传 nil 保持原样。
    public func togglePopoverOrOpenWindow(autoDismiss: TimeInterval? = nil) {
        cancelAutoDismissTimer()
        guard !popover.isShown else {
            closePopover()
            return
        }

        presentReopenPopover(autoDismiss: autoDismiss)
    }

    private func presentReopenPopover(autoDismiss: TimeInterval?) {
        isPinnedByClick = true
        showPopover(anchor: .cached)
        if !popover.isShown {
            openSettings(tab: .openAI)
        } else if let autoDismiss {
            scheduleAutoDismiss(after: autoDismiss)
        }
    }

    // MARK: - 系统休眠与唤醒

    /// 监听休眠唤醒事件以补刷过期额度数据。
    private func observeWakeEvents() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceCenter
                .publisher(for: name)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        await self?.refreshAfterWake()
                    }
                }
                .store(in: &cancellables)
        }
    }

    /// 睡眠期间定时器不 fire，唤醒后数据可能已经过期若干个周期，这里补刷一次。
    /// 两个唤醒通知会先后到达，靠 refreshIfStale 的时间判断 + refreshAll 的 isRefreshing 闸门去重。
    private func refreshAfterWake() async {
        let manager = RefreshManager.shared
        let halfInterval = Double(manager.settings.refreshIntervalMinutes * 30)
        await manager.refreshIfStale(olderThan: halfInterval)
    }

    private static func describe(_ rect: NSRect?) -> String {
        guard let rect else { return "nil" }
        return String(format: "%.0f,%.0f %.0fx%.0f", rect.minX, rect.minY, rect.width, rect.height)
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "TokenBar - \(I18n(.subtitle))", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: I18n(.menuRefreshAll), action: #selector(refreshAction), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: I18n(.menuPreferences), action: #selector(openSettingsAction), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: I18n(.menuQuit), action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        guard let statusItem else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshAction() {
        Task {
            await RefreshManager.shared.refreshAll()
        }
    }

    @objc private func openSettingsAction() {
        openSettings(tab: .openAI)
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    public func updateSettingsTitle(tab: SettingsTab) {
        settingsWindow?.title = "TokenBar - \(tab.title)"
    }

    public func openSettings(tab: SettingsTab = .openAI) {
        closePopover()

        if let existing = settingsWindow {
            // 复用 hosting view：以前每次都重建整棵 SettingsView，用户未保存的输入被丢弃、
            // 滚动位置重置。切 tab 与重新读钥匙串改为通过 settingsRequest 通知视图。
            existing.title = "TokenBar - \(tab.title)"
            settingsRequest.open(tab: tab)
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "TokenBar - \(tab.title)"
        settingsRequest.tab = tab
        window.contentView = NSHostingView(rootView: SettingsView(refreshManager: .shared, initialTab: tab, request: settingsRequest))
        window.isReleasedWhenClosed = false

        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 设置窗口复用时，向已存在的 SettingsView 传递「切到哪个 tab」与「重新加载」请求
@MainActor
public final class SettingsWindowRequest: ObservableObject {
    @Published public var tab: SettingsTab = .openAI
    /// 每次打开窗口递增；SettingsView 用 .task(id:) 监听它重跑钥匙串读取
    @Published public var openCount: Int = 0

    public init() {}

    func open(tab: SettingsTab) {
        self.tab = tab
        openCount += 1
    }
}

// MARK: - NSPopoverDelegate

extension MenuBarController: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        // .transient 点击外部关闭也会走到这里，状态必须在唯一出口复位
        isPinnedByClick = false
        cancelHoverTimer()
        removeMouseMonitor()
        cancelAutoDismissTimer()
        // 弹窗是辅助面板的子窗口，只能在它关闭之后再回收面板
        anchorPanel?.orderOut(nil)
        currentAnchorRect = nil
        lastShowUsedFallback = false
    }
}
