# Discord Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** linkC posts its events (agent alerts, tasks, closed workers, rate limits, watched services) to Discord webhooks, routed by project, inside Discord's rate limits.

**Architecture:** Every alert `NotificationManager` already shows also becomes a `LinkCEvent`. The relay adds task and worker events, which are Discord only. A `DiscordNotifier` routes each event to a webhook (`DiscordWebhooks`, URLs in the Keychain) and hands it to that webhook's `WebhookQueue`, which paces requests with a sliding window (`WebhookPacer`), batches them (`DiscordMessage`), and retries or stops by Discord's answer.

**Tech Stack:** Swift 6 (strict concurrency), Foundation, Security (Keychain), URLSession, SwiftUI (Settings), XCTest.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-11-05-discord-notifications-design.md`. When this plan and the spec disagree, stop and ask. One deliberate difference: the spec's `DiscordWebhookConfig` and `DiscordRouter` are one type here, `DiscordWebhooks`.
- Outbound only: linkC never reads from Discord.
- **Never log, show or notify a webhook URL.** Logs and messages name a webhook "default" or by its project folder's name. Transport errors are reported by their description only, never `String(describing:)` of a `URLError` (its `userInfo` holds the URL).
- Sliding window: at most **5** requests per webhook in any **2 s**. Discord's `X-RateLimit-Remaining: 0` + `X-RateLimit-Reset-After`, and a 429's `retry_after`, can only make it stricter.
- The message is the JD LLC house style (spec §5, Task 7): one Components V2 container, at most **40** components and **4000** text characters (UTF-16 units); title **100**, detail line **120**, folder name **50**, at most **4** detail lines, digest pages of at most **15** events; cut with `…`. (Tasks 1-4 first built embeds; Task 7 replaces them.)
- At most **100** waiting events per webhook; the oldest are dropped and counted.
- Retries for 5xx, timeouts and no network: **2, 4, 8, 16, 32 s** (the first attempt plus five retries).
- 404, 401, 403 stop the webhook; 400 (and any other 4xx but 429) drops the message.
- `allowed_mentions: {"parse": []}` on every message; no `content`, `embeds` or `username` (Settings tells the user to name the webhook "linkC").
- Tones: done green `0x57F287` ✅, needs-you yellow `0xFEE75C` ⚠️, failed red `0xED4245` ❌, info blurple `0x5865F2` 📋 (info posts with SUPPRESS_NOTIFICATIONS).
- Only a 200 whose JSON has a non-empty `id` counts as sent; every post adds `with_components=true&wait=true`.
- Keychain: generic password, service `com.linkc.app.discord-webhook`, account `default` or the canonical project folder.
- A project with its own webhook entry never falls back to the default.
- Tests go through seams only: `ScriptedWebhookTransport`, `ManualClock`, `InMemorySecretStore`, `InMemoryUserDefaults`. No network, no Keychain.
- Swift 6 strict concurrency; `swift build --build-tests 2>&1 | grep -E "warning:|error:"` must print nothing.
- No new dependencies. Mock data only in tests. Fail loud: no swallowed errors.
- Commit messages: conventional (`feat(discord): …`, `test(discord): …`), no trailers of any kind, no AI or tool names.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/LinkCKit/Discord/LinkCEvent.swift` (new) | the event value |
| `Sources/LinkCKit/Discord/DiscordMessage.swift` (new) | events → one webhook request body, within Discord's limits |
| `Sources/LinkCKit/Discord/SecretStore.swift` (new) | the secret seam and its Keychain implementation |
| `Sources/LinkCKit/Discord/DiscordWebhooks.swift` (new) | URL validation, the configured webhooks, routing |
| `Sources/LinkCKit/Preferences/AppPreferences.swift` | `discordProjects` |
| `Sources/LinkCKit/Discord/WebhookTransport.swift` (new) | the HTTP seam, its response, and the URLSession implementation |
| `Sources/LinkCKit/Discord/WebhookPacer.swift` (new) | the sliding window and Discord's rate-limit answers |
| `Sources/LinkCKit/Discord/WebhookQueue.swift` (new) | one webhook's queue, and `WebhookStatus` |
| `Sources/LinkCKit/Discord/DiscordNotifier.swift` (new) | queues per URL, global pause, stop notice, Settings actions |
| `Sources/LinkCKit/Discord/TaskEventFeed.swift` (new) | task state changes between relay passes → events |
| `Sources/LinkCKit/Notify/NotificationManager.swift` | `onEvent`, `postEvent`, `postLocal`, `project:`/`tone:` |
| `Sources/LinkCKit/App/AppCoordinator*.swift` | pass the folder at every alert; task and worker events; `onEvent`, `postLocalNotification` |
| `Sources/LinkCKit/Config/HealthMonitor.swift` | `HealthChange.tone` |
| `Sources/linkc/Screens/SettingsScreen.swift`, `Sources/linkc/LinkCApp.swift`, `README.md` | the DISCORD section and the wiring |

---

### Task 1: The event and the Discord message

**Files:**
- Create: `Sources/LinkCKit/Discord/LinkCEvent.swift`
- Create: `Sources/LinkCKit/Discord/DiscordMessage.swift`
- Test: `Tests/LinkCKitTests/DiscordMessageTests.swift`

**Interfaces:**
- Produces:
  - `public struct LinkCEvent: Equatable, Sendable` with `kind: Kind`, `tone: Tone`, `title`, `body`, `project: String?`, `at: Date`, and `init(kind:tone:title:body:project:at:)`;
  - `LinkCEvent.Kind` (`sessionState, alert, service, task, workerClosed`) and `LinkCEvent.Tone` (`done, needsYou, failed, info`);
  - `enum DiscordMessage` with `batch(_ events: [LinkCEvent], dropped: Int) -> (payload: Payload, taken: Int)`, `encode(_:) throws -> Data`, `embed(for:) -> Embed`, `cut(_:to:) -> String`, and the limit constants.

- [ ] **Step 1: Write the failing tests** in `Tests/LinkCKitTests/DiscordMessageTests.swift`:

```swift
import XCTest
@testable import LinkCKit

/// The body of one webhook request: what Discord shows, and the limits it enforces (spec §4.2, §5).
final class DiscordMessageTests: XCTestCase {
    private func event(
        _ title: String = "Codex · money-printer · finished", body: String = "", tone: LinkCEvent.Tone = .done,
        project: String? = "/Users/me/money-printer"
    ) -> LinkCEvent {
        LinkCEvent(kind: .sessionState, tone: tone, title: title, body: body, project: project,
                   at: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func json(_ payload: DiscordMessage.Payload) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: DiscordMessage.encode(payload)) as? [String: Any])
    }

    /// Text from a task or an agent can hold `@everyone`: no message may ping anyone.
    func testEveryMessageTurnsMentionsOff() throws {
        let body = try json(DiscordMessage.batch([event(body: "@everyone look")], dropped: 0).payload)
        XCTAssertEqual(body["allowed_mentions"] as? [String: [String]], ["parse": []])
        XCTAssertEqual(body["username"] as? String, "linkC")
    }

    func testAnEventIsOneEmbedWithItsProjectInTheFooter() {
        let embed = DiscordMessage.embed(for: event(body: "all green"))
        XCTAssertEqual(embed.title, "Codex · money-printer · finished")
        XCTAssertEqual(embed.description, "all green")
        XCTAssertEqual(embed.footer.text, "money-printer")
        XCTAssertEqual(embed.timestamp, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(DiscordMessage.embed(for: event(project: nil)).footer.text, "linkC")
        XCTAssertNil(DiscordMessage.embed(for: event(body: "")).description, "an empty body adds no description")
    }

    func testEachToneHasItsColor() {
        XCTAssertEqual(DiscordMessage.embed(for: event(tone: .done)).color, 0x3BA55C)
        XCTAssertEqual(DiscordMessage.embed(for: event(tone: .needsYou)).color, 0xFAA61A)
        XCTAssertEqual(DiscordMessage.embed(for: event(tone: .failed)).color, 0xED4245)
        XCTAssertEqual(DiscordMessage.embed(for: event(tone: .info)).color, 0x99AAB5)
    }

    func testLongFieldsAreCutWithAnEllipsis() {
        let embed = DiscordMessage.embed(for: event(
            String(repeating: "t", count: 300), body: String(repeating: "b", count: 5000)))
        XCTAssertEqual(embed.title.utf16.count, 256)
        XCTAssertTrue(embed.title.hasSuffix("…"))
        XCTAssertEqual(embed.description?.utf16.count, 4096)
        XCTAssertTrue(embed.description?.hasSuffix("…") ?? false)
    }

    /// Discord counts UTF-16 units: a body of emoji is cut by them, and never mid-character.
    func testCutsCountUTF16AndNeverSplitACharacter() throws {
        let description = try XCTUnwrap(DiscordMessage.embed(for: event(body: String(repeating: "🚀", count: 3000))).description)
        XCTAssertLessThanOrEqual(description.utf16.count, 4096)
        XCTAssertTrue(description.dropLast().allSatisfy { $0 == "🚀" })
        XCTAssertTrue(description.hasSuffix("…"))
    }

    func testABatchTakesAtMostTenEventsOldestFirst() {
        let events = (0..<30).map { event("event \($0)") }
        let (payload, taken) = DiscordMessage.batch(events, dropped: 0)
        XCTAssertEqual(taken, 10)
        XCTAssertEqual(payload.embeds.map(\.title), (0..<10).map { "event \($0)" })
    }

    func testABatchStaysWithinSixThousandCharacters() {
        let events = (0..<3).map { event("e\($0)", body: String(repeating: "x", count: 2500)) }
        let (payload, taken) = DiscordMessage.batch(events, dropped: 0)
        XCTAssertEqual(taken, 2)
        XCTAssertLessThanOrEqual(payload.embeds.map(\.characterCount).reduce(0, +), 6000)
    }

    /// The description gives way first, so one event always fits a message on its own.
    func testOneHugeEventStillFitsAMessageAlone() {
        let huge = event(String(repeating: "t", count: 256), body: String(repeating: "x", count: 10_000),
                         project: "/p/" + String(repeating: "f", count: 3000))
        let (payload, taken) = DiscordMessage.batch([huge], dropped: 0)
        XCTAssertEqual(taken, 1)
        XCTAssertLessThanOrEqual(payload.embeds[0].characterCount, 6000)
        XCTAssertEqual(payload.embeds[0].footer.text.utf16.count, 2048)
    }

    func testDroppedEventsAreCountedInTheMessage() throws {
        XCTAssertEqual(DiscordMessage.batch([event()], dropped: 3).payload.content,
                       "3 earlier events were not posted (Discord was rate limiting).")
        XCTAssertEqual(DiscordMessage.batch([event()], dropped: 1).payload.content,
                       "1 earlier event was not posted (Discord was rate limiting).")
        let plain = try json(DiscordMessage.batch([event()], dropped: 0).payload)
        XCTAssertNil(plain["content"], "no line when nothing was dropped")
    }
}
```

