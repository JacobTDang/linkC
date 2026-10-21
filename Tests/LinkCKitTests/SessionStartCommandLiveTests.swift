import XCTest
@testable import LinkCKit

/// Claude Code runs a SessionStart hook only as a command: it never sends an `http` SessionStart hook,
/// though it sends `http` hooks for every other event linkC uses (observed with Claude Code 2.1.306).
/// So linkC's SessionStart is a shell command that posts the event to the hook server itself. These run
/// that exact command through `/bin/sh -c`, as the CLI does, against a real server.
final class SessionStartCommandLiveTests: XCTestCase {
    /// The server records an event before it responds, so a lock-guarded box holds every event by the
    /// time the command has finished.
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [HookEvent] = []

        func record(_ event: HookEvent) {
            lock.lock()
            stored.append(event)
            lock.unlock()
        }

        var all: [HookEvent] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// A SessionStart hook input like the real CLI's, piped to the command on stdin.
    private let input = #"{"session_id":"conv-9","transcript_path":"/tmp/conv-9.jsonl","cwd":"/tmp","hook_event_name":"SessionStart","source":"startup"}"#

    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func sessionStartCommand(port: UInt16, token: String) throws -> String {
        let hooks = SettingsComposer.linkcHooks(port: port, token: token)
        let blocks = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let entries = try XCTUnwrap(blocks.first?["hooks"] as? [[String: Any]])
        return try XCTUnwrap(entries.first?["command"] as? String)
    }

    /// Runs `script` the way the CLI runs a command hook: `/bin/sh -c`, the hook input on stdin, and
    /// the session's environment, which carries `LINKC_SESSION`.
    private func run(_ script: String, linkcSession: String, environment: [String: String] = [:]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["LINKC_SESSION": linkcSession, "PATH": "/usr/bin:/bin"].merging(environment) { _, extra in extra }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus,
                   stdout: String(decoding: out, as: UTF8.self),
                   stderr: String(decoding: err, as: UTF8.self))
    }

    func testTheCommandDeliversSessionStartForItsSession() throws {
        let server = HookServer.forTesting()
        server.requiredToken = "tok-live"
        let events = EventBox()
        server.onEvent = { events.record($0) }
        try server.start()
        defer { server.stop() }

        let result = try run(try sessionStartCommand(port: server.port, token: "tok-live"), linkcSession: "L1")

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(events.all.count, 1)
        let event = try XCTUnwrap(events.all.first)
        XCTAssertEqual(event.kind, .sessionStart)
        XCTAssertEqual(event.linkcSessionId, "L1", "the session comes from the environment the CLI runs the hook in")
        XCTAssertEqual(event.claudeSessionId, "conv-9", "the CLI's hook input reaches the server as the body")
    }

    /// The session inherits the user's environment, proxy settings included, and curl honors them even
    /// for 127.0.0.1: the post to linkC must go straight to the local server.
    func testTheCommandIgnoresAProxyInTheEnvironment() throws {
        let server = HookServer.forTesting()
        server.requiredToken = "tok-live"
        let events = EventBox()
        server.onEvent = { events.record($0) }
        try server.start()
        defer { server.stop() }

        let deadProxy = "http://127.0.0.1:9"
        let result = try run(try sessionStartCommand(port: server.port, token: "tok-live"), linkcSession: "L1",
                             environment: ["http_proxy": deadProxy, "HTTP_PROXY": deadProxy, "all_proxy": deadProxy])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(events.all.map(\.kind), [.sessionStart])
    }

    /// The CLI adds what a SessionStart hook prints to the conversation as context, so the command
    /// must print nothing, the server's response included.
    func testTheCommandPrintsNothing() throws {
        let server = HookServer.forTesting()
        server.requiredToken = "tok-live"
        try server.start()
        defer { server.stop() }

        let result = try run(try sessionStartCommand(port: server.port, token: "tok-live"), linkcSession: "L1")

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
    }

    /// The command carries the run's token: without it the server drops the event.
    func testTheCommandCarriesTheToken() throws {
        let server = HookServer.forTesting()
        server.requiredToken = "tok-live"
        let events = EventBox()
        server.onEvent = { events.record($0) }
        try server.start()
        defer { server.stop() }

        _ = try run(try sessionStartCommand(port: server.port, token: "tok-other"), linkcSession: "L1")

        XCTAssertTrue(events.all.isEmpty, "a command made with another token must not deliver")
    }

    /// With nothing listening the command fails, and says so on stderr, which the CLI shows: a missed
    /// start must not pass silently.
    func testTheCommandFailsLoudlyWhenNothingListens() throws {
        let server = HookServer.forTesting()
        try server.start()
        let port = server.port
        server.stop()

        let result = try run(try sessionStartCommand(port: port, token: "tok"), linkcSession: "L1")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.stderr.isEmpty)
        XCTAssertEqual(result.stdout, "")
    }
}
