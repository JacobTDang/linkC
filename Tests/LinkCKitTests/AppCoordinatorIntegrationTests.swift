import XCTest
@testable import LinkCKit

/// End-to-end wiring test: a real HTTP hook POST flows through the real HookServer, the
/// decoder, the store, the focus policy, and into a recording notification sink — exercising
/// the actual AppCoordinator glue with only kitty and the UN center faked out.
@MainActor
final class AppCoordinatorIntegrationTests: XCTestCase {

    /// Mock kitty: `focusedLinkcSession()` triggers an `ls`; return an empty tree.
    private struct MockRunner: CommandRunner {
        func run(executable: String, arguments: [String], environment: [String: String]?) async throws -> CommandResult {
            CommandResult(stdout: "[]", stderr: "", exitCode: 0)
        }
    }

    private final class RecordingSink: NotificationSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _deliveries: [(id: String, title: String, body: String)] = []
        var deliveries: [(id: String, title: String, body: String)] {
            lock.lock(); defer { lock.unlock() }; return _deliveries
        }
        func deliver(id: String, title: String, body: String) {
            lock.lock(); _deliveries.append((id, title, body)); lock.unlock()
        }
    }

    func testHookPostDrivesStoreAndNotification() async throws {
        let sink = RecordingSink()
        let coordinator = AppCoordinator(
            kitty: KittyController(kittyPath: "/x", kittenPath: "/x", socketPath: "unix:/tmp/x.sock", runner: MockRunner()),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: sink, now: { Date() }),
            claudePath: "/x/claude",
            settingsDir: FileManager.default.temporaryDirectory.appendingPathComponent("linkc-test-\(UUID().uuidString)"),
            userSettingsURL: FileManager.default.temporaryDirectory.appendingPathComponent("no-such-settings.json"),
            frontmostBundleID: { nil } // user is NOT watching kitty → should notify
        )
        try coordinator.start()
        defer { coordinator.shutdown() }

        // Seed a session the way newSession would (without launching real kitty).
        _ = coordinator.store.create(cwd: "/tmp", title: "api", id: "L1")

        // Fire a real Stop hook at the live server.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(coordinator.hookPort)/hook")!)
        request.httpMethod = "POST"
        request.setValue("stop", forHTTPHeaderField: "X-LinkC-Event")
        request.setValue("L1", forHTTPHeaderField: "X-LinkC-Session")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"session_id":"c1","cwd":"/tmp","hook_event_name":"Stop"}"#.utf8)
        let (respData, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: respData, encoding: .utf8), "{}")

        // Let the async onEvent → handle → store/notify propagate.
        var finished = false
        for _ in 0..<100 {
            if coordinator.store.session(id: "L1")?.state == .finished { finished = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(finished, "Stop hook should have driven session L1 to .finished")
        XCTAssertEqual(coordinator.store.session(id: "L1")?.claudeSessionId, "c1")

        // A finished session while not watching kitty should have posted exactly one notification.
        let deliveries = sink.deliveries
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries.first?.id, "L1")
        XCTAssertTrue(deliveries.first?.body.contains("finished") ?? false)
    }

    /// Records every command it's asked to run so we can assert the launch argv.
    private final class RecordingRunner: CommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(exe: String, args: [String])] = []
        var calls: [(exe: String, args: [String])] {
            lock.lock(); defer { lock.unlock() }; return _calls
        }
        func run(executable: String, arguments: [String], environment: [String: String]?) async throws -> CommandResult {
            lock.lock(); _calls.append((executable, arguments)); lock.unlock()
            // Non-empty integer stdout so `ls` probes read as reachable and `launch` yields a window id.
            return CommandResult(stdout: "7", stderr: "", exitCode: 0)
        }
    }

    func testLaunchModeInjectsClaudeFlag() async throws {
        func launchArgs(for mode: LaunchMode) async throws -> [String] {
            let runner = RecordingRunner()
            let coordinator = AppCoordinator(
                kitty: KittyController(kittyPath: "/x", kittenPath: "/x", socketPath: "unix:/tmp/x.sock", runner: runner),
                hookServer: HookServer(port: 0),
                notifications: NotificationManager(sink: RecordingSink(), now: { Date() }),
                claudePath: "/usr/bin/claude",
                settingsDir: FileManager.default.temporaryDirectory.appendingPathComponent("linkc-mode-\(UUID().uuidString)"),
                userSettingsURL: FileManager.default.temporaryDirectory.appendingPathComponent("nope.json"),
                frontmostBundleID: { nil }
            )
            _ = try await coordinator.newSession(cwd: "/tmp", mode: mode)
            return try XCTUnwrap(runner.calls.first { $0.args.contains("launch") }).args
        }

        let newArgs = try await launchArgs(for: .new)
        XCTAssertTrue(newArgs.contains("/usr/bin/claude"))
        XCTAssertFalse(newArgs.contains("--continue"))
        XCTAssertFalse(newArgs.contains("--resume"))

        let continueArgs = try await launchArgs(for: .continueLast)
        XCTAssertTrue(continueArgs.contains("--continue"))
        XCTAssertFalse(continueArgs.contains("--resume"))

        let resumeArgs = try await launchArgs(for: .resume)
        XCTAssertTrue(resumeArgs.contains("--resume"))
        XCTAssertFalse(resumeArgs.contains("--continue"))
    }
}
