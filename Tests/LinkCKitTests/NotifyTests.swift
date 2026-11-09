import XCTest
@testable import LinkCKit

// MARK: - Test double

/// Test-only `NotificationSink`. Records every delivered (id, title, body) tuple so
/// tests can assert on delivery without ever touching `UNUserNotificationCenter` —
/// that real center needs an app bundle and isn't reachable from `swift test`.
/// Only ever driven synchronously from a single `@MainActor` test method at a time,
/// so `@unchecked Sendable` is safe here (mirrors the real `NotificationSink`
/// requirement without needing actor isolation for a plain recording spy).
final class RecordingSink: NotificationSink, @unchecked Sendable {
    struct Delivery: Equatable {
        let id: String
        let title: String
        let body: String
    }

    private(set) var deliveries: [Delivery] = []

    func deliver(id: String, title: String, body: String) {
        deliveries.append(Delivery(id: id, title: title, body: body))
    }
}

// MARK: - FocusPolicy

final class FocusPolicyTests: XCTestCase {
    private func session(id: String = "L1", state: SessionState = .finished) -> Session {
        Session(id: id, cwd: "/tmp", title: "api", state: state)
    }

    func testNotNotifiableNeverNotifies() {
        XCTAssertFalse(FocusPolicy.shouldNotify(
            session: session(),
            enteredNotifiable: false,
            isWatchingThisSession: false
        ))
    }

    func testNotifiableAndNotWatchingNotifies() {
        XCTAssertTrue(FocusPolicy.shouldNotify(
            session: session(),
            enteredNotifiable: true,
            isWatchingThisSession: false
        ))
    }

    func testNotifiableButWatchingThisSessionSuppresses() {
        XCTAssertFalse(FocusPolicy.shouldNotify(
            session: session(),
            enteredNotifiable: true,
            isWatchingThisSession: true
        ))
    }

    func testEnteredNotifiableGatesFirstEvenWhenWatching() {
        // enteredNotifiable == false wins regardless of the watch state.
        XCTAssertFalse(FocusPolicy.shouldNotify(
            session: session(),
            enteredNotifiable: false,
            isWatchingThisSession: true
        ))
    }
}

// MARK: - NotificationManager.message(for:)

final class NotificationMessageTests: XCTestCase {
    private func session(state: SessionState) -> Session {
        Session(id: "L1", cwd: "/tmp", title: "api", state: state)
    }

    func testFinishedMessage() {
        XCTAssertEqual(NotificationManager.message(for: session(state: .finished)), "api · finished")
    }

    func testWaitingPermissionMessage() {
        XCTAssertEqual(NotificationManager.message(for: session(state: .waitingPermission)), "api · needs permission")
    }

    func testWaitingIdleMessage() {
        XCTAssertEqual(NotificationManager.message(for: session(state: .waitingIdle)), "api · waiting for input")
    }

    func testErrorMessage() {
        XCTAssertEqual(NotificationManager.message(for: session(state: .error)), "api · ended with an error")
    }

    func testNonNotifiableStatesHaveNoMessage() {
        XCTAssertNil(NotificationManager.message(for: session(state: .working)))
        XCTAssertNil(NotificationManager.message(for: session(state: .ready)))
        XCTAssertNil(NotificationManager.message(for: session(state: .starting)))
        XCTAssertNil(NotificationManager.message(for: session(state: .ended)))
    }
}

// MARK: - NotificationManager.post

@MainActor
final class NotificationManagerPostTests: XCTestCase {
    private func session(id: String = "L1", state: SessionState = .finished) -> Session {
        Session(id: id, cwd: "/tmp", title: "api", state: state)
    }

    func testFinishedSessionDeliversOnce() {
        let sink = RecordingSink()
        let manager = NotificationManager(sink: sink, now: { Date(timeIntervalSince1970: 0) })
        manager.post(session: session())
        XCTAssertEqual(sink.deliveries, [.init(id: "L1", title: "linkC", body: "api · finished")])
    }

    func testImmediateRepeatIsDeduped() {
        let now = Date(timeIntervalSince1970: 0)
        let sink = RecordingSink()
        let manager = NotificationManager(sink: sink, now: { now }, coalesceInterval: 2.0)
        manager.post(session: session())
        manager.post(session: session())
        XCTAssertEqual(sink.deliveries.count, 1, "an identical (session id, state) posted again within the coalesce window must be suppressed")
    }

    func testRepeatAfterCoalesceIntervalElapsesDeliversAgain() {
        var now = Date(timeIntervalSince1970: 0)
        let sink = RecordingSink()
        let manager = NotificationManager(sink: sink, now: { now }, coalesceInterval: 2.0)
        manager.post(session: session())
        now = now.addingTimeInterval(2.0)
        manager.post(session: session())
        XCTAssertEqual(sink.deliveries.count, 2, "once the coalesce interval has fully elapsed, the same (session, state) should deliver again")
    }

    func testWorkingSessionDeliversNothing() {
        let sink = RecordingSink()
        let manager = NotificationManager(sink: sink, now: { Date(timeIntervalSince1970: 0) })
        manager.post(session: session(state: .working))
        XCTAssertTrue(sink.deliveries.isEmpty)
    }

