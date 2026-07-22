import XCTest
@testable import LinkCKit

/// Integration-style tests with real (harmless) PTY children, mirroring
/// AppCoordinatorIntegrationTests: launch/select semantics, the exited-row-keeps-scrollback
/// contract, stop/dismiss/relaunch, and fail-loud launch errors.
@MainActor
final class ShellCoordinatorTests: XCTestCase {

    private var terminals: TerminalSessionManager!

    override func setUp() {
        terminals = TerminalSessionManager()
    }

    override func tearDown() {
        for session in terminals.sessions { terminals.terminate(session.id) }
    }

    private func makeCoordinator(shell: String) -> ShellCoordinator {
        ShellCoordinator(terminals: terminals, shellPath: { shell })
    }

    /// Poll until `condition` is true or ~2s elapse — child exits arrive via the main queue.
    private func waitUntil(_ condition: @autoclosure () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition never became true")
    }

    func testLaunchRunsAndSelects() throws {
        let coordinator = makeCoordinator(shell: "/bin/cat")  // blocks forever, exits on SIGTERM
        let row = try coordinator.launch(cwd: "/tmp")

        XCTAssertEqual(coordinator.store.row(id: row.id)?.state, .running)
        XCTAssertEqual(row.title, "tmp", "title derives from the folder name")
        XCTAssertNotNil(terminals.session(id: row.id))
        XCTAssertEqual(terminals.selectedId, row.id, "a new terminal opens selected, like sessions")
    }

    func testNaturalExitKeepsRowAndScrollback() async throws {
        let coordinator = makeCoordinator(shell: "/usr/bin/true")  // exits 0 immediately
        let row = try coordinator.launch(cwd: "/tmp")

        try await waitUntil(coordinator.store.row(id: row.id)?.state == .exited(0))
        XCTAssertEqual(coordinator.store.rows.count, 1, "exited terminal stays visible")
        XCTAssertNotNil(terminals.session(id: row.id), "scrollback stays inspectable")
    }

    func testCrashExitCarriesCode() async throws {
        let coordinator = makeCoordinator(shell: "/usr/bin/false")  // exits 1
        let row = try coordinator.launch(cwd: "/tmp")
        try await waitUntil(coordinator.store.row(id: row.id)?.state == .exited(1))
    }

    func testDecodeWaitStatus() {
        XCTAssertEqual(ShellCoordinator.decodeWaitStatus(0), 0, "clean exit")
        XCTAssertEqual(ShellCoordinator.decodeWaitStatus(256), 1, "exit(1) as raw waitpid status")
        XCTAssertEqual(ShellCoordinator.decodeWaitStatus(35 << 8), 35)
        XCTAssertNil(ShellCoordinator.decodeWaitStatus(9), "SIGKILL death has no exit code")
        XCTAssertNil(ShellCoordinator.decodeWaitStatus(nil))
    }

    func testStopKillsAndRemoves() async throws {
        let coordinator = makeCoordinator(shell: "/bin/cat")
        let row = try coordinator.launch(cwd: "/tmp")

        coordinator.stop(row.id)
        try await waitUntil(coordinator.store.row(id: row.id) == nil)
        XCTAssertNil(terminals.session(id: row.id))
    }

    func testDismissIsExitedOnly() async throws {
        let coordinator = makeCoordinator(shell: "/bin/cat")
        let running = try coordinator.launch(cwd: "/tmp")

        coordinator.dismiss(running.id)
        XCTAssertNotNil(coordinator.store.row(id: running.id), "dismiss must not touch a running shell")

        coordinator.stop(running.id)
        try await waitUntil(coordinator.store.row(id: running.id) == nil)

        let exiting = makeCoordinator(shell: "/usr/bin/true")
        let row = try exiting.launch(cwd: "/tmp")
        try await waitUntil(exiting.store.row(id: row.id)?.state == .exited(0))
        exiting.dismiss(row.id)
        XCTAssertNil(exiting.store.row(id: row.id))
        XCTAssertNil(terminals.session(id: row.id))
    }

    func testRelaunchReplacesExitedRowWithSameCwd() async throws {
        let coordinator = makeCoordinator(shell: "/usr/bin/true")
        let row = try coordinator.launch(cwd: "/tmp")
        try await waitUntil(coordinator.store.row(id: row.id)?.state == .exited(0))

        let fresh = try coordinator.relaunch(coordinator.store.row(id: row.id)!)
        XCTAssertNil(coordinator.store.row(id: row.id), "old row replaced")
        XCTAssertEqual(fresh.cwd, "/tmp")
        XCTAssertNotEqual(fresh.id, row.id)
    }

    func testLaunchFailureLeavesNothingBehind() {
        let coordinator = makeCoordinator(shell: "/no/such/shell")
        XCTAssertThrowsError(try coordinator.launch(cwd: "/tmp"))
        XCTAssertTrue(coordinator.store.rows.isEmpty)
        XCTAssertTrue(terminals.sessions.isEmpty)
    }
}
