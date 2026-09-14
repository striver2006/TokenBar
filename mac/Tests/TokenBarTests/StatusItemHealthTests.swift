import XCTest
@testable import TokenBar

/// 状态项健康判定与重建退避。
///
/// 几何取自 macOS 26.6.2 / 3440×1440 单屏的真机实测。
///
/// 健康基线是用一个独立探针程序量到的 AppKit frame `(2661, 1410, 80, 30)` ——
/// maxY 正好贴齐屏幕顶边，`visibleFrame.maxY = 1410`、菜单栏带高 30。
/// 故障态的 TokenBar 由辅助功能 API 读到 `(3332, −1, 109, 24)`，换算后右边缘与顶边都越出屏幕。
final class StatusItemHealthTests: XCTestCase {

    /// 实测：菜单栏带高 30，visibleFrame 顶边 1410
    private let mainScreen = StatusItemHealth.ScreenGeometry(
        frame: NSRect(x: 0, y: 0, width: 3440, height: 1440),
        visibleFrame: NSRect(x: 0, y: 80, width: 3440, height: 1330)
    )
    /// 健康状态项窗口的 AppKit frame（探针实测）
    private let healthyRect = NSRect(x: 2661, y: 1410, width: 80, height: 30)
    /// 线上故障态：顶边与右边缘都越出屏幕
    private let detachedRect = NSRect(x: 3332, y: 1417, width: 109, height: 24)

    private func makeSnapshot(
        hasItem: Bool = true,
        hasButton: Bool = true,
        isVisible: Bool = true,
        buttonWidth: CGFloat = 80,
        windowFrame: NSRect? = nil,
        windowNumber: Int? = 4096,
        registeredInWindowServer: Bool? = true,
        mirrored: Bool? = true,
        screens: [StatusItemHealth.ScreenGeometry]? = nil
    ) -> StatusItemHealth.Snapshot {
        StatusItemHealth.Snapshot(
            hasItem: hasItem,
            hasButton: hasButton,
            isVisible: isVisible,
            buttonWidth: buttonWidth,
            windowFrame: windowFrame ?? healthyRect,
            windowNumber: windowNumber,
            registeredInWindowServer: registeredInWindowServer,
            mirroredByMenuBarHost: mirrored,
            screens: screens ?? [mainScreen]
        )
    }

    // MARK: - evaluate

    func testHealthyBaseline() {
        XCTAssertEqual(StatusItemHealth.evaluate(makeSnapshot()), .healthy)
    }

    /// 几何看着正常，但窗口没在窗口服务器注册 —— 图标一样看不见
    func testDetachedWhenNotRegisteredInWindowServer() {
        let snapshot = makeSnapshot(registeredInWindowServer: false)
        XCTAssertEqual(StatusItemHealth.evaluate(snapshot), .detached(.notRegistered))
    }

    /// 线上故障态：几何判定必须能独立命中，不依赖窗口服务器那条信号
    /// （maxY = 1441 越出屏幕顶边、maxX = 3441 越出右边界）
    func testDetachedByGeometryAloneWhenWindowServerSignalUnavailable() {
        for signal in [nil, true, false] as [Bool?] {
            let snapshot = makeSnapshot(windowFrame: detachedRect, registeredInWindowServer: signal)
            XCTAssertEqual(
                StatusItemHealth.evaluate(snapshot), .detached(.offMenuBar),
                "reg=\(String(describing: signal)) 时几何判定应优先命中"
            )
        }
    }

    /// 查不到窗口服务器（无权限 / API 变化）绝不能当成掉线
    func testUnavailableWindowServerSignalNeverCausesDetach() {
        XCTAssertEqual(StatusItemHealth.evaluate(makeSnapshot(registeredInWindowServer: nil)), .healthy)
        XCTAssertEqual(StatusItemHealth.evaluate(makeSnapshot(mirrored: nil)), .healthy)
    }

    /// 真正的根因形态：几何停在正常位置、窗口也在，但控制中心没为它画镜像
    /// （探针实测：LS 死记录导致被 blocked list 隐藏时 frame=2634 而 mirror=false）
    func testDetachedWhenMenuBarHostDoesNotMirror() {
        XCTAssertEqual(StatusItemHealth.evaluate(makeSnapshot(mirrored: false)), .detached(.notMirrored))
        // 镜像信号优先于窗口服务器注册信号
        XCTAssertEqual(
            StatusItemHealth.evaluate(makeSnapshot(registeredInWindowServer: false, mirrored: false)),
            .detached(.notMirrored)
        )
    }

    func testDetachedWhenWindowMissing() {
        // makeSnapshot 的 windowFrame 默认值会兜成 healthyRect，这里直接构造
        let snapshot = StatusItemHealth.Snapshot(
            hasItem: true, hasButton: true, isVisible: true, buttonWidth: 80,
            windowFrame: nil, windowNumber: 4096, registeredInWindowServer: true,
            screens: [mainScreen]
        )
        XCTAssertEqual(StatusItemHealth.evaluate(snapshot), .detached(.noWindow))
    }

