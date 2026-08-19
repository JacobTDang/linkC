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

    /// Claude Code sends a human description with most Bash calls — "Reading the token
    /// block" beats the raw `cd …; sed -n '1,80p' …` it describes.
    func testDescriptionOutranksRawArguments() {
        let bash = toolUseLine(
            #"{"type":"tool_use","id":"t8","name":"Bash","input":{"command":"cd /x; sed -n '1,80p' app/globals.css","description":"Reading the token block"}}"#
        )
        XCTAssertEqual(ActivityEvents.apply(line: bash, to: nil)?.label, "Reading the token block")

        // Subagents keep their ▸ mark — the description is the same field, but the kind matters.
        let agent = toolUseLine(
            #"{"type":"tool_use","id":"t9","name":"Agent","input":{"description":"Map architecture"}}"#
        )
        XCTAssertEqual(ActivityEvents.apply(line: agent, to: nil)?.label, "▸ Map architecture")
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

        // NotebookEdit carries its file under notebook_path, not file_path.
        let notebook = toolUseLine(
            #"{"type":"tool_use","id":"t7","name":"NotebookEdit","input":{"notebook_path":"/a/b/analysis.ipynb"}}"#
        )
        XCTAssertEqual(ActivityEvents.apply(line: notebook, to: nil)?.label, "✎ analysis.ipynb")
    }

    /// A finished tool does NOT blank the row: during the thinking that follows, the last
    /// action is more useful than an absence. Only the next action replaces it (and the
    /// turn-boundary sweep wipes it — that part lives in the tracker).
    func testResultKeepsTheLastAction() {
        let current = CurrentActivity(toolUseId: "t1", label: "$ swift test")

        let unrelated = #"{"type":"user","isSidechain":false,"message":{"content":[{"type":"tool_result","tool_use_id":"other"}]}}"#
        XCTAssertEqual(ActivityEvents.apply(line: unrelated, to: current), current)

        let matching = #"{"type":"user","isSidechain":false,"message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}"#
        XCTAssertEqual(ActivityEvents.apply(line: matching, to: current), current,
                       "the last action survives its own result")
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

    /// Ended sessions must not leak tracker state for the process lifetime: unbind drops
    /// every per-session dictionary in one call.
    @MainActor
    func testUnbindDropsAllPerSessionState() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-unbind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        let lines = """
        {"type":"assistant","isSidechain":false,"timestamp":"2026-08-18T04:00:00Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}
        {"type":"assistant","isSidechain":false,"timestamp":"2026-08-18T04:00:01Z","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{"description":"Survey","subagent_type":"Explore"}}]}}
        """
        try (lines + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "S1", transcriptPath: transcript.path)
        tracker.refreshSession("S1")
        XCTAssertNotNil(tracker.sessionActivity("S1"))
        XCTAssertFalse(tracker.sessionAgents("S1").isEmpty)

        tracker.unbind(sessionId: "S1")

        XCTAssertNil(tracker.sessionActivity("S1"))
        XCTAssertTrue(tracker.sessionAgents("S1").isEmpty)
        XCTAssertNil(tracker.sessionUsage("S1"))
        // And a refresh sweep no longer touches the dead session's transcript.
        tracker.refreshAllSessions()
        XCTAssertNil(tracker.sessionActivity("S1"))
    }
}
