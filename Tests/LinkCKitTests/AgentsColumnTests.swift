import XCTest
@testable import LinkCKit

/// The agent cards linkC draws beside a session's terminal, built from the known-projects list the
/// way the linkc-agents mod builds them inside the agent CLI (mods/linkc-agents/hooks/register.tsx).
final class AgentsColumnTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func iso(_ date: Date) -> String { date.formatted(.iso8601) }

    private func session(
        _ id: String, agent: String = "codex", activity: KnownProject.OpenSession.Activity = .idle,
        title: String? = nil, state: String? = "ready", since: Date? = nil, model: String? = nil,
        worker: Bool? = nil, action: String? = nil, subagents: Int? = nil,
        cacheExpiresAt: String? = nil, cacheEstimate: Bool? = nil, contextPercent: Int? = nil,
        step: String? = nil, subagentSteps: [KnownProject.OpenSession.Subagent]? = nil
    ) -> KnownProject.OpenSession {
        KnownProject.OpenSession(id: id, agent: agent, activity: activity, title: title ?? id, state: state,
                                 since: since.map(iso), model: model, worker: worker, action: action,
                                 subagents: subagents, cacheExpiresAt: cacheExpiresAt, cacheEstimate: cacheEstimate,
                                 contextPercent: contextPercent, step: step, subagentSteps: subagentSteps)
    }

    /// A session the app published without a title.
    private func untitled(_ id: String, agent: String, state: String = "ready") -> KnownProject.OpenSession {
        KnownProject.OpenSession(id: id, agent: agent, activity: .idle, title: nil, state: state)
    }

    private func column(_ sessions: [KnownProject.OpenSession], selected: String? = nil, in path: String = "/repo",
                        limits: [String: [KnownLimit]] = [:]) -> AgentsColumn {
        AgentsColumn.build(projects: [KnownProject(path: path, sessions: sessions)], limits: limits,
                           roots: [path: .repo(path)], selectedId: selected ?? sessions[0].id)
    }

    private func card(_ session: KnownProject.OpenSession, in path: String = "/repo") throws -> AgentCard {
        try XCTUnwrap(column([session], in: path).cards.first)
    }

    // MARK: - Which sessions

    func testTheColumnListsTheSelectedSessionsRepoWithEveryWorktreeAndNothingElse() {
        let projects = [
            KnownProject(path: "/repo", sessions: [session("A")]),
            KnownProject(path: "/repo/.worktrees/fix", sessions: [session("B")]),
            KnownProject(path: "/repo/.claude/worktrees/feat/Sources", sessions: [session("C")]),
            KnownProject(path: "/far-away", sessions: [session("D")]),
            KnownProject(path: "/other", sessions: [session("E")]),
            // Shares the repo's folder name as a prefix, but not its folder.
            KnownProject(path: "/repo-two", sessions: [session("F")]),
        ]
        let roots: [String: RepoRoots.Root] = [
            "/repo": .repo("/repo"),
            "/repo/.worktrees/fix": .repo("/repo"),
            "/repo/.claude/worktrees/feat/Sources": .repo("/repo"),
            // A worktree outside the repo's folder.
            "/far-away": .repo("/repo"),
            "/other": .repo("/other"),
            "/repo-two": .repo("/repo-two"),
        ]

        let column = AgentsColumn.build(projects: projects, limits: [:], roots: roots, selectedId: "B")

        let shown = Dictionary(uniqueKeysWithValues: column.cards.map { ($0.id, $0.worktree) })
        XCTAssertEqual(shown, ["A": "", "B": "fix", "C": "feat", "D": "far-away"])
        XCTAssertNil(column.problem)
        XCTAssertFalse(column.isPending)
    }

    /// A folder whose repo git has not answered for yet joins by lying inside the repo's folder.
    func testAFolderNotResolvedYetJoinsByLyingInsideTheRepo() {
        let projects = [
            KnownProject(path: "/repo", sessions: [session("A")]),
            KnownProject(path: "/repo/Sources", sessions: [session("B")]),
            KnownProject(path: "/elsewhere", sessions: [session("C")]),
            // Shares the repo's folder name as a prefix, but not its folder.
            KnownProject(path: "/repo-two", sessions: [session("D")]),
        ]

        let column = AgentsColumn.build(projects: projects, limits: [:], roots: ["/repo": .repo("/repo")], selectedId: "A")

        XCTAssertEqual(column.cards.map(\.id).sorted(), ["A", "B"])
        XCTAssertEqual(column.cards.first { $0.id == "B" }?.worktree, "Sources")
    }

    /// Outside git a folder is its own repo: its sessions, and no other folder's.
    func testOutsideGitTheFolderIsTheRepo() {
        let projects = [
            KnownProject(path: "/plain", sessions: [session("A"), session("B")]),
            KnownProject(path: "/plain-too", sessions: [session("C")]),
        ]
        let roots: [String: RepoRoots.Root] = ["/plain": .repo("/plain"), "/plain-too": .repo("/plain-too")]

        let column = AgentsColumn.build(projects: projects, limits: [:], roots: roots, selectedId: "A")

        XCTAssertEqual(column.cards.map(\.id).sorted(), ["A", "B"])
        XCTAssertEqual(column.cards.map(\.worktree), ["", ""])
    }

    func testAGitFailureSaysWhyInPlaceOfTheCards() {
        let projects = [KnownProject(path: "/repo", sessions: [session("A")])]

        let column = AgentsColumn.build(projects: projects, limits: [:], roots: ["/repo": .failed("git cannot read the repo of /repo: dubious ownership")],
                                        selectedId: "A")

        XCTAssertEqual(column.problem, "git cannot read the repo of /repo: dubious ownership")
        XCTAssertEqual(column.cards, [])
    }

    func testUntilGitAnswersTheColumnWaitsRatherThanSayingTheRepoIsEmpty() {
        let projects = [KnownProject(path: "/repo", sessions: [session("A")])]

        let column = AgentsColumn.build(projects: projects, limits: [:], roots: [:], selectedId: "A")

        XCTAssertTrue(column.isPending)
        XCTAssertEqual(column.cards, [])
        XCTAssertNil(column.problem)
    }

    func testASessionNotPublishedYetWaitsToo() {
        let projects = [KnownProject(path: "/repo", sessions: [session("A")])]

        let column = AgentsColumn.build(projects: projects, limits: [:], roots: ["/repo": .repo("/repo")], selectedId: "NEW")

        XCTAssertTrue(column.isPending)
        XCTAssertEqual(column.cards, [])
    }

    // MARK: - Order and header

    func testWhatNeedsYouSortsFirstThenWorkThenTheRest() {
        let sessions = [
            session("1", title: "ready", state: "ready"),
            session("2", title: "done", state: "finished"),
            session("3", title: "working b", state: "working"),
            session("4", title: "waiting", state: "waitingIdle"),
            session("5", title: "working a", state: "working"),
            session("6", title: "error", state: "error"),
            session("7", title: "permission", state: "waitingPermission"),
            session("8", title: "starting", state: "starting"),
        ]

        let titles = column(sessions).cards.map(\.title)

        XCTAssertEqual(titles, ["permission", "error", "waiting", "working a", "working b", "starting", "done", "ready"])
    }

    /// Ties sort by what the card's title says: an untitled card's is its raw agent name, as in the mod.
    func testAnUntitledCardSortsByItsRawAgentName() {
        // "codex" sorts before "Codex"; the agent's display name would tie them, and the id would put A first.
        let ids = column([session("A", title: "Codex"), untitled("B", agent: "codex")]).cards.map(\.id)

        XCTAssertEqual(ids, ["B", "A"])
    }

    func testTheHeaderCountsWhatNeedsYouAndEveryCard() {
        let sessions = [
            session("1", state: "waitingPermission"),
            session("2", state: "error"),
            session("3", state: "waitingIdle"),
            session("4", state: "working"),
            session("5", state: "ready"),
        ]

        let column = column(sessions)

        XCTAssertEqual(column.needsYou, 3)
        XCTAssertEqual(column.needsYouLabel, "3 need you")
        XCTAssertEqual(column.countLabel, "5")
        XCTAssertNil(self.column([session("1", state: "ready")]).needsYouLabel)
    }

    func testOnlyTheSelectedSessionsCardIsMarked() {
        let cards = column([session("A"), session("B"), session("C")], selected: "B").cards

        XCTAssertEqual(cards.filter(\.isSelected).map(\.id), ["B"])
    }

    // MARK: - The first line

    func testAModelIdReadsAsAPersonNamesIt() {
        XCTAssertEqual(AgentCard.modelLabel("Opus 5.5"), "Opus 5.5")
        XCTAssertEqual(AgentCard.modelLabel("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(AgentCard.modelLabel("claude-haiku-5-5-20261001"), "Haiku 5.5")
        XCTAssertEqual(AgentCard.modelLabel("claude-opus-4-20250514"), "Opus 4")
        XCTAssertEqual(AgentCard.modelLabel("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        XCTAssertEqual(AgentCard.modelLabel("gemini-3.8-flash-medium"), "gemini-3.8 flash medium")
        XCTAssertEqual(AgentCard.modelLabel("gpt-5.5-codex"), "gpt-5.5 codex")
        XCTAssertEqual(AgentCard.modelLabel("opencode/big-pickle"), "opencode/big-pickle")
    }

    /// The model as a person names it; without one, the agent as the list names it; a worker says so.
    func testTheSubtitleNamesTheModelOrTheAgentAndAWorker() throws {
        XCTAssertEqual(try card(session("A", agent: "agy", model: "gemini-3.8-flash-medium", worker: true)).subtitle,
                       "gemini-3.8 flash medium · worker")
        XCTAssertEqual(try card(session("A", agent: "claude", model: "claude-opus-5-5")).subtitle, "Opus 5.5")
        XCTAssertEqual(try card(session("A", agent: "codex")).subtitle, "codex")
        XCTAssertEqual(try card(session("A", agent: "newcomer")).subtitle, "newcomer")
    }

    /// An untitled card is titled by its raw agent name, as in the mod, and its subtitle does not say it twice.
    func testAnUntitledCardIsTitledByItsRawAgentName() throws {
        let card = try card(untitled("A", agent: "codex"))

        XCTAssertEqual(card.title, "codex")
        XCTAssertEqual(card.subtitle, "")
    }

    func testTheCacheClockRoundsDownAndMarksAGuessTheLastMinuteAndACold() throws {
        let label = { (left: TimeInterval, estimate: Bool?) throws -> AgentCacheLabel? in
            try self.card(self.session("A", cacheExpiresAt: self.iso(self.now + left), cacheEstimate: estimate)).cache(at: self.now)
        }

        XCTAssertEqual(try label(41 * 60 + 59, nil), AgentCacheLabel(text: "◷ 41m", tint: .muted))
        XCTAssertEqual(try label(30 * 60 + 5, true), AgentCacheLabel(text: "◷ ~30m", tint: .muted))
        XCTAssertEqual(try label(5 * 60, nil), AgentCacheLabel(text: "◷ 5m", tint: .soon))
        XCTAssertEqual(try label(59, nil), AgentCacheLabel(text: "◷ <1m", tint: .soon))
        XCTAssertEqual(try label(0, nil), AgentCacheLabel(text: "◷ cold", tint: .cold))
        XCTAssertEqual(try label(-600, true), AgentCacheLabel(text: "◷ cold", tint: .cold))
        XCTAssertEqual(try label(90 * 60, nil), AgentCacheLabel(text: "◷ 1h", tint: .muted))
        XCTAssertNil(try card(session("A")).cache(at: now))
    }

    /// A time that does not parse is said above the cards, which still show; its card shows no clock.
    func testACacheTimeThatIsNotATimeSaysSo() {
        let column = column([session("A", cacheExpiresAt: "soon"), session("B")])

        XCTAssertEqual(column.cards.count, 2)
        XCTAssertEqual(column.problem, #"session A's cache time "soon" is not a time"#)
        XCTAssertNil(column.cards.first { $0.id == "A" }?.cache(at: now))
    }

    func testTheAgeReadsInMinutesHoursOrDays() throws {
        XCTAssertEqual(try card(session("A", since: now - 30)).age(at: now), "now")
        XCTAssertEqual(try card(session("A", since: now - 12 * 60 - 59)).age(at: now), "12m")
        XCTAssertEqual(try card(session("A", since: now - 3 * 3600)).age(at: now), "3h")
        XCTAssertEqual(try card(session("A", since: now - 2 * 86_400)).age(at: now), "2d")
        XCTAssertEqual(try card(session("A")).age(at: now), "")
    }

    // MARK: - The second line

    private struct Line: Equatable {
        let glyph: String
        let detail: String
        let working: Bool
        init(_ glyph: String, _ detail: String, working: Bool) {
            self.glyph = glyph
            self.detail = detail
            self.working = working
        }
    }

    /// The second line of `session`'s card, with the session running in `path` of /repo.
    private func line(_ session: KnownProject.OpenSession, in path: String = "/repo") throws -> Line {
        let anchor = self.session("ANCHOR")
        let projects = path == "/repo"
            ? [KnownProject(path: path, sessions: [anchor, session])]
            : [KnownProject(path: "/repo", sessions: [anchor]), KnownProject(path: path, sessions: [session])]
        var roots: [String: RepoRoots.Root] = ["/repo": .repo("/repo")]
        roots[path] = .repo("/repo")
        let card = try XCTUnwrap(AgentsColumn.build(projects: projects, limits: [:], roots: roots, selectedId: "ANCHOR")
            .cards.first { $0.id == session.id })
        return Line(card.look.glyph, card.detail, working: card.isWorking)
    }

    func testAWorkingCardShowsItsActionOrItsSubagentsAndShimmers() throws {
        let fix = "/repo/.worktrees/fix"
        XCTAssertEqual(try line(session("A", state: "working", action: "Running the suite"), in: fix), Line("●", "Running the suite fix", working: true))
        XCTAssertEqual(try line(session("A", state: "working", action: "Running the suite", subagents: 2)), Line("●", "Running the suite · 2 subagents", working: true))
        XCTAssertEqual(try line(session("A", state: "working", subagents: 1)), Line("●", "running 1 subagent", working: true))
        XCTAssertEqual(try line(session("A", state: "working"), in: fix), Line("●", "fix", working: true))
    }

    /// The dot and the shimmer already say it works: never the word for the state, never an empty line.
    func testAWorkingCardWithNothingToTellYetShimmersOnAnEllipsis() throws {
        XCTAssertEqual(try line(session("A", state: "working")), Line("●", "…", working: true))
    }

    /// A session whose own turn ended while its subagents still run is at work, not idle or waiting.
    func testATurnThatEndedWithSubagentsRunningReadsAsWorking() throws {
        XCTAssertEqual(try line(session("A", state: "finished", subagents: 2)), Line("●", "running 2 subagents", working: true))
        XCTAssertEqual(try line(session("A", state: "waitingIdle", subagents: 1)), Line("●", "running 1 subagent", working: true))
    }

    /// A permission wait or an error still comes first, subagents or not.
    func testWhatNeedsYouReadsAsItsStateAndDoesNotShimmer() throws {
        XCTAssertEqual(try line(session("A", state: "waitingPermission")), Line("!", "needs permission", working: false))
        XCTAssertEqual(try line(session("A", state: "waitingPermission", action: "Edit Foo.swift")), Line("!", "Edit Foo.swift", working: false))
        XCTAssertEqual(try line(session("A", state: "waitingPermission", subagents: 2)), Line("!", "needs permission", working: false))
        XCTAssertEqual(try line(session("A", state: "error", subagents: 2)), Line("✗", "error", working: false))
        XCTAssertEqual(try line(session("A", state: "waitingIdle")), Line("●", "waiting for you", working: false))
    }

    func testACardAtRestReadsItsStateAndWhereItRuns() throws {
        XCTAssertEqual(try line(session("A", state: "starting")), Line("◌", "starting", working: false))
        XCTAssertEqual(try line(session("A", state: "finished")), Line("✓", "done", working: false))
        XCTAssertEqual(try line(session("A", state: "ready"), in: "/repo/.worktrees/fix"), Line("○", "ready fix", working: false))
    }

    /// The view sets the worktree apart from what the session does, so it never truncates away.
    func testTheSummaryIsTheLineWithoutItsWorktree() throws {
        let projects = [
            KnownProject(path: "/repo", sessions: [session("ANCHOR")]),
            KnownProject(path: "/repo/.worktrees/fix", sessions: [
                session("A", state: "working", action: "Running the suite"),
                session("B", state: "working"),
                session("C", state: "waitingPermission"),
            ]),
        ]
        let cards = AgentsColumn.build(projects: projects, limits: [:], roots: ["/repo": .repo("/repo"), "/repo/.worktrees/fix": .repo("/repo")],
                                       selectedId: "ANCHOR").cards
        let summary = { (id: String) in cards.first { $0.id == id }.map { "\($0.summary) | \($0.worktree)" } }

        XCTAssertEqual(summary("A"), "Running the suite | fix")
        // The worktree alone, as the mod shows it: no "…" before it.
        XCTAssertEqual(summary("B"), " | fix")
        XCTAssertEqual(summary("C"), "needs permission | fix")
        XCTAssertEqual(summary("ANCHOR"), "ready | ")
    }

    /// What a card's agent records first-hand (its step) outranks what its screen shows (its action);
    /// what needs you still reads its screen.
    func testTheSecondLineReadsTheStepItsAgentRecordsAheadOfItsScreen() throws {
        XCTAssertEqual(try line(session("A", state: "working", action: "Working", step: "$ swift test")),
                       Line("●", "$ swift test", working: true))
        XCTAssertEqual(try line(session("A", state: "working", step: "$ swift test")), Line("●", "$ swift test", working: true))
        XCTAssertEqual(try line(session("A", state: "waitingPermission", action: "Edit Foo.swift", step: "$ swift test")),
                       Line("!", "Edit Foo.swift", working: false))
        XCTAssertEqual(try line(session("A", state: "waitingPermission", step: "$ swift test")), Line("!", "needs permission", working: false))
    }

    /// The first running subagent by name and step and the rest counted, at work or with the turn
    /// over; never over what needs you.
    func testACardNamesItsFirstRunningSubagentAndCountsTheRest() throws {
        let steps = [KnownProject.OpenSession.Subagent(name: "Survey", step: "⊙ Card.swift"), .init(name: "Plan", step: nil)]

        XCTAssertEqual(try line(session("A", state: "working", subagents: 2, step: "$ make", subagentSteps: steps)),
                       Line("●", "$ make · Survey: ⊙ Card.swift +1", working: true))
        XCTAssertEqual(try line(session("A", state: "finished", subagents: 2, subagentSteps: steps)),
                       Line("●", "Survey: ⊙ Card.swift +1", working: true))
        // The count can run ahead of the names the agent's files record.
        XCTAssertEqual(try line(session("A", state: "working", subagents: 3, subagentSteps: [.init(name: "Plan", step: nil)])),
                       Line("●", "Plan +2", working: true))
        XCTAssertEqual(try line(session("A", state: "waitingPermission", subagents: 2, subagentSteps: steps)),
                       Line("!", "needs permission", working: false))
    }

    /// A state this build does not know reads by the coarse activity.
    func testAStateNotKnownReadsByTheActivity() throws {
        XCTAssertEqual(try line(session("A", activity: .busy, state: "compacting", action: "Compacting")), Line("●", "Compacting", working: true))
        XCTAssertEqual(try line(session("A", activity: .idle, state: "compacting")), Line("○", "idle", working: false))
        XCTAssertEqual(try line(session("A", activity: .starting, state: nil)), Line("◌", "starting", working: false))
    }

    func testEachStateReadsInItsOwnTint() throws {
        let tint = { (state: String) throws -> AgentCardLook.Tint in try self.card(self.session("A", state: state)).look.tint }
        XCTAssertEqual(try tint("waitingPermission"), .attention)
        XCTAssertEqual(try tint("waitingIdle"), .attention)
        XCTAssertEqual(try tint("error"), .error)
        XCTAssertEqual(try tint("working"), .working)
        XCTAssertEqual(try tint("finished"), .done)
        XCTAssertEqual(try tint("ready"), .muted)
        XCTAssertEqual(try tint("starting"), .attention)
    }

    // MARK: - Context and plan limits

    /// How full the context is, beside the model: orange from 80%.
    func testACardShowsHowFullItsContextIsInOrangeFromEightyPercent() throws {
        XCTAssertEqual(try card(session("A", contextPercent: 41)).context, AgentMeterLabel(text: "41%", tint: .muted))
        XCTAssertEqual(try card(session("A", contextPercent: 79)).context, AgentMeterLabel(text: "79%", tint: .muted))
        XCTAssertEqual(try card(session("A", contextPercent: 80)).context, AgentMeterLabel(text: "80%", tint: .warn))
        XCTAssertEqual(try card(session("A", contextPercent: 100)).context, AgentMeterLabel(text: "100%", tint: .warn))
        XCTAssertNil(try card(session("A")).context)
    }

    /// The card's agent's tightest plan limit, once it reaches 70%: orange, red from 90%. A tie keeps
    /// the first the agent lists.
    func testACardShowsItsAgentsTightestPlanLimitOnceItReachesSeventyPercent() {
        let limits: [String: [KnownLimit]] = [
            "codex": [KnownLimit(label: "5h", percent: 72, resets: nil), KnownLimit(label: "7d", percent: 91, resets: "2030-01-01T00:00:00Z")],
            "claude": [KnownLimit(label: "5h", percent: 40, resets: nil)],
            "agy": [KnownLimit(label: "5h", percent: 70, resets: nil), KnownLimit(label: "7d", percent: 69, resets: nil)],
            "opencode": [KnownLimit(label: "5h", percent: 89, resets: nil), KnownLimit(label: "7d", percent: 89, resets: nil)],
            "kilo": [KnownLimit(label: "7d", percent: 90, resets: nil)],
        ]
        let sessions = ["codex", "claude", "agy", "opencode", "kilo", "cursor"].map { session($0, agent: $0) }
        let cards = column(sessions, limits: limits).cards
        let limit = { (id: String) in cards.first { $0.id == id }?.limit }

        XCTAssertEqual(limit("codex"), AgentMeterLabel(text: "7d 91%", tint: .critical))
        XCTAssertNil(limit("claude"))
        XCTAssertEqual(limit("agy"), AgentMeterLabel(text: "5h 70%", tint: .warn))
        XCTAssertEqual(limit("opencode"), AgentMeterLabel(text: "5h 89%", tint: .warn))
        XCTAssertEqual(limit("kilo"), AgentMeterLabel(text: "7d 90%", tint: .critical))
        XCTAssertNil(limit("cursor"), "an agent that reports no limits shows none")
    }

    // MARK: - Redraws

    /// The labels that tick (ages, cache clocks) redraw at the moment their text changes, not a minute late.
    func testTheColumnRedrawsWhenTheNextLabelChanges() throws {
        let column = column([
            session("A", since: now - 30, cacheExpiresAt: iso(now + 125)),
            session("B", since: now - 50),
        ])

        // A's clock drops to 1m in 5 s, before B's age turns "1m" at 10 s.
        let first = try XCTUnwrap(column.nextRedraw(after: now))
        XCTAssertEqual(first.timeIntervalSince(now), 5, accuracy: 0.01)
        let a = try XCTUnwrap(column.cards.first { $0.id == "A" })
        XCTAssertEqual(a.cache(at: now)?.text, "◷ 2m")
        XCTAssertEqual(a.cache(at: first)?.text, "◷ 1m")

        let second = try XCTUnwrap(column.nextRedraw(after: first))
        XCTAssertEqual(second.timeIntervalSince(now), 10, accuracy: 0.01)
        let b = try XCTUnwrap(column.cards.first { $0.id == "B" })
        XCTAssertEqual(b.age(at: second), "1m")
    }

    func testACacheGoesColdOnTime() throws {
        let column = column([session("A", cacheExpiresAt: iso(now + 20))])

        let next = try XCTUnwrap(column.nextRedraw(after: now))

        XCTAssertEqual(next.timeIntervalSince(now), 20, accuracy: 0.01)
        XCTAssertEqual(column.cards[0].cache(at: next)?.text, "◷ cold")
        XCTAssertNil(column.nextRedraw(after: next), "nothing on a cold card ticks any more")
    }

    // MARK: - Width

    /// SF Mono 12.5's "W" as SwiftTerm measures it, on a Retina screen, beside the 17pt scroller
    /// SwiftTerm keeps.
    private let sfMono = TerminalGrid(fontCellWidth: 7.72705078125, backingScale: 2, scrollerWidth: 17)

    /// SwiftTerm 1.15.0 rounds a cell's width up to the pixel grid and keeps the scroller's width
    /// out of the grid (AppleTerminalView.computeFontDimensions, MacTerminalView.getEffectiveWidth).
    func testTheTerminalHasAsManyColumnsAsSwiftTermLaysOut() {
        XCTAssertEqual(sfMono.cellWidth, 8)
        XCTAssertEqual(sfMono.columns(inViewWidth: 17 + 80 * 8), 80)
        XCTAssertEqual(sfMono.columns(inViewWidth: 17 + 80 * 8 - 0.5), 79)
        // The width 80 cells of the font's own advance take: SwiftTerm fits 75 in it.
        XCTAssertEqual(sfMono.columns(inViewWidth: 80 * 7.72705078125), 75)
        XCTAssertEqual(sfMono.columns(inViewWidth: 10), 0)
        // The pixel grid depends on the screen: 7.3pt is 7.5pt on a Retina screen and 8pt on any other.
        XCTAssertEqual(TerminalGrid(fontCellWidth: 7.3, backingScale: 2, scrollerWidth: 17).cellWidth, 7.5)
        XCTAssertEqual(TerminalGrid(fontCellWidth: 7.3, backingScale: 1, scrollerWidth: 17).cellWidth, 8)
    }

    /// The column gives way when it would leave the terminal under 80 columns.
    func testTheColumnHidesWhenItWouldLeaveTheTerminalUnderEightyColumns() {
        let room = AgentsColumnLayout.width + AgentsColumnLayout.gap + 17 + 80 * 8

        XCTAssertEqual(room, 901)
        XCTAssertTrue(AgentsColumnLayout.fits(paneWidth: room, grid: sfMono))
        XCTAssertFalse(AgentsColumnLayout.fits(paneWidth: room - 0.5, grid: sfMono))
        // Where 80 cells of the font's own advance would have let the column in, it leaves 75 columns.
        XCTAssertFalse(AgentsColumnLayout.fits(paneWidth: 80 * 7.72705078125 + AgentsColumnLayout.width + AgentsColumnLayout.gap,
                                               grid: sfMono))
        XCTAssertFalse(AgentsColumnLayout.fits(paneWidth: 0, grid: sfMono))
        XCTAssertFalse(AgentsColumnLayout.fits(paneWidth: 2_000, grid: TerminalGrid(fontCellWidth: 0, backingScale: 2, scrollerWidth: 17)),
                       "no cell width yet: no room to judge")
        XCTAssertFalse(AgentsColumnLayout.fits(paneWidth: 2_000, grid: TerminalGrid(fontCellWidth: 7.7, backingScale: 0, scrollerWidth: 17)),
                       "no screen yet: no pixel grid to judge by")
    }

    /// Where the column fits it shows beside the terminal, or not, as its toggle says. Where it does
    /// not, the toggle opens the same cards in a popover, whichever way the column is set.
    func testWhereTheColumnDoesNotFitItsToggleOpensAPopover() {
        let place = { (width: CGFloat, isOn: Bool) in AgentsColumnLayout.placement(paneWidth: width, grid: self.sfMono, isOn: isOn) }

        XCTAssertEqual(place(901, true), .beside)
        XCTAssertEqual(place(901, false), .hidden)
        XCTAssertEqual(place(900, true), .popover)
        XCTAssertEqual(place(900, false), .popover)
        // The panel opens 760pt wide, leaving its terminal pane about 476pt; a torn-off terminal opens
        // 720pt wide, its pane 696pt.
        XCTAssertEqual(place(476, true), .popover)
        XCTAssertEqual(place(696, true), .popover)
    }

    // MARK: - Opening a card

    /// In the panel a card selects its session. In a torn-off window, the window's own card leaves the
    /// panel's selection alone, and a card whose terminal is in the panel also brings the panel up:
    /// selecting it there alone shows nothing while the panel is hidden.
    func testOpeningACardSelectsItsSessionAndShowsWhereItsTerminalIs() {
        XCTAssertEqual(AgentCardClick.of(card: "A", besideSession: "A", inWindow: false, cardInWindow: false), .focus)
        XCTAssertEqual(AgentCardClick.of(card: "B", besideSession: "A", inWindow: false, cardInWindow: false), .focus)
        XCTAssertEqual(AgentCardClick.of(card: "B", besideSession: "A", inWindow: false, cardInWindow: true), .focus)
        XCTAssertEqual(AgentCardClick.of(card: "A", besideSession: "A", inWindow: true, cardInWindow: true), .acknowledge)
        XCTAssertEqual(AgentCardClick.of(card: "B", besideSession: "A", inWindow: true, cardInWindow: false), .focusShowingPanel)
        XCTAssertEqual(AgentCardClick.of(card: "B", besideSession: "A", inWindow: true, cardInWindow: true), .focus)
    }
}