- [ ] **Step 2: Run them to see them fail.** `swift test --filter DiscordMessageTests` fails to compile: `LinkCEvent` and `DiscordMessage` don't exist.

- [ ] **Step 3: Implement.** `Sources/LinkCKit/Discord/LinkCEvent.swift`:

```swift
import Foundation

/// Something that happened in linkC that the user may want to hear about away from the Mac: what
/// linkC posts to Discord (spec 2026-11-05 §2). `project` is the canonical folder it belongs to,
/// nil for an event that belongs to no project (a watched service).
public struct LinkCEvent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// An agent finished, needs permission, is waiting for input, or ended with an error.
        case sessionState
        /// Any other alert linkC shows as a macOS notification.
        case alert
        /// A watched service went down or came back.
        case service
        /// A task became delivered, done, failed, expired or cancelled. Discord only.
        case task
        /// linkC closed a worker. Discord only.
        case workerClosed
    }

    /// How the event reads at a glance; it sets the color.
    public enum Tone: Equatable, Sendable {
        case done, needsYou, failed, info
    }

    public let kind: Kind
    public let tone: Tone
    public let title: String
    public let body: String
    public let project: String?
    public let at: Date

    public init(kind: Kind, tone: Tone, title: String, body: String, project: String?, at: Date) {
        self.kind = kind
        self.tone = tone
        self.title = title
        self.body = body
        self.project = project
        self.at = at
    }
}
```

`Sources/LinkCKit/Discord/DiscordMessage.swift`:

```swift
import Foundation

/// The JSON body of one webhook request: the oldest waiting events, one embed each, within Discord's
/// limits (spec §4.2, §5). Discord counts characters in UTF-16 units, so every limit here does too.
enum DiscordMessage {
    static let maxEmbeds = 10
    /// Discord's limit on the characters of all embeds in one message together.
    static let maxTotalCharacters = 6000
    static let maxTitle = 256
    static let maxDescription = 4096
    static let maxFooter = 2048

    struct Footer: Encodable, Equatable {
        let text: String
    }

    struct Embed: Encodable, Equatable {
        let title: String
        let description: String?
        let color: Int
        let footer: Footer
        let timestamp: String

        /// What counts toward `maxTotalCharacters`.
        var characterCount: Int { title.utf16.count + (description?.utf16.count ?? 0) + footer.text.utf16.count }
    }

    struct AllowedMentions: Encodable, Equatable {
        let parse: [String]
    }

    struct Payload: Encodable, Equatable {
        let username: String
        let content: String?
        let allowedMentions: AllowedMentions
        let embeds: [Embed]

        enum CodingKeys: String, CodingKey {
            case username, content, embeds
            case allowedMentions = "allowed_mentions"
        }
    }

    static func color(for tone: LinkCEvent.Tone) -> Int {
        switch tone {
        case .done: 0x3BA55C
        case .needsYou: 0xFAA61A
        case .failed: 0xED4245
        case .info: 0x99AAB5
        }
    }

    static func embed(for event: LinkCEvent) -> Embed {
        let title = cut(event.title, to: maxTitle)
        let footer = cut(event.project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "linkC", to: maxFooter)
        // One embed always fits a message on its own: the description gives way first.
        let room = min(maxDescription, maxTotalCharacters - title.utf16.count - footer.utf16.count)
        let description = event.body.isEmpty ? nil : cut(event.body, to: room)
        return Embed(title: title, description: description, color: color(for: event.tone),
                     footer: Footer(text: footer), timestamp: timestamp(event.at))
    }

    /// The message for the oldest of `events` that fit, and how many it took: at least one when
    /// `events` isn't empty. `dropped` events that never made it into a message are counted in it.
    static func batch(_ events: [LinkCEvent], dropped: Int) -> (payload: Payload, taken: Int) {
        var embeds: [Embed] = []
        var characters = 0
        for event in events.prefix(maxEmbeds) {
            let embed = embed(for: event)
            guard embeds.isEmpty || characters + embed.characterCount <= maxTotalCharacters else { break }
            embeds.append(embed)
            characters += embed.characterCount
        }
        let content = dropped > 0
            ? "\(dropped) earlier event\(dropped == 1 ? " was" : "s were") not posted (Discord was rate limiting)."
            : nil
        let payload = Payload(username: "linkC", content: content, allowedMentions: AllowedMentions(parse: []),
                              embeds: embeds)
        return (payload, embeds.count)
    }

    static func encode(_ payload: Payload) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    /// `text`, cut to at most `limit` UTF-16 units with an ellipsis, never inside a character.
    static func cut(_ text: String, to limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var kept = ""
        var units = 0
        for character in text {
            let width = character.utf16.count
            guard units + width <= limit - 1 else { break }
            kept.append(character)
            units += width
        }
        return kept + "…"
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 4: Run the tests.** `swift test --filter DiscordMessageTests` passes, and the build shows no warnings.

- [ ] **Step 5: Commit.** Tests first (`test(discord): the event and the Discord message`), then the implementation (`feat(discord): the event and the Discord message`).

---

### Task 2: Webhook URLs, the Keychain and routing

**Files:**
- Create: `Sources/LinkCKit/Discord/SecretStore.swift`
- Create: `Sources/LinkCKit/Discord/DiscordWebhooks.swift`
- Modify: `Sources/LinkCKit/Preferences/AppPreferences.swift`
- Create: `Tests/LinkCKitTests/Support/InMemorySecretStore.swift`
- Test: `Tests/LinkCKitTests/DiscordWebhooksTests.swift`

**Interfaces:**
- Consumes: `LinkCEvent` (Task 1).
- Produces:
  - `public protocol SecretStore: Sendable`, with `secret(service:account:) throws -> String?`, `setSecret(_:service:account:) throws` and `deleteSecret(service:account:) throws`;
  - `public struct KeychainSecretStore: SecretStore` with `init()` and `Failure` (an OSStatus);
  - `public struct DiscordWebhookURL: Equatable, Sendable` with `url`, `id`, and `static func parse(_:) -> Result<DiscordWebhookURL, Refusal>`;
  - `public enum DiscordWebhookState: Equatable, Sendable` (`notSet`, `set(DiscordWebhookURL)`, `missing`, `unreadable(String)`);
  - `public enum DiscordRoute: Equatable` (`webhook(account: String, DiscordWebhookURL)`, `none(reason: String?)`);
  - `@MainActor @Observable public final class DiscordWebhooks` with `init(secrets:preferences:)`, `static let service`, `static let defaultAccount`, `projects`, `state(for:)`, `reload()`, `set(_:for:) throws -> DiscordWebhookURL`, `remove(_:) throws` and `route(_:) -> DiscordRoute`;
  - `AppPreferences.discordProjects: [String]`.

- [ ] **Step 1: Write the failing tests.** `Tests/LinkCKitTests/Support/InMemorySecretStore.swift`:

```swift
import Foundation
@testable import LinkCKit

/// A `SecretStore` for tests: secrets in memory, never the Keychain. While `failure` is set, every
/// call throws it.
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var storedFailure: Error?

    var failure: Error? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }

    var count: Int { lock.withLock { items.count } }

    private func key(_ service: String, _ account: String) -> String { service + "\u{0}" + account }

    func secret(service: String, account: String) throws -> String? {
        try lock.withLock {
            if let storedFailure { throw storedFailure }
            return items[key(service, account)]
        }
    }

    func setSecret(_ value: String, service: String, account: String) throws {
        try lock.withLock {
            if let storedFailure { throw storedFailure }
            items[key(service, account)] = value
        }
    }

    func deleteSecret(service: String, account: String) throws {
        try lock.withLock {
            if let storedFailure { throw storedFailure }
            items[key(service, account)] = nil
        }
    }
}
```

`Tests/LinkCKitTests/DiscordWebhooksTests.swift`:

```swift
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
```

- [ ] **Step 2: Run them to see them fail.** `swift test --filter DiscordWebhooksTests` fails to compile.

- [ ] **Step 3: Implement.** In `AppPreferences.swift`:
  - add `static let discordProjects = "discordWebhookProjects"` to `Keys`;
  - add, after `linkCApps`:

```swift
    /// The project folders (canonical) that have a Discord webhook of their own. The URLs are secrets
    /// and live only in the Keychain (`DiscordWebhooks`).
    public var discordProjects: [String] {
        didSet { defaults.set(discordProjects, forKey: Keys.discordProjects) }
    }
```

  - and in `init`, before `self.linkCApps = apps`:

```swift
        self.discordProjects = defaults.object(forKey: Keys.discordProjects) as? [String] ?? []
```

`Sources/LinkCKit/Discord/SecretStore.swift`:

```swift
import Foundation
import Security

/// Where linkC keeps a secret it holds itself: only Discord webhook URLs (spec 2026-11-05 §1, §6).
/// The Keychain in the app; an in-memory store in tests.
public protocol SecretStore: Sendable {
    /// The secret, or nil when there is none.
    func secret(service: String, account: String) throws -> String?
    func setSecret(_ value: String, service: String, account: String) throws
    /// Removes the secret; one already gone is fine.
    func deleteSecret(service: String, account: String) throws
}

