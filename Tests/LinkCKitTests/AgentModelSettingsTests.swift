import XCTest
@testable import LinkCKit

final class AgentModelSettingsTests: XCTestCase {
    func testSeededMappingMatchesTheSpec() {
        let s = AgentModelSettings.seeded
        XCTAssertEqual(s.model(for: .claude, tier: .light), "haiku")
        XCTAssertEqual(s.model(for: .claude, tier: .standard), "sonnet")
        XCTAssertEqual(s.model(for: .claude, tier: .deep), "opus")
        // Every codex id was confirmed by a live `codex exec --model <id>` run. The first
        // guesses, gpt-6-sol and gpt-6-luna, came back HTTP 400; these spellings answered.
        XCTAssertEqual(s.model(for: .codex, tier: .light), "gpt-5.6-luna")
        XCTAssertEqual(s.model(for: .codex, tier: .standard), "gpt-5.6-sol")
        XCTAssertEqual(s.model(for: .codex, tier: .deep), "gpt-6-astra")
        XCTAssertEqual(s.model(for: .agy, tier: .light), "gemini-3.8-flash-low")
        XCTAssertEqual(s.model(for: .agy, tier: .standard), "gemini-3.8-flash-medium")
        XCTAssertEqual(s.model(for: .agy, tier: .deep), "gemini-3.1-pro-high")
        XCTAssertEqual(s.defaultTier(for: .codex), .standard)
    }

    func testCursorAndShellHaveNoMapping() {
        let s = AgentModelSettings.seeded
        XCTAssertNil(s.model(for: .cursor, tier: .standard))
        XCTAssertNil(s.model(for: .shell, tier: .standard))
    }

    func testAnEditedModelIsReadBackAndSurvivesARoundTrip() throws {
        var s = AgentModelSettings.seeded
        s.setModel("gpt-7-nova", for: .codex, tier: .deep)
        s.setDefaultTier(.light, for: .codex)
        let decoded = try JSONDecoder().decode(AgentModelSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded.model(for: .codex, tier: .deep), "gpt-7-nova")
        XCTAssertEqual(decoded.defaultTier(for: .codex), .light)
    }

    func testTierForModelPrefersTheLighterTierWhenTwoShareAnId() {
        var s = AgentModelSettings.seeded
        s.setModel("sonnet", for: .claude, tier: .light)
        XCTAssertEqual(s.tier(forModel: "sonnet", agent: .claude), .light)
        XCTAssertEqual(s.tier(forModel: "opus", agent: .claude), .deep)
        XCTAssertNil(s.tier(forModel: "something-nobody-configured", agent: .claude))
    }

    func testAnAgentWithNoConfiguredDefaultFallsBackToStandard() {
        var s = AgentModelSettings(models: [:], defaultTiers: [:])
        XCTAssertEqual(s.defaultTier(for: .claude), .standard)
        s.setDefaultTier(.deep, for: .claude)
        XCTAssertEqual(s.defaultTier(for: .claude), .deep)
    }
}
