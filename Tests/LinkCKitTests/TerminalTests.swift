import XCTest
@testable import LinkCKit

/// Bookkeeping tests for the terminal manager. `makeSession` deliberately does NOT spawn a
/// process (the view + PTY are created lazily by `TerminalSession.start`/`.terminalView`), so
/// add / select / remove / terminate can all be exercised without a live PTY.
@MainActor
final class TerminalSessionManagerTests: XCTestCase {

    func testMakeSessionAddsAndSelectsIt() {
        let manager = TerminalSessionManager()
        let session = manager.makeSession(id: "L1", cwd: "/tmp", title: "api")
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(session.id, "L1")
        XCTAssertEqual(manager.selectedId, "L1", "a newly made session must become selected")
    }

    func testMakeSecondSessionSelectsTheLatest() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.makeSession(id: "L2", cwd: "/b", title: "b")
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(manager.selectedId, "L2")
    }

    func testSelectChangesSelectionAndIgnoresUnknownIds() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.makeSession(id: "L2", cwd: "/b", title: "b")

        manager.select("L1")
        XCTAssertEqual(manager.selectedId, "L1")

        manager.select("nope")
        XCTAssertEqual(manager.selectedId, "L1", "selecting an unknown id must not change the selection")
    }

    func testSessionLookup() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        XCTAssertEqual(manager.session(id: "L1")?.cwd, "/a")
        XCTAssertNil(manager.session(id: "nope"))
    }

    func testRemovingSelectedFallsBackToLastRemaining() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.makeSession(id: "L2", cwd: "/b", title: "b") // selected

        manager.remove("L2")
        XCTAssertEqual(manager.sessions.map(\.id), ["L1"])
        XCTAssertEqual(manager.selectedId, "L1", "removing the selected session must reselect a remaining one")

        manager.remove("L1")
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertNil(manager.selectedId, "removing the last session must clear the selection")
    }

    func testRemovingNonSelectedKeepsSelection() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.makeSession(id: "L2", cwd: "/b", title: "b") // selected

        manager.remove("L1")
        XCTAssertEqual(manager.selectedId, "L2", "removing a non-selected session must not change the selection")
    }

    func testDeselectClearsSelectionWithoutRemovingSessions() {
        // Returning to the home overview clears the selection but keeps every terminal alive.
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.makeSession(id: "L2", cwd: "/b", title: "b") // selected

        manager.deselect()
        XCTAssertNil(manager.selectedId, "deselect must clear the selection (return to home overview)")
        XCTAssertEqual(manager.sessions.map(\.id), ["L1", "L2"], "deselect must not remove any session")
    }

    func testTerminateNeverStartedSessionRemovesItWithoutSpawning() {
        // terminate() on a session whose PTY was never started is a no-op kill followed by a
        // plain removal — no view, no process, no crash.
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.terminate("L1")
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertNil(manager.selectedId)
    }

    func testTerminateUnknownIdIsIgnored() {
        let manager = TerminalSessionManager()
        manager.makeSession(id: "L1", cwd: "/a", title: "a")
        manager.terminate("nope")
        XCTAssertEqual(manager.sessions.map(\.id), ["L1"])
    }
}

@MainActor
final class TerminalSessionTests: XCTestCase {
    func testTerminateBeforeStartIsSafeNoOp() {
        let session = TerminalSession(id: "L1", cwd: "/tmp", title: "api")
        session.terminate() // must not force-create the view or crash
        XCTAssertEqual(session.id, "L1")
        XCTAssertEqual(session.cwd, "/tmp")
        XCTAssertEqual(session.title, "api")
    }

    func testRecentOutputBeforeStartIsEmpty() {
        // A session whose PTY was never started has no buffer to read. Reading it must return
        // "" — and, like terminate(), must not force the lazy view/PTY into existence.
        let session = TerminalSession(id: "L1", cwd: "/tmp", title: "api")
        XCTAssertEqual(session.recentOutput(lines: 3), "")
        session.terminate() // still a safe no-op — proves recentOutput didn't spawn a view
    }
}
