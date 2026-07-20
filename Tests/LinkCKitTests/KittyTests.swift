import Foundation
import XCTest
@testable import LinkCKit

// MARK: - Fixture loading

/// Loads the real `kitten @ ls` capture used across the parser and controller tests.
/// Tries both a flat and a `Fixtures`-nested resource layout since SwiftPM's exact
/// bundling of `.process("Fixtures")` isn't worth hard-coding a single assumption about.
private func loadKittyLsFixtureData() throws -> Data {
    let bundle = Bundle.module
    if let url = bundle.url(forResource: "kitty-ls", withExtension: "json") {
        return try Data(contentsOf: url)
    }
    if let url = bundle.url(forResource: "kitty-ls", withExtension: "json", subdirectory: "Fixtures") {
        return try Data(contentsOf: url)
    }
    throw LinkCError.parse("test fixture kitty-ls.json not found in test bundle")
}

private func loadKittyLsFixtureString() throws -> String {
    guard let string = String(data: try loadKittyLsFixtureData(), encoding: .utf8) else {
        throw LinkCError.parse("kitty-ls.json fixture is not valid UTF-8")
    }
    return string
}

// MARK: - Test double

/// Test-only `CommandRunner`. Records every invocation and answers via a caller-supplied
/// handler that sees the full call history (including the current call), so tests can
/// key behavior off *which* executable/argv was invoked rather than raw call order —
/// important because `KittyController.ensureWorkspaceRunning` fires a background launch
/// concurrently with its polling loop. Never used outside tests.
actor MockCommandRunner: CommandRunner {
    struct Call: Equatable, Sendable {
        let executable: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    private let handler: @Sendable ([Call]) throws -> CommandResult

    /// Always answers with the same canned result, no matter what is invoked.
    init(_ result: CommandResult) {
        handler = { _ in result }
    }

    /// Full control: invoked with every call recorded so far (the current one is `.last`).
    init(handler: @escaping @Sendable ([Call]) throws -> CommandResult) {
        self.handler = handler
    }

    func run(executable: String, arguments: [String], environment: [String: String]?) async throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments))
        return try handler(calls)
    }

    var lastCall: Call? { calls.last }
}

// MARK: - KittyLsParser

final class KittyLsParserTests: XCTestCase {
    func testParsesRealFixtureShape() throws {
        let windows = try KittyLsParser.parse(loadKittyLsFixtureData())
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].tabs.count, 2)
    }

    func testProbeSessionWindowHasExpectedCwd() throws {
        let windows = try KittyLsParser.parse(loadKittyLsFixtureData())
        let probe = try XCTUnwrap(windows.allWindows.first { $0.linkcSession == "PROBE123" })
        XCTAssertEqual(probe.cwd, "/Users/jacobdang")
    }

    func testWindowWithoutUserVarYieldsNilLinkcSession() throws {
        let windows = try KittyLsParser.parse(loadKittyLsFixtureData())
        let plain = try XCTUnwrap(windows.allWindows.first { $0.linkcSession == nil })
        XCTAssertEqual(plain.cwd, "/Users/jacobdang/Desktop/projects/linkC")
    }

    func testFocusedLinkcSessionResolves() throws {
        let windows = try KittyLsParser.parse(loadKittyLsFixtureData())
        XCTAssertEqual(windows.focusedLinkcSession, "PROBE123")
    }

    func testMalformedInputThrowsParseError() {
        XCTAssertThrowsError(try KittyLsParser.parse(Data("not json at all".utf8))) { error in
            guard case LinkCError.parse = error else {
                return XCTFail("expected LinkCError.parse, got \(error)")
            }
        }
    }

    func testEmptyInputThrowsParseError() {
        XCTAssertThrowsError(try KittyLsParser.parse(Data())) { error in
            guard case LinkCError.parse = error else {
                return XCTFail("expected LinkCError.parse, got \(error)")
            }
        }
    }
}

// MARK: - ProcessCommandRunner

