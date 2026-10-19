import XCTest
@testable import LinkCKit

/// The ancestor walk over a made-up process tree: the kernel hides an Apple binary's environment
/// (a test's own `/bin/sh` reads as empty), so the walk is tested through its two lookups.
final class ProcessSnooperAncestorEnvironmentTests: XCTestCase {
    /// 40 → 30 → 20 → 10 → launchd.
    private let parents: [pid_t: pid_t] = [40: 30, 30: 20, 20: 10, 10: 1]

    private func walk(_ environments: [pid_t: [String: String]], from pid: pid_t = 40, maxDepth: Int = 8) -> String? {
        ProcessSnooper.environmentVariable("MARK", inAncestorsOf: pid, maxDepth: maxDepth,
                                           parentOf: { self.parents[$0] },
                                           variableOf: { name, pid in environments[pid]?[name] })
    }

    func testTheNearestAncestorCarryingTheVariableWins() {
        XCTAssertEqual(walk([20: ["MARK": "near"], 10: ["MARK": "far"]]), "near")
    }

    func testTheProcessItselfIsNotItsOwnAncestor() {
        XCTAssertNil(walk([40: ["MARK": "mine"]]))
    }

    func testAnEmptyValueIsPassedOver() {
        XCTAssertEqual(walk([30: ["MARK": ""], 10: ["MARK": "far"]]), "far")
    }

    func testTheWalkStopsBeforeLaunchdAndAtItsDepth() {
        XCTAssertNil(walk([1: ["MARK": "launchd"]]))
        XCTAssertNil(walk([10: ["MARK": "far"]], maxDepth: 2))
        XCTAssertEqual(walk([10: ["MARK": "far"]], maxDepth: 3), "far")
    }
}
