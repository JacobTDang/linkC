import os
import XCTest
@testable import LinkCKit

@MainActor
final class SidebarSignalTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ id: String, _ state: SessionState, agent: AgentKind = .claude) -> Session {
        Session(id: id, cwd: "/p", title: "p", state: state, stateChangedAt: t0, agentKind: agent)
    }

    /// A signal built the way the app builds it, with the inputs the test controls. `limit` is a
    /// cooldown's end: a session that errored while it runs is rate limited, judged at `now`.
    private func signal(
        _ sessions: [Session], now: Date, held: [String: String] = [:], limit: Date? = nil,
        actions: [String: String] = [:]
    ) -> SidebarSignal {
        SidebarSignal(
            sessions: sessions,
            heldTitle: { held[$0.id] },
            isRateLimited: { _ in limit.map { $0 > now } ?? false },
            action: { actions[$0.id] })
    }

    private var quietSessions: [Session] {
        [session("idle", .ready), session("done", .finished), session("codex", .working, agent: .codex),
         session("boom", .error)]
    }

    func testAQuietSecondLeavesTheSignalEqual() {
        let actions = ["codex": "$ swift test"]
        let now = t0.addingTimeInterval(300)
        let limit = now.addingTimeInterval(600)
        XCTAssertEqual(
            signal(quietSessions, now: now, held: ["idle": "Task ab12: fix"], limit: limit, actions: actions),
            signal(quietSessions, now: now.addingTimeInterval(1), held: ["idle": "Task ab12: fix"], limit: limit, actions: actions))
    }

    func testARateLimitThatLapsesChangesTheSignal() {
        let limit = t0.addingTimeInterval(30)
        let limited = signal(quietSessions, now: t0.addingTimeInterval(29), limit: limit)
        let lapsed = signal(quietSessions, now: t0.addingTimeInterval(31), limit: limit)
        XCTAssertEqual(limited.rateLimited, ["boom"])
        XCTAssertEqual(lapsed.rateLimited, [])
        XCTAssertNotEqual(limited, lapsed)
    }

    func testAHeldTaskTitleAppearingOrChangingChangesTheSignal() {
        let none = signal(quietSessions, now: t0)
        let held = signal(quietSessions, now: t0, held: ["idle": "Task ab12: fix"])
        let retitled = signal(quietSessions, now: t0, held: ["idle": "Task cd34: ship"])
        XCTAssertNotEqual(none, held)
        XCTAssertNotEqual(held, retitled)
        XCTAssertEqual(held.heldTitles, ["idle": "Task ab12: fix"])
    }

    func testAnActionLineAppearingChangesTheSignalButItsWordingDoesNot() {
        let none = signal(quietSessions, now: t0)
        let running = signal(quietSessions, now: t0, actions: ["codex": "$ swift build"])
        let later = signal(quietSessions, now: t0, actions: ["codex": "$ swift test"])
        XCTAssertNotEqual(none, running, "a line to show where there was none re-renders the row")
        XCTAssertEqual(running, later, "the row's own timeline reads the wording live")
        XCTAssertEqual(running.showingAction, ["codex"])
    }

    func testABlankActionLineShowsNothing() {
        XCTAssertEqual(
            signal(quietSessions, now: t0, actions: ["codex": "  \n"]), signal(quietSessions, now: t0))
    }

    func testAnActionLineIsOnlyReadForASessionThatShowsOne() {
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let sessions = [session("idle", .ready), session("work", .working), session("perm", .waitingPermission),
                        session("end", .ended)]
        _ = SidebarSignal(
            sessions: sessions, heldTitle: { _ in nil }, isRateLimited: { _ in false },
            action: { session in
                asked.withLock { $0.append(session.id) }
                return "line"
            })
        XCTAssertEqual(asked.withLock { $0 }, ["work", "perm"])
    }

    func testRateLimitIsOnlyAskedOfAnErroredSession() {
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        _ = SidebarSignal(
            sessions: quietSessions, heldTitle: { _ in nil },
            isRateLimited: { session in
                asked.withLock { $0.append(session.id) }
                return true
            },
            action: { _ in nil })
        XCTAssertEqual(asked.withLock { $0 }, ["boom"])
    }

    // MARK: - The feed

    /// A view that reads the feed is invalidated through observation. Whatever the toolchain's
    /// Observation library does with an equal value, a once-a-second sample of unchanged inputs
    /// must not invalidate the sidebar.
    func testAQuietSecondDoesNotNotifyObservers() {
        let feed = SidebarSignalFeed()
        feed.publish(signal(quietSessions, now: t0, held: ["idle": "Task ab12: fix"]))

        let fired = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = feed.signal
        } onChange: {
            fired.withLock { $0 += 1 }
        }
        feed.publish(signal(quietSessions, now: t0.addingTimeInterval(1), held: ["idle": "Task ab12: fix"]))
        XCTAssertEqual(fired.withLock { $0 }, 0, "an unchanged signal must not invalidate the sidebar")
    }

    func testAChangedSignalNotifiesObserversOnce() {
        let feed = SidebarSignalFeed()
        feed.publish(signal(quietSessions, now: t0))

        let fired = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = feed.signal
        } onChange: {
            fired.withLock { $0 += 1 }
        }
        let held = signal(quietSessions, now: t0, held: ["idle": "Task ab12: fix"])
        feed.publish(held)
        XCTAssertEqual(fired.withLock { $0 }, 1)
        XCTAssertEqual(feed.signal, held)
    }
}
