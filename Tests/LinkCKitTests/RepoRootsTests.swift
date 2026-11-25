import os
import XCTest
@testable import LinkCKit

/// Which repo a folder is in, as the agent cards group sessions: its main checkout, through any
/// worktree, by git's common dir. Real git on real folders, so the argv is the one the app runs.
@MainActor
final class RepoRootsTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-roots-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func folder(_ path: String) throws -> URL {
        let url = tempDir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A repo with one commit, so worktrees can be added to it.
    private func makeRepo(_ name: String) throws -> URL {
        let repo = try folder(name)
        try runGit(["init", "-q", "-b", "main"], in: repo)
        try runGit(["commit", "-q", "--allow-empty", "-m", "start"], in: repo)
        return repo
    }

    func testASubfolderAndEveryWorktreeResolveToTheMainCheckout() async throws {
        let repo = try makeRepo("repo")
        let sources = try folder("repo/Sources")
        try runGit(["worktree", "add", "-q", "-b", "fix", ".worktrees/fix"], in: repo)
        // A worktree outside the repo's own folder is still the repo's.
        try runGit(["worktree", "add", "-q", "-b", "far", tempDir.appendingPathComponent("far-away").path], in: repo)
        let inside = repo.appendingPathComponent(".worktrees/fix").path
        let outside = tempDir.appendingPathComponent("far-away").path
        let roots = RepoRoots()

        await roots.resolve([repo.path, sources.path, inside, outside])

        let main = RepoRoots.Root.repo(ProjectPath.canonical(repo.path))
        XCTAssertEqual(roots.roots[repo.path], main)
        XCTAssertEqual(roots.roots[sources.path], main)
        XCTAssertEqual(roots.roots[inside], main)
        XCTAssertEqual(roots.roots[outside], main)
    }

    func testTwoReposStayApart() async throws {
        let one = try makeRepo("one")
        let two = try makeRepo("two")
        let roots = RepoRoots()

        await roots.resolve([one.path, two.path])

        XCTAssertEqual(roots.roots[one.path], .repo(ProjectPath.canonical(one.path)))
        XCTAssertEqual(roots.roots[two.path], .repo(ProjectPath.canonical(two.path)))
    }

    /// Outside git a folder is its own repo, by its real path: a link to it reads as the folder itself.
    func testAFolderOutsideGitIsItsOwnRepoByItsRealPath() async throws {
        let plain = try folder("plain")
        let link = tempDir.appendingPathComponent("link-to-plain")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: plain)
        let roots = RepoRoots()

        await roots.resolve([link.path])

        XCTAssertEqual(roots.roots[link.path], .repo(ProjectPath.canonical(plain.path)))
        XCTAssertNotEqual(ProjectPath.canonical(plain.path), link.path)
    }

    @MainActor private final class TestNow {
        var date: Date
        init(_ date: Date) { self.date = date }
    }

    /// Answers each git run from a script, and counts the runs.
    private final class ScriptedGit: ProcessRunner, Sendable {
        private let answer: @Sendable ([String]) -> ProcessResult
        private let box = OSAllocatedUnfairLock(initialState: [[String]]())

        init(_ answer: @escaping @Sendable ([String]) -> ProcessResult) {
            self.answer = answer
        }

        var runs: [[String]] { box.withLock { $0 } }

        func runCapturing(_ executable: String, args: [String], cwd: URL?, timeout: TimeInterval) async throws -> ProcessResult {
            box.withLock { $0.append([executable] + args) }
            return answer(args)
        }
    }

    /// Any other failure says why, rather than quietly showing a narrower repo.
    func testAGitFailureOtherThanNoRepoSaysWhy() async {
        let git = ScriptedGit { _ in
            ProcessResult(status: 128, stdout: "", stderr: "fatal: detected dubious ownership in repository at '/repo'")
        }
        let roots = RepoRoots(runner: git, gitPath: "/usr/bin/git")

        await roots.resolve(["/repo"])

        guard case .failed(let why) = roots.roots["/repo"] else {
            return XCTFail("expected a failure, got \(String(describing: roots.roots["/repo"]))")
        }
        XCTAssertTrue(why.contains("dubious ownership"), why)
        XCTAssertTrue(why.contains("/repo"), why)
    }

    func testTheAppAsksGitForTheCommonDirOfEachFolderOnce() async {
        let git = ScriptedGit { _ in ProcessResult(status: 0, stdout: "/repo/.git\n", stderr: "") }
        let roots = RepoRoots(runner: git, gitPath: "/usr/bin/git")

        await roots.resolve(["/repo/a"])
        await roots.resolve(["/repo/a"])

        XCTAssertEqual(git.runs, [["/usr/bin/git", "-C", "/repo/a", "rev-parse", "--path-format=absolute", "--git-common-dir"]])
        XCTAssertEqual(roots.roots["/repo/a"], .repo("/repo"))
    }

    /// A failure is tried again, but not on every sweep: a broken repo must not spawn git each second.
    func testAFailureIsTriedAgainOnlyAfterAWhile() async {
        let git = ScriptedGit { _ in ProcessResult(status: 128, stdout: "", stderr: "fatal: something broke") }
        let clock = TestNow(Date(timeIntervalSince1970: 1_000_000))
        let roots = RepoRoots(runner: git, gitPath: "/usr/bin/git", retryAfter: 10, now: { clock.date })

        await roots.resolve(["/repo"])
        clock.date += 5
        await roots.resolve(["/repo"])
        XCTAssertEqual(git.runs.count, 1)

        clock.date += 6
        await roots.resolve(["/repo"])
        XCTAssertEqual(git.runs.count, 2)
    }

    func testNoGitSaysSo() async {
        let roots = RepoRoots(runner: ScriptedGit { _ in ProcessResult(status: 0, stdout: "", stderr: "") }, gitPath: nil)

        await roots.resolve(["/repo"])

        guard case .failed(let why) = roots.roots["/repo"] else {
            return XCTFail("expected a failure, got \(String(describing: roots.roots["/repo"]))")
        }
        XCTAssertTrue(why.contains("git"), why)
    }

    func testAFolderNoLongerListedIsForgotten() async {
        let git = ScriptedGit { args in ProcessResult(status: 0, stdout: "\(args[1])/.git\n", stderr: "") }
        let roots = RepoRoots(runner: git, gitPath: "/usr/bin/git")

        await roots.resolve(["/a", "/b"])
        await roots.resolve(["/b"])

        XCTAssertEqual(roots.roots, ["/b": .repo("/b")])
    }
}
