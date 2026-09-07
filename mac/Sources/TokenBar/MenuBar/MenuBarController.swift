import Cocoa
import SwiftUI

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

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hoverTimer: Timer?
    private var isPinnedByClick: Bool = false
    private var settingsWindow: NSWindow?
    private var trackingView: HoverTrackingView?

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

        // Mouse moved monitor to maintain hover when cursor is in popover or button
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMoved(event)
            }
            return event
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

        if let button = statusItem.button, let window = button.window {
            let buttonScreenRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let mouseLoc = NSEvent.mouseLocation
            if buttonScreenRect.contains(mouseLoc) {
                hoverTimer?.invalidate()
                return
            }

            if let popWindow = popover.contentViewController?.view.window {
                let popRect = popWindow.frame
                if popRect.contains(mouseLoc) {
                    hoverTimer?.invalidate()
                    return
                }
            }
        }
    }

    public func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
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
            showPopover()
            if !popover.isShown {
                openSettings(tab: .openAI)
            }
        }
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
