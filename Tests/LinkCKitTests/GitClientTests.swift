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
}
