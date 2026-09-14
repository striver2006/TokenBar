import Foundation

/// 状态项"还在不在菜单栏上"的判定，以及判定为掉线后的重建退避策略。
///
/// 起因（macOS 26.6.2 / 3440×1440 实测）：状态项对象活着、内容完好
/// （`AXEnabled=true`、`AXTitle=" 100%/65%"`、tooltip 正常），但控制中心没有为它
/// 渲染菜单栏镜像，几何常停在 `(3332, 1417, 109, 24)`（右边缘越出屏幕），用户就"看不到图标"。
///
/// 根因不在应用代码：macOS 26 的 ControlCenter 维护一份持久的「应用菜单栏项」记录
/// （系统设置 › 菜单栏 › 应用程序），本应用的 bundle id 一旦被记在某条开关已关的记录名下
/// （2026-09-14 实测：从 IDE 终端直接执行可执行文件，会被记到 IDE 名下），每个新 host 创建后
/// ~20ms 就 `Moving host to blocked list` 并隐藏。应用侧无法解除，只能识别并指引用户去系统设置。
/// 所以最可靠的健康信号是**控制中心有没有为它画镜像**（layer-25、onscreen 的控制中心窗口）；
/// 几何判定只是辅助 —— 被 block 的状态项 frame 也可能停在正常位置。
/// `button.window == nil` / 宽度为 0 这两个信号在这种故障态下都不成立，单靠它们会漏判。
///
/// 全部为纯函数，几何由调用方采样后传入，便于单测。
public enum StatusItemHealth {

    /// 一块屏幕的几何，避免纯函数依赖 NSScreen
    public struct ScreenGeometry: Equatable {
        public let frame: NSRect
        public let visibleFrame: NSRect

