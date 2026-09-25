import XCTest
@testable import LinkCKit

/// Real child processes. `/bin/sh` without `-l` stands in for the login shell, and
/// `/usr/bin/python3 -m http.server` stands in for an app.
@MainActor
final class LinkCAppProcessTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!
    private var processes: [LinkCAppProcess] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for process in processes { process.stopAndWait() }
        try FileManager.default.removeItem(at: folder)
    }

    private func app(_ start: [String], health: String = "/", timing: LinkCAppProcess.Timing = .init(healthTimeout: 20)) -> LinkCAppProcess {
        let process = LinkCAppProcess(
            folder: folder.path,
            manifest: LinkCAppManifest(name: "Test app", start: start, health: health),
            launcher: .init(shell: "/bin/sh", login: false),
            timing: timing)
        processes.append(process)
        return process
    }

    private let server = ["/usr/bin/python3", "-m", "http.server", "{port}", "--bind", "127.0.0.1"]

    private func waitUntil(_ seconds: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition never became true") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func isRunning(_ state: LinkCAppProcess.State) -> Bool {
        if case .running = state { return true }
        return false
    }

    private func groupIsGone(_ group: pid_t) -> Bool {
        kill(-group, 0) == -1 && errno == ESRCH
    }

    func testAHealthyServerRunsAndShowsItsPage() async throws {
        let process = app(server)
        process.start()
        XCTAssertEqual(process.state, .starting)
        try await waitUntil { isRunning(process.state) }
        guard case .running(let url) = process.state else { return XCTFail("not running: \(process.state)") }
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.query, "linkc=1")
    }

    func testStopEndsTheWholeGroupIncludingAChild() async throws {
        let pidFile = folder.appendingPathComponent("child.pid").path
        let process = app(["/bin/sh", "-c", "sleep 300 & echo $! > \(pidFile); exec /usr/bin/python3 -m http.server {port} --bind 127.0.0.1"])
        process.start()
        try await waitUntil { isRunning(process.state) }
        let child = try XCTUnwrap(pid_t(String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let group = try XCTUnwrap(process.processGroup)

        process.stop()
        XCTAssertEqual(process.state, .asleep)
        try await waitUntil { groupIsGone(group) }
        XCTAssertEqual(kill(child, 0), -1, "the child in the group is gone too")
    }

    func testACommandThatExitsAtOnceFailsWithItsLog() async throws {
        let process = app(["/bin/sh", "-c", "echo boom >&2; exit 3"])
        process.start()
        try await waitUntil { if case .failed = process.state { return true } else { return false } }
        guard case .failed(let reason) = process.state else { return XCTFail("\(process.state)") }
        XCTAssertTrue(reason.contains("3"), reason)
        try await waitUntil { process.log.contains("boom") }
    }

    func testAMissingCommandFailsAsNotFound() async throws {
        let process = app(["linkc-no-such-command-4711"])
        process.start()
        try await waitUntil { if case .failed = process.state { return true } else { return false } }
        guard case .failed(let reason) = process.state else { return XCTFail("\(process.state)") }
        XCTAssertTrue(reason.contains("not found"), reason)
        XCTAssertTrue(reason.contains("linkc-no-such-command-4711"), reason)
    }

    func testAServerThatNeverAnswersFailsAfterTheTimeoutAndIsStopped() async throws {
        let process = app(["/bin/sleep", "300"], timing: .init(healthTimeout: 0.6, pollInterval: 0.1))
        process.start()
        let group = try XCTUnwrap(process.processGroup)
        try await waitUntil { if case .failed = process.state { return true } else { return false } }
        guard case .failed(let reason) = process.state else { return XCTFail("\(process.state)") }
        XCTAssertTrue(reason.contains("did not answer"), reason)
        try await waitUntil { groupIsGone(group) }
    }

    func testAProcessThatIgnoresTermIsKilledAfterTheGrace() async throws {
        let process = app(["/bin/sh", "-c", "trap '' TERM; sleep 300"], timing: .init(healthTimeout: 30, stopGrace: 0.3))
        process.start()
        let group = try XCTUnwrap(process.processGroup)
        try await Task.sleep(for: .milliseconds(300))
        process.stop()
        try await waitUntil(5) { groupIsGone(group) }
    }

    func testAnAppThatDiesWhileRunningShowsExited() async throws {
        let process = app(server)
        process.start()
        try await waitUntil { isRunning(process.state) }
        let group = try XCTUnwrap(process.processGroup)
        kill(group, SIGKILL)
        try await waitUntil { if case .exited = process.state { return true } else { return false } }
        guard case .exited(let status) = process.state else { return XCTFail("\(process.state)") }
        XCTAssertEqual(status, 137)
    }

    func testTheLogKeepsTheLast200Lines() async throws {
        let process = app(["/bin/sh", "-c", "i=0; while [ $i -lt 250 ]; do echo line$i; i=$((i+1)); done; sleep 300"])
        process.start()
        try await waitUntil { process.log.last == "line249" }
        XCTAssertEqual(process.log.count, LinkCAppProcess.logLimit)
        XCTAssertEqual(process.log.first, "line50")
    }

    func testRetryStartsAgainAfterAFailure() async throws {
        let process = app(["/bin/sh", "-c", "exit 1"])
        process.start()
        try await waitUntil { if case .failed = process.state { return true } else { return false } }
        process.manifest.start = server
        process.start()
        try await waitUntil { isRunning(process.state) }
    }
}
