# Verified Task Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** linkC marks a delegated task `done` only after it runs the delegator's tests itself, at the worker's commit, and they pass. The delegator gets exactly one line for each outcome.

**Architecture:** The delegator commits tests on a branch, then passes `verify` to `linkc_delegate_task`. The task starts in `gating`. The app runs the command at the base commit, where it must fail, and then delivers the task. The worker reports a sha through `linkc_complete_task`, which moves the task to `reported`. The app then verifies at that sha: the tests must be unchanged and the command must exit 0. The app sets the result. All process work goes through `ProcessRunner` and `GitClient`. The relay depends on a `TaskVerifier` protocol so that tests can script verdicts.

**Tech Stack:** Swift 6 (strict concurrency), XCTest, SwiftPM, Foundation `Process`, git CLI.

**Spec:** `docs/superpowers/specs/2026-09-10-verified-task-completion-design.md`. Read §15 (planning amendments) first. Where §15 differs from an earlier section, §15 applies.

**Where to work:** Use a worktree branched from `main` after PR #28 merges. Until then, branch from `feat/task-protocol-v2`. All paths are relative to the repository root.

## Global Constraints

- Every target uses Swift 6 language mode with strict concurrency. Add no new package dependencies.
- `./scripts/tsan.sh` must stay clean.
- The summary limit is 1,000 characters. A verdict keeps the last 2,000 characters of stdout and of stderr.
- `Verification.timeoutSeconds` must be 1...3600. The default is 600.
- Run at most one verification in each workspace at a time, and at most `maxConcurrentVerifications` (2) in total.
- A `gating` task expires after 60 minutes.
- Every message and reason abbreviates SHAs to 7 characters (`VerificationRunner.short`).
- The MCP `serverInfo.version` changes to `0.3.0`. The v2 stability policy applies: do not change tool names, required parameters, or parameter types. You can only add optional parameters.
- The gate passes only on exit status 1–125. Verification passes only on exit status 0.
- `GitClient` status checks exclude linkC's own directory: `git status --porcelain -- . ':(exclude).linkc'`.
- Fail loud. Every failure must become a verdict reason, an `isError` tool result, or an `NSLog` that includes the task id. Do not ignore any error.
- Test doubles stay in `Tests/` only. When a test asserts on command output, use a marker that cannot appear in the command string.
- Write commit messages with a conventional-commit prefix. Do not mention any AI tool.
- Run tests from the repository root with `swift test --filter <Suite>`.

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `Sources/LinkCKit/Config/ProcessRunner.swift` | `ProcessResult`, `ProcessRunnerError`, the `runCapturing` requirement, the `run` extension, `LiveProcessRunner.runCapturingSync` | 1 |
| `Sources/LinkCKit/Git/GitClient.swift` (new) | The `GitInspecting` protocol and the synchronous `GitClient` | 2 |
| `Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift` | Modified files through `GitClient`; a task body that shows the verdict | 2, 8 |
| `Sources/LinkCKit/App/AppCoordinator.swift` | `gitStatusSummary` (replaces `inspectGitStatus`); `verifier`; `verificationsInFlight` | 2, 6 |
| `Sources/LinkCKit/Blackboard/InboxModels.swift` | `gating` and `reported` states; `Verification`; `Verdict`; report `sha`; new `InboxError` cases | 3, 9 |
| `Sources/LinkCKit/Blackboard/InboxStore.swift` | `createTask(verification:)`, `reportTask`, `resolveGate`, `adjudicate`, `acceptUnverified`, `failTask` | 4, 9 |
| `Sources/LinkCKit/Verification/VerificationRunner.swift` (new) | `TaskVerifier` and `VerificationRunner` | 5 |
| `Sources/LinkCKit/App/AppCoordinator+Relay.swift` | Start and finish verification runs; new expiry cases; the delivery frame | 6 |
| `Sources/LinkCKit/MCP/MCPServer.swift` | `verify` on delegate; `sha` on complete; verdicts in `linkc_get_task`; v0.3.0 | 7 |

Test files: `ProcessRunnerTests.swift`, `GitClientTests.swift` (new), `TaskVerificationModelTests.swift` (new), `InboxVerificationTests.swift` (new), `VerificationRunnerTests.swift` (new), `AppCoordinatorRelayTests.swift`, `MCPServerTaskTests.swift`, `MCPServerTests.swift`, `AgentDashboardAggregatorTests.swift`, `InboxTaskLifecycleTests.swift`, and `InboxStoreTests.swift`. The doubles are in `MCPServerServiceTests.swift` and `OracleDetailTests.swift`.

---

### Task 1: `runCapturing` — return the exit status as data

**Files:**
- Modify: `Sources/LinkCKit/Config/ProcessRunner.swift` (the whole file)
- Modify: `Tests/LinkCKitTests/MCPServerServiceTests.swift` (`FakeRunner`)
- Modify: `Tests/LinkCKitTests/OracleDetailTests.swift` (`ScriptedRunner`)
- Test: `Tests/LinkCKitTests/ProcessRunnerTests.swift` (add at the end)

**Interfaces:**
- Produces:
  - `ProcessResult(status: Int32, stdout: String, stderr: String)`
  - `ProcessRunnerError.timedOut(seconds: Int)`
  - The protocol's only requirement: `runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult`
  - Extension `run(_:args:cwd:timeout:) async throws -> String`, which returns the same result and error text as before
  - `LiveProcessRunner.runCapturingSync(executable: String, args: [String], cwd: URL?, timeout: TimeInterval) throws -> ProcessResult`

- [ ] **Step 1: Write the failing tests.** Add this to the end of `Tests/LinkCKitTests/ProcessRunnerTests.swift`:

```swift
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
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), dir.resolvingSymlinksInPath().path)
    }
}
```

- [ ] **Step 2: Run the tests and make sure that they fail.**

Run: `swift test --filter ProcessRunnerCapturingTests 2>&1 | tail -15`
Expected: The build fails with `value of type 'LiveProcessRunner' has no member 'runCapturing'`.

- [ ] **Step 3: Replace `Sources/LinkCKit/Config/ProcessRunner.swift` with:**

```swift
import Foundation

/// What a finished subprocess did: its exit status and both captured streams.
public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunnerError: Error, Equatable {
    case timedOut(seconds: Int)
}

/// The seam every subprocess call goes through (MCP health, plugin list, plugin toggles, task
/// verification) — faked in tests, timeout-enforced in the live implementation. Fail loud: a
/// stalled CLI must never hang the panel.
public protocol ProcessRunner: Sendable {
    /// Runs to completion and returns the exit status as data. Throws only when the process
    /// cannot start, or `ProcessRunnerError.timedOut`.
    func runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult
}

extension ProcessRunner {
    /// stdout of a command that must succeed. A non-zero status throws `LinkCError.process`
    /// carrying the CLI's own stderr reason; a timeout throws `LinkCError.process` too.
    public func run(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> String {
        let command = "\(executable) \(args.joined(separator: " "))"
        let result: ProcessResult
        do {
            result = try await runCapturing(executable, args: args, cwd: cwd, timeout: timeout)
        } catch ProcessRunnerError.timedOut(let seconds) {
            throw LinkCError.process("\(command) timed out after \(seconds)s")
        }
        guard result.status == 0 else {
            // The CLI's own words first — they carry the actionable part.
            let detail = LiveProcessRunner.meaningfulStderr(Data(result.stderr.utf8))
            throw LinkCError.process(
                detail.isEmpty
                    ? "\(command) exited with status \(result.status)"
                    : "\(detail) (\(command) exited with status \(result.status))"
            )
        }
        return result.stdout
    }
}

/// Holds what the two drain tasks read. Locked because the reads run concurrently.
private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data()
    private var _err = Data()

    var out: Data { lock.withLock { _out } }
    var err: Data { lock.withLock { _err } }

    func setOut(_ data: Data) { lock.withLock { _out = data } }
    func setErr(_ data: Data) { lock.withLock { _err = data } }
}

public struct LiveProcessRunner: ProcessRunner {
    /// Enough for a CLI's error message; a runaway stderr must not balloon an error string.
    private static let stderrCap = 4096

    /// The actionable part of stderr. CLIs prepend advisory banners (the `oci` key-
    /// permissions warning fires on every call) and put the real reason LAST, so the cap
    /// keeps the tail — capping the head would drop exactly the line worth reading.
    static func meaningfulStderr(_ data: Data) -> String {
        // Decode the tail; a multi-byte character split by the cut is dropped by the
        // lossy conversion rather than failing the whole decode.
        let tail = data.suffix(stderrCap)
        let text = String(data: tail, encoding: .utf8)
            ?? String(decoding: tail, as: UTF8.self)
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning:") }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init() {}

    public func runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.runCapturingSync(executable: executable, args: args, cwd: cwd, timeout: timeout)
        }.value
    }

    /// Synchronous core, public for callers outside an async context (`GitClient`, the MCP
    /// stdio server). The Process/Pipe pair never crosses a concurrency boundary. BOTH
    /// streams are drained on background queues WHILE the child runs: a pipe holds ~64KB, so
    /// a chatty child that fills it while nobody reads would block forever and burn the
    /// timeout. stderr is captured because CLIs say WHY they failed there.
    public static func runCapturingSync(
        executable: String, args: [String], cwd: URL?, timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        let stdout = Pipe()
        process.standardOutput = stdout
        let stderr = Pipe()
        process.standardError = stderr

        // Drain both pipes concurrently so neither can fill and stall the child.
        let collected = StreamCollector()
        let outDone = DispatchSemaphore(value: 0)
        let errDone = DispatchSemaphore(value: 0)
        let drainQueue = DispatchQueue(label: "linkc.process.drain", attributes: .concurrent)
        drainQueue.async {
            collected.setOut(stdout.fileHandleForReading.readDataToEndOfFile())
            outDone.signal()
        }
        drainQueue.async {
            collected.setErr(stderr.fileHandleForReading.readDataToEndOfFile())
            errDone.signal()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            // The drains end when the child's pipe ends close.
            _ = outDone.wait(timeout: .now() + 2)
            _ = errDone.wait(timeout: .now() + 2)
            throw ProcessRunnerError.timedOut(seconds: Int(timeout))
        }

        // Both reads finish once the child exits and its pipe ends close.
        _ = outDone.wait(timeout: .now() + 5)
        _ = errDone.wait(timeout: .now() + 5)
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: collected.out, as: UTF8.self),
            stderr: String(decoding: collected.err, as: UTF8.self)
        )
    }
}
```

- [ ] **Step 4: Change the two test doubles so that they implement the new requirement.** In `Tests/LinkCKitTests/MCPServerServiceTests.swift`, replace `FakeRunner`'s `run` method with:

```swift
    func runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { recorded.append(Call(executable: executable, args: args)) }
        return ProcessResult(status: 0, stdout: try result.get(), stderr: "")
    }
```

In `Tests/LinkCKitTests/OracleDetailTests.swift`, replace `ScriptedRunner`'s `run` method with:

```swift
    func runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { recorded.append(Call(executable: executable, args: args)) }
        let snapshot = lock.withLock { answers }
        for (token, answer) in snapshot where args.contains(token) {
            return ProcessResult(status: 0, stdout: try answer.get(), stderr: "")
        }
        throw LinkCError.process("unscripted command: \(args.joined(separator: " "))")
    }
```

- [ ] **Step 5: Make sure that there are no other conforming types.**

Run: `grep -rnE "(class|struct) [A-Za-z]+: ProcessRunner" Sources Tests`
Expected: exactly three lines, one each for `LiveProcessRunner`, `FakeRunner`, and `ScriptedRunner`. If there are more, change each one as in Step 4.

- [ ] **Step 6: Run the tests and make sure that they pass.**

Run: `swift test --filter "ProcessRunner|MCPServerServiceTests|OracleDetailTests" 2>&1 | tail -15`
Expected: PASS. The existing `ProcessRunnerTests`, `ProcessRunnerStderrTests`, and `ProcessRunnerBackpressureTests` must pass without changes. They prove that `run` kept its error text.

- [ ] **Step 7: Commit.**

```bash
git add Sources/LinkCKit/Config/ProcessRunner.swift Tests/LinkCKitTests/ProcessRunnerTests.swift Tests/LinkCKitTests/MCPServerServiceTests.swift Tests/LinkCKitTests/OracleDetailTests.swift
git commit -m "refactor(process): return the exit status as data from runCapturing; run becomes an extension over it"
```

---
### Task 2: `GitClient` — one synchronous git seam

**Files:**
- Create: `Sources/LinkCKit/Git/GitClient.swift`
- Test: `Tests/LinkCKitTests/GitClientTests.swift`
- Modify: `Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift`. Delete `inspectGitModifiedFiles(at:)` (about lines 273–311) and replace its call (about line 181).
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift`. Delete `inspectGitStatus(in:)` (starts at about line 753), add `gitStatusSummary(in:)`, and change the call in `spawnTeammate` (about line 346).
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift`. Change the call in `checkLimitsAndReroute` (about line 353).

**Interfaces:**
- Consumes: `LiveProcessRunner.runCapturingSync` (Task 1).
- Produces:
  - `protocol GitInspecting: Sendable`, with these requirements:
    - `headSha(in: URL) throws -> String`
    - `resolveCommit(_ rev: String, in: URL) throws -> String` (returns the full 40-character SHA)
    - `statusPorcelain(in: URL) throws -> String` (excludes `.linkc`)
    - `isAncestor(_ ancestor: String, of descendant: String, in: URL) throws -> Bool`
    - `changedFiles(_ paths: [String], from: String, to: String, in: URL) throws -> [String]`
    - `fileExists(_ path: String, at rev: String, in: URL) throws -> Bool`
  - Extension methods on `GitInspecting`: `isClean(in:) throws -> Bool` and `modifiedFiles(in:) throws -> [String]`.
  - `GitClient(timeout: TimeInterval = 10, gitPath: String? = GitClient.resolveGit())`
  - `GitClient.resolveGit() -> String?`
  - `AppCoordinator.gitStatusSummary(in: String) -> String?`

Each exit status in this task was checked against git 2.50.1:

| Command | Exit status |
|---|---|
| `rev-parse --verify --quiet X^{commit}` | 0 and the full SHA, or 1 if X is unknown |
| `merge-base --is-ancestor` | 0, 1, or 128 if a revision is invalid |
| `cat-file -e rev:path` for a missing path | 128, so it cannot tell a missing path from an error. Use `ls-tree`, which returns 0 with empty output. |
| `status --porcelain -- . ':(exclude).linkc'` | Hides `.linkc/`. Returns 128 outside a repository. |

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/GitClientTests.swift`:

```swift
import XCTest
@testable import LinkCKit

/// Real git against a temporary repository — which exit status means what is the contract.
final class GitClientTests: XCTestCase {
    private var repo: URL!
    private let git = GitClient()

    override func setUpWithError() throws {
        try super.setUpWithError()
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try sh("init", "-q", "-b", "main")
        try write("a\n", "Tests/Sub/X.swift")
        try write("build/\n", ".gitignore")
        try sh("add", "-A")
        try sh("commit", "-q", "-m", "base")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
        try super.tearDownWithError()
    }

