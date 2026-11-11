import XCTest
@testable import LinkCKit

/// Posts a card of each tone and a digest to a preview channel through the real transport (spec §5.4).
/// It runs only with DISCORD_PREVIEW_WEBHOOK_URL set:
/// `DISCORD_PREVIEW_WEBHOOK_URL="<a test channel's webhook URL>" swift test --filter DiscordLivePreviewTests`.
/// Then look at the channel: Discord saving a message says nothing about how it reads.
final class DiscordLivePreviewTests: XCTestCase {
    func testEveryKindOfMessageIsSavedInThePreviewChannel() async throws {
        guard let text = ProcessInfo.processInfo.environment["DISCORD_PREVIEW_WEBHOOK_URL"], !text.isEmpty else {
            throw XCTSkip("DISCORD_PREVIEW_WEBHOOK_URL is not set")
        }
        let webhook = try DiscordWebhookURL.parse(text).get()
        let at = Date()
        let folder = "/Users/me/Projects/linkC"
        let events = [
            LinkCEvent(kind: .sessionState, tone: .done, title: "Claude · api · finished", body: "", project: folder, at: at),
            LinkCEvent(kind: .sessionState, tone: .needsYou, title: "Codex · linkC · needs permission", body: "",
                       project: folder, at: at),
            LinkCEvent(kind: .task, tone: .failed, title: "Task failed · Claude → Codex",
                       body: "AAAA1111 · fix the flaky test\ntests still red", project: folder, at: at),
            LinkCEvent(kind: .workerClosed, tone: .info, title: "Codex worker closed",
                       body: "It sat idle after its work ended.", project: folder, at: at),
        ]
        var pages = try events.flatMap { try DiscordMessage.pages([$0], dropped: 0) }
        pages += try DiscordMessage.pages(events, dropped: 2)

        let transport = URLSessionWebhookTransport()
        for page in pages {
            let response = try await transport.post(DiscordMessage.encode(page.payload),
                                                    to: DiscordMessage.postURL(for: webhook.url))
            XCTAssertNotNil(response.savedMessageID, "Discord answered \(response.status) without saving the message")
            try await Task.sleep(for: .milliseconds(600))
        }
    }
}
