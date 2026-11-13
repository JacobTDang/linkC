import XCTest
@testable import LinkCKit

final class TierModelChoicesTests: XCTestCase {
    func testOptionsAreAvailablePlusOther() {
        let lists: [AgentKind: AgentModelList] = [
            .agy: AgentModelList(
                models: [
                    ListedModel(id: "gemini-3.8-flash-medium", name: "Flash"),
                    ListedModel(id: "claude-opus-4-6-thinking", name: "Opus"),
                ],
                fetchedAt: Date(),
                error: nil),
        ]
        let choices = TierModelChoices.make(
            agent: .agy, lists: lists, settings: .seeded, current: "gemini-3.8-flash-medium")
        XCTAssertEqual(choices.optionLabels.last, TierModelChoices.otherLabel)
        XCTAssertTrue(choices.optionLabels.contains("gemini-3.8-flash-medium"))
        XCTAssertTrue(choices.optionLabels.contains("claude-opus-4-6-thinking"))
        XCTAssertEqual(choices.selectedOption, "gemini-3.8-flash-medium")
        XCTAssertFalse(choices.showsOtherField)
    }

    func testOpenCodeOptionsAreFreeOnly() {
        let lists: [AgentKind: AgentModelList] = [
            .opencode: AgentModelList(
                models: [
                    ListedModel(id: "opencode/big-pickle", name: "opencode/big-pickle"),
                    ListedModel(id: "opencode/claude-sonnet-5", name: "opencode/claude-sonnet-5"),
                    ListedModel(id: "ollama/qwen3.8:27b-32k", name: "ollama/qwen3.8:27b-32k"),
                ],
                fetchedAt: Date(),
                error: nil),
        ]
        var settings = AgentModelSettings.seeded
        settings.setModel("opencode/claude-sonnet-5", for: .opencode, tier: .deep)
        let choices = TierModelChoices.make(
            agent: .opencode, lists: lists, settings: settings, current: "opencode/big-pickle")
        XCTAssertTrue(choices.optionLabels.contains("opencode/big-pickle"))
        XCTAssertTrue(choices.optionLabels.contains("ollama/qwen3.8:27b-32k"))
        XCTAssertFalse(choices.optionLabels.contains("opencode/claude-sonnet-5"))
    }

    func testCurrentOutsideListSelectsOther() {
        let choices = TierModelChoices.make(
            agent: .claude, lists: [:], settings: .seeded, current: "hand-typed")
        XCTAssertEqual(choices.selectedOption, TierModelChoices.otherLabel)
        XCTAssertTrue(choices.showsOtherField)
        XCTAssertEqual(choices.typedId, "hand-typed")
        XCTAssertNil(choices.validationError)
    }

    func testTypedNonFreeOpenCodeIdIsRefused() {
        let error = TierModelChoices.validationError(
            forTypedId: "opencode/claude-sonnet-5", agent: .opencode)
        XCTAssertEqual(error, "opencode/claude-sonnet-5 is not a free OpenCode model")

        let choices = TierModelChoices.make(
            agent: .opencode, lists: [:], settings: .seeded, current: "opencode/claude-sonnet-5")
        XCTAssertEqual(choices.validationError, "opencode/claude-sonnet-5 is not a free OpenCode model")
    }

    func testTypedFreeOpenCodeIdIsAccepted() {
        XCTAssertNil(TierModelChoices.validationError(
            forTypedId: "opencode/beam-free", agent: .opencode))
        XCTAssertNil(TierModelChoices.validationError(
            forTypedId: "hand-typed", agent: .claude))
    }

    func testKiloOptionsAreFreeOnly() {
        let lists: [AgentKind: AgentModelList] = [
            .kilo: AgentModelList(
                models: [
                    ListedModel(id: "kilo/kilo-auto/free", name: "kilo/kilo-auto/free"),
                    ListedModel(id: "kilo/anthropic/claude-sonnet-5", name: "kilo/anthropic/claude-sonnet-5"),
                    ListedModel(id: "kilo/reflection/beam-free", name: "kilo/reflection/beam-free"),
                ],
                fetchedAt: Date(),
                error: nil),
        ]
        var settings = AgentModelSettings.seeded
        settings.setModel("kilo/anthropic/claude-sonnet-5", for: .kilo, tier: .deep)
        let choices = TierModelChoices.make(
            agent: .kilo, lists: lists, settings: settings, current: "kilo/kilo-auto/free")
        XCTAssertTrue(choices.optionLabels.contains("kilo/kilo-auto/free"))
        XCTAssertTrue(choices.optionLabels.contains("kilo/reflection/beam-free"))
        XCTAssertFalse(choices.optionLabels.contains("kilo/anthropic/claude-sonnet-5"))
    }

    func testTypedNonFreeKiloIdIsRefused() {
        let error = TierModelChoices.validationError(
            forTypedId: "kilo/anthropic/claude-sonnet-5", agent: .kilo)
        XCTAssertEqual(error, "kilo/anthropic/claude-sonnet-5 is not a free Kilo model")
        XCTAssertNil(TierModelChoices.validationError(forTypedId: "kilo/kilo-auto/free", agent: .kilo))
    }

    func testShowsListAgeAndError() {
        let fetched = Date(timeIntervalSince1970: 1_700_000_000)
        let lists: [AgentKind: AgentModelList] = [
            .agy: AgentModelList(
                models: [ListedModel(id: "gemini-3.8-flash-medium", name: "Flash")],
                fetchedAt: fetched,
                error: "agy offline"),
        ]
        let choices = TierModelChoices.make(
            agent: .agy, lists: lists, settings: .seeded, current: "gemini-3.8-flash-medium",
            now: fetched.addingTimeInterval(120))
        XCTAssertEqual(choices.listAgeText, "2m ago")
        XCTAssertEqual(choices.listError, "agy offline")
    }

