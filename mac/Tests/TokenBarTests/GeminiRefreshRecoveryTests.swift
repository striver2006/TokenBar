import XCTest
@testable import TokenBar

private final class GeminiTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

private actor GeminiTokenFixture {
    enum Reply: Sendable {
        case network(URLError.Code)
        case oauth(String)
        case success
    }
    private var replies: [Reply]
    private(set) var requests = 0
    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests += 1
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        let status: Int
        let body: String
        switch reply {
        case .network(let code): throw URLError(code)
        case .oauth(let error): status = 400; body = "{\"error\":\"\(error)\"}"
        case .success: status = 200; body = "{\"access_token\":\"fixture-access\",\"expires_in\":3600}"
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class GeminiRefreshRecoveryTests: XCTestCase {
    private func service(_ fixture: GeminiTokenFixture, clock: GeminiTestClock, candidateCount: Int = 1) -> GeminiService {
        GeminiService(tokenRefreshEnvironment: .init(
            candidates: { (0..<candidateCount).map { (id: "fixture-\($0)", secret: "fixture") } },
            send: { try await fixture.send($0) },
            now: { clock.now() }
        ))
    }

    func testNetworkFailureKeepsCauseAndOriginalDeadlineDuringRepeatedRefreshes() async {
        let clock = GeminiTestClock()
        let fixture = GeminiTokenFixture([.network(.timedOut), .success])
        let service = service(fixture, clock: clock)
        let first = await service.refreshGoogleAccessToken(refreshToken: "fixture-refresh")
        XCTAssertEqual(first, .unreachable)
        let error = await service.credentialError(for: first)
        let deadline = clock.now().addingTimeInterval(120)
        XCTAssertEqual(error.retryAt, deadline)
        XCTAssertTrue(error.message(isZh: true).contains("无法连接"))
        XCTAssertTrue(error.message(isZh: true).contains("自动重试"))
        XCTAssertTrue(error.message(isZh: false).contains("Cannot reach"))

        for _ in 0..<3 {
            clock.advance(30)
            let outcome = await service.refreshGoogleAccessToken(refreshToken: "fixture-refresh")
            XCTAssertEqual(outcome, .cooldown(reason: .tokenRefreshUnreachable, retryAt: deadline))
            let repeated = await service.credentialError(for: outcome)
            XCTAssertEqual(repeated.stage, error.stage)
            XCTAssertEqual(repeated.retryAt, deadline, "点击刷新不能重置倒计时")
        }
        let duringCooldown = await fixture.requests
        XCTAssertEqual(duringCooldown, 1, "冷却期间不发送请求")
        clock.advance(30)
        let recovered = await service.refreshGoogleAccessToken(refreshToken: "fixture-refresh")
        XCTAssertEqual(recovered.accessToken, "fixture-access", "到期后可立即恢复")
        let afterSuccess = await service.credentialError(for: .unreachable)
        XCTAssertNil(afterSuccess.retryAt, "成功必须清掉旧失败状态")
    }

    func testPermanentFailuresKeepRecoveryGuidanceWithoutAutomaticRetry() async {
        for (code, stage) in [("invalid_grant", GeminiService.CredentialStage.refreshTokenDead), ("invalid_client", .clientMismatch)] {
            let clock = GeminiTestClock()
            let fixture = GeminiTokenFixture([.oauth(code)])
            let service = service(fixture, clock: clock)
            _ = await service.refreshGoogleAccessToken(refreshToken: "fixture-refresh")
            let outcome = await service.refreshGoogleAccessToken(refreshToken: "fixture-refresh")
            let error = await service.credentialError(for: outcome)
            XCTAssertEqual(error.stage, stage)
            XCTAssertNil(error.retryAt)
            XCTAssertFalse(error.message(isZh: true).contains("自动重试"))
            if stage == .refreshTokenDead {
                let ownError = await service.credentialError(for: outcome, ownLogin: true)
                XCTAssertEqual(ownError.stage, .ownLoginRevoked)
            }
        }
    }

    func testDifferentCredentialDoesNotInheritCooldownAndResetAllowsImmediateRetry() async {
        let clock = GeminiTestClock()
        let fixture = GeminiTokenFixture([.network(.notConnectedToInternet), .network(.timedOut), .success])
        let service = service(fixture, clock: clock)
        _ = await service.refreshGoogleAccessToken(refreshToken: "old")
        let second = await service.refreshGoogleAccessToken(refreshToken: "new")
        XCTAssertEqual(second, .unreachable)
        let count = await fixture.requests
        XCTAssertEqual(count, 2, "新凭证必须实际尝试，不能继承旧冷却")
        await service.resetTokenRefreshState()
        let third = await service.refreshGoogleAccessToken(refreshToken: "new")
        XCTAssertEqual(third.accessToken, "fixture-access")
    }

    func testCancelledURLRequestDoesNotTryNextCandidateOrStartCooldown() async {
        let clock = GeminiTestClock()
        let fixture = GeminiTokenFixture([.network(.cancelled), .success])
        let service = service(fixture, clock: clock, candidateCount: 2)
        let cancelled = await service.refreshGoogleAccessToken(refreshToken: "fixture-refresh")
        XCTAssertEqual(cancelled, .cancelled)
        let count = await fixture.requests
        XCTAssertEqual(count, 1, "取消后不得继续试候选")
        let next = await service.refreshGoogleAccessToken(refreshToken: "fixture-refresh")
        XCTAssertEqual(next.accessToken, "fixture-access", "取消不能触发 120 秒冷却")
    }

    func testTaskCancellationStopsInFlightRequestWithoutRecordingFailure() async {
        let entered = expectation(description: "request started")
        let service = GeminiService(tokenRefreshEnvironment: .init(
            candidates: { [(id: "fixture", secret: "fixture")] },
            send: { _ in
                entered.fulfill()
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw URLError(.badServerResponse)
            }
        ))
        let request = Task { await service.refreshGoogleAccessToken(refreshToken: "fixture-refresh") }
        await fulfillment(of: [entered], timeout: 2)
        request.cancel()
        let outcome = await request.value
        XCTAssertEqual(outcome, .cancelled)
        let error = await service.credentialError(for: .unreachable)
        XCTAssertNil(error.retryAt)
    }

    func testCancellationBeforeRequestDoesNotSendOrRecordFailure() async {
        let fixture = GeminiTokenFixture([.success])
        let service = service(fixture, clock: GeminiTestClock())
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.refreshGoogleAccessToken(refreshToken: "fixture-refresh")
        }
        let result = await request.value
        XCTAssertEqual(result, .cancelled)
        let count = await fixture.requests
        XCTAssertEqual(count, 0)
        let next = await service.refreshGoogleAccessToken(refreshToken: "fixture-refresh")
        XCTAssertEqual(next.accessToken, "fixture-access")
    }

    @MainActor
    func testSchedulerCoalescesRepeatedRefreshAndDoesNotPostponeDeadline() async {
        let scheduler = GeminiRetryScheduler()
        let fired = expectation(description: "one retry")
        fired.assertForOverFulfill = true
        let deadline = Date().addingTimeInterval(0.03)
        scheduler.schedule(at: deadline) { fired.fulfill() }
        scheduler.schedule(at: deadline) { XCTFail("duplicate retry") }
        scheduler.schedule(at: deadline.addingTimeInterval(60)) { XCTFail("postponed retry") }
        XCTAssertEqual(scheduler.deadline, deadline)
        await fulfillment(of: [fired], timeout: 2)
        XCTAssertNil(scheduler.deadline)
    }

    @MainActor
    func testSchedulerCancellationAlsoCancelsRetryWaitingForAnotherRefresh() async throws {
        let scheduler = GeminiRetryScheduler()
        let readyChecked = expectation(description: "waiting for refresh")
        scheduler.schedule(at: Date(), ready: { readyChecked.fulfill(); return false }) {
            XCTFail("cancelled retry fired")
        }
        await fulfillment(of: [readyChecked], timeout: 2)
        scheduler.cancel()
        XCTAssertNil(scheduler.deadline)
        let replacement = expectation(description: "replacement retry")
        scheduler.schedule(at: Date()) { replacement.fulfill() }
        await fulfillment(of: [replacement], timeout: 2)
    }

    @MainActor
    func testSchedulerWaitsForRefreshThenCanRearmAfterAnotherFailure() async {
        let scheduler = GeminiRetryScheduler()
        var ready = false
        let checked = expectation(description: "blocked by current refresh")
        let retried = expectation(description: "first retry")
        let rearmed = expectation(description: "retry after another failure")
        scheduler.schedule(at: Date(), ready: {
            if !ready { checked.fulfill() }
            return ready
        }) {
            retried.fulfill()
            scheduler.schedule(at: Date().addingTimeInterval(0.01)) { rearmed.fulfill() }
            XCTAssertFalse(Task.isCancelled, "安排下一次重试不能取消当前的刷新")
        }
        await fulfillment(of: [checked], timeout: 2)
        ready = true
        await fulfillment(of: [retried, rearmed], timeout: 3)
    }

    @MainActor
    func testCancellingPendingRetryPreventsItFromFiring() async {
        let scheduler = GeminiRetryScheduler()
        let cancelled = expectation(description: "no retry after success or logout")
        cancelled.isInverted = true
        scheduler.schedule(at: Date().addingTimeInterval(0.02)) { cancelled.fulfill() }
        scheduler.cancel()
        await fulfillment(of: [cancelled], timeout: 0.08)
    }
}
