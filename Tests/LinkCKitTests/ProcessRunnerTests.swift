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

    func testLargeStderrOnFailureStillReportsTheReason() async {
        let runner = LiveProcessRunner()
        do {
            _ = try await runner.run(
                "/bin/sh",
                args: ["-c", "yes 'noise' | head -c 100000 >&2; echo 'Access token not provided' >&2; exit 1"],
                cwd: nil, timeout: 20
            )
            XCTFail("a nonzero exit must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("noise"), "the capped detail survives")
        }
    }
}
