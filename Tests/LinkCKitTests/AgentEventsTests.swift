import XCTest
@testable import LinkCKit

/// Subagent activity parsed from the session transcript: spawns carry description + type;
/// completion is either a real tool_result (sync agents) or a task-notification naming the
/// tool-use id (async agents — their immediate tool_result is just launch metadata).
final class AgentEventsTests: XCTestCase {

    private let spawnLine = """
    {"type":"assistant","timestamp":"2026-07-23T04:00:00Z","message":{"content":[\
    {"type":"tool_use","id":"toolu_A","name":"Agent",\
    "input":{"description":"Survey local Claude config surface","subagent_type":"Explore","prompt":"..."}}]}}
    """

    func testSpawnParsed() throws {
        let events = AgentEvents.parse(line: spawnLine)
        XCTAssertEqual(events, [.spawned(
            toolUseId: "toolu_A",
            description: "Survey local Claude config surface",
            type: "Explore",
            at: Date(timeIntervalSince1970: 1_784_779_200)
        )])
    }

    func testAsyncLaunchResultIsNotCompletion() {
        let line = """
        {"type":"user","timestamp":"2026-07-23T04:00:01Z","message":{"content":[\
        {"type":"tool_result","tool_use_id":"toolu_A","content":[{"type":"text",\
        "text":"Async agent launched successfully. (This tool result is internal metadata)"}]}]}}
        """
        XCTAssertTrue(AgentEvents.parse(line: line).isEmpty)
    }

    func testSyncToolResultCompletes() throws {
        let line = """
        {"type":"user","timestamp":"2026-07-23T04:05:00Z","message":{"content":[\
        {"type":"tool_result","tool_use_id":"toolu_A","content":[{"type":"text",\
        "text":"Here is the exploration report: 42 findings."}]}]}}
        """
        let events = AgentEvents.parse(line: line)
        XCTAssertEqual(events.count, 1)
        guard case .completed(let id, let result, _) = events[0] else { return XCTFail() }
        XCTAssertEqual(id, "toolu_A")
        XCTAssertEqual(result, "Here is the exploration report: 42 findings.")
    }

    func testTaskNotificationCompletes() throws {
        let line = """
        {"type":"user","timestamp":"2026-07-23T04:08:00Z","message":{"content":\
        "[SYSTEM NOTIFICATION]\\n<task-notification>\\n<tool-use-id>toolu_A</tool-use-id>\\n\
        <status>completed</status>\\n<result>The full agent report body.</result>\\n</task-notification>"}}
        """
        let events = AgentEvents.parse(line: line)
        XCTAssertEqual(events.count, 1)
        guard case .completed(let id, let result, _) = events[0] else { return XCTFail() }
        XCTAssertEqual(id, "toolu_A")
        XCTAssertEqual(result, "The full agent report body.")
    }