    /// Runs git in the test repository with a fixed identity; fails the test on a non-zero exit.
    @discardableResult
    private func sh(_ args: String...) throws -> String {
        let result = try LiveProcessRunner.runCapturingSync(
            executable: try XCTUnwrap(GitClient.resolveGit()),
            args: ["-c", "user.email=t@t", "-c", "user.name=t"] + args, cwd: repo, timeout: 10
        )
        XCTAssertEqual(result.status, 0, "git \(args.joined(separator: " ")): \(result.stderr)")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commitNewFile() throws -> String {
        try write("c\n", "new.txt")
        try sh("add", "new.txt")
        try sh("commit", "-q", "-m", "next")
        return try git.headSha(in: repo)
    }

    func testHeadAndResolveCommit() throws {
        let head = try git.headSha(in: repo)
        XCTAssertEqual(head.count, 40)
        XCTAssertEqual(try git.resolveCommit(String(head.prefix(7)), in: repo), head)
        XCTAssertEqual(try git.resolveCommit("main", in: repo), head)
        XCTAssertThrowsError(try git.resolveCommit("deadbeef", in: repo)) {
            XCTAssertTrue($0.localizedDescription.contains("'deadbeef' is not a commit"), $0.localizedDescription)
        }
    }

    func testStatusIgnoresLinkcAndIgnoredFilesButNotUntrackedOrEdited() throws {
        XCTAssertTrue(try git.isClean(in: repo))
        try write("x", ".linkc/inbox.json")
        try write("y", "build/out")
        XCTAssertTrue(try git.isClean(in: repo), "linkC's own state and ignored files are not changes")
        try write("z", "untracked.txt")
        XCTAssertFalse(try git.isClean(in: repo), "an untracked file changes the build")
        try FileManager.default.removeItem(at: repo.appendingPathComponent("untracked.txt"))
        try write("edited\n", "Tests/Sub/X.swift")
        XCTAssertFalse(try git.isClean(in: repo))
        XCTAssertEqual(try git.modifiedFiles(in: repo), ["Tests/Sub/X.swift"])
    }

    func testIsAncestor() throws {
        let base = try git.headSha(in: repo)
        let next = try commitNewFile()
        XCTAssertTrue(try git.isAncestor(base, of: next, in: repo))
        XCTAssertFalse(try git.isAncestor(next, of: base, in: repo))
        XCTAssertThrowsError(try git.isAncestor("deadbeefdeadbeef", of: next, in: repo))
    }

    func testChangedFilesAndFileExists() throws {
        let base = try git.headSha(in: repo)
        let next = try commitNewFile()
        XCTAssertEqual(try git.changedFiles(["Tests/Sub/X.swift"], from: base, to: next, in: repo), [])
        XCTAssertEqual(try git.changedFiles(["new.txt", "Tests/Sub/X.swift"], from: base, to: next, in: repo), ["new.txt"])
        XCTAssertTrue(try git.fileExists("Tests/Sub/X.swift", at: base, in: repo))
        XCTAssertFalse(try git.fileExists("Tests/Sub/Missing.swift", at: base, in: repo))
        XCTAssertFalse(try git.fileExists("new.txt", at: base, in: repo))
    }

    func testOutsideARepositoryThrows() throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        XCTAssertThrowsError(try git.statusPorcelain(in: plain))
    }

    func testMissingGitFailsLoud() {
        XCTAssertThrowsError(try GitClient(gitPath: nil).headSha(in: repo)) {
            XCTAssertTrue($0.localizedDescription.contains("git not found"), $0.localizedDescription)
        }
    }
}
```

- [ ] **Step 2: Run the tests and make sure that they fail.**

Run: `swift test --filter GitClientTests 2>&1 | tail -10`
Expected: The build fails with `cannot find 'GitClient' in scope`.

- [ ] **Step 3: Implement.** Create `Sources/LinkCKit/Git/GitClient.swift`:

```swift
import Foundation

/// The git questions linkC asks. Synchronous: each is one short local git command, and the
/// MCP stdio server that asks some of them has no async context.
public protocol GitInspecting: Sendable {
    func headSha(in workspace: URL) throws -> String
    /// The full 40-character SHA of `rev`; throws when `rev` is not a commit.
    func resolveCommit(_ rev: String, in workspace: URL) throws -> String
    /// `git status --porcelain` with linkC's own `.linkc` directory excluded.
    func statusPorcelain(in workspace: URL) throws -> String
    func isAncestor(_ ancestor: String, of descendant: String, in workspace: URL) throws -> Bool
    /// Which of `paths` differ between the two commits.
    func changedFiles(_ paths: [String], from: String, to: String, in workspace: URL) throws -> [String]
    func fileExists(_ path: String, at rev: String, in workspace: URL) throws -> Bool
}

extension GitInspecting {
    public func isClean(in workspace: URL) throws -> Bool {
        try statusPorcelain(in: workspace).isEmpty
    }

    /// Paths named by `git status --porcelain`; for a rename, the new path.
    public func modifiedFiles(in workspace: URL) throws -> [String] {
        try statusPorcelain(in: workspace).split(separator: "\n").compactMap { line in
            let text = String(line)
            guard text.count >= 4 else { return nil }
            var path = String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return path.isEmpty ? nil : path
        }
    }
}

public struct GitClient: GitInspecting {
    public static let candidatePaths = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]

    let gitPath: String?
    let timeout: TimeInterval

    public init(timeout: TimeInterval = 10, gitPath: String? = GitClient.resolveGit()) {
        self.timeout = timeout
        self.gitPath = gitPath
    }

    public static func resolveGit() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func headSha(in workspace: URL) throws -> String {
        try output(["rev-parse", "HEAD"], in: workspace)
    }

    public func resolveCommit(_ rev: String, in workspace: URL) throws -> String {
        let args = ["rev-parse", "--verify", "--quiet", "\(rev)^{commit}"]
        let result = try git(args, in: workspace)
        switch result.status {
        case 0: return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        case 1: throw LinkCError.process("'\(rev)' is not a commit")
        default: throw failure(result, args)
        }
    }

    public func statusPorcelain(in workspace: URL) throws -> String {
        try output(["status", "--porcelain", "--", ".", ":(exclude).linkc"], in: workspace)
    }

    public func isAncestor(_ ancestor: String, of descendant: String, in workspace: URL) throws -> Bool {
        let args = ["merge-base", "--is-ancestor", ancestor, descendant]
        let result = try git(args, in: workspace)
        switch result.status {
        case 0: return true
        case 1: return false
        default: throw failure(result, args)
        }
    }

    public func changedFiles(_ paths: [String], from: String, to: String, in workspace: URL) throws -> [String] {
        try output(["diff", "--name-only", from, to, "--"] + paths, in: workspace)
            .split(separator: "\n").map(String.init)
    }

    public func fileExists(_ path: String, at rev: String, in workspace: URL) throws -> Bool {
        // `cat-file -e` exits 128 for a missing path — the same status as a real error.
        // `ls-tree` exits 0 and prints nothing.
        !(try output(["ls-tree", "--name-only", rev, "--", path], in: workspace)).isEmpty
    }

    private func git(_ args: [String], in workspace: URL) throws -> ProcessResult {
        guard let gitPath else {
            throw LinkCError.process("git not found (looked in \(Self.candidatePaths.joined(separator: ", ")))")
        }
        return try LiveProcessRunner.runCapturingSync(executable: gitPath, args: args, cwd: workspace, timeout: timeout)
    }

    /// stdout of a git command that must exit 0, minus trailing newlines. Leading spaces are
    /// kept: they are part of porcelain status lines (" M path").
    private func output(_ args: [String], in workspace: URL) throws -> String {
        let result = try git(args, in: workspace)
        guard result.status == 0 else { throw failure(result, args) }
        var text = result.stdout
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }

    private func failure(_ result: ProcessResult, _ args: [String]) -> LinkCError {
        let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return LinkCError.process("git \(args.joined(separator: " ")) exited \(result.status)\(reason.isEmpty ? "" : ": \(reason)")")
    }
}
```

- [ ] **Step 4: Run the tests and make sure that they pass.**

Run: `swift test --filter GitClientTests 2>&1 | tail -10`
Expected: PASS, 6 tests.

- [ ] **Step 5: Replace the aggregator's git spawner.** In `AgentDashboardAggregator.swift`, delete the whole `private func inspectGitModifiedFiles(at path: String) -> [String]`. Then replace these two lines:

```swift
        // 7. Inspect modified files in git
        let modifiedFiles = inspectGitModifiedFiles(at: norm)
```

with:

```swift
        // 7. Modified files in git. A workspace that is not a git repository has none.
        let modifiedFiles = (try? GitClient().modifiedFiles(in: URL(fileURLWithPath: norm))) ?? []
```

- [ ] **Step 6: Replace the coordinator's git spawner.** In `AppCoordinator.swift`, delete the whole `func inspectGitStatus(in workspacePath: String) -> String?`, including its nested `DataBox` class. Add this in its place:

```swift
    /// `git status --porcelain` for the handoff memo, or nil when the folder is not a git
    /// repository or has no changes. One-second timeout: callers run on the main actor.
    func gitStatusSummary(in workspacePath: String) -> String? {
        guard let text = try? GitClient(timeout: 1).statusPorcelain(in: URL(fileURLWithPath: workspacePath)),
              !text.isEmpty else { return nil }
        return text
    }
```

In `spawnTeammate`, change `let gitSummary = inspectGitStatus(in: norm)` to `let gitSummary = gitStatusSummary(in: norm)`. In `AppCoordinator+Relay.swift`, change `gitSummary: inspectGitStatus(in: norm),` to `gitSummary: gitStatusSummary(in: norm),`.

- [ ] **Step 7: Make sure that neither spawner is left.**

Run: `grep -rn "inspectGit" Sources Tests`
Expected: no output.

- [ ] **Step 8: Run the tests that use these callers.**

Run: `swift test --filter "GitClientTests|AgentDashboardAggregatorTests|AppCoordinatorRelayTests|AppCoordinatorIntegrationTests" 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 9: Commit.**

```bash
git add Sources/LinkCKit/Git/GitClient.swift Tests/LinkCKitTests/GitClientTests.swift Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift Sources/LinkCKit/App/AppCoordinator.swift Sources/LinkCKit/App/AppCoordinator+Relay.swift
git commit -m "feat(git): add GitClient and replace both hand-rolled git spawners"
```

---
### Task 3: Models — `gating`, `reported`, `Verification`, `Verdict`

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/InboxModels.swift`
- Test: `Tests/LinkCKitTests/TaskVerificationModelTests.swift`

**Interfaces:**
- Produces:
  - `TaskState.gating` and `TaskState.reported`
  - `Verification(branch:baseSha:command:testPaths:timeoutSeconds: = 600)` with `.validationError: String?`
  - `Verdict(passed:sha:exitStatus:reason:stdoutTail:stderrTail:ranAt: = Date())`
  - `Verdict.notRun(reason:sha: = nil)` and `Verdict.tailLimit` (2_000)
  - `TaskReport(status:summary:sha: = nil, commits: = [], tests: = [])` and `TaskReport.summaryLimit` (1_000). Task 9 removes `tests`.
  - New `TaskRecord` fields: `verification: Verification?`, `gate: Verdict?`, `verdict: Verdict?`
  - New `InboxError` cases: `invalidVerification(String)`, `summaryTooLong(count: Int)`, `shaRequired`, `invalidReportStatus(String)`, `notVerified(String)`, `verificationPresent(String)`
- The v2 transitions `delivered → done` and `started → done` stay for now. Task 9 removes them together with `completeTask`, which still depends on them.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/TaskVerificationModelTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class TaskVerificationModelTests: XCTestCase {
    private let base = String(repeating: "b", count: 40)

    func testGatingAndReportedAreOpen() {
        XCTAssertTrue(TaskState.gating.isOpen)
        XCTAssertTrue(TaskState.reported.isOpen)
    }

    func testNewTransitions() {
        XCTAssertTrue(TaskState.gating.canTransition(to: .queued))
        XCTAssertTrue(TaskState.gating.canTransition(to: .cancelled))
        XCTAssertTrue(TaskState.gating.canTransition(to: .expired))
        XCTAssertFalse(TaskState.gating.canTransition(to: .delivered))
        XCTAssertTrue(TaskState.delivered.canTransition(to: .reported))
        XCTAssertTrue(TaskState.started.canTransition(to: .reported))
        XCTAssertFalse(TaskState.queued.canTransition(to: .reported))
        for next: TaskState in [.done, .failed, .cancelled, .expired] {
            XCTAssertTrue(TaskState.reported.canTransition(to: next), "reported -> \(next)")
        }
        XCTAssertFalse(TaskState.reported.canTransition(to: .started))
    }

    func testVerificationValidation() {
        func v(branch: String = "task/x", sha: String? = nil, command: String = "./check.sh",
               paths: [String] = ["check.sh"], timeout: Int = 600) -> Verification {
            Verification(branch: branch, baseSha: sha ?? base, command: command, testPaths: paths, timeoutSeconds: timeout)
        }
        XCTAssertNil(v().validationError)
        XCTAssertEqual(v(branch: " ").validationError, "branch is empty")
        XCTAssertEqual(v(command: "").validationError, "command is empty")
        XCTAssertEqual(v(paths: []).validationError, "test_paths is empty")
        XCTAssertEqual(v(sha: "3f9e2c1").validationError, "base_sha must be a full 40-character lowercase SHA")
        XCTAssertEqual(v(sha: String(repeating: "B", count: 40)).validationError, "base_sha must be a full 40-character lowercase SHA")
        XCTAssertEqual(v(timeout: 0).validationError, "timeout_seconds must be between 1 and 3600")
        XCTAssertEqual(v(timeout: 3601).validationError, "timeout_seconds must be between 1 and 3600")
        XCTAssertEqual(Verification(branch: "b", baseSha: base, command: "c", testPaths: ["t"]).timeoutSeconds, 600)
    }

    func testNotRunVerdict() {
        let verdict = Verdict.notRun(reason: "worker reported failure")
        XCTAssertFalse(verdict.passed)
        XCTAssertNil(verdict.sha)
        XCTAssertNil(verdict.exitStatus)
        XCTAssertEqual(verdict.reason, "worker reported failure")
    }

    /// An inbox written by v2 — reports carry `tests`, tasks carry no verification — must decode.
    func testInboxWrittenBeforeVerificationDecodes() throws {
        let json = """
        {"version":2,"workspacePath":"/w","updatedAt":"2026-09-09T12:00:00Z","messages":[],"agentLimits":[],
         "tasks":[{"id":"t1","fromAgent":"claude","toAgent":"codex","prompt":"p","files":[],"state":"done","hop":0,
         "createdAt":"2026-09-09T12:00:00Z","leaseExpiresAt":"2026-09-09T16:00:00Z",
         "report":{"status":"done","summary":"s","commits":["abc"],"tests":["swift test"]},
         "unreportedTurnEndNotified":false}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let task = try XCTUnwrap(decoder.decode(Inbox.self, from: Data(json.utf8)).tasks.first)
        XCTAssertNil(task.verification)
        XCTAssertNil(task.gate)
        XCTAssertNil(task.verdict)
        XCTAssertNil(task.report?.sha)
        XCTAssertEqual(task.report?.commits, ["abc"])
    }

    func testNewErrorDescriptions() {
        XCTAssertEqual(InboxError.summaryTooLong(count: 1001).localizedDescription,
                       "Rejected: summary is 1001 characters; the limit is 1,000.")
        XCTAssertEqual(InboxError.shaRequired.localizedDescription,
                       "Rejected: this task is verified; report the sha of your commit.")
        XCTAssertEqual(InboxError.invalidVerification("command is empty").localizedDescription,
                       "Rejected: invalid verify — command is empty.")
    }
}
```

- [ ] **Step 2: Run the tests and make sure that they fail.**

Run: `swift test --filter TaskVerificationModelTests 2>&1 | tail -10`
Expected: The build fails. `TaskState` has no member `gating`, and `Verification` is not in scope.

- [ ] **Step 3: Implement in `InboxModels.swift`.** Replace the `TaskState` enum with:

