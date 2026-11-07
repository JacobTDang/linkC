import XCTest
@testable import LinkCKit

/// One webhook's queue: pacing, batching, the bound and Discord's answers (spec §4).
@MainActor
final class WebhookQueueTests: XCTestCase {
    private let url = URL(string: "https://discord.com/api/webhooks/1/token")!
    private let wallNow = Date(timeIntervalSince1970: 1_000)

    private func event(_ n: Int, body: String = "") -> LinkCEvent {
        LinkCEvent(kind: .alert, tone: .info, title: "event \(n)", body: body, project: nil,
                   at: Date(timeIntervalSince1970: 0))
    }

    private func makeQueue(_ transport: ScriptedWebhookTransport, _ clock: ManualClock) -> WebhookQueue<ManualClock> {
        let wallNow = self.wallNow
        return WebhookQueue(name: "default", url: url, transport: transport, clock: clock, wallClock: { wallNow })
    }

    /// Waits for something the queue reaches on its own.
    private func until(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<TestWait.polls {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for: \(what)")
    }

    private func sendOneByOne(_ queue: WebhookQueue<ManualClock>, _ transport: ScriptedWebhookTransport, _ count: Int) async throws {
        let start = transport.requests.count
        for n in 1...count {
            queue.enqueue(event(n))
            try await until("request \(start + n)") { transport.requests.count == start + n }
        }
    }

    func testFiveRequestsGoAtOnceAndTheSixthWaitsForTheWindow() async throws {
        let clock = ManualClock(), transport = ScriptedWebhookTransport()
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        try await sendOneByOne(queue, transport, 5)

        queue.enqueue(event(6))
        try await until("the sixth waits") { !clock.pendingSleeps.isEmpty }
        XCTAssertEqual(transport.requests.count, 5)
        XCTAssertEqual(clock.pendingSleeps.first?.requested, .seconds(2))
        XCTAssertEqual(queue.status, .waiting(until: wallNow.addingTimeInterval(2)))

        clock.advance(by: .seconds(2))
        try await until("the sixth goes once the first left the window") { transport.requests.count == 6 }
        try await until("posted") { queue.status == .posted(at: self.wallNow) }
    }

    func testARequestTwoSecondsAfterAFullWindowGoesAtOnce() async throws {
        let clock = ManualClock(), transport = ScriptedWebhookTransport()
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        try await sendOneByOne(queue, transport, 5)
        clock.advance(by: .seconds(2))

        try await sendOneByOne(queue, transport, 1)
        XCTAssertTrue(clock.pendingSleeps.isEmpty)
    }

    func testExhaustedHeadersHoldTheNextRequest() async throws {
        let clock = ManualClock()
        let transport = ScriptedWebhookTransport([.success(WebhookResponse(
            status: 204, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset-After": "1.5"]))])
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        try await sendOneByOne(queue, transport, 1)

        queue.enqueue(event(2))
        try await until("the second waits") { !clock.pendingSleeps.isEmpty }
        XCTAssertEqual(clock.pendingSleeps.first?.requested, .milliseconds(1500))
        clock.advance(by: .milliseconds(1500))
        try await until("the second goes") { transport.requests.count == 2 }
    }

    func testA429ResendsTheSameMessageAfterItsWait() async throws {
        let clock = ManualClock()
        let transport = ScriptedWebhookTransport([.success(WebhookResponse(
            status: 429, body: Data(#"{"retry_after":0.7,"global":false}"#.utf8)))])
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        queue.enqueue(event(1))
        try await until("the 429") { transport.requests.count == 1 }
        try await until("the wait") { !clock.pendingSleeps.isEmpty }
        XCTAssertEqual(clock.pendingSleeps.first?.requested, .milliseconds(700))

        clock.advance(by: .milliseconds(700))
        try await until("the resend") { transport.requests.count == 2 }
        XCTAssertEqual(transport.requests[1].body, transport.requests[0].body)
        try await until("posted") { queue.status == .posted(at: self.wallNow) }
    }

    func testAGlobal429IsReported() async throws {
        let clock = ManualClock()
        let transport = ScriptedWebhookTransport([.success(WebhookResponse(
            status: 429, body: Data(#"{"retry_after":2,"global":true}"#.utf8)))])
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        var reported: [Duration] = []
        queue.onGlobalLimit = { reported.append($0) }
        queue.enqueue(event(1))
        try await until("the global limit is reported") { reported == [.seconds(2)] }
    }

    func testThirtyWaitingEventsGoAsThreeMessagesOfTen() async throws {
        let clock = ManualClock(), transport = ScriptedWebhookTransport()
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        for n in 0..<30 { queue.enqueue(event(n)) }
        try await until("three messages") { transport.requests.count == 3 }
        XCTAssertEqual(transport.requests.map(\.embedTitles.count), [10, 10, 10])
        XCTAssertEqual(transport.requests[0].embedTitles.first, "event 0")
        XCTAssertEqual(transport.requests[2].embedTitles.last, "event 29")
    }

    func testTheCharacterLimitSplitsABatch() async throws {
        let clock = ManualClock(), transport = ScriptedWebhookTransport()
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        for n in 0..<3 { queue.enqueue(event(n, body: String(repeating: "x", count: 2500))) }
        try await until("two messages") { transport.requests.count == 2 }
        XCTAssertEqual(transport.requests.map(\.embedTitles.count), [2, 1])
    }

    func testMoreThanAHundredWaitingDropsTheOldestAndSaysSo() async throws {
        let clock = ManualClock(), transport = ScriptedWebhookTransport()
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        try await sendOneByOne(queue, transport, 5)
        for n in 0...100 { queue.enqueue(event(100 + n)) }
        try await until("the batch waits for the window") { !clock.pendingSleeps.isEmpty }

        clock.advance(by: .seconds(2))
        // The next batches follow at once, up to the window: wait for the first, not for a count.
        try await until("the batch goes") { transport.requests.count >= 6 }
        XCTAssertEqual(transport.requests[5].json["content"] as? String,
                       "1 earlier event was not posted (Discord was rate limiting).")
        XCTAssertEqual(transport.requests[5].embedTitles.first, "event 101")
    }

    func testA404StopsTheWebhookAndSendsNothingMore() async throws {
        let clock = ManualClock(), transport = ScriptedWebhookTransport([.success(WebhookResponse(status: 404))])
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        var stopped: [Int] = []
        queue.onStopped = { stopped.append($0) }
        queue.enqueue(event(1))
        try await until("stopped") { queue.status == .stopped(status: 404) }
        XCTAssertEqual(stopped, [404])
        XCTAssertTrue(queue.isStopped)

        queue.enqueue(event(2))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testA500IsRetriedFiveTimesThenDroppedAndReported() async throws {
        let clock = ManualClock()
        let transport = ScriptedWebhookTransport(Array(repeating: .success(WebhookResponse(status: 500)), count: 6))
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        queue.enqueue(event(1))
        for (attempt, delay) in [2, 4, 8, 16, 32].enumerated() {
            try await until("attempt \(attempt + 1)") { transport.requests.count == attempt + 1 }
            try await until("retry wait \(delay)") { !clock.pendingSleeps.isEmpty }
            XCTAssertEqual(clock.pendingSleeps.first?.requested, .seconds(delay))
            clock.advance(by: .seconds(delay))
        }
        try await until("the sixth attempt") { transport.requests.count == 6 }
        try await until("failed") {
            if case .failed = queue.status { return true }
            return false
        }

        queue.enqueue(event(2))
        try await until("the next message still goes") { transport.requests.count == 7 }
    }

    func testANetworkFailureIsRetried() async throws {
        let clock = ManualClock(), transport = ScriptedWebhookTransport([.failure(URLError(.timedOut))])
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        queue.enqueue(event(1))
        try await until("the retry wait") { !clock.pendingSleeps.isEmpty }
        XCTAssertEqual(clock.pendingSleeps.first?.requested, .seconds(2))
        clock.advance(by: .seconds(2))
        try await until("the retry") { transport.requests.count == 2 }
        try await until("posted") { queue.status == .posted(at: self.wallNow) }
    }

    func testA400IsDroppedAtOnceAndTheNextMessageStillGoes() async throws {
        let clock = ManualClock()
        let transport = ScriptedWebhookTransport([.success(WebhookResponse(
            status: 400, body: Data(#"{"message":"Invalid Form Body","code":50035}"#.utf8)))])
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        queue.enqueue(event(1))
        try await until("failed with the 400") {
            if case .failed(let text, _) = queue.status { return text.contains("400") }
            return false
        }
        XCTAssertTrue(clock.pendingSleeps.isEmpty, "a 400 is not retried")

        queue.enqueue(event(2))
        try await until("the next message goes") { transport.requests.count == 2 }
    }

    /// A cancelled queue is done for good: it takes nothing more.
    func testACancelledQueueTakesNothingMore() async throws {
        let clock = ManualClock(), transport = ScriptedWebhookTransport()
        let queue = makeQueue(transport, clock)
        queue.cancel()
        queue.enqueue(event(1))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// A request still in flight when its queue is cancelled (its webhook was replaced) is answered into
    /// nothing: no status, no stop, no notice for the webhook that replaced it.
    func testAnAnswerAfterCancelChangesNothing() async throws {
        let clock = ManualClock(), transport = GatedWebhookTransport()
        let queue = WebhookQueue(name: "default", url: url, transport: transport, clock: clock, wallClock: { Date() })
        var stopped: [Int] = []
        var statuses: [WebhookStatus] = []
        queue.onStopped = { stopped.append($0) }
        queue.enqueue(event(1))
        try await until("the request is in flight") { transport.requests == 1 }
        queue.onStatus = { statuses.append($0) }

        queue.cancel()
        transport.release(with: WebhookResponse(status: 404))
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(stopped, [])
        XCTAssertEqual(statuses, [])
        XCTAssertFalse(queue.isStopped)
    }

    /// Discord's global limit, passed on by another queue, holds this one too.
    func testAPauseHoldsTheNextRequest() async throws {
        let clock = ManualClock(), transport = ScriptedWebhookTransport()
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        queue.pause(for: .seconds(3))
        queue.enqueue(event(1))
        try await until("the request waits") { !clock.pendingSleeps.isEmpty }
        XCTAssertEqual(clock.pendingSleeps.first?.requested, .seconds(3))
        XCTAssertTrue(transport.requests.isEmpty)
        clock.advance(by: .seconds(3))
        try await until("the request goes") { transport.requests.count == 1 }
    }

    /// A redirect is not Discord's answer, and the transport follows none: a retry would get the same.
    func testARedirectIsDroppedNotRetried() async throws {
        let clock = ManualClock(), transport = ScriptedWebhookTransport([.success(WebhookResponse(status: 301))])
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        queue.enqueue(event(1))
        try await until("failed with the redirect") {
            if case .failed(let text, _) = queue.status { return text.contains("301") }
            return false
        }
        XCTAssertTrue(clock.pendingSleeps.isEmpty, "a redirect is not retried")
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// The events of a message linkC had to drop are counted in the next message, never lost silently.
    func testADroppedMessagesEventsAreCountedInTheNext() async throws {
        let clock = ManualClock()
        let transport = ScriptedWebhookTransport([.success(WebhookResponse(status: 400))])
        let queue = makeQueue(transport, clock)
        defer { queue.cancel() }
        queue.enqueue(event(1))
        queue.enqueue(event(2))
        try await until("the 400") { transport.requests.count == 1 }
        try await until("failed") {
            if case .failed = queue.status { return true }
            return false
        }

        queue.enqueue(event(3))
        try await until("the next message") { transport.requests.count == 2 }
        XCTAssertEqual(transport.requests[1].json["content"] as? String,
                       "2 earlier events were not posted (Discord was rate limiting).")
        XCTAssertEqual(transport.requests[1].embedTitles, ["event 3"])
    }
}

