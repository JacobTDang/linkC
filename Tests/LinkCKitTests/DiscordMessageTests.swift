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
