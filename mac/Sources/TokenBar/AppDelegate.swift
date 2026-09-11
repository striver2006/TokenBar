import Cocoa
import Combine

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()
    private var activityToken: NSObjectProtocol?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure app runs as an accessory menu bar application without Dock icon
        NSApp.setActivationPolicy(.accessory)

        // 没有窗口的 accessory 进程会被 App Nap 降频，定时刷新的间隔会被拉长到不可预期。
        // 只声明 .background，不阻止系统休眠。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .background,
            reason: "Periodic quota refresh"
        )

        // Setup standard system Edit menu to enable Cmd+C, Cmd+V, Cmd+X, Cmd+A, Cmd+Z
        setupMainMenu()

        // Setup the Menu Bar status item and popover
        MenuBarController.shared.setup()

        Log.lifecycle.notice("TokenBar 启动，refreshInterval=\(RefreshManager.shared.settings.refreshIntervalMinutes, privacy: .public)min")

        // 用户再次启动 TokenBar 时，第二个实例退出前会发该通知，这里弹出面板示意"我在这"
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(SingleInstanceGuard.activateNotificationName),
            object: Bundle.main.bundleIdentifier,
            queue: nil
        ) { _ in
            Log.lifecycle.notice("收到第二实例启动通知，弹出面板")
            Task { @MainActor in
                MenuBarController.shared.togglePopoverOrOpenWindow()
            }
        }

        LocalizationManager.shared.$currentLanguage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.setupMainMenu()
            }
            .store(in: &cancellables)
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            MenuBarController.shared.togglePopoverOrOpenWindow()
        }
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // 1. App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: I18n(.menuAbout), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: I18n(.menuHide), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: I18n(.menuHideOthers), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: I18n(.menuShowAll), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: I18n(.menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. Edit Menu (Crucial for Cmd+C, Cmd+V, Cmd+X, Cmd+A, Cmd+Z)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: I18n(.menuEdit))

        let undoItem = NSMenuItem(title: I18n(.menuUndo), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: I18n(.menuRedo), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(redoItem)

        editMenu.addItem(NSMenuItem.separator())

        let cutItem = NSMenuItem(title: I18n(.menuCut), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(title: I18n(.menuCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: I18n(.menuPaste), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(title: I18n(.menuSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(selectAllItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // 3. Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: I18n(.menuWindow))
        windowMenu.addItem(withTitle: I18n(.menuMinimize), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: I18n(.menuCloseWindow), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
