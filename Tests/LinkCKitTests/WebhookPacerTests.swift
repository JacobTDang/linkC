import XCTest
@testable import LinkCKit

/// When the next request to a webhook may go (spec §4.1).
final class WebhookPacerTests: XCTestCase {
    typealias Instant = ManualClock.Instant

    private func at(_ milliseconds: Int) -> Instant { Instant(offset: .milliseconds(milliseconds)) }

    func testFiveRequestsGoAtOnceAndTheSixthWaitsForTheOldestToLeaveTheWindow() {
        var pacer = WebhookPacer<Instant>()
        for ms in [0, 100, 200, 300, 400] {
            XCTAssertEqual(pacer.readyAt(at(ms)), at(ms))
            pacer.recordSend(at: at(ms))
        }
        XCTAssertEqual(pacer.readyAt(at(500)), at(2000))
        XCTAssertEqual(pacer.readyAt(at(2000)), at(2000), "the oldest left the window 2 s after it went")
        pacer.recordSend(at: at(2000))
        XCTAssertEqual(pacer.readyAt(at(2000)), at(2100), "the next waits for the second oldest")
    }

    func testAFullWindowEmptiesTwoSecondsLater() {
        var pacer = WebhookPacer<Instant>()
        for _ in 0..<5 { pacer.recordSend(at: at(0)) }
        XCTAssertEqual(pacer.readyAt(at(1999)), at(2000))
        for _ in 0..<5 {
            XCTAssertEqual(pacer.readyAt(at(2000)), at(2000))
            pacer.recordSend(at: at(2000))
        }
        XCTAssertEqual(pacer.readyAt(at(2000)), at(4000))
    }

    func testABlockHoldsEvenAnEmptyWindowAndNeverShortens() {
        var pacer = WebhookPacer<Instant>()
        pacer.block(until: at(1500))
        XCTAssertEqual(pacer.readyAt(at(0)), at(1500))
        pacer.block(until: at(700))
        XCTAssertEqual(pacer.readyAt(at(0)), at(1500), "a shorter block never shortens a longer one")
    }

    func testExhaustedHeadersAskForTheirResetTime() {
        let exhausted = DiscordRateLimit.read(WebhookResponse(
            status: 204, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset-After": "1.5"]))
        XCTAssertEqual(exhausted.exhaustedFor, .milliseconds(1500))
        XCTAssertNil(exhausted.retryAfter)
        XCTAssertNil(DiscordRateLimit.read(WebhookResponse(
            status: 204, headers: ["X-RateLimit-Remaining": "3", "X-RateLimit-Reset-After": "1.5"])).exhaustedFor)
    }

    func testA429WaitsItsRetryAfterFromTheBodyElseTheHeader() {
        let body = Data(#"{"message":"You are being rate limited.","retry_after":0.7,"global":false}"#.utf8)
        let fromBody = DiscordRateLimit.read(WebhookResponse(status: 429, body: body))
        XCTAssertEqual(fromBody.retryAfter, .milliseconds(700))
        XCTAssertFalse(fromBody.global)
        XCTAssertEqual(DiscordRateLimit.read(WebhookResponse(status: 429, headers: ["Retry-After": "3"])).retryAfter,
                       .seconds(3))
    }

    func testAGlobal429IsMarkedGlobal() {
        let body = Data(#"{"retry_after":2,"global":true}"#.utf8)
        XCTAssertTrue(DiscordRateLimit.read(WebhookResponse(status: 429, body: body)).global)
        XCTAssertTrue(DiscordRateLimit.read(WebhookResponse(
            status: 429, headers: ["X-RateLimit-Global": "true", "Retry-After": "2"])).global)
    }

    func testA429ThatGivesNoWaitWaitsFiveSeconds() {
        XCTAssertEqual(DiscordRateLimit.read(WebhookResponse(status: 429)).retryAfter, .seconds(5))
    }

    /// Numbers from the network are untrusted: a huge or infinite wait is clamped to an hour, never a crash.
    func testAnAbsurdWaitIsClampedToAnHour() {
        let huge = Data(#"{"retry_after":1e30}"#.utf8)
        XCTAssertEqual(DiscordRateLimit.read(WebhookResponse(status: 429, body: huge)).retryAfter, .seconds(3600))
        XCTAssertEqual(DiscordRateLimit.read(WebhookResponse(status: 429, headers: ["Retry-After": "inf"])).retryAfter,
                       .seconds(3600))
        XCTAssertEqual(DiscordRateLimit.read(WebhookResponse(
            status: 204, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset-After": "nan"])).exhaustedFor,
            .seconds(3600))
        XCTAssertEqual(DiscordRateLimit.read(WebhookResponse(status: 429, headers: ["Retry-After": "-4"])).retryAfter,
                       .zero)
    }
}

