import Foundation

/// The map as an agent reads it from `linkc_get_project_context`: the system, each place with
/// its components, then the notes. No coordinates — they mean nothing to an agent.
public enum BoardReport {
    /// "" when the map says nothing — an empty section is noise in a tool result.
    public static func markdown(for map: BoardMap) -> String {
        let system = map.system?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !map.components.isEmpty || !map.notes.isEmpty || !system.isEmpty else { return "" }

        var text = "## System\n"
        text += "_Status here is not checked — this is only what the file says. linkC's board is what shows what is actually running._\n"
        if !system.isEmpty { text += "\(sanitized(system))\n" }

        // Every place a component names, even one with no frame, so nothing is ever dropped.
        let labels = Set(map.frames.map(\.label)).union(map.components.map(\.place)).subtracting([BoardMap.notPlaced])
        let order = labels.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } + [BoardMap.notPlaced]
        for place in order {
            let members = map.components
                .filter { $0.place == place }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !members.isEmpty else { continue }
            text += "\n### \(sanitized(place))\n"
            for component in members { text += line(for: component) }
        }

        if !map.notes.isEmpty {
            text += "\n### Notes\n"
            for note in map.notes { text += "- \(sanitized(note.text))\n" }
        }
        return text + "\n"
    }

    private static func line(for component: BoardComponent) -> String {
        var head = "- **\(sanitized(component.name))** (\(sanitized(component.kind.raw))"
        if let tech = nonEmpty(component.tech) { head += " · \(sanitized(tech))" }
        if component.planned { head += ", PLANNED — does not exist yet" }
        head += ")"

        var parts: [String] = []
        if let does = nonEmpty(component.does) { parts.append(sanitized(does)) }
        if let reachedBy = nonEmpty(component.reachedBy) { parts.append("reached by \(sanitized(reachedBy))") }
        if let runs = nonEmpty(component.runs) { parts.append("runs \(sanitized(runs))") }
        if !component.uses.isEmpty {
            let uses = component.uses.keys.sorted().map { target -> String in
                let label = component.uses[target] ?? ""
                return label.isEmpty ? sanitized(target) : "\(sanitized(target)) (\(sanitized(label)))"
            }
            parts.append("uses \(uses.joined(separator: ", "))")
        }
        if !component.legacyUsedBy.isEmpty {
            parts.append("used by \(component.legacyUsedBy.map(sanitized).joined(separator: ", "))")
        }
        return parts.isEmpty ? "\(head)\n" : "\(head) — \(parts.joined(separator: "; "))\n"
    }

    private static func nonEmpty(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A single field's worth of text taken straight from `system-map.json` — a file that may come
    /// from a cloned repository, so it is not trusted input. It must never be able to introduce
    /// markdown structure into a report an agent reads as instructions: a newline could open a
    /// forged heading or bullet, and `**`/backticks could forge emphasis or a code span that
    /// swallows text around it. It is also capped, so one field cannot balloon a tool result.
    private static let maxFieldLength = 200

    /// Neutralises one field's worth of text taken from `system-map.json` so it cannot forge
    /// markdown structure — used for every field this report prints, and for any other text
    /// pulled from the file that lands in a markdown report an agent reads (a parse error can
    /// carry a name straight from the file, for instance).
    static func sanitized(_ text: String) -> String {
        var collapsed = ""
        collapsed.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" || CharacterSet.controlCharacters.contains(scalar) {
                collapsed.unicodeScalars.append(" ")
            } else {
                collapsed.unicodeScalars.append(scalar)
            }
        }

        // `_` is left alone: legitimate fields are full of it (env var names like
        // `DATABASE_URL`), and underscore-emphasis needs a pair with no space touching either
        // inner edge to render at all, so a lone `_` cannot forge structure the way `*` or a
        // backtick can.
        //
        // The escape character itself is escaped first. Otherwise a field's own backslash
        // sitting right next to a `*` or backtick combines with the backslash this function
        // inserts — `\*` becomes `\\*`, an escaped backslash followed by a live, unescaped
        // asterisk — cancelling the very escaping this is meant to guarantee.
        var neutralised = ""
        neutralised.reserveCapacity(collapsed.count)
        for character in collapsed {
            switch character {
            case "\\": neutralised.append("\\")
            case "*", "`": neutralised.append("\\")
            default: break
            }
            neutralised.append(character)
        }

        if neutralised.count > maxFieldLength {
            return String(neutralised.prefix(maxFieldLength)) + "…"
        }
        return neutralised
    }
}
