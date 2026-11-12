import XCTest
@testable import LinkCKit

/// OpenCode's screen reader runs for OpenCode and Kilo sessions (same TUI chrome): its input box
/// has none of the prompt markers the generic scan stops at, so every other agent keeps reading
/// screens the way it always did.
final class OpenCodeScreenGatingTests: XCTestCase {
    /// A finished OpenCode turn with a stray row above its input box. The generic reader takes the
    /// row for a spinner phrase; OpenCode's own reader knows from the footer that the turn is over.
    private func finishedTurnWithAStrayPhraseRow() throws -> [String] {
        var rows = try CodexScreenFixture.rows("opencode-2.2.5-done")
        let edge = try XCTUnwrap(rows.lastIndex(where: OpenCodeScreen.isInputBoxEdge))
        rows.insert("     ~ Reading file...", at: edge - 3)
        return rows
    }

    private var openCodeFamily: Set<AgentKind> { [.opencode, .kilo] }

    func testEveryNonOpenCodeFixtureStillUsesTheGenericReader() throws {
        let others = CodexScreenFixture.allNames().filter {
            !$0.hasPrefix("opencode-") && !$0.hasPrefix("freebuff-") && !$0.hasPrefix("kilo-")
        }
        XCTAssertFalse(others.isEmpty)
        for name in others {
            let rows = try CodexScreenFixture.rows(name)
            // Crush's own screens have their own reader, which `CrushScreenTests` covers.
            for agent in AgentKind.allCases where !openCodeFamily.contains(agent) && agent != .freebuff
                && !(agent == .crush && name.hasPrefix("crush-")) {
                XCTAssertEqual(
                    TerminalPreview.liveActivity(from: rows, agent: agent),
                    TerminalPreview.genericLiveActivity(from: rows),
                    "\(name) as \(agent)")
            }
        }
    }

    /// The fixture sweep above cannot tell a gated reader from an ungated one, since no other agent's
    /// screen looks like OpenCode's. This screen does: the two readers answer it differently.
    func testAnOpenCodeScreenIsReadTheOpenCodeWayForOpenCodeAndTheGenericWayForEveryOtherAgent() throws {
        let rows = try finishedTurnWithAStrayPhraseRow()
        let generic = try XCTUnwrap(TerminalPreview.genericLiveActivity(from: rows), "the generic reader takes the stray row for a phrase")
        XCTAssertEqual(OpenCodeScreen.turn(in: rows), .idle, "OpenCode's reader says the turn is over")

        for agent in AgentKind.allCases where !openCodeFamily.contains(agent) && agent != .freebuff {
            XCTAssertEqual(TerminalPreview.liveActivity(from: rows, agent: agent), generic, "\(agent)")
        }
        XCTAssertNil(TerminalPreview.liveActivity(from: rows, agent: .opencode))
        XCTAssertNil(TerminalPreview.liveActivity(from: rows, agent: .kilo),
                     "Kilo shares OpenCode's reader")
    }

    func testAnOpenCodeLookingScreenInANonOpenCodeSessionIsNotReadAsOpenCode() throws {
        let rows = try CodexScreenFixture.rows("opencode-2.2.5-working-narrow")

        XCTAssertNil(TerminalPreview.liveActivity(from: rows, agent: .codex))
        XCTAssertEqual(TerminalPreview.liveActivity(from: rows, agent: .opencode), "Working")
        XCTAssertEqual(TerminalPreview.liveActivity(from: rows, agent: .kilo), "Working")
    }

    /// What a session does with its screen follows its own agent kind, both when asked for its
    /// activity line and when the sweep decides whether it is working.
    @MainActor
    func testASessionReadsTheSameScreenByItsAgentKind() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-opencode-gating-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let coordinator = AppCoordinator(workspaceDir: workspace)
        defer { coordinator.shutdown() }
        let screen = "\u{1b}[2J\u{1b}[H" + (try finishedTurnWithAStrayPhraseRow()).joined(separator: "\r\n")
        var terminals: [AgentKind: TerminalSession] = [:]
        for agent in [AgentKind.opencode, .codex] {
            let id = agent.rawValue
            _ = coordinator.store.create(cwd: workspace.path, title: id, id: id, agentKind: agent)
            coordinator.store.updateState(id: id, to: .ready)
            let terminal = coordinator.terminals.makeSession(id: id, cwd: workspace.path, title: id, agentKind: agent)
            terminal.terminalView.getTerminal().resize(cols: 120, rows: ScreenFixture.height)
            terminal.terminalView.feed(text: screen)
            terminals[agent] = terminal
        }

        XCTAssertNil(try XCTUnwrap(terminals[.opencode]).liveActivityLine(), "OpenCode's footer says the turn is over")
        XCTAssertNotNil(try XCTUnwrap(terminals[.codex]).liveActivityLine(), "the generic reader finds a phrase on it")
        coordinator.sampleAgentStates()

        XCTAssertEqual(coordinator.store.session(id: AgentKind.opencode.rawValue)?.state, .ready)
        XCTAssertEqual(coordinator.store.session(id: AgentKind.codex.rawValue)?.state, .working)
    }
}
