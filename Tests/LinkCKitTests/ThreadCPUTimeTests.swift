import XCTest

final class ThreadCPUTimeTests: XCTestCase {
    /// The TSan scale must only ever loosen budgets under `scripts/tsan.sh` — a false positive in a
    /// plain run would silently let real slowdowns through. The script sets `TSAN_OPTIONS`, which a
    /// plain `swift test` never does, so it is an independent check on the runtime detection.
    func testBudgetsAreScaledOnlyUnderThreadSanitizer() {
        let underTSan = ProcessInfo.processInfo.environment["TSAN_OPTIONS"] != nil
        XCTAssertEqual(ThreadCPUTime.budgetScale, underTSan ? 5 : 1)
        XCTAssertEqual(ThreadCPUTime.budget(2.0), underTSan ? 10.0 : 2.0)
    }
}
