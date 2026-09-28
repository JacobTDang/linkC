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

    /// Protected automatically alongside `test_paths` (D18c): a worker cannot drop a protected
    /// test by editing the harness that runs it instead of the file itself. The xcodeproj entry
    /// is a glob pathspec — `changedFiles` passes it straight to `git diff`, which matches it
    /// against any project in the workspace.
    private static let harnessProtectedPaths = ["Package.swift", "*.xcodeproj/project.pbxproj"]

    public func gate(_ v: Verification, in workspace: URL) async -> Verdict {
        let before = await offGitThread { self.checkout(v.baseSha, label: "base ", in: workspace) }
        if let problem = before.problem {
            return .notRun(reason: "gate failed: \(problem)")
        }
        let result: ProcessResult
        do {
            result = try await execute(v, in: workspace)
        } catch {
            return .notRun(reason: "gate failed: \(Self.describe(error))", sha: v.baseSha)
        }
        let after = await offGitThread { self.checkout(v.baseSha, label: "base ", in: workspace) }
        if after.problem != nil {
            return Self.verdict(result, sha: v.baseSha, reason: "gate failed: workspace changed during the gate")
        }
        let warning = Self.warningText(for: before.untracked + after.untracked)
        if let signal = result.signal {
            return Self.verdict(result, sha: v.baseSha, reason: "gate failed: command was killed (signal \(signal))", warning: warning)
        }
        switch result.status {
        case 1...125:
            return Self.verdict(result, sha: v.baseSha, reason: nil, warning: warning)
        case 0:
            return Self.verdict(result, sha: v.baseSha, reason: "tests already pass at \(Self.short(v.baseSha)); brief refused", warning: warning)
        case 126, 127:
            return Self.verdict(result, sha: v.baseSha, reason: "gate failed: command could not run (exit \(result.status))", warning: warning)
        default:
            return Self.verdict(result, sha: v.baseSha, reason: "gate failed: command was killed (exit \(result.status))", warning: warning)
        }
    }

    public func verify(_ v: Verification, sha: String, in workspace: URL) async -> Verdict {
        let before = await offGitThread { self.checkout(sha, label: "", in: workspace) }
        if let problem = before.problem {
            return .notRun(reason: problem)
        }
        do {
            guard try await offGitThreadThrowing({ try self.git.isAncestor(v.baseSha, of: sha, in: workspace) }) else {
                return .notRun(reason: "\(Self.short(sha)) does not descend from base \(Self.short(v.baseSha))")
            }
            // Before the command: modified tests (and the harness that runs them) must never run.
            let changed = try await offGitThreadThrowing({
                try self.git.changedFiles(
                    v.testPaths + Self.harnessProtectedPaths, from: v.baseSha, to: sha, in: workspace
                )
            })
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
        let after = await offGitThread { self.checkout(sha, label: "", in: workspace) }
        if after.problem != nil {
            return Self.verdict(result, sha: sha, reason: "workspace changed during verification")
        }
        let warning = Self.warningText(for: before.untracked + after.untracked)
        let reason: String?
        if let signal = result.signal {
            reason = "tests failed at \(Self.short(sha)) (signal \(signal))"
        } else if result.status == 126 || result.status == 127 {
            reason = "command could not run at \(Self.short(sha)) (exit \(result.status))"
        } else if result.status != 0 {
            reason = "tests failed at \(Self.short(sha)) (exit \(result.status))"
        } else {
            reason = nil
        }
        return Self.verdict(result, sha: sha, reason: reason, warning: warning)
    }

    /// One checkout check's outcome. `problem` is non-nil only for a HEAD mismatch or a TRACKED
    /// change (D18a) — either stops the run. `untracked` is informational and never stops it.
    private struct CheckoutStatus {
        let problem: String?
        let untracked: [String]
    }

    private func checkout(_ expected: String, label: String, in workspace: URL) -> CheckoutStatus {
        do {
            let head = try git.headSha(in: workspace)
            guard head == expected else {
                return CheckoutStatus(
                    problem: "HEAD is \(Self.short(head)), expected \(label)\(Self.short(expected))", untracked: []
                )
            }
            let status = try git.cleanStatus(in: workspace)
            guard status.clean else { return CheckoutStatus(problem: "working tree is not clean", untracked: []) }
            return CheckoutStatus(problem: nil, untracked: status.untracked)
        } catch {
            return CheckoutStatus(problem: Self.describe(error), untracked: [])
        }
    }

    /// Runs synchronous git work off the calling thread. `gate`/`verify` are `async`, and a
    /// direct `git` call otherwise blocks whatever thread runs them — a Swift-concurrency
    /// cooperative-pool thread for the whole subprocess, when reached through a `Task` (D19b,
    /// same root cause as D19a's `ProcessRunner` fix).
    private func offGitThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    /// The throwing counterpart of `offGitThread`, for the git calls that can fail.
    private func offGitThreadThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func execute(_ v: Verification, in workspace: URL) async throws -> ProcessResult {
        // A login shell loads PATH and dotfiles; a GUI app's inherited PATH cannot find `swift`.
        try await runner.runCapturing(shell, args: ["-l", "-c", v.command], cwd: workspace,
                                      timeout: TimeInterval(v.timeoutSeconds))
    }

    /// D18a: an untracked, un-ignored file is never a failure reason on its own — folded into
    /// `nil` when there is none, sorted and deduplicated across the before/after checkout checks.
    private static func warningText(for untracked: [String]) -> String? {
        let files = Set(untracked).sorted()
        return files.isEmpty ? nil : "left untracked: \(files.joined(separator: ", "))"
    }

    /// `passed` reflects only a real failure `reason`; an untracked-file `warning` rides along
    /// in the rendered text without flipping it.
    private static func verdict(_ r: ProcessResult, sha: String, reason: String?, warning: String? = nil) -> Verdict {
        let text: String?
        switch (reason, warning) {
        case let (reason?, warning?): text = "\(reason) (\(warning))"
        case let (reason?, nil): text = reason
        case let (nil, warning?): text = warning
        case (nil, nil): text = nil
        }
        return Verdict(
            passed: reason == nil, sha: sha, exitStatus: r.status, reason: text,
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
