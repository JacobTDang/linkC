import XCTest
@testable import LinkCKit

/// "What is Claude doing right now?" — the most recent main-chain tool_use without its
/// tool_result yet, formatted for a one-line row. Sidechain lines never leak a subagent's
/// inner actions; a matching result clears; malformed blocks are skipped alone.
final class ActivityEventsTests: XCTestCase {

    private func toolUseLine(_ blockJSON: String, sidechain: Bool = false) -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"message":{"content":[\#(blockJSON)]}}"#
    }

    func testBashShowsFirstCommandLine() {
        let line = toolUseLine(
            #"{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test\ngit push"}}"#
        )
        let activity = ActivityEvents.apply(line: line, to: nil)
        XCTAssertEqual(activity?.label, "$ swift test")
        XCTAssertEqual(activity?.toolUseId, "t1")
    }

    func testFileAndAgentAndFallbackLabels() {
        let edit = toolUseLine(
            #"{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/a/b/PanelView.swift"}}"#
        )
        XCTAssertEqual(ActivityEvents.apply(line: edit, to: nil)?.label, "✎ PanelView.swift")

        let read = toolUseLine(
            #"{"type":"tool_use","id":"t3","name":"Read","input":{"file_path":"/a/b/Theme.swift"}}"#
        )
        XCTAssertEqual(ActivityEvents.apply(line: read, to: nil)?.label, "⊙ Theme.swift")

        let agent = toolUseLine(
            #"{"type":"tool_use","id":"t4","name":"Agent","input":{"description":"Map architecture"}}"#
        )
        XCTAssertEqual(ActivityEvents.apply(line: agent, to: nil)?.label, "▸ Map architecture")

        let other = toolUseLine(#"{"type":"tool_use","id":"t5","name":"WebSearch","input":{}}"#)
        XCTAssertEqual(ActivityEvents.apply(line: other, to: nil)?.label, "WebSearch")
    }

    func testResultClearsOnlyMatchingId() {
        let current = CurrentActivity(toolUseId: "t1", label: "$ swift test")

        let unrelated = #"{"type":"user","isSidechain":false,"message":{"content":[{"type":"tool_result","tool_use_id":"other"}]}}"#
        XCTAssertEqual(ActivityEvents.apply(line: unrelated, to: current), current)

        let matching = #"{"type":"user","isSidechain":false,"message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}"#
        XCTAssertNil(ActivityEvents.apply(line: matching, to: current))
    }

    func testSidechainLinesAreIgnored() {
        let current = CurrentActivity(toolUseId: "t1", label: "$ swift test")
        let sidechain = toolUseLine(
            #"{"type":"tool_use","id":"inner","name":"Bash","input":{"command":"rm -rf /tmp/x"}}"#,
            sidechain: true
        )
        XCTAssertEqual(
            ActivityEvents.apply(line: sidechain, to: current), current,
            "a subagent's inner action must not masquerade as the session's own"
        )
    }

    func testMalformedBlockSkippedAlone() {
        let line = #"{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"tool_use","id":"bad","name":"Bash","input":"garbage-shape"},{"type":"tool_use","id":"t6","name":"Bash","input":{"command":"ls"}}]}}"#
        XCTAssertEqual(ActivityEvents.apply(line: line, to: nil)?.label, "$ ls")
        XCTAssertNil(ActivityEvents.apply(line: "not json", to: nil))
    }
}

/// Tracker exposure: refresh records the activity from the transcript; the turn-boundary
/// sweep clears it alongside the agent runs.
final class ActivityTrackerTests: XCTestCase {
    @MainActor
    func testTrackerTracksAndSweepClears() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        let line = #"{"type":"assistant","isSidechain":false,"timestamp":"2026-08-18T04:00:00Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}"#
        try (line + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "S1", transcriptPath: transcript.path)
        tracker.refreshSession("S1")
        XCTAssertEqual(tracker.sessionActivity("S1"), "$ swift test")

        tracker.sweepAgents("S1")
        XCTAssertNil(tracker.sessionActivity("S1"), "turn boundaries clear the activity too")
    }
}
