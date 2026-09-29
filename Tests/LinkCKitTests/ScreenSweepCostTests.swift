import XCTest
@testable import LinkCKit

/// The cost of `sampleAgentStates` over the screens ~20 agent sessions show: 50 rows each, drawn
/// on real terminal buffers. CPU time of the calling thread, so time spent waiting on a busy
/// machine does not count.
final class ScreenSweepCostTests: XCTestCase {
    private static let sessionCount = 20
    private static let ticks = 100

    private var workspace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-sweep-cost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
        try super.tearDownWithError()
    }

    /// Twenty sessions across the agent kinds, each drawn with `screen`.
    @MainActor
    private func makeSessions(screen: String) -> (AppCoordinator, [TerminalSession]) {
        let coordinator = AppCoordinator(workspaceDir: workspace)
        let kinds: [AgentKind] = [.claude, .codex, .cursor, .agy]
        var terminals: [TerminalSession] = []
        for i in 0..<Self.sessionCount {
            let id = "S\(i)"
            let kind = kinds[i % kinds.count]
            _ = coordinator.store.create(cwd: workspace.path, title: id, id: id, agentKind: kind)
            coordinator.store.updateState(id: id, to: .ready)
            let term = coordinator.terminals.makeSession(id: id, cwd: workspace.path, title: id, agentKind: kind)
            term.terminalView.getTerminal().resize(cols: 120, rows: ScreenFixture.height)
            term.terminalView.feed(text: screen)
            terminals.append(term)
        }
        return (coordinator, terminals)
    }

    /// Sessions waiting at their prompt: nothing on any screen changes between ticks.
    @MainActor
    func testAHundredSweepsOverTwentyIdleScreensStayWithinBudget() {
        let (coordinator, _) = makeSessions(screen: ScreenFixture.terminalInput(spinnerSeconds: nil))
        defer { coordinator.shutdown() }
        coordinator.sampleAgentStates()

        let elapsed = ThreadCPUTime.elapsed {
            for _ in 0..<Self.ticks { coordinator.sampleAgentStates() }
        }

        XCTAssertLessThan(
            elapsed, ThreadCPUTime.budget(2.5),
            "debug-build guard: \(Self.ticks) sweeps over \(Self.sessionCount) idle sessions took \(elapsed)s of CPU"
        )
    }

    /// Sessions mid-turn: the spinner's timer redraws every tick, so every screen differs from the last.
    @MainActor
    func testAHundredSweepsOverTwentyTickingScreensStayWithinBudget() {
        let (coordinator, terminals) = makeSessions(screen: ScreenFixture.terminalInput(spinnerSeconds: 1))
        defer { coordinator.shutdown() }
        coordinator.sampleAgentStates()

        var elapsed: TimeInterval = 0
        for tick in 0..<Self.ticks {
            let redraw = "\u{1b}[H" + ScreenFixture.rows(spinnerSeconds: tick + 2).joined(separator: "\r\n")
            for term in terminals { term.terminalView.feed(text: redraw) }
            elapsed += ThreadCPUTime.elapsed { coordinator.sampleAgentStates() }
        }

        XCTAssertLessThan(
            elapsed, ThreadCPUTime.budget(4.5),
            "debug-build guard: \(Self.ticks) sweeps over \(Self.sessionCount) redrawn sessions took \(elapsed)s of CPU"
        )
    }
}
