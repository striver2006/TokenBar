import Cocoa
import SwiftUI
import Combine

final class HoverTrackingView: NSView {
    var onMouseEnter: (() -> Void)?
    var onMouseExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExit?()
    }
}

@MainActor
public final class MenuBarController: NSObject {
    public static let shared = MenuBarController()

    /// 弹窗锚点来源：`.pointer` 表示由悬停/点击触发（鼠标一定在图标上，可用于校验坐标），
    /// `.cached` 表示从 Dock / Finder 重开等鼠标不在图标上的场景，只能信任缓存坐标。
    public enum PopoverAnchorMode {
        case pointer
        case cached
    }

    /// 两层防护的独立开关，便于排查时单独关闭
    private static let screenRelayoutEnabled = true
    private static let anchorFallbackEnabled = true
    /// 调试键：`defaults write com.tokenbar.mac TokenBarForceAnchorFallback -bool YES` 强制走兜底路径
    private static let forceFallbackDefaultsKey = "TokenBarForceAnchorFallback"

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hoverTimer: Timer?
    private var isPinnedByClick: Bool = false
    private var settingsWindow: NSWindow?
    private var trackingView: HoverTrackingView?
    private var cancellables = Set<AnyCancellable>()

    /// 缓存坐标过期时用于挂载 NSPopover 的透明辅助面板（懒创建、复用）
    private var anchorPanel: NSPanel?
    /// 本次弹窗实际使用的锚点屏幕矩形；悬停期间的鼠标命中判断只认它
    private var currentAnchorRect: NSRect?
    private var lastShowUsedFallback = false
    private var relayoutWorkItem: DispatchWorkItem?

    public override init() {
        super.init()
    }

