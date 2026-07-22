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
