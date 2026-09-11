import XCTest
@testable import TokenBar

final class SingleInstanceGuardTests: XCTestCase {
    /// flock 按打开文件描述加锁：同一进程内两个独立实例也应互斥，
    /// 这样才能拦住"开发构建 + 正式安装版"这类共用锁文件的双开。
    func testSecondLockOnSameFileIsRejected() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TokenBarSingleInstanceTests-\(UUID().uuidString)", isDirectory: true)

        let first = ProcessSingletonLock(directory: dir, fileName: "singleton.lock")
        XCTAssertTrue(first.isLocked)

        let second = ProcessSingletonLock(directory: dir, fileName: "singleton.lock")
        XCTAssertFalse(second.isLocked)

        // 首个锁释放后（模拟进程退出），同一路径可以重新加锁
        do { try FileManager.default.removeItem(at: dir) } catch { /* 清理失败不影响断言 */ }
    }

    func testLockIsReacquirableAfterRelease() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TokenBarSingleInstanceTests-\(UUID().uuidString)", isDirectory: true)

        do {
            let first = ProcessSingletonLock(directory: dir, fileName: "singleton.lock")
            XCTAssertTrue(first.isLocked)
        }
        let second = ProcessSingletonLock(directory: dir, fileName: "singleton.lock")
        XCTAssertTrue(second.isLocked)

        try? FileManager.default.removeItem(at: dir)
    }
}