```swift
/// Lifecycle state of a delegated task. See spec §5.1 for the transition table.
public enum TaskState: String, Codable, Sendable, CaseIterable {
    case gating, queued, delivered, started, reported, done, failed, cancelled, expired

    public var isOpen: Bool {
        switch self {
        case .gating, .queued, .delivered, .started, .reported: return true
        case .done, .failed, .cancelled, .expired: return false
        }
    }

    public func canTransition(to next: TaskState) -> Bool {
        switch (self, next) {
        case (.gating, .queued), (.gating, .cancelled), (.gating, .expired):
            return true
        case (.queued, .delivered), (.queued, .cancelled), (.queued, .expired):
            return true
        case (.delivered, .started), (.delivered, .reported), (.delivered, .done), (.delivered, .failed),
             (.delivered, .cancelled), (.delivered, .expired):
            return true
        case (.started, .reported), (.started, .done), (.started, .failed), (.started, .cancelled), (.started, .expired):
            return true
        case (.reported, .done), (.reported, .failed), (.reported, .cancelled), (.reported, .expired):
            return true
        default:
            return false
        }
    }
}
```

Replace the `TaskReport` struct with the following, and add `Verification` and `Verdict` directly after it:

```swift
/// The assignee's report, supplied through `linkc_complete_task`. For a verified task it is a
/// claim: linkC decides the outcome by running the verification at `sha`.
public struct TaskReport: Codable, Sendable, Equatable {
    public static let summaryLimit = 1_000

    public let status: String   // "done" | "failed"
    public let summary: String
    public let sha: String?
    public let commits: [String]
    public let tests: [String]

    public init(status: String, summary: String, sha: String? = nil, commits: [String] = [], tests: [String] = []) {
        self.status = status
        self.summary = summary
        self.sha = sha
        self.commits = commits
        self.tests = tests
    }
}

/// How linkC checks a task: the delegator's tests, committed at `baseSha` on `branch`, run by `command`.
public struct Verification: Codable, Sendable, Equatable {
    public static let defaultTimeoutSeconds = 600
    public static let timeoutRange = 1...3600

    public let branch: String
    public let baseSha: String
    public let command: String
    public let testPaths: [String]
    public let timeoutSeconds: Int

    public init(branch: String, baseSha: String, command: String, testPaths: [String],
                timeoutSeconds: Int = Verification.defaultTimeoutSeconds) {
        self.branch = branch
        self.baseSha = baseSha
        self.command = command
        self.testPaths = testPaths
        self.timeoutSeconds = timeoutSeconds
    }

    /// Nil when valid; otherwise what is wrong.
    public var validationError: String? {
        if branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "branch is empty" }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "command is empty" }
        if testPaths.isEmpty { return "test_paths is empty" }
        if baseSha.count != 40 || !baseSha.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return "base_sha must be a full 40-character lowercase SHA"
        }
        if !Verification.timeoutRange.contains(timeoutSeconds) { return "timeout_seconds must be between 1 and 3600" }
        return nil
    }
}

/// The result of a gate or a verification. `passed` means the check succeeded: for the gate,
/// that the tests ran and failed at base; for verification, that they passed at `sha`.
public struct Verdict: Codable, Sendable, Equatable {
    public static let tailLimit = 2_000

    public let passed: Bool
    public let sha: String?        // the commit the command ran at; nil if it never ran
    public let exitStatus: Int32?  // nil if the command never finished
    public let reason: String?     // set whenever passed == false
    public let stdoutTail: String
    public let stderrTail: String
    public let ranAt: Date

    public init(passed: Bool, sha: String?, exitStatus: Int32?, reason: String?,
                stdoutTail: String, stderrTail: String, ranAt: Date = Date()) {
        self.passed = passed
        self.sha = sha
        self.exitStatus = exitStatus
        self.reason = reason
        self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail
        self.ranAt = ranAt
    }

    /// A failed verdict reached without the command finishing.
    public static func notRun(reason: String, sha: String? = nil) -> Verdict {
        Verdict(passed: false, sha: sha, exitStatus: nil, reason: reason, stdoutTail: "", stderrTail: "")
    }
}
```

In `TaskRecord`, add these three stored properties after `unreportedTurnEndNotified`:

```swift
    public var verification: Verification?
    public var gate: Verdict?
    public var verdict: Verdict?
```

Add these three parameters to the end of its `init` parameter list:

```swift
        verification: Verification? = nil,
        gate: Verdict? = nil,
        verdict: Verdict? = nil
```

Add these three assignments to the end of the `init` body:

```swift
        self.verification = verification
        self.gate = gate
        self.verdict = verdict
```

In `InboxError`, add these cases after `case emptySummary`:

```swift
    case invalidVerification(String)
    case summaryTooLong(count: Int)
    case shaRequired
    case invalidReportStatus(String)
    case notVerified(String)
    case verificationPresent(String)
```

Add these arms to `errorDescription`, after the `.emptySummary` arm:

```swift
        case .invalidVerification(let reason):
            return "Rejected: invalid verify — \(reason)."
        case .summaryTooLong(let count):
            return "Rejected: summary is \(count) characters; the limit is 1,000."
        case .shaRequired:
            return "Rejected: this task is verified; report the sha of your commit."
        case .invalidReportStatus(let status):
            return "Rejected: status must be \"done\" or \"failed\", not \"\(status)\"."
        case .notVerified(let id):
            return "Task \(id.prefix(8)) has no verification."
        case .verificationPresent(let id):
            return "Task \(id.prefix(8)) is verified; linkC must adjudicate it."
```

- [ ] **Step 4: Run the tests and make sure that they pass, including the existing inbox suites.**

Run: `swift test --filter "TaskVerificationModelTests|InboxStoreTests|InboxTaskLifecycleTests" 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/LinkCKit/Blackboard/InboxModels.swift Tests/LinkCKitTests/TaskVerificationModelTests.swift
git commit -m "feat(inbox): add gating and reported states, Verification, Verdict, and a report sha"
```

---
### Task 4: `InboxStore` — create, report, gate, adjudicate, fail

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/InboxStore.swift`
- Test: `Tests/LinkCKitTests/InboxVerificationTests.swift`

**Interfaces:**
- Consumes: the Task 3 models.
- Produces:
  - `createTask(from:to:prompt:files:hop:force:verification: Verification? = nil, timeout:)`. A task with a verification starts in `gating`. The dedupe key also includes `verification?.baseSha`.
  - `reportTask(taskId: String, report: TaskReport, timeout:) throws` (`delivered | started → reported`)
  - `resolveGate(taskId: String, verdict: Verdict, timeout:) throws` (`gating → queued | cancelled`)
  - `adjudicate(taskId: String, verdict: Verdict, timeout:) throws` (`reported → done | failed`, verified tasks only)
  - `acceptUnverified(taskId: String, timeout:) throws` (`reported → done | failed`, unverified tasks only)
  - `failTask(taskId: String, reason: String, timeout:) throws` (`delivered | started → failed`)
- `completeTask` stays until Task 9.

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/InboxVerificationTests.swift`:

```swift
import XCTest
@testable import LinkCKit

final class InboxVerificationTests: XCTestCase {
    private var tempDir: URL!
    private var store: InboxStore!
    private let base = String(repeating: "b", count: 40)
    private let sha = String(repeating: "d", count: 40)

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-verify-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = InboxStore(workspaceRoot: tempDir.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func verification(base other: String? = nil) -> Verification {
        Verification(branch: "task/x", baseSha: other ?? base, command: "./check.sh", testPaths: ["check.sh"])
    }

    private func verdict(passed: Bool, sha: String? = nil, exit: Int32? = nil, reason: String? = nil) -> Verdict {
        Verdict(passed: passed, sha: sha, exitStatus: exit, reason: reason, stdoutTail: "", stderrTail: "")
    }

    /// A verified task past its gate and delivered to session "s".
    private func deliveredVerifiedTask(_ prompt: String = "Make check pass") throws -> TaskRecord {
        let task = try store.createTask(from: .claude, to: .codex, prompt: prompt, files: [], verification: verification())
        try store.resolveGate(taskId: task.id, verdict: verdict(passed: true, sha: base, exit: 1))
        try store.markTaskDelivered(taskId: task.id, sessionId: "s")
        return try XCTUnwrap(store.task(id: task.id))
    }

    private func deliveredPlainTask(_ prompt: String = "Plain") throws -> TaskRecord {
        let task = try store.createTask(from: .claude, to: .codex, prompt: prompt, files: [])
        try store.markTaskDelivered(taskId: task.id, sessionId: "s")
        return task
    }

    func testVerifiedTaskStartsGatingAndPlainTaskStartsQueued() throws {
        XCTAssertEqual(try store.createTask(from: .claude, to: .codex, prompt: "V", files: [], verification: verification()).state, .gating)
        XCTAssertEqual(try store.createTask(from: .claude, to: .codex, prompt: "P", files: []).state, .queued)
    }

    func testInvalidVerificationIsRejected() {
        let bad = Verification(branch: "task/x", baseSha: base, command: " ", testPaths: ["check.sh"])
        XCTAssertThrowsError(try store.createTask(from: .claude, to: .codex, prompt: "V", files: [], verification: bad)) {
            XCTAssertEqual($0 as? InboxError, .invalidVerification("command is empty"))
        }
    }

    func testDedupeKeyIncludesTheBase() throws {
        let first = try store.createTask(from: .claude, to: .codex, prompt: "Same", files: [], verification: verification())
        let again = try store.createTask(from: .claude, to: .codex, prompt: "Same", files: [], verification: verification())
        let rebased = try store.createTask(from: .claude, to: .codex, prompt: "Same", files: [],
                                           verification: verification(base: String(repeating: "e", count: 40)))
        XCTAssertEqual(again.id, first.id)
        XCTAssertNotEqual(rebased.id, first.id)
    }

    func testResolveGate() throws {
        let red = try store.createTask(from: .claude, to: .codex, prompt: "Red", files: [], verification: verification())
        try store.resolveGate(taskId: red.id, verdict: verdict(passed: true, sha: base, exit: 1))
        let queued = try XCTUnwrap(store.task(id: red.id))
        XCTAssertEqual(queued.state, .queued)
        XCTAssertEqual(queued.gate?.exitStatus, 1)

        let green = try store.createTask(from: .claude, to: .codex, prompt: "Green", files: [], verification: verification())
        try store.resolveGate(taskId: green.id, verdict: verdict(passed: false, sha: base, exit: 0,
                                                                  reason: "tests already pass at bbbbbbb; brief refused"))
        let cancelled = try XCTUnwrap(store.task(id: green.id))
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(cancelled.cancelReason, "tests already pass at bbbbbbb; brief refused")
        XCTAssertNotNil(cancelled.finishedAt)

        XCTAssertThrowsError(try store.resolveGate(taskId: red.id, verdict: verdict(passed: true)), "only a gating task has a gate")
    }

    func testReportTaskMovesToReportedAndExtendsTheLease() throws {
        let task = try deliveredVerifiedTask()
        let before = Date()
        try store.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "did it", sha: sha))
        let reported = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(reported.state, .reported)
        XCTAssertEqual(reported.report?.sha, sha)
        XCTAssertGreaterThanOrEqual(reported.leaseExpiresAt.timeIntervalSince(before), TaskRecord.leaseDuration - 1)
        XCTAssertTrue(try store.load().messages.isEmpty, "reporting sends nothing")
    }

    func testSummaryLimit() throws {
        let ok = try deliveredPlainTask("Ok")
        XCTAssertNoThrow(try store.reportTask(taskId: ok.id, report: TaskReport(status: "done", summary: String(repeating: "a", count: 1_000))))
        let long = try deliveredPlainTask("Long")
        XCTAssertThrowsError(try store.reportTask(taskId: long.id, report: TaskReport(status: "done", summary: String(repeating: "a", count: 1_001)))) {
            XCTAssertEqual($0 as? InboxError, .summaryTooLong(count: 1_001))
        }
    }

    func testShaIsRequiredOnlyForAVerifiedDoneReport() throws {
        let verified = try deliveredVerifiedTask()
        XCTAssertThrowsError(try store.reportTask(taskId: verified.id, report: TaskReport(status: "done", summary: "x"))) {
            XCTAssertEqual($0 as? InboxError, .shaRequired)
        }
        XCTAssertEqual(try store.task(id: verified.id)?.state, .delivered)
        XCTAssertNoThrow(try store.reportTask(taskId: verified.id, report: TaskReport(status: "failed", summary: "gave up")))
        let plain = try deliveredPlainTask()
        XCTAssertNoThrow(try store.reportTask(taskId: plain.id, report: TaskReport(status: "done", summary: "x")))
    }

    func testReportStatusMustBeDoneOrFailed() throws {
        let task = try deliveredPlainTask()
        XCTAssertThrowsError(try store.reportTask(taskId: task.id, report: TaskReport(status: "maybe", summary: "x"))) {
            XCTAssertEqual($0 as? InboxError, .invalidReportStatus("maybe"))
        }
    }

    func testAdjudicate() throws {
        let pass = try deliveredVerifiedTask("Pass")
        try store.reportTask(taskId: pass.id, report: TaskReport(status: "done", summary: "x", sha: sha))
        try store.adjudicate(taskId: pass.id, verdict: verdict(passed: true, sha: sha, exit: 0))
        let done = try XCTUnwrap(store.task(id: pass.id))
        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(done.verdict?.sha, sha)
        XCTAssertNotNil(done.finishedAt)

        let fail = try deliveredVerifiedTask("Fail")
        try store.reportTask(taskId: fail.id, report: TaskReport(status: "done", summary: "x", sha: sha))
        try store.adjudicate(taskId: fail.id, verdict: verdict(passed: false, sha: sha, exit: 1, reason: "tests failed at ddddddd (exit 1)"))
        XCTAssertEqual(try store.task(id: fail.id)?.state, .failed)

        let plain = try deliveredPlainTask()
        try store.reportTask(taskId: plain.id, report: TaskReport(status: "done", summary: "x"))
        XCTAssertThrowsError(try store.adjudicate(taskId: plain.id, verdict: verdict(passed: true))) {
            XCTAssertEqual($0 as? InboxError, .notVerified(plain.id))
        }

        let early = try deliveredVerifiedTask("Early")
        XCTAssertThrowsError(try store.adjudicate(taskId: early.id, verdict: verdict(passed: true)), "only a reported task can be adjudicated")
    }

    func testAcceptUnverified() throws {
        let done = try deliveredPlainTask("Done")
        try store.reportTask(taskId: done.id, report: TaskReport(status: "done", summary: "x"))
        try store.acceptUnverified(taskId: done.id)
        XCTAssertEqual(try store.task(id: done.id)?.state, .done)

        let failed = try deliveredPlainTask("Failed")
        try store.reportTask(taskId: failed.id, report: TaskReport(status: "failed", summary: "x"))
        try store.acceptUnverified(taskId: failed.id)
        XCTAssertEqual(try store.task(id: failed.id)?.state, .failed)

        let verified = try deliveredVerifiedTask()
        try store.reportTask(taskId: verified.id, report: TaskReport(status: "done", summary: "x", sha: sha))
        XCTAssertThrowsError(try store.acceptUnverified(taskId: verified.id)) {
            XCTAssertEqual($0 as? InboxError, .verificationPresent(verified.id))
        }
    }

    func testFailTask() throws {
        let task = try deliveredPlainTask()
        try store.markTaskStarted(taskId: task.id)
        try store.failTask(taskId: task.id, reason: "assignee session ended before reporting")
        let failed = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.cancelReason, "assignee session ended before reporting")

        let reported = try deliveredPlainTask("Reported")
        try store.reportTask(taskId: reported.id, report: TaskReport(status: "done", summary: "x"))
        XCTAssertThrowsError(try store.failTask(taskId: reported.id, reason: "x"), "the relay settles a reported task")
    }
}
```

