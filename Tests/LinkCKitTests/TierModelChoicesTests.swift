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
}
