import XCTest
@testable import LinkCKit

final class SubagentRobustnessTests: XCTestCase {

    // MARK: - 1. TranscriptLine.Input effectiveDescription

    func testTranscriptLineInputEffectiveDescriptionPriority() throws {
        let jsonDescription = """
        {"command":"test","description":"Primary description","prompt":"Prompt fallback","task":"Task fallback","goal":"Goal fallback"}
        """
        let inputDesc = try JSONDecoder().decode(TranscriptLine.Input.self, from: Data(jsonDescription.utf8))
        XCTAssertEqual(inputDesc.description, "Primary description")
        XCTAssertEqual(inputDesc.prompt, "Prompt fallback")
        XCTAssertEqual(inputDesc.task, "Task fallback")
        XCTAssertEqual(inputDesc.goal, "Goal fallback")
        XCTAssertEqual(inputDesc.effectiveDescription, "Primary description")

        let jsonPrompt = """
        {"prompt":"Prompt text","task":"Task text","goal":"Goal text"}
        """
        let inputPrompt = try JSONDecoder().decode(TranscriptLine.Input.self, from: Data(jsonPrompt.utf8))
        XCTAssertEqual(inputPrompt.effectiveDescription, "Prompt text")

        let jsonEmptyDesc = """
        {"description":"","prompt":"Prompt from empty desc"}
        """
        let inputEmptyDesc = try JSONDecoder().decode(TranscriptLine.Input.self, from: Data(jsonEmptyDesc.utf8))
        XCTAssertEqual(inputEmptyDesc.effectiveDescription, "Prompt from empty desc")

        let jsonTask = """
        {"task":"Task only","goal":"Goal fallback"}
        """
        let inputTask = try JSONDecoder().decode(TranscriptLine.Input.self, from: Data(jsonTask.utf8))
        XCTAssertEqual(inputTask.effectiveDescription, "Task only")

        let jsonGoal = """
        {"goal":"Goal only"}
        """
        let inputGoal = try JSONDecoder().decode(TranscriptLine.Input.self, from: Data(jsonGoal.utf8))
        XCTAssertEqual(inputGoal.effectiveDescription, "Goal only")

        let jsonNone = """
        {"command":"ls"}
        """
        let inputNone = try JSONDecoder().decode(TranscriptLine.Input.self, from: Data(jsonNone.utf8))
        XCTAssertNil(inputNone.effectiveDescription)
    }

    // MARK: - 2. AgentEvents Recognized Tool Names

    func testAgentEventsRecognizesModernToolNames() throws {
        let toolNames = ["Agent", "Task", "invoke_subagent", "subagent", "linkc_delegate_task"]

        for (idx, toolName) in toolNames.enumerated() {
            let line = """
            {"type":"assistant","timestamp":"2026-07-23T04:00:0\(idx)Z","message":{"content":[\
            {"type":"tool_use","id":"toolu_\(idx)","name":"\(toolName)",\
            "input":{"task":"Perform \(toolName) job","subagent_type":"Worker"}}]}}
            """
            let events = AgentEvents.parse(line: line)
            XCTAssertEqual(events.count, 1, "Tool name '\(toolName)' should produce a spawned event")
            guard let first = events.first else { continue }
            guard case .spawned(let id, let description, let type, _) = first else {
                XCTFail("Expected .spawned event for \(toolName)")
                continue
            }
            XCTAssertEqual(id, "toolu_\(idx)")
            XCTAssertEqual(description, "Perform \(toolName) job")
            XCTAssertEqual(type, "Worker")
        }
    }

    func testAgentEventsToolNameFallbackDescription() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-07-23T04:00:00Z","message":{"content":[\
        {"type":"tool_use","id":"toolu_sub1","name":"invoke_subagent",\
        "input":{"command":"noop"}}]}}
        """
        let events = AgentEvents.parse(line: line)
        XCTAssertEqual(events.count, 1)
        guard case .spawned(let id, let description, _, _)? = events.first else {
            return XCTFail("Expected .spawned event")
        }
        XCTAssertEqual(id, "toolu_sub1")
        XCTAssertEqual(description, "Subagent invoke_subagent")
    }

    func testAgentEventsIgnoresUnrecognizedTool() throws {
        let line = """
        {"type":"assistant","timestamp":"2026-07-23T04:00:00Z","message":{"content":[\
        {"type":"tool_use","id":"toolu_bash","name":"Bash",\
        "input":{"command":"ls -la"}}]}}
        """
        let events = AgentEvents.parse(line: line)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - 3. AppCoordinator In-flight Subagent Preservation

    private final class DummyNotificationSink: NotificationSink, @unchecked Sendable {
        func deliver(id: String, title: String, body: String) {}
    }

    @MainActor
    func testAppCoordinatorPreservesRunningSubagentOnStopAndSweepsOnUserPromptSubmit() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkc-coord-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let transcriptFile = tempDir.appendingPathComponent("transcript.jsonl")
        let spawnLine = """
        {"type":"assistant","timestamp":"2026-07-23T04:00:00Z","message":{"content":[\
        {"type":"tool_use","id":"toolu_sub_flight","name":"invoke_subagent",\
        "input":{"prompt":"Active in-flight subagent work","subagent_type":"Explore"}}]}}
        """
        try (spawnLine + "\n").write(to: transcriptFile, atomically: true, encoding: .utf8)

        let tracker = UsageTracker(projectsDir: tempDir)
        let coordinator = AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer(port: 0),
            notifications: NotificationManager(sink: DummyNotificationSink(), now: { Date() }),
            claudePath: "/bin/echo",
            settingsDir: tempDir.appendingPathComponent("settings"),
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            isWatching: { _ in false }
        )
        coordinator.usageTracker = tracker

        let session = coordinator.store.create(cwd: tempDir.path, title: "Test Session", id: "S1")
        XCTAssertEqual(session.id, "S1")

        // 1. Send stop hook event: Parent turn finishes, but subagent is still in flight in transcript
        let stopEvent = HookEvent(
            kind: .stop,
            linkcSessionId: "S1",
            claudeSessionId: "c1",
            cwd: tempDir.path,
            transcriptPath: transcriptFile.path
        )
        coordinator.handle(stopEvent)

        // Verify the running subagent was preserved (not swept) because it is still running!
        let runsAfterStop = tracker.sessionAgents("S1")
        XCTAssertEqual(runsAfterStop.count, 1)
        guard let runningAgent = runsAfterStop.first else {
            return XCTFail("Expected running agent to be parsed")
        }
        XCTAssertEqual(runningAgent.id, "toolu_sub_flight")
        XCTAssertTrue(runningAgent.isRunning, "Subagent must remain running across .stop while in-flight")
        XCTAssertFalse(runningAgent.endedBySweep)

        // 2. Send user prompt submit event: Next turn begins, previous in-flight subagents are now swept
        let submitEvent = HookEvent(
            kind: .userPromptSubmit,
            linkcSessionId: "S1",
            claudeSessionId: "c1",
            cwd: tempDir.path,
            transcriptPath: transcriptFile.path
        )
        coordinator.handle(submitEvent)

        let runsAfterSubmit = tracker.sessionAgents("S1")
        XCTAssertEqual(runsAfterSubmit.count, 1)
        guard let sweptAgent = runsAfterSubmit.first else {
            return XCTFail("Expected swept agent to be present")
        }
        XCTAssertEqual(sweptAgent.id, "toolu_sub_flight")
        XCTAssertFalse(sweptAgent.isRunning, "Subagent must be swept upon new user prompt submission")
        XCTAssertTrue(sweptAgent.endedBySweep)
    }
}