- [ ] **Step 2: Run the tests and make sure that they fail.**

Run: `swift test --filter InboxVerificationTests 2>&1 | tail -10`
Expected: The build fails with `extra argument 'verification' in call`.

- [ ] **Step 3: Change `createTask`.** In `InboxStore.swift`, replace the whole `createTask` function (including its doc comment) with:

```swift
    /// Creates a task with an exclusive lease on `files`. A task with a verification starts in
    /// `gating`; linkC delivers it only after confirming its tests fail at base. Refuses when
    /// another assignee holds an open lease on any of the files unless `force`. Idempotent for
    /// an identical assignee, prompt, and base.
    public func createTask(
        from: AgentKind,
        to: AgentKind,
        prompt: String,
        files: [String],
        hop: Int = 0,
        force: Bool = false,
        verification: Verification? = nil,
        timeout: TimeInterval = 5.0
    ) throws -> TaskRecord {
        guard hop <= 2 else { throw InboxError.hopLimit(hop) }
        guard !LinkCFrame.beginsWithMarker(prompt) else { throw InboxError.framedBody }
        if let reason = verification?.validationError { throw InboxError.invalidVerification(reason) }

        return try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            let normalized = files.map { ($0 as NSString).standardizingPath }

            if let existing = inbox.tasks.first(where: {
                $0.state.isOpen && $0.toAgent == to && $0.prompt == prompt
                    && $0.verification?.baseSha == verification?.baseSha
            }) {
                return existing
            }

            if !force && !normalized.isEmpty {
                let holders = inbox.tasks.filter { other in
                    other.state.isOpen && other.toAgent != to && !Set(other.files).isDisjoint(with: normalized)
                }
                if !holders.isEmpty { throw InboxError.leaseConflict(holders: holders) }
            }

            let task = TaskRecord(
                fromAgent: from, toAgent: to, prompt: prompt, files: normalized,
                state: verification == nil ? .queued : .gating, hop: hop, verification: verification
            )
            inbox.tasks.append(task)
            inbox.updatedAt = Date()
            try saveUnlocked(inbox)
            return task
        }
    }
```

- [ ] **Step 4: Add the new lifecycle methods.** Insert these directly after `cancelTask`:

```swift
    /// The worker's report: `delivered | started → reported`. Enqueues nothing — the relay
    /// settles the task and tells the delegator. Extends the lease so a late report cannot
    /// expire while it waits for its verdict.
    public func reportTask(taskId: String, report: TaskReport, timeout: TimeInterval = 5.0) throws {
        let summary = report.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw InboxError.emptySummary }
        guard summary.count <= TaskReport.summaryLimit else { throw InboxError.summaryTooLong(count: summary.count) }
        guard report.status == "done" || report.status == "failed" else { throw InboxError.invalidReportStatus(report.status) }
        try transition(taskId: taskId, timeout: timeout, target: { task in
            if task.verification != nil && report.status == "done" && report.sha == nil { throw InboxError.shaRequired }
            return .reported
        }, mutate: { task in
            task.report = report
            task.leaseExpiresAt = Date().addingTimeInterval(TaskRecord.leaseDuration)
        })
    }

    /// Records the gate: `gating → queued` when the tests failed at base, else `→ cancelled`.
    public func resolveGate(taskId: String, verdict: Verdict, timeout: TimeInterval = 5.0) throws {
        let next: TaskState = verdict.passed ? .queued : .cancelled
        try transition(taskId: taskId, timeout: timeout, target: { task in
            guard task.state == .gating else { throw InboxError.illegalTransition(taskId: taskId, from: task.state, to: next) }
            return next
        }, mutate: { task in
            task.gate = verdict
            if !verdict.passed {
                task.cancelReason = verdict.reason
                task.finishedAt = Date()
            }
        })
    }

    /// linkC's verdict on a verified task: `reported → done | failed`.
    public func adjudicate(taskId: String, verdict: Verdict, timeout: TimeInterval = 5.0) throws {
        let next: TaskState = verdict.passed ? .done : .failed
        try transition(taskId: taskId, timeout: timeout, target: { task in
            guard task.state == .reported else { throw InboxError.illegalTransition(taskId: taskId, from: task.state, to: next) }
            guard task.verification != nil else { throw InboxError.notVerified(taskId) }
            return next
        }, mutate: { task in
            task.verdict = verdict
            task.finishedAt = Date()
        })
    }

    /// Settles an unverified task on the worker's word: `reported → done | failed`.
    public func acceptUnverified(taskId: String, timeout: TimeInterval = 5.0) throws {
        try transition(taskId: taskId, timeout: timeout, target: { task in
            let next: TaskState = task.report?.status == "done" ? .done : .failed
            guard task.state == .reported else { throw InboxError.illegalTransition(taskId: taskId, from: task.state, to: next) }
            guard task.verification == nil else { throw InboxError.verificationPresent(taskId) }
            return next
        }, mutate: { task in
            task.finishedAt = Date()
        })
    }

    /// linkC failing a task whose assignee can no longer report (its session ended).
    public func failTask(taskId: String, reason: String, timeout: TimeInterval = 5.0) throws {
        try transition(taskId: taskId, timeout: timeout, target: { task in
            guard task.state == .delivered || task.state == .started else {
                throw InboxError.illegalTransition(taskId: taskId, from: task.state, to: .failed)
            }
            return .failed
        }, mutate: { task in
            task.cancelReason = reason
            task.finishedAt = Date()
        })
    }
```

- [ ] **Step 5: Let a transition check the record under the lock.** Replace the private `transition(taskId:to:timeout:mutate:)` with these two functions:

```swift
    private func transition(
        taskId: String,
        to next: TaskState,
        timeout: TimeInterval,
        mutate: (inout TaskRecord) -> Void
    ) throws {
        try transition(taskId: taskId, timeout: timeout, target: { _ in next }, mutate: mutate)
    }

    /// `target` runs under the lock with the current record; it validates and names the next state.
    private func transition(
        taskId: String,
        timeout: TimeInterval,
        target: (TaskRecord) throws -> TaskState,
        mutate: (inout TaskRecord) -> Void
    ) throws {
        try withFileLock(timeout: timeout) {
            var inbox = try loadUnlocked()
            guard let idx = inbox.tasks.firstIndex(where: { $0.id == taskId }) else {
                throw InboxError.taskNotFound(taskId)
            }
            let current = inbox.tasks[idx].state
            let next = try target(inbox.tasks[idx])
            guard current.canTransition(to: next) else {
                throw InboxError.illegalTransition(taskId: taskId, from: current, to: next)
            }
            inbox.tasks[idx].state = next
            mutate(&inbox.tasks[idx])
            inbox.updatedAt = Date()
            try saveUnlocked(inbox)
        }
    }
```

- [ ] **Step 6: Run the tests and make sure that they pass, including the existing inbox suites.**

Run: `swift test --filter "InboxVerificationTests|InboxStoreTests|InboxTaskLifecycleTests" 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 7: Commit.**

```bash
git add Sources/LinkCKit/Blackboard/InboxStore.swift Tests/LinkCKitTests/InboxVerificationTests.swift
git commit -m "feat(inbox): report, gate, adjudicate, and fail tasks; verified tasks start gating"
```

---
### Task 5: `VerificationRunner` — every outcome is a verdict

**Files:**
- Create: `Sources/LinkCKit/Verification/VerificationRunner.swift`
- Test: `Tests/LinkCKitTests/VerificationRunnerTests.swift`

**Interfaces:**
- Consumes: `ProcessRunner.runCapturing` and `ProcessRunnerError` (Task 1); `GitInspecting` (Task 2); `Verification`, `Verdict`, and `Verdict.notRun` (Task 3); `ShellResolver.loginShell()` (existing).
- Produces:
  - `protocol TaskVerifier: Sendable`, with `gate(_:in:) async -> Verdict` and `verify(_:sha:in:) async -> Verdict`
  - `VerificationRunner(git: any GitInspecting = GitClient(), runner: any ProcessRunner = LiveProcessRunner(), shell: String = ShellResolver.loginShell())`
  - `VerificationRunner.short(_ sha: String) -> String` (7 characters)
- Reason strings. Tasks 6, 7, and 8 depend on them exactly:

  | Check | Reasons |
  |---|---|
  | Gate | `gate failed: HEAD is <h7>, expected base <b7>`, `gate failed: working tree is not clean`, `gate failed: workspace changed during the gate`, `tests already pass at <b7>; brief refused`, `gate failed: command could not run (exit <n>)`, `gate failed: command was killed (exit <n>)`, `gate failed: timed out after <n>s`, `gate failed: <git error>` |
  | Verify | `HEAD is <h7>, expected <s7>`, `working tree is not clean`, `<s7> does not descend from base <b7>`, `test files modified: <paths>`, `workspace changed during verification`, `tests failed at <s7> (exit <n>)`, `timed out after <n>s` |

- [ ] **Step 1: Write the failing tests.** Create `Tests/LinkCKitTests/VerificationRunnerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests and make sure that they fail.**

Run: `swift test --filter VerificationRunnerTests 2>&1 | tail -10`
Expected: The build fails with `cannot find 'VerificationRunner' in scope`.

- [ ] **Step 3: Implement.** Create `Sources/LinkCKit/Verification/VerificationRunner.swift`:

```swift
import Foundation

/// Runs a task's verification and turns every outcome into a `Verdict`. The relay depends on
/// this protocol so tests can script verdicts.
public protocol TaskVerifier: Sendable {
    /// Checks that the tests fail at base. `passed` means they ran and failed (exit 1–125).
    func gate(_ verification: Verification, in workspace: URL) async -> Verdict
    /// Checks that the tests pass at `sha`, unchanged since base.
    func verify(_ verification: Verification, sha: String, in workspace: URL) async -> Verdict
}

public struct VerificationRunner: TaskVerifier {
    let git: any GitInspecting
    let runner: any ProcessRunner
    let shell: String

    public init(
        git: any GitInspecting = GitClient(),
        runner: any ProcessRunner = LiveProcessRunner(),
        shell: String = ShellResolver.loginShell()
    ) {
        self.git = git
        self.runner = runner
        self.shell = shell
    }

    /// Seven characters — the abbreviation every message and reason uses.
    public static func short(_ sha: String) -> String { String(sha.prefix(7)) }

    public func gate(_ v: Verification, in workspace: URL) async -> Verdict {
        if let problem = checkout(v.baseSha, label: "base ", in: workspace) {
            return .notRun(reason: "gate failed: \(problem)")
        }
        let result: ProcessResult
        do {
            result = try await execute(v, in: workspace)
        } catch {
            return .notRun(reason: "gate failed: \(Self.describe(error))", sha: v.baseSha)
        }
        if checkout(v.baseSha, label: "base ", in: workspace) != nil {
            return Self.verdict(result, sha: v.baseSha, reason: "gate failed: workspace changed during the gate")
        }
        switch result.status {
        case 1...125:
            return Self.verdict(result, sha: v.baseSha, reason: nil)
        case 0:
            return Self.verdict(result, sha: v.baseSha, reason: "tests already pass at \(Self.short(v.baseSha)); brief refused")
        case 126, 127:
            return Self.verdict(result, sha: v.baseSha, reason: "gate failed: command could not run (exit \(result.status))")
        default:
            return Self.verdict(result, sha: v.baseSha, reason: "gate failed: command was killed (exit \(result.status))")
        }
    }

    public func verify(_ v: Verification, sha: String, in workspace: URL) async -> Verdict {
        if let problem = checkout(sha, label: "", in: workspace) {
            return .notRun(reason: problem)
        }
        do {
            guard try git.isAncestor(v.baseSha, of: sha, in: workspace) else {
                return .notRun(reason: "\(Self.short(sha)) does not descend from base \(Self.short(v.baseSha))")
            }
            // Before the command: modified tests must never run.
            let changed = try git.changedFiles(v.testPaths, from: v.baseSha, to: sha, in: workspace)
            guard changed.isEmpty else {
                return .notRun(reason: "test files modified: \(changed.joined(separator: ", "))")
            }
        } catch {
            return .notRun(reason: Self.describe(error))
        }
        let result: ProcessResult
        do {
            result = try await execute(v, in: workspace)
        } catch {
            return .notRun(reason: Self.describe(error), sha: sha)
        }
        if checkout(sha, label: "", in: workspace) != nil {
            return Self.verdict(result, sha: sha, reason: "workspace changed during verification")
        }
        return Self.verdict(result, sha: sha,
                            reason: result.status == 0 ? nil : "tests failed at \(Self.short(sha)) (exit \(result.status))")
    }

    /// Nil when HEAD is `expected` and the tree is clean; otherwise what is wrong.
    private func checkout(_ expected: String, label: String, in workspace: URL) -> String? {
        do {
            let head = try git.headSha(in: workspace)
            guard head == expected else { return "HEAD is \(Self.short(head)), expected \(label)\(Self.short(expected))" }
            guard try git.isClean(in: workspace) else { return "working tree is not clean" }
            return nil
        } catch {
            return Self.describe(error)
        }
    }

    private func execute(_ v: Verification, in workspace: URL) async throws -> ProcessResult {
        // A login shell loads PATH and dotfiles; a GUI app's inherited PATH cannot find `swift`.
        try await runner.runCapturing(shell, args: ["-l", "-c", v.command], cwd: workspace,
                                      timeout: TimeInterval(v.timeoutSeconds))
    }

    /// `passed` is exactly "no reason": every failing path sets one.
    private static func verdict(_ r: ProcessResult, sha: String, reason: String?) -> Verdict {
        Verdict(
            passed: reason == nil, sha: sha, exitStatus: r.status, reason: reason,
            stdoutTail: String(r.stdout.suffix(Verdict.tailLimit)),
            stderrTail: String(r.stderr.suffix(Verdict.tailLimit))
        )
    }

    private static func describe(_ error: Error) -> String {
        if let timeout = error as? ProcessRunnerError, case .timedOut(let seconds) = timeout {
            return "timed out after \(seconds)s"
        }
        return error.localizedDescription
    }
}
```

- [ ] **Step 4: Run the tests and make sure that they pass.**

Run: `swift test --filter VerificationRunnerTests 2>&1 | tail -10`
Expected: PASS, 13 tests.

- [ ] **Step 5: Commit.**

```bash
git add Sources/LinkCKit/Verification/VerificationRunner.swift Tests/LinkCKitTests/VerificationRunnerTests.swift
git commit -m "feat(verification): add VerificationRunner — gate at base, verify at sha, every outcome a verdict"
```

---
### Task 6: Relay — gate and verify off the main actor, one line per outcome

**Files:**
- Modify: `Sources/LinkCKit/App/AppCoordinator.swift` (stored properties and the designated `init`)
- Modify: `Sources/LinkCKit/App/AppCoordinator+Relay.swift`
- Test: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: `TaskVerifier` and `VerificationRunner.short` (Task 5); `reportTask`, `resolveGate`, `adjudicate`, `acceptUnverified`, and `failTask` (Task 4).
- Produces:
  - `AppCoordinator.init(…, claudeJsonURL:, verifier: any TaskVerifier = VerificationRunner(), isWatching:)`
  - `verificationsInFlight: Set<String>` (internal)
  - `static let maxConcurrentVerifications = 2`
  - `launchVerifications(workspacePath:inboxStore:)`
  - `finishVerification(of:verdict:workspacePath:)`
