import XCTest
@testable import LinkCKit

/// Scripted git. Each `headSha` / `statusPorcelain` call takes the next queued answer; the last repeats.
final class ScriptedGit: GitInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var heads: [String]
    private var statuses: [String]
    var ancestor = true
    var changed: [String] = []
    var error: Error?

    init(heads: [String], statuses: [String] = [""]) {
        self.heads = heads
        self.statuses = statuses
    }

    func headSha(in workspace: URL) throws -> String {
        if let error { throw error }
        return lock.withLock { heads.count > 1 ? heads.removeFirst() : heads[0] }
    }
    func statusPorcelain(in workspace: URL) throws -> String {
        lock.withLock { statuses.count > 1 ? statuses.removeFirst() : statuses[0] }
    }
    func resolveCommit(_ rev: String, in workspace: URL) throws -> String { rev }
    func isAncestor(_ ancestor: String, of descendant: String, in workspace: URL) throws -> Bool { self.ancestor }
    func changedFiles(_ paths: [String], from: String, to: String, in workspace: URL) throws -> [String] { changed }
    func fileExists(_ path: String, at rev: String, in workspace: URL) throws -> Bool { true }
}

/// Records each command and returns one scripted result.
final class CommandStub: ProcessRunner, @unchecked Sendable {
    struct Call: Equatable { let executable: String; let args: [String]; let cwd: URL?; let timeout: TimeInterval }
    private let lock = NSLock()
    private var recorded: [Call] = []
    private let result: Result<ProcessResult, Error>

    var calls: [Call] { lock.withLock { recorded } }

    init(_ result: Result<ProcessResult, Error>) { self.result = result }

    func runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { recorded.append(Call(executable: executable, args: args, cwd: cwd, timeout: timeout)) }
        return try result.get()
    }
}

final class VerificationRunnerTests: XCTestCase {
    private let base = String(repeating: "b", count: 40)
    private let head = String(repeating: "c", count: 40)
    private let workspace = URL(fileURLWithPath: "/tmp/linkc-verify-workspace")
    private let verification = Verification(branch: "task/x", baseSha: String(repeating: "b", count: 40),
                                            command: "run-tests", testPaths: ["T.swift"], timeoutSeconds: 5)

    private func exits(_ status: Int32, stdout: String = "") -> CommandStub {
        CommandStub(.success(ProcessResult(status: status, stdout: stdout, stderr: "")))
    }

    private func runner(_ git: ScriptedGit, _ command: CommandStub) -> VerificationRunner {
        VerificationRunner(git: git, runner: command, shell: "/bin/zsh")
    }

    // MARK: gate

    func testGateRunsTheCommandThroughALoginShellInTheWorkspace() async {
        let command = exits(1)
        let verdict = await runner(ScriptedGit(heads: [base]), command).gate(verification, in: workspace)
        XCTAssertTrue(verdict.passed)
        XCTAssertNil(verdict.reason)
        XCTAssertEqual(verdict.exitStatus, 1)
        XCTAssertEqual(verdict.sha, base)
        XCTAssertEqual(command.calls, [CommandStub.Call(executable: "/bin/zsh", args: ["-l", "-c", "run-tests"], cwd: workspace, timeout: 5)])
    }