    func testDetachedWhenWindowNumberIsZero() {
        XCTAssertEqual(StatusItemHealth.evaluate(makeSnapshot(windowNumber: 0)), .detached(.zeroWindowNumber))
    }

    func testDetachedWhenWindowSizeIsZero() {
        let snapshot = makeSnapshot(windowFrame: NSRect(x: 2661, y: 1410, width: 0, height: 0))
        XCTAssertEqual(StatusItemHealth.evaluate(snapshot), .detached(.zeroWindowSize))
    }

    func testDetachedWhenButtonWidthIsZero() {
        XCTAssertEqual(StatusItemHealth.evaluate(makeSnapshot(buttonWidth: 0)), .detached(.zeroButtonWidth))
    }

    func testDetachedWhenWindowSitsInScreenMiddle() {
        let snapshot = makeSnapshot(windowFrame: NSRect(x: 1720, y: 700, width: 80, height: 30))
        XCTAssertEqual(StatusItemHealth.evaluate(snapshot), .detached(.offMenuBar))
    }

    func testNoItemAndNoButton() {
        XCTAssertEqual(StatusItemHealth.evaluate(makeSnapshot(hasItem: false)), .detached(.noItem))
        XCTAssertEqual(StatusItemHealth.evaluate(makeSnapshot(hasButton: false)), .detached(.noButton))
    }

    /// isVisible 必须排在所有几何判定之前：用户 Cmd 拖走不该被当成故障重建
    func testUserHiddenTakesPrecedenceOverGeometry() {
        XCTAssertEqual(StatusItemHealth.evaluate(makeSnapshot(isVisible: false)), .userHidden)

        let hiddenAndDetached = StatusItemHealth.Snapshot(
            hasItem: true, hasButton: true, isVisible: false, buttonWidth: 0,
            windowFrame: nil, windowNumber: 0, registeredInWindowServer: false,
            screens: [mainScreen]
        )
        XCTAssertEqual(StatusItemHealth.evaluate(hiddenAndDetached), .userHidden)
    }

    /// 熄屏 / 显示器重配置中途：绝不在这时重建
    func testIndeterminateWhenNoScreens() {
        XCTAssertEqual(StatusItemHealth.evaluate(makeSnapshot(screens: [])), .indeterminate)
    }

    func testHealthyOnSecondaryScreen() {
        let secondary = StatusItemHealth.ScreenGeometry(
            frame: NSRect(x: 3440, y: 200, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 3440, y: 200, width: 1920, height: 1055)
        )
        let snapshot = makeSnapshot(
            windowFrame: NSRect(x: 4000, y: 1254, width: 80, height: 22),
            screens: [mainScreen, secondary]
        )
        XCTAssertEqual(StatusItemHealth.evaluate(snapshot), .healthy)
    }

    /// 带下边界：菜单栏带高 30 + 松弛 8 → 最低允许 maxY = 1402
    func testMenuBarBandBottomBoundary() {
        let inside = makeSnapshot(windowFrame: NSRect(x: 2661, y: 1380, width: 80, height: 22))
        XCTAssertEqual(StatusItemHealth.evaluate(inside), .healthy)

        let outside = makeSnapshot(windowFrame: NSRect(x: 2661, y: 1379, width: 80, height: 22))
        XCTAssertEqual(StatusItemHealth.evaluate(outside), .detached(.offMenuBar))
    }

    /// 健康态 maxY 正好等于屏幕顶边，只有真越出去才算掉线
    func testMenuBarBandTopBoundary() {
        XCTAssertEqual(StatusItemHealth.evaluate(makeSnapshot()), .healthy)

        let overshoot = makeSnapshot(windowFrame: NSRect(x: 2661, y: 1412, width: 80, height: 30))
        XCTAssertEqual(StatusItemHealth.evaluate(overshoot), .detached(.offMenuBar))
    }

    /// 右边缘越出屏幕 —— 故障态的另一个特征
    func testMenuBarBandRightBoundary() {
        let overshoot = makeSnapshot(windowFrame: NSRect(x: 3361, y: 1410, width: 80, height: 30))
        XCTAssertEqual(StatusItemHealth.evaluate(overshoot), .detached(.offMenuBar))
    }

    // MARK: - RebuildPolicy

    private let policy = StatusItemHealth.RebuildPolicy()

    private func decide(
        _ verdict: StatusItemHealth.Verdict = .detached(.offMenuBar),
        detachedRun: Int = 2,
        attempts: Int = 0,
        secondsSinceLastRebuild: TimeInterval? = nil
    ) -> StatusItemHealth.RebuildPolicy.Decision {
        let now = Date()
        return policy.decide(
            verdict: verdict,
            consecutiveDetached: detachedRun,
            attempts: attempts,
            now: now,
            lastRebuildAt: secondsSinceLastRebuild.map { now.addingTimeInterval(-$0) }
        )
    }