    public func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "TokenBarStatusItem"

        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            if let image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.50percent", accessibilityDescription: "TokenBar")?.withSymbolConfiguration(config) {
                image.isTemplate = true
                button.image = image
            } else if let fallbackImage = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "TokenBar") {
                fallbackImage.isTemplate = true
                button.image = fallbackImage
            }

            // 等宽数字，避免额度百分比跳动时菜单栏宽度抖动
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            button.target = self
            button.action = #selector(statusBarButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            // Setup hover tracking view
            let tracker = HoverTrackingView(frame: button.bounds)
            tracker.autoresizingMask = [.width, .height]
            tracker.onMouseEnter = { [weak self] in
                Task { @MainActor in
                    self?.handleHoverEntered()
                }
            }
            tracker.onMouseExit = { [weak self] in
                Task { @MainActor in
                    self?.handleHoverExited()
                }
            }

            button.addSubview(tracker, positioned: .below, relativeTo: nil)
            self.trackingView = tracker
        }

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

        // 额度 / 设置任一变化后刷新菜单栏摘要文案（objectWillChange 早于赋值，故延到下一轮 runloop）
        RefreshManager.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemTitle()
            }
            .store(in: &cancellables)
        updateStatusItemTitle()

        // Mouse moved monitor to maintain hover when cursor is in popover or button
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMoved(event)
            }
            return event
        }

        if Self.screenRelayoutEnabled {
            observeScreenChanges()
        }
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        let currentEvent = NSApp.currentEvent
        if currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        // Left Click toggle
        hoverTimer?.invalidate()
        hoverTimer = nil

        if popover.isShown {
            if isPinnedByClick {
                closePopover()
                isPinnedByClick = false
            } else {
                // If it was open by hover, click now pins it
                isPinnedByClick = true
            }
        } else {
            isPinnedByClick = true
            showPopover()
        }
    }

    public func handleHoverEntered() {
        guard RefreshManager.shared.settings.enableHover else { return }
        guard !popover.isShown else { return }

        hoverTimer?.invalidate()
        // Debounce before opening on hover
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.popover.isShown else { return }
                self.isPinnedByClick = false
                self.showPopover()
            }
        }
    }

    public func handleHoverExited() {
        hoverTimer?.invalidate()
        hoverTimer = nil

        // If not pinned by click, close after leaving with a delay
        if popover.isShown && !isPinnedByClick {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, !self.isPinnedByClick else { return }
                    self.closePopover()
                }
            }
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        guard popover.isShown && !isPinnedByClick else { return }

        let mouseLoc = NSEvent.mouseLocation
        if let anchorRect = currentAnchorRect ?? cachedButtonScreenRect(), anchorRect.contains(mouseLoc) {
            hoverTimer?.invalidate()
            return
        }

        if let popWindow = popover.contentViewController?.view.window, popWindow.frame.contains(mouseLoc) {
            hoverTimer?.invalidate()
            return
        }
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
        guard let button = statusItem.button else { return }
        let cachedRect = cachedButtonScreenRect()

        var resolution = MenuBarAnchor.Resolution(rect: cachedRect ?? .zero, isFallback: false)
        if Self.anchorFallbackEnabled, anchor == .pointer {
            let mouse = NSEvent.mouseLocation
            // accessory 应用的 NSScreen.main 不可靠，按鼠标所在屏幕取
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens.first
            if let screen {
                resolution = MenuBarAnchor.resolve(
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
            }
        }
        currentAnchorRect = resolution.rect
        lastShowUsedFallback = resolution.isFallback

        if resolution.isFallback, let anchorView = prepareAnchorPanel(frame: resolution.rect) {
            Log.lifecycle.debug("状态项缓存坐标过期，改用鼠标位置锚定：cached=\(NSStringFromRect(cachedRect ?? .zero)) actual=\(NSStringFromRect(resolution.rect))")
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        } else {
            // 正常路径不留辅助面板
            anchorPanel?.orderOut(nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
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

    public func togglePopoverOrOpenWindow() {
        if popover.isShown {
            closePopover()
        } else {
            isPinnedByClick = true
            // 从 Dock / Finder 重开，鼠标不在图标上，只能信任缓存坐标
            showPopover(anchor: .cached)
            if !popover.isShown {
                openSettings(tab: .openAI)
            }
        }
    }

    // MARK: - 状态项重新布局

    /// 显示器参数变化 / 唤醒后，托管在系统进程里的状态项窗口可能已被移动，
    /// 而本进程的 frame 副本只在状态项重新布局时才同步，这里主动轻推一次。
    private func observeScreenChanges() {
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.scheduleStatusItemRelayout() }
            }
            .store(in: &cancellables)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceCenter
                .publisher(for: name)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.scheduleStatusItemRelayout()
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

    /// 显示器重配置期间通知会连发多次，合并到最后一次之后再动布局
    private func scheduleStatusItemRelayout(delay: TimeInterval = 1.0) {
        relayoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.nudgeStatusItemLayout()
        }
        relayoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 用"定长 → 变长"轻推状态项，迫使 NSStatusBar 重新布局并同步托管窗口 frame。
    /// 净宽度不变，因此不产生可见跳动；弹窗打开时跳过（布局变化会让 NSPopover 重定位）。
    private func nudgeStatusItemLayout() {
        guard let statusItem = statusItem, let button = statusItem.button, !popover.isShown else { return }
        let width = button.bounds.width
        guard width > 0 else { return }
        statusItem.length = width
        statusItem.length = NSStatusItem.variableLength
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
            existing.title = "TokenBar - \(tab.title)"
            existing.contentView = NSHostingView(rootView: SettingsView(refreshManager: .shared, initialTab: tab))
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
        window.contentView = NSHostingView(rootView: SettingsView(refreshManager: .shared, initialTab: tab))
        window.isReleasedWhenClosed = false

        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - NSPopoverDelegate

extension MenuBarController: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        // 弹窗是辅助面板的子窗口，只能在它关闭之后再回收面板
        anchorPanel?.orderOut(nil)
        currentAnchorRect = nil
        if lastShowUsedFallback {
            lastShowUsedFallback = false
            // 刚刚证实缓存坐标过期，趁弹窗关闭轻推一次，争取下次回到正常路径
            if Self.screenRelayoutEnabled {
                scheduleStatusItemRelayout(delay: 0.3)
            }
        }
    }
}