final class ProcessCommandRunnerTests: XCTestCase {
    func testCapturesStdoutAndSuccessExitCode() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run(executable: "/bin/echo", arguments: ["hello", "linkc"], environment: nil)
        XCTAssertEqual(result.stdout, "hello linkc\n")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.succeeded)
    }

    func testCapturesNonZeroExitCode() async throws {
        let runner = ProcessCommandRunner()
        let result = try await runner.run(executable: "/usr/bin/false", arguments: [], environment: nil)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.succeeded)
    }

    func testThrowsProcessErrorForMissingExecutable() async {
        let runner = ProcessCommandRunner()
        do {
            _ = try await runner.run(executable: "/no/such/binary-linkc-test", arguments: [], environment: nil)
            XCTFail("expected LinkCError.process to be thrown")
        } catch LinkCError.process {
            // expected
        } catch {
            XCTFail("expected LinkCError.process, got \(error)")
        }
    }

    func testRunDetachedThrowsProcessErrorForMissingExecutable() {
        let runner = ProcessCommandRunner()
        XCTAssertThrowsError(try runner.runDetached(executable: "/no/such/binary-linkc-test", arguments: [], environment: nil)) { error in
            guard case LinkCError.process = error else {
                return XCTFail("expected LinkCError.process, got \(error)")
            }
        }
    }

    func testRunDetachedSpawnsWithoutWaitingForExit() throws {
        // A long-running child returns control immediately (no waitUntilExit), and nothing
        // is captured. `/bin/sleep 5` would block the old capture path for 5s; here it must
        // return in well under that.
        let runner = ProcessCommandRunner()
        let start = Date()
        try runner.runDetached(executable: "/bin/sleep", arguments: ["5"], environment: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0, "runDetached must not wait for the child to exit")
    }
}

// MARK: - KittyController

final class KittyControllerTests: XCTestCase {
    private let sock = "unix:/tmp/linkc-test.sock"

    private func makeController(
        runner: CommandRunner,
        maxReadinessAttempts: Int = 40,
        readinessPollInterval: Duration = .milliseconds(100)
    ) -> KittyController {
        KittyController(
            kittyPath: "/opt/kitty",
            kittenPath: "/opt/kitten",
            socketPath: sock,
            runner: runner,
            maxReadinessAttempts: maxReadinessAttempts,
            readinessPollInterval: readinessPollInterval
        )
    }

    // MARK: launchSession

    func testLaunchSessionBuildsArgvInOrderAndParsesWindowId() async throws {
        let mock = MockCommandRunner(CommandResult(stdout: "7", stderr: "", exitCode: 0))
        let controller = makeController(runner: mock)

        let windowId = try await controller.launchSession(
            command: ["claude", "--settings", "/tmp/s.json"],
            cwd: "/a b",
            title: "api",
            linkcSessionId: "L1",
            extraEnv: ["FOO": "bar"]
        )

        XCTAssertEqual(windowId, 7)
        let recordedCall = await mock.lastCall
        let call = try XCTUnwrap(recordedCall)
        XCTAssertEqual(call.executable, "/opt/kitten")
        XCTAssertEqual(call.arguments, [
            "@", "--to", sock,
            "launch", "--type=tab", "--cwd=/a b",
            "--tab-title", "api",
            "--var", "linkc_session=L1",
            "--env", "LINKC_SESSION=L1",
            "--env", "FOO=bar",
            "claude", "--settings", "/tmp/s.json",
        ])
    }

    func testLaunchSessionThrowsKittyOnNonIntegerStdout() async {
        let mock = MockCommandRunner(CommandResult(stdout: "not-a-number", stderr: "", exitCode: 0))
        let controller = makeController(runner: mock)
        do {
            _ = try await controller.launchSession(command: ["claude"], cwd: "/tmp", title: "t", linkcSessionId: "L1", extraEnv: [:])
            XCTFail("expected throw")
        } catch LinkCError.kitty {
            // expected
        } catch {
            XCTFail("expected LinkCError.kitty, got \(error)")
        }
    }

