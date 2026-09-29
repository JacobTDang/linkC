import XCTest
@testable import LinkCKit

/// The cost of `sampleAgentStates` over the screens ~20 agent sessions show: 50 rows each, drawn
/// on real terminal buffers. CPU time of the calling thread, so time spent waiting on a busy
/// machine does not count.
final class ScreenSweepCostTests: XCTestCase {
    private static let sessionCount = 20
    private static let ticks = 100
    /// The most of a redrawn sweep's cost an idle sweep may take. Measured at 0.46 to 0.47 in a
    /// debug build, whatever the machine's load (an idle sweep still reads every screen once), and
    /// at 1.0 with the limit scan and the watchdog signature recomputed on every sweep.
    private static let idleShareOfRedrawnCost = 0.75

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

    /// Twenty sessions across the agent kinds, each drawn with `screen`, in their own folder `name`
    /// so two coordinators in one test share no blackboard or inbox.
    @MainActor
    private func makeSessions(in name: String, screen: String) throws -> (AppCoordinator, [TerminalSession]) {
        let folder = workspace.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let coordinator = AppCoordinator(workspaceDir: folder)
        let kinds: [AgentKind] = [.claude, .codex, .cursor, .agy]
        var terminals: [TerminalSession] = []
        for i in 0..<Self.sessionCount {
            let id = "S\(i)"
            let kind = kinds[i % kinds.count]
            _ = coordinator.store.create(cwd: folder.path, title: id, id: id, agentKind: kind)
            coordinator.store.updateState(id: id, to: .ready)
            let term = coordinator.terminals.makeSession(id: id, cwd: folder.path, title: id, agentKind: kind)
            term.terminalView.getTerminal().resize(cols: 120, rows: ScreenFixture.height)
            term.terminalView.feed(text: screen)
            terminals.append(term)
        }
        return (coordinator, terminals)
    }

    /// Sweeps over sessions waiting at their prompt cost a fraction of sweeps over sessions whose
    /// screen changes every tick: an unchanged screen is not classified or scanned again.
    ///
    /// The baseline is measured in the same run, tick for tick, on identical sessions whose spinner
    /// timer redraws every tick (so no screen ever matches the last). That makes the guard a ratio
    /// that holds on a slow or busy machine, where a fixed CPU-time budget does not. Nothing in
    /// this test says how long a sweep takes; `ScreenReadingTests` and `LimitScanSkipTests` count
    /// the reads, scans and walks a sweep is allowed.
    @MainActor
    func testSweepsOverUnchangedScreensCostFarLessThanSweepsOverRedrawnOnes() throws {
        let (idleCoordinator, _) = try makeSessions(in: "idle", screen: ScreenFixture.terminalInput(spinnerSeconds: nil))
        let (redrawnCoordinator, redrawnTerminals) = try makeSessions(in: "redrawn", screen: ScreenFixture.terminalInput(spinnerSeconds: 1))
        defer {
            idleCoordinator.shutdown()
            redrawnCoordinator.shutdown()
        }
        idleCoordinator.sampleAgentStates()
        redrawnCoordinator.sampleAgentStates()

        var idle: TimeInterval = 0
        var redrawn: TimeInterval = 0
        for tick in 0..<Self.ticks {
            let redraw = "\u{1b}[H" + ScreenFixture.rows(spinnerSeconds: tick + 2).joined(separator: "\r\n")
            for term in redrawnTerminals { term.terminalView.feed(text: redraw) }
            idle += ThreadCPUTime.elapsed { idleCoordinator.sampleAgentStates() }
            redrawn += ThreadCPUTime.elapsed { redrawnCoordinator.sampleAgentStates() }
        }

        XCTAssertGreaterThan(redrawn, 0, "the baseline measured nothing")
        XCTAssertLessThan(
            idle / redrawn, Self.idleShareOfRedrawnCost,
            "\(Self.ticks) sweeps over \(Self.sessionCount) sessions: idle screens took \(idle)s of CPU, redrawn ones \(redrawn)s"
        )
    }
}
