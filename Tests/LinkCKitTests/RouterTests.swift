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
        active: Set<AgentKind> = [],
        settings: AgentModelSettings? = nil,
        refusals: [AgentKind: String] = [:]
    ) throws -> RouterDecision {
        try Router.route(
            prompt: prompt,
            installed: installed ?? agents,
            settings: settings ?? self.settings,
            limits: limited,
            usageTight: Set(usage.filter { $0.value >= 80 }.map(\.key)),
            activeInFolder: active,
            refusals: refusals
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
        XCTAssertEqual(d.agent, .agy)
        XCTAssertEqual(d.reason, "web research → agy light (browse-capable); effort low")
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

    /// A browse agent passed over for web research is named in the reason whether or not another
    /// browse agent takes the work: agy refused and OpenCode chosen says why agy is not first.
    func testWebResearchNamesARefusedBrowseAgentWhenAnotherBrowseAgentTakesIt() throws {
        let why = "light tier is set to gemini-3.8-flash-low, which agy no longer offers"
        let d = try route(
            "Browse the docs for this API",
            installed: [.agy, .opencode, .claude],
            refusals: [.agy: why])
        XCTAssertEqual(d.agent, .opencode)
        XCTAssertEqual(d.reason, "web research → opencode light (browse-capable); agy skipped (\(why))")
    }

    /// With no browse agent free, each skipped browse agent is named once, not again in the passed-over list.
    func testWebResearchNamesEachSkippedBrowseAgentOnceWhenNoneIsFree() throws {
        let d = try route(
            "Browse the docs for this API",
            installed: [.agy, .opencode, .claude],
            refusals: [.agy: "agy refused", .opencode: "opencode refused"])
        XCTAssertEqual(d.agent, .claude)
        XCTAssertEqual(
            d.reason,
            "web research → claude light (no browse-capable agent free); agy skipped (agy refused); opencode skipped (opencode refused); effort low")
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
            active: [.claude])
        XCTAssertEqual(d.agent, .codex)
        XCTAssertEqual(d.reason, "implementation → codex standard; claude skipped (limited); effort medium")
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
            active: [.claude])
        XCTAssertEqual(d.agent, .codex, "claude is tight (>=80%); prefer headroom")
        XCTAssertEqual(d.reason, "implementation → codex standard; claude skipped (usage tight); effort medium")
    }

    func testTiesGoToTheAgentAlreadyActiveInTheFolder() throws {
        let d = try route(
            "Implement a feature",
            installed: [.claude, .codex],
            active: [.codex])
        XCTAssertEqual(d.agent, .codex)
        XCTAssertEqual(d.reason, "implementation → codex standard; tie → already active in folder; effort medium")
    }

    /// With no agent active in the folder, the first free candidate takes the work and the reason
    /// claims no tie.
    func testWithNothingActiveTheFirstCandidateIsPicked() throws {
        let d = try route("Implement a feature", installed: [.claude, .codex])
        XCTAssertEqual(d.agent, .claude)
        XCTAssertEqual(d.reason, "implementation → claude standard; effort medium")
    }

    func testRefusesWhenEveryAgentIsLimited() {
        XCTAssertThrowsError(try route(
            "Implement a feature",
            installed: [.claude],
            limited: [RouterLimit(agent: .claude, pool: nil)]
        )) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "no installed agent is free to take this task at standard — claude skipped (limited). Name an agent with `to`.")
        }
    }

    /// Keywords match whole words and phrases, never a piece of another word: "information" is not
    /// "format", "browser" is not "browse", and a file or guide named after a hard topic is not that topic.
    func testTheClassifierMatchesWholeWordsAndPhrases() {
        let cases: [(prompt: String, kind: Router.TaskKind)] = [
            ("show the model information", .ordinary),
            ("browser extension crash", .ordinary),
            ("Fix the typo in the migration guide", .trivialEdit),
            ("Rename the variable in Security.swift", .trivialEdit),
            ("Fix the typo in ARCHITECTURE.md", .trivialEdit),
            ("parser for the new config format", .ordinary),
        ]
        for (prompt, kind) in cases {
            XCTAssertEqual(Router.classify(prompt), kind, prompt)
        }
    }

    /// Light is for short prompts: a long brief that mentions a rename is ordinary work, and long
    /// web research still goes to a browse-capable agent, on its standard tier.
    func testOnlyAShortPromptIsSentToLight() throws {
        let brief = "Rename the session store's helpers, then thread the new effort field through every path that creates, copies or looks up a task, and add tests for each of them"
        XCTAssertEqual(Router.classify(brief), .ordinary)
        XCTAssertEqual(try route(brief).tier, .standard)

        let research = "Do some web research on how each agent CLI sets reasoning effort, compare their flags and config keys, note which models refuse it, and summarise what you find"
        XCTAssertEqual(Router.classify(research), .webResearch)
        let d = try route(research)
        XCTAssertEqual(d.agent, .agy)
        XCTAssertEqual(d.tier, .standard)
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
