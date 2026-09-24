import XCTest
import os
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

    /// Sampling runs once a second against every row. A write that fires observers even when
    /// nothing changed makes any view that both reads `rows` and drives sampling re-render
    /// itself forever — main thread pinned, window never painted.
    func testUpdateDetectedAgentWithUnchangedValueDoesNotNotifyObservers() {
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/tmp", title: "t")
        store.updateDetectedAgent(id: "T1", agent: .codex)

        let fired = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.rows
        } onChange: {
            fired.withLock { $0 = true }
        }
        store.updateDetectedAgent(id: "T1", agent: .codex)
        XCTAssertFalse(fired.withLock { $0 }, "an unchanged agent must not invalidate observers")
        XCTAssertEqual(store.row(id: "T1")?.detectedAgent, .codex)
    }

    func testUpdateDetectedAgentWithChangedValueNotifiesObservers() {
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/tmp", title: "t")

        let fired = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.rows
        } onChange: {
            fired.withLock { $0 = true }
        }
        store.updateDetectedAgent(id: "T1", agent: .claude)
        XCTAssertTrue(fired.withLock { $0 })
        XCTAssertEqual(store.row(id: "T1")?.detectedAgent, .claude)
    }

    func testAPlainTerminalTakesItsNewFoldersName() {
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/Users/j/Projects/linkC", title: "linkC")

        let updated = store.updateDirectory(id: "T1", to: "/Users/j/Projects/linkC/Sources", home: "/Users/j")
        XCTAssertEqual(updated?.cwd, "/Users/j/Projects/linkC/Sources")
        XCTAssertEqual(updated?.title, "Sources")
        XCTAssertEqual(store.row(id: "T1"), updated)

        XCTAssertEqual(store.updateDirectory(id: "T1", to: "/Users/j", home: "/Users/j")?.title, "~")
    }

    func testACommandTerminalKeepsItsTitle() {
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/Users/j", title: "logs: web", command: "docker logs -f web")

        let updated = store.updateDirectory(id: "T1", to: "/tmp", home: "/Users/j")
        XCTAssertEqual(updated?.cwd, "/tmp")
        XCTAssertEqual(updated?.title, "logs: web")
    }

    func testTheSameFolderChangesNothing() {
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/Users/j/Projects/linkC", title: "linkC")

        XCTAssertNil(store.updateDirectory(id: "T1", to: "/Users/j/Projects/linkC", home: "/Users/j"))
        XCTAssertNil(store.updateDirectory(id: "missing", to: "/tmp", home: "/Users/j"))
    }

    func testAnOldNameIsCorrectedInPlace() {
        // A terminal restored with a name saved by an older linkC ("j" for the home folder).
        let store = ShellTerminalStore()
        store.add(id: "T1", cwd: "/Users/j", title: "j")

        XCTAssertEqual(store.updateDirectory(id: "T1", to: "/Users/j", home: "/Users/j")?.title, "~")
    }
}
