import XCTest
@testable import LinkCKit

final class RouterTests: XCTestCase {
    private let settings = AgentModelSettings.seeded
    private let agents: [AgentKind] = [.claude, .codex, .agy, .opencode, .crush]

    private func route(
        _ prompt: String,
        installed: [AgentKind]? = nil,
        limited: [RouterLimit] = [],
        usage: [AgentKind: Double] = [:],
        active: AgentKind? = nil,
        settings: AgentModelSettings? = nil
    ) throws -> RouterDecision {
        try Router.route(
            prompt: prompt,
            installed: installed ?? agents,
            settings: settings ?? self.settings,
            limits: limited,
            usageTight: Set(usage.filter { $0.value >= 80 }.map(\.key)),
            activeInFolder: active
        )
    }

    func testTrivialEditKeywordsPickLight() throws {
        for prompt in ["Rename the helper", "Fix a typo in README", "Format the file", "Bump the version"] {
            let d = try route(prompt)
            XCTAssertEqual(d.tier, .light, prompt)
            XCTAssertEqual(d.effort, .low, prompt)
        }
    }

    func testWebResearchPicksLightOnABrowseCapableAgent() throws {
        let d = try route("Do some web research on Swift concurrency and scrape the docs")
        XCTAssertEqual(d.tier, .light)
        XCTAssertTrue([AgentKind.agy, .opencode].contains(d.agent), "got \(d.agent)")
        XCTAssertTrue(d.reason.lowercased().contains("browse") || d.reason.lowercased().contains("research"),
                      d.reason)
    }

    func testWebResearchPrefersAgyWhenBothAreFree() throws {
        let d = try route("Look up the docs for this API", installed: [.agy, .opencode, .claude])
        XCTAssertEqual(d.agent, .agy)
        XCTAssertEqual(d.tier, .light)
    }

    func testWebResearchFallsToOpenCodeWhenAgyIsLimited() throws {
        let d = try route(
            "Browse the docs for this API",
            installed: [.agy, .opencode, .claude],
            limited: [RouterLimit(agent: .agy, pool: nil)])
        XCTAssertEqual(d.agent, .opencode)
        XCTAssertEqual(d.tier, .light)
    }

    func testOrdinaryImplementationIsStandard() throws {
        let d = try route("Implement the login form and add unit tests")
        XCTAssertEqual(d.tier, .standard)
        XCTAssertEqual(d.effort, .medium)
    }

    func testArchitectureAndSecurityAreDeep() throws {
        for prompt in [
            "Design the architecture for the multiplayer sync",
            "Hard debugging of a race in the relay",
            "Security review of the auth flow",
            "Plan the database migrations"
        ] {
            let d = try route(prompt)
            XCTAssertEqual(d.tier, .deep, prompt)
            XCTAssertEqual(d.effort, .high, prompt)
        }
    }

    func testNeverPicksALimitedAgent() throws {
        let d = try route(
            "Implement a feature",
            installed: [.claude, .codex],
            limited: [RouterLimit(agent: .claude, pool: nil)],
            active: .claude)
        XCTAssertEqual(d.agent, .codex)
    }

    func testNeverPicksALimitedPool() throws {
        // agy's light tier is a Gemini model; a Gemini-pool limit must exclude it.
        let d = try route(
            "Rename a typo",
            installed: [.agy, .claude],
            limited: [RouterLimit(agent: .agy, pool: "gemini")])
        XCTAssertNotEqual(d.agent, .agy)
    }

    func testPrefersAgentsWithUsageHeadroom() throws {
        let d = try route(
            "Implement a feature",
            installed: [.claude, .codex],
            usage: [.claude: 90, .codex: 10],
            active: .claude)
        XCTAssertEqual(d.agent, .codex, "claude is tight (>=80%); prefer headroom")
    }

    func testTiesGoToTheAgentAlreadyActiveInTheFolder() throws {
        let d = try route(
            "Implement a feature",
            installed: [.claude, .codex],
            active: .codex)
        XCTAssertEqual(d.agent, .codex)
        XCTAssertTrue(d.reason.lowercased().contains("active") || d.reason.contains("codex"), d.reason)
    }

    func testRefusesWhenEveryAgentIsLimited() {
        XCTAssertThrowsError(try route(
            "Implement a feature",
            installed: [.claude],
            limited: [RouterLimit(agent: .claude, pool: nil)]
        )) { error in
            XCTAssertTrue(String(describing: error).lowercased().contains("limit")
                          || String(describing: error).lowercased().contains("no agent"),
                          String(describing: error))
        }
    }

    /// Cursor takes no tier and every routed task carries one, so a task routed to Cursor would be
    /// refused when it is delegated. Cursor is never a candidate, even as the only agent free.
    func testCursorIsNeverRoutedToEvenWhenItIsTheOnlyFreeAgent() {
        XCTAssertThrowsError(try route(
            "Implement a feature",
            installed: [.claude, .cursor],
            limited: [RouterLimit(agent: .claude, pool: nil)]
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "no installed agent is free to take this task at standard — claude skipped (limited); cursor skipped (never routed: it takes no tier). Name an agent with `to`.")
        }
    }

    func testUnsupportedEffortAgentGetsNilEffort() throws {
        // Force a route onto opencode via web research with only opencode installed.
        let d = try route(
            "Scrape the docs for this library",
            installed: [.opencode])
        XCTAssertEqual(d.agent, .opencode)
        XCTAssertNil(d.effort)
    }
}
