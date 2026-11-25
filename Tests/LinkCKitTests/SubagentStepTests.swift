import XCTest
@testable import LinkCKit

/// A Claude session's running subagents, each by the name it was given and the step its own
/// transcript (`<session>/subagents/agent-<id>.jsonl`, tied to its spawn by `<id>.meta.json`) is on.
@MainActor
final class SubagentStepTests: XCTestCase {
    private var dir: URL!
    private var transcript: URL { dir.appendingPathComponent("made-up-session.jsonl") }
    private var subagents: URL { dir.appendingPathComponent("made-up-session/subagents") }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-substeps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func spawn(_ id: String, _ description: String) -> String {
        #"{"type":"assistant","isSidechain":false,"timestamp":"2026-08-18T04:00:00Z","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"Agent","input":{"description":"\#(description)","subagent_type":"Explore"}}]}}"#
    }

    private func result(_ id: String) -> String {
        #"{"type":"user","isSidechain":false,"timestamp":"2026-08-18T04:05:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"done"}]}}"#
    }

    private func sidechainRead(_ file: String) -> String {
        #"{"type":"assistant","isSidechain":true,"agentId":"x","timestamp":"2026-08-18T04:01:00Z","message":{"content":[{"type":"tool_use","id":"s\#(file.count)","name":"Read","input":{"file_path":"/p/\#(file)"}}]}}"#
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func subagent(_ agentId: String, spawnedBy toolUseId: String, lines: [String]) throws {
        try write([#"{"agentType":"Explore","description":"ignored","toolUseId":"\#(toolUseId)"}"#],
                  to: subagents.appendingPathComponent("agent-\(agentId).meta.json"))
        try write(lines, to: subagents.appendingPathComponent("agent-\(agentId).jsonl"))
    }

    private func tracker() -> UsageTracker {
        let tracker = UsageTracker(projectsDir: dir)
        tracker.bind(sessionId: "S1", transcriptPath: transcript.path)
        return tracker
    }

    func testARunningSubagentShowsItsNameAndTheStepItsTranscriptIsOn() throws {
        try write([spawn("toolu_A", "Survey the readers")], to: transcript)
        try subagent("aaa", spawnedBy: "toolu_A", lines: [sidechainRead("One.swift"), sidechainRead("Two.swift")])
        let tracker = tracker()

        tracker.refreshSession("S1")

        XCTAssertEqual(tracker.sessionSubagentSteps("S1"), [.init(name: "Survey the readers", step: "⊙ Two.swift")])
    }

    /// The step follows the subagent's transcript as it grows.
    func testTheStepMovesAsTheSubagentWorks() throws {
        try write([spawn("toolu_A", "Survey")], to: transcript)
        try subagent("aaa", spawnedBy: "toolu_A", lines: [sidechainRead("One.swift")])
        let tracker = tracker()
        tracker.refreshSession("S1")

        let handle = try FileHandle(forWritingTo: subagents.appendingPathComponent("agent-aaa.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((sidechainRead("Three.swift") + "\n").utf8))
        try handle.close()
        tracker.refreshSession("S1")

        XCTAssertEqual(tracker.sessionSubagentSteps("S1").map(\.step), ["⊙ Three.swift"])
    }

    /// One whose transcript is not there yet still shows by name; a finished one does not show.
    func testASubagentWithNoTranscriptYetShowsByNameAndAFinishedOneNotAtAll() throws {
        try write([spawn("toolu_A", "Plan the change"), spawn("toolu_B", "Already done"), result("toolu_B")], to: transcript)
        try subagent("bbb", spawnedBy: "toolu_B", lines: [sidechainRead("Gone.swift")])
        let tracker = tracker()

        tracker.refreshSession("S1")

        XCTAssertEqual(tracker.sessionSubagentSteps("S1"), [.init(name: "Plan the change", step: nil)])
    }

    func testUnbindDropsTheSubagentSteps() throws {
        try write([spawn("toolu_A", "Survey")], to: transcript)
        try subagent("aaa", spawnedBy: "toolu_A", lines: [sidechainRead("One.swift")])
        let tracker = tracker()
        tracker.refreshSession("S1")

        tracker.unbind(sessionId: "S1")

        XCTAssertEqual(tracker.sessionSubagentSteps("S1"), [])
    }
}
