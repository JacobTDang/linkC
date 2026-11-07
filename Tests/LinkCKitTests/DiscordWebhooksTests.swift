import XCTest
@testable import LinkCKit

/// Which webhook an event goes to, and how webhook URLs are checked and kept (spec §3, §6).
@MainActor
final class DiscordWebhooksTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private let alpha = "https://discord.com/api/webhooks/123456789012345678/AbC-def_GHI"
    private let fallback = "https://discord.com/api/webhooks/987654321/zyx"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-discord-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func preferences(_ defaults: UserDefaults = InMemoryUserDefaults()) -> AppPreferences {
        AppPreferences(defaults: defaults, modelStore: AgentModelStore(directory: root))
    }

    private func make(_ secrets: InMemorySecretStore = InMemorySecretStore())
        -> (webhooks: DiscordWebhooks, secrets: InMemorySecretStore, preferences: AppPreferences) {
        let preferences = preferences()
        return (DiscordWebhooks(secrets: secrets, preferences: preferences), secrets, preferences)
    }

    private func event(project: String?) -> LinkCEvent {
        LinkCEvent(kind: .alert, tone: .info, title: "t", body: "", project: project, at: Date())
    }

    private func webhook(_ text: String) throws -> DiscordWebhookURL {
        try DiscordWebhookURL.parse(text).get()
    }

    func testDiscordsOwnHostsAreAccepted() throws {
        for host in ["discord.com", "discordapp.com", "canary.discord.com", "ptb.discord.com"] {
            XCTAssertEqual(try webhook("https://\(host)/api/webhooks/42/tok-en_1").id, "42")
        }
        XCTAssertEqual(try webhook("  \(alpha)\n").url.absoluteString, alpha, "whitespace from a paste is trimmed")
    }

    func testOtherShapesAreRefusedWithTheReason() {
        let refused = [
            "http://discord.com/api/webhooks/42/token",
            "https://evil.com/api/webhooks/42/token",
            "https://discord.com.evil.com/api/webhooks/42/token",
            "https://discord.com:8443/api/webhooks/42/token",
            "https://discord.com/api/webhooks/abc/token",
            "https://discord.com/api/webhooks/42",
            "https://discord.com/api/webhooks/42/",
            "https://discord.com/api/webhooks/42/token/extra",
            "https://discord.com/api/webhooks/42/token?wait=true",
            "https://discord.com/api/v10/webhooks/42/token",
            "not a url",
        ]
        for text in refused {
            guard case .failure(let refusal) = DiscordWebhookURL.parse(text) else {
                XCTFail("accepted \(text)")
                continue
            }
            XCTAssertFalse(refusal.description.isEmpty, text)
        }
    }

    func testAWebhookIsKeptInTheSecretStoreAndOnlyItsProjectInPreferences() throws {
        let (webhooks, secrets, preferences) = make()
        try webhooks.set(alpha, for: "/p/alpha")
        XCTAssertEqual(try secrets.secret(service: DiscordWebhooks.service, account: "/p/alpha"), alpha)
        XCTAssertEqual(preferences.discordProjects, ["/p/alpha"])
        XCTAssertEqual(webhooks.state(for: "/p/alpha"), .set(try webhook(alpha)))

        try webhooks.set(fallback, for: DiscordWebhooks.defaultAccount)
        XCTAssertEqual(preferences.discordProjects, ["/p/alpha"], "the default is not a project")

        try webhooks.remove("/p/alpha")
        XCTAssertNil(try secrets.secret(service: DiscordWebhooks.service, account: "/p/alpha"))
        XCTAssertEqual(preferences.discordProjects, [])
        XCTAssertEqual(webhooks.state(for: "/p/alpha"), .notSet)
    }

    func testARefusedURLIsNotStored() {
        let (webhooks, secrets, preferences) = make()
        XCTAssertThrowsError(try webhooks.set("https://evil.com/api/webhooks/42/token", for: "/p/alpha"))
        XCTAssertEqual(secrets.count, 0)
        XCTAssertEqual(preferences.discordProjects, [])
    }

    func testAProjectsEventGoesToItsOwnWebhook() throws {
        let (webhooks, _, _) = make()
        try webhooks.set(fallback, for: DiscordWebhooks.defaultAccount)
        try webhooks.set(alpha, for: "/p/alpha")
        XCTAssertEqual(webhooks.route(event(project: "/p/alpha")), .webhook(account: "/p/alpha", try webhook(alpha)))
    }

    func testOtherEventsGoToTheDefault() throws {
        let (webhooks, _, _) = make()
        try webhooks.set(fallback, for: DiscordWebhooks.defaultAccount)
        try webhooks.set(alpha, for: "/p/alpha")
        let toDefault = DiscordRoute.webhook(account: DiscordWebhooks.defaultAccount, try webhook(fallback))
        XCTAssertEqual(webhooks.route(event(project: "/p/beta")), toDefault)
        XCTAssertEqual(webhooks.route(event(project: nil)), toDefault)
        XCTAssertEqual(webhooks.route(event(project: "/p/alpha/sub")), toDefault, "a subfolder is not its parent's project")
    }

    func testWithNoWebhookNothingIsPosted() {
        XCTAssertEqual(make().webhooks.route(event(project: "/p/alpha")), .none(reason: nil))
    }

    /// A project with its own entry never falls back to the default, which could post one project's
    /// work into another project's server.
    func testAProjectWhoseWebhookIsMissingIsNotPostedAndNeverFallsBack() throws {
        let (webhooks, secrets, _) = make()
        try webhooks.set(fallback, for: DiscordWebhooks.defaultAccount)
        try webhooks.set(alpha, for: "/p/alpha")
        try secrets.deleteSecret(service: DiscordWebhooks.service, account: "/p/alpha")
        webhooks.reload()

        XCTAssertEqual(webhooks.state(for: "/p/alpha"), .missing)
        guard case .none(let reason?) = webhooks.route(event(project: "/p/alpha")) else {
            return XCTFail("posted somewhere")
        }
        XCTAssertTrue(reason.contains("missing"), reason)
    }

    func testAKeychainThatCantBeReadIsNotPostedAndSaysWhy() throws {
        let (webhooks, secrets, _) = make()
        try webhooks.set(fallback, for: DiscordWebhooks.defaultAccount)
        secrets.failure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "locked"])
        webhooks.reload()

        guard case .unreadable(let reason) = webhooks.state(for: DiscordWebhooks.defaultAccount) else {
            return XCTFail("read as \(webhooks.state(for: DiscordWebhooks.defaultAccount))")
        }
        XCTAssertTrue(reason.contains("locked"), reason)
        XCTAssertEqual(webhooks.route(event(project: nil)), .none(reason: reason))
    }

    func testTheProjectListSurvivesARelaunch() {
        let defaults = InMemoryUserDefaults()
        preferences(defaults).discordProjects = ["/p/alpha"]
        XCTAssertEqual(preferences(defaults).discordProjects, ["/p/alpha"])
    }
}