        public init(frame: NSRect, visibleFrame: NSRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    /// 由 MenuBarController 从 AppKit 采样得到的状态项快照
    public struct Snapshot: Equatable {
        public let hasItem: Bool
        public let hasButton: Bool
        /// `NSStatusItem.isVisible`
        public let isVisible: Bool
        public let buttonWidth: CGFloat
        /// `button.window?.frame`（AppKit 屏幕坐标）；window 为 nil 时传 nil
        public let windowFrame: NSRect?
        /// `button.window?.windowNumber`；≤ 0 表示窗口从未被窗口服务器接管
        public let windowNumber: Int?
        /// 控制中心是否为它渲染了菜单栏镜像（layer-25、onscreen 的控制中心窗口，按 autosaveName 或几何匹配）。
        /// 这是 macOS 26 上最可靠的信号；**无法查询时传 nil，该信号被忽略**。
        public let mirroredByMenuBarHost: Bool?
        public let screens: [ScreenGeometry]

        public init(
            hasItem: Bool,
            hasButton: Bool,
            isVisible: Bool,
            buttonWidth: CGFloat,
            windowFrame: NSRect?,
            windowNumber: Int?,
            mirroredByMenuBarHost: Bool? = nil,
            screens: [ScreenGeometry]
        ) {
            self.hasItem = hasItem
            self.hasButton = hasButton
            self.isVisible = isVisible
            self.buttonWidth = buttonWidth
            self.windowFrame = windowFrame
            self.windowNumber = windowNumber
            self.mirroredByMenuBarHost = mirroredByMenuBarHost
            self.screens = screens
        }
    }

    public enum Reason: String, Equatable {
        case noItem
        case noButton
        case noWindow
        case zeroWindowNumber
        case zeroWindowSize
        case zeroButtonWidth
        case offMenuBar
        /// 控制中心没有为它渲染镜像 —— 典型就是被 blocked list 隐藏
        case notMirrored
    }

    public enum Verdict: Equatable {
        case healthy
        /// `isVisible == false`：用户 Cmd 拖走或历史持久化状态。**不重建** —— 重建会覆盖用户意图。
        case userHidden
        /// 掉线，需要重建
        case detached(Reason)
        /// 无屏幕 / 正在重配置：本轮跳过，且不计入连续掉线计数
        case indeterminate

        public var isDetached: Bool {
            if case .detached = self { return true }
            return false
        }

        public var logDescription: String {
            switch self {
            case .healthy: return "healthy"
            case .userHidden: return "userHidden"
            case .indeterminate: return "indeterminate"
            case .detached(let reason): return "detached(\(reason.rawValue))"
            }
        }
    }

    /// 判定顺序即优先级，不要调整：
    /// `isVisible` 必须排在所有几何判定之前，否则用户主动隐藏会被当成故障反复重建。
    public static func evaluate(_ snapshot: Snapshot) -> Verdict {
        // 熄屏 / 显示器重配置中途，几何不可信，绝不在这时重建
        guard !snapshot.screens.isEmpty else { return .indeterminate }

        guard snapshot.hasItem else { return .detached(.noItem) }
        guard snapshot.hasButton else { return .detached(.noButton) }

        guard snapshot.isVisible else { return .userHidden }

        guard let frame = snapshot.windowFrame else { return .detached(.noWindow) }
        guard (snapshot.windowNumber ?? 0) > 0 else { return .detached(.zeroWindowNumber) }
        guard frame.width > 0, frame.height > 0 else { return .detached(.zeroWindowSize) }
        guard snapshot.buttonWidth > 0 else { return .detached(.zeroButtonWidth) }

        // 几何判定在前：它只依赖 AppKit 自己的数字，不依赖任何跨进程查询。
        // 本次线上故障（maxY 越出屏幕顶边、maxX 越出右边界）单靠几何就能命中。
        let onMenuBar = snapshot.screens.contains { screen in
            MenuBarAnchor.isInMenuBarBand(
                frame,
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        guard onMenuBar else { return .detached(.offMenuBar) }

        // 几何看着正常，但控制中心没为它画镜像 —— 图标一样是看不见的。
        // nil = 查不了（无权限 / API 变化），忽略该信号，绝不因为查不到就判掉线。
        if snapshot.mirroredByMenuBarHost == false { return .detached(.notMirrored) }

        return .healthy
    }

    /// 重建退避。重建会让图标闪一下、并可能改变它在菜单栏里的排序，
    /// 所以要连续确认、指数退避、总次数封顶，宁可晚修也不要抖动。
    public struct RebuildPolicy: Equatable {
        /// 连续几次判定掉线才真正动手
        public var confirmations: Int
        /// 单次运行的重建预算
        public var maxAttempts: Int
        /// `notMirrored`（几何正常、控制中心不画镜像）的重建预算。这种掉线绝大多数是被系统
        /// 「菜单栏 › 应用程序」设置拉黑，重建只会让 ControlCenter 再拉黑一次并重写偏好，
        /// 所以只试一次证明不是偶发，之后交给 `blockedBySystem` 去提示用户。
        public var notMirroredAttempts: Int
        /// 退避基数：30 / 60 / 120 / 240 …
        public var baseInterval: TimeInterval
        public var maxInterval: TimeInterval
        /// 连续健康这么久之后，重建预算清零
        public var stableResetWindow: TimeInterval

        public init(
            confirmations: Int = 2,
            maxAttempts: Int = 5,
            notMirroredAttempts: Int = 1,
            baseInterval: TimeInterval = 30,
            maxInterval: TimeInterval = 900,
            stableResetWindow: TimeInterval = 600
        ) {
            self.confirmations = confirmations
            self.maxAttempts = maxAttempts
            self.notMirroredAttempts = notMirroredAttempts
            self.baseInterval = baseInterval
            self.maxInterval = maxInterval
            self.stableResetWindow = stableResetWindow
        }

        public enum Decision: Equatable {
            /// 还没到确认次数，或还在退避窗口内；调用方自行与探测间隔取 max
            case wait(TimeInterval)
            case rebuild
            /// 预算最后一次：先清掉 autosave 的位置/可见性键再重建。
            /// 没有这一档的话，持久化位置被写坏时带 autosaveName 重建会一直把坏状态还原回来。
            case resetAutosaveThenRebuild
            case giveUp
            /// 几何正常但控制中心不画镜像，且已经重建过一次仍然如此：判定为被系统
            /// 「菜单栏 › 应用程序」设置拉黑。不再重建，调用方应提示用户去系统设置解除，
            /// 并继续低频探测 —— 用户在设置里放行后 ControlCenter 会就地 `Unblocking host`，无需重建。
            case blockedBySystem
        }

        /// 该判定下还允不允许重建（reopen 路径等不走 decide 的地方用它，避免把 notMirrored 重建 5 次）
        public func allowsRebuild(verdict: Verdict, attempts: Int) -> Bool {
            guard verdict.isDetached else { return false }
            return attempts < attemptBudget(for: verdict)
        }

        private func attemptBudget(for verdict: Verdict) -> Int {
            if case .detached(.notMirrored) = verdict { return min(notMirroredAttempts, maxAttempts) }
            return maxAttempts
        }

        public func decide(
            verdict: Verdict,
            consecutiveDetached: Int,
            attempts: Int,
            now: Date,
            lastRebuildAt: Date?
        ) -> Decision {
            guard verdict.isDetached else { return .wait(0) }
            guard consecutiveDetached >= confirmations else { return .wait(0) }
            if case .detached(.notMirrored) = verdict, attempts >= attemptBudget(for: verdict) {
                return .blockedBySystem
            }
            guard attempts < maxAttempts else { return .giveUp }

            if attempts > 0, let last = lastRebuildAt {
                let window = min(baseInterval * pow(2, Double(attempts - 1)), maxInterval)
                let elapsed = now.timeIntervalSince(last)
                if elapsed < window {
                    return .wait(window - elapsed)
                }
            }

            return attempts == maxAttempts - 1 ? .resetAutosaveThenRebuild : .rebuild
        }

        /// 连续健康够久 → 把重建预算还回去
        public func shouldResetAttempts(now: Date, healthySince: Date?) -> Bool {
            guard let healthySince else { return false }
            return now.timeIntervalSince(healthySince) >= stableResetWindow
        }
    }
}