- Message bodies, which the store wraps as `[linkC task <id8>] <body>`:
  - `cancelled — <gate reason>`
  - `done — verified at <s7>`
  - `failed — <reason>`
  - `done (unverified)`
  - `failed — worker reported failure`
  - `failed — report is missing its sha`
  - `expired — gate did not run within 60m`
  - `expired — lease lapsed before verification`
  - `failed — assignee session ended before reporting`
  - `expired — lease lapsed without a report`

- [ ] **Step 1: Extend the test harness.** In `AppCoordinatorRelayTests.swift`:
  - Give `makeCoordinator` a verifier. Change its signature to `private func makeCoordinator(sink: NotificationSink = RecordingSink(), verifier: any TaskVerifier = VerificationRunner()) -> AppCoordinator`.
  - Pass `verifier: verifier,` between `agentPathResolver:` and `isWatching:` in the `AppCoordinator(...)` call.
  - Add this at the end of the file, outside the class:

```swift
/// Returns scripted verdicts and records each call. With `hold`, every run waits for `release()`.
private final class ScriptedVerifier: TaskVerifier, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private let hold: Bool
    private let gateVerdict: Verdict
    private let verifyVerdict: Verdict

    init(gate: Verdict = .fixture(passed: true, exit: 1), verify: Verdict = .fixture(passed: true, exit: 0), hold: Bool = false) {
        self.gateVerdict = gate
        self.verifyVerdict = verify
        self.hold = hold
    }

    var calls: [String] { lock.withLock { recorded } }

    func gate(_ verification: Verification, in workspace: URL) async -> Verdict {
        await record("gate \(workspace.lastPathComponent)")
        return gateVerdict
    }

    func verify(_ verification: Verification, sha: String, in workspace: URL) async -> Verdict {
        await record("verify \(sha.prefix(7))")
        return verifyVerdict
    }

    /// Lets every waiting run finish.
    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { held.removeAll() }
            return held
        }
        waiting.forEach { $0.resume() }
    }

    private func record(_ call: String) async {
        guard hold else {
            lock.withLock { recorded.append(call) }
            return
        }
        // Record and park under one lock, so a run counted in `calls` can always be released.
        await withCheckedContinuation { continuation in
            lock.withLock {
                recorded.append(call)
                held.append(continuation)
            }
        }
    }
}

private extension Verdict {
    static func fixture(passed: Bool, sha: String? = nil, exit: Int32? = nil, reason: String? = nil) -> Verdict {
        Verdict(passed: passed, sha: sha, exitStatus: exit, reason: reason, stdoutTail: "", stderrTail: "")
    }
}
```

- [ ] **Step 2: Update the dead-assignee assertion.** In `testExpireTasksForStaleQueueAndDeadAssignee`, replace `XCTAssertEqual(dead.report?.summary, "assignee session ended before reporting")` with:

```swift
        XCTAssertEqual(dead.cancelReason, "assignee session ended before reporting")
```

- [ ] **Step 3: Write the failing tests.** Add this inside the class, after the last test:

```swift
    // MARK: - Verification

    private let base40 = String(repeating: "b", count: 40)
    private let sha40 = String(repeating: "d", count: 40)

    private func verification() -> Verification {
        Verification(branch: "task/x", baseSha: base40, command: "./check.sh", testPaths: ["check.sh"])
    }

    /// A verified task moved through its gate and delivery to `reported`.
    private func reportedVerifiedTask(_ inbox: InboxStore, status: String = "done") throws -> TaskRecord {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Make check pass", files: [], verification: verification())
        try inbox.resolveGate(taskId: task.id, verdict: .fixture(passed: true, sha: base40, exit: 1))
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "worker")
        try inbox.reportTask(taskId: task.id, report: TaskReport(status: status, summary: "did it", sha: status == "done" ? sha40 : nil))
        return try XCTUnwrap(inbox.task(id: task.id))
    }

    /// The outcome lines the delegator received for `task`.
    private func lines(_ inbox: InboxStore, _ task: TaskRecord) throws -> [String] {
        try inbox.load().messages.filter { $0.taskId == task.id && $0.kind == .completion }.map(\.prompt)
    }

    @MainActor
    func testGateRedQueuesTheTaskSilently() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let verifier = ScriptedVerifier(gate: .fixture(passed: true, sha: base40, exit: 1))
        let coordinator = makeCoordinator(verifier: verifier)
        defer { coordinator.shutdown() }
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Make check pass", files: [], verification: verification())

        coordinator.launchVerifications(workspacePath: ws, inboxStore: inbox)

        let queued = try await waitUntil { (try? inbox.task(id: task.id))?.state == .queued }
        XCTAssertTrue(queued)
        XCTAssertEqual(verifier.calls.count, 1)
        XCTAssertEqual(try inbox.task(id: task.id)?.gate?.exitStatus, 1)
        XCTAssertTrue(try lines(inbox, task).isEmpty, "a red gate sends nothing")
    }

    @MainActor
    func testGateRefusalCancelsWithOneLine() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let reason = "tests already pass at bbbbbbb; brief refused"
        let coordinator = makeCoordinator(verifier: ScriptedVerifier(gate: .fixture(passed: false, sha: base40, exit: 0, reason: reason)))
        defer { coordinator.shutdown() }
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Make check pass", files: [], verification: verification())

        coordinator.launchVerifications(workspacePath: ws, inboxStore: inbox)

        let cancelled = try await waitUntil { (try? inbox.task(id: task.id))?.state == .cancelled }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(try inbox.task(id: task.id)?.cancelReason, reason)
        XCTAssertEqual(try lines(inbox, task), ["[linkC task \(task.shortId)] cancelled — \(reason)"])
    }

    @MainActor
    func testVerifiedPassMovesToDoneWithOneLine() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let verifier = ScriptedVerifier(verify: .fixture(passed: true, sha: sha40, exit: 0))
        let coordinator = makeCoordinator(verifier: verifier)
        defer { coordinator.shutdown() }
        let task = try reportedVerifiedTask(inbox)

        coordinator.launchVerifications(workspacePath: ws, inboxStore: inbox)

        let done = try await waitUntil { (try? inbox.task(id: task.id))?.state == .done }
        XCTAssertTrue(done)
        XCTAssertEqual(verifier.calls, ["verify ddddddd"])
        XCTAssertEqual(try lines(inbox, task), ["[linkC task \(task.shortId)] done — verified at ddddddd"])
    }

    @MainActor
    func testVerifiedFailureCarriesTheReason() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let reason = "tests failed at ddddddd (exit 1)"
        let coordinator = makeCoordinator(verifier: ScriptedVerifier(verify: .fixture(passed: false, sha: sha40, exit: 1, reason: reason)))
        defer { coordinator.shutdown() }
        let task = try reportedVerifiedTask(inbox)

        coordinator.launchVerifications(workspacePath: ws, inboxStore: inbox)

        let failed = try await waitUntil { (try? inbox.task(id: task.id))?.state == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(try inbox.task(id: task.id)?.verdict?.reason, reason)
        XCTAssertEqual(try lines(inbox, task), ["[linkC task \(task.shortId)] failed — \(reason)"])
    }

    @MainActor
    func testUnverifiedReportSettlesWithoutARun() throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let verifier = ScriptedVerifier()
        let coordinator = makeCoordinator(verifier: verifier)
        defer { coordinator.shutdown() }
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Plain", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "worker")
        try inbox.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "did it"))

        coordinator.launchVerifications(workspacePath: ws, inboxStore: inbox)

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .done)
        XCTAssertTrue(verifier.calls.isEmpty)
        XCTAssertEqual(try lines(inbox, task), ["[linkC task \(task.shortId)] done (unverified)"])
    }

    @MainActor
    func testWorkerFailureSettlesWithoutARun() throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let verifier = ScriptedVerifier()
        let coordinator = makeCoordinator(verifier: verifier)
        defer { coordinator.shutdown() }
        let task = try reportedVerifiedTask(inbox, status: "failed")

        coordinator.launchVerifications(workspacePath: ws, inboxStore: inbox)

        let settled = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(settled.state, .failed)
        XCTAssertEqual(settled.verdict?.reason, "worker reported failure")
        XCTAssertTrue(verifier.calls.isEmpty)
        XCTAssertEqual(try lines(inbox, task), ["[linkC task \(task.shortId)] failed — worker reported failure"])
    }

    @MainActor
    func testReportWithoutShaFailsWithoutARun() throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let verifier = ScriptedVerifier()
        let coordinator = makeCoordinator(verifier: verifier)
        defer { coordinator.shutdown() }
        let task = try reportedVerifiedTask(inbox)
        // reportTask refuses this shape; a hand-edited inbox.json can still contain it.
        var raw = try inbox.load()
        let idx = try XCTUnwrap(raw.tasks.firstIndex { $0.id == task.id })
        raw.tasks[idx].report = TaskReport(status: "done", summary: "did it")
        try inbox.saveRaw(raw)

        coordinator.launchVerifications(workspacePath: ws, inboxStore: inbox)

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .failed)
        XCTAssertTrue(verifier.calls.isEmpty)
        XCTAssertEqual(try lines(inbox, task), ["[linkC task \(task.shortId)] failed — report is missing its sha"])
    }

    @MainActor
    func testRunsAreSerializedPerWorkspace() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let verifier = ScriptedVerifier(hold: true)
        let coordinator = makeCoordinator(verifier: verifier)
        defer { coordinator.shutdown() }
        let first = try inbox.createTask(from: .claude, to: .codex, prompt: "First", files: [], verification: verification())
        let second = try inbox.createTask(from: .claude, to: .codex, prompt: "Second", files: [], verification: verification())

        coordinator.launchVerifications(workspacePath: ws, inboxStore: inbox)
        let one = try await waitUntil { verifier.calls.count == 1 }
        XCTAssertTrue(one)
        coordinator.launchVerifications(workspacePath: ws, inboxStore: inbox)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(verifier.calls.count, 1, "a second run in the same workspace must wait")

        verifier.release()
        let firstQueued = try await waitUntil { (try? inbox.task(id: first.id))?.state == .queued }
        XCTAssertTrue(firstQueued)
        coordinator.launchVerifications(workspacePath: ws, inboxStore: inbox)
        let two = try await waitUntil { verifier.calls.count == 2 }
        XCTAssertTrue(two)
        verifier.release()
        let secondQueued = try await waitUntil { (try? inbox.task(id: second.id))?.state == .queued }
        XCTAssertTrue(secondQueued)
    }

    @MainActor
    func testAtMostTwoRunsAtOnce() async throws {
        let verifier = ScriptedVerifier(hold: true)
        let coordinator = makeCoordinator(verifier: verifier)
        defer { coordinator.shutdown() }
        var workspaces: [(path: String, inbox: InboxStore)] = []
        for name in ["w1", "w2", "w3"] {
            let path = tempDir.appendingPathComponent(name).path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            let inbox = InboxStore(workspaceRoot: path)
            _ = try inbox.createTask(from: .claude, to: .codex, prompt: "Task in \(name)", files: [], verification: verification())
            workspaces.append((path, inbox))
        }

        for w in workspaces { coordinator.launchVerifications(workspacePath: w.path, inboxStore: w.inbox) }
        let two = try await waitUntil { verifier.calls.count == 2 }
        XCTAssertTrue(two)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(verifier.calls.count, AppCoordinator.maxConcurrentVerifications)

        verifier.release()
        let drained = try await waitUntil { coordinator.verificationsInFlight.isEmpty }
        XCTAssertTrue(drained)
        coordinator.launchVerifications(workspacePath: workspaces[2].path, inboxStore: workspaces[2].inbox)
        let three = try await waitUntil { verifier.calls.count == 3 }
        XCTAssertTrue(three)
        verifier.release()
        let finished = try await waitUntil { coordinator.verificationsInFlight.isEmpty }
        XCTAssertTrue(finished)
    }

    @MainActor
    func testGatingTaskExpiresAfterSixtyMinutes() throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator(verifier: ScriptedVerifier())
        defer { coordinator.shutdown() }
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Old gate", files: [], verification: verification())
        var raw = try inbox.load()
        raw.tasks[0] = TaskRecord(id: task.id, fromAgent: .claude, toAgent: .codex, prompt: "Old gate", state: .gating,
                                  createdAt: Date().addingTimeInterval(-61 * 60), verification: verification())
        try inbox.saveRaw(raw)

        coordinator.expireTasks(workspacePath: ws, inboxStore: inbox)

        let expired = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(expired.state, .expired)
        XCTAssertEqual(expired.cancelReason, "gate did not run within 60m")
        XCTAssertEqual(try lines(inbox, task), ["[linkC task \(task.shortId)] expired — gate did not run within 60m"])
    }

    @MainActor
    func testReportedTaskSurvivesAssigneeExitButNotItsLease() throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let coordinator = makeCoordinator(verifier: ScriptedVerifier())
        defer { coordinator.shutdown() }
        let task = try reportedVerifiedTask(inbox) // its session "worker" does not exist

        coordinator.expireTasks(workspacePath: ws, inboxStore: inbox)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .reported, "a worker may exit after reporting")

        var raw = try inbox.load()
        let idx = try XCTUnwrap(raw.tasks.firstIndex { $0.id == task.id })
        raw.tasks[idx].leaseExpiresAt = Date().addingTimeInterval(-1)
        try inbox.saveRaw(raw)
        coordinator.expireTasks(workspacePath: ws, inboxStore: inbox)

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .expired)
        XCTAssertEqual(try lines(inbox, task), ["[linkC task \(task.shortId)] expired — lease lapsed before verification"])
    }

    @MainActor
    func testVerdictForAnEndedTaskIsDropped() async throws {
        let ws = tempDir.path
        let inbox = InboxStore(workspaceRoot: ws)
        let verifier = ScriptedVerifier(verify: .fixture(passed: true, sha: sha40, exit: 0), hold: true)
        let coordinator = makeCoordinator(verifier: verifier)
        defer { coordinator.shutdown() }
        let task = try reportedVerifiedTask(inbox)

        coordinator.launchVerifications(workspacePath: ws, inboxStore: inbox)
        let running = try await waitUntil { verifier.calls.count == 1 }
        XCTAssertTrue(running)
        try inbox.cancelTask(taskId: task.id, reason: "scope changed")
        verifier.release()
        let finished = try await waitUntil { coordinator.verificationsInFlight.isEmpty }
        XCTAssertTrue(finished)

        XCTAssertEqual(try inbox.task(id: task.id)?.state, .cancelled)
        XCTAssertNil(try inbox.task(id: task.id)?.verdict)
        XCTAssertTrue(try lines(inbox, task).isEmpty, "a dropped verdict sends nothing")
    }

    @MainActor
    func testDeliveryFrameNamesBranchCommandAndProtectedTests() {
        let verified = TaskRecord(fromAgent: .claude, toAgent: .codex, prompt: "Make check pass", verification: verification())
        let frame = AppCoordinator.deliveryFrame(for: verified)
        XCTAssertTrue(frame.hasPrefix("[linkC task \(verified.shortId) from Claude Code]\nMake check pass\n"))
        XCTAssertTrue(frame.contains("Work on branch task/x. linkC verifies by running `./check.sh` at the sha you report. Do not modify: check.sh."))
        XCTAssertTrue(frame.contains("linkc_complete_task(\"\(verified.id)\", status, summary, sha)"))

        let plain = TaskRecord(fromAgent: .claude, toAgent: .codex, prompt: "Plain")
        XCTAssertFalse(AppCoordinator.deliveryFrame(for: plain).contains("Work on branch"))
    }
```

- [ ] **Step 4: Run the tests and make sure that they fail.**

Run: `swift test --filter AppCoordinatorRelayTests 2>&1 | tail -10`
Expected: The build fails with `extra argument 'verifier' in call` and `value of type 'AppCoordinator' has no member 'launchVerifications'`.