    func testLaunchSessionThrowsKittyOnNonZeroExit() async {
        let mock = MockCommandRunner(CommandResult(stdout: "", stderr: "boom", exitCode: 1))
        let controller = makeController(runner: mock)
        do {
            _ = try await controller.launchSession(command: ["claude"], cwd: "/tmp", title: "t", linkcSessionId: "L1", extraEnv: [:])
            XCTFail("expected throw")
        } catch LinkCError.kitty {
            // expected
        } catch {
            XCTFail("expected LinkCError.kitty, got \(error)")
        }
    }

    // MARK: focus / close

    func testFocusBuildsMatchArgv() async throws {
        let mock = MockCommandRunner(CommandResult(stdout: "", stderr: "", exitCode: 0))
        let controller = makeController(runner: mock)
        try await controller.focus(linkcSessionId: "L1")
        let recordedCall = await mock.lastCall
        let call = try XCTUnwrap(recordedCall)
        XCTAssertEqual(call.executable, "/opt/kitten")
        XCTAssertEqual(call.arguments, ["@", "--to", sock, "focus-tab", "--match", "var:linkc_session=L1"])
    }

    func testFocusThrowsKittyOnFailure() async {
        let mock = MockCommandRunner(CommandResult(stdout: "", stderr: "no match", exitCode: 1))
        let controller = makeController(runner: mock)
        do {
            try await controller.focus(linkcSessionId: "L1")
            XCTFail("expected throw")
        } catch LinkCError.kitty {
            // expected
        } catch {
            XCTFail("expected LinkCError.kitty, got \(error)")
        }
    }

    func testCloseBuildsMatchArgv() async throws {
        let mock = MockCommandRunner(CommandResult(stdout: "", stderr: "", exitCode: 0))
        let controller = makeController(runner: mock)
        try await controller.close(linkcSessionId: "L1")
        let recordedCall = await mock.lastCall
        let call = try XCTUnwrap(recordedCall)
        XCTAssertEqual(call.executable, "/opt/kitten")
        XCTAssertEqual(call.arguments, ["@", "--to", sock, "close-tab", "--match", "var:linkc_session=L1"])
    }

    func testCloseThrowsKittyOnFailure() async {
        let mock = MockCommandRunner(CommandResult(stdout: "", stderr: "no match", exitCode: 1))
        let controller = makeController(runner: mock)
        do {
            try await controller.close(linkcSessionId: "L1")
            XCTFail("expected throw")
        } catch LinkCError.kitty {
            // expected
        } catch {
            XCTFail("expected LinkCError.kitty, got \(error)")
        }
    }

    // MARK: list / focusedLinkcSession

