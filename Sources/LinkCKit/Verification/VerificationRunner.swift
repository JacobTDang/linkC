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