- [ ] **Step 5: Give the coordinator a verifier.** In `AppCoordinator.swift`, add these properties directly after the `let agentPathResolver` property:

```swift
    /// Runs task gates and verifications off the main actor; injected so tests can script verdicts.
    let verifier: any TaskVerifier
    /// Workspaces with a verification run in flight — at most one run per workspace.
    var verificationsInFlight: Set<String> = []
```

In the designated `init`, add the parameter `verifier: any TaskVerifier = VerificationRunner(),` directly after `claudeJsonURL: URL? = nil,`. Add `self.verifier = verifier` directly after `self.claudeJsonURL = claudeJsonURL`. The convenience initializers rely on the default and don't change.

- [ ] **Step 6: Change the relay.** In `AppCoordinator+Relay.swift`, replace `processPendingMessages` with:

```swift
    /// One relay tick for `workspacePath`: expire, deliver tasks, deliver messages, verify.
    public func processPendingMessages(workspacePath: String) {
        let norm = (workspacePath as NSString).standardizingPath
        let inboxStore = InboxStore(workspaceRoot: norm)
        expireTasks(workspacePath: norm, inboxStore: inboxStore)
        dispatchTasks(workspacePath: norm, inboxStore: inboxStore)
        dispatchMessages(workspacePath: norm, inboxStore: inboxStore)
        launchVerifications(workspacePath: norm, inboxStore: inboxStore)
    }
```

Add this after `static let queuedTaskExpiry`:

```swift
    /// Verification runs in flight across all workspaces; each is a full build and test run.
    static let maxConcurrentVerifications = 2
```

Replace `deliveryFrame(for:)` with:

```swift
    /// The text injected into the assignee's terminal. Composed at injection time; never stored as a message.
    static func deliveryFrame(for task: TaskRecord) -> String {
        var lines = ["[linkC task \(task.shortId) from \(task.fromAgent.displayName)]", task.prompt, ""]
        if let v = task.verification {
            lines.append("Work on branch \(v.branch). linkC verifies by running `\(v.command)` at the sha you report. Do not modify: \(v.testPaths.joined(separator: ", ")).")
            lines.append("")
        }
        lines.append("When you begin, call linkc_start_task(\"\(task.id)\"). When finished, commit your work and call linkc_complete_task(\"\(task.id)\", status, summary, sha). Do not paste this brief into any reply.")
        return lines.joined(separator: "\n")
    }
```

In `expireTasks`, replace the whole `switch task.state { … }` with:

```swift
            switch task.state {
            case .gating:
                if now.timeIntervalSince(task.createdAt) > Self.queuedTaskExpiry {
                    do {
                        try inboxStore.expireTask(taskId: task.id, reason: "gate did not run within 60m")
                        try echo("expired — gate did not run within 60m", for: task, inboxStore: inboxStore)
                    } catch {
                        NSLog("[linkC relay] expireTasks: task %@ stale gate — %@", task.shortId, String(describing: error))
                    }
                }
            case .queued:
                if now.timeIntervalSince(task.createdAt) > Self.queuedTaskExpiry {
                    do {
                        try inboxStore.expireTask(taskId: task.id, reason: "undelivered for 60m")
                    } catch {
                        NSLog("[linkC relay] expireTasks: task %@ stale queued — %@", task.shortId, String(describing: error))
                    }
                }
            case .delivered, .started:
                let assigneeAlive = task.assigneeSessionId.flatMap { store.session(id: $0) }.map { $0.state != .ended } ?? false
                if !assigneeAlive {
                    let reason = "assignee session ended before reporting"
                    do {
                        try inboxStore.failTask(taskId: task.id, reason: reason)
                        try echo("failed — \(reason)", for: task, inboxStore: inboxStore)
                    } catch {
                        NSLog("[linkC relay] expireTasks: task %@ dead assignee — %@", task.shortId, String(describing: error))
                    }
                } else if task.leaseExpiresAt < now {
                    do {
                        try inboxStore.expireTask(taskId: task.id, reason: "lease expired")
                        try echo("expired — lease lapsed without a report", for: task, inboxStore: inboxStore)
                    } catch {
                        NSLog("[linkC relay] expireTasks: task %@ expired lease — %@", task.shortId, String(describing: error))
                    }
                }
            case .reported:
                // A worker may exit after reporting, so only the lease applies here.
                if task.leaseExpiresAt < now {
                    do {
                        try inboxStore.expireTask(taskId: task.id, reason: "lease expired before verification")
                        try echo("expired — lease lapsed before verification", for: task, inboxStore: inboxStore)
                    } catch {
                        NSLog("[linkC relay] expireTasks: task %@ reported lease — %@", task.shortId, String(describing: error))
                    }
                }
            case .done, .failed, .cancelled, .expired:
                break
            }
```

Insert this section directly before `// MARK: - Turn end`:

```swift
    // MARK: - Verification

    /// Settles reports that need no run, then starts at most one verification run for this
    /// workspace, and at most `maxConcurrentVerifications` overall. Never blocks the main actor:
    /// the run awaits the verifier off the main actor and hops back to record the verdict.
    func launchVerifications(workspacePath: String, inboxStore: InboxStore) {
        guard workspaceExists(workspacePath) else { return }
        let open: [TaskRecord]
        do {
            open = try inboxStore.openTasks()
        } catch {
            NSLog("[linkC relay] launchVerifications: open tasks — %@", String(describing: error))
            return
        }

        var runnable: [TaskRecord] = []
        for task in open where task.state == .gating || task.state == .reported {
            guard task.state == .reported else {
                runnable.append(task)
                continue
            }
            do {
                if task.verification == nil {
                    try inboxStore.acceptUnverified(taskId: task.id)
                    let line = task.report?.status == "done" ? "done (unverified)" : "failed — worker reported failure"
                    try echo(line, for: task, inboxStore: inboxStore)
                } else if task.report?.status != "done" {
                    try settle(task, reason: "worker reported failure", inboxStore: inboxStore)
                } else if task.report?.sha == nil {
                    try settle(task, reason: "report is missing its sha", inboxStore: inboxStore)
                } else {
                    runnable.append(task)
                }
            } catch {
                NSLog("[linkC relay] launchVerifications: task %@ settle — %@", task.shortId, String(describing: error))
            }
        }

        guard !verificationsInFlight.contains(workspacePath),
              verificationsInFlight.count < Self.maxConcurrentVerifications,
              let next = runnable.min(by: { $0.createdAt < $1.createdAt }),
              let verification = next.verification else { return }

        verificationsInFlight.insert(workspacePath)
        let verifier = self.verifier
        let workspace = URL(fileURLWithPath: workspacePath)
        let sha = next.report?.sha
        Task { [weak self] in
            let verdict: Verdict
            if next.state == .reported, let sha {
                verdict = await verifier.verify(verification, sha: sha, in: workspace)
            } else {
                verdict = await verifier.gate(verification, in: workspace)
            }
            self?.finishVerification(of: next, verdict: verdict, workspacePath: workspacePath)
        }
    }

    private func settle(_ task: TaskRecord, reason: String, inboxStore: InboxStore) throws {
        try inboxStore.adjudicate(taskId: task.id, verdict: .notRun(reason: reason))
        try echo("failed — \(reason)", for: task, inboxStore: inboxStore)
    }

    /// Records the verdict and sends the delegator its one line. A task that ended while its run
    /// was in flight rejects the transition; the verdict is logged and dropped.
    func finishVerification(of task: TaskRecord, verdict: Verdict, workspacePath: String) {
        defer { verificationsInFlight.remove(workspacePath) }
        guard workspaceExists(workspacePath) else {
            NSLog("[linkC relay] finishVerification: task %@ workspace is gone; verdict dropped", task.shortId)
            return
        }
        let inboxStore = InboxStore(workspaceRoot: workspacePath)
        do {
            if task.state == .gating {
                try inboxStore.resolveGate(taskId: task.id, verdict: verdict)
                if !verdict.passed {
                    try echo("cancelled — \(verdict.reason ?? "gate failed")", for: task, inboxStore: inboxStore)
                }
            } else {
                try inboxStore.adjudicate(taskId: task.id, verdict: verdict)
                let line = verdict.passed
                    ? "done — verified at \(VerificationRunner.short(verdict.sha ?? ""))"
                    : "failed — \(verdict.reason ?? "verification failed")"
                try echo(line, for: task, inboxStore: inboxStore)
            }
        } catch {
            NSLog("[linkC relay] finishVerification: task %@ verdict dropped — %@", task.shortId, String(describing: error))
        }
    }
```

- [ ] **Step 7: Run the tests and make sure that they pass.**

Run: `swift test --filter AppCoordinatorRelayTests 2>&1 | tail -10`
Expected: PASS. That includes the 13 new tests and every existing relay test.

- [ ] **Step 8: Check the new concurrency with ThreadSanitizer.**

Run: `./scripts/tsan.sh --filter AppCoordinatorRelayTests 2>&1 | grep -c "WARNING: ThreadSanitizer"`
Expected: `0`

- [ ] **Step 9: Commit.**

```bash
git add Sources/LinkCKit/App/AppCoordinator.swift Sources/LinkCKit/App/AppCoordinator+Relay.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "feat(relay): gate and verify tasks off the main actor, one run per workspace, one line per outcome"
```

---
### Task 7: MCP — verified delegation, sha-carrying reports, verdicts in `linkc_get_task`

**Files:**
- Modify: `Sources/LinkCKit/MCP/MCPServer.swift`
- Test: `Tests/LinkCKitTests/MCPServerTaskTests.swift`, `Tests/LinkCKitTests/MCPServerTests.swift`

**Interfaces:**
- Consumes: `GitClient` (Task 2); `createTask(…verification:)` and `reportTask` (Task 4); `VerificationRunner.short` (Task 5).
- Produces:
  - `linkc_delegate_task` accepts an optional `verify` object (`branch`, `base_sha`, `command`, `test_paths`, and the optional `timeout_seconds`). The tool validates it with git and stores the base SHA in full.
  - `linkc_complete_task` accepts an optional `sha` and resolves it to a full SHA.
  - `linkc_complete_task` still accepts `tests` but ignores it.
  - `linkc_complete_task` no longer adds a message to the queue or writes a blackboard note.
  - `serverInfo.version` is `0.3.0`.

- [ ] **Step 1: Update the existing tests.**
  - In `MCPServerTests.swift`, change `XCTAssertEqual(serverInfo?["version"] as? String, "0.2.0")` to `"0.3.0"`.
  - In `MCPServerTaskTests.swift`, delete `testCompleteTaskSucceedsWhenEchoEnqueueFails`. The code path that it tested is removed.
  - Replace `testCompleteTaskRecordsReportEnqueuesOneLineAndPostsNote` with:

```swift
    func testCompleteTaskRecordsReportAndWritesNothingElse() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let srv = server(as: .codex)
        let res = try call(srv, "linkc_complete_task", [
            "task_id": task.id, "status": "done", "summary": "Implemented and tested.",
            "commits": ["abc1234"], "tests": ["accepted and ignored"]
        ])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertEqual(res.text, "Reported. Unverified task.")
        let t = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(t.state, .reported)
        XCTAssertEqual(t.report?.commits, ["abc1234"])
        XCTAssertTrue(try inbox.load().messages.isEmpty, "the relay sends the outcome line, not the tool")
        XCTAssertTrue(try srv.store.load().sharedNotes.isEmpty, "the report lives only on the task")
    }
```

- [ ] **Step 2: Write the failing tests.** Add this inside `MCPServerTaskTests`:

```swift
    // MARK: - Verified tasks

    /// Runs git in tempDir with a fixed identity; fails the test on a non-zero exit.
    @discardableResult
    private func git(_ args: String...) throws -> String {
        let result = try LiveProcessRunner.runCapturingSync(
            executable: try XCTUnwrap(GitClient.resolveGit()),
            args: ["-c", "user.email=t@t", "-c", "user.name=t"] + args, cwd: tempDir, timeout: 10
        )
        XCTAssertEqual(result.status, 0, "git \(args.joined(separator: " ")): \(result.stderr)")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// tempDir as a repository with check.sh committed on branch task/x; returns that commit.
    private func repoWithTests() throws -> String {
        try git("init", "-q", "-b", "main")
        try "#!/bin/sh\ntest -f marker.txt\n".write(to: tempDir.appendingPathComponent("check.sh"), atomically: true, encoding: .utf8)
        try git("add", "check.sh")
        try git("commit", "-q", "-m", "tests")
        try git("checkout", "-q", "-b", "task/x")
        return try git("rev-parse", "HEAD")
    }

    private func verify(base: String, branch: String = "task/x", paths: [String] = ["check.sh"]) -> [String: Any] {
        ["branch": branch, "base_sha": base, "command": "./check.sh", "test_paths": paths]
    }

    func testDelegateWithVerifyCreatesAGatingTaskAtTheFullBase() throws {
        let base = try repoWithTests()
        let res = try call(server(as: .claude), "linkc_delegate_task",
                           ["to": "codex", "prompt": "Make check pass", "verify": verify(base: String(base.prefix(7)))])
        XCTAssertFalse(res.isError, res.text)
        let task = try XCTUnwrap(inbox.load().tasks.first)
        XCTAssertEqual(task.state, .gating)
        XCTAssertEqual(task.verification?.baseSha, base)
        XCTAssertEqual(task.verification?.timeoutSeconds, 600)
        XCTAssertEqual(res.text, "Task \(task.shortId) created. linkC will confirm the tests fail at \(base.prefix(7)) before delivery.")
    }

    func testDelegateWithVerifyRejectsBadReferences() throws {
        let base = try repoWithTests()
        let srv = server(as: .claude)
        let badBase = try call(srv, "linkc_delegate_task", ["to": "codex", "prompt": "A", "verify": verify(base: "deadbeef")])
        XCTAssertTrue(badBase.isError)
        XCTAssertTrue(badBase.text.contains("verify.base_sha"), badBase.text)

        let missingPath = try call(srv, "linkc_delegate_task", ["to": "codex", "prompt": "B", "verify": verify(base: base, paths: ["nope.sh"])])
        XCTAssertTrue(missingPath.isError)
        XCTAssertTrue(missingPath.text.contains("'nope.sh' does not exist at \(base.prefix(7))"), missingPath.text)

        try git("checkout", "-q", "-b", "other")
        try "x\n".write(to: tempDir.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
        try git("add", "extra.txt")
        try git("commit", "-q", "-m", "moved")
        let movedBranch = try call(srv, "linkc_delegate_task", ["to": "codex", "prompt": "C", "verify": verify(base: base, branch: "other")])
        XCTAssertTrue(movedBranch.isError)
        XCTAssertTrue(movedBranch.text.contains("not base \(base.prefix(7))"), movedBranch.text)

        XCTAssertTrue(try inbox.load().tasks.isEmpty, "a rejected verify creates no task")
    }

    func testVerifiedCompleteNeedsTheShaOfARealCommit() throws {
        let base = try repoWithTests()
        _ = try call(server(as: .claude), "linkc_delegate_task", ["to": "codex", "prompt": "Make check pass", "verify": verify(base: base)])
        let task = try XCTUnwrap(inbox.load().tasks.first)
        try inbox.resolveGate(taskId: task.id, verdict: Verdict(passed: true, sha: base, exitStatus: 1, reason: nil, stdoutTail: "", stderrTail: ""))
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let worker = server(as: .codex)

        let noSha = try call(worker, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "added marker"])
        XCTAssertTrue(noSha.isError)
        XCTAssertEqual(noSha.text, InboxError.shaRequired.localizedDescription)
        let bogus = try call(worker, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "added marker", "sha": "deadbeef"])
        XCTAssertTrue(bogus.isError)
        XCTAssertTrue(bogus.text.hasPrefix("Error: sha:"), bogus.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)

        try "ok\n".write(to: tempDir.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        try git("add", "marker.txt")
        try git("commit", "-q", "-m", "fix")
        let sha = try git("rev-parse", "HEAD")
        let reported = try call(worker, "linkc_complete_task",
                                ["task_id": task.id, "status": "done", "summary": "added marker", "sha": String(sha.prefix(7))])
        XCTAssertFalse(reported.isError, reported.text)
        XCTAssertEqual(reported.text, "Reported. linkC is verifying at \(sha.prefix(7)).")
        let t = try XCTUnwrap(inbox.task(id: task.id))
        XCTAssertEqual(t.state, .reported)
        XCTAssertEqual(t.report?.sha, sha)
    }

    func testCompleteTaskEnforcesTheSummaryLimit() throws {
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Build", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "s1")
        let res = try call(server(as: .codex), "linkc_complete_task",
                           ["task_id": task.id, "status": "done", "summary": String(repeating: "a", count: 1_001)])
        XCTAssertTrue(res.isError)
        XCTAssertTrue(res.text.contains("the limit is 1,000"), res.text)
        XCTAssertEqual(try inbox.task(id: task.id)?.state, .delivered)
    }

    func testGetTaskShowsVerificationAndVerdict() throws {
        let base = String(repeating: "b", count: 40)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "Make check pass", files: [],
                                        verification: Verification(branch: "task/x", baseSha: base, command: "./check.sh", testPaths: ["check.sh"]))
        try inbox.resolveGate(taskId: task.id, verdict: Verdict(passed: false, sha: base, exitStatus: 0,
                                                                reason: "tests already pass at bbbbbbb; brief refused",
                                                                stdoutTail: "GATE_STDOUT_MARKER", stderrTail: ""))
        let res = try call(server(as: .claude), "linkc_get_task", ["task_id": task.id])
        XCTAssertFalse(res.isError, res.text)
        XCTAssertTrue(res.text.contains("## Verification"))
        XCTAssertTrue(res.text.contains("`./check.sh`"))
        XCTAssertTrue(res.text.contains("## Gate"))
        XCTAssertTrue(res.text.contains("tests already pass at bbbbbbb; brief refused"))
        XCTAssertTrue(res.text.contains("GATE_STDOUT_MARKER"))
    }
```

