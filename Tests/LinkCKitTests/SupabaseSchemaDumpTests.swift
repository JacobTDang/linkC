import XCTest
@testable import LinkCKit

final class SupabaseSchemaDumpTests: XCTestCase {
    private let projectPath = "/Users/jacob/Projects/june"

    func testRunsSupabaseDbDumpThroughTheLoginShellInTheProjectFolder() async throws {
        let runner = CommandStub(.success(ProcessResult(status: 0, stdout: "CREATE TABLE orgs ();\n", stderr: "")))
        let output = try await SupabaseSchemaDump.run(projectPath: projectPath, runner: runner)
        XCTAssertEqual(output, "CREATE TABLE orgs ();\n")
        XCTAssertEqual(runner.calls, [
            CommandStub.Call(
                executable: ShellResolver.loginShell(), args: ["-l", "-c", "supabase db dump --schema-only"],
                cwd: URL(fileURLWithPath: projectPath), timeout: 120),
        ])
    }

    func testANonzeroExitThrowsWithTheLastFiveLinesOfStderr() async {
        let stderr = (1...7).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let runner = CommandStub(.success(ProcessResult(status: 1, stdout: "", stderr: stderr)))
        do {
            _ = try await SupabaseSchemaDump.run(projectPath: projectPath, runner: runner)
            XCTFail("expected a throw")
        } catch let error as LinkCError {
            XCTAssertEqual(error.errorDescription, "line 3\nline 4\nline 5\nline 6\nline 7")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAMissingSupabaseCLIThrowsTheShellsOwnMessage() async {
        let runner = CommandStub(.success(ProcessResult(status: 127, stdout: "", stderr: "zsh:1: command not found: supabase\n")))
        do {
            _ = try await SupabaseSchemaDump.run(projectPath: projectPath, runner: runner)
            XCTFail("expected a throw")
        } catch let error as LinkCError {
            XCTAssertEqual(error.errorDescription, "zsh:1: command not found: supabase")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testANonzeroExitWithNoStderrFallsBackToTheExitStatus() async {
        let runner = CommandStub(.success(ProcessResult(status: 2, stdout: "", stderr: "")))
        do {
            _ = try await SupabaseSchemaDump.run(projectPath: projectPath, runner: runner)
            XCTFail("expected a throw")
        } catch let error as LinkCError {
            XCTAssertEqual(error.errorDescription, "supabase db dump --schema-only exited with status 2")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testATimeoutThrowsAClearMessage() async {
        let runner = CommandStub(.failure(ProcessRunnerError.timedOut(seconds: 120)))
        do {
            _ = try await SupabaseSchemaDump.run(projectPath: projectPath, runner: runner)
            XCTFail("expected a throw")
        } catch let error as LinkCError {
            XCTAssertEqual(error.errorDescription, "supabase db dump --schema-only timed out after 120s")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
