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

    /// Each shape is refused by the check meant for it, with that check's reason.
    func testOtherShapesAreRefusedWithTheReason() {
        let shape = "looks like https://discord.com/api/webhooks/<id>/<token>"
        let refused: [(text: String, reason: String)] = [
            ("", "not a URL"),
            ("https://discord.com/api/webhooks/42/tok en", "the webhook token is missing or malformed"),
            ("http://discord.com/api/webhooks/42/token", "starts with https://"),
            ("https://evil.com/api/webhooks/42/token", "is on discord.com"),
            ("https://discord.com.evil.com/api/webhooks/42/token", "is on discord.com"),
            ("https://discord.com@evil.com/api/webhooks/42/token", "is on discord.com"),
            ("https://x@discord.com/api/webhooks/42/token", shape),
            ("https://x:y@discord.com/api/webhooks/42/token", shape),
            ("https://discord.com:8443/api/webhooks/42/token", shape),
            ("https://discord.com/api/webhooks/42/token?wait=true", shape),
            ("https://discord.com/api/webhooks/42/token#top", shape),
            ("https://discord.com/api/webhooks/%34%32/token", shape),
            ("https://discord.com/%61pi/webhooks/42/token", shape),
            ("https://discord.com/api/webhooks/42", shape),
            ("https://discord.com/api/webhooks/42/token/extra", shape),
            ("https://discord.com/api/v10/webhooks/42/token", shape),
            ("https://discord.com/api/webhooks/abc/token", "the webhook id is a number"),
            ("https://discord.com/api/webhooks/４２/token", "the webhook id is a number"),
            ("https://discord.com/api/webhooks/42/", "the webhook token is missing or malformed"),
        ]
        for (text, reason) in refused {
            guard case .failure(let refusal) = DiscordWebhookURL.parse(text) else {
                XCTFail("accepted \(text)")
                continue
            }
            XCTAssertTrue(refusal.description.contains(reason), "\(text): \(refusal.description)")
        }
    }

    /// One webhook has one spelling, so it gets one queue and one rate limit: the host is lowercased
    /// and the token kept as it is.
    func testTheStoredURLIsRebuiltFromItsParts() throws {
        XCTAssertEqual(try webhook("https://DISCORD.com/api/webhooks/42/AbC").url.absoluteString,
                       "https://discord.com/api/webhooks/42/AbC")
    }

    /// A webhook printed anywhere (a log line, a test failure) shows its id, never its token.
    func testAWebhookPrintsItsIdNeverItsToken() throws {
        let set = try webhook(alpha)
        XCTAssertEqual("\(set)", "webhook 123456789012345678")
        XCTAssertFalse(String(describing: DiscordWebhookState.set(set)).contains("AbC-def_GHI"))
        XCTAssertFalse(String(describing: DiscordRoute.webhook(account: "default", set)).contains("AbC-def_GHI"))
    }

    /// Errors read well wherever they are shown through `localizedDescription` (Settings, the status line).
    func testErrorsKeepTheirReasonThroughLocalizedDescription() {
        guard case .failure(let refusal) = DiscordWebhookURL.parse("http://discord.com/api/webhooks/42/token") else {
            return XCTFail("accepted")
        }
        XCTAssertEqual(refusal.localizedDescription, refusal.description)
        XCTAssertTrue(KeychainSecretStore.Failure(status: errSecItemNotFound).localizedDescription
            .contains("Keychain error -25300"))
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
        XCTAssertEqual(webhooks.route(event(project: "/p/alphabet")), toDefault, "a folder whose name starts the same is not inside it")
    }

    /// A project's webhook covers every folder inside it, its worktrees included (spec §3).
    func testASubfolderOrWorktreeGoesToItsProjectsWebhook() throws {
        let (webhooks, _, _) = make()
        try webhooks.set(fallback, for: DiscordWebhooks.defaultAccount)
        try webhooks.set(alpha, for: "/p/alpha")
        let toAlpha = DiscordRoute.webhook(account: "/p/alpha", try webhook(alpha))
        XCTAssertEqual(webhooks.route(event(project: "/p/alpha/.worktrees/feature")), toAlpha)
        XCTAssertEqual(webhooks.route(event(project: "/p/alpha/sub/deeper")), toAlpha)
    }

    /// When listed folders nest, the nearest one above the event's folder wins.
    func testTheNearestListedFolderWins() throws {
        let (webhooks, _, _) = make()
        let worktree = "https://discord.com/api/webhooks/555555555/wt-token"
        try webhooks.set(alpha, for: "/p/alpha")
        try webhooks.set(worktree, for: "/p/alpha/.worktrees/feature")
        XCTAssertEqual(webhooks.route(event(project: "/p/alpha/.worktrees/feature/src")),
                       .webhook(account: "/p/alpha/.worktrees/feature", try webhook(worktree)))
        XCTAssertEqual(webhooks.route(event(project: "/p/alpha/.worktrees/other")),
                       .webhook(account: "/p/alpha", try webhook(alpha)))
    }

    /// The nearest listed folder decides even when its webhook is missing: no fallback to a parent's or the default.
    func testAMissingNearestWebhookFallsBackToNoOne() throws {
        let (webhooks, secrets, _) = make()
        try webhooks.set(fallback, for: DiscordWebhooks.defaultAccount)
        try webhooks.set(alpha, for: "/p/alpha")
        try webhooks.set("https://discord.com/api/webhooks/555555555/wt-token", for: "/p/alpha/.worktrees/feature")
        try secrets.deleteSecret(service: DiscordWebhooks.service, account: "/p/alpha/.worktrees/feature")
        webhooks.reload()
        guard case .none(let reason?) = webhooks.route(event(project: "/p/alpha/.worktrees/feature/src")) else {
            return XCTFail("the worktree's missing webhook must stop its events")
        }
        XCTAssertTrue(reason.contains("missing"), reason)
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

    /// Settings may hand over a folder through a symlink: the project is kept, and matched, in its
    /// canonical form.
    func testAProjectIsKeptInItsCanonicalForm() throws {
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let (webhooks, _, preferences) = make()

        try webhooks.set(alpha, for: link.path)

        XCTAssertEqual(preferences.discordProjects, [ProjectPath.canonical(real.path)])
        XCTAssertEqual(webhooks.route(event(project: ProjectPath.canonical(real.path))),
                       .webhook(account: ProjectPath.canonical(real.path), try webhook(alpha)))
        try webhooks.remove(link.path)
        XCTAssertEqual(preferences.discordProjects, [])
    }

    /// A project listed but not read yet is missing, never silently not set.
    func testAListedProjectNotReadYetIsMissing() {
        let (webhooks, _, preferences) = make()
        preferences.discordProjects = ["/p/alpha"]
        XCTAssertEqual(webhooks.state(for: "/p/alpha"), .missing)
        XCTAssertEqual(webhooks.state(for: "/p/beta"), .notSet)
    }

    func testAStoredValueThatIsNotAWebhookIsUnreadable() throws {
        let secrets = InMemorySecretStore()
        try secrets.setSecret("https://evil.com/api/webhooks/42/token", service: DiscordWebhooks.service,
                              account: DiscordWebhooks.defaultAccount)
        let (webhooks, _, _) = make(secrets)
        guard case .unreadable(let reason) = webhooks.state(for: DiscordWebhooks.defaultAccount) else {
            return XCTFail("read as \(webhooks.state(for: DiscordWebhooks.defaultAccount))")
        }
        XCTAssertTrue(reason.contains("not valid"), reason)
    }

    func testAnUnreadableProjectWebhookNeverFallsBack() throws {
        let (webhooks, secrets, _) = make()
        try webhooks.set(fallback, for: DiscordWebhooks.defaultAccount)
        try webhooks.set(alpha, for: "/p/alpha")
        secrets.failure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "locked"])
        webhooks.reload()

        guard case .none(let reason?) = webhooks.route(event(project: "/p/alpha")) else {
            return XCTFail("posted somewhere")
        }
        XCTAssertTrue(reason.contains("locked"), reason)
    }

    func testTheWebhooksAreReadAgainAtTheNextLaunch() throws {
        let defaults = InMemoryUserDefaults(), secrets = InMemorySecretStore()
        try DiscordWebhooks(secrets: secrets, preferences: preferences(defaults)).set(alpha, for: "/p/alpha")
        let relaunched = DiscordWebhooks(secrets: secrets, preferences: preferences(defaults))
        XCTAssertEqual(relaunched.state(for: "/p/alpha"), .set(try webhook(alpha)))
    }

    /// The project list is the routing table: one stored with the wrong type is kept aside, not lost.
    func testAProjectListOfTheWrongTypeIsKeptAside() {
        let defaults = InMemoryUserDefaults()
        defaults.set("not a list", forKey: "discordWebhookProjects")
        XCTAssertEqual(preferences(defaults).discordProjects, [])
        XCTAssertEqual(defaults.object(forKey: "discordWebhookProjects.unreadable") as? String, "not a list")
    }
}
