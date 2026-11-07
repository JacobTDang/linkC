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