/// One Keychain generic password per secret, in the user's login keychain.
public struct KeychainSecretStore: SecretStore {
    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus

        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(message)"
        }
    }

    public init() {}

    private func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func secret(service: String, account: String) throws -> String? {
        var query = query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw Failure(status: errSecDecode)
        }
        return text
    }

    public func setSecret(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(service: service, account: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(service: service, account: account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
            return
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func deleteSecret(service: String, account: String) throws {
        let status = SecItemDelete(query(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
```

`Sources/LinkCKit/Discord/DiscordWebhooks.swift`:

```swift
import Foundation
import Observation

/// A webhook URL linkC accepts: `https://` on Discord's own hosts, with the path
/// `/api/webhooks/<numeric id>/<token>` and nothing after it (spec §6).
public struct DiscordWebhookURL: Equatable, Sendable {
    public let url: URL
    /// The webhook's numeric id: what Settings shows, never the URL.
    public let id: String

    public static let hosts: Set<String> = ["discord.com", "discordapp.com", "canary.discord.com", "ptb.discord.com"]

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ text: String) -> Result<DiscordWebhookURL, Refusal> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let shape = "a webhook URL looks like https://discord.com/api/webhooks/<id>/<token>"
        guard let components = URLComponents(string: trimmed), let url = URL(string: trimmed) else {
            return .failure(Refusal(description: "that is not a URL: \(shape)"))
        }
        guard components.scheme == "https" else {
            return .failure(Refusal(description: "a webhook URL starts with https://"))
        }
        guard let host = components.host?.lowercased(), hosts.contains(host) else {
            return .failure(Refusal(description: "a webhook URL is on discord.com"))
        }
        guard components.port == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            return .failure(Refusal(description: shape))
        }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0].isEmpty, parts[1] == "api", parts[2] == "webhooks" else {
            return .failure(Refusal(description: shape))
        }
        let id = parts[3], token = parts[4]
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return .failure(Refusal(description: "the webhook id is a number: \(shape)"))
        }
        guard !token.isEmpty, token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            return .failure(Refusal(description: "the webhook token is missing or malformed: \(shape)"))
        }
        return .success(DiscordWebhookURL(url: url, id: id))
    }
}

/// One webhook as linkC last read it from the Keychain.
public enum DiscordWebhookState: Equatable, Sendable {
    case notSet
    case set(DiscordWebhookURL)
    /// Listed for a project, but its Keychain item is gone.
    case missing
    /// The Keychain could not be read, or holds something that is not a webhook URL.
    case unreadable(String)
}

/// Where an event goes (spec §3).
public enum DiscordRoute: Equatable {
    case webhook(account: String, DiscordWebhookURL)
    /// Not posted: no webhook applies (`reason` nil), or the one that applies can't be used.
    case none(reason: String?)
}

/// The Discord webhooks the user set: a default, and one per project folder (spec §3, §6). Each URL
/// is a Keychain item under `service`, account `defaultAccount` or the canonical folder;
/// `AppPreferences.discordProjects` lists the folders that have one, with no URLs. The Keychain is
/// read when linkC starts and on `reload()`, not for every event.
@MainActor
@Observable
public final class DiscordWebhooks {
    public static let service = "com.linkc.app.discord-webhook"
    public static let defaultAccount = "default"

    @ObservationIgnored private let secrets: SecretStore
    @ObservationIgnored private let preferences: AppPreferences
    private var states: [String: DiscordWebhookState] = [:]

    public init(secrets: SecretStore, preferences: AppPreferences) {
        self.secrets = secrets
        self.preferences = preferences
        reload()
    }

    /// The project folders that have a webhook of their own.
    public var projects: [String] { preferences.discordProjects }

    public func state(for account: String) -> DiscordWebhookState {
        states[account] ?? .notSet
    }

    /// Reads the default webhook and every listed project's again.
    public func reload() {
        var loaded: [String: DiscordWebhookState] = [:]
        for account in [Self.defaultAccount] + preferences.discordProjects {
            loaded[account] = read(account, listed: account != Self.defaultAccount)
        }
        states = loaded
    }

    /// Stores `text` for `account` (the default, or a canonical project folder) once it parses.
    @discardableResult
    public func set(_ text: String, for account: String) throws -> DiscordWebhookURL {
        let webhook = try DiscordWebhookURL.parse(text).get()
        try secrets.setSecret(webhook.url.absoluteString, service: Self.service, account: account)
        if account != Self.defaultAccount, !preferences.discordProjects.contains(account) {
            preferences.discordProjects.append(account)
        }
        states[account] = .set(webhook)
        return webhook
    }

    public func remove(_ account: String) throws {
        try secrets.deleteSecret(service: Self.service, account: account)
        preferences.discordProjects.removeAll { $0 == account }
        states[account] = nil
    }

    /// Where `event` goes: its project's webhook when the project has its own entry, else the default.
    /// A project with its own entry never falls back, even when its webhook can't be used.
    public func route(_ event: LinkCEvent) -> DiscordRoute {
        let account = event.project.flatMap { preferences.discordProjects.contains($0) ? $0 : nil }
            ?? Self.defaultAccount
        switch state(for: account) {
        case .set(let webhook): return .webhook(account: account, webhook)
        case .notSet: return .none(reason: nil)
        case .missing: return .none(reason: "this project's webhook is missing — set it again")
        case .unreadable(let reason): return .none(reason: reason)
        }
    }

