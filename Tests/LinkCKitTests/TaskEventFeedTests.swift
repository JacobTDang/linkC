import XCTest
@testable import LinkCKit

/// Task changes between two relay passes, whichever process made them (spec §2.1).
final class TaskEventFeedTests: XCTestCase {
    private let folder = "/p/alpha"
    private let at = Date(timeIntervalSince1970: 7)

    private func task(_ id: String, _ state: TaskState, prompt: String = "fix the flaky test\nand more",
                      report: TaskReport? = nil, cancelReason: String? = nil) -> TaskRecord {
        TaskRecord(id: id + "-0000-0000", fromAgent: .claude, toAgent: .codex, prompt: prompt, state: state,
                   report: report, cancelReason: cancelReason)
    }

    func testTheFirstPassOnlyRecords() {
        var feed = TaskEventFeed()
        XCTAssertTrue(feed.events(in: folder, tasks: [task("AAAA1111", .done)], at: at).isEmpty)
    }

    func testEachReportedStateRaisesOneEventAndTheOthersNone() {
        var feed = TaskEventFeed()
        _ = feed.events(in: folder, tasks: [task("AAAA1111", .gating)], at: at)
        var events: [LinkCEvent] = []
        for state in [TaskState.queued, .delivered, .started, .reported, .done] {
            events += feed.events(in: folder, tasks: [task("AAAA1111", state)], at: at)
        }
        XCTAssertEqual(events.map(\.title), ["Task delivered · Claude → Codex", "Task done · Claude → Codex"])
        XCTAssertEqual(events.map(\.tone), [.info, .done])
        XCTAssertEqual(events.map(\.kind), [.task, .task])
        XCTAssertEqual(events.first?.project, folder)
    }

    func testFailedExpiredAndCancelledAreReported() {
        var feed = TaskEventFeed()
        _ = feed.events(in: folder, tasks: [], at: at)
        let events = feed.events(in: folder, tasks: [
            task("AAAA1111", .failed, report: TaskReport(status: "failed", summary: "tests still red")),
            task("BBBB2222", .expired, cancelReason: "its lease lapsed"),
            task("CCCC3333", .cancelled, cancelReason: "not needed"),
        ], at: at)
        XCTAssertEqual(events.map(\.tone), [.failed, .failed, .info])
        XCTAssertEqual(events.map(\.body), [
            "`AAAA1111` fix the flaky test\ntests still red",
            "`BBBB2222` fix the flaky test\nits lease lapsed",
            "`CCCC3333` fix the flaky test\nnot needed",
        ])
    }

    func testANewTaskAlreadyDoneRaisesDone() {
        var feed = TaskEventFeed()
        _ = feed.events(in: folder, tasks: [], at: at)
        let events = feed.events(in: folder, tasks: [
            task("AAAA1111", .done, report: TaskReport(status: "done", summary: "fixed"))], at: at)
        XCTAssertEqual(events.map(\.body), ["`AAAA1111` fix the flaky test\nfixed"])
    }

    func testAnUnchangedTaskRaisesNothingAgain() {
        var feed = TaskEventFeed()
        _ = feed.events(in: folder, tasks: [], at: at)
        XCTAssertEqual(feed.events(in: folder, tasks: [task("AAAA1111", .done)], at: at).count, 1)
        XCTAssertTrue(feed.events(in: folder, tasks: [task("AAAA1111", .done)], at: at).isEmpty)
    }

    /// A pass whose read failed doesn't call the feed: the next pass compares with the last good one.
    func testAPassThatCouldNotReadLosesAndRepeatsNothing() {
        var feed = TaskEventFeed()
        _ = feed.events(in: folder, tasks: [task("AAAA1111", .queued)], at: at)
        // (a pass here could not read the inbox)
        XCTAssertEqual(feed.events(in: folder, tasks: [task("AAAA1111", .done)], at: at).count, 1)
        XCTAssertTrue(feed.events(in: folder, tasks: [task("AAAA1111", .done)], at: at).isEmpty)
    }

    func testAFolderNoLongerServedStartsOverSilently() {
        var feed = TaskEventFeed()
        _ = feed.events(in: folder, tasks: [], at: at)
        feed.retain(only: [])
        XCTAssertTrue(feed.events(in: folder, tasks: [task("AAAA1111", .done)], at: at).isEmpty)
    }

    func testALongPromptsFirstLineIsCut() {
        var feed = TaskEventFeed()
        _ = feed.events(in: folder, tasks: [], at: at)
        let events = feed.events(in: folder, tasks: [task("AAAA1111", .delivered, prompt: String(repeating: "p", count: 300))], at: at)
        XCTAssertEqual(events.first?.body, "`AAAA1111` " + String(repeating: "p", count: 119) + "…")
    }
}
