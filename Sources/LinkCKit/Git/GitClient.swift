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
    /// One `git status --porcelain` call, split into tracked-change lines and untracked
    /// (un-ignored) paths — porcelain excludes ignored paths by default, so every `"??"` line
    /// is exactly that.
    private func parsedStatus(in workspace: URL) throws -> (tracked: [Substring], untracked: [String]) {
        var tracked: [Substring] = []
        var untracked: [String] = []
        for line in try statusPorcelain(in: workspace).split(separator: "\n") {
            if line.hasPrefix("??") {
                untracked.append(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            } else {
                tracked.append(line)
            }
        }
        return (tracked, untracked)
    }

    /// True when no TRACKED file differs from HEAD/the index (D18a). An untracked, un-ignored
    /// file does not count; see `untrackedFiles`.
    public func isClean(in workspace: URL) throws -> Bool {
        try parsedStatus(in: workspace).tracked.isEmpty
    }

    /// Untracked, un-ignored paths — never a clean-tree failure on their own (D18a); callers
    /// surface them as a warning instead.
    public func untrackedFiles(in workspace: URL) throws -> [String] {
        try parsedStatus(in: workspace).untracked
    }

    /// `isClean` and `untrackedFiles` from a single `git status --porcelain` call, for a caller
    /// that wants both without asking git twice.
    public func cleanStatus(in workspace: URL) throws -> (clean: Bool, untracked: [String]) {
        let status = try parsedStatus(in: workspace)
        return (status.tracked.isEmpty, status.untracked)
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

    /// True when `workspace` or one of its ancestors holds a `.git` entry — a directory, or the
    /// file a linked worktree uses. A folder outside any repository is an answer, not an error.
    public static func isRepository(_ workspace: URL) -> Bool {
        var path = (workspace.path as NSString).standardizingPath
        while true {
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) { return true }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return false }
            path = parent
        }
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
        do {
            return try LiveProcessRunner.runCapturingSync(executable: gitPath, args: args, cwd: workspace, timeout: timeout)
        } catch ProcessRunnerError.timedOut(let seconds) {
            // A bare `ProcessRunnerError` has no `LocalizedError` conformance — left to escape,
            // it renders as an opaque "error 0." in verdicts and MCP output (D17).
            throw LinkCError.process("git \(args.first ?? "") timed out after \(seconds)s")
        }
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
