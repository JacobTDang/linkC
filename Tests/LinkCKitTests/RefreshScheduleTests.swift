import XCTest
@testable import LinkCKit

/// The panel's refreshes each run at their own interval, from when they last ran. Showing the panel runs
/// only what has gone stale, so a panel that comes and goes (another Space, the app hidden) costs no more
/// than one left open.
final class RefreshScheduleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testTheFirstShowRunsEverything() {
        var schedule = RefreshSchedule.panel
        XCTAssertEqual(Set(schedule.takeDue(at: start, showing: true)), Set(PanelRefresh.allCases))
    }

    func testFiveMinutesOfTicksRunEachRefreshAtItsInterval() {
        var schedule = RefreshSchedule.panel
        var runs: [PanelRefresh: Int] = [:]
        for refresh in schedule.takeDue(at: start, showing: true) { runs[refresh, default: 0] += 1 }
        for tick in 1...60 {
            for refresh in schedule.takeDue(at: at(Double(tick) * 5), showing: false) { runs[refresh, default: 0] += 1 }
        }
        // The show at 0 s, then one run per interval up to 300 s.
        XCTAssertEqual(runs[.sessions], 61, "every 5 s")
        XCTAssertEqual(runs[.servers], 21, "every 15 s")
        XCTAssertEqual(runs[.window], 11, "every 30 s")
        XCTAssertEqual(runs[.updateCheck], 11, "every 30 s")
        XCTAssertEqual(runs[.cloud], 3, "every 120 s")
        XCTAssertEqual(runs[.codexUsage], 2, "every 300 s")
        XCTAssertEqual(runs[.health], 1, "only when the panel is shown")
    }

    func testATimerTickThatFiresALittleEarlyStillRunsWhatIsDue() {
        var schedule = RefreshSchedule.panel
        _ = schedule.takeDue(at: start, showing: true)
        XCTAssertEqual(Set(schedule.takeDue(at: at(4.9), showing: false)), [.sessions])
        XCTAssertEqual(Set(schedule.takeDue(at: at(14.9), showing: false)), [.sessions, .servers])
    }

    func testATickBeforeAnythingIsDueRunsNothing() {
        var schedule = RefreshSchedule.panel
        _ = schedule.takeDue(at: start, showing: true)
        XCTAssertEqual(schedule.takeDue(at: at(2), showing: false), [])
    }

    func testShowingAgainSoonRunsOnlyWhatHasGoneStale() {
        var schedule = RefreshSchedule.panel
        _ = schedule.takeDue(at: start, showing: true)
        // Hidden after a moment, back 20 s after the first show.
        XCTAssertEqual(Set(schedule.takeDue(at: at(20), showing: true)), [.sessions, .servers])
    }

    func testShowingAgainAfterALongAbsenceRunsEverything() {
        var schedule = RefreshSchedule.panel
        _ = schedule.takeDue(at: start, showing: true)
        XCTAssertEqual(Set(schedule.takeDue(at: at(400), showing: true)), Set(PanelRefresh.allCases))
    }

    func testAPanelThatComesAndGoesStillRefreshesTheSlowSources() {
        // Shown for 10 s out of every 20 s: no tick ever lands 30 s after a show, but the window usage and
        // update check still run every 30 s.
        var schedule = RefreshSchedule.panel
        var windowRuns: [TimeInterval] = []
        for cycle in 0..<9 {
            let shownAt = Double(cycle) * 20
            for (offset, showing) in [(0.0, true), (5.0, false), (10.0, false)] {
                if schedule.takeDue(at: at(shownAt + offset), showing: showing).contains(.window) {
                    windowRuns.append(shownAt + offset)
                }
            }
        }
        XCTAssertEqual(windowRuns, [0, 30, 60, 90, 120, 150])
    }

    func testHealthRunsWhenShownAtMostOnceAMinute() {
        var schedule = RefreshSchedule.panel
        _ = schedule.takeDue(at: start, showing: true)
        XCTAssertFalse(schedule.takeDue(at: at(30), showing: true).contains(.health))
        XCTAssertFalse(schedule.takeDue(at: at(65), showing: false).contains(.health), "never on a tick")
        XCTAssertTrue(schedule.takeDue(at: at(70), showing: true).contains(.health))
    }

    func testTheResultFollowsTheDeclarationOrder() {
        var schedule = RefreshSchedule.panel
        XCTAssertEqual(schedule.takeDue(at: start, showing: true), PanelRefresh.allCases)
    }
}
