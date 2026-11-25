import Foundation
import Observation

/// The repo each folder is in, for the agent cards beside a terminal: the folder of the repo's main
/// checkout, which every worktree and subfolder of the repo shares (`git rev-parse --git-common-dir`).
/// A folder outside git is its own repo, by its real path. Each folder is asked once; git runs off the
/// main thread, and never from a view.
@MainActor
@Observable
public final class RepoRoots {
    public enum Root: Equatable, Sendable {
        /// The repo's folder, or the folder itself outside git: a real path.
        case repo(String)
        /// Why git could not say. The cards say it rather than show a narrower repo.
        case failed(String)
    }

    /// Each folder asked about, by the path it was asked as.
    public private(set) var roots: [String: Root] = [:]

    /// The folders the latest call listed: an answer for one dropped since is not kept.
    @ObservationIgnored private var listed: Set<String> = []
    /// Folders git is being asked about now, so an overlapping call does not ask again.
    @ObservationIgnored private var asking: Set<String> = []
    /// When each failed folder last failed: it is asked again once `retryAfter` has passed, not on
    /// every sweep, so a broken repo does not run git every second.
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    @ObservationIgnored private let runner: any ProcessRunner
    @ObservationIgnored private let gitPath: String?
    @ObservationIgnored private let retryAfter: TimeInterval
    @ObservationIgnored private let now: @MainActor () -> Date

    private static let timeout: TimeInterval = 5

    public init(runner: any ProcessRunner = LiveProcessRunner(), gitPath: String? = GitClient.resolveGit(),
                retryAfter: TimeInterval = 10, now: @escaping @MainActor () -> Date = Date.init) {
        self.runner = runner
        self.gitPath = gitPath
        self.retryAfter = retryAfter
        self.now = now
    }

    /// Asks git about each of `folders` not answered yet, or whose last failure is old enough to try
    /// again, all at once. Folders not in `folders` are forgotten.
    public func resolve(_ folders: [String]) async {
        let wanted = Set(folders)
        listed = wanted
        if roots.keys.contains(where: { !wanted.contains($0) }) {
            roots = roots.filter { wanted.contains($0.key) }
        }
        failedAt = failedAt.filter { wanted.contains($0.key) }
        let at = now()
        let due = wanted.filter { folder in
            guard !asking.contains(folder) else { return false }
            switch roots[folder] {
            case nil: return true
            case .repo: return false
            case .failed: return failedAt[folder].map { at.timeIntervalSince($0) >= retryAfter } ?? true
            }
        }
        guard !due.isEmpty else { return }
        asking.formUnion(due)
        let runner = runner
        let gitPath = gitPath
        await withTaskGroup(of: (String, Root).self) { group in
            for folder in due {
                group.addTask { (folder, await Self.root(of: folder, runner: runner, gitPath: gitPath)) }
            }
            for await (folder, root) in group {
                asking.remove(folder)
                // Dropped from the list while git ran: forgotten, not brought back.
                guard listed.contains(folder) else { continue }
                if case .failed = root { failedAt[folder] = now() } else { failedAt[folder] = nil }
                if roots[folder] != root { roots[folder] = root }
            }
        }
    }

    private nonisolated static func root(of folder: String, runner: any ProcessRunner, gitPath: String?) async -> Root {
        guard let gitPath else {
            return .failed("git was not found at \(GitClient.candidatePaths.joined(separator: ", ")), so linkC cannot tell which repo \(folder) is in")
        }
        let result: ProcessResult
        do {
            result = try await runner.runCapturing(
                gitPath, args: ["-C", folder, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                cwd: nil, timeout: timeout)
        } catch {
            return .failed("git cannot read the repo of \(folder): \(error.localizedDescription)")
        }
        if result.status == 0 {
            return .repo(ProjectPath.canonical(repoFolder(gitCommonDir: result.stdout)))
        }
        let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if reason.range(of: "not a git repository", options: .caseInsensitive) != nil {
            return .repo(ProjectPath.canonical(folder))
        }
        return .failed("git cannot read the repo of \(folder): \(reason.isEmpty ? "it exited \(result.status)" : reason)")
    }

    /// The main checkout's folder from git's common dir: `<repo>/.git` in an ordinary repo. Any other
    /// common dir (a bare repo, a separated git dir) is the repo's own name for itself.
    nonisolated static func repoFolder(gitCommonDir: String) -> String {
        let dir = gitCommonDir.trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.hasSuffix("/.git") ? String(dir.dropLast("/.git".count)) : dir
    }
}