    func testGateRefusesWhenTestsAlreadyPass() async {
        let verdict = await runner(ScriptedGit(heads: [base]), exits(0)).gate(verification, in: workspace)
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.reason, "tests already pass at bbbbbbb; brief refused")
    }

    func testGateRefusesACommandThatCouldNotRunOrWasKilled() async {
        let missing = await runner(ScriptedGit(heads: [base]), exits(127)).gate(verification, in: workspace)
        XCTAssertEqual(missing.reason, "gate failed: command could not run (exit 127)")
        let killed = await runner(ScriptedGit(heads: [base]), exits(130)).gate(verification, in: workspace)
        XCTAssertEqual(killed.reason, "gate failed: command was killed (exit 130)")
    }

    func testGateChecksTheCheckoutBeforeRunning() async {
        let command = exits(1)
        let wrongHead = await runner(ScriptedGit(heads: [head]), command).gate(verification, in: workspace)
        XCTAssertEqual(wrongHead.reason, "gate failed: HEAD is ccccccc, expected base bbbbbbb")
        XCTAssertTrue(command.calls.isEmpty, "nothing runs on the wrong commit")
        let dirty = await runner(ScriptedGit(heads: [base], statuses: ["?? stray.swift"]), exits(1)).gate(verification, in: workspace)
        XCTAssertEqual(dirty.reason, "gate failed: working tree is not clean")
    }

    func testGateRejectsAWorkspaceThatChangedDuringTheRun() async {
        let verdict = await runner(ScriptedGit(heads: [base, head]), exits(1)).gate(verification, in: workspace)
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.reason, "gate failed: workspace changed during the gate")
    }

    func testGateTimeoutAndGitErrorBecomeReasons() async {
        let slow = CommandStub(.failure(ProcessRunnerError.timedOut(seconds: 5)))
        let timedOut = await runner(ScriptedGit(heads: [base]), slow).gate(verification, in: workspace)
        XCTAssertEqual(timedOut.reason, "gate failed: timed out after 5s")
        let git = ScriptedGit(heads: [base])
        git.error = LinkCError.process("git rev-parse HEAD exited 128: fatal: not a git repository")
        let broken = await runner(git, exits(1)).gate(verification, in: workspace)
        XCTAssertEqual(broken.reason, "gate failed: git rev-parse HEAD exited 128: fatal: not a git repository")
    }

    // MARK: verify

    func testVerifyPassesOnExitZero() async {
        let verdict = await runner(ScriptedGit(heads: [head]), exits(0)).verify(verification, sha: head, in: workspace)
        XCTAssertTrue(verdict.passed)
        XCTAssertEqual(verdict.sha, head)
        XCTAssertEqual(verdict.exitStatus, 0)
    }

    func testVerifyFailureKeepsTheOutputTail() async {
        // The marker is the last thing the command printed; it is not in the command string.
        let stdout = String(repeating: "noise ", count: 1_000) + "FIXTURE_TAIL_MARKER"
        let verdict = await runner(ScriptedGit(heads: [head]), exits(1, stdout: stdout)).verify(verification, sha: head, in: workspace)
        XCTAssertFalse(verdict.passed)
        XCTAssertEqual(verdict.reason, "tests failed at ccccccc (exit 1)")
        XCTAssertEqual(verdict.stdoutTail.count, Verdict.tailLimit)
        XCTAssertTrue(verdict.stdoutTail.hasSuffix("FIXTURE_TAIL_MARKER"))
    }

    func testVerifyRejectsTheWrongCheckout() async {
        let verdict = await runner(ScriptedGit(heads: [base]), exits(0)).verify(verification, sha: head, in: workspace)
        XCTAssertEqual(verdict.reason, "HEAD is bbbbbbb, expected ccccccc")
    }

    func testVerifyRejectsAShaThatDoesNotDescendFromBase() async {
        let git = ScriptedGit(heads: [head])
        git.ancestor = false
        let command = exits(0)
        let verdict = await runner(git, command).verify(verification, sha: head, in: workspace)
        XCTAssertEqual(verdict.reason, "ccccccc does not descend from base bbbbbbb")
        XCTAssertTrue(command.calls.isEmpty)
    }

    func testVerifyNeverRunsModifiedTests() async {
        let git = ScriptedGit(heads: [head])
        git.changed = ["T.swift"]
        let command = exits(0)
        let verdict = await runner(git, command).verify(verification, sha: head, in: workspace)
        XCTAssertEqual(verdict.reason, "test files modified: T.swift")
        XCTAssertTrue(command.calls.isEmpty, "modified tests must never run")
    }

    func testVerifyRejectsAWorkspaceThatChangedDuringTheRun() async {
        let verdict = await runner(ScriptedGit(heads: [head, base]), exits(0)).verify(verification, sha: head, in: workspace)
        XCTAssertEqual(verdict.reason, "workspace changed during verification")
    }

    func testVerifyTimeout() async {
        let slow = CommandStub(.failure(ProcessRunnerError.timedOut(seconds: 5)))
        let verdict = await runner(ScriptedGit(heads: [head]), slow).verify(verification, sha: head, in: workspace)
        XCTAssertEqual(verdict.reason, "timed out after 5s")
        XCTAssertEqual(verdict.sha, head)
        XCTAssertNil(verdict.exitStatus)
    }
}
