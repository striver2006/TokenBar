import XCTest
import SwiftUI
@testable import TokenBar

final class MenuBarAnchorTests: XCTestCase {
    // MARK: - 弹窗锚点解析

    /// 3440×1440 单屏，菜单栏高 25
    private let anchorScreen = NSRect(x: 0, y: 0, width: 3440, height: 1440)

    private let anchorVisible = NSRect(x: 0, y: 80, width: 3440, height: 1335)

    /// 状态项按钮真实位置（缓存正确时）
    private let anchorButton = NSRect(x: 2815, y: 1415, width: 109, height: 25)

    private func resolveAnchor(
        cached: NSRect?,
        mouse: NSPoint,
        screen: NSRect? = nil,
        visible: NSRect? = nil
    ) -> MenuBarAnchor.Resolution {
        MenuBarAnchor.resolve(
            cachedButtonRect: cached,
            mouseLocation: mouse,
            screenFrame: screen ?? anchorScreen,
            visibleFrame: visible ?? anchorVisible
        )
    }

    func testMenuBarAnchorUsesCachedRectWhenMouseInside() {
        let result = resolveAnchor(cached: anchorButton, mouse: NSPoint(x: 2870, y: 1428))
        XCTAssertEqual(result, MenuBarAnchor.Resolution(rect: anchorButton, isFallback: false))
    }

    func testMenuBarAnchorToleranceAllowsSlightlyOutside() {
        // 越出 1pt（容差 2）仍信任缓存
        let inside = resolveAnchor(cached: anchorButton, mouse: NSPoint(x: 2925, y: 1428))
        XCTAssertFalse(inside.isFallback)
        XCTAssertEqual(inside.rect, anchorButton)

        // 越出 3pt 判定过期
        let outside = resolveAnchor(cached: anchorButton, mouse: NSPoint(x: 2927, y: 1428))
        XCTAssertTrue(outside.isFallback)
    }

    func testMenuBarAnchorFallsBackWhenCachedRectIsStale() {
        // 复现线上故障：缓存停留在 1080p 布局，鼠标实际在 3440 宽屏的图标上
        let stale = NSRect(x: 1815, y: 1055, width: 109, height: 25)
        let result = resolveAnchor(cached: stale, mouse: NSPoint(x: 2870, y: 1428))
        XCTAssertTrue(result.isFallback)
        XCTAssertEqual(result.rect, NSRect(x: 2815.5, y: 1415, width: 109, height: 25))
    }

    func testMenuBarAnchorFallbackClampsToScreenEdges() {
        let stale = NSRect(x: 100, y: 100, width: 109, height: 25)
        let right = resolveAnchor(cached: stale, mouse: NSPoint(x: 3435, y: 1428))
        XCTAssertTrue(right.isFallback)
        XCTAssertEqual(right.rect.maxX, 3440)

        let left = resolveAnchor(cached: stale, mouse: NSPoint(x: 5, y: 1428))
        XCTAssertTrue(left.isFallback)
        XCTAssertEqual(left.rect.minX, 0)
    }

    func testMenuBarAnchorFallbackUsesDefaultHeightWhenMenuBarHidden() {
        let stale = NSRect(x: 100, y: 100, width: 109, height: 25)
        // 菜单栏隐藏：visibleFrame 顶边与屏幕顶边齐平
        let hiddenVisible = NSRect(x: 0, y: 80, width: 3440, height: 1360)
        let result = MenuBarAnchor.resolve(
            cachedButtonRect: stale,
            mouseLocation: NSPoint(x: 2870, y: 1430),
            screenFrame: anchorScreen,
            visibleFrame: hiddenVisible,
            defaultMenuBarHeight: 30
        )
        XCTAssertTrue(result.isFallback)
        XCTAssertEqual(result.rect.height, 30)
        XCTAssertEqual(result.rect.maxY, 1440)
    }

    func testMenuBarAnchorFallbackWithoutCachedRect() {
        let result = resolveAnchor(cached: nil, mouse: NSPoint(x: 2870, y: 1428))
        XCTAssertTrue(result.isFallback)
        XCTAssertEqual(result.rect.width, MenuBarAnchor.defaultButtonWidth)
        XCTAssertEqual(result.rect.midX, 2870)
        XCTAssertEqual(result.rect.maxY, 1440)
    }

    func testMenuBarAnchorKeepsCachedWhenMouseOutsideMenuBarBand() {
        // 从 Dock 重开：鼠标在屏幕中部，无法推导，沿用缓存
        let stale = NSRect(x: 1815, y: 1055, width: 109, height: 25)
        let result = resolveAnchor(cached: stale, mouse: NSPoint(x: 1720, y: 720))
        XCTAssertEqual(result, MenuBarAnchor.Resolution(rect: stale, isFallback: false))
    }

    func testMenuBarAnchorSecondaryScreenOffset() {
        // 副屏位于主屏右侧、抬高 200
        let screen = NSRect(x: 3440, y: 200, width: 1920, height: 1080)
        let visible = NSRect(x: 3440, y: 200, width: 1920, height: 1055)
        let stale = NSRect(x: 100, y: 100, width: 80, height: 25)
        let result = resolveAnchor(cached: stale, mouse: NSPoint(x: 5000, y: 1270), screen: screen, visible: visible)
        XCTAssertTrue(result.isFallback)
        XCTAssertEqual(result.rect, NSRect(x: 4960, y: 1255, width: 80, height: 25))
    }

