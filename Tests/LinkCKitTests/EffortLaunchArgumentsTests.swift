import XCTest
@testable import LinkCKit

final class EffortLaunchArgumentsTests: XCTestCase {
    func testClaudeAndAgyPassEffortFlag() {
        XCTAssertEqual(
            AgentModelCatalog.effortLaunchArguments(effort: .high, for: .claude),
            ["--effort", "high"])
        XCTAssertEqual(
            AgentModelCatalog.effortLaunchArguments(effort: .low, for: .agy),
            ["--effort", "low"])
    }

    func testCodexPassesModelReasoningEffortConfig() {
        XCTAssertEqual(
            AgentModelCatalog.effortLaunchArguments(effort: .medium, for: .codex),
            ["-c", "model_reasoning_effort=\"medium\""])
    }

    func testCrushOpenCodeKiloCursorTakeNoEffortArgument() {
        for agent in [AgentKind.crush, .opencode, .kilo, .cursor, .grok] {
            XCTAssertEqual(
                AgentModelCatalog.effortLaunchArguments(effort: .high, for: agent),
                [],
                agent.rawValue)
        }
    }

    func testClaudeLaunchArgsAppendEffortAfterModel() {
        let settingsPath = "/tmp/linkc-settings.json"
        let args = AppCoordinator.claudeLaunchArgs(mode: .new, resumeId: nil, settingsPath: settingsPath)
            + AgentModelCatalog.launchArguments(model: "sonnet", for: .claude)
            + AgentModelCatalog.effortLaunchArguments(effort: .medium, for: .claude)
        XCTAssertTrue(args.contains("--effort"))
        XCTAssertEqual(args.last, "medium")
        let effortIdx = args.firstIndex(of: "--effort")!
        let modelIdx = args.firstIndex(of: "--model")!
        XCTAssertLessThan(modelIdx, effortIdx)
    }
}