    func testDifferentSessionIdsAreNotCoalescedTogether() {
        let sink = RecordingSink()
        let manager = NotificationManager(sink: sink, now: { Date(timeIntervalSince1970: 0) })
        manager.post(session: session(id: "L1"))
        manager.post(session: session(id: "L2"))
        XCTAssertEqual(sink.deliveries.count, 2, "dedupe keys on session id — a different session must not be suppressed")
    }

    func testDifferentStateForSameSessionIsNotDeduped() {
        let sink = RecordingSink()
        let manager = NotificationManager(sink: sink, now: { Date(timeIntervalSince1970: 0) })
        manager.post(session: session(id: "L1", state: .finished))
        manager.post(session: session(id: "L1", state: .error))
        XCTAssertEqual(sink.deliveries.count, 2, "dedupe keys on (session id, state) — a genuinely new state must not be suppressed")
    }

    func testRequestAuthorizationWithRecordingSinkIsSafeNoOp() async {
        // With a RecordingSink (not a UNNotificationSink), requestAuthorization must never
        // reach UNUserNotificationCenter — there's no app bundle under `swift test`.
        let sink = RecordingSink()
        let manager = NotificationManager(sink: sink, now: { Date(timeIntervalSince1970: 0) })
        await manager.requestAuthorization()
    }

    func testPostGenericAlertDeliversImmediately() {
        let sink = RecordingSink()
        let manager = NotificationManager(sink: sink, now: { Date(timeIntervalSince1970: 0) })
        manager.post(title: "linkC: Swarm Rate Limited", body: "All candidates are rate limited.", project: nil)
        XCTAssertEqual(sink.deliveries.count, 1)
        XCTAssertEqual(sink.deliveries.first?.title, "linkC: Swarm Rate Limited")
        XCTAssertEqual(sink.deliveries.first?.body, "All candidates are rate limited.")
        XCTAssertTrue(sink.deliveries.first?.id.hasPrefix("alert:") ?? false)
    }
}

// MARK: - NotificationManager events

/// Every alert is also an event for Discord; Discord-only events and linkC's own notices are not
/// macOS notifications and events respectively (spec 2026-11-05 §2).
@MainActor
final class NotificationManagerEventTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 5)

    private func make(_ sink: RecordingSink = RecordingSink()) -> (NotificationManager, Box) {
        let manager = NotificationManager(sink: sink, now: { Date(timeIntervalSince1970: 5) })
        let box = Box()
        manager.onEvent = { box.events.append($0) }
        return (manager, box)
    }

    private final class Box {
        var events: [LinkCEvent] = []
    }

    func testAnAlertIsAlsoAnEventWithItsProject() {
        let (manager, box) = make()
        manager.post(title: "linkC: Codex Rate Limited", body: "limit", project: "/p/alpha")
        XCTAssertEqual(box.events, [LinkCEvent(kind: .alert, tone: .needsYou, title: "Codex Rate Limited", body: "limit",
                                               project: ProjectPath.canonical("/p/alpha"), at: at)])
    }

    func testASessionAlertIsAlsoAnEventAndACoalescedRepeatIsNot() {
        let (manager, box) = make()
        let session = Session(id: "L1", cwd: "/tmp", title: "api", state: .finished)
        manager.post(session: session)
        manager.post(session: session)
        XCTAssertEqual(box.events, [LinkCEvent(kind: .sessionState, tone: .done, title: "Claude · api · finished", body: "",
                                               project: ProjectPath.canonical("/tmp"), at: at)])
    }

    func testEachSessionStateHasItsTone() {
        let (manager, box) = make()
        for (id, state) in [("A", SessionState.waitingPermission), ("B", .waitingIdle), ("C", .error)] {
            manager.post(session: Session(id: id, cwd: "/tmp", title: "api", state: state))
        }
        XCTAssertEqual(box.events.map(\.tone), [.needsYou, .needsYou, .failed])
    }

    func testAServiceAlertIsAnEventWithNoProject() {
        let (manager, box) = make()
        manager.postAlert(id: "alert:x", title: "api", body: "api is not responding", tone: .failed)
        XCTAssertEqual(box.events, [LinkCEvent(kind: .service, tone: .failed, title: "api", body: "api is not responding",
                                               project: nil, at: at)])
    }

    func testADiscordOnlyEventIsNoMacNotification() {
        let sink = RecordingSink()
        let (manager, box) = make(sink)
        let event = LinkCEvent(kind: .task, tone: .done, title: "Task done", body: "", project: "/p", at: at)
        manager.postEvent(event)
        XCTAssertEqual(box.events, [event])
        XCTAssertTrue(sink.deliveries.isEmpty)
    }

    func testALocalNotificationIsNeverAnEvent() {
        let sink = RecordingSink()
        let (manager, box) = make(sink)
        manager.postLocal(title: "linkC stopped posting to Discord", body: "…")
        XCTAssertEqual(sink.deliveries.count, 1)
        XCTAssertTrue(box.events.isEmpty)
    }
}
