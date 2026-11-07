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
        XCTAssertEqual(OpenCodeSessions.listArguments, ["session", "list", "--format", "json", "--standalone"])
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
}
