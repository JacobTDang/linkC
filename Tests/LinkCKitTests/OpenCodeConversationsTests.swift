import XCTest
@testable import LinkCKit

/// How linkC names an OpenCode conversation and reads OpenCode's own answers about it. The JSON
/// below is the shape OpenCode 2.2.5 printed for `session export --sanitize` and
/// `session list --format json`.
final class OpenCodeConversationsTests: XCTestCase {
    /// OpenCode takes any `--session` id that starts with "ses" and creates the conversation under it.
    func testANewIdIsOneOpenCodeAccepts() {
        let id = OpenCodeConversations.newId()
        XCTAssertTrue(id.hasPrefix("ses_linkc"), id)
        XCTAssertEqual(id.count, "ses_linkc".count + 32, id)
        XCTAssertTrue(id.dropFirst("ses_linkc".count).allSatisfy { $0.isHexDigit && !$0.isUppercase }, id)
        XCTAssertNotEqual(OpenCodeConversations.newId(), OpenCodeConversations.newId())
    }

    func testTheLaunchArgumentsNameTheConversation() {
        XCTAssertEqual(OpenCodeConversations.launchArguments(conversationId: "ses_linkcabc"), ["--session", "ses_linkcabc"])
    }

    func testTheModelIsReadFromTheExportsInfo() throws {
        let export = #"{"info":{"id":"ses_linkcabc","agent":"build","model":{"id":"big-pickle","providerID":"opencode","variant":"default"}},"messages":[{"model":{"id":"deepseek-v4.1-flash-free","providerID":"opencode"}}]}"#
        XCTAssertEqual(try OpenCodeConversations.model(fromExport: export), "opencode/big-pickle")
    }

    func testAnExportWithNoModelIsAnError() {
        XCTAssertThrowsError(try OpenCodeConversations.model(fromExport: #"{"info":{"id":"ses_x"},"messages":[]}"#))
        XCTAssertThrowsError(try OpenCodeConversations.model(fromExport: #"{"info":{"model":{"id":"","providerID":"opencode"}}}"#))
        XCTAssertThrowsError(try OpenCodeConversations.model(fromExport: "Session not found"))
    }

    /// `session list` covers the whole project (every worktree of the repo); only the folder's own count.
    func testTheListKeepsOnlyTheFoldersConversationsNewestFirst() throws {
        let list = """
        [
          {"id": "ses_c", "updated": 3, "directory": "/repo"},
          {"id": "ses_b", "updated": 2, "directory": "/repo/.worktrees/other"},
          {"id": "ses_a", "updated": 1, "directory": "/repo/"}
        ]
        """
        XCTAssertEqual(try OpenCodeConversations.ids(fromList: list, in: "/repo"), ["ses_c", "ses_a"])
        XCTAssertEqual(try OpenCodeConversations.ids(fromList: "[]", in: "/repo"), [])
    }

    func testAListThatIsNotJSONIsAnError() {
        XCTAssertThrowsError(try OpenCodeConversations.ids(fromList: "Error: something", in: "/repo"))
    }

    /// Only a missing conversation is an answer; any other failure is reported, with OpenCode's reason.
    func testOnlySessionNotFoundMeansTheConversationIsMissing() {
        XCTAssertTrue(OpenCodeConversations.isMissing(ProcessResult(status: 1, stdout: "", stderr: "Session not found: ses_linkcnope")))
        XCTAssertFalse(OpenCodeConversations.isMissing(ProcessResult(status: 1, stdout: "", stderr: "database is locked")))
        XCTAssertFalse(OpenCodeConversations.isMissing(ProcessResult(status: 0, stdout: "{}", stderr: "")))
    }
}
