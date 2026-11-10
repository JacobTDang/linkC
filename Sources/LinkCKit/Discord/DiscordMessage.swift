import Foundation

/// The body of one webhook request in the JD LLC house style: one Components V2 card per event, a digest for
/// several, within Discord's limits (spec §4.2, §5). Discord counts characters in UTF-16 units, so every limit
/// here does too.
enum DiscordMessage {
    static let maxComponents = 40          // every component in a message, the container included
    static let maxTextCharacters = 4000    // all text displays' content together, in UTF-16 units
    static let maxEventsPerPage = 15
    static let maxTitle = 100
    static let maxDetailLine = 120
    static let maxDetailLines = 4
    static let maxFolderName = 50
    static let isComponentsV2 = 1 << 15
    static let suppressNotifications = 1 << 12

    indirect enum Component: Equatable, Encodable {
        case container(accentColor: Int, [Component])   // {"type":17,"accent_color":…,"components":[…]}
        case text(String)                                // {"type":10,"content":…}
        case separator                                   // {"type":14,"divider":true,"spacing":1}

        private enum CodingKeys: String, CodingKey {
            case type
            case accentColor = "accent_color"
            case components
            case content
            case divider
            case spacing
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .container(let accentColor, let children):
                try container.encode(17, forKey: .type)
                try container.encode(accentColor, forKey: .accentColor)
                try container.encode(children, forKey: .components)
            case .text(let content):
                try container.encode(10, forKey: .type)
                try container.encode(content, forKey: .content)
            case .separator:
                try container.encode(14, forKey: .type)
                try container.encode(true, forKey: .divider)
                try container.encode(1, forKey: .spacing)
            }
        }
    }

    struct Payload: Equatable, Encodable {
        let flags: Int
        let container: Component

        private enum CodingKeys: String, CodingKey {
            case flags
            case components
            case allowedMentions = "allowed_mentions"
        }

        private struct AllowedMentions: Encodable, Equatable {
            let parse: [String] = []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(flags, forKey: .flags)
            try container.encode([self.container], forKey: .components)
            try container.encode(AllowedMentions(), forKey: .allowedMentions)
        }
    }

    struct Page: Equatable {
        let payload: Payload
        /// How many events this page carries (the dropped count is not one of them).
        let eventCount: Int
    }

    struct OverLimit: Error, LocalizedError {
        let errorDescription: String?
    }

    static func color(for tone: LinkCEvent.Tone) -> Int {
        switch tone {
        case .done: 0x57F287
        case .needsYou: 0xFEE75C
        case .failed: 0xED4245
        case .info: 0x5865F2
        }
    }

    static func emoji(for tone: LinkCEvent.Tone) -> String {
        switch tone {
        case .done: "✅"
        case .needsYou: "⚠️"
        case .failed: "❌"
        case .info: "📋"
        }
    }

    static func digestAccent(for events: [LinkCEvent]) -> Int {
        if events.contains(where: { $0.tone == .failed }) { return color(for: .failed) }
        if events.contains(where: { $0.tone == .needsYou }) { return color(for: .needsYou) }
        if events.contains(where: { $0.tone == .done }) { return color(for: .done) }
        return color(for: .info)
    }

    static func flags(for events: [LinkCEvent]) -> Int {
        var f = isComponentsV2
        if events.allSatisfy({ $0.tone == .info }) {
            f |= suppressNotifications
        }
        return f
    }

    private static let markdownEscapeCharacters: Set<Character> = [
        "\\", "*", "_", "~", "`", "|", "<", ">", "[", "]", "(", ")", "#", "@"
    ]

    static func escape(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var normalized = ""
        var inWhitespace = false
        for char in trimmed {
            if char.isWhitespace || char.isNewline {
                if !inWhitespace {
                    normalized.append(" ")
                    inWhitespace = true
                }
            } else {
                normalized.append(char)
                inWhitespace = false
            }
        }

        var pieces: [String] = []
        var totalUtf16 = 0
        for char in normalized {
            let piece = markdownEscapeCharacters.contains(char) ? "\\\(char)" : String(char)
            pieces.append(piece)
            totalUtf16 += piece.utf16.count
        }

        if totalUtf16 <= limit {
            return pieces.joined()
        }

        var kept = ""
        var units = 0
        let budget = max(0, limit - 1)
        for piece in pieces {
            let pieceUnits = piece.utf16.count
            guard units + pieceUnits <= budget else { break }
            kept.append(piece)
            units += pieceUnits
        }
        return kept + "…"
    }

    static func detailLines(for body: String) -> [String] {
        let lines = body.components(separatedBy: .newlines)
            .map { escape($0, limit: maxDetailLine) }
            .filter { !$0.isEmpty }
        guard lines.count > maxDetailLines else { return lines }
        var result = Array(lines.prefix(maxDetailLines - 1))
        let leftOut = lines.count - (maxDetailLines - 1)
        result.append("… \(leftOut) more line\(leftOut == 1 ? "" : "s")")
        return result
    }

    static func timestamp(_ date: Date) -> String {
        let unix = Int(date.timeIntervalSince1970)
        return "<t:\(unix):f> (<t:\(unix):R>)"
    }

    static func droppedLine(_ dropped: Int) -> String {
        dropped == 1 ? "⚠️ 1 earlier event was not posted." : "⚠️ \(dropped) earlier events were not posted."
    }

    static func folderName(of project: String?) -> String? {
        guard let project else { return nil }
        let last = URL(fileURLWithPath: project).lastPathComponent
        guard !last.isEmpty else { return nil }
        return escape(last, limit: maxFolderName)
    }

    static func postURL(for webhook: URL) -> URL {
        guard var components = URLComponents(url: webhook, resolvingAgainstBaseURL: false) else {
            preconditionFailure("invalid webhook URL for postURL")
        }
        var items = components.queryItems?.filter { $0.name != "with_components" && $0.name != "wait" } ?? []
        items.append(URLQueryItem(name: "with_components", value: "true"))
        items.append(URLQueryItem(name: "wait", value: "true"))
        components.queryItems = items
        guard let url = components.url else {
            preconditionFailure("could not construct postURL")
        }
        return url
    }

    static func size(_ payload: Payload) -> (components: Int, characters: Int) {
        size(of: payload.container)
    }

    private static func size(of component: Component) -> (components: Int, characters: Int) {
        switch component {
        case .container(_, let children):
            var comps = 1
            var chars = 0
            for child in children {
                let s = size(of: child)
                comps += s.components
                chars += s.characters
            }
            return (comps, chars)
        case .text(let content):
            return (1, content.utf16.count)
        case .separator:
            return (1, 0)
        }
    }

    static func check(_ payload: Payload) throws {
        let (components, characters) = size(payload)
        if components > maxComponents {
            throw OverLimit(errorDescription: "a message has \(components) components; Discord allows \(maxComponents)")
        }
        if characters > maxTextCharacters {
            throw OverLimit(errorDescription: "a message has \(characters) text characters; Discord allows \(maxTextCharacters)")
        }
        func checkEmpty(component: Component) throws {
            switch component {
            case .container(_, let children):
                for child in children { try checkEmpty(component: child) }
            case .text(let content):
                if content.isEmpty {
                    throw OverLimit(errorDescription: "a message has an empty text display")
                }
            case .separator:
                break
            }
        }
        try checkEmpty(component: payload.container)
    }

    static func encode(_ payload: Payload) throws -> Data {
        try JSONEncoder().encode(payload)
    }

    static func pages(_ events: [LinkCEvent], dropped: Int) throws -> [Page] {
        guard !events.isEmpty else { return [] }
        if events.count == 1 {
            let event = events[0]
            var children: [Component] = []
            children.append(.text("## \(emoji(for: event.tone)) \(escape(event.title, limit: maxTitle))"))
            let details = detailLines(for: event.body)
            if !details.isEmpty {
                children.append(.text(details.joined(separator: "\n")))
            }
            if dropped > 0 {
                children.append(.text(droppedLine(dropped)))
            }
            children.append(.separator)
            if let folder = folderName(of: event.project) {
                children.append(.text("-# \(folder) · \(timestamp(event.at))"))
            } else {
                children.append(.text("-# \(timestamp(event.at))"))
            }
            let payload = Payload(flags: flags(for: [event]), container: .container(accentColor: color(for: event.tone), children))
            try check(payload)
            return [Page(payload: payload, eventCount: 1)]
        }

        // Several: digest pages, oldest first.
        // Pack greedily: an event joins the current page while the page holds fewer than maxEventsPerPage
        // events and still fits both limits, measured with the longest headline suffix it could get
        // (for example " (99/99)"); otherwise it starts the next page.
        func buildDigestContainer(
            pageEvents: [LinkCEvent],
            totalEvents: Int,
            suffix: String,
            isFirstPage: Bool
        ) -> Component {
            let headline = "## 📋 \(totalEvents) linkC events\(suffix)"
            var children: [Component] = [.text(headline)]
            for e in pageEvents {
                var line = "\(emoji(for: e.tone)) **\(escape(e.title, limit: maxTitle))**"
                if let folder = folderName(of: e.project) {
                    line += " · \(folder)"
                }
                if let firstDetail = detailLines(for: e.body).first {
                    line += "\n-# \(firstDetail)"
                }
                children.append(.text(line))
            }
            if isFirstPage && dropped > 0 {
                children.append(.text(droppedLine(dropped)))
            }
            children.append(.separator)
            // A digest page carries at least one event (maxEventsPerPage is 15), so max() is never nil.
            guard let newestDate = pageEvents.map(\.at).max() else {
                preconditionFailure("a digest page has at least one event")
            }
            children.append(.text("-# \(timestamp(newestDate))"))
            return .container(accentColor: digestAccent(for: pageEvents), children)
        }

        func canFit(current: [LinkCEvent], candidate: LinkCEvent, isFirstPage: Bool) -> Bool {
            if current.count >= maxEventsPerPage { return false }
            let testEvents = current + [candidate]
            let testContainer = buildDigestContainer(
                pageEvents: testEvents,
                totalEvents: events.count,
                suffix: " (99/99)",
                isFirstPage: isFirstPage
            )
            let payload = Payload(flags: flags(for: testEvents), container: testContainer)
            let (comps, chars) = size(payload)
            return comps <= maxComponents && chars <= maxTextCharacters
        }

        var pagesEvents: [[LinkCEvent]] = []
        var current: [LinkCEvent] = []

        for event in events {
            let isFirst = pagesEvents.isEmpty
            if current.isEmpty {
                current.append(event)
            } else if canFit(current: current, candidate: event, isFirstPage: isFirst) {
                current.append(event)
            } else {
                pagesEvents.append(current)
                current = [event]
            }
        }
        if !current.isEmpty {
            pagesEvents.append(current)
        }

        var result: [Page] = []
        for (index, pageEvents) in pagesEvents.enumerated() {
            let suffix = pagesEvents.count > 1 ? " (\(index + 1)/\(pagesEvents.count))" : ""
            let container = buildDigestContainer(
                pageEvents: pageEvents,
                totalEvents: events.count,
                suffix: suffix,
                isFirstPage: index == 0
            )
            let payload = Payload(flags: flags(for: pageEvents), container: container)
            try check(payload)
            result.append(Page(payload: payload, eventCount: pageEvents.count))
        }
        return result
    }
}
