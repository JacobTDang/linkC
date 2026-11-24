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

    /// agy's Gemini ids bake the level in (`…-low` / `…-medium` / `…-high`). Passing both a
    /// leveled id and a conflicting `--effort` makes agy refuse; a matching level is accepted
    /// but the effort flag alone is the source of truth, so launch strips the suffix.
    func testAgyLaunchModelStripsEffortSuffixWhenEffortIsSet() {
        XCTAssertEqual(
            AgentModelCatalog.agyModelIdForLaunch(model: "gemini-3.8-flash-low", effort: .low),
            "gemini-3.8-flash")
        XCTAssertEqual(
            AgentModelCatalog.agyModelIdForLaunch(model: "gemini-3.8-flash-medium", effort: .high),
            "gemini-3.8-flash")
        XCTAssertEqual(
            AgentModelCatalog.agyModelIdForLaunch(model: "gemini-3.1-pro-high", effort: .max),
            "gemini-3.1-pro")
        XCTAssertEqual(
            AgentModelCatalog.agyModelIdForLaunch(model: "gemini-3.8-flash", effort: .low),
            "gemini-3.8-flash")
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
