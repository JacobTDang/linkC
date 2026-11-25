import XCTest
@testable import LinkCKit

/// agy takes `--effort` only for a model whose ids carry a level, and only a level agy lists for it.
/// Measured on agy 1.5.16 with `agy --print`: `--model gemini-3.8-flash --effort high` runs Gemini 3.8
/// Flash (High); `gemini-3.8-flash --effort xhigh` is refused, "(available: low, medium, high)";
/// `gpt-oss-120b --effort high` is refused, "(available: medium)"; and `claude-opus-4-6-thinking
/// --effort high` is refused, "--effort is not supported for model".
final class AgyEffortTests: XCTestCase {
    private let listed = TestModelLists.agyModels

    func testALeveledIdSplitsIntoItsBaseAndLevel() throws {
        let flash = try XCTUnwrap(AgyEffort.split("gemini-3.8-flash-low"))
        XCTAssertEqual(flash.base, "gemini-3.8-flash")
        XCTAssertEqual(flash.level, .low)
        let hydrogen = try XCTUnwrap(AgyEffort.split("gemini-4-hydrogen-xhigh"))
        XCTAssertEqual(hydrogen.base, "gemini-4-hydrogen")
        XCTAssertEqual(hydrogen.level, .xhigh)
        XCTAssertNil(AgyEffort.split("claude-opus-4-6-thinking"))
        XCTAssertNil(AgyEffort.split("claude-sonnet-4-6"))
        XCTAssertNil(AgyEffort.split("gemini-3.8-flash"))
    }

    func testTheLevelsAreTheOnesAgyListsForTheIdsBase() {
        XCTAssertEqual(AgyEffort.levels(for: "gemini-3.8-flash-low", listed: listed), [.low, .medium, .high])
        XCTAssertEqual(AgyEffort.levels(for: "gemini-4-hydrogen-medium", listed: listed), [.low, .medium, .high, .xhigh])
        XCTAssertEqual(AgyEffort.levels(for: "gpt-oss-120b-medium", listed: listed), [.medium])
        XCTAssertEqual(AgyEffort.levels(for: "claude-opus-4-6-thinking", listed: listed), [])
        XCTAssertEqual(AgyEffort.levels(for: "gemini-3.1-pro-high", listed: listed), [], "agy no longer lists Pro")
    }

    func testAnOfferedLevelLaunchesTheBaseIdWithTheFlag() {
        let launch = AgyEffort.launch(id: "gemini-3.8-flash-low", effort: .high, listed: listed)
        XCTAssertEqual(launch.model, "gemini-3.8-flash")
        XCTAssertEqual(launch.effort, .high)
        let gptOss = AgyEffort.launch(id: "gpt-oss-120b-medium", effort: .medium, listed: listed)
        XCTAssertEqual(gptOss.model, "gpt-oss-120b")
        XCTAssertEqual(gptOss.effort, .medium)
    }

    func testAnythingElseLaunchesTheIdAsConfiguredWithNoFlag() {
        let cases: [(id: String, effort: ReasoningEffort?, listed: [ListedModel]?)] = [
            ("claude-opus-4-6-thinking", .high, listed),
            ("claude-sonnet-4-6", .low, listed),
            ("gpt-oss-120b-medium", .high, listed),
            ("gemini-3.8-flash-low", .xhigh, listed),
            ("gemini-3.8-flash-low", nil, listed),
            ("gemini-3.8-flash-low", .high, nil),
        ]
        for c in cases {
            let launch = AgyEffort.launch(id: c.id, effort: c.effort, listed: c.listed)
            XCTAssertEqual(launch.model, c.id, "\(c.id) at \(String(describing: c.effort))")
            XCTAssertNil(launch.effort, "\(c.id) at \(String(describing: c.effort))")
        }
    }

    /// Settings offers only the levels agy lists for the tier's model, and says why when there are none.
    func testSettingsOffersOnlyTheLevelsTheModelHas() {
        XCTAssertEqual(AgentEffortSupport.forModel("gemini-3.8-flash-low", agent: .agy, listed: listed),
                       .levels([.low, .medium, .high]))
        XCTAssertEqual(AgentEffortSupport.forModel("gemini-4-hydrogen-high", agent: .agy, listed: listed),
                       .levels([.low, .medium, .high, .xhigh]))
        XCTAssertEqual(AgentEffortSupport.forModel("claude-opus-4-6-thinking", agent: .agy, listed: listed),
                       .unsupported(reason: "agy lists no effort levels for claude-opus-4-6-thinking, so it runs as configured"))
        XCTAssertEqual(AgentEffortSupport.forModel("gemini-3.8-flash-low", agent: .agy, listed: nil),
                       .unsupported(reason: "agy's models have not been listed yet, so gemini-3.8-flash-low runs as configured"))
        XCTAssertEqual(AgentEffortSupport.forModel(nil, agent: .agy, listed: listed),
                       .unsupported(reason: "no model is set for this tier"))
        XCTAssertEqual(AgentEffortSupport.forModel("sonnet", agent: .claude, listed: nil), .levels(ReasoningEffort.allCases))
    }

    /// The level Settings shows is the one that will run: the tier's effort when agy lists it for the
    /// model, else the level baked into the id.
    func testSettingsShowsTheLevelThatWillRun() {
        XCTAssertEqual(AgyEffort.runningLevel(id: "gemini-3.8-flash-low", effort: .high, listed: listed), .high)
        XCTAssertEqual(AgyEffort.runningLevel(id: "gemini-3.8-flash-low", effort: .xhigh, listed: listed), .low)
        XCTAssertNil(AgyEffort.runningLevel(id: "claude-opus-4-6-thinking", effort: .high, listed: listed))
    }
}