    func testListParsesCannedLsOutput() async throws {
        let mock = MockCommandRunner(CommandResult(stdout: try loadKittyLsFixtureString(), stderr: "", exitCode: 0))
        let controller = makeController(runner: mock)
        let windows = try await controller.list()
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].tabs.count, 2)
        let recordedCall = await mock.lastCall
        let call = try XCTUnwrap(recordedCall)
        XCTAssertEqual(call.arguments, ["@", "--to", sock, "ls"])
    }

    func testListThrowsKittyOnFailure() async {
        let mock = MockCommandRunner(CommandResult(stdout: "", stderr: "no socket", exitCode: 1))
        let controller = makeController(runner: mock)
        do {
            _ = try await controller.list()
            XCTFail("expected throw")
        } catch LinkCError.kitty {
            // expected
        } catch {
            XCTFail("expected LinkCError.kitty, got \(error)")
        }
    }

    func testFocusedLinkcSessionResolvesFromList() async throws {
        let mock = MockCommandRunner(CommandResult(stdout: try loadKittyLsFixtureString(), stderr: "", exitCode: 0))
        let controller = makeController(runner: mock)
        let id = try await controller.focusedLinkcSession()
        XCTAssertEqual(id, "PROBE123")
    }

    // MARK: ensureWorkspaceRunning

    func testEnsureWorkspaceRunningReturnsImmediatelyWhenAlreadyUp() async throws {
        let mock = MockCommandRunner(CommandResult(stdout: "[]", stderr: "", exitCode: 0))
        let controller = makeController(runner: mock)
        try await controller.ensureWorkspaceRunning()
        let count = await mock.calls.count
        XCTAssertEqual(count, 1, "should only probe once and return — never launch when already up")
    }

    func testEnsureWorkspaceRunningLaunchesAndPollsUntilUp() async throws {
        let mock = MockCommandRunner { calls in
            let current = calls.last!
            if current.executable == "/opt/kitten" {
                let lsAttemptsSoFar = calls.filter { $0.executable == "/opt/kitten" }.count
                if lsAttemptsSoFar >= 3 {
                    return CommandResult(stdout: "[]", stderr: "", exitCode: 0)
                }
                return CommandResult(stdout: "", stderr: "connection refused", exitCode: 1)
            }
            // The one-shot launch of the kitty GUI process itself.
            return CommandResult(stdout: "", stderr: "", exitCode: 0)
        }
        let controller = makeController(runner: mock, maxReadinessAttempts: 20, readinessPollInterval: .milliseconds(5))

        try await controller.ensureWorkspaceRunning()

        // The background launch is fire-and-forget; give it a brief moment to be
        // recorded by the mock before asserting on it.
        try await Task.sleep(for: .milliseconds(50))

        let calls = await mock.calls
        let lsCalls = calls.filter { $0.executable == "/opt/kitten" }
        XCTAssertGreaterThanOrEqual(lsCalls.count, 3)

        let launchCalls = calls.filter { $0.executable == "/opt/kitty" }
        XCTAssertEqual(launchCalls.count, 1)
        XCTAssertEqual(launchCalls[0].arguments, [
            "--instance-group", "linkc",
            "-o", "allow_remote_control=yes",
            "-o", "macos_quit_when_last_window_closed=yes",
            "--listen-on", sock,
        ])
    }

    func testEnsureWorkspaceRunningThrowsKittyAfterExhaustingAttempts() async {
        let mock = MockCommandRunner(CommandResult(stdout: "", stderr: "connection refused", exitCode: 1))
        let controller = makeController(runner: mock, maxReadinessAttempts: 3, readinessPollInterval: .milliseconds(1))
        do {
            try await controller.ensureWorkspaceRunning()
            XCTFail("expected throw")
        } catch LinkCError.kitty {
            // expected
        } catch {
            XCTFail("expected LinkCError.kitty, got \(error)")
        }
    }

    func testEnsureWorkspaceRunningPropagatesRealErrorsWithoutMasking() async {
        let mock = MockCommandRunner { _ in throw LinkCError.process("kitten binary not found") }
        let controller = makeController(runner: mock, maxReadinessAttempts: 3, readinessPollInterval: .milliseconds(1))
        do {
            try await controller.ensureWorkspaceRunning()
            XCTFail("expected throw")
        } catch LinkCError.process {
            // expected: a real spawn error surfaces as-is, not masked as a generic timeout
        } catch {
            XCTFail("expected LinkCError.process to propagate untouched, got \(error)")
        }
    }

    func testEnsureWorkspaceRunningSurfacesDetachedLaunchSpawnFailure() async {
        // The kitty GUI is spawned detached — a spawn failure (e.g. missing binary) is the
        // one launch outcome we can observe synchronously, and it must surface as a kitty
        // error rather than a generic timeout.
        struct FailingLaunchRunner: CommandRunner {
            func run(executable: String, arguments: [String], environment: [String: String]?) async throws -> CommandResult {
                CommandResult(stdout: "", stderr: "connection refused", exitCode: 1) // ls probes never reachable
            }
            func runDetached(executable: String, arguments: [String], environment: [String: String]?) throws {
                throw LinkCError.process("no such file: \(executable)")
            }
        }
        let controller = makeController(runner: FailingLaunchRunner(), maxReadinessAttempts: 5, readinessPollInterval: .milliseconds(1))
        do {
            try await controller.ensureWorkspaceRunning()
            XCTFail("expected throw")
        } catch LinkCError.kitty(let message) {
            XCTAssertTrue(message.contains("failed to launch kitty"), "expected the spawn failure to surface, got: \(message)")
        } catch {
            XCTFail("expected LinkCError.kitty, got \(error)")
        }
    }
}
