import XCTest
@testable import LinkCKit

/// Claude and Codex sessions launched on a tier, read back from a stand-in that records its argv: the
/// tier's effort from Settings (here never the tier's default) follows the tier's model.
@MainActor
final class AppCoordinatorEffortLaunchTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-effort-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private struct NullSink: NotificationSink {
        func deliver(id: String, title: String, body: String) {}
    }

    private func makeCoordinator(models: AgentModelSettings) throws -> AppCoordinator {
        let stub = tempDir.appendingPathComponent("stub-agent.sh")
        let script = "#!/bin/sh\n"
            + "printf '%s\\n' \"$@\" > \"$(dirname \"$0\")/argv-$LINKC_SESSION\"\n"
            + "stty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let settingsDir = tempDir.appendingPathComponent("settings")
        let agent = stub.path
        return AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: NullSink(), now: { Date() }),
            claudePath: agent,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("no-such-settings.json"),
            manifestDir: settingsDir,
            agentPathResolver: { _ in agent },
            modelSettings: { models },
            modelLists: TestModelLists.none,
            deliverySettle: 0,
            turnEndQuietPeriod: 0,
            isWatching: { _ in false }
        )
    }

    /// The argv the stand-in recorded, polled for up to five seconds until it ends in `last`.
    private func launchedArguments(of session: Session, endingIn last: String) -> [String] {
        launchedArguments(of: session) { $0.last == last }
    }

    /// The argv the stand-in recorded, polled for up to five seconds until `done` holds.
    private func launchedArguments(of session: Session, until done: ([String]) -> Bool) -> [String] {
        let file = tempDir.appendingPathComponent("argv-\(session.id)")
        var lines: [String] = []
        let deadline = Date().addingTimeInterval(5)
        while !done(lines), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        return lines
    }

    func testAClaudeTierLaunchPassesItsEffortAfterItsModel() throws {
        var models = AgentModelSettings.seeded
        models.setEffort(.xhigh, for: .claude, tier: .deep)
        let coordinator = try makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .claude, mode: .new, tier: .deep)

        let argv = launchedArguments(of: session, endingIn: "xhigh")
        XCTAssertEqual(Array(argv.suffix(4)), ["--model", "opus", "--effort", "xhigh"], "\(argv)")
        XCTAssertEqual(session.effort, .xhigh)
    }

    func testACodexTierLaunchSetsModelReasoningEffort() throws {
        var models = AgentModelSettings.seeded
        models.setEffort(.high, for: .codex, tier: .standard)
        let coordinator = try makeCoordinator(models: models)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .codex, mode: .new, tier: .standard)

        let argv = launchedArguments(of: session, endingIn: "model_reasoning_effort=\"high\"")
        XCTAssertEqual(Array(argv.suffix(4)), ["--model", "gpt-5.6-sol", "-c", "model_reasoning_effort=\"high\""], "\(argv)")
        XCTAssertEqual(session.effort, .high)
    }

    /// A session opened with no tier is the CLI's own: linkC sets no effort on it.
    func testASessionWithNoTierGetsNoEffort() throws {
        let coordinator = try makeCoordinator(models: .seeded)
        defer { coordinator.shutdown() }

        let session = try coordinator.newSession(cwd: tempDir.path, agent: .claude, mode: .new)

        let argv = launchedArguments(of: session) { $0.contains("--settings") }
        XCTAssertTrue(argv.contains("--settings"), "\(argv)")
        XCTAssertFalse(argv.contains("--effort"), "\(argv)")
        XCTAssertNil(session.effort)
    }
}
