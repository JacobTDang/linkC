import XCTest
@testable import LinkCKit

final class ReasoningEffortTests: XCTestCase {
    func testDefaultEffortPerTier() {
        XCTAssertEqual(ReasoningEffort.default(for: .light), .low)
        XCTAssertEqual(ReasoningEffort.default(for: .standard), .medium)
        XCTAssertEqual(ReasoningEffort.default(for: .deep), .high)
    }

    func testSeededEffortsMatchTier() {
        let s = AgentModelSettings.seeded
        for agent in [AgentKind.claude, .codex, .agy, .crush] {
            XCTAssertEqual(s.effort(for: agent, tier: .light), .low, agent.rawValue)
            XCTAssertEqual(s.effort(for: agent, tier: .standard), .medium, agent.rawValue)
            XCTAssertEqual(s.effort(for: agent, tier: .deep), .high, agent.rawValue)
        }
    }

    func testUnsupportedAgentsHaveNoEffort() {
        let s = AgentModelSettings.seeded
        XCTAssertNil(s.effort(for: .cursor, tier: .standard))
        XCTAssertNil(s.effort(for: .grok, tier: .standard))
        XCTAssertNil(s.effort(for: .opencode, tier: .standard))
        XCTAssertNil(s.effort(for: .kilo, tier: .standard))
    }

    func testAnEditedEffortIsReadBack() {
        var s = AgentModelSettings.seeded
        s.setEffort(.xhigh, for: .claude, tier: .deep)
        XCTAssertEqual(s.effort(for: .claude, tier: .deep), .xhigh)
        XCTAssertEqual(s.effort(for: .claude, tier: .standard), .medium)
    }

    func testClaudeCodexAgySupportAllFiveLevels() {
        for agent in [AgentKind.claude, .codex, .agy] {
            guard case .levels(let levels) = AgentEffortSupport.forAgent(agent) else {
                return XCTFail("\(agent.rawValue) should support effort levels")
            }
            XCTAssertEqual(levels, ReasoningEffort.allCases)
        }
    }

    func testCrushSupportsOnlyLowMediumHigh() {
        guard case .levels(let levels) = AgentEffortSupport.forAgent(.crush) else {
            return XCTFail("crush should support effort levels")
        }
        XCTAssertEqual(levels, [.low, .medium, .high])
    }

    func testCursorGrokOpenCodeKiloAreUnsupportedWithAReason() {
        for agent in [AgentKind.cursor, .grok, .opencode, .kilo] {
            guard case .unsupported(let reason) = AgentEffortSupport.forAgent(agent) else {
                return XCTFail("\(agent.rawValue) should be unsupported")
            }
            XCTAssertTrue(reason.contains(agent.displayName) || reason.lowercased().contains(agent.rawValue),
                          "reason should name the agent: \(reason)")
        }
    }
}
