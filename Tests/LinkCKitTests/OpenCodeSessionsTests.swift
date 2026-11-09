import XCTest
@testable import LinkCKit

/// OpenCode's `--continue` takes the newest session of the whole project — every worktree of a
/// repo is one project — so linkC picks the session that ran in the very folder it opens.
final class OpenCodeSessionsTests: XCTestCase {
    private var root: URL!
    private var here: String { root.appendingPathComponent("main").path }
    private var worktree: String { root.appendingPathComponent("worktree").path }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-opencode-sessions-\(UUID().uuidString)")
        for folder in ["main", "worktree"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// `opencode session list --format json` output, in the fields OpenCode 2.2.5 (and 1.18.19) prints.
    private func listing(_ entries: [(id: String, directory: String, updated: Double)]) throws -> String {
        let objects: [[String: Any]] = entries.map {
            ["id": $0.id, "title": "a session", "updated": $0.updated, "created": $0.updated - 1000,
             "projectId": "b6c90be0b9fdd46da66b8e571c85ff25336524ce", "directory": $0.directory]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: objects, options: .prettyPrinted), as: UTF8.self)
    }

    func testTheArgumentsListThisProjectsSessionsWithoutStartingTheSharedService() {
        XCTAssertEqual(OpenCodeSessions.listArguments,
                       ["session", "list", "--format", "json", "--standalone", "--max-count", "10000"])
    }

    /// `n` minimal listing entries, all in `folder`.
    private func listing(count n: Int, in folder: String) -> String {
        let objects = (0..<n).map { #"{"id":"ses_\#($0)","directory":"\#(folder)","updated":\#($0)}"# }
        return "[" + objects.joined(separator: ",") + "]"
    }

    /// OpenCode lists 100 sessions unless asked for more, across every worktree of the project, so a
    /// listing that fills the count linkC asked for may have cut this folder's own session off.
    func testAListingThatFillsTheLimitThrowsRatherThanRiskMissingThisFoldersSession() {
        let full = listing(count: OpenCodeSessions.listLimit, in: worktree)
        XCTAssertThrowsError(try OpenCodeSessions.newest(in: here, listing: full)) { error in
            XCTAssertTrue(String(describing: error).contains("\(OpenCodeSessions.listLimit) sessions"), String(describing: error))
        }
    }

    func testAListingOneShortOfTheLimitIsRead() throws {
        let short = listing(count: OpenCodeSessions.listLimit - 1, in: here)
        XCTAssertEqual(try OpenCodeSessions.newest(in: here, listing: short), "ses_\(OpenCodeSessions.listLimit - 2)")
    }

    func testTheNewestSessionInThisFolderIsChosen() throws {
        let out = try listing([("ses_worktree", worktree, 1_794_071_409_000),
                               ("ses_older", here, 1_794_071_301_000),
                               ("ses_newer", here, 1_794_071_408_175)])
        XCTAssertEqual(try OpenCodeSessions.newest(in: here, listing: out), "ses_newer")
    }

    func testASessionInAnotherFolderOfTheSameProjectIsNotChosen() throws {
        let out = try listing([("ses_worktree", worktree, 1_794_071_409_000)])
        XCTAssertNil(try OpenCodeSessions.newest(in: here, listing: out))
    }

    /// OpenCode prints nothing at all for a project with no sessions.
    func testAProjectWithNoSessionsHasNone() throws {
        XCTAssertNil(try OpenCodeSessions.newest(in: here, listing: ""))
        XCTAssertNil(try OpenCodeSessions.newest(in: here, listing: "\n"))
    }

    func testFoldersAreComparedCanonically() throws {
        let out = try listing([("ses_here", here, 1)])
        XCTAssertEqual(try OpenCodeSessions.newest(in: here + "/.", listing: out), "ses_here")
        XCTAssertEqual(try OpenCodeSessions.newest(in: here + "/", listing: out), "ses_here")
    }

    func testOutputThatIsNotTheListingThrows() {
        XCTAssertThrowsError(try OpenCodeSessions.newest(in: here, listing: "Error: no project found"))
        XCTAssertThrowsError(try OpenCodeSessions.newest(in: here, listing: #"{"id":"ses_x"}"#))
    }

    // MARK: - The real listing, run against a stand-in `opencode`

    /// An executable shell script beside the recorded files, standing in for `opencode`.
    private func stubOpenCode(_ body: String) throws -> URL {
        let script = root.appendingPathComponent("stub-opencode.sh")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// A non-zero exit is OpenCode's failure to report, with its own words, not an empty listing.
    func testAListingThatExitsNonZeroThrowsWithOpenCodesOwnWords() async throws {
        let stub = try stubOpenCode("echo boom-marker-on-stderr >&2\nexit 1\n")

        do {
            let listing = try await AppCoordinator.listOpenCodeSessions(executable: stub.path, folder: here)
            XCTFail("a failed listing returned \(listing.debugDescription)")
        } catch {
            XCTAssertTrue(String(describing: error).contains("boom-marker-on-stderr"), String(describing: error))
        }
    }

    /// The listing runs `OpenCodeSessions.listArguments` in the session's folder and returns what
    /// OpenCode printed.
    func testTheListingRunsTheListArgumentsInTheFolderAndReturnsTheOutput() async throws {
        let stub = try stubOpenCode("""
            printf '%s\\n' "$@" > "$(dirname "$0")/argv"
            pwd -P > "$(dirname "$0")/cwd"
            printf '%s' '[{"id":"ses_x","directory":"/d","updated":1}]'
            """)

        let out = try await AppCoordinator.listOpenCodeSessions(executable: stub.path, folder: here)

        XCTAssertEqual(out, #"[{"id":"ses_x","directory":"/d","updated":1}]"#)
        let argv = try String(contentsOf: root.appendingPathComponent("argv"), encoding: .utf8)
        XCTAssertEqual(argv.split(separator: "\n").map(String.init), OpenCodeSessions.listArguments)
        let cwd = try String(contentsOf: root.appendingPathComponent("cwd"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ProjectPath.canonical(cwd), ProjectPath.canonical(here))
    }
}
