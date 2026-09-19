import XCTest
@testable import LinkCKit

final class ClaudeTitleTests: XCTestCase {
    func testParseReturnsTheTitle() {
        let line = #"{"type":"ai-title","aiTitle":"Session UI redesign","sessionId":"s1"}"#
        XCTAssertEqual(ClaudeTitle.parse(line), "Session UI redesign")
    }

    func testParseIgnoresOtherLineTypesEvenWhenTheyMentionTheMarker() {
        let quoted = #"{"type":"user","message":{"content":"grep for \"ai-title\" lines"}}"#
        XCTAssertNil(ClaudeTitle.parse(quoted))
        XCTAssertNil(ClaudeTitle.parse(#"{"type":"assistant","message":{}}"#))
    }

    func testParseRejectsABlankMissingOrMalformedTitle() {
        XCTAssertNil(ClaudeTitle.parse(#"{"type":"ai-title","aiTitle":"   ","sessionId":"s1"}"#))
        XCTAssertNil(ClaudeTitle.parse(#"{"type":"ai-title","sessionId":"s1"}"#))
        XCTAssertNil(ClaudeTitle.parse(#"{"type":"ai-title","aiTitle":"#))
    }
}

@MainActor
final class UsageTrackerTitleTests: XCTestCase {
    nonisolated(unsafe) private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func titleLine(_ title: String) -> String {
        #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"c1"}"#
    }

    private let userLine = #"{"type":"user","message":{"content":"hi"}}"#

    private func append(_ text: String, to path: String) throws {
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func testTheLatestTitleWinsIncludingOneAppendedAfterTheFirstRead() throws {
        let path = dir.appendingPathComponent("s.jsonl").path
        try [titleLine("First name"), userLine, titleLine("Second name"), ""].joined(separator: "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "L1", transcriptPath: path)
        tracker.refreshSession("L1")
        XCTAssertEqual(tracker.sessionTitle("L1"), "Second name")

        try append(titleLine("Renamed") + "\n", to: path)
        tracker.refreshSession("L1")
        XCTAssertEqual(tracker.sessionTitle("L1"), "Renamed")
    }

    func testANewReadWithNoTitleLineKeepsTheEarlierTitle() throws {
        let path = dir.appendingPathComponent("s.jsonl").path
        try (titleLine("Kept") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "L1", transcriptPath: path)
        tracker.refreshSession("L1")
        try append(userLine + "\n", to: path)
        tracker.refreshSession("L1")
        XCTAssertEqual(tracker.sessionTitle("L1"), "Kept")
    }

    func testATranscriptWithNoTitleLineHasNoTitle() throws {
        let path = dir.appendingPathComponent("s.jsonl").path
        try (userLine + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "L1", transcriptPath: path)
        tracker.refreshSession("L1")
        XCTAssertNil(tracker.sessionTitle("L1"))
    }

    func testUnbindDropsTheTitle() throws {
        let path = dir.appendingPathComponent("s.jsonl").path
        try (titleLine("Gone soon") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "L1", transcriptPath: path)
        tracker.refreshSession("L1")
        tracker.unbind(sessionId: "L1")
        XCTAssertNil(tracker.sessionTitle("L1"))
    }
}
