import XCTest
import SwiftUI
@testable import TokenBar

final class RefreshMechanismTests: XCTestCase {
    // MARK: - 刷新可靠性（定时刷新停摆修复）

    func testWithTimeoutReturnsTrueWhenOperationFinishesInTime() async {
        let finished = await withTimeout(seconds: 2) { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(finished)
    }

    func testWithTimeoutReturnsFalseWhenOperationOverruns() async {
        let start = Date()
        let finished = await withTimeout(seconds: 0.3) { @MainActor in
            // 故意用一个不响应取消的睡眠，模拟挂死的厂商请求
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        XCTAssertFalse(finished)
        // 关键：必须在预算内返回，而不是等操作自己跑完
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    @MainActor

    func testWithTimeoutFromMainActorContext() async {
        // 复现真实调用场景：从 @MainActor 上下文调用，且 operation 挂在一个
        // 不响应取消的等待上（模拟卡死的网络请求）
        let start = Date()
        let finished = await withTimeout(seconds: 0.5) { @MainActor in
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
                // 故意永不 resume
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertFalse(finished, "超时必须返回 false")
        XCTAssertLessThan(elapsed, 3.0, "必须在预算内返回，实际 \(elapsed)s")
    }

    /// 超时分支与完成分支并发抢 resume，只能有一个生效 ——
    /// CheckedContinuation 二次 resume 会直接 crash。
    /// runOnKeychainQueue 与 prefetch 都押在这个类型上。
    func testResumeOnceOnlyFirstWins() async {
        let value: Int = await withCheckedContinuation { cont in
            let gate = ResumeOnce<Int>(cont)
            DispatchQueue.concurrentPerform(iterations: 16) { i in
                gate.resume(i == 0 ? 1 : 2)
            }
        }
        XCTAssertTrue(value == 1 || value == 2)
    }

    // MARK: - 定时器自愈（刷新间隔改了不生效）

    func testTimerRebuildWhenTimerInvalidated() {
        // 定时器失效：无论间隔是否一致都必须重建
        XCTAssertTrue(RefreshTimerHealth.needsRebuild(
            timerIsValid: false, activeIntervalMinutes: 5, desiredIntervalMinutes: 5))
        XCTAssertTrue(RefreshTimerHealth.needsRebuild(
            timerIsValid: false, activeIntervalMinutes: nil, desiredIntervalMinutes: 1))
    }

    func testTimerRebuildWhenIntervalDiffersFromSettings() {
        // 真实故障：设置改成 1 分钟但保存副作用没触发，定时器还按 5 分钟跑。
        // 只判「定时器是否有效」救不回来，必须比对间隔。
        XCTAssertTrue(RefreshTimerHealth.needsRebuild(
            timerIsValid: true, activeIntervalMinutes: 5, desiredIntervalMinutes: 1))
        XCTAssertTrue(RefreshTimerHealth.needsRebuild(
            timerIsValid: true, activeIntervalMinutes: 1, desiredIntervalMinutes: 60))
        // 定时器还没建立过
        XCTAssertTrue(RefreshTimerHealth.needsRebuild(
            timerIsValid: true, activeIntervalMinutes: nil, desiredIntervalMinutes: 5))
    }

    func testTimerNotRebuiltWhenHealthy() {
        // 间隔一致且定时器有效时不能重建：每次重建都会把计时相位打回零，
        // 间隔较长时反复重建会导致永远刷不到。
        XCTAssertFalse(RefreshTimerHealth.needsRebuild(
            timerIsValid: true, activeIntervalMinutes: 5, desiredIntervalMinutes: 5))
        XCTAssertFalse(RefreshTimerHealth.needsRebuild(
            timerIsValid: true, activeIntervalMinutes: 1, desiredIntervalMinutes: 1))
    }

    // MARK: - 简单厂商表驱动刷新（SimpleQuotaTransition / ProviderRefreshDescriptor）

    private func makeQuotaWindow(_ title: WindowTitle, used: Double) -> TokenWindow {
        TokenWindow(title: title, usedPercentage: used, startTime: Date(), endTime: Date().addingTimeInterval(3600))
    }

    /// 成功一轮：两个窗口 + 账号串整体覆盖写入，错误态清掉、lastUpdated 推进、卡片停止转圈
    func testSimpleQuotaTransitionSuccessOverwritesSlotsAndClearsErrorState() {
        let stale = makeQuotaWindow(.fiveHour, used: 10)
        var quota = ProviderQuota(provider: .glm)
        quota.fiveHourWindow = stale
        quota.weeklyWindow = stale
        quota.accountInfo = "old-account"
        quota.isAuthorized = false
        quota.hadRefreshError = true
        quota.errorMessage = "上一轮的错误"
        quota.isLoading = true

        quota = SimpleQuotaTransition.beginLoading(quota)
        XCTAssertTrue(quota.isLoading)
        XCTAssertNil(quota.errorMessage, "入口必须清掉上一轮文案，否则失败态会粘到成功轮上")

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        quota = SimpleQuotaTransition.success(
            quota,
            fiveHour: makeQuotaWindow(.fiveHour, used: 42),
            weekly: nil,
            account: "GLM • 1234",
            now: now
        )
        quota = SimpleQuotaTransition.finishLoading(quota)

        XCTAssertEqual(quota.fiveHourWindow?.usedPercentage, 42)
        XCTAssertNil(quota.weeklyWindow, "service 返回 nil 时要覆盖旧窗口，不能留着上一轮的数据")
        XCTAssertEqual(quota.accountInfo, "GLM • 1234")
        XCTAssertTrue(quota.isAuthorized)
        XCTAssertFalse(quota.hadRefreshError)
        XCTAssertEqual(quota.lastUpdated, now, "refreshAll 靠 lastUpdated 是否推进判断本轮有无收获")
        XCTAssertFalse(quota.isLoading)
    }

    /// Key 已配置但请求失败：只置 hadRefreshError，授权态与旧数据一律保留
    /// （卡片显示「重试」而不是「去配置」，网络恢复前仍能看到上一次的额度）
    func testSimpleQuotaTransitionFailureKeepsAuthorizationAndOldData() {
        let previousUpdate = Date(timeIntervalSince1970: 1_600_000_000)
        var quota = ProviderQuota(provider: .kimi, isAuthorized: true)
        quota.weeklyWindow = makeQuotaWindow(.weekly, used: 55)
        quota.accountInfo = "kimi-account"
        quota.lastUpdated = previousUpdate
        quota.isLoading = true

        quota = SimpleQuotaTransition.beginLoading(quota)
        quota = SimpleQuotaTransition.failure(quota, message: "The request timed out.")
        quota = SimpleQuotaTransition.finishLoading(quota)

        XCTAssertTrue(quota.hadRefreshError)
        XCTAssertEqual(quota.errorMessage, "The request timed out.")
        XCTAssertTrue(quota.isAuthorized, "刷新失败不能把已授权打成未配置")
        XCTAssertEqual(quota.weeklyWindow?.usedPercentage, 55, "刷新失败要保留旧数据")
        XCTAssertEqual(quota.accountInfo, "kimi-account")
        XCTAssertEqual(quota.lastUpdated, previousUpdate, "失败不推进 lastUpdated，全失败轮次才不会显示「刚刚更新」")
        XCTAssertFalse(quota.isLoading)
    }

    /// 空 Key：未配置态，且不置 hadRefreshError —— 否则「从没配过 Key」的厂商会让
    /// 首刷退避重试与 anyRefreshError 一直为真
    func testSimpleQuotaTransitionMissingKeyIsNotARefreshError() {
        var quota = SimpleQuotaTransition.beginLoading(ProviderQuota(provider: .openAI, isAuthorized: true))
        quota = SimpleQuotaTransition.missingKey(quota, message: "请输入 OpenAI API Key")
        quota = SimpleQuotaTransition.finishLoading(quota)

        XCTAssertFalse(quota.isAuthorized)
        XCTAssertEqual(quota.errorMessage, "请输入 OpenAI API Key")
        XCTAssertFalse(quota.hadRefreshError)
        XCTAssertNil(quota.lastUpdated)
        XCTAssertFalse(quota.isLoading)
    }

    /// 表项接线本身也要有回归网：复制粘贴最容易把「A 厂商读 B 的 Key」「余额挂错槽位」这类
    /// 串位带进来，而它们的表象是另一个厂商莫名未配置，很难查到表上
    func testProviderRefreshDescriptorTableWiring() {
        var settings = AppSettings.defaultSettings
        settings.glmApiKey = "glm-key"
        settings.openAIApiKey = "openai-key"
        settings.deepseekApiKey = "deepseek-key"
        settings.volcengineApiKey = "volcengine-key"
        settings.kimiApiKey = "kimi-key"
        settings.openRouterApiKey = "openrouter-key"

        let table: [(spec: ProviderRefreshDescriptor, expectedSecretKey: SecretKey, expectedMissing: I18nKey, expectedKey: String)] = [
            (.glm, .glmApiKey, .errMissingGLMKey, "glm-key"),
            (.openAI, .openAIApiKey, .errMissingOpenAIKey, "openai-key"),
            (.deepseek, .deepseekApiKey, .errMissingDeepSeekKey, "deepseek-key"),
            (.volcengine, .volcengineApiKey, .errMissingVolcengineKey, "volcengine-key"),
            (.kimi, .kimiApiKey, .errMissingKimiKey, "kimi-key"),
            (.openRouter, .openRouterApiKey, .errMissingOpenRouterKey, "openrouter-key"),
        ]

        for entry in table {
            let name = entry.spec.type.rawValue
            XCTAssertEqual(entry.spec.apiKey(settings), entry.expectedKey, "\(name) 读错了 settings 字段")
            XCTAssertEqual(entry.spec.secretKey, entry.expectedSecretKey, "\(name) 的钥匙串键串位")
            XCTAssertEqual(entry.spec.missingKeyMessage, entry.expectedMissing, "\(name) 的空 Key 文案串位")
            // logName 必须与 refreshAll 里 runProvider 注册的名字一致，日志才对得上
            XCTAssertEqual(entry.spec.logName, name.lowercased(), "\(name) 的日志标识与注册名不符")
        }

        // 余额槽位：DeepSeek / Kimi 的余额并入周窗口，OpenRouter 并入主窗口，其余三家没有余额
        XCTAssertNil(ProviderRefreshDescriptor.glm.balance)
        XCTAssertNil(ProviderRefreshDescriptor.openAI.balance)
        XCTAssertNil(ProviderRefreshDescriptor.volcengine.balance)
        XCTAssertEqual(ProviderRefreshDescriptor.deepseek.balance?.slot, .weekly)
        XCTAssertEqual(ProviderRefreshDescriptor.kimi.balance?.slot, .weekly)
        XCTAssertEqual(ProviderRefreshDescriptor.openRouter.balance?.slot, .fiveHour)
        // providerKey 是余额历史与低余额通知去重的持久键，改动会让既有历史失联
        XCTAssertEqual(ProviderRefreshDescriptor.deepseek.balance?.providerKey, "deepseek")
        XCTAssertEqual(ProviderRefreshDescriptor.kimi.balance?.providerKey, "kimi")
        XCTAssertEqual(ProviderRefreshDescriptor.openRouter.balance?.providerKey, "openrouter")
    }

    // MARK: - 稳态失败退避（#20）
    // 与 Windows 端约定同一语义：effectiveInterval = baseInterval × min(2^n, 8)，
    // n 为连续「全失败轮次」数；判定只对 Timer 触发的轮次生效。

    func testFailureBackoffDisabledWithoutConsecutiveFailures() {
        // n = 0（尚无连续失败）：tick 到点即放行，哪怕距上次尝试只有 0 秒
        XCTAssertFalse(RefreshManager.failureBackoff(
            consecutiveFailures: 0, baseInterval: 60, elapsedSinceLastAttempt: 0))
        // 防御：负数计数同样不退避
        XCTAssertFalse(RefreshManager.failureBackoff(
            consecutiveFailures: -1, baseInterval: 60, elapsedSinceLastAttempt: 0))
    }

    func testFailureBackoffSkipsTickUntilDoubledIntervalElapses() {
        // n = 1 → 有效间隔 2×60s：刚过一个基础间隔仍要跳过，到 2 倍即放行
        XCTAssertTrue(RefreshManager.failureBackoff(
            consecutiveFailures: 1, baseInterval: 60, elapsedSinceLastAttempt: 61))
        XCTAssertTrue(RefreshManager.failureBackoff(
            consecutiveFailures: 1, baseInterval: 60, elapsedSinceLastAttempt: 119.9))
        XCTAssertFalse(RefreshManager.failureBackoff(
            consecutiveFailures: 1, baseInterval: 60, elapsedSinceLastAttempt: 120))
    }

    func testFailureBackoffGrowsExponentiallyAndCapsAt8x() {
        // n = 2 → 4×；n = 3 → 8×；n = 10 仍封顶 8×（大 n 还不得移位溢出）
        XCTAssertTrue(RefreshManager.failureBackoff(
            consecutiveFailures: 2, baseInterval: 60, elapsedSinceLastAttempt: 239))
        XCTAssertFalse(RefreshManager.failureBackoff(
            consecutiveFailures: 2, baseInterval: 60, elapsedSinceLastAttempt: 240))
        XCTAssertTrue(RefreshManager.failureBackoff(
            consecutiveFailures: 3, baseInterval: 60, elapsedSinceLastAttempt: 479))
        XCTAssertFalse(RefreshManager.failureBackoff(
            consecutiveFailures: 3, baseInterval: 60, elapsedSinceLastAttempt: 480))
        XCTAssertTrue(RefreshManager.failureBackoff(
            consecutiveFailures: 10, baseInterval: 60, elapsedSinceLastAttempt: 479))
        XCTAssertFalse(RefreshManager.failureBackoff(
            consecutiveFailures: 10, baseInterval: 60, elapsedSinceLastAttempt: 480))
        XCTAssertFalse(RefreshManager.failureBackoff(
            consecutiveFailures: 64, baseInterval: 60, elapsedSinceLastAttempt: 480))
    }

    func testFailureBackoffScalesWithBaseInterval() {
        // 5 分钟基础间隔，n = 1 → 600s 才放行
        XCTAssertTrue(RefreshManager.failureBackoff(
            consecutiveFailures: 1, baseInterval: 300, elapsedSinceLastAttempt: 599))
        XCTAssertFalse(RefreshManager.failureBackoff(
            consecutiveFailures: 1, baseInterval: 300, elapsedSinceLastAttempt: 600))
    }
}
