import XCTest
@testable import LinkCKit

/// The body of one webhook request in the JD LLC house style: one Components V2 card per event, a digest for
/// several, within Discord's limits (spec §4.2, §5).
final class DiscordMessageTests: XCTestCase {
    private static let unix = 1_800_000_000
    private let stamp = "<t:1800000000:f> (<t:1800000000:R>)"

    private func event(
        _ title: String = "Codex · money-printer · finished", body: String = "", tone: LinkCEvent.Tone = .done,
        project: String? = "/Users/me/money-printer", at seconds: Int = DiscordMessageTests.unix
    ) -> LinkCEvent {
        LinkCEvent(kind: .sessionState, tone: tone, title: title, body: body, project: project,
                   at: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    private func json(_ payload: DiscordMessage.Payload) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: DiscordMessage.encode(payload)) as? [String: Any])
    }

    /// The one container's children, as Discord receives them.
    private func children(_ payload: DiscordMessage.Payload) throws -> [[String: Any]] {
        let components = try XCTUnwrap(json(payload)["components"] as? [[String: Any]])
        XCTAssertEqual(components.count, 1, "one container per message")
        XCTAssertEqual(components.first?["type"] as? Int, 17)
        return try XCTUnwrap(components.first?["components"] as? [[String: Any]])
    }

    /// Each child as a short string: its text, or "---" for a separator.
    private func lines(_ payload: DiscordMessage.Payload) throws -> [String] {
        try children(payload).map { child in
            switch child["type"] as? Int {
            case 10: child["content"] as? String ?? "<no content>"
            case 14: "---"
            default: "<type \(child["type"] ?? "none")>"
            }
        }
    }

    private func accent(_ payload: DiscordMessage.Payload) throws -> Int? {
        try (json(payload)["components"] as? [[String: Any]])?.first?["accent_color"] as? Int
    }

    private func only(_ events: [LinkCEvent], dropped: Int = 0) throws -> DiscordMessage.Payload {
        let pages = try DiscordMessage.pages(events, dropped: dropped)
        XCTAssertEqual(pages.count, 1)
        return try XCTUnwrap(pages.first?.payload)
    }

    // MARK: - One event

    func testOneEventIsOneCard() throws {
        let card = try only([event(body: "all green")])
        XCTAssertEqual(try lines(card), [
            "## ✅ Codex · money-printer · finished",
            "all green",
            "---",
            "-# linkC · money-printer · \(stamp)",
        ])
        XCTAssertEqual(try accent(card), 0x57F287)
    }

    /// A Components V2 message carries nothing else: Discord answers 400 to `content` or `embeds`, and the
    /// webhook's own name shows who posted. Text from a task or an agent can hold `@everyone`: nothing pings.
    func testTheBodyIsComponentsOnlyAndPingsNobody() throws {
        let body = try json(only([event(body: "@everyone look")]))
        XCTAssertEqual(Set(body.keys), ["flags", "components", "allowed_mentions"])
        XCTAssertEqual(body["allowed_mentions"] as? [String: [String]], ["parse": []])
        XCTAssertEqual(body["flags"] as? Int, 1 << 15)
        let separator = try XCTUnwrap(children(only([event()])).first { $0["type"] as? Int == 14 })
        XCTAssertEqual(separator["divider"] as? Bool, true)
    }

    func testAnEventWithNoDetailOrProject() throws {
        XCTAssertEqual(try lines(only([event(project: nil)])), [
            "## ✅ Codex · money-printer · finished",
            "---",
            "-# linkC · \(stamp)",
        ])
    }

    func testEachToneHasItsColorEmojiAndSound() throws {
        let cases: [(LinkCEvent.Tone, String, Int, Int)] = [
            (.done, "✅", 0x57F287, 1 << 15),
            (.needsYou, "⚠️", 0xFEE75C, 1 << 15),
            (.failed, "❌", 0xED4245, 1 << 15),
            (.info, "📋", 0x5865F2, 1 << 15 | 1 << 12),
        ]
        for (tone, emoji, color, flags) in cases {
            let card = try only([event("t", tone: tone)])
            XCTAssertEqual(try lines(card).first, "## \(emoji) t", "\(tone)")
            XCTAssertEqual(try accent(card), color, "\(tone)")
            XCTAssertEqual(try json(card)["flags"] as? Int, flags, "\(tone): only information posts silently")
        }
    }

    /// Text from agents, tasks and folders is markdown-escaped and kept on one line (house style).
    func testTextIsEscapedAndEachLineKeptOnOne() throws {
        let card = try only([event("fix *all* the `bugs` @everyone", body: "line   one\n\n  line two  ",
                                   project: "/p/my_project")])
        XCTAssertEqual(try lines(card), [
            "## ✅ fix \\*all\\* the \\`bugs\\` \\@everyone",
            "line one\nline two",
            "---",
            "-# linkC · my\\_project · \(stamp)",
        ])
    }

    func testLongTextIsCutVisibly() throws {
        let card = try only([event(String(repeating: "t", count: 300), body: String(repeating: "b", count: 300),
                                   project: "/p/" + String(repeating: "f", count: 200))])
        let shown = try lines(card)
        XCTAssertEqual(shown[0], "## ✅ " + String(repeating: "t", count: 99) + "…")
        XCTAssertEqual(shown[1], String(repeating: "b", count: 119) + "…")
        XCTAssertEqual(shown[3], "-# linkC · " + String(repeating: "f", count: 49) + "… · \(stamp)")
    }

    /// A cut counts UTF-16 units, as Discord does, and never splits a character or an escape.
    func testACutNeverSplitsACharacterOrAnEscape() {
        let rockets = DiscordMessage.escape(String(repeating: "🚀", count: 200), limit: 100)
        XCTAssertLessThanOrEqual(rockets.utf16.count, 100)
        XCTAssertTrue(rockets.dropLast().allSatisfy { $0 == "🚀" })
        XCTAssertTrue(rockets.hasSuffix("…"))
        XCTAssertEqual(DiscordMessage.escape(String(repeating: "*", count: 100), limit: 9), "\\*\\*\\*\\*…")
        XCTAssertEqual(DiscordMessage.escape("short", limit: 9), "short")
    }

    /// At most 4 detail lines: a longer body says how many lines it left out, never drops them silently.
    func testMoreThanFourDetailLinesSaySoOnTheLast() throws {
        let card = try only([event(body: "l1\nl2\nl3\nl4\nl5\nl6")])
        XCTAssertEqual(try lines(card)[1], "l1\nl2\nl3\n… 3 more lines")
        XCTAssertEqual(try lines(only([event(body: "l1\nl2\nl3\nl4")]))[1], "l1\nl2\nl3\nl4")
    }

    func testDroppedEventsAreCountedOnTheCard() throws {
        XCTAssertEqual(try lines(only([event()], dropped: 3)), [
            "## ✅ Codex · money-printer · finished",
            "⚠️ 3 earlier events were not posted.",
            "---",
            "-# linkC · money-printer · \(stamp)",
        ])
        XCTAssertEqual(try lines(only([event()], dropped: 1))[1], "⚠️ 1 earlier event was not posted.")
    }

    // MARK: - A digest

    func testSeveralEventsAreOneDigest() throws {
        let digest = try only([
            event("first", body: "it worked\nmore", tone: .done, project: "/p/alpha", at: 1_800_000_000),
            event("second", tone: .failed, project: nil, at: 1_800_000_060),
            event("third", body: "x", tone: .info, project: "/p/beta", at: 1_800_000_030),
        ])
        XCTAssertEqual(try lines(digest), [
            "## 📋 3 linkC events",
            "✅ **first** · alpha\n-# it worked",
            "❌ **second**",
            "📋 **third** · beta\n-# x",
            "---",
            "-# linkC · <t:1800000060:f> (<t:1800000060:R>)",
        ])
        XCTAssertEqual(try accent(digest), 0xED4245, "the most serious event sets the color")
        XCTAssertEqual(try json(digest)["flags"] as? Int, 1 << 15)
    }

    func testTheMostSeriousToneSetsADigestsColor() throws {
        XCTAssertEqual(try accent(only([event(tone: .info), event(tone: .needsYou), event(tone: .done)])), 0xFEE75C)
        XCTAssertEqual(try accent(only([event(tone: .info), event(tone: .done)])), 0x57F287)
        XCTAssertEqual(try accent(only([event(tone: .info), event(tone: .info)])), 0x5865F2)
    }

    func testADigestOfInformationPostsSilently() throws {
        XCTAssertEqual(try json(only([event(tone: .info), event(tone: .info)]))["flags"] as? Int, 1 << 15 | 1 << 12)
    }

    func testThirtyEventsAreTwoPagesOfFifteenInOrder() throws {
        let pages = try DiscordMessage.pages((0..<30).map { event("e\($0)", tone: .info, project: nil) }, dropped: 0)
        XCTAssertEqual(pages.map(\.eventCount), [15, 15])
        XCTAssertEqual(try lines(pages[0].payload).first, "## 📋 30 linkC events (1/2)")
        XCTAssertEqual(try lines(pages[1].payload).first, "## 📋 30 linkC events (2/2)")
        XCTAssertEqual(try lines(pages[0].payload)[1], "📋 **e0**")
        XCTAssertEqual(try lines(pages[1].payload)[15], "📋 **e29**")
    }

    /// Long events fill a page before 15 do: pages split at Discord's limits, and every page stays under them.
    func testLongEventsSplitPagesAtDiscordsLimits() throws {
        let long = (0..<15).map { n in
            event(String(repeating: "t", count: 300) + "\(n)", body: String(repeating: "b", count: 300),
                  project: "/p/" + String(repeating: "f", count: 200))
        }
        let pages = try DiscordMessage.pages(long, dropped: 0)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.map(\.eventCount).reduce(0, +), 15)
        for (n, page) in pages.enumerated() {
            let size = DiscordMessage.size(page.payload)
            XCTAssertLessThanOrEqual(size.components, 40)
            XCTAssertLessThanOrEqual(size.characters, 4000)
            XCTAssertEqual(try lines(page.payload).first, "## 📋 15 linkC events (\(n + 1)/\(pages.count))")
        }
    }

    func testTheDroppedLineIsOnTheFirstPageOnly() throws {
        let pages = try DiscordMessage.pages((0..<20).map { event("e\($0)") }, dropped: 2)
        XCTAssertEqual(pages.count, 2)
        XCTAssertTrue(try lines(pages[0].payload).contains("⚠️ 2 earlier events were not posted."))
        XCTAssertFalse(try lines(pages[1].payload).contains { $0.hasPrefix("⚠️") })
        XCTAssertEqual(pages.map(\.eventCount), [15, 5])
    }

    func testNoEventsAreNoPages() throws {
        XCTAssertTrue(try DiscordMessage.pages([], dropped: 0).isEmpty)
    }

    // MARK: - Limits

    /// A message over a limit is an error found before posting, never text cut silently.
    func testAMessageOverALimitIsAnError() {
        func payload(_ texts: [String]) -> DiscordMessage.Payload {
            DiscordMessage.Payload(flags: DiscordMessage.isComponentsV2,
                                   container: .container(accentColor: 0, texts.map { .text($0) }))
        }
        XCTAssertNoThrow(try DiscordMessage.check(payload(Array(repeating: "x", count: 39))))
        XCTAssertThrowsError(try DiscordMessage.check(payload(Array(repeating: "x", count: 40))), "41 components")
        XCTAssertNoThrow(try DiscordMessage.check(payload([String(repeating: "x", count: 4000)])))
        XCTAssertThrowsError(try DiscordMessage.check(payload([String(repeating: "x", count: 4001)])))
        XCTAssertThrowsError(try DiscordMessage.check(payload([""])), "an empty text display")
    }

    // MARK: - Transport

    /// Without `with_components` Discord drops the components; without `wait` an unsaved message looks sent.
    func testThePostURLAsksForComponentsAndASavedMessage() {
        XCTAssertEqual(DiscordMessage.postURL(for: URL(string: "https://discord.com/api/webhooks/1/token")!).absoluteString,
                       "https://discord.com/api/webhooks/1/token?with_components=true&wait=true")
        XCTAssertEqual(DiscordMessage.postURL(for: URL(string: "https://discord.com/api/webhooks/1/token?thread_id=5")!).absoluteString,
                       "https://discord.com/api/webhooks/1/token?thread_id=5&with_components=true&wait=true")
    }

    /// Only a 200 whose JSON has a non-empty `id` means Discord saved the message.
    func testOnlyA200WithAnIdIsASavedMessage() {
        XCTAssertEqual(WebhookResponse(status: 200, body: Data(#"{"id":"123","type":0}"#.utf8)).savedMessageID, "123")
        XCTAssertNil(WebhookResponse(status: 200, body: Data("{}".utf8)).savedMessageID)
        XCTAssertNil(WebhookResponse(status: 200, body: Data(#"{"id":""}"#.utf8)).savedMessageID)
        XCTAssertNil(WebhookResponse(status: 200, body: Data(#"{"id":123}"#.utf8)).savedMessageID)
        XCTAssertNil(WebhookResponse(status: 200, body: Data("ok".utf8)).savedMessageID)
        XCTAssertNil(WebhookResponse(status: 204).savedMessageID)
        XCTAssertNil(WebhookResponse(status: 201, body: Data(#"{"id":"1"}"#.utf8)).savedMessageID)
    }
}