    private func read(_ account: String, listed: Bool) -> DiscordWebhookState {
        do {
            guard let text = try secrets.secret(service: Self.service, account: account) else {
                return listed ? .missing : .notSet
            }
            switch DiscordWebhookURL.parse(text) {
            case .success(let webhook): return .set(webhook)
            case .failure(let refusal): return .unreadable("the stored webhook is not valid: \(refusal)")
            }
        } catch {
            return .unreadable("the Keychain could not be read: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 4: Run the tests.** `swift test --filter "DiscordWebhooksTests|AppPreferencesTests"` passes, with no warnings.

- [ ] **Step 5: Commit.** Tests first (`test(discord): webhook URLs, the secret store and routing`), then `feat(discord): webhook URLs in the Keychain, and routing by project`.

---

### Task 3: The pacer and the queue

**Files:**
- Create: `Sources/LinkCKit/Discord/WebhookTransport.swift`
- Create: `Sources/LinkCKit/Discord/WebhookPacer.swift`
- Create: `Sources/LinkCKit/Discord/WebhookQueue.swift`
- Create: `Tests/LinkCKitTests/Support/ScriptedWebhookTransport.swift`
- Test: `Tests/LinkCKitTests/WebhookPacerTests.swift`, `Tests/LinkCKitTests/WebhookQueueTests.swift`

**Interfaces:**
- Consumes: `LinkCEvent`, `DiscordMessage` (Task 1).
- Produces:
  - `public struct WebhookResponse` (`status`, lowercased `headers`, `body`);
  - `public protocol WebhookTransport: Sendable { func post(_ body: Data, to url: URL) async throws -> WebhookResponse }`;
  - `struct WebhookPacer<Instant>` with `readyAt(_:)`, `recordSend(at:)` and `block(until:)`;
  - `struct DiscordRateLimit` with `read(_:)`, `exhaustedFor`, `retryAfter` and `global`;
  - `public enum WebhookStatus` (`idle`, `posted(at:)`, `waiting(until:)`, `stopped(status:)`, `failed(_:at:)`, `missing`);
  - `@MainActor final class WebhookQueue<C: Clock>` with:
    - `init(name:url:transport:clock:wallClock:)`;
    - `enqueue(_:)`, `pause(for:)`, `cancel()`;
    - `status`, `isStopped`;
    - `onStatus`, `onGlobalLimit`, `onStopped`.

- [ ] **Step 1: Write the failing tests.** `Tests/LinkCKitTests/Support/ScriptedWebhookTransport.swift`:

```swift
import Foundation
@testable import LinkCKit

/// A `WebhookTransport` for tests: records every request and answers from a script, oldest first.
/// Once the script runs out, every request is answered 204.
final class ScriptedWebhookTransport: WebhookTransport, @unchecked Sendable {
    struct Request {
        let url: URL
        let body: Data

        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }

        var embedTitles: [String] {
            (json["embeds"] as? [[String: Any]])?.compactMap { $0["title"] as? String } ?? []
        }
    }

    private let lock = NSLock()
    private var script: [Result<WebhookResponse, Error>]
    private var recorded: [Request] = []

    init(_ script: [Result<WebhookResponse, Error>] = []) {
        self.script = script
    }

    var requests: [Request] { lock.withLock { recorded } }

    func post(_ body: Data, to url: URL) async throws -> WebhookResponse {
        let answer: Result<WebhookResponse, Error> = lock.withLock {
            recorded.append(Request(url: url, body: body))
            return script.isEmpty ? .success(WebhookResponse(status: 204)) : script.removeFirst()
        }
        return try answer.get()
    }
}
```

`Tests/LinkCKitTests/WebhookPacerTests.swift`:

```swift
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
}
```

`Tests/LinkCKitTests/WebhookQueueTests.swift`:

```swift
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
        try await until("the batch goes") { transport.requests.count == 6 }
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
}
```

- [ ] **Step 2: Run them to see them fail.** `swift test --filter "WebhookPacerTests|WebhookQueueTests"` fails to compile.

- [ ] **Step 3: Implement.** `Sources/LinkCKit/Discord/WebhookTransport.swift`:

```swift
import Foundation

/// One webhook response: what the queue reads from it (spec §4.4). Header names are lowercased.
public struct WebhookResponse: Equatable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        self.body = body
    }
}

/// The seam every webhook request goes through: URLSession in the app, a script in tests.
public protocol WebhookTransport: Sendable {
    func post(_ body: Data, to url: URL) async throws -> WebhookResponse
}
```

`Sources/LinkCKit/Discord/WebhookPacer.swift`:

```swift
import Foundation

/// When the next request to one webhook may go (spec §4.1): fewer than `limit` requests in the last
/// `window`, and no wait Discord asked for still running. Pure: the queue gives it the clock.
struct WebhookPacer<Instant: InstantProtocol> where Instant.Duration == Duration {
    let limit: Int
    let window: Duration
    /// The send times of the recent requests, oldest first.
    private var sends: [Instant] = []
    private var blockedUntil: Instant?

    init(limit: Int = 5, window: Duration = .seconds(2)) {
        self.limit = limit
        self.window = window
    }

    /// The earliest instant at or after `now` the next request may go.
    func readyAt(_ now: Instant) -> Instant {
        var ready = now
        let recent = sends.filter { now < $0.advanced(by: window) }
        if recent.count >= limit {
            // Once `limit` requests are in the window, the next goes when the oldest of them leaves it.
            ready = max(ready, recent[recent.count - limit].advanced(by: window))
        }
        if let blockedUntil {
            ready = max(ready, blockedUntil)
        }
        return ready
    }

    /// Counts a request, answered or not.
    mutating func recordSend(at instant: Instant) {
        sends.removeAll { $0.advanced(by: window) <= instant }
        sends.append(instant)
    }

    /// Holds every request until `instant`. A shorter block never shortens a longer one.
    mutating func block(until instant: Instant) {
        if let blockedUntil, instant <= blockedUntil { return }
        blockedUntil = instant
    }
}

/// What a webhook response says about Discord's rate limits (spec §4.1). Discord says its limits
/// change and must be read, not hard-coded, so these can only make the pacer stricter.
struct DiscordRateLimit: Equatable {
    /// `X-RateLimit-Remaining: 0`: wait `X-RateLimit-Reset-After` before the next request.
    var exhaustedFor: Duration?
    /// A 429: wait this long, then resend.
    var retryAfter: Duration?
    /// A 429 for Discord's global, per-IP limit.
    var global = false

    /// The wait for a 429 that gives none: an odd answer, so a long, safe one.
    static let defaultRetryAfter: Duration = .seconds(5)

    static func read(_ response: WebhookResponse) -> DiscordRateLimit {
        var limit = DiscordRateLimit()
        if response.headers["x-ratelimit-remaining"] == "0",
           let reset = response.headers["x-ratelimit-reset-after"].flatMap(Double.init) {
            limit.exhaustedFor = duration(seconds: reset)
        }
        guard response.status == 429 else { return limit }
        // A 429 body is JSON; one that isn't leaves the headers to say how long to wait.
        let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        if let seconds = (body?["retry_after"] as? Double) ?? response.headers["retry-after"].flatMap(Double.init) {
            limit.retryAfter = duration(seconds: seconds)
        } else {
            limit.retryAfter = defaultRetryAfter
        }
        limit.global = (body?["global"] as? Bool) == true || response.headers["x-ratelimit-global"]?.lowercased() == "true"
        return limit
    }

    private static func duration(seconds: Double) -> Duration {
        .milliseconds(Int((max(0, seconds) * 1000).rounded()))
    }
}
```

`Sources/LinkCKit/Discord/WebhookQueue.swift`:

```swift
import Foundation

/// What Settings shows for a webhook (spec §6).
public enum WebhookStatus: Equatable, Sendable {
    /// Nothing posted since linkC started.
    case idle
    case posted(at: Date)
    /// Holding a message until Discord's limits allow it, or until a retry.
    case waiting(until: Date)
    /// Discord answered 404, 401 or 403: the webhook is deleted or invalid. Nothing more is sent until
    /// its URL is set again or a test succeeds.
    case stopped(status: Int)
    /// The last message could not be posted.
    case failed(String, at: Date)
    /// A project's webhook is listed but its Keychain item is gone.
    case missing
}

/// One webhook's queue (spec §4): events go out oldest first, one request at a time, packed up to
/// Discord's limits, paced by `WebhookPacer`, then resent, dropped or stopped by Discord's answer.
/// `name` is "default" or the project folder's name: logs never carry the URL.
@MainActor
final class WebhookQueue<C: Clock> where C.Duration == Duration {
    static var maxPending: Int { 100 }
    /// The waits before each retry of a message Discord didn't answer: the first attempt plus five.
    static var retryDelays: [Duration] { [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32)] }

    let name: String
    let url: URL
    private let transport: WebhookTransport
    private let clock: C
    private let wallClock: () -> Date
    private var pacer: WebhookPacer<C.Instant>
    private var pending: [LinkCEvent] = []
    private var dropped = 0
    private var runner: Task<Void, Never>?

    private(set) var status: WebhookStatus = .idle {
        didSet { if status != oldValue { onStatus?(status) } }
    }

    var onStatus: ((WebhookStatus) -> Void)?
    /// A 429 for Discord's global, per-IP limit: `DiscordNotifier` pauses every queue for this long.
    var onGlobalLimit: ((Duration) -> Void)?
    /// Discord answered 404, 401 or 403: this webhook is done.
    var onStopped: ((Int) -> Void)?

    init(name: String, url: URL, transport: WebhookTransport, clock: C, wallClock: @escaping () -> Date = Date.init) {
        self.name = name
        self.url = url
        self.transport = transport
        self.clock = clock
        self.wallClock = wallClock
        self.pacer = WebhookPacer()
    }

    var isStopped: Bool {
        if case .stopped = status { return true }
        return false
    }

    /// Queues `event` for the next message. A stopped webhook takes nothing.
    func enqueue(_ event: LinkCEvent) {
        guard !isStopped else { return }
        pending.append(event)
        if pending.count > Self.maxPending {
            let excess = pending.count - Self.maxPending
            pending.removeFirst(excess)
            dropped += excess
        }
        guard runner == nil else { return }
        runner = Task { [weak self] in await self?.drain() }
    }

    /// Holds the next request for `duration`: Discord's global limit, reported by any queue.
    func pause(for duration: Duration) {
        pacer.block(until: clock.now.advanced(by: duration))
    }

    /// Stops sending, for good: the queue is being replaced or linkC is quitting.
    func cancel() {
        runner?.cancel()
        runner = nil
    }

    private func drain() async {
        defer { runner = nil }
        while !pending.isEmpty, !isStopped, !Task.isCancelled {
            await waitForTurn()
            guard !Task.isCancelled, !isStopped, !pending.isEmpty else { return }
            // Packed now, as it goes: everything that arrived during the wait rides along.
            let (payload, taken) = DiscordMessage.batch(pending, dropped: dropped)
            pending.removeFirst(taken)
            dropped = 0
            let body: Data
            do {
                body = try DiscordMessage.encode(payload)
            } catch {
                NSLog("[linkC discord] %@: a message could not be encoded — %@", name, error.localizedDescription)
                status = .failed("a message could not be encoded: \(error.localizedDescription)", at: wallClock())
                continue
            }
            await deliver(body)
        }
    }

    /// Sends one message until Discord takes it, refuses it, stops the webhook, or the retries run out
    /// (spec §4.4).
    private func deliver(_ body: Data) async {
        var failures = 0
        while !Task.isCancelled {
            await waitForTurn()
            guard !Task.isCancelled else { return }
            pacer.recordSend(at: clock.now)
            let response: WebhookResponse
            do {
                response = try await transport.post(body, to: url)
            } catch {
                guard !Task.isCancelled, await retry(&failures, because: "no answer: \(error.localizedDescription)") else { return }
                continue
            }
            let limits = DiscordRateLimit.read(response)
            if let exhausted = limits.exhaustedFor {
                pacer.block(until: clock.now.advanced(by: exhausted))
            }
            switch response.status {
            case 200..<300:
                status = .posted(at: wallClock())
                return
            case 429:
                let wait = limits.retryAfter ?? DiscordRateLimit.defaultRetryAfter
                pacer.block(until: clock.now.advanced(by: wait))
                if limits.global { onGlobalLimit?(wait) }
            case 401, 403, 404:
                pending.removeAll()
                dropped = 0
                NSLog("[linkC discord] %@: Discord answered %d, so this webhook is stopped", name, response.status)
                status = .stopped(status: response.status)
                onStopped?(response.status)
                return
            case 400..<500:
                let detail = String(decoding: response.body.prefix(500), as: UTF8.self)
                NSLog("[linkC discord] %@: Discord refused a message (%d) — %@", name, response.status, detail)
                status = .failed("Discord refused a message (\(response.status)): \(detail)", at: wallClock())
                return
            default:
                guard await retry(&failures, because: "Discord answered \(response.status)") else { return }
            }
        }
    }

    /// Waits out the next retry delay. False once every delay was used: the message is dropped.
    private func retry(_ failures: inout Int, because reason: String) async -> Bool {
        guard failures < Self.retryDelays.count else {
            NSLog("[linkC discord] %@: a message was dropped after %d retries — %@", name, failures, reason)
            status = .failed("a message was dropped after \(failures) retries: \(reason)", at: wallClock())
            return false
        }
        let delay = Self.retryDelays[failures]
        failures += 1
        status = .waiting(until: wallClock().addingTimeInterval(delay.seconds))
        do {
            try await clock.sleep(for: delay)
        } catch {
            return false
        }
        return true
    }

    /// Sleeps until the pacer lets the next request go. It reads the pacer again after each sleep, as a
    /// global pause can arrive meanwhile.
    private func waitForTurn() async {
        while !Task.isCancelled {
            let now = clock.now
            let ready = pacer.readyAt(now)
            guard now < ready else { return }
            status = .waiting(until: wallClock().addingTimeInterval(now.duration(to: ready).seconds))
            do {
                try await clock.sleep(until: ready, tolerance: nil)
            } catch {
                return
            }
        }
    }
}

extension Duration {
    /// The duration in seconds, for `Date` arithmetic.
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
```

- [ ] **Step 4: Run the tests.** `swift test --filter "WebhookPacerTests|WebhookQueueTests"` passes, with no warnings.

- [ ] **Step 5: Commit.** Tests first (`test(discord): the sliding window, Discord's rate limits and the webhook queue`), then `feat(discord): a webhook queue paced by a sliding window and Discord's answers`.

---

### Task 4: The notifier and the real transport

**Files:**
- Create: `Sources/LinkCKit/Discord/DiscordNotifier.swift`
- Modify: `Sources/LinkCKit/Discord/WebhookTransport.swift` (add `URLSessionWebhookTransport`)
- Test: `Tests/LinkCKitTests/DiscordNotifierTests.swift`

**Interfaces:**
- Consumes: Tasks 1 to 3.
- Produces:
  - `@MainActor @Observable public final class DiscordNotifier<C: Clock>` with:
    - `init(webhooks:transport:clock:wallClock:notifyUser:)`;
    - `webhooks`;
    - `post(_ event: LinkCEvent)`;
    - `set(_:for:) throws`, `remove(_:) throws`, `sendTest(to:) throws`;
    - `status(for:) -> WebhookStatus`;
    - `shutdown()`;
  - `public func WebhookStatus.label(now: Date) -> String`;
  - `public struct URLSessionWebhookTransport: WebhookTransport` with `init()`.

- [ ] **Step 1: Write the failing tests** in `Tests/LinkCKitTests/DiscordNotifierTests.swift`:

```swift
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
```

- [ ] **Step 2: Run them to see them fail.** `swift test --filter DiscordNotifierTests` fails to compile.

- [ ] **Step 3: Implement.** Append to `Sources/LinkCKit/Discord/WebhookTransport.swift`:

```swift
/// The real transport: an ephemeral session, a 10 s timeout, and no redirects (a webhook that
/// redirects is not Discord's). Errors are reported by their description only: a `URLError`'s
/// `userInfo` holds the URL, which is a secret.
public struct URLSessionWebhookTransport: WebhookTransport {
    public struct Failure: Error, LocalizedError {
        public let errorDescription: String?
    }

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    public func post(_ body: Data, to url: URL) async throws -> WebhookResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure(errorDescription: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure(errorDescription: "the answer was not HTTP")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return WebhookResponse(status: http.statusCode, headers: headers, body: data)
    }
}
```

`Sources/LinkCKit/Discord/DiscordNotifier.swift`:

```swift
import Foundation
import Observation

/// Posts linkC's events to the user's Discord webhooks (spec 2026-11-05). It routes each event (§3),
/// keeps one `WebhookQueue` per webhook URL, passes a global 429 to every queue (§4.1), tells the user
/// once when a webhook stops (§4.4), and keeps each webhook's status for Settings (§6).
@MainActor
@Observable
public final class DiscordNotifier<C: Clock> where C.Duration == Duration {
    public struct NoWebhook: Error, LocalizedError {
        public var errorDescription: String? { "No webhook is set." }
    }

    public let webhooks: DiscordWebhooks
    /// Each queue's status, by webhook URL.
    private var queueStatus: [String: WebhookStatus] = [:]
    @ObservationIgnored private var queues: [String: WebhookQueue<C>] = [:]
    /// The end of the last global 429's wait, so a queue made during it waits too.
    @ObservationIgnored private var globalPauseUntil: C.Instant?
    @ObservationIgnored private let transport: WebhookTransport
    @ObservationIgnored private let clock: C
    @ObservationIgnored private let wallClock: () -> Date
    @ObservationIgnored private let notifyUser: (String, String) -> Void

    /// `notifyUser` posts a macOS notification that is never forwarded to Discord.
    public init(webhooks: DiscordWebhooks, transport: WebhookTransport, clock: C,
                wallClock: @escaping () -> Date = Date.init, notifyUser: @escaping (String, String) -> Void) {
        self.webhooks = webhooks
        self.transport = transport
        self.clock = clock
        self.wallClock = wallClock
        self.notifyUser = notifyUser
    }

    public func post(_ event: LinkCEvent) {
        guard case .webhook(let account, let webhook) = webhooks.route(event) else { return }
        queue(for: webhook, account: account).enqueue(event)
    }

    /// Stores a webhook for `account` and starts it fresh, a stopped one included (Settings' Set).
    public func set(_ text: String, for account: String) throws {
        let webhook = try webhooks.set(text, for: account)
        replaceQueue(for: webhook, account: account)
    }

    public func remove(_ account: String) throws {
        guard case .set(let webhook) = webhooks.state(for: account) else {
            try webhooks.remove(account)
            return
        }
        try webhooks.remove(account)
        // Another account may still use the same URL: its queue stays.
        let stillUsed = ([DiscordWebhooks.defaultAccount] + webhooks.projects).contains {
            webhooks.state(for: $0) == .set(webhook)
        }
        if !stillUsed {
            let key = webhook.url.absoluteString
            queues[key]?.cancel()
            queues[key] = nil
            queueStatus[key] = nil
        }
    }

    /// Settings' Send test: one "linkC is connected" event through a fresh queue. A test restarts a
    /// stopped webhook (spec §4.4).
    public func sendTest(to account: String) throws {
        guard case .set(let webhook) = webhooks.state(for: account) else { throw NoWebhook() }
        let label = account == DiscordWebhooks.defaultAccount ? "every project without its own webhook" : Self.name(of: account)
        replaceQueue(for: webhook, account: account).enqueue(LinkCEvent(
            kind: .alert, tone: .done, title: "linkC is connected",
            body: "Events for \(label) will be posted here.",
            project: account == DiscordWebhooks.defaultAccount ? nil : account, at: wallClock()))
    }

    /// What Settings shows for `account`'s webhook.
    public func status(for account: String) -> WebhookStatus {
        switch webhooks.state(for: account) {
        case .set(let webhook): queueStatus[webhook.url.absoluteString] ?? .idle
        case .notSet: .idle
        case .missing: .missing
        case .unreadable(let reason): .failed(reason, at: wallClock())
        }
    }

    /// Stops every queue: linkC is quitting.
    public func shutdown() {
        queues.values.forEach { $0.cancel() }
        queues.removeAll()
    }

    /// "default", or the project folder's name: how logs and notices name a webhook, never by its URL.
    static func name(of account: String) -> String {
        account == DiscordWebhooks.defaultAccount ? "default" : URL(fileURLWithPath: account).lastPathComponent
    }

    private func queue(for webhook: DiscordWebhookURL, account: String) -> WebhookQueue<C> {
        queues[webhook.url.absoluteString] ?? replaceQueue(for: webhook, account: account)
    }

    @discardableResult
    private func replaceQueue(for webhook: DiscordWebhookURL, account: String) -> WebhookQueue<C> {
        let key = webhook.url.absoluteString
        queues[key]?.cancel()
        let name = Self.name(of: account)
        let queue = WebhookQueue(name: name, url: webhook.url, transport: transport, clock: clock, wallClock: wallClock)
        queue.onStatus = { [weak self] status in self?.queueStatus[key] = status }
        queue.onGlobalLimit = { [weak self] wait in self?.pauseEveryQueue(for: wait) }
        queue.onStopped = { [weak self] status in
            self?.notifyUser("linkC stopped posting to Discord",
                             "The \(name) webhook answered \(status): it was deleted or is no longer valid. "
                                + "Set it again in Settings > Discord.")
        }
        if let globalPauseUntil {
            let now = clock.now
            if now < globalPauseUntil { queue.pause(for: now.duration(to: globalPauseUntil)) }
        }
        queues[key] = queue
        queueStatus[key] = .idle
        return queue
    }

    private func pauseEveryQueue(for wait: Duration) {
        globalPauseUntil = clock.now.advanced(by: wait)
        queues.values.forEach { $0.pause(for: wait) }
    }
}

extension WebhookStatus {
    /// The status line Settings shows under a webhook (spec §6).
    public func label(now: Date) -> String {
        switch self {
        case .idle:
            return "Not posted yet"
        case .posted(let at):
            let seconds = Int(now.timeIntervalSince(at))
            if seconds < 60 { return "Posted just now" }
            if seconds < 3600 { return "Posted \(seconds / 60)m ago" }
            return "Posted \(seconds / 3600)h ago"
        case .waiting(let until):
            return "Waiting \(max(1, Int(until.timeIntervalSince(now).rounded(.up))))s for Discord"
        case .stopped(let status):
            return status == 404 ? "Stopped: webhook deleted (404)" : "Stopped: webhook not accepted (\(status))"
        case .failed(let message, _):
            return "Failed: \(message)"
        case .missing:
            return "Webhook missing — set it again"
        }
    }
}
```

- [ ] **Step 4: Run the tests.** `swift test --filter "DiscordNotifierTests|WebhookQueueTests|DiscordWebhooksTests"` passes, with no warnings.

- [ ] **Step 5: Commit.** Tests first (`test(discord): routing to queues, the global pause, the stop notice and Settings' actions`), then `feat(discord): the notifier that posts linkC's events to its webhooks`.

---

### Task 5: Where the events come from

**Files:**
- Create: `Sources/LinkCKit/Discord/TaskEventFeed.swift`
- Modify:
  - `Sources/LinkCKit/Notify/NotificationManager.swift`;
  - `Sources/LinkCKit/App/AppCoordinator.swift`, `AppCoordinator+Relay.swift`, `AppCoordinator+Watchdog.swift`, `AppCoordinator+Open.swift` and `AppCoordinator+Workers.swift`;
  - `Sources/LinkCKit/Config/HealthMonitor.swift`;
  - `Sources/linkc/LinkCApp.swift` (its two `notify` calls, so the app keeps building).
- Test:
  - `Tests/LinkCKitTests/NotifyTests.swift` (update one test, add more);
  - `Tests/LinkCKitTests/TaskEventFeedTests.swift` (new);
  - `Tests/LinkCKitTests/AppCoordinatorDiscordEventTests.swift` (new).

**Interfaces:**
- Consumes: `LinkCEvent` (Task 1).
- Produces:
  - `NotificationManager.onEvent: ((LinkCEvent) -> Void)?`, `post(title:body:project:tone:)`, `postAlert(id:title:body:tone:)`, `postEvent(_:)` and `postLocal(title:body:)`;
  - `AppCoordinator.onEvent` (public), `postLocalNotification(title:body:)` (public) and `notify(id:title:body:tone:)` (public, with a new `tone:`);
  - `HealthChange.tone`;
  - `struct TaskEventFeed` with `events(in:tasks:at:)` and `retain(only:)`.

- [ ] **Step 1: Write the failing tests.** In `Tests/LinkCKitTests/NotifyTests.swift`, change `testPostGenericAlertDeliversImmediately`'s call to `manager.post(title: "linkC: Swarm Rate Limited", body: "All candidates are rate limited.", project: nil)`, and add this class at the end of the file:

```swift
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
```

`Tests/LinkCKitTests/TaskEventFeedTests.swift`:

```swift
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
```

`Tests/LinkCKitTests/AppCoordinatorDiscordEventTests.swift`:

```swift
import XCTest
@testable import LinkCKit

/// The coordinator's events for Discord: task changes, closed workers, and alerts with their folder.
@MainActor
final class AppCoordinatorDiscordEventTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("linkc-discord-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var folder: String { ProjectPath.canonical(tempDir.path) }

    private final class Box {
        var events: [LinkCEvent] = []
    }

    private func makeCoordinator() -> (AppCoordinator, Box) {
        let script = tempDir.appendingPathComponent("mock_agent.sh")
        try? "#!/bin/sh\nstty -echo 2>/dev/null\nprintf '\\033[?2004h'\nexec /bin/cat\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let settingsDir = tempDir.appendingPathComponent("settings")
        try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let coordinator = AppCoordinator(
            terminals: TerminalSessionManager(),
            hookServer: HookServer.forTesting(),
            notifications: NotificationManager(sink: RecordingSink(), now: { Date() }),
            claudePath: script.path,
            settingsDir: settingsDir,
            userSettingsURL: tempDir.appendingPathComponent("user-settings.json"),
            manifestDir: tempDir.appendingPathComponent("manifest"),
            agentPathResolver: { _ in script.path },
            deliverySettle: 0,
            injectionGap: 0,
            isWatching: { _ in false }
        )
        let box = Box()
        coordinator.onEvent = { box.events.append($0) }
        return (coordinator, box)
    }

    private func stopAll(_ coordinator: AppCoordinator) {
        coordinator.store.sessions.forEach { coordinator.stopSession($0.id) }
        coordinator.shutdown()
    }

    func testATaskChangeRaisesOneTaskEventAndTheFirstPassNone() throws {
        let (coordinator, box) = makeCoordinator()
        defer { stopAll(coordinator) }
        let inbox = InboxStore(workspaceRoot: folder)
        let task = try inbox.createTask(from: .claude, to: .codex, prompt: "carry", files: [])
        try inbox.cancelTask(taskId: task.id, reason: "not needed")

        coordinator.processPendingMessages(workspacePath: folder)
        XCTAssertTrue(box.events.filter { $0.kind == .task }.isEmpty, "the first pass only records")

        let second = try inbox.createTask(from: .claude, to: .codex, prompt: "other work", files: [])
        try inbox.cancelTask(taskId: second.id, reason: "changed my mind")
        coordinator.processPendingMessages(workspacePath: folder)

        let taskEvents = box.events.filter { $0.kind == .task }
        XCTAssertEqual(taskEvents.map(\.title), ["Task cancelled · Claude → Codex"])
        XCTAssertEqual(taskEvents.first?.project, folder)
    }

    func testAWorkerClosedOnRequestRaisesAnEvent() throws {
        let (coordinator, box) = makeCoordinator()
        defer { stopAll(coordinator) }
        let inbox = InboxStore(workspaceRoot: folder)
        let worker = try coordinator.newSession(cwd: folder, agent: .codex, asWorker: true)
        let task = try inbox.createTask(from: .claude, to: .codex, fromSessionId: "D", prompt: "carry", files: [])
        try inbox.markTaskDelivered(taskId: task.id, sessionId: worker.id)
        try inbox.reportTask(taskId: task.id, report: TaskReport(status: "done", summary: "did it"))
        coordinator.store.updateState(id: worker.id, to: .finished)
        _ = try inbox.requestClose(taskId: task.id, by: .delegator)

        coordinator.reapIdleWorkers(workspacePath: folder, inboxStore: inbox)

        let closed = box.events.filter { $0.kind == .workerClosed }
        XCTAssertEqual(closed.map(\.title), ["Codex worker closed"])
        XCTAssertEqual(closed.first?.project, folder)
        XCTAssertEqual(closed.first?.body, "Closed on request for task `\(task.shortId)`.")
    }

    func testALocalNotificationRaisesNoEvent() {
        let (coordinator, box) = makeCoordinator()
        defer { stopAll(coordinator) }
        coordinator.postLocalNotification(title: "linkC update", body: "installed")
        XCTAssertTrue(box.events.isEmpty)
    }

    func testAServiceAlertRaisesAServiceEvent() {
        let (coordinator, box) = makeCoordinator()
        defer { stopAll(coordinator) }
        coordinator.notify(id: "health:api", title: "api", body: "api is not responding", tone: .failed)
        XCTAssertEqual(box.events.map(\.kind), [.service])
        XCTAssertEqual(box.events.map(\.tone), [.failed])
    }
}
```

- [ ] **Step 2: Run them to see them fail.** `swift test --filter "NotificationManagerEventTests|NotificationManagerPostTests|TaskEventFeedTests|AppCoordinatorDiscordEventTests"` fails to compile.

- [ ] **Step 3: Implement.**

**`NotificationManager.swift`:**
- Add, after `onActivate`:

```swift
    /// Told every event linkC posts, for Discord (spec 2026-11-05 §2). The app wires it to its
    /// `DiscordNotifier`.
    public var onEvent: ((LinkCEvent) -> Void)?
```

- In `post(session:)`, after `sink.deliver(...)`:

```swift
        onEvent?(LinkCEvent(
            kind: .sessionState, tone: Self.tone(for: session.state),
            title: "\(session.agentKind.displayName) · \(body)", body: "",
            project: ProjectPath.canonical(session.cwd), at: timestamp))
```

- Replace `postAlert` and `post(title:body:)`, and add the new methods:

```swift
    /// Post an alert that isn't about a session (a watched service changing state). No
    /// dedupe here on purpose: the caller only reports genuine CHANGES, so coalescing
    /// would swallow a real down→up→down flap.
    public func postAlert(id: String, title: String, body: String, tone: LinkCEvent.Tone) {
        sink.deliver(id: id, title: title, body: body)
        onEvent?(LinkCEvent(kind: .service, tone: tone, title: Self.eventTitle(title), body: body,
                            project: nil, at: now()))
    }

    /// Post a generic alert notification with an auto-generated identifier. `project` is the folder it
    /// concerns, which routes its Discord post; nil when it concerns none.
    public func post(title: String, body: String, project: String?, tone: LinkCEvent.Tone = .needsYou) {
        sink.deliver(id: "\(AppCoordinator.alertIdPrefix)\(UUID().uuidString)", title: title, body: body)
        onEvent?(LinkCEvent(kind: .alert, tone: tone, title: Self.eventTitle(title), body: body,
                            project: project.map(ProjectPath.canonical), at: now()))
    }

    /// An event for Discord only: task changes and closed workers, which would make macOS
    /// notifications noisy (spec §2).
    public func postEvent(_ event: LinkCEvent) {
        onEvent?(event)
    }

    /// A macOS notification that is never forwarded to Discord: linkC's own word about itself, such as
    /// a webhook that stopped or an update notice.
    public func postLocal(title: String, body: String) {
        sink.deliver(id: "\(AppCoordinator.alertIdPrefix)\(UUID().uuidString)", title: title, body: body)
    }

    nonisolated static func tone(for state: SessionState) -> LinkCEvent.Tone {
        switch state {
        case .finished: .done
        case .waitingPermission, .waitingIdle: .needsYou
        case .error: .failed
        default: .info
        }
    }

    /// Discord posts as "linkC" already: the macOS title's "linkC: " prefix is dropped there.
    nonisolated static func eventTitle(_ title: String) -> String {
        title.hasPrefix("linkC: ") ? String(title.dropFirst("linkC: ".count)) : title
    }
```

**`HealthMonitor.swift`:** `HealthChange` gains a tone, and each of the three changes passes one:

```swift
public struct HealthChange: Equatable, Sendable {
    public let endpointId: String
    public let title: String
    public let body: String
    /// How the change reads in Discord: down is failed, degraded needs you, back up is done.
    public let tone: LinkCEvent.Tone
}
```

```swift
            case (.ok, .down), (.degraded, .down):
                return HealthChange(
                    endpointId: endpoint.id,
                    title: endpoint.label,
                    body: "\(endpoint.label) is not responding",
                    tone: .failed
                )
            case (.ok, .degraded(let code, _)), (.down, .degraded(let code, _)):
                return HealthChange(
                    endpointId: endpoint.id,
                    title: endpoint.label,
                    body: "\(endpoint.label) is answering \(code)",
                    tone: .needsYou
                )
            case (.down, .ok), (.degraded, .ok):
                return HealthChange(
                    endpointId: endpoint.id,
                    title: endpoint.label,
                    body: "\(endpoint.label) is back up",
                    tone: .done
                )
```

**`Sources/linkc/LinkCApp.swift`:** the two `notify` calls change, so the app target keeps building:

```swift
            if let notice = UpdateSwap.takeNotice() {
                coordinator.postLocalNotification(title: "linkC update", body: notice)
```

```swift
                self.coordinator?.notify(
                    id: "health:\(change.endpointId)", title: change.title, body: change.body, tone: change.tone
                )
```

**`AppCoordinator.swift`:**
- `notify(id:title:body:)` becomes `public func notify(id: String, title: String, body: String, tone: LinkCEvent.Tone)` and passes `tone:` to `postAlert`.
- Add after it:

```swift
    /// A macOS notification linkC never forwards to Discord.
    public func postLocalNotification(title: String, body: String) {
        notifications.postLocal(title: title, body: body)
    }

    /// Told every event linkC posts, for Discord (spec 2026-11-05): alerts, task changes, closed workers.
    public var onEvent: ((LinkCEvent) -> Void)? {
        get { notifications.onEvent }
        set { notifications.onEvent = newValue }
    }
```

- Add a stored property next to `relayWork`:

```swift
    /// The task states each folder had at the last relay pass, for Discord's task events.
    var taskEvents = TaskEventFeed()
```

- In `sweepTick`, after `relayWork.retain(only: workspaces)`, add `taskEvents.retain(only: workspaces)`.

**Every other `notifications.post(title:body:)` call passes its folder** as `project:`, right after `body:`, keeping the default tone (`.needsYou`):

| File | Call | Add |
|---|---|---|
| `AppCoordinator+Watchdog.swift` | tasks look stuck (`watchStuckTasks`) | `project: workspacePath` |
| `AppCoordinator+Watchdog.swift` | a notice can't land (`noteUndeliveredNotice`) | `project: workspacePath` |
| `AppCoordinator+Relay.swift` | turn ended with open tasks (`relayTurnEnd`) | `project: norm` |
| `AppCoordinator+Relay.swift` | rate limited (`checkLimitsAndReroute`, inside `tellDelegator`) | `project: session.cwd` |
| `AppCoordinator+Relay.swift` | swarm rate limited (`checkLimitsAndReroute`) | `project: norm` |
| `AppCoordinator+Open.swift` | both "your prompt was not typed" | `project: session.cwd` |

For example, the stuck-task call becomes:

```swift
            notifications.post(
                title: "linkC: \(reported.count) task(s) look stuck",
                body: "\(reasons.joined(separator: "; ")). The delegating agent was told.",
                project: workspacePath
            )
```

The prompt-dropped call in `launch` becomes:

```swift
                    notifications.post(title: "linkC: your prompt was not typed",
                                       body: "You typed into \(session.agentKind.displayName) first. Paste it in yourself if you still want it.",
                                       project: session.cwd, tone: .info)
```

**`AppCoordinator+Relay.swift`, `processPendingMessages`:** after `pollPasteReadiness(workspacePath: norm)`, add `reportTaskEvents(workspacePath: norm, inboxStore: inboxStore)`. Then add to the extension:

```swift
    /// Posts the task changes in `workspacePath` since the last pass, for Discord only (spec §2.1). A read
    /// that fails keeps the last snapshot, so the next pass compares again: nothing is lost or repeated.
    func reportTaskEvents(workspacePath norm: String, inboxStore: InboxStore) {
        // Like every relay phase: a store read would recreate a deleted workspace on disk.
        guard workspaceExists(norm) else { return }
        let tasks: [TaskRecord]
        do {
            tasks = try inboxStore.load(timeout: Self.relayLockTimeout).tasks
        } catch {
            if !isRelayLockTimeout(error) {
                NSLog("[linkC relay] reportTaskEvents: tasks — %@", String(describing: error))
            }
            return
        }
        for event in taskEvents.events(in: norm, tasks: tasks, at: now()) {
            notifications.postEvent(event)
        }
    }
```

**`AppCoordinator+Workers.swift`:**
- `answerCloseRequests` gains `workspacePath norm: String` (pass `norm` at its call).
- Its `.close(let sessionId)` case becomes:

```swift
            case .close(let sessionId):
                NSLog("[linkC relay] closing worker %@ on request for task %@", sessionId, task.shortId)
                let agent = store.session(id: sessionId)?.agentKind
                stopSession(sessionId)
                postWorkerClosed(agent, in: norm, because: "Closed on request for task `\(task.shortId)`.")
                outcome = .closed(at: now())
```

- The reaper loop becomes:

```swift
            NSLog("[linkC relay] closing finished worker %@ in %@", id, workspacePath)
            let agent = store.session(id: id)?.agentKind
            stopSession(id)
            postWorkerClosed(agent, in: norm, because: "It sat idle after its work ended.")
```

- Add:

```swift
    /// A Discord-only event for a worker linkC just closed (spec §2).
    private func postWorkerClosed(_ agent: AgentKind?, in folder: String, because reason: String) {
        notifications.postEvent(LinkCEvent(
            kind: .workerClosed, tone: .info, title: "\(agent?.displayName ?? "A") worker closed",
            body: reason, project: folder, at: now()))
    }
```

`Sources/LinkCKit/Discord/TaskEventFeed.swift`:

```swift
import Foundation

/// Finds each folder's task changes between two relay passes (spec §2.1), whichever process made them:
/// linkC's relay or a `linkc-mcp`. The first pass for a folder only records, so a restart never posts
/// the backlog.
struct TaskEventFeed {
    /// The states that raise an event; moves to any other state raise none.
    static let reportedStates: Set<TaskState> = [.delivered, .done, .failed, .expired, .cancelled]

    private var seen: [String: [String: TaskState]] = [:]

    /// The events for `folder` since the last pass: one per task that moved to, or appeared in, a
    /// reported state.
    mutating func events(in folder: String, tasks: [TaskRecord], at date: Date) -> [LinkCEvent] {
        let current = Dictionary(tasks.map { ($0.id, $0.state) }, uniquingKeysWith: { _, last in last })
        defer { seen[folder] = current }
        guard let previous = seen[folder] else { return [] }
        return tasks.compactMap { task in
            guard previous[task.id] != task.state, Self.reportedStates.contains(task.state) else { return nil }
            return Self.event(for: task, in: folder, at: date)
        }
    }

    /// Forgets folders the relay no longer serves; one served again starts over silently.
    mutating func retain(only folders: Set<String>) {
        seen = seen.filter { folders.contains($0.key) }
    }

    static func event(for task: TaskRecord, in folder: String, at date: Date) -> LinkCEvent {
        let (word, tone): (String, LinkCEvent.Tone) = switch task.state {
        case .delivered: ("delivered", .info)
        case .done: ("done", .done)
        case .failed: ("failed", .failed)
        case .expired: ("expired", .failed)
        case .cancelled: ("cancelled", .info)
        default: (task.state.rawValue, .info)
        }
        var lines = ["`\(task.shortId)` \(firstLine(of: task.prompt))"]
        let outcome: String? = switch task.state {
        case .done, .failed: task.report?.summary ?? task.cancelReason
        case .expired, .cancelled: task.cancelReason
        default: nil
        }
        if let outcome, !outcome.isEmpty { lines.append(outcome) }
        return LinkCEvent(
            kind: .task, tone: tone,
            title: "Task \(word) · \(task.fromAgent.displayName) → \(task.toAgent.displayName)",
            body: lines.joined(separator: "\n"), project: folder, at: date)
    }

    /// The prompt's first line, cut at 120 characters.
    static func firstLine(of prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }
}
```

- [ ] **Step 4: Run the tests.** `swift test --filter "NotificationManagerEventTests|NotificationManagerPostTests|TaskEventFeedTests|AppCoordinatorDiscordEventTests|AppCoordinatorRelayTests|AppCoordinatorWatchdogTests|AppCoordinatorOpenTests|HealthTransitionTests"` passes, `swift build --build-tests 2>&1 | grep -E "warning:|error:"` prints nothing, and the full suite shows 0 failures.

- [ ] **Step 5: Commit.** Tests first (`test(discord): alerts, task changes and closed workers become events`), then `feat(discord): every alert, task change and closed worker becomes an event`.

---

### Task 6: Settings, the app's wiring, and the README

**Files:**
- Modify: `Sources/linkc/Screens/SettingsScreen.swift`, `Sources/linkc/LinkCApp.swift`, `README.md`

The app target has no unit tests. Check it by building with no warnings, by running the full suite, and by reading it. The controller runs the manual checks in spec §9 on an installed build.

**Interfaces:**
- Consumes: `DiscordNotifier`, `DiscordWebhooks`, `KeychainSecretStore`, `URLSessionWebhookTransport` (Tasks 2 to 4); `AppCoordinator.onEvent`, `postLocalNotification`, `notify(id:title:body:tone:)` and `HealthChange.tone` (Task 5).

- [ ] **Step 1: Wire the notifier** in `Sources/linkc/LinkCApp.swift`.
  - Add a property to `AppModel`, after `coordinator`:

```swift
    /// Posts linkC's events to the user's Discord webhooks (Settings > Discord).
    private(set) var discord: DiscordNotifier<ContinuousClock>?
```

  - In `start()`, after `coordinator.onCommandSessionOpened = …` and before `try coordinator.start()`:

```swift
            // linkC's events also go to Discord, for the webhooks set in Settings > Discord.
            let discord = DiscordNotifier(
                webhooks: DiscordWebhooks(secrets: KeychainSecretStore(), preferences: prefs),
                transport: URLSessionWebhookTransport(),
                clock: ContinuousClock(),
                notifyUser: { [weak coordinator] title, body in
                    coordinator?.postLocalNotification(title: title, body: body)
                }
            )
            coordinator.onEvent = { [weak discord] event in discord?.post(event) }
            self.discord = discord
```


- [ ] **Step 2: The DISCORD section** in `Sources/linkc/Screens/SettingsScreen.swift`.
  - Add `@State private var addingDiscordProject: String?` to `SettingsScreen`.
  - After the WATCHED SERVICES row, still inside the `VStack(spacing: 6)`:

```swift
                    SectionHeader(title: "DISCORD").padding(.top, 6)
                    Text(
                        "linkC posts its events to Discord: an agent finishing or needing you, tasks, closed "
                            + "workers, rate limits and watched services. A project with its own webhook posts "
                            + "there; everything else goes to the default. Webhook URLs stay in your Keychain."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    if let discord = model.discord {
                        DiscordWebhookRow(discord: discord, account: DiscordWebhooks.defaultAccount, title: "Default")
                        ForEach(discord.webhooks.projects, id: \.self) { folder in
                            DiscordWebhookRow(discord: discord, account: folder,
                                              title: URL(fileURLWithPath: folder).lastPathComponent)
                        }
                        if let folder = addingDiscordProject, !discord.webhooks.projects.contains(folder) {
                            DiscordWebhookRow(discord: discord, account: folder,
                                              title: URL(fileURLWithPath: folder).lastPathComponent,
                                              opensEditing: true, onDone: { addingDiscordProject = nil })
                        }
                        HStack {
                            QuietLink("Add project…") { addDiscordProject() }
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                    }
```

  - Add the action to `SettingsScreen`:

```swift
    private func addDiscordProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the project folder whose events go to a webhook of their own"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addingDiscordProject = ProjectPath.canonical(url.path)
    }
```

  - Add the row at file scope:

```swift
/// One Discord webhook in Settings: its name, its webhook's id (never the URL) and status, and
/// set / test / remove. The URL is typed into a secure field and cleared once stored.
private struct DiscordWebhookRow: View {
    let discord: DiscordNotifier<ContinuousClock>
    let account: String
    let title: String
    /// Opens with the field showing: a project just added has no webhook yet.
    var opensEditing = false
    var onDone: () -> Void = {}

    @State private var editing = false
    @State private var text = ""
    @State private var error: String?

    private var state: DiscordWebhookState { discord.webhooks.state(for: account) }

    private var isSet: Bool {
        if case .set = state { return true }
        return false
    }

    private var detail: String {
        switch state {
        case .notSet: "Not set"
        case .set(let webhook): "Webhook \(webhook.id) · \(discord.status(for: account).label(now: Date()))"
        case .missing: WebhookStatus.missing.label(now: Date())
        case .unreadable(let reason): reason
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                if isSet { QuietLink("test") { run { try discord.sendTest(to: account) } } }
                QuietLink(isSet ? "change" : "set") { editing.toggle() }
                if state != .notSet || account != DiscordWebhooks.defaultAccount {
                    QuietLink("remove") {
                        run {
                            try discord.remove(account)
                            onDone()
                        }
                    }
                }
            }
            if editing {
                HStack(spacing: 6) {
                    SecureField("https://discord.com/api/webhooks/…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.mini)
                        .onSubmit { save() }
                    QuietLink("save") { save() }
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.contextWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { if opensEditing { editing = true } }
    }

    private func save() {
        run {
            try discord.set(text, for: account)
            text = ""
            editing = false
            onDone()
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
```

  `error.localizedDescription` must read well for a refused URL and a Keychain failure. Add to `DiscordWebhooks.swift`:

```swift
extension DiscordWebhookURL.Refusal: LocalizedError {
    public var errorDescription: String? { description }
}
```

  and to `SecretStore.swift`:

```swift
extension KeychainSecretStore.Failure: LocalizedError {
    public var errorDescription: String? { description }
}
```

- [ ] **Step 3: README.** After the "Opening an agent from a terminal" subsection, add:

```markdown
### Discord

linkC can post its events to a Discord channel, so you can follow your agents from your phone:
- an agent finishing, needing permission or input, or ending with an error;
- a task delivered, done, failed, expired or cancelled;
- a worker closing;
- rate limits, and watched services going down or coming back.

In Settings > Discord, paste a channel's webhook URL (Discord: channel settings > Integrations > Webhooks)
as the default. A project can have its own webhook: its events go there instead and never to the default.
Webhook URLs are kept in your Keychain. linkC only posts; nothing in Discord reaches your agents. Posts are
paced to Discord's limits and grouped when many events arrive at once. A webhook that Discord reports as
deleted stops posting, and linkC tells you so.
```

- [ ] **Step 4: Verify.**
  - `swift build --build-tests 2>&1 | grep -E "warning:|error:"` prints nothing.
  - The full suite shows 0 failures: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | sort -k2 -n | tail -1`.
  - Do not run the app or `build-app.sh`; the controller does.

- [ ] **Step 5: Commit.** `feat(discord): Settings > Discord, the app's wiring, and the README`.

### Task 7: Post in the JD LLC house style

Runs after Task 5 and before Task 6.

linkC posts its events to Discord webhooks (spec `docs/superpowers/specs/2026-11-05-discord-notifications-design.md`,
§4.2, §4.4 and §5, amended for the house style). Today `DiscordMessage` builds embeds. This task replaces it with
Components V2 cards and digests, and makes the queue count a message as sent only when Discord saved it.

Read spec §4.2, §4.4 and §5 first. The tests are committed; do not modify any test file.

#### Files

- Rewrite: `Sources/LinkCKit/Discord/DiscordMessage.swift`
- Modify: `Sources/LinkCKit/Discord/WebhookQueue.swift`
- Modify: `Sources/LinkCKit/Discord/WebhookTransport.swift`
- Tests (committed, read them): `Tests/LinkCKitTests/DiscordMessageTests.swift`, `WebhookQueueTests.swift`,
  `DiscordNotifierTests.swift`, `WebhookTransportTests.swift`, `DiscordLivePreviewTests.swift`, and the support files
  `Tests/LinkCKitTests/Support/ScriptedWebhookTransport.swift`, `GatedWebhookTransport.swift`.

#### 1. `DiscordMessage` (internal `enum`, rewrite)

Constants, with these exact names and values:

```swift
static let maxComponents = 40          // every component in a message, the container included
static let maxTextCharacters = 4000    // all text displays' content together, in UTF-16 units
static let maxEventsPerPage = 15
static let maxTitle = 100
static let maxDetailLine = 120
static let maxDetailLines = 4
static let maxFolderName = 50
static let isComponentsV2 = 1 << 15
static let suppressNotifications = 1 << 12
```

Types:

```swift
indirect enum Component: Equatable, Encodable {
    case container(accentColor: Int, [Component])   // {"type":17,"accent_color":…,"components":[…]}
    case text(String)                                // {"type":10,"content":…}
    case separator                                   // {"type":14,"divider":true,"spacing":1}
}

struct Payload: Equatable, Encodable {
    let flags: Int
    let container: Component
    // Encodes exactly {"flags": flags, "components": [container], "allowed_mentions": {"parse": []}}.
    // No content, embeds or username.
}

struct Page: Equatable {
    let payload: Payload
    /// How many events this page carries (the dropped count is not one of them).
    let eventCount: Int
}

struct OverLimit: Error, LocalizedError { let errorDescription: String? }
```

Functions:

- `static func pages(_ events: [LinkCEvent], dropped: Int) throws -> [Page]`
  - No events: `[]`.
  - One event: one card (below).
  - Several: digest pages (below), oldest first. Pack greedily: an event joins the current page while the page
    holds fewer than `maxEventsPerPage` events and still fits both limits, measured with the longest headline suffix
    it could get (for example `" (99/99)"`); otherwise it starts the next page.
  - `dropped > 0`: the dropped line goes on the first page (or the card) only.
  - Every page is checked with `check` before any is returned, so a bad later page posts nothing.
- `static func check(_ payload: Payload) throws` — throws `OverLimit` when the message has more than
  `maxComponents` components (nested included), more than `maxTextCharacters` text characters, or an empty text
  display. The error names the count and the limit, for example "a message has 41 components; Discord allows 40".
- `static func size(_ payload: Payload) -> (components: Int, characters: Int)`.
- `static func encode(_ payload: Payload) throws -> Data` (JSONEncoder).
- `static func escape(_ text: String, limit: Int) -> String` — whitespace runs (newlines included) become one
  space and the ends are trimmed; each of `\ * _ ~ ` | < > [ ] ( ) # @` gets a backslash before it; the result is at
  most `limit` UTF-16 units, cut with a trailing `…` that counts toward the limit. A cut never splits a character
  or an escape (an escape and its character are one piece).
- `static func postURL(for webhook: URL) -> URL` — the webhook URL with `with_components=true` and `wait=true`
  appended to its query, keeping any query items it already has, in that order.

Tone table (spec §5.3): done `0x57F287` ✅, needsYou `0xFEE75C` ⚠️, failed `0xED4245` ❌, info `0x5865F2` 📋.
A message's flags are `isComponentsV2`, plus `suppressNotifications` when every event in it is `.info`.

**Detail lines** of an event (from `body`): split on newlines, escape each line with `limit: maxDetailLine`, drop
the empty ones. At most `maxDetailLines`: when there are more, show the first `maxDetailLines - 1` and then
`"… N more lines"` (N = the lines left out; "1 more line" when N is 1).

**Folder name**: the last path component of `event.project`, escaped with `limit: maxFolderName`.

**Dropped line**: `"⚠️ 1 earlier event was not posted."`, `"⚠️ N earlier events were not posted."`.

**Footer timestamp**: `<t:UNIX:f> (<t:UNIX:R>)`, UNIX = whole seconds of the date.

**A card** (one event): one container, accent = the event's tone color, children in order:
1. `.text("## <emoji> <escaped title, limit maxTitle>")`
2. `.text(<detail lines joined by "\n">)`, only when there is at least one
3. `.text(<dropped line>)`, only when `dropped > 0`
4. `.separator`
5. `.text("-# linkC · <folder> · <timestamp>")`, or `"-# linkC · <timestamp>"` with no project

**A digest page**: one container, accent = the most serious tone on the page (failed, then needsYou, then done,
then info), children in order:
1. `.text("## 📋 <N> linkC events")` where N is the number of events across all pages; with more than one page,
   `" (i/k)"` follows.
2. One `.text` per event: `"<emoji> **<escaped title>**"`, then `" · <folder>"` when it has a project, then
   `"\n-# <first detail line>"` when it has one.
3. `.text(<dropped line>)` on the first page, when `dropped > 0`.
4. `.separator`
5. `.text("-# linkC · <timestamp of the newest event on this page>")`

#### 2. `WebhookResponse.savedMessageID` (`WebhookTransport.swift`)

```swift
/// The id of the message Discord saved: only a 200 whose JSON object has a non-empty string `id` (spec §4.4).
public var savedMessageID: String? { … }
```

#### 3. Transport errors by type, never by text (`WebhookTransport.swift`)

`URLSessionWebhookTransport` reports a failed request as `Failure(errorDescription: Self.describe(error))`, where

```swift
/// A transport error by its type (and a URLError's code), never by its text, which can hold the URL.
static func describe(_ error: Error) -> String
```

- a `URLError`: `"<words> (URLError <code>)"` with these words — `.timedOut` "the request timed out",
  `.notConnectedToInternet` "no internet connection", `.networkConnectionLost` "the connection was lost",
  `.cannotFindHost` "the host was not found", `.cannotConnectToHost` "could not connect"; any other code is just
  `"URLError <code>"`. Example: `"the request timed out (URLError -1001)"`, `"URLError -1200"`.
- any other error: its type name, `String(describing: type(of: error))`.

#### 4. `WebhookQueue`

- Posts to `DiscordMessage.postURL(for: url)` (compute it once in `init`). `url` stays the plain webhook URL.
- When a request goes out it takes **every** waiting event (and the dropped count), builds `DiscordMessage.pages`,
  and posts the pages in order, one request each, before any event that arrived meanwhile. A page that is dropped
  (4xx, redirect, retries used up) adds its `eventCount` (plus the carried dropped count, for the first page) to
  `dropped`, and the next page still goes. When the webhook stops (401, 403, 404) or the queue is cancelled, the
  remaining pages are discarded like the rest of the queue.
- If `pages` or `encode` throws: log it (`NSLog`, by the webhook's name, never the URL), set
  `.failed("a message could not be built: <description>", at:)`, count every event it carried as dropped, and go on.
- Success is `response.savedMessageID != nil` (only a 200 with an id). Any other 2xx — a 204, `{}`, a body that
  is not JSON — is retried like a 5xx, with the reason `"Discord answered <status> without saving the message"`.
- A 4xx (other than 401, 403, 404, 429) shows Discord's JSON `code` and `message`:
  `"Discord refused a message (400): code 50035, Invalid Form Body"`; with no JSON body,
  `"Discord refused a message (400)"`. Log the same text. Never log the request body.
- Everything else is unchanged: the pacer, 429 handling, the global limit, stopping, the retry delays, cancel.

#### Verify

- `swift build --build-tests 2>&1 | grep -E "warning:|error:"` prints nothing.
- `swift test --filter "DiscordMessageTests|WebhookQueueTests|DiscordNotifierTests|WebhookTransportTests|DiscordLivePreviewTests"` passes
  (the live preview test is skipped without `DISCORD_PREVIEW_WEBHOOK_URL`).
- `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | sort -k2 -n | tail -1` shows 0 failures.
