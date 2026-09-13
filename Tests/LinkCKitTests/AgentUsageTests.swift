import XCTest
@testable import LinkCKit

final class AgentUsageTests: XCTestCase {
    func testAReadingIsStaleAfterAnHour() {
        let fresh = AgentUsage(agent: .codex, windows: [], planType: nil,
                               observedAt: Date().addingTimeInterval(-59 * 60), unavailableReason: nil)
        let stale = AgentUsage(agent: .codex, windows: [], planType: nil,
                               observedAt: Date().addingTimeInterval(-61 * 60), unavailableReason: nil)
        XCTAssertFalse(fresh.isStale)
        XCTAssertTrue(stale.isStale)
    }

    func testTheWarnThresholdIsInclusive() {
        func usage(_ percent: Double) -> AgentUsage {
            AgentUsage(agent: .codex, windows: [UsageWindow(label: "5h", usedPercent: percent, tokens: nil, resetsAt: nil)],
                       planType: nil, observedAt: Date(), unavailableReason: nil)
        }
        XCTAssertNil(usage(79.9).windowNeedingWarning)
        XCTAssertEqual(usage(80).windowNeedingWarning?.label, "5h")
        XCTAssertEqual(usage(80.1).windowNeedingWarning?.label, "5h")
    }

    func testAStaleOrUnavailableReadingNeverWarns() {
        let stale = AgentUsage(agent: .codex, windows: [UsageWindow(label: "5h", usedPercent: 99, tokens: nil, resetsAt: nil)],
                               planType: nil, observedAt: Date().addingTimeInterval(-2 * 3600), unavailableReason: nil)
        XCTAssertNil(stale.windowNeedingWarning, "a stale number must not drive a warning")
        let unknown = AgentUsage(agent: .agy, windows: [], planType: nil, observedAt: nil,
                                 unavailableReason: "agy writes no local session records")
        XCTAssertNil(unknown.windowNeedingWarning)
    }

    /// A reading at 95% whose window's `resetsAt` has already passed describes a window that
    /// has already moved on — the observation is fresh, but the number it reports no longer
    /// describes anything current, so it must never drive a warning.
    func testAWindowWhoseResetHasAlreadyPassedNeverWarns() {
        let staleWindow = AgentUsage(
            agent: .codex,
            windows: [UsageWindow(label: "5h", usedPercent: 95, tokens: nil,
                                   resetsAt: Date().addingTimeInterval(-600))],
            planType: nil, observedAt: Date(), unavailableReason: nil
        )
        XCTAssertNil(staleWindow.windowNeedingWarning, "a window whose reset has already passed must never warn")
    }

    func testANeverObservedReadingIsStale() {
        let unknown = AgentUsage(agent: .agy, windows: [], planType: nil, observedAt: nil,
                                 unavailableReason: "agy writes no local session records")
        XCTAssertTrue(unknown.isStale, "no observation at all must never read as fresh")
    }
}
