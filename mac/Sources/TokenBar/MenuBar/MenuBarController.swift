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

    /// 两层防护的独立开关，便于排查时单独关闭
    private static let screenRelayoutEnabled = true
    private static let anchorFallbackEnabled = true
    /// 调试键：`defaults write com.tokenbar.mac TokenBarForceAnchorFallback -bool YES` 强制走兜底路径
    private static let forceFallbackDefaultsKey = "TokenBarForceAnchorFallback"
    /// 调试键：强制把状态项判成掉线，用来验证重建链路
    private static let forceUnhealthyDefaultsKey = "TokenBarForceStatusItemUnhealthy"
    /// 调试键：不给按钮挂悬停追踪区，A/B 它是否干扰菜单栏布局
    private static let disableHoverTrackerDefaultsKey = "TokenBarDisableHoverTracker"

    private static let statusItemAutosaveName = "TokenBarStatusItem"
    private static let rebuildPolicy = StatusItemHealth.RebuildPolicy()

    /// 状态项可能被销毁重建，不能再用隐式解包
    private var statusItem: NSStatusItem?
    private var popover: NSPopover!
    private var hoverTimer: Timer?
    /// 唤醒示意弹窗的自动收回定时器（一次性）；用户点按状态项接管后取消
    private var autoDismissTimer: Timer?
    /// 状态项内容心跳定时器，teardown 场景需与悬停定时器同样对待
    private var statusItemHeartbeat: Timer?
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

    /// 状态项内容自愈心跳间隔：太久会放大空白时长，太短则频繁无谓重布局
    static let statusItemHeartbeatInterval: TimeInterval = 300
    /// 判定掉线后的快探测间隔
    static let statusItemProbeInterval: TimeInterval = 15
    /// 启动校验梯。登录自启时菜单栏服务未必就绪，隔着几档复查
    private static let launchProbeLadder: [TimeInterval] = [2, 5, 15, 60]
    /// 显示器重配置后这段时间内几何不可信，一律按 indeterminate 处理
    private static let screenReconfigureQuietWindow: TimeInterval = 3

    /// setup 的一次性部分是否已经跑过。用它而不是 `statusItem == nil` 做幂等，
    /// 否则状态项一旦重建，订阅与监听会被重复注册。
    private var didSetupOnce = false
    /// 重建要先异步清 LaunchServices 死记录，这段时间内再来的重建请求直接丢弃
    private var isRebuilding = false
    /// reopen 路径触发的重建完成后要接着弹窗；用 Optional<Optional> 区分"没有待办"与"待办且不自动收回"
    private var pendingReopenAutoDismiss: TimeInterval??
    private var healthCheckWorkItem: DispatchWorkItem?
    private var rebuildAttempts = 0
    private var consecutiveDetached = 0
    private var lastRebuildAt: Date?
    private var healthySince: Date?
    private var screenReconfigureUntil: Date?
    /// `userHidden` 只尝试一次性拉回可见，之后尊重用户意图
    private var didForceVisibleOnce = false

    private override init() {
        super.init()
    }

    deinit {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    public func setup() {
        // 幂等只看这一个标志：订阅与监听必须只注册一次，状态项本身则允许反复重建
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

        if Self.screenRelayoutEnabled {
            observeScreenChanges()
            observeStatusItemHealth()
            // 启动就把 LaunchServices 死记录清掉：等到判定掉线再清，要多白等一轮探测
            purgeStaleLaunchServicesRecords(reason: "launch") { _ in }
            // 登录自启时菜单栏服务未必已经就绪，隔着几档复查有没有真的拿到槽位
            for delay in Self.launchProbeLadder {
                scheduleHealthCheck(delay: delay, reason: "launch+\(Int(delay))s", coalescing: false)
            }
        }
    }

    // MARK: - 状态项的安装与重建

    /// 可重入：销毁旧状态项后重新安装。**这里不得出现任何订阅/监听注册**，
    /// 那些只属于 `setup()` 的一次性部分。
    private func installStatusItem(clearAutosaveState: Bool = false) {
        if clearAutosaveState {
            // 持久化位置被写坏时，带 autosaveName 重建会把坏状态一并还原回来
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "NSStatusItem Preferred Position \(Self.statusItemAutosaveName)")
            defaults.removeObject(forKey: "NSStatusItem Visible \(Self.statusItemAutosaveName)")
            Log.lifecycle.error("已清除状态项持久化位置键：autosave=\(Self.statusItemAutosaveName, privacy: .public)")
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.statusItemAutosaveName
        // 重建时显式拉回可见，避免坏的持久化可见性被沿用
        item.isVisible = true
        statusItem = item

        guard let button = item.button else {
            Log.lifecycle.error("状态项安装失败：button 为 nil，待健康检查重试")
            return
        }
        button.target = self
        button.action = #selector(statusBarButtonClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyStatusItemContent()
        installHoverTracking(on: button)
        // 刚创建时窗口还没分配，这里只如实记"装上了"，几何留给随后的健康检查判定 ——
        // 旧日志拿 `button.image != nil` 当"状态项已创建成功"是假阳性，图标看不见时它照样报成功
        Log.lifecycle.notice(
            "状态项已安装（几何待校验）：图标=\(button.image != nil ? "有" : "无", privacy: .public) clearAutosave=\(clearAutosaveState, privacy: .public)")
    }

    /// 悬停追踪区直接挂在状态项按钮上，不再往按钮里塞子视图。
    ///
    /// 早先的实现是 `button.addSubview(HoverTrackingView(...), positioned: .below)`。
    /// macOS 26 的状态项由系统进程托管布局，少往它的按钮里插东西就少一个和这套流程打架的变量；
    /// 同机另一个只 `addTrackingArea` 的菜单栏应用（vps-traffic-quota）从没出现过拿不到槽位的故障。
    /// 不过用探针单独对比过两种写法，几何都正常 —— 故障偶发，没能当场复现，
    /// 所以这是"对齐已知稳定的实现"，不是已经坐实的根因修复。
    ///
    /// `.inVisibleRect` 让 AppKit 跟着按钮 bounds 走，额度文案变宽变窄都不必重建追踪区。
    private func installHoverTracking(on button: NSStatusBarButton) {
        guard !UserDefaults.standard.bool(forKey: Self.disableHoverTrackerDefaultsKey) else {
            Log.lifecycle.notice("调试开关生效：跳过悬停追踪区安装")
            return
        }
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

    private func teardownStatusItem() {
        if let button = statusItem?.button {
            if let trackingArea {
                button.removeTrackingArea(trackingArea)
            }
            button.target = nil
            button.action = nil
            button.image = nil
        }
        trackingArea = nil
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    /// 轻推 length 治不了"状态项没拿到菜单栏槽位"这类故障（实测心跳推了多次都无效），
    /// 只能整个销毁重建。
    private func rebuildStatusItem(reason: String, clearAutosaveState: Bool) {
        guard !isRebuilding else { return }
        isRebuilding = true
        // 被 ControlCenter 拉黑的根因在 LaunchServices 死记录，不先清掉，重建多少次都一样被隐藏
        purgeStaleLaunchServicesRecords(reason: "rebuild") { [weak self] purged in
            guard let self else { return }
            self.isRebuilding = false
            self.performStatusItemRebuild(reason: reason, clearAutosaveState: clearAutosaveState, purgedRecords: purged)
        }
    }

    private func performStatusItemRebuild(reason: String, clearAutosaveState: Bool, purgedRecords: Int) {
        let before = cachedButtonScreenRect()
        // 弹窗挂在旧 button 上，先收干净再换
        if popover.isShown { closePopover() }
        anchorPanel?.orderOut(nil)

        teardownStatusItem()
        installStatusItem(clearAutosaveState: clearAutosaveState)
        updateStatusItemTitle()

        rebuildAttempts += 1
        lastRebuildAt = Date()
        consecutiveDetached = 0
        Log.lifecycle.error(
            "状态项重建：原因=\(reason, privacy: .public) 第\(self.rebuildAttempts, privacy: .public)次 clearAutosave=\(clearAutosaveState, privacy: .public) 清理LS死记录=\(purgedRecords, privacy: .public) 旧窗口=\(Self.describe(before), privacy: .public)")
        scheduleHealthCheck(delay: 1.5, reason: "post-rebuild")

        if let autoDismiss = pendingReopenAutoDismiss {
            pendingReopenAutoDismiss = nil
            // 新状态项的窗口要过一拍才有几何，稍等再弹
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.presentReopenPopover(autoDismiss: autoDismiss)
            }
        }
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
            Log.lifecycle.error("showPopover：状态项不可用，改为安排一次健康检查")
            scheduleHealthCheck(delay: 0.1, reason: "showPopover-noItem")
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

        if resolution.isFallback {
            // 锚点走兜底，本身就是状态项掉线的证据
            scheduleHealthCheck(delay: 0.1, reason: "anchorFallback")
        }

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

        // 从 Dock / Finder / `tb` 重开时鼠标不在图标上，掉线就地重建 ——
        // 顺带让这条路径成为"把不见了的图标修回来"的手段
        let verdict = StatusItemHealth.evaluate(statusItemSnapshot())
        if verdict.isDetached, rebuildAttempts < Self.rebuildPolicy.maxAttempts, !isRebuilding {
            logStatusItemState(reason: "reopen")
            pendingReopenAutoDismiss = autoDismiss
            rebuildStatusItem(reason: verdict.logDescription, clearAutosaveState: false)
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

    // MARK: - 状态项重新布局

    /// 显示器参数变化 / 唤醒后，托管在系统进程里的状态项窗口可能已被移动，
    /// 而本进程的 frame 副本只在状态项重新布局时才同步，这里主动轻推一次。
    private func observeScreenChanges() {
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // 重配置期间几何不可信，先划一段静默窗口再查
                    self.screenReconfigureUntil = Date().addingTimeInterval(Self.screenReconfigureQuietWindow)
                    self.scheduleHealthCheck(delay: 1.5, reason: "screenParams")
                }
            }
            .store(in: &cancellables)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceCenter
                .publisher(for: name)
                .sink { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        // 唤醒会连发两个通知，只清连续计数；重建预算不清零，免得反复唤醒把它刷空
                        self.consecutiveDetached = 0
                        self.scheduleHealthCheck(delay: 2.0, reason: "wake")
                        await self.refreshAfterWake()
                    }
                }
                .store(in: &cancellables)
        }
    }

    /// 状态项内容自愈。macOS 26 托管渲染可能在进程长跑期间丢掉按钮内容
    /// （位置保留、可点击，但图标与文字不再绘制）；唤醒/显示器变化由
    /// observeScreenChanges 覆盖，这里补 App 激活与低频心跳两条路径。
    private func observeStatusItemHealth() {
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.scheduleHealthCheck(delay: 0.5, reason: "didBecomeActive") }
            }
            .store(in: &cancellables)

        // 与悬停定时器同样注册到 .common mode，事件跟踪期间不被挂起。
        // 掉线期间的快探测由 runHealthCheck 自调度，这条只是低频保底闹钟。
        let heartbeat = Timer(timeInterval: Self.statusItemHeartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runHealthCheck(reason: "heartbeat")
            }
        }
        RunLoop.main.add(heartbeat, forMode: .common)
        statusItemHeartbeat = heartbeat
    }

    /// 睡眠期间定时器不 fire，唤醒后数据可能已经过期若干个周期，这里补刷一次。
    /// 两个唤醒通知会先后到达，靠 refreshIfStale 的时间判断 + refreshAll 的 isRefreshing 闸门去重。
    private func refreshAfterWake() async {
        let manager = RefreshManager.shared
        let halfInterval = Double(manager.settings.refreshIntervalMinutes * 30)
        await manager.refreshIfStale(olderThan: halfInterval)
    }

    // MARK: - 状态项健康检查

    /// 显示器重配置期间通知会连发多次，合并到最后一次之后再查。
    /// - Parameter coalescing: 启动校验梯要的是"每一档都跑"，那里传 false 各自独立排期
    private func scheduleHealthCheck(delay: TimeInterval, reason: String, coalescing: Bool = true) {
        guard coalescing else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.runHealthCheck(reason: reason)
            }
            return
        }
        healthCheckWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.runHealthCheck(reason: reason)
        }
        healthCheckWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func statusItemSnapshot() -> StatusItemHealth.Snapshot {
        let screens = NSScreen.screens.map {
            StatusItemHealth.ScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        if UserDefaults.standard.bool(forKey: Self.forceUnhealthyDefaultsKey) {
            // 调试：合成一个掉线快照，用来验证重建链路
            return StatusItemHealth.Snapshot(
                hasItem: statusItem != nil,
                hasButton: statusItem?.button != nil,
                isVisible: true,
                buttonWidth: statusItem?.button?.bounds.width ?? 0,
                windowFrame: statusItem?.button?.window?.frame,
                windowNumber: statusItem?.button?.window?.windowNumber,
                registeredInWindowServer: nil,
                mirroredByMenuBarHost: false,
                screens: screens
            )
        }
        let button = statusItem?.button
        let window = button?.window
        return StatusItemHealth.Snapshot(
            hasItem: statusItem != nil,
            hasButton: button != nil,
            isVisible: statusItem?.isVisible ?? false,
            buttonWidth: button?.bounds.width ?? 0,
            windowFrame: window?.frame,
            windowNumber: window?.windowNumber,
            registeredInWindowServer: window.flatMap { windowIsRegistered($0) },
            mirroredByMenuBarHost: window.flatMap { menuBarHostMirrors($0.frame) },
            screens: screens
        )
    }

    /// 控制中心是否为这个状态项窗口渲染了菜单栏镜像。
    ///
    /// macOS 26：每个真正显示出来的状态项，在 layer-25 层都有一个 onscreen 的控制中心窗口，
    /// 与应用自己那个离屏的状态项窗口同 x 同宽。被 ControlCenter 放进 blocked list 隐藏的
    /// 状态项没有这条镜像 —— 这是目前最可靠的健康信号，几何判定只是辅助（被 block 的状态项
    /// frame 也可能停在正常位置）。查询失败返回 nil，让该信号被忽略。
    private func menuBarHostMirrors(_ frame: NSRect) -> Bool? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 25,
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let width = bounds["Width"], let height = bounds["Height"],
                  height <= 40                                  // 只认菜单栏那一排，排除弹窗
            else { continue }
            if abs(x - frame.minX) <= 2, abs(width - frame.width) <= 2 {
                return true
            }
        }
        return false
    }

    nonisolated private static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// 清掉本 bundle id 在 LaunchServices 里指向已不存在路径的陈旧注册。
    ///
    /// 图标"消失"的真正根因：macOS 26 的 ControlCenter 按 bundle id 查 LaunchServices，只要撞上
    /// 一条路径已被删除的注册记录（换过构建输出目录、反复挂载 DMG 测安装包都会留下），就把这个
    /// bundle id 的状态项 `Moving host to blocked list` 并隐藏，重启进程、重建状态项都没用；
    /// 用 `lsregister -u` 注销死记录后，下一次注册立即恢复。这一步必须排在重建之前。
    ///
    /// 只能解析 `lsregister -dump`：`NSWorkspace.urlsForApplications(withBundleIdentifier:)`
    /// 会把不存在的路径过滤掉，拿它永远找不到死记录。dump 是全量输出（本机 ~1 秒、几十 MB），
    /// 所以放后台队列跑，完成后回主线程。
    private func purgeStaleLaunchServicesRecords(reason: String, completion: @escaping @MainActor (Int) -> Void) {
        guard let bundleID = Bundle.main.bundleIdentifier,
              FileManager.default.isExecutableFile(atPath: Self.lsregisterPath) else {
            completion(0)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let stale = Self.staleLaunchServicesPaths(bundleID: bundleID)
            var purged = 0
            for path in stale where Self.runLSRegister(["-u", path]) {
                purged += 1
            }
            let staleCount = stale.count
            Task { @MainActor in
                if staleCount > 0 {
                    Log.lifecycle.error(
                        "LaunchServices 死记录清理[\(reason, privacy: .public)]：发现 \(staleCount, privacy: .public) 条，注销 \(purged, privacy: .public) 条")
                } else {
                    Log.lifecycle.notice("LaunchServices 注册核对[\(reason, privacy: .public)]：无死记录")
                }
                completion(purged)
            }
        }
    }

    /// 跑 `lsregister -dump` 并取本 bundle id 所有注册路径里已不存在的那些。可在后台线程跑。
    nonisolated private static func staleLaunchServicesPaths(bundleID: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = ["-dump"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return staleLaunchServicesPaths(inDump: text, bundleID: bundleID) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    /// `lsregister -dump` 的纯文本解析，抽出来便于单测。
    ///
    /// 记录之间用整行 80 个 `-` 分隔；每条记录里 `identifier:` 与 `path:` 各占一行、值前有对齐空白，
    /// path 末尾带 ` (0x…)` 序号。只认本 bundle id 且路径已不存在的记录。
    nonisolated static func staleLaunchServicesPaths(
        inDump text: String,
        bundleID: String,
        fileExists: (String) -> Bool
    ) -> [String] {
        var stale: [String] = []
        var identifier: String?
        var path: String?

        func flush() {
            defer { identifier = nil; path = nil }
            guard identifier == bundleID, let path, !path.isEmpty, !fileExists(path) else { return }
            stale.append(path)
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.count >= 20, line.allSatisfy({ $0 == "-" }) {
                flush()
            } else if line.hasPrefix("identifier:") {
                identifier = line.dropFirst("identifier:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("path:") {
                var value = line.dropFirst("path:".count).trimmingCharacters(in: .whitespaces)
                if value.hasSuffix(")"), let range = value.range(of: " (0x", options: .backwards) {
                    value = String(value[..<range.lowerBound])
                }
                path = value
            }
        }
        flush()
        return stale
    }

    nonisolated private static func runLSRegister(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 按窗口号反查 CGWindowList。
    ///
    /// 只查自己的窗口号、只读 bounds（`kCGWindowName` 才需要屏幕录制权限），查不了就返回 nil
    /// 让这个信号被忽略。**绝不能看 `kCGWindowIsOnscreen`** —— macOS 26 上健康的第三方状态项
    /// 自己的窗口也是 offscreen，真正上屏的是控制中心的镜像窗口。
    private func windowIsRegistered(_ window: NSWindow) -> Bool? {
        guard window.windowNumber > 0 else { return false }
        // macOS 26 上状态项窗口托管在系统进程，本进程拿到的 windowNumber 是个超出
        // CGWindowID(UInt32) 范围的占位值（实测健康状态项为 4294967296 = 2^32）。
        // 这种窗口号查不了窗口服务器，返回 nil 让该信号被忽略 ——
        // 当成 false 会把健康的状态项判成掉线、反复重建。
        guard window.windowNumber <= Int(UInt32.max) else { return nil }

        // 全量枚举再按窗口号过滤，而不是带 on-screen 语义的查询：
        // 状态项窗口本身是离屏的，只有控制中心的镜像窗口才上屏。
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        for info in list {
            guard let number = info[kCGWindowNumber as String] as? Int,
                  number == window.windowNumber else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"] else { return false }
            return width > 0 && height > 0
        }
        return false
    }

    private func runHealthCheck(reason: String) {
        // 误判闸门：弹窗/右键菜单开着，或鼠标按着（可能正在拖图标），这时的几何都不作数
        guard !popover.isShown, statusItem?.menu == nil, NSEvent.pressedMouseButtons == 0 else {
            scheduleHealthCheck(delay: 5, reason: "deferred-\(reason)")
            return
        }
        if let until = screenReconfigureUntil, Date() < until {
            scheduleHealthCheck(delay: Self.statusItemProbeInterval, reason: "reconfiguring-\(reason)")
            return
        }
        screenReconfigureUntil = nil

        let snapshot = statusItemSnapshot()
        let verdict = StatusItemHealth.evaluate(snapshot)
        logStatusItemState(reason: reason, snapshot: snapshot, verdict: verdict)

        switch verdict {
        case .indeterminate:
            scheduleHealthCheck(delay: Self.statusItemProbeInterval, reason: "indeterminate")

        case .userHidden:
            consecutiveDetached = 0
            if !didForceVisibleOnce {
                didForceVisibleOnce = true
                statusItem?.isVisible = true
                Log.lifecycle.error("状态项 isVisible=false（疑似被拖出菜单栏），一次性尝试恢复可见后不再干预")
            }

        case .healthy:
            consecutiveDetached = 0
            if healthySince == nil { healthySince = Date() }
            if Self.rebuildPolicy.shouldResetAttempts(now: Date(), healthySince: healthySince) {
                rebuildAttempts = 0
            }
            // 内容幂等重刷仍然保留：它治的是"位置还在、图标不画了"那种托管渲染丢失
            nudgeStatusItemLayout()

        case .detached:
            healthySince = nil
            consecutiveDetached += 1
            let decision = Self.rebuildPolicy.decide(
                verdict: verdict,
                consecutiveDetached: consecutiveDetached,
                attempts: rebuildAttempts,
                now: Date(),
                lastRebuildAt: lastRebuildAt
            )
            switch decision {
            case .wait(let seconds):
                scheduleHealthCheck(delay: max(seconds, Self.statusItemProbeInterval), reason: "backoff")
            case .rebuild:
                rebuildStatusItem(reason: verdict.logDescription, clearAutosaveState: false)
            case .resetAutosaveThenRebuild:
                rebuildStatusItem(reason: verdict.logDescription, clearAutosaveState: true)
            case .giveUp:
                Log.lifecycle.error(
                    "状态项重建预算耗尽（\(self.rebuildAttempts, privacy: .public) 次），停止自愈")
            }
        }
    }

    private static func describe(_ rect: NSRect?) -> String {
        guard let rect else { return "nil" }
        return String(format: "%.0f,%.0f %.0fx%.0f", rect.minX, rect.minY, rect.width, rect.height)
    }

    private func logStatusItemState(
        reason: String,
        snapshot: StatusItemHealth.Snapshot? = nil,
        verdict: StatusItemHealth.Verdict? = nil
    ) {
        let snapshot = snapshot ?? statusItemSnapshot()
        let verdict = verdict ?? StatusItemHealth.evaluate(snapshot)
        let registered = snapshot.registeredInWindowServer.map(String.init(describing:)) ?? "?"
        let mirrored = snapshot.mirroredByMenuBarHost.map(String.init(describing:)) ?? "?"
        let line = "状态项[\(reason)] verdict=\(verdict.logDescription) visible=\(snapshot.isVisible) btnW=\(Int(snapshot.buttonWidth)) win=\(Self.describe(snapshot.windowFrame)) winNum=\(snapshot.windowNumber ?? -1) mirror=\(mirrored) reg=\(registered) screens=\(snapshot.screens.count) rebuilds=\(rebuildAttempts) detachedRun=\(consecutiveDetached)"
        if case .healthy = verdict {
            Log.lifecycle.info("\(line, privacy: .public)")
        } else {
            Log.lifecycle.error("\(line, privacy: .public)")
        }
    }

    /// 用"定长 → 变长"轻推状态项，迫使 NSStatusBar 重新布局并同步托管窗口 frame。
    /// 净宽度不变，因此不产生可见跳动；弹窗打开时跳过（布局变化会让 NSPopover 重定位）。
    /// 轻推前先幂等重刷按钮内容：macOS 26 托管渲染丢失内容时，单纯重布局不足以重画图标与文字。
    ///
    /// 它治的只是"位置还在、图标不画了"。状态项压根没拿到菜单栏槽位时轻推无效
    /// （实测 300s 心跳推了多次都救不回来），那种故障归 rebuildStatusItem 管。
    private func nudgeStatusItemLayout() {
        guard let statusItem = statusItem, let button = statusItem.button, !popover.isShown else { return }
        applyStatusItemContent()
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
        // 复查一次：lastShowUsedFallback 时争取下次回到正常锚点路径；
        // 健康分支里还会幂等重刷按钮内容（macOS 26 托管渲染可能在弹窗期间丢内容）
        if Self.screenRelayoutEnabled {
            scheduleHealthCheck(delay: 0.3, reason: "popoverClosed")
        }
        lastShowUsedFallback = false
    }
}
