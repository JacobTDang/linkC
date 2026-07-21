import XCTest
@testable import LinkCKit

/// End-to-end wiring test: a real HTTP hook POST flows through the real HookServer, the
/// decoder, the store, the focus policy, and into a recording notification sink — exercising
/// the actual AppCoordinator glue with only the terminal spawn and the UN center faked out.
@MainActor
final class AppCoordinatorIntegrationTests: XCTestCase {

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

    /// Builds a coordinator wired to a real (but un-spawned) terminal manager and a fake
    /// notification center. `isWatching` returns false so notifiable states would notify.
    private func makeCoordinator(
        sink: NotificationSink,
        claudePath: String = "/x/claude",
        settingsDir: URL = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-test-\(UUID().uuidString)")
    ) -> AppCoordinator {
        AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: sink, now: { Date() }),
            claudePath: claudePath,
            settingsDir: settingsDir,
            userSettingsURL: FileManager.default.temporaryDirectory.appendingPathComponent("no-such-settings.json"),
            isWatching: { _ in false }
        )
    }

    /// Fires one hook at the live server and waits for its 200 — so by the time it returns,
    /// the event has been enqueued onto the coordinator's serial stream (respond enqueues
    /// before it replies). Awaiting each in turn thus fixes enqueue order.
    private func fireHook(port: UInt16, event: String, session: String) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook")!)
        request.httpMethod = "POST"
        request.setValue(event, forHTTPHeaderField: "X-LinkC-Event")
        request.setValue(session, forHTTPHeaderField: "X-LinkC-Session")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"session_id":"c1","cwd":"/tmp"}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    /// Polls until `predicate` holds (or times out). Used to await async event propagation.
    private func waitUntil(_ predicate: () -> Bool, iterations: Int = 100) async throws -> Bool {
        for _ in 0..<iterations {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    /// I1: a SessionEnd hook prunes the session from the store — dead entries must not
    /// accumulate — and ending a session posts no notification.
    func testSessionEndPrunesSessionFromStore() async throws {
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        try coordinator.start()
        defer { coordinator.shutdown() }

        _ = coordinator.store.create(cwd: "/tmp", title: "api", id: "L1")
        XCTAssertNotNil(coordinator.store.session(id: "L1"))

        try await fireHook(port: coordinator.hookPort, event: "session_end", session: "L1")

        let removed = try await waitUntil { coordinator.store.session(id: "L1") == nil }
        XCTAssertTrue(removed, "a SessionEnd hook must prune the session from the store")
        XCTAssertTrue(sink.deliveries.isEmpty, "ending a session must not post a notification")
    }

    /// I3: events are applied strictly in arrival order. A userPromptSubmit → stop →
    /// sessionEnd sequence must settle on the terminal end (session pruned), never stick on
    /// an earlier .working/.finished state as reordered unstructured tasks could.
    func testSerialEventSequenceSettlesOnTerminalEnd() async throws {
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        try coordinator.start()
        defer { coordinator.shutdown() }

        _ = coordinator.store.create(cwd: "/tmp", title: "api", id: "L1")

        try await fireHook(port: coordinator.hookPort, event: "user_prompt_submit", session: "L1")
        try await fireHook(port: coordinator.hookPort, event: "stop", session: "L1")
        try await fireHook(port: coordinator.hookPort, event: "session_end", session: "L1")

        let removed = try await waitUntil { coordinator.store.session(id: "L1") == nil }
        XCTAssertTrue(removed, "the terminal SessionEnd must win — the session must not be stuck working/finished")
    }

    /// A real Stop hook POST drives the store to `.finished`, binds the claude id, and — since
    /// the user is not watching (isWatching == false) — posts exactly one notification.
    func testHookPostDrivesStoreAndNotification() async throws {
        let sink = RecordingSink()
        let coordinator = makeCoordinator(sink: sink)
        try coordinator.start()
        defer { coordinator.shutdown() }

        // Seed a session the way newSession would (without launching a real terminal).
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

        let finished = try await waitUntil { coordinator.store.session(id: "L1")?.state == .finished }
        XCTAssertTrue(finished, "Stop hook should have driven session L1 to .finished")
        XCTAssertEqual(coordinator.store.session(id: "L1")?.claudeSessionId, "c1")

        // A finished session while not watching should have posted exactly one notification.
        let deliveries = sink.deliveries
        XCTAssertEqual(deliveries.count, 1)
        XCTAssertEqual(deliveries.first?.id, "L1")
        XCTAssertTrue(deliveries.first?.body.contains("finished") ?? false)
    }

    /// newSession writes the per-session settings file and launches a terminal; stopSession
    /// kills that terminal, deletes the settings file, and removes the session from the store.
    /// Uses `/bin/cat` as a stand-in for claude — a real but harmless PTY child that blocks on
    /// its input rather than exiting on its own, so the "file exists after launch" assertion
    /// isn't raced by the auto-prune that a self-exiting child would trigger.
    func testStopSessionLaunchesThenCleansUpSettingsAndSession() async throws {
        let settingsDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cleanup-\(UUID().uuidString)")
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }

        let coordinator = makeCoordinator(sink: RecordingSink(), claudePath: "/bin/cat", settingsDir: settingsDir)

        let session = try coordinator.newSession(cwd: cwd.path, mode: .new)
        let settingsFile = settingsDir.appendingPathComponent("session-\(session.id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsFile.path), "newSession must write the per-session settings file")
        XCTAssertNotNil(coordinator.terminals.session(id: session.id), "newSession must register a terminal")
        XCTAssertEqual(coordinator.terminals.selectedId, session.id, "the new session must be selected")

        coordinator.stopSession(session.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsFile.path), "stopSession must delete the per-session settings file")
        XCTAssertNil(coordinator.store.session(id: session.id), "stopSession must remove the session from the store")
        XCTAssertNil(coordinator.terminals.session(id: session.id), "stopSession must remove the terminal")
    }

    /// The launch mode maps to the right claude flag (pure mapping — no spawn needed).
    func testLaunchModeClaudeArgs() {
        XCTAssertEqual(LaunchMode.new.claudeArgs, [])
        XCTAssertEqual(LaunchMode.continueLast.claudeArgs, ["--continue"])
        XCTAssertEqual(LaunchMode.resume.claudeArgs, ["--resume"])
    }
}
