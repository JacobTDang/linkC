import XCTest
@testable import LinkCKit

/// Routing events to queues, the global pause, the stop notice and Settings' actions (spec §3, §4, §6).
@MainActor
final class DiscordNotifierTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let defaultURL = "https://discord.com/api/webhooks/1/default-token"
    private let alphaURL = "https://discord.com/api/webhooks/2/alpha-token"
    private let alpha = "/p/alpha"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-notifier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private final class Notices {
        var posted: [(title: String, body: String)] = []
    }

    private func make(_ transport: ScriptedWebhookTransport, clock: ManualClock = ManualClock(),
                      secrets: InMemorySecretStore = InMemorySecretStore())
        -> (notifier: DiscordNotifier<ManualClock>, notices: Notices) {
        let preferences = AppPreferences(defaults: InMemoryUserDefaults(), modelStore: AgentModelStore(directory: root))
        let notices = Notices()
        let notifier = DiscordNotifier(
            webhooks: DiscordWebhooks(secrets: secrets, preferences: preferences),
            transport: transport, clock: clock, wallClock: { Date(timeIntervalSince1970: 1_000) },
            notifyUser: { notices.posted.append(($0, $1)) })
        return (notifier, notices)
    }

    private func event(_ title: String, project: String?) -> LinkCEvent {
        LinkCEvent(kind: .alert, tone: .info, title: title, body: "", project: project, at: Date(timeIntervalSince1970: 0))
    }

    private func until(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<TestWait.polls {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for: \(what)")
    }

    func testAProjectsEventGoesToItsWebhookAndOthersToTheDefault() async throws {
        let transport = ScriptedWebhookTransport()
        let (notifier, _) = make(transport)
        defer { notifier.shutdown() }
        try notifier.set(defaultURL, for: DiscordWebhooks.defaultAccount)
        try notifier.set(alphaURL, for: alpha)

        notifier.post(event("for alpha", project: alpha))
        try await until("alpha's request") { transport.requests.count == 1 }
        notifier.post(event("for beta", project: "/p/beta"))
        try await until("the default's request") { transport.requests.count == 2 }

        XCTAssertEqual(transport.requests.map(\.url.absoluteString), [alphaURL, defaultURL])
        XCTAssertEqual(transport.requests.map(\.embedTitles), [["for alpha"], ["for beta"]])
    }

    func testWithNoWebhookNothingIsSent() async throws {
        let transport = ScriptedWebhookTransport()
        let (notifier, _) = make(transport)
        defer { notifier.shutdown() }
        notifier.post(event("lost", project: nil))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAMissingProjectWebhookPostsNothingAndShowsMissing() async throws {
        let transport = ScriptedWebhookTransport(), secrets = InMemorySecretStore()
        let (notifier, _) = make(transport, secrets: secrets)
        defer { notifier.shutdown() }
        try notifier.set(defaultURL, for: DiscordWebhooks.defaultAccount)
        try notifier.set(alphaURL, for: alpha)
        try secrets.deleteSecret(service: DiscordWebhooks.service, account: alpha)
        notifier.webhooks.reload()

        notifier.post(event("for alpha", project: alpha))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(transport.requests.isEmpty, "never falls back to the default")
        XCTAssertEqual(notifier.status(for: alpha), .missing)
    }

    /// Discord's global limit is per IP: a webhook made after the 429 waits too.
    func testAGlobal429PausesEveryWebhook() async throws {
        let clock = ManualClock()
        let transport = ScriptedWebhookTransport([.success(WebhookResponse(
            status: 429, body: Data(#"{"retry_after":3,"global":true}"#.utf8)))])
        let (notifier, _) = make(transport, clock: clock)
        defer { notifier.shutdown() }
        try notifier.set(defaultURL, for: DiscordWebhooks.defaultAccount)
        try notifier.set(alphaURL, for: alpha)

        notifier.post(event("for alpha", project: alpha))
        try await until("the global 429") { transport.requests.count == 1 }
        try await until("alpha waits") { clock.pendingSleeps.count == 1 }
        notifier.post(event("for the default", project: nil))
        try await until("the default waits too") { clock.pendingSleeps.count == 2 }
        XCTAssertEqual(transport.requests.count, 1)

        clock.advance(by: .seconds(3))
        try await until("both go") { transport.requests.count == 3 }
    }

    /// One queue per webhook URL: two accounts set to the same URL share its window.
    func testTwoAccountsWithOneURLShareOneWindow() async throws {
        let clock = ManualClock(), transport = ScriptedWebhookTransport()
        let (notifier, _) = make(transport, clock: clock)
        defer { notifier.shutdown() }
        try notifier.set(defaultURL, for: DiscordWebhooks.defaultAccount)
        try notifier.set(defaultURL, for: alpha)
        for n in 1...5 {
            notifier.post(event("e\(n)", project: n.isMultiple(of: 2) ? alpha : nil))
            try await until("request \(n)") { transport.requests.count == n }
        }

        notifier.post(event("e6", project: alpha))
        try await until("the sixth waits for the shared window") { !clock.pendingSleeps.isEmpty }
        XCTAssertEqual(transport.requests.count, 5)
    }

    func testAStoppedWebhookTellsTheUserOnceAndATestStartsItAgain() async throws {
        let transport = ScriptedWebhookTransport([.success(WebhookResponse(status: 404))])
        let (notifier, notices) = make(transport)
        defer { notifier.shutdown() }
        try notifier.set(alphaURL, for: alpha)

        notifier.post(event("first", project: alpha))
        try await until("stopped") { notifier.status(for: alpha) == .stopped(status: 404) }
        notifier.post(event("second", project: alpha))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(notices.posted.count, 1)
        XCTAssertEqual(notices.posted.first?.title, "linkC stopped posting to Discord")
        XCTAssertTrue(notices.posted.first?.body.contains("alpha") ?? false)
        XCTAssertFalse(notices.posted.first?.body.contains("alpha-token") ?? true, "never the URL")

        try notifier.sendTest(to: alpha)
        try await until("the test goes") { transport.requests.count == 2 }
        XCTAssertEqual(transport.requests[1].embedTitles, ["linkC is connected"])
        try await until("posted") { notifier.status(for: alpha) == .posted(at: Date(timeIntervalSince1970: 1_000)) }
    }

    func testSettingAWebhookAgainStartsItFresh() async throws {
        let transport = ScriptedWebhookTransport([.success(WebhookResponse(status: 404))])
        let (notifier, _) = make(transport)
        defer { notifier.shutdown() }
        try notifier.set(alphaURL, for: alpha)
        notifier.post(event("first", project: alpha))
        try await until("stopped") { notifier.status(for: alpha) == .stopped(status: 404) }

        try notifier.set(alphaURL, for: alpha)
        XCTAssertEqual(notifier.status(for: alpha), .idle)
        notifier.post(event("again", project: alpha))
        try await until("it goes") { transport.requests.count == 2 }
    }

    func testRemovingAWebhookStopsItsEvents() async throws {
        let transport = ScriptedWebhookTransport()
        let (notifier, _) = make(transport)
        defer { notifier.shutdown() }
        try notifier.set(alphaURL, for: alpha)
        try notifier.remove(alpha)
        notifier.post(event("for alpha", project: alpha))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(notifier.webhooks.state(for: alpha), .notSet)
    }

    func testATestWithNoWebhookSaysSo() {
        let (notifier, _) = make(ScriptedWebhookTransport())
        XCTAssertThrowsError(try notifier.sendTest(to: DiscordWebhooks.defaultAccount))
    }

    func testStatusLabels() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(WebhookStatus.idle.label(now: now), "Not posted yet")
        XCTAssertEqual(WebhookStatus.posted(at: now.addingTimeInterval(-20)).label(now: now), "Posted just now")
        XCTAssertEqual(WebhookStatus.posted(at: now.addingTimeInterval(-120)).label(now: now), "Posted 2m ago")
        XCTAssertEqual(WebhookStatus.posted(at: now.addingTimeInterval(-7200)).label(now: now), "Posted 2h ago")
        XCTAssertEqual(WebhookStatus.waiting(until: now.addingTimeInterval(3.2)).label(now: now), "Waiting 4s for Discord")
        XCTAssertEqual(WebhookStatus.stopped(status: 404).label(now: now), "Stopped: webhook deleted (404)")
        XCTAssertEqual(WebhookStatus.stopped(status: 401).label(now: now), "Stopped: webhook not accepted (401)")
        XCTAssertEqual(WebhookStatus.failed("Discord answered 500", at: now).label(now: now), "Failed: Discord answered 500")
        XCTAssertEqual(WebhookStatus.missing.label(now: now), "Webhook missing — set it again")
    }
}