- [ ] **Step 3: Run the tests and make sure that they fail.**

Run: `swift test --filter "MCPServerTaskTests|MCPServerTests" 2>&1 | grep -E "error:|failed" | head`
Expected:
- The version assertion fails.
- The new delegate tests fail: the task is `queued`, not `gating`.
- `testCompleteTaskRecordsReportAndWritesNothingElse` fails: the state is `done` and a message was queued.

- [ ] **Step 4: Update the version and the two schemas.** In `MCPServer.swift`, change `"version": "0.2.0"` to `"version": "0.3.0"`. In the `linkc_delegate_task` `properties`, add this after `"force"`:

```swift
                        "verify": [
                            "type": "object",
                            "description": "Make this a verified task. linkC confirms the tests fail at base_sha before delivery, then runs command at the worker's reported sha and decides done or failed itself.",
                            "properties": [
                                "branch": ["type": "string", "description": "Branch the worker commits on; its tip must equal base_sha"],
                                "base_sha": ["type": "string", "description": "Commit holding the tests you wrote"],
                                "command": ["type": "string", "description": "Shell command that runs those tests; exit 0 means they pass"],
                                "test_paths": ["type": "array", "items": ["type": "string"], "description": "Test files the worker must not modify"],
                                "timeout_seconds": ["type": "integer", "description": "1-3600, default 600"]
                            ],
                            "required": ["branch", "base_sha", "command", "test_paths"]
                        ]
```

Replace the `linkc_complete_task` tool entry with:

```swift
            [
                "name": "linkc_complete_task",
                "description": "Report the result of a task you were assigned. Commit first and pass that commit's sha. For a verified task linkC runs the tests itself and tells the delegator the outcome in one line.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "task_id": ["type": "string"],
                        "status": ["type": "string", "enum": ["done", "failed"]],
                        "summary": ["type": "string", "description": "What changed, at most 1,000 characters"],
                        "sha": ["type": "string", "description": "The commit holding your work; required for a verified task reported done"],
                        "commits": ["type": "array", "items": ["type": "string"]],
                        "tests": ["type": "array", "items": ["type": "string"], "description": "Deprecated; ignored"]
                    ],
                    "required": ["task_id", "status", "summary"]
                ]
            ],
```

- [ ] **Step 5: Validate `verify` when a task is delegated.** In the `linkc_delegate_task` handler, replace everything from `let task: TaskRecord` through the `let successText = …` line with:

```swift
                var verification: Verification?
                if let verify = args["verify"] as? [String: Any] {
                    do {
                        verification = try resolveVerification(verify)
                    } catch {
                        return toolResultResponse(id: id, text: "Error: \(error.localizedDescription)", isError: true)
                    }
                }

                let task: TaskRecord
                do {
                    task = try inboxStore.createTask(from: caller.agent, to: toAgent, prompt: prompt, files: files,
                                                     force: force, verification: verification)
                } catch let error as InboxError {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }

                let successText = verification.map {
                    "Task \(task.shortId) created. linkC will confirm the tests fail at \(VerificationRunner.short($0.baseSha)) before delivery."
                } ?? "Task \(task.id) queued for \(toAgent.displayName). It will be delivered when \(toAgent.displayName) is idle. Track with linkc_get_task(\"\(task.id)\")."
```

Add this private method next to `requireTask`:

```swift
    /// Checks `verify` against the workspace's git and returns it with base_sha fully resolved.
    private func resolveVerification(_ raw: [String: Any]) throws -> Verification {
        func field(_ key: String) throws -> String {
            guard let value = (raw[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                throw LinkCError.server("verify.\(key) is required")
            }
            return value
        }
        let branch = try field("branch")
        let baseArg = try field("base_sha")
        let command = try field("command")
        guard let paths = raw["test_paths"] as? [String], !paths.isEmpty else {
            throw LinkCError.server("verify.test_paths is required")
        }
        let timeout = raw["timeout_seconds"] as? Int ?? Verification.defaultTimeoutSeconds

        let git = GitClient()
        let workspace = URL(fileURLWithPath: workspaceRoot)
        let base: String
        do { base = try git.resolveCommit(baseArg, in: workspace) } catch {
            throw LinkCError.server("verify.base_sha: \(error.localizedDescription)")
        }
        let tip: String
        do { tip = try git.resolveCommit(branch, in: workspace) } catch {
            throw LinkCError.server("verify.branch: \(error.localizedDescription)")
        }
        guard tip == base else {
            throw LinkCError.server("verify.branch '\(branch)' is at \(VerificationRunner.short(tip)), not base \(VerificationRunner.short(base)); commit the tests on that branch first")
        }
        for path in paths {
            guard try git.fileExists(path, at: base, in: workspace) else {
                throw LinkCError.server("verify.test_paths '\(path)' does not exist at \(VerificationRunner.short(base))")
            }
        }
        return Verification(branch: branch, baseSha: base, command: command, testPaths: paths, timeoutSeconds: timeout)
    }
```

- [ ] **Step 6: Report through `reportTask`.** Replace the whole `case "linkc_complete_task":` block with:

```swift
            case "linkc_complete_task":
                do {
                    let task = try requireTask(args)
                    guard caller.agent == task.toAgent else {
                        return toolResultResponse(id: id, text: "Error: task \(task.shortId) is assigned to \(task.toAgent.displayName), not \(caller.agent.displayName).", isError: true)
                    }
                    let status = (args["status"] as? String ?? "").lowercased()
                    guard status == "done" || status == "failed" else {
                        return toolResultResponse(id: id, text: "Error: 'status' must be \"done\" or \"failed\".", isError: true)
                    }
                    let summary = (args["summary"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !summary.isEmpty else {
                        return toolResultResponse(id: id, text: InboxError.emptySummary.localizedDescription, isError: true)
                    }
                    var sha: String?
                    if let raw = (args["sha"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                        do {
                            sha = try GitClient().resolveCommit(raw, in: URL(fileURLWithPath: workspaceRoot))
                        } catch {
                            return toolResultResponse(id: id, text: "Error: sha: \(error.localizedDescription). Commit your work, then report that commit's sha.", isError: true)
                        }
                    }
                    // `tests` is still accepted from older callers and ignored: linkC runs the tests itself.
                    let report = TaskReport(status: status, summary: summary, sha: sha, commits: args["commits"] as? [String] ?? [])
                    try inboxStore.reportTask(taskId: task.id, report: report)

                    let text: String
                    if task.verification == nil {
                        text = "Reported. Unverified task."
                    } else if status == "done", let sha {
                        text = "Reported. linkC is verifying at \(VerificationRunner.short(sha))."
                    } else {
                        text = "Reported. linkC will mark the task failed."
                    }
                    return toolResultResponse(id: id, text: text)
                } catch {
                    return toolResultResponse(id: id, text: error.localizedDescription, isError: true)
                }
```

- [ ] **Step 7: Show verdicts in `linkc_get_task`.** In `taskMarkdown`, replace the `if let r = t.report { … }` block with:

```swift
        if let r = t.report {
            text += "\n## Report (\(r.status))\n\(r.summary)\n"
            if let sha = r.sha { text += "\n**Sha:** \(sha)\n" }
            if !r.commits.isEmpty { text += "\n**Commits:** \(r.commits.joined(separator: ", "))\n" }
        }
        if let v = t.verification {
            text += "\n## Verification\n- **Branch:** \(v.branch)\n- **Base:** \(v.baseSha)\n- **Command:** `\(v.command)`\n"
            text += "- **Protected tests:** \(v.testPaths.joined(separator: ", "))\n- **Timeout:** \(v.timeoutSeconds)s\n"
        }
        if let gate = t.gate { text += "\n## Gate\n" + verdictMarkdown(gate) }
        if let verdict = t.verdict { text += "\n## Verdict\n" + verdictMarkdown(verdict) }
```

Add this after `taskMarkdown`:

```swift
    private func verdictMarkdown(_ v: Verdict) -> String {
        var text = "- **Result:** \(v.passed ? "passed" : "failed")\n"
        if let sha = v.sha { text += "- **At:** \(sha)\n" }
        if let exit = v.exitStatus { text += "- **Exit:** \(exit)\n" }
        if let reason = v.reason { text += "- **Reason:** \(reason)\n" }
        if !v.stdoutTail.isEmpty { text += "\n**stdout (tail)**\n```\n\(v.stdoutTail)\n```\n" }
        if !v.stderrTail.isEmpty { text += "\n**stderr (tail)**\n```\n\(v.stderrTail)\n```\n" }
        return text
    }
```

- [ ] **Step 8: Run the tests and make sure that they pass.**

Run: `swift test --filter "MCPServer" 2>&1 | tail -10`
Expected: PASS.

Run: `grep -rn "report\.tests\|postNote(authorAgent: caller.agent, title: \"Task" Sources`
Expected: no output.

- [ ] **Step 9: Commit.**

```bash
git add Sources/LinkCKit/MCP/MCPServer.swift Tests/LinkCKitTests/MCPServerTaskTests.swift Tests/LinkCKitTests/MCPServerTests.swift
git commit -m "feat(mcp): verified delegation, sha-carrying reports, and verdicts in linkc_get_task; v0.3.0"
```

---
### Task 8: Dashboard — a task item shows its verdict

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift` (the `// 1b. Process Tasks` loop)
- Test: `Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift` (add at the end of the class)

**Interfaces:**
- Consumes: `TaskRecord.verification` and `verdict`, `VerificationRunner.short`, and the store methods from Task 4.
- Produces: `AgentDashboardAggregator.taskBody(_ task: TaskRecord) -> String` (static):
  - While the task is open: the prompt.
  - Verified `done`: `verified at <s7>`.
  - Unverified `done`: `unverified`.
  - `failed`, `cancelled`, or `expired`: `verdict.reason`, else `cancelReason`, else `report.summary`, else the prompt.

- [ ] **Step 1: Write the failing test.** Add this inside `AgentDashboardAggregatorTests`:

```swift
    func testTaskItemBodyShowsTheVerdict() throws {
        let ws = (tempDir.path as NSString).standardizingPath
        let inbox = InboxStore(workspaceRoot: ws)
        let base = String(repeating: "b", count: 40)
        let sha = String(repeating: "d", count: 40)
        let verification = Verification(branch: "task/x", baseSha: base, command: "./check.sh", testPaths: ["check.sh"])
        func verdict(_ passed: Bool, _ sha: String, _ exit: Int32, _ reason: String? = nil) -> Verdict {
            Verdict(passed: passed, sha: sha, exitStatus: exit, reason: reason, stdoutTail: "", stderrTail: "")
        }

        let passed = try inbox.createTask(from: .claude, to: .codex, prompt: "Pass", files: [], verification: verification)
        try inbox.resolveGate(taskId: passed.id, verdict: verdict(true, base, 1))
        try inbox.markTaskDelivered(taskId: passed.id, sessionId: "s")
        try inbox.reportTask(taskId: passed.id, report: TaskReport(status: "done", summary: "ok", sha: sha))
        try inbox.adjudicate(taskId: passed.id, verdict: verdict(true, sha, 0))

        let refused = try inbox.createTask(from: .claude, to: .cursor, prompt: "Refused", files: [], verification: verification)
        try inbox.resolveGate(taskId: refused.id, verdict: verdict(false, base, 0, "tests already pass at bbbbbbb; brief refused"))

        let plain = try inbox.createTask(from: .claude, to: .agy, prompt: "Plain", files: [])
        try inbox.markTaskDelivered(taskId: plain.id, sessionId: "s2")
        try inbox.reportTask(taskId: plain.id, report: TaskReport(status: "done", summary: "ok"))
        try inbox.acceptUnverified(taskId: plain.id)

        let open = try inbox.createTask(from: .claude, to: .codex, prompt: "Still open", files: [])

        let data = AgentDashboardAggregator().aggregateProject(workspacePath: ws, liveSessions: [])
        func body(_ t: TaskRecord) -> String? { data.activityItems.first { $0.id == "task-\(t.id)" }?.body }
        XCTAssertEqual(body(passed), "verified at ddddddd")
        XCTAssertEqual(body(refused), "tests already pass at bbbbbbb; brief refused")
        XCTAssertEqual(body(plain), "unverified")
        XCTAssertEqual(body(open), "Still open")
    }
```

- [ ] **Step 2: Run the test and make sure that it fails.**

Run: `swift test --filter AgentDashboardAggregatorTests/testTaskItemBodyShowsTheVerdict 2>&1 | tail -10`
Expected: FAIL. `body(passed)` is `"ok"`, which is the worker's summary, not `"verified at ddddddd"`.

- [ ] **Step 3: Implement.** In the `// 1b. Process Tasks` loop, replace `body: task.report?.summary ?? task.prompt,` with `body: Self.taskBody(task),`. Then add this method to `AgentDashboardAggregator`, directly after `aggregateGlobal`:

```swift
    /// What the dashboard shows for a task: the prompt while open, the outcome once settled.
    /// Every failure reason reaches the UI through this body.
    static func taskBody(_ task: TaskRecord) -> String {
        switch task.state {
        case .done:
            guard task.verification != nil else { return "unverified" }
            return "verified at \(VerificationRunner.short(task.verdict?.sha ?? ""))"
        case .failed, .cancelled, .expired:
            return task.verdict?.reason ?? task.cancelReason ?? task.report?.summary ?? task.prompt
        case .gating, .queued, .delivered, .started, .reported:
            return task.prompt
        }
    }
```

