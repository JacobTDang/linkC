import XCTest
@testable import LinkCKit

/// The shell rows' bookkeeping. The load-bearing rule: `markExited` KEEPS the row — a crashed
/// dev server must stay visible (with its scrollback) until the user dismisses it.
@MainActor
final class ShellTerminalStoreTests: XCTestCase {

    func testAddAndLookup() {
        let store = ShellTerminalStore()
        let row = store.add(id: "T1", cwd: "/tmp/proj", title: "proj")
        XCTAssertEqual(row.state, .running)
        XCTAssertEqual(store.row(id: "T1")?.title, "proj")
        XCTAssertEqual(store.runningCount, 1)
    }

    func testMarkExitedKeepsTheRow() {
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/tmp", title: "t")
        store.markExited(id: "T1", code: 137)
        XCTAssertEqual(store.row(id: "T1")?.state, .exited(137))
        XCTAssertEqual(store.rows.count, 1, "an exited shell must stay visible until dismissed")
        XCTAssertEqual(store.runningCount, 0)
    }

    func testMarkExitedUnknownIdIsANoOp() {
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/tmp", title: "t")
        store.markExited(id: "ghost", code: 0)
        XCTAssertEqual(store.row(id: "T1")?.state, .running)
        XCTAssertEqual(store.rows.count, 1)
    }

    func testRemoveDropsTheRow() {
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/tmp", title: "t")
        store.remove(id: "T1")
        XCTAssertTrue(store.rows.isEmpty)
        store.remove(id: "T1")  // idempotent
    }

    func testRunningCountExcludesExited() {
        let store = ShellTerminalStore()
        store.add(id: "A", cwd: "/a", title: "a")
        store.add(id: "B", cwd: "/b", title: "b")
        store.markExited(id: "A", code: 0)
        XCTAssertEqual(store.runningCount, 1)
    }
}