    func testPolicyWaitsWhenHealthy() {
        XCTAssertEqual(decide(.healthy), .wait(0))
        XCTAssertEqual(decide(.userHidden), .wait(0))
        XCTAssertEqual(decide(.indeterminate), .wait(0))
    }

    func testPolicyNeedsConsecutiveConfirmations() {
        XCTAssertEqual(decide(detachedRun: 1), .wait(0))
        XCTAssertEqual(decide(detachedRun: 2), .rebuild)
    }

    func testPolicyBackoffGrowsExponentially() {
        // attempts=1 → 30s 窗口
        guard case .wait(let first) = decide(attempts: 1, secondsSinceLastRebuild: 10) else {
            return XCTFail("应仍在退避窗口内")
        }
        XCTAssertEqual(first, 20, accuracy: 0.5)
        XCTAssertEqual(decide(attempts: 1, secondsSinceLastRebuild: 31), .rebuild)

        // attempts=2 → 60s，attempts=3 → 120s
        guard case .wait(let second) = decide(attempts: 2, secondsSinceLastRebuild: 10) else {
            return XCTFail("应仍在退避窗口内")
        }
        XCTAssertEqual(second, 50, accuracy: 0.5)
        guard case .wait(let third) = decide(attempts: 3, secondsSinceLastRebuild: 10) else {
            return XCTFail("应仍在退避窗口内")
        }
        XCTAssertEqual(third, 110, accuracy: 0.5)
    }

    func testPolicyLastAttemptClearsAutosaveThenGivesUp() {
        XCTAssertEqual(decide(attempts: 4, secondsSinceLastRebuild: 300), .resetAutosaveThenRebuild)
        XCTAssertEqual(decide(attempts: 5, secondsSinceLastRebuild: 900), .giveUp)
    }

    func testPolicyResetsAttemptsAfterStablePeriod() {
        let now = Date()
        XCTAssertTrue(policy.shouldResetAttempts(now: now, healthySince: now.addingTimeInterval(-601)))
        XCTAssertFalse(policy.shouldResetAttempts(now: now, healthySince: now.addingTimeInterval(-599)))
        XCTAssertFalse(policy.shouldResetAttempts(now: now, healthySince: nil))
    }
}

/// `lsregister -dump` 解析：找出本 bundle id 下路径已不存在的陈旧注册。
/// 样本照抄真实 dump 的格式（80 个 `-` 分隔、字段值前对齐空白、path 末尾 ` (0x…)` 序号）。
final class LaunchServicesDumpParsingTests: XCTestCase {
    private let separator = String(repeating: "-", count: 80)

    private func record(identifier: String, path: String, seq: String) -> String {
        """
        \(separator)
        container:                  / (0x4)
        path:                       \(path) (\(seq))
        identifier:                 \(identifier)
        version:                    1.0 ({length = 32, bytes = 0x01000000 ... })
        executable:                 Contents/MacOS/TokenBar
        type code:                  'APPL' (4150504c)
        """
    }

    private var sampleDump: String {
        [
            "Checking data integrity......done.",
            record(identifier: "com.tokenbar.mac", path: "/Applications/TokenBar.app", seq: "0x4654"),
            record(identifier: "com.tokenbar.mac", path: "/Users/chenzhenbo/Work/TokenBar/build/TokenBar.app", seq: "0x2ecc"),
            record(identifier: "com.unidrop.client", path: "/Volumes/dmg.Qj9lpz/UniDrop.app", seq: "0x3e7c"),
            record(identifier: "com.tokenbar.mac", path: "/Users/chenzhenbo/Work/TokenBar/mac/build/TokenBar.app", seq: "0x45ec"),
            separator,
        ].joined(separator: "\n")
    }

    func testFindsOnlyOwnBundleStalePaths() {
        let existing: Set<String> = ["/Applications/TokenBar.app", "/Users/chenzhenbo/Work/TokenBar/mac/build/TokenBar.app"]
        let stale = MenuBarController.staleLaunchServicesPaths(inDump: sampleDump, bundleID: "com.tokenbar.mac") {
            existing.contains($0)
        }
        // UniDrop 的死记录不是我们的，不能碰；序号后缀必须被剥掉
        XCTAssertEqual(stale, ["/Users/chenzhenbo/Work/TokenBar/build/TokenBar.app"])
    }

    func testReturnsEmptyWhenAllPathsExist() {
        let stale = MenuBarController.staleLaunchServicesPaths(inDump: sampleDump, bundleID: "com.tokenbar.mac") { _ in true }
        XCTAssertTrue(stale.isEmpty)
    }

    func testHandlesPathWithSpacesAndNoTrailingSeparator() {
        let dump = record(identifier: "com.unidrop.client", path: "/Volumes/UniDrop 1/UniDrop.app", seq: "0x411c")
        let stale = MenuBarController.staleLaunchServicesPaths(inDump: dump, bundleID: "com.unidrop.client") { _ in false }
        XCTAssertEqual(stale, ["/Volumes/UniDrop 1/UniDrop.app"])
    }
}
