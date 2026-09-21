import XCTest
@testable import LinkCKit

final class RelaunchPlanTests: XCTestCase {
    private func makeEntry(
        _ id: String, _ agent: AgentKind = .claude, conversation: String? = nil, cwd: String = "/p/linkC",
        worker: Bool = false
    ) -> RestorableSession {
        RestorableSession(
            linkcId: id, claudeSessionId: conversation, cwd: cwd, title: "t", agentKind: agent,
            wasActiveOnQuit: true, endedAt: nil, isWorker: worker)
    }

    private func plan(_ entries: [RestorableSession], holding: Set<String> = []) -> RelaunchPlan {
        RelaunchPlan.make(entries: entries, workersHoldingTasks: holding)
    }

    func testAClaudeSessionWithAnIdComesBack() {
        let result = plan([makeEntry("A", conversation: "c1")])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["A"], toEarlier: [], drop: []))
    }

    func testTwoEntriesOnOneConversationBringBackOnlyTheLast() {
        let result = plan([makeEntry("A", conversation: "c1"), makeEntry("B", conversation: "c1")])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["B"], toEarlier: ["A"], drop: []))
    }

    func testOneContinuePerFolderAndAgentTheNewestWinning() {
        let result = plan([makeEntry("A", .agy), makeEntry("B", .agy), makeEntry("C", .agy, cwd: "/p/other")])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["B", "C"], toEarlier: ["A"], drop: []))
    }

    func testDifferentAgentsInOneFolderEachContinue() {
        let result = plan([makeEntry("A", .agy), makeEntry("B", .cursor), makeEntry("C", .codex)])
        XCTAssertEqual(result.relaunch, ["A", "B", "C"])
        XCTAssertEqual(result.toEarlier, [])
    }

    func testAnIdlessClaudeEntryYieldsToOneResumingByIdInTheSameFolder() {
        let result = plan([makeEntry("A", conversation: "c1"), makeEntry("B")])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["A"], toEarlier: ["B"], drop: []))
    }

    func testAnIdlessClaudeEntryContinuesWhenNoneResumesInItsFolder() {
        let result = plan([makeEntry("A", conversation: "c1", cwd: "/p/one"), makeEntry("B", cwd: "/p/two")])
        XCTAssertEqual(result.relaunch, ["A", "B"])
    }

    func testAWorkerComesBackOnlyWhileItHoldsATask() {
        let result = plan(
            [makeEntry("W1", .codex, worker: true), makeEntry("W2", .codex, cwd: "/p/other", worker: true)],
            holding: ["W1"])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["W1"], toEarlier: [], drop: ["W2"]))
    }

    func testAWorkerThatLosesAContestIsDroppedNotFiledUnderEarlier() {
        // The worker holds a task, but the user's own id-less session of the same agent in the
        // same folder was launched after it and wins the one continue.
        let result = plan([makeEntry("W", .codex, worker: true), makeEntry("U", .codex)], holding: ["W"])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["U"], toEarlier: [], drop: ["W"]))
    }

    func testFoldersCompareStandardized() {
        let result = plan([makeEntry("A", .agy, cwd: "/p/linkC/"), makeEntry("B", .agy, cwd: "/p/./linkC")])
        XCTAssertEqual(result, RelaunchPlan(relaunch: ["B"], toEarlier: ["A"], drop: []))
    }

    func testDroppedWorkersKeepManifestOrderWhateverTheReason() {
        let result = plan(
            [makeEntry("C", .codex, worker: true),
             makeEntry("N", .codex, cwd: "/p/other", worker: true),
             makeEntry("U", .codex)],
            holding: ["C"])
        XCTAssertEqual(result.drop, ["C", "N"])
    }

    func testAnOldManifestEntryReadsAsTheUsers() throws {
        let json = #"{"linkcId":"A","cwd":"/p","title":"t","agentKind":"claude","wasActiveOnQuit":true}"#
        let decoded = try JSONDecoder().decode(RestorableSession.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.isWorker)
    }

    func testIsWorkerSurvivesARoundTrip() throws {
        let original = makeEntry("W", .codex, worker: true)
        let decoded = try JSONDecoder().decode(RestorableSession.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(decoded.isWorker)
    }
}
