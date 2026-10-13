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
        try runGit(["init", "-q", "-b", "main"], in: repo)
        try write("a\n", "Tests/Sub/X.swift")
        try write("build/\n", ".gitignore")
        try runGit(["add", "-A"], in: repo)
        try runGit(["commit", "-q", "-m", "base"], in: repo)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo)
        try super.tearDownWithError()
    }

    private func write(_ text: String, _ path: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commitNewFile() throws -> String {
        try write("c\n", "new.txt")
        try runGit(["add", "new.txt"], in: repo)
        try runGit(["commit", "-q", "-m", "next"], in: repo)
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

    func testStatusIgnoresLinkcAndIgnoredFilesAndUntrackedButNotEdited() throws {
        XCTAssertTrue(try git.isClean(in: repo))
        try write("x", ".linkc/inbox.json")
        try write("y", "build/out")
        XCTAssertTrue(try git.isClean(in: repo), "linkC's own state and ignored files are not changes")
        // D18a: only TRACKED changes make the tree unclean — an untracked, un-ignored file is
        // surfaced separately (untrackedFiles), never a failure on its own.
        try write("z", "untracked.txt")
        XCTAssertTrue(try git.isClean(in: repo), "an untracked file does not fail the clean-tree check")
        XCTAssertEqual(try git.untrackedFiles(in: repo), ["untracked.txt"])
        try FileManager.default.removeItem(at: repo.appendingPathComponent("untracked.txt"))
        try write("edited\n", "Tests/Sub/X.swift")
        XCTAssertFalse(try git.isClean(in: repo), "a tracked edit still makes the tree unclean")
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

    func testIsRepository() throws {
        XCTAssertTrue(GitClient.isRepository(repo))
        XCTAssertTrue(GitClient.isRepository(repo.appendingPathComponent("Tests/Sub")))
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        XCTAssertFalse(GitClient.isRepository(plain))
    }

    func testMissingGitFailsLoud() {
        XCTAssertThrowsError(try GitClient(gitPath: nil).headSha(in: repo)) {
            XCTAssertTrue($0.localizedDescription.contains("git not found"), $0.localizedDescription)
        }
    }

    /// D17: a raw `ProcessRunnerError.timedOut` has no `LocalizedError` conformance — it must
    /// never escape `GitClient` as-is, or it renders as an opaque "error 0." in verdicts and MCP
    /// output. `GitClient` wraps it into a descriptive `LinkCError.process`.
    func testGitTimeoutBecomesADescriptiveError() throws {
        let script = repo.appendingPathComponent("slow-git.sh")
        try "#!/bin/sh\nsleep 5\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let slowGit = GitClient(timeout: 1.2, gitPath: script.path)
        XCTAssertThrowsError(try slowGit.headSha(in: repo)) { error in
            XCTAssertEqual(error.localizedDescription, "git rev-parse timed out after 1s")
        }
    }

    /// A temporary linked worktree of `repo` on a new branch, removed with the test.
    private func addWorktree(_ name: String, branch: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        let root: URL = repo
        addTeardownBlock {
            _ = try? runGit(["worktree", "remove", "--force", dir.path], in: root)
            try? FileManager.default.removeItem(at: dir)
        }
        if let branch {
            _ = try runGit(["worktree", "add", dir.path, "-b", branch], in: repo)
        } else {
            _ = try runGit(["worktree", "add", "--detach", dir.path], in: repo)
        }
        return dir
    }

    func testTheWorktreeHoldingABranchIsFound() throws {
        let dir = try addWorktree("linkc-wt", branch: "feature/worktree-branch")
        let found = try XCTUnwrap(try git.worktree(holding: "feature/worktree-branch", in: repo))
        XCTAssertEqual(ProjectPath.canonical(found.path), ProjectPath.canonical(dir.path))
    }

    func testTheRootHoldsItsOwnBranch() throws {
        let found = try XCTUnwrap(try git.worktree(holding: "main", in: repo))
        XCTAssertEqual(ProjectPath.canonical(found.path), ProjectPath.canonical(repo.path))
    }

    func testABranchNoWorktreeHoldsHasNone() throws {
        _ = try runGit(["branch", "unlinked-branch"], in: repo)
        XCTAssertNil(try git.worktree(holding: "unlinked-branch", in: repo))
        XCTAssertNil(try git.worktree(holding: "does-not-exist", in: repo))
    }

    /// Only the exact branch matches: a sibling sharing its prefix, and a detached worktree, don't.
    func testOnlyTheExactBranchMatches() throws {
        let sibling = try addWorktree("linkc-wt-sibling", branch: "feature/x-2")
        _ = try addWorktree("linkc-wt-detached", branch: nil)
        XCTAssertNil(try git.worktree(holding: "feature/x", in: repo))
        let found = try XCTUnwrap(try git.worktree(holding: "feature/x-2", in: repo))
        XCTAssertEqual(ProjectPath.canonical(found.path), ProjectPath.canonical(sibling.path))
    }

    func testAWorktreePathWithASpaceAndAFullRefName() throws {
        let dir = try addWorktree("linkc wt spaced", branch: "task/spaced")
        let byName = try XCTUnwrap(try git.worktree(holding: "task/spaced", in: repo))
        XCTAssertEqual(ProjectPath.canonical(byName.path), ProjectPath.canonical(dir.path))
        let byRef = try XCTUnwrap(try git.worktree(holding: "refs/heads/task/spaced", in: repo))
        XCTAssertEqual(ProjectPath.canonical(byRef.path), ProjectPath.canonical(dir.path))
    }

    /// A worktree whose folder is gone is not a checkout to run in: the lookup says so.
    func testAWorktreeWhoseFolderIsGoneIsReported() throws {
        let dir = try addWorktree("linkc-wt-gone", branch: "task/gone")
        try FileManager.default.removeItem(at: dir)
        XCTAssertThrowsError(try git.worktree(holding: "task/gone", in: repo)) { error in
            XCTAssertTrue(error.localizedDescription.contains("git worktree prune"), error.localizedDescription)
        }
    }
}
