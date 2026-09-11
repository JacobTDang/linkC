import XCTest
@testable import LinkCKit

/// The subprocess seam every CLI call goes through. Real processes here — the timeout contract
/// is the whole point and can't be faked meaningfully.
final class ProcessRunnerTests: XCTestCase {

    func testCapturesStdout() async throws {
        let out = try await LiveProcessRunner().run("/bin/echo", args: ["hello"], cwd: nil, timeout: 5)
        XCTAssertEqual(out, "hello\n")
    }

    func testTimeoutTerminatesAndThrows() async {
        let started = Date()
        do {
            _ = try await LiveProcessRunner().run("/bin/sleep", args: ["5"], cwd: nil, timeout: 0.2)
            XCTFail("expected a timeout throw")
        } catch {
            XCTAssertTrue("\(error)".contains("timed out"), "got: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "must not wait out the child")
    }

    func testMissingExecutableThrows() async {
        do {
            _ = try await LiveProcessRunner().run("/no/such/binary", args: [], cwd: nil, timeout: 5)
            XCTFail("expected a launch throw")
        } catch {
            // Any thrown error is fine — the point is it doesn't hang or return "".
        }
    }

    func testNonZeroExitThrows() async {
        do {
            _ = try await LiveProcessRunner().run("/usr/bin/false", args: [], cwd: nil, timeout: 5)
            XCTFail("expected a non-zero-exit throw")
        } catch {
            XCTAssertTrue("\(error)".contains("status"), "got: \(error)")
        }
    }
}

/// stderr is the CLI's explanation of a failure ("Access token not provided", "Cannot
/// connect to the Docker daemon"). Discarding it left every caller unable to tell an auth
/// prompt from a crash — this is the seam that makes login-state detection possible.
final class ProcessRunnerStderrTests: XCTestCase {

    func testFailureCarriesStderrDetail() async {
        let runner = LiveProcessRunner()
        do {
            _ = try await runner.run(
                "/bin/sh", args: ["-c", "echo 'Access token not provided' >&2; exit 1"],
                cwd: nil, timeout: 10
            )
            XCTFail("a nonzero exit must throw")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("Access token not provided"),
                "the CLI's own words must survive: \(error.localizedDescription)"
            )
        }
    }

    func testSilentFailureStillReportsTheCommand() async {
        let runner = LiveProcessRunner()
        do {
            _ = try await runner.run("/bin/sh", args: ["-c", "exit 3"], cwd: nil, timeout: 10)
            XCTFail("a nonzero exit must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("status 3"))
        }
    }

    /// Advisory banners (the oci CLI emits one on every call) must not bury the reason a
    /// command actually failed.
    func testAdvisoryWarningsAreTrimmedFromTheReason() async {
        let runner = LiveProcessRunner()
        do {
            _ = try await runner.run(
                "/bin/sh",
                args: ["-c", "echo 'Warning: your key file is too permissive' >&2; echo 'Access token not provided' >&2; exit 1"],
                cwd: nil, timeout: 10
            )
            XCTFail("a nonzero exit must throw")
        } catch {
            // Assert on the reason itself: the full message also echoes the command,
            // which in this test happens to contain the warning text verbatim.
            let message = error.localizedDescription
            let reason = message.components(separatedBy: " (/bin/sh").first ?? message
            XCTAssertEqual(reason, "Access token not provided", "advisory noise is dropped")
        }
    }

    func testStdoutIsUnaffectedByStderrNoise() async throws {
        let runner = LiveProcessRunner()
        let output = try await runner.run(
            "/bin/sh", args: ["-c", "echo 'notice' >&2; echo '[{\"ok\":true}]'"],
            cwd: nil, timeout: 10
        )
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "[{\"ok\":true}]")
    }
}

/// A pipe holds ~64KB. Reading only after exit means a chatty child fills the buffer,
/// blocks on write, and never exits — so both streams must be drained while it runs.
final class ProcessRunnerBackpressureTests: XCTestCase {

    func testLargeStderrDoesNotDeadlock() async throws {
        let runner = LiveProcessRunner()
        // 200KB of stderr — comfortably past the buffer that used to deadlock.
        let output = try await runner.run(
            "/bin/sh",
            args: ["-c", "yes 'noisy diagnostic line' | head -c 200000 >&2; echo done"],
            cwd: nil, timeout: 20
        )
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "done")
    }

    func testLargeStdoutIsReturnedWhole() async throws {
        let runner = LiveProcessRunner()
        let output = try await runner.run(
            "/bin/sh", args: ["-c", "yes 'x' | head -c 200000"], cwd: nil, timeout: 20
        )
        XCTAssertEqual(output.count, 200000, "a large stdout must not be truncated or stall")
    }