- [ ] **Step 4: Run the tests and make sure that they pass.**

Run: `swift test --filter "AgentDashboardAggregatorTests|AppCoordinatorDashboardTests|DashboardModelsTests" 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add Sources/LinkCKit/Blackboard/AgentDashboardAggregator.swift Tests/LinkCKitTests/AgentDashboardAggregatorTests.swift
git commit -m "feat(dashboard): task items show the outcome, not the worker's summary"
```

---

### Task 9: Remove `completeTask`, the direct `→ done` transitions, and `TaskReport.tests`

**Files:**
- Modify: `Sources/LinkCKit/Blackboard/InboxStore.swift` (delete `completeTask`)
- Modify: `Sources/LinkCKit/Blackboard/InboxModels.swift` (`canTransition`, `TaskReport`)
- Modify: `Tests/LinkCKitTests/InboxStoreTests.swift`, `Tests/LinkCKitTests/InboxTaskLifecycleTests.swift`, `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift`

**Interfaces:**
- Consumes: `reportTask` and `acceptUnverified` (Task 4). Task 6 and Task 7 have already moved every caller in `Sources/` off `completeTask`.
- Produces: After this task, a worker can reach `done` only through `reported`, and only linkC can move a task out of `reported`.

- [ ] **Step 1: Change the tests to the final contract.**
  - In `InboxStoreTests.swift`, change `XCTAssertTrue(TaskState.delivered.canTransition(to: .done))` to `XCTAssertFalse(TaskState.delivered.canTransition(to: .done))`. Change `XCTAssertTrue(TaskState.started.canTransition(to: .done))` to `XCTAssertFalse(TaskState.started.canTransition(to: .done))`.
  - In `InboxTaskLifecycleTests.swift`, find this block:

```swift
        try store.completeTask(taskId: task.id, report: TaskReport(status: "done", summary: "Shipped", commits: ["abc123"], tests: ["swift test"]))
        t = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(t.state, .done)
```

and replace it with:

```swift
        try store.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "Shipped", commits: ["abc123"]))
        t = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(t.state, .reported)
        try store.acceptUnverified(taskId: task.id)
        t = try XCTUnwrap(store.task(id: task.id))
        XCTAssertEqual(t.state, .done)
```

In `testCompleteWithFailedStatusSetsFailedState`, replace the `completeTask` line with:

```swift
        try store.reportTask(taskId: task.id, report: TaskReport(status: "failed", summary: "Build broke"))
        try store.acceptUnverified(taskId: task.id)
```

In `testIllegalTransitionsThrow` and `testCompleteRejectsEmptySummary`, replace `store.completeTask(` with `store.reportTask(`.

  - In `AppCoordinatorRelayTests.swift`, `testExpireTasksDoesNotEchoWhenTransitionAlreadyTerminal` contains this:

```swift
        try inbox.completeTask(
            taskId: task.id,
            report: TaskReport(status: "done", summary: "completed by another process")
        )
```

Replace it with:

```swift
        try inbox.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "completed by another process"))
        try inbox.acceptUnverified(taskId: task.id)
```

In `testRerouteSkipsCopyWhenOriginalAlreadyDone`, replace the `completeTask` line with:

```swift
        try inbox.reportTask(taskId: original.id, report: TaskReport(status: "done", summary: "shipped before the limit hit"))
        try inbox.acceptUnverified(taskId: original.id)
```

In `testExplicitCompletionSuppressesTurnEndLine`, replace the `completeTask` line with:

```swift
        try inbox.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "ok"))
```

- [ ] **Step 2: Run the tests and make sure that they fail.**

Run: `swift test --filter "InboxStoreTests|InboxTaskLifecycleTests|AppCoordinatorRelayTests" 2>&1 | grep -E "error:|failed" | head`
Expected: Two `XCTAssertFalse failed` failures in `InboxStoreTests`. The removed transitions are still allowed.

- [ ] **Step 3: Remove the old path.** In `InboxStore.swift`, delete the whole `public func completeTask(taskId:report:timeout:)`. In `InboxModels.swift`, replace the `delivered` and `started` arms of `canTransition` with:

```swift
        case (.delivered, .started), (.delivered, .reported), (.delivered, .failed),
             (.delivered, .cancelled), (.delivered, .expired):
            return true
        case (.started, .reported), (.started, .failed), (.started, .cancelled), (.started, .expired):
            return true
```

Replace `TaskReport` with the following. `JSONDecoder` ignores a stale `tests` key in old files, and `testInboxWrittenBeforeVerificationDecodes` guards that.

```swift
/// The assignee's report, supplied through `linkc_complete_task`. For a verified task it is a
/// claim: linkC decides the outcome by running the verification at `sha`.
public struct TaskReport: Codable, Sendable, Equatable {
    public static let summaryLimit = 1_000

    public let status: String   // "done" | "failed"
    public let summary: String
    public let sha: String?
    public let commits: [String]

    public init(status: String, summary: String, sha: String? = nil, commits: [String] = []) {
        self.status = status
        self.summary = summary
        self.sha = sha
        self.commits = commits
    }
}
```

- [ ] **Step 4: Make sure that nothing refers to the old path.**

Run: `grep -rnE "completeTask|report\??\.tests|tests: \[" Sources Tests`
Expected: no output. `"tests"` appears only as the deprecated schema key in `MCPServer.swift`, which the pattern does not match.

- [ ] **Step 5: Run the full suite and ThreadSanitizer.**

Run: `swift test 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

Run: `./scripts/tsan.sh 2>&1 | grep -c "WARNING: ThreadSanitizer"`
Expected: `0`

- [ ] **Step 6: Commit.**

```bash
git add Sources/LinkCKit/Blackboard/InboxStore.swift Sources/LinkCKit/Blackboard/InboxModels.swift Tests/LinkCKitTests/InboxStoreTests.swift Tests/LinkCKitTests/InboxTaskLifecycleTests.swift Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "refactor(inbox): remove completeTask and the direct done transitions; only linkC settles a report"
```

---
### Task 10: End to end — MCP, relay, real git, a real login shell

**Files:**
- Test: `Tests/LinkCKitTests/AppCoordinatorRelayTests.swift` (add inside the class)

**Interfaces:**
- Consumes: everything above. `makeCoordinator()` uses the real `VerificationRunner()` by default.
- This test would have caught the `.linkc` bug. `.linkc/inbox.json` is created in the repository during the test, and the gate still has to see a clean tree.

- [ ] **Step 1: Write the tests.** Add this inside `AppCoordinatorRelayTests`:

```swift
    // MARK: - End to end: MCP, relay, real git, a real login shell

    @discardableResult
    private func repoGit(_ repo: URL, _ args: String...) throws -> String {
        let result = try LiveProcessRunner.runCapturingSync(
            executable: try XCTUnwrap(GitClient.resolveGit()),
            args: ["-c", "user.email=t@t", "-c", "user.name=t"] + args, cwd: repo, timeout: 10
        )
        XCTAssertEqual(result.status, 0, "git \(args.joined(separator: " ")): \(result.stderr)")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A repository whose check.sh fails until marker.txt exists, committed on branch task/x.
    private func makeCheckRepo() throws -> URL {
        let repo = tempDir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let check = repo.appendingPathComponent("check.sh")
        try "#!/bin/sh\ntest -f marker.txt\n".write(to: check, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: check.path)
        try repoGit(repo, "init", "-q", "-b", "main")
        try repoGit(repo, "add", "check.sh")
        try repoGit(repo, "commit", "-q", "-m", "tests")
        try repoGit(repo, "checkout", "-q", "-b", "task/x")
        return repo
    }

    private func mcp(_ server: MCPServer, _ name: String, _ args: [String: Any]) throws -> (text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]]
        let response = try XCTUnwrap(server.handleMessage(try JSONSerialization.data(withJSONObject: request)))
        let result = (try JSONSerialization.jsonObject(with: response) as? [String: Any])?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return (text, result?["isError"] as? Bool ?? false)
    }

    /// Delegates a verified task through MCP, waits for the real gate to queue it, and delivers it.
    @MainActor
    private func delegateAndGate(_ repo: URL, _ coordinator: AppCoordinator) async throws -> TaskRecord {
        let inbox = InboxStore(workspaceRoot: repo.path)
        let delegator = MCPServer(workspaceRoot: repo.path, environment: ["LINKC_AGENT": "claude"], ancestorResolver: { _ in nil })
        let base = try repoGit(repo, "rev-parse", "HEAD")
        let delegated = try mcp(delegator, "linkc_delegate_task", [
            "to": "codex", "prompt": "Make check.sh pass",
            "verify": ["branch": "task/x", "base_sha": base, "command": "./check.sh", "test_paths": ["check.sh"], "timeout_seconds": 60]
        ])
        XCTAssertFalse(delegated.isError, delegated.text)
        let task = try XCTUnwrap(inbox.load().tasks.first)
        XCTAssertEqual(task.state, .gating)

        coordinator.launchVerifications(workspacePath: repo.path, inboxStore: inbox)
        let gated = try await waitUntil({ (try? inbox.task(id: task.id))?.state == .queued }, iterations: 500)
        XCTAssertTrue(gated, "gate: \(String(describing: try? inbox.task(id: task.id)?.gate))")
        try inbox.markTaskDelivered(taskId: task.id, sessionId: "worker")
        return task
    }

    /// The worker: commit one file, then report that commit's sha through MCP.
    private func commitAndReport(_ repo: URL, _ task: TaskRecord, file: String, contents: String) throws -> String {
        try contents.write(to: repo.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try repoGit(repo, "add", file)
        try repoGit(repo, "commit", "-q", "-m", "worker")
        let sha = try repoGit(repo, "rev-parse", "HEAD")
        let worker = MCPServer(workspaceRoot: repo.path, environment: ["LINKC_AGENT": "codex"], ancestorResolver: { _ in nil })
        let reported = try mcp(worker, "linkc_complete_task", ["task_id": task.id, "status": "done", "summary": "worker change", "sha": sha])
        XCTAssertFalse(reported.isError, reported.text)
        return sha
    }

    @MainActor
    func testVerifiedTaskEndToEnd() async throws {
        let repo = try makeCheckRepo()
        let inbox = InboxStore(workspaceRoot: repo.path)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let task = try await delegateAndGate(repo, coordinator)

        let sha = try commitAndReport(repo, task, file: "marker.txt", contents: "ok\n")
        coordinator.launchVerifications(workspacePath: repo.path, inboxStore: inbox)

        let done = try await waitUntil({ (try? inbox.task(id: task.id))?.state == .done }, iterations: 500)
        XCTAssertTrue(done, "verdict: \(String(describing: try? inbox.task(id: task.id)?.verdict))")
        XCTAssertEqual(try lines(inbox, task), ["[linkC task \(task.shortId)] done — verified at \(sha.prefix(7))"])
    }

    @MainActor
    func testVerifiedTaskFailsWhenTheWorkerEditsTheTests() async throws {
        let repo = try makeCheckRepo()
        let inbox = InboxStore(workspaceRoot: repo.path)
        let coordinator = makeCoordinator()
        defer { coordinator.shutdown() }
        let task = try await delegateAndGate(repo, coordinator)

        _ = try commitAndReport(repo, task, file: "check.sh", contents: "#!/bin/sh\nexit 0\n")
        coordinator.launchVerifications(workspacePath: repo.path, inboxStore: inbox)

        let failed = try await waitUntil({ (try? inbox.task(id: task.id))?.state == .failed }, iterations: 500)
        XCTAssertTrue(failed, "verdict: \(String(describing: try? inbox.task(id: task.id)?.verdict))")
        XCTAssertEqual(try lines(inbox, task), ["[linkC task \(task.shortId)] failed — test files modified: check.sh"])
    }
```

- [ ] **Step 2: Run the tests.**

Run: `swift test --filter "AppCoordinatorRelayTests/testVerifiedTask" 2>&1 | tail -10`
Expected: PASS for both tests. If the gate reports `working tree is not clean`, the `.linkc` exclusion in `GitClient.statusPorcelain` is missing. Fix it there. Do not change this test.

- [ ] **Step 3: Mutation check.** Show that the tamper check is what makes the second test pass. In `VerificationRunner.swift`, temporarily change `guard changed.isEmpty else {` to `guard changed.isEmpty || true else {`.

Run: `swift test --filter "testVerifiedTaskFailsWhenTheWorkerEditsTheTests|testVerifyNeverRunsModifiedTests" 2>&1 | grep -E "failed|passed" | tail -4`
Expected: both tests FAIL.

Run: `git checkout -- Sources/LinkCKit/Verification/VerificationRunner.swift && swift test --filter "testVerifiedTaskFailsWhenTheWorkerEditsTheTests|testVerifyNeverRunsModifiedTests" 2>&1 | tail -4`
Expected: both tests PASS. Do not commit the change from this step.

- [ ] **Step 4: Run the full suite and ThreadSanitizer.**

Run: `swift test 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

Run: `./scripts/tsan.sh 2>&1 | grep -c "WARNING: ThreadSanitizer"`
Expected: `0`

- [ ] **Step 5: Commit.**

```bash
git add Tests/LinkCKitTests/AppCoordinatorRelayTests.swift
git commit -m "test(verification): end to end through MCP, relay, real git, and a login shell"
```

---

## After merge

Do these steps after the branch merges to `main`. They are not tasks in the branch.

- Ship with `./build-app.sh` from `main`. Do not copy `linkc-mcp` over `~/.local/bin/linkc-mcp`. That path is a symlink into the signed bundle, and copying over it breaks the signature.
- Make sure that the new binary is registered. Run `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ~/.local/bin/linkc-mcp | grep -o '"version":"0.3.0"'`. It must print `"version":"0.3.0"`.
- Clients must reconnect to see `verify` and `sha`.

## Self-Review

**Spec coverage.** Each spec section and the tasks that implement it:

| Spec | Tasks |
|---|---|
| §5.1 | 3, 9 |
| §5.2–§5.3 | 3 |
| §5.4 | 3, 9 |
| §6 | 4. `failTask` comes from §15.4. |
| §7.1 | 7. The delivery frame is in Task 6. |
| §7.2–§7.3 | 7 |
| §8.1 | 1 |
| §8.2 | 2, synchronous per §15.1–§15.3 |
| §8.3 | 5 |
| §8.4 | 6 |
| §8.5 | 6 |
| §9 | 6 |
| §10 | 8, synchronous per §15.1 |
| §11 | 4, 5, 6, 7 |
| §12 | Every task. End to end and the mutation check are Task 10. ThreadSanitizer runs in Tasks 6, 9, and 10. |
| §13 | 2 (both git spawners), 7 (the queued message and blackboard note), 9 (`completeTask`, `tests`, transitions) |
| §14 | After merge |

**Placeholder scan.** Every step includes its code or its exact command, with the expected output.

**Type consistency.** These names keep the same signatures in every task that uses them:

| Name | Defined in | Used in |
|---|---|---|
| `runCapturingSync(executable:args:cwd:timeout:)` | 1 | 2, 7, 10 |
| `GitInspecting` members | 2 | 5 |
| `Verdict.notRun(reason:sha:)` | 3 | 5, 6 |
| `VerificationRunner.short(_:)` | 5 | 6, 7, 8 |
| `reportTask`, `resolveGate`, `adjudicate`, `acceptUnverified`, `failTask` | 4 | 6, 7, 8, 9, 10 |
| `maxConcurrentVerifications`, `verificationsInFlight` | 6 | Task 6 tests |
| `lines(_:_:)` | 6 | 10 |