    // MARK: - 无鼠标锚点解析（tb / Dock reopen / 第二实例唤醒）

    /// 线上故障态：状态项停在屏幕右上角，右边缘 3441、顶边 1441，各越界 1pt
    private let anchorDetachedButton = NSRect(x: 3332, y: 1417, width: 109, height: 24)

    private func resolveNoPointer(
        cached: NSRect?,
        screen: NSRect? = nil,
        visible: NSRect? = nil,
        trailingClusterMinX: CGFloat? = nil
    ) -> MenuBarAnchor.Resolution {
        MenuBarAnchor.resolveWithoutPointer(
            cachedButtonRect: cached,
            screenFrame: screen ?? anchorScreen,
            visibleFrame: visible ?? anchorVisible,
            trailingClusterMinX: trailingClusterMinX
        )
    }

    func testAnchorWithoutPointerTrustsRectInsideMenuBarBand() {
        let result = resolveNoPointer(cached: anchorButton)
        XCTAssertEqual(result, MenuBarAnchor.Resolution(rect: anchorButton, isFallback: false))
    }

    /// 复现 `tb` 弹窗贴死在屏幕右缘：缓存矩形越界，必须走兜底而不是原样放行
    func testAnchorWithoutPointerFallsBackForDetachedRect() {
        let result = resolveNoPointer(cached: anchorDetachedButton)
        XCTAssertTrue(result.isFallback)
        XCTAssertEqual(result.rect.width, 109)
        XCTAssertEqual(result.rect.maxY, 1440)
        // 关键：兜底锚点不能贴着屏幕右缘，否则弹窗又会被夹回去
        XCTAssertLessThan(result.rect.maxX, 3440 - 100)
    }

    func testAnchorWithoutPointerFallsBackForUnusableRects() {
        for cached in [nil, NSRect.zero, NSRect(x: 2815, y: 1415, width: 0, height: 25)] as [NSRect?] {
            let result = resolveNoPointer(cached: cached)
            XCTAssertTrue(result.isFallback, "cached=\(String(describing: cached)) 应走兜底")
            XCTAssertEqual(result.rect.width, MenuBarAnchor.defaultButtonWidth)
            XCTAssertEqual(result.rect.midX, 3440 - MenuBarAnchor.defaultTrailingInset)
            XCTAssertEqual(result.rect.maxY, 1440)
        }
    }

    /// 与 `resolve` 分支 3 的行为**故意不同**：那里鼠标不在带内时会原样退回缓存，
    /// 这里没有鼠标可参照，只认几何，屏幕中部的陈旧矩形一律兜底
    func testAnchorWithoutPointerRejectsStaleRectInScreenMiddle() {
        let stale = NSRect(x: 1815, y: 1055, width: 109, height: 25)
        XCTAssertTrue(resolveNoPointer(cached: stale).isFallback)
        // 对照：有鼠标时 resolve 仍会沿用它
        XCTAssertFalse(resolveAnchor(cached: stale, mouse: NSPoint(x: 1720, y: 720)).isFallback)
    }

    func testAnchorWithoutPointerUsesDefaultHeightWhenMenuBarHidden() {
        let hiddenVisible = NSRect(x: 0, y: 80, width: 3440, height: 1360)
        let result = MenuBarAnchor.resolveWithoutPointer(
            cachedButtonRect: nil,
            screenFrame: anchorScreen,
            visibleFrame: hiddenVisible,
            defaultMenuBarHeight: 30
        )
        XCTAssertTrue(result.isFallback)
        XCTAssertEqual(result.rect.height, 30)
        XCTAssertEqual(result.rect.maxY, 1440)
    }

    func testAnchorWithoutPointerOnSecondaryScreen() {
        let screen = NSRect(x: 3440, y: 200, width: 1920, height: 1080)
        let visible = NSRect(x: 3440, y: 200, width: 1920, height: 1055)
        let result = resolveNoPointer(cached: nil, screen: screen, visible: visible)
        XCTAssertTrue(result.isFallback)
        XCTAssertEqual(result.rect.maxY, 1280)
        XCTAssertEqual(result.rect.midX, 5360 - MenuBarAnchor.defaultTrailingInset)
    }

    func testAnchorWithoutPointerClampsOversizedTrailingInset() {
        let result = MenuBarAnchor.resolveWithoutPointer(
            cachedButtonRect: nil,
            screenFrame: anchorScreen,
            visibleFrame: anchorVisible,
            trailingInset: 4000
        )
        XCTAssertEqual(result.rect.minX, 0)
    }

    /// 已知系统项簇左边界时（实测控制中心从 2703 开始），兜底锚点贴到它左侧
    func testAnchorWithoutPointerSitsLeftOfSystemCluster() {
        let result = resolveNoPointer(cached: anchorDetachedButton, trailingClusterMinX: 2703)
        XCTAssertTrue(result.isFallback)
        XCTAssertLessThanOrEqual(result.rect.maxX, 2703)
    }
}