    func testGarbageAndUnrelatedLinesAreEmpty() {
        XCTAssertTrue(AgentEvents.parse(line: "not json").isEmpty)
        XCTAssertTrue(AgentEvents.parse(line: #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#).isEmpty)
    }

    func testStringContentToolResultCompletes() throws {
        // Real transcripts sometimes carry tool_result content as a bare string, not a block array.
        let line = """
        {"type":"user","timestamp":"2026-07-23T04:05:00Z","message":{"content":[\
        {"type":"tool_result","tool_use_id":"toolu_A","content":"plain string result"}]}}
        """
        let events = AgentEvents.parse(line: line)
        XCTAssertEqual(events.count, 1)
        guard let first = events.first else { return XCTFail("no events parsed") }
        guard case .completed(let id, let result, _) = first else { return XCTFail() }
        XCTAssertEqual(id, "toolu_A")
        XCTAssertEqual(result, "plain string result")
    }

    func testMalformedBlockDoesNotDropSiblings() throws {
        // One undecodable block (input as a bare string) must not erase the whole line's events.
        let line = """
        {"type":"assistant","timestamp":"2026-07-23T04:00:00Z","message":{"content":[\
        {"type":"tool_use","id":"toolu_X","name":"Agent","input":"garbage-shape"},\
        {"type":"tool_use","id":"toolu_A","name":"Agent",\
        "input":{"description":"Survey","subagent_type":"Explore"}}]}}
        """
        let events = AgentEvents.parse(line: line)
        XCTAssertEqual(events.count, 1)
        guard let first = events.first else { return XCTFail("no events parsed") }
        guard case .spawned(let id, let description, _, _) = first else { return XCTFail() }
        XCTAssertEqual(id, "toolu_A")
        XCTAssertEqual(description, "Survey")
    }

    func testEmptyToolResultStillCompletes() throws {
        // A completion with no text is still a completion — dropping it strands the run as "running".
        let line = """
        {"type":"user","timestamp":"2026-07-23T04:05:00Z","message":{"content":[\
        {"type":"tool_result","tool_use_id":"toolu_A","content":[]}]}}
        """
        let events = AgentEvents.parse(line: line)
        XCTAssertEqual(events.count, 1)
        guard let first = events.first else { return XCTFail("no events parsed") }
        guard case .completed(let id, let result, _) = first else { return XCTFail() }
        XCTAssertEqual(id, "toolu_A")
        XCTAssertNil(result)
    }

    func testAssemblerPairsSpawnsWithCompletions() {
        var assembler = AgentAssembler()
        let t0 = Date(timeIntervalSince1970: 1_784_692_800)
        assembler.feed([
            .spawned(toolUseId: "toolu_A", description: "Survey", type: "Explore", at: t0),
            .spawned(toolUseId: "toolu_B", description: "Design", type: "Plan", at: t0.addingTimeInterval(10)),
        ])
        assembler.feed([.completed(toolUseId: "toolu_A", resultText: "done!", at: t0.addingTimeInterval(120))])

        XCTAssertEqual(assembler.runs.count, 2)
        let a = assembler.runs.first { $0.id == "toolu_A" }!
        XCTAssertFalse(a.isRunning)
        XCTAssertEqual(a.resultText, "done!")
        XCTAssertEqual(a.endedAt, t0.addingTimeInterval(120))
        XCTAssertTrue(assembler.runs.first { $0.id == "toolu_B" }!.isRunning)
        // Completion for an unknown id is a quiet no-op.
        assembler.feed([.completed(toolUseId: "toolu_ghost", resultText: nil, at: t0)])
        XCTAssertEqual(assembler.runs.count, 2)
    }

    func testEndAllRunningSweepsOpenRuns() {
        var assembler = AgentAssembler()
        let t0 = Date(timeIntervalSince1970: 1_784_692_800)
        assembler.feed([
            .spawned(toolUseId: "toolu_A", description: "Survey", type: "Explore", at: t0),
            .spawned(toolUseId: "toolu_B", description: "Design", type: "Plan", at: t0),
        ])
        assembler.feed([.completed(toolUseId: "toolu_A", resultText: "done", at: t0.addingTimeInterval(60))])

        assembler.endAllRunning(at: t0.addingTimeInterval(90))

        let a = assembler.runs.first { $0.id == "toolu_A" }!
        XCTAssertEqual(a.endedAt, t0.addingTimeInterval(60), "already-ended runs keep their real end")
        let b = assembler.runs.first { $0.id == "toolu_B" }!
        XCTAssertFalse(b.isRunning)
        XCTAssertEqual(b.endedAt, t0.addingTimeInterval(90))
        XCTAssertNil(b.resultText)
    }

    func testLateCompletionFillsSweptRun() {
        var assembler = AgentAssembler()
        let t0 = Date(timeIntervalSince1970: 1_784_692_800)
        assembler.feed([.spawned(toolUseId: "toolu_A", description: "Survey", type: "Explore", at: t0)])
        assembler.endAllRunning(at: t0.addingTimeInterval(90))
        assembler.feed([.completed(toolUseId: "toolu_A", resultText: "late report", at: t0.addingTimeInterval(120))])

        XCTAssertEqual(assembler.runs[0].resultText, "late report", "the body we were missing arrives")
        XCTAssertEqual(assembler.runs[0].endedAt, t0.addingTimeInterval(90), "sweep end stamp is kept")
    }
}

/// The tracker-level sweep: refresh reads the spawn from the transcript; the sweep then
/// ends anything the transcript never closed out.
final class AgentSweepTrackerTests: XCTestCase {
    @MainActor
    func testSweepEndsRunningAgents() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("t.jsonl")
        let spawn = """
        {"type":"assistant","timestamp":"2026-07-23T04:00:00Z","message":{"content":[\
        {"type":"tool_use","id":"toolu_A","name":"Agent",\
        "input":{"description":"Survey","subagent_type":"Explore","prompt":"..."}}]}}
        """
        try (spawn + "\n").write(to: transcript, atomically: true, encoding: .utf8)

        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "S1", transcriptPath: transcript.path)
        tracker.refreshSession("S1")
        XCTAssertTrue(tracker.sessionAgents("S1").contains(where: \.isRunning))

        tracker.sweepAgents("S1", at: Date(timeIntervalSince1970: 1_784_779_260))

        let runs = tracker.sessionAgents("S1")
        XCTAssertEqual(runs.count, 1)
        XCTAssertFalse(runs[0].isRunning)
        XCTAssertEqual(runs[0].endedAt, Date(timeIntervalSince1970: 1_784_779_260))
    }
}

/// Compact ages for time-in-state and agent rows: seconds under a minute, then minutes, then hours.
final class AgeFormatTests: XCTestCase {
    func testCompact() {
        XCTAssertEqual(AgeFormat.compact(5), "5s")
        XCTAssertEqual(AgeFormat.compact(59), "59s")
        XCTAssertEqual(AgeFormat.compact(60), "1m")
        XCTAssertEqual(AgeFormat.compact(59 * 60), "59m")
        XCTAssertEqual(AgeFormat.compact(3600), "1h")
        XCTAssertEqual(AgeFormat.compact(26 * 3600), "26h")
        XCTAssertEqual(AgeFormat.compact(-5), "0s", "clock skew clamps to zero")
    }
}

/// Session state transitions stamp when they happened — the "needs permission · 4m" number.
final class StateAgeTests: XCTestCase {
    func testReducerStampsOnlyRealTransitions() {
        let t0 = Date(timeIntervalSince1970: 1_784_692_800)
        let t1 = t0.addingTimeInterval(300)
        var session = Session(id: "L1", cwd: "/tmp", title: "t", state: .working)

        let event = HookEvent(kind: .notificationPermission, linkcSessionId: "L1", claudeSessionId: nil, cwd: nil)
        (session, _) = SessionReducer.apply(event, to: session, now: t0)
        XCTAssertEqual(session.state, .waitingPermission)
        XCTAssertEqual(session.stateChangedAt, t0)

        // The same state arriving again must NOT reset the clock.
        (session, _) = SessionReducer.apply(event, to: session, now: t1)
        XCTAssertEqual(session.stateChangedAt, t0, "re-asserted state keeps the original timestamp")
    }
}
