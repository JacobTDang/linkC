import XCTest
@testable import LinkCKit

final class LimitCooldownTests: XCTestCase {
    /// UTC throughout, so "at 3:05 PM" resolves the same wherever the test happens to run.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// 2024-01-15, at the given hour:minute UTC.
    private func date(hour: Int, minute: Int, day: Int = 15) -> Date {
        var components = DateComponents()
        components.year = 2024
        components.month = 1
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    private func usage(usedPercent: Double?, resetsAt: Date?) -> AgentUsage {
        AgentUsage(
            agent: .codex,
            windows: [UsageWindow(label: "5h", usedPercent: usedPercent, tokens: nil, resetsAt: resetsAt)],
            planType: nil,
            observedAt: Date(),
            unavailableReason: nil
        )
    }

    /// Rule (a) beats rule (b): a window at or past 99.5% with a future reset wins even when the
    /// banner text itself claims a much sooner time.
    func testUsageWindowBeatsTheBannerText() {
        let now = date(hour: 14, minute: 0)
        let realReset = now.addingTimeInterval(3 * 3600)
        let result = LimitCooldown.expiry(
            bannerText: "Please try again in 5 minutes.",
            usage: usage(usedPercent: 100, resetsAt: realReset),
            now: now, calendar: calendar, fallback: 900
        )
        XCTAssertEqual(result, realReset, "an exhausted window's own reset must win over the banner's claimed time")
    }

    /// A window's reset already in the past does not count as "the real reset" — it describes a
    /// window that has already moved on, so this rule must not apply.
    func testAPastResetIsIgnored() {
        let now = date(hour: 14, minute: 0)
        let pastReset = now.addingTimeInterval(-3600)
        let result = LimitCooldown.expiry(
            bannerText: "", usage: usage(usedPercent: 100, resetsAt: pastReset),
            now: now, calendar: calendar, fallback: 500
        )
        XCTAssertEqual(result, now.addingTimeInterval(500), "a past reset must fall through to the fallback")
    }

    /// "at 3:05 PM" when `now` is still earlier that same day resolves to today.
    func testAtTimeResolvesToTodayWhenStillAhead() {
        let now = date(hour: 14, minute: 0) // 2:00 PM
        let result = LimitCooldown.expiry(
            bannerText: "Please try again at 3:05 PM.", usage: nil,
            now: now, calendar: calendar, fallback: 900
        )
        XCTAssertEqual(result, date(hour: 15, minute: 5), "3:05 PM has not happened yet today")
    }

    /// The same banner time, once `now` has already passed it, resolves to tomorrow. Also proves
    /// the bare "3:05pm" (no "at", no space, lowercase) form parses.
    func testAtTimeResolvesToTomorrowWhenAlreadyPassed() {
        let now = date(hour: 16, minute: 0) // 4:00 PM
        let result = LimitCooldown.expiry(
            bannerText: "quota resets 3:05pm", usage: nil,
            now: now, calendar: calendar, fallback: 900
        )
        XCTAssertEqual(result, date(hour: 15, minute: 5, day: 16), "3:05 PM already passed today, so it means tomorrow")
    }

    /// "in 2h 10m" — a combined hours+minutes duration.
    func testInHoursAndMinutesDuration() {
        let now = date(hour: 9, minute: 0)
        let result = LimitCooldown.expiry(
            bannerText: "Try again in 2h 10m.", usage: nil,
            now: now, calendar: calendar, fallback: 999_999
        )
        XCTAssertEqual(result, now.addingTimeInterval(2 * 3600 + 10 * 60))
    }

    /// "in 45 minutes" — a minutes-only duration.
    func testInMinutesOnlyDuration() {
        let now = date(hour: 9, minute: 0)
        let result = LimitCooldown.expiry(
            bannerText: "You can try again in 45 minutes.", usage: nil,
            now: now, calendar: calendar, fallback: 999_999
        )
        XCTAssertEqual(result, now.addingTimeInterval(45 * 60))
    }

    /// "in 1 hour" — an hours-only duration.
    func testInHoursOnlyDuration() {
        let now = date(hour: 9, minute: 0)
        let result = LimitCooldown.expiry(
            bannerText: "Try again in 1 hour.", usage: nil,
            now: now, calendar: calendar, fallback: 999_999
        )
        XCTAssertEqual(result, now.addingTimeInterval(3600))
    }

    /// No usage window and no parseable banner text: the fixed fallback applies exactly as it
    /// does today.
    func testFallsBackToTheGivenCooldownWhenNothingElseApplies() {
        let now = date(hour: 9, minute: 0)
        let result = LimitCooldown.expiry(
            bannerText: "You've hit your limit. Please wait.", usage: nil,
            now: now, calendar: calendar, fallback: 1234
        )
        XCTAssertEqual(result, now.addingTimeInterval(1234))
    }

    /// However short the fallback, the result is never less than 60 seconds out.
    func testNeverRestsForLessThanSixtySeconds() {
        let now = date(hour: 9, minute: 0)
        let result = LimitCooldown.expiry(
            bannerText: "", usage: nil, now: now, calendar: calendar, fallback: 5
        )
        XCTAssertEqual(result, now.addingTimeInterval(60))
    }
}
