import XCTest
@testable import LinkCKit

/// The once-a-second sweep reads every live session's screen. The buffer-to-rows conversion is
/// the expensive part, so it happens once per session per sweep and every check shares the rows.
final class ScreenReadingTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-screen-reading-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
        try super.tearDownWithError()
    }

    /// A coordinator with one session per entry, each holding `screen` on a terminal that was never
    /// given a process — the screen is exactly what the test draws, with nothing racing it.
    @MainActor
    private func makeCoordinator(
        sessions: [(id: String, agent: AgentKind)], screen: String
    ) -> (AppCoordinator, [String: TerminalSession]) {
        let coordinator = AppCoordinator(workspaceDir: workspace)
        var terminals: [String: TerminalSession] = [:]
        for (id, agent) in sessions {
            _ = coordinator.store.create(cwd: workspace.path, title: id, id: id, agentKind: agent)
            coordinator.store.updateState(id: id, to: .ready)
            let term = coordinator.terminals.makeSession(id: id, cwd: workspace.path, title: id, agentKind: agent)
            term.terminalView.getTerminal().resize(cols: 120, rows: ScreenFixture.height)
            term.terminalView.feed(text: screen)
            terminals[id] = term
        }
        return (coordinator, terminals)
    }

    @MainActor
    func testASweepReadsEachSessionsScreenOnce() throws {
        let (coordinator, terminals) = makeCoordinator(
            sessions: [("codex", .codex), ("claude", .claude), ("cursor", .cursor)],
            screen: ScreenFixture.terminalInput()
        )
        defer { coordinator.shutdown() }
        XCTAssertGreaterThan(try XCTUnwrap(terminals["codex"]).screenSnapshot().rows.count, 30, "the fixture screen must have drawn")
        let before = terminals.mapValues(\.screenReadCount)

        coordinator.sampleAgentStates()

        for (id, term) in terminals {
            XCTAssertEqual(term.screenReadCount - before[id]!, 1, "\(id): every check in a sweep must share one read of the screen")
        }
    }

    @MainActor
    func testASnapshotAnswersEveryQuestionTheRowLevelReadersDo() throws {
        let (coordinator, terminals) = makeCoordinator(sessions: [("s", .codex)], screen: ScreenFixture.terminalInput())
        defer { coordinator.shutdown() }
        let term = try XCTUnwrap(terminals["s"])

        let snapshot = term.screenSnapshot()

        XCTAssertEqual(snapshot.recentOutput(lines: 15), term.recentOutput(lines: 15))
        XCTAssertEqual(snapshot.recentRows(12), term.recentScreenRows(12))
        XCTAssertEqual(snapshot.liveActivity(), term.liveActivityLine())
        XCTAssertEqual(snapshot.liveActivity(), "Percolating…")
        XCTAssertEqual(snapshot.progressSignature(), term.screenSignature())
        XCTAssertEqual(snapshot.showsTrustPrompt(), term.showsTrustPrompt())
    }

    func testAScreenNeverStartedHasNoSignatureAndABlankOneDoes() {
        XCTAssertEqual(ScreenSnapshot.none.progressSignature(), "")
        XCTAssertNil(ScreenSnapshot.none.liveActivity())
        XCTAssertFalse(ScreenSnapshot.none.showsTrustPrompt())
        XCTAssertNotEqual(ScreenSnapshot(rows: []).progressSignature(), "", "a started terminal with nothing on it is not the same as no terminal")
    }

    func testTheFingerprintFollowsTheRowsAndTheirBoundaries() {
        let rows = ["⏺ Read(a.swift)", "  ⎿  Read 200 lines", "╭────╮"]
        XCTAssertEqual(ScreenSnapshot(rows: rows).fingerprint, ScreenSnapshot(rows: rows).fingerprint)
        XCTAssertNotEqual(ScreenSnapshot(rows: rows).fingerprint, ScreenSnapshot(rows: Array(rows.dropLast())).fingerprint)
        var edited = rows
        edited[1] = "  ⎿  Read 201 lines"
        XCTAssertNotEqual(ScreenSnapshot(rows: rows).fingerprint, ScreenSnapshot(rows: edited).fingerprint)
        XCTAssertNotEqual(
            ScreenSnapshot(rows: ["ab", "c"]).fingerprint, ScreenSnapshot(rows: ["a", "bc"]).fingerprint,
            "moving text across a row boundary is a change"
        )
    }
}