    /// CLIs put banners first and the real reason last, so the cap must keep the TAIL.
    /// Capping the head would drop exactly the line that makes a failure actionable —
    /// which is how login detection would silently stop working on a chatty CLI.
    func testLargeStderrOnFailureKeepsTheLastLineNotTheFirst() async {
        let runner = LiveProcessRunner()
        // The reason is written by a script FILE, so the command echoed in the error
        // can't contain the phrase — otherwise the assertion passes on the echo rather
        // than on captured stderr.
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-cap-\(UUID().uuidString).sh")
        try? """
        yes 'noise' | head -c 100000 >&2
        printf 'AUTH_REQUIRED_MARKER\\n' >&2
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }

        do {
            _ = try await runner.run("/bin/sh", args: [script.path], cwd: nil, timeout: 20)
            XCTFail("a nonzero exit must throw")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(
                message.contains("AUTH_REQUIRED_MARKER"),
                "the actionable LAST line must survive the cap (head-capping drops it): \(message.prefix(200))"
            )
        }
    }
}

/// `runCapturing` treats the exit status as data: verification needs a failing test run's
/// status and output, not an exception.
final class ProcessRunnerCapturingTests: XCTestCase {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-capture-\(UUID().uuidString).sh")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testNonZeroExitIsReturnedNotThrown() async throws {
        // Markers come from a script FILE, so they cannot appear in the command string.
        let s = try script("printf 'OUT_MARKER_41\\n'\nprintf 'ERR_MARKER_42\\n' >&2\nexit 3\n")
        defer { try? FileManager.default.removeItem(at: s) }
        let result = try await LiveProcessRunner().runCapturing("/bin/sh", args: [s.path], cwd: nil, timeout: 10)
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stdout, "OUT_MARKER_41\n")
        XCTAssertEqual(result.stderr, "ERR_MARKER_42\n")
    }

    func testTimeoutThrowsTypedError() async {
        do {
            _ = try await LiveProcessRunner().runCapturing("/bin/sleep", args: ["5"], cwd: nil, timeout: 1)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? ProcessRunnerError, .timedOut(seconds: 1))
        }
    }

    func testSyncCoreRunsInTheWorkingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = try LiveProcessRunner.runCapturingSync(executable: "/bin/pwd", args: ["-P"], cwd: dir, timeout: 5)
        XCTAssertEqual(result.status, 0)
        // Resolve both paths to handle macOS symlink differences (/var vs /private/var)
        let pwdPath = URL(fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
        let expectedPath = dir.resolvingSymlinksInPath().path
        XCTAssertEqual(pwdPath, expectedPath)
    }
}

/// `runCapturingSync` spawns the child itself, as the leader of its own process group.
final class ProcessRunnerSpawnTests: XCTestCase {
    func testTheChildInheritsTheEnvironment() throws {
        let result = try LiveProcessRunner.runCapturingSync(executable: "/bin/sh", args: ["-c", "printf %s \"$HOME\""], cwd: nil, timeout: 5)
        XCTAssertEqual(result.stdout, ProcessInfo.processInfo.environment["HOME"])
    }

    /// As Foundation's `terminationStatus` reported it: the signal number, not a shell-style 128 + n.
    func testAChildEndedByASignalReportsTheSignalNumber() throws {
        let result = try LiveProcessRunner.runCapturingSync(executable: "/bin/sh", args: ["-c", "kill -KILL $$"], cwd: nil, timeout: 5)
        XCTAssertEqual(result.status, SIGKILL)
        XCTAssertEqual(result.signal, SIGKILL)
    }

    /// A normal exit must leave `signal` nil — only a signal death sets it.
    func testANormalExitReportsNoSignal() throws {
        let result = try LiveProcessRunner.runCapturingSync(executable: "/bin/sh", args: ["-c", "exit 0"], cwd: nil, timeout: 5)
        XCTAssertNil(result.signal)
    }

    /// `kill -9 $$` inside a login-shell `-c` string: some shells replace themselves with the
    /// last command, so the signal death reaches the runner directly rather than as exit 128 + N.
    func testASignalKillReportsTheSignalNumberViaShellDashC() throws {
        let result = try LiveProcessRunner.runCapturingSync(executable: "/bin/sh", args: ["-c", "kill -9 $$"], cwd: nil, timeout: 5)
        XCTAssertEqual(result.signal, 9)
    }

    /// Unique to this test, so pgrep matches nothing else.
    private let marker = "37.4242"

    /// Processes whose command line holds the marker, as `pid args` lines; empty when none.
    private func survivors() throws -> String {
        let result = try LiveProcessRunner.runCapturingSync(executable: "/usr/bin/pgrep", args: ["-fl", marker], cwd: nil, timeout: 5)
        XCTAssertTrue(result.status == 0 || result.status == 1, "pgrep failed: \(result.stderr)")
        return result.stdout
    }

    /// Verification runs `shell -l -c <command>`. For a compound command such as
    /// `cd pkg && swift test`, the shell forks the real work, and a timeout must stop all of it:
    /// a survivor keeps SwiftPM's lock and holds both pipes open. SIGTERM goes to the command's
    /// process group; whatever ignores it gets SIGKILL after a 2 s grace.
    func testTimeoutKillsEverythingTheCommandStarted() async throws {
        let commands = [
            "cd . && sleep \(marker)",
            "sleep \(marker) & wait",
            // The grandchild ignores SIGTERM, so only SIGKILL stops it.
            "(trap '' TERM; exec sleep \(marker)) & wait",
        ]
        for command in commands {
            let started = Date()
            do {
                _ = try await LiveProcessRunner().runCapturing("/bin/sh", args: ["-c", command], cwd: nil, timeout: 1)
                XCTFail("expected a timeout: \(command)")
            } catch {
                XCTAssertEqual(error as? ProcessRunnerError, .timedOut(seconds: 1), command)
            }
            XCTAssertLessThan(Date().timeIntervalSince(started), 4.5, "must return within a few seconds: \(command)")

            var remaining = try survivors()
            for _ in 0..<20 where !remaining.isEmpty {
                try await Task.sleep(for: .milliseconds(100))
                remaining = try survivors()
            }
            XCTAssertEqual(remaining, "", "`\(command)` left processes running after its timeout")
        }
    }
}