    func testNoListYetHasNoAge() {
        let choices = TierModelChoices.make(
            agent: .agy, lists: [:], settings: .seeded, current: "gemini-3.8-flash-medium")
        XCTAssertNil(choices.listAgeText)
        XCTAssertNil(choices.listError)
    }

    // MARK: - A typed id the agent does not list

    private func liveList(_ ids: [String], fetchedAt: Date, error: String? = nil) -> AgentModelList {
        AgentModelList(models: ids.map { ListedModel(id: $0, name: $0) }, fetchedAt: fetchedAt, error: error)
    }

    func testTypedIdNotInALiveListWarnsAndStillSaves() {
        let fetched = Date(timeIntervalSince1970: 1_700_000_000)
        let lists: [AgentKind: AgentModelList] = [.agy: liveList(["gemini-3.8-flash-medium"], fetchedAt: fetched)]
        let now = fetched.addingTimeInterval(120)

        let warning = TierModelChoices.warning(forTypedId: "gemini-9", agent: .agy, lists: lists, now: now)

        XCTAssertEqual(warning, "gemini-9 is not in agy's list (read 2m ago). Delegation refuses it until agy lists it.")
        XCTAssertNil(TierModelChoices.validationError(forTypedId: "gemini-9", agent: .agy), "a warning never blocks saving")
        let choices = TierModelChoices.make(agent: .agy, lists: lists, settings: .seeded, current: "gemini-9", now: now)
        XCTAssertEqual(choices.warning, warning)
        XCTAssertNil(choices.validationError)
    }

    func testTypedIdInTheLiveListDoesNotWarnInAnyCase() {
        let lists: [AgentKind: AgentModelList] = [.cursor: liveList(["composer-2"], fetchedAt: Date())]
        XCTAssertNil(TierModelChoices.warning(forTypedId: "composer-2", agent: .cursor, lists: lists))
        XCTAssertNil(TierModelChoices.warning(forTypedId: "Composer-2 ", agent: .cursor, lists: lists))
    }

    /// Only a list that was read cleanly says what the CLI offers: a failed refresh, an empty list and
    /// a list never read say nothing, and neither does an agent with no listing command.
    func testNoWarningWithoutAListThatWasReadCleanly() {
        let fetched = Date()
        XCTAssertNil(TierModelChoices.warning(
            forTypedId: "x", agent: .grok, lists: [.grok: liveList(["a"], fetchedAt: fetched, error: "grok offline")]))
        XCTAssertNil(TierModelChoices.warning(
            forTypedId: "x", agent: .grok, lists: [.grok: liveList([], fetchedAt: fetched)]))
        XCTAssertNil(TierModelChoices.warning(forTypedId: "x", agent: .grok, lists: [:]))
        XCTAssertNil(TierModelChoices.warning(forTypedId: "x", agent: .claude, lists: [:]))
        XCTAssertNil(TierModelChoices.warning(forTypedId: "", agent: .grok, lists: [.grok: liveList(["a"], fetchedAt: fetched)]))
    }

    /// A non-free OpenCode id stays refused, with its own text and no warning on top; a free one the
    /// list lacks is only warned about.
    func testOpenCodeNonFreeStaysRefusedAndAFreeUnlistedIdWarns() {
        let fetched = Date(timeIntervalSince1970: 1_700_000_000)
        let lists: [AgentKind: AgentModelList] = [.opencode: liveList(["opencode/big-pickle"], fetchedAt: fetched)]
        let now = fetched.addingTimeInterval(30)

        let paid = TierModelChoices.make(
            agent: .opencode, lists: lists, settings: .seeded, current: "opencode/claude-sonnet-5", now: now)
        XCTAssertEqual(paid.validationError, "opencode/claude-sonnet-5 is not a free OpenCode model")
        XCTAssertNil(paid.warning)

        let free = TierModelChoices.make(
            agent: .opencode, lists: lists, settings: .seeded, current: "opencode/gone-free", now: now)
        XCTAssertNil(free.validationError)
        XCTAssertEqual(free.warning,
                       "opencode/gone-free is not in opencode's list (read 30s ago). Delegation refuses it until opencode lists it.")
    }

    func testKiloNonFreeStaysRefusedAndAFreeUnlistedIdWarns() {
        let fetched = Date(timeIntervalSince1970: 1_700_000_000)
        let lists: [AgentKind: AgentModelList] = [.kilo: liveList(["kilo/kilo-auto/free"], fetchedAt: fetched)]
        let now = fetched.addingTimeInterval(30)

        let paid = TierModelChoices.make(
            agent: .kilo, lists: lists, settings: .seeded, current: "kilo/anthropic/claude-sonnet-5", now: now)
        XCTAssertEqual(paid.validationError, "kilo/anthropic/claude-sonnet-5 is not a free Kilo model")
        XCTAssertNil(paid.warning)

        let free = TierModelChoices.make(
            agent: .kilo, lists: lists, settings: .seeded, current: "kilo/gone/free", now: now)
        XCTAssertNil(free.validationError)
        XCTAssertEqual(free.warning,
                       "kilo/gone/free is not in kilo's list (read 30s ago). Delegation refuses it until kilo lists it.")
    }
}
