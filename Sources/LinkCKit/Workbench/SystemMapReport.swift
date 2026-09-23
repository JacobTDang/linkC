import Foundation

/// The map as an agent reads it, in the same markdown the project-context tool already returns.
public enum SystemMapReport {
    /// "" when the map names nothing — an empty section is noise in a tool result.
    public static func markdown(for map: SystemMap, statuses: [String: ComponentStatus]) -> String {
        guard !map.components.isEmpty else { return "" }
        var text = "## System\n"
        for component in map.components {
            var parts: [String] = [sanitized(component.kind.raw)]
            if let reachedBy = component.reachedBy, !reachedBy.isEmpty { parts.append("reached by \(sanitized(reachedBy))") }
            if let runs = component.runs, !runs.isEmpty { parts.append("runs \(sanitized(runs))") }
            if !component.usedBy.isEmpty {
                parts.append("used by \(component.usedBy.map(sanitized).joined(separator: ", "))")
            }
            if component.intended {
                parts.append("INTENDED — does not exist yet")
            } else {
                switch statuses[component.name] {
                case .present: parts.append("running now")
                case .missing: parts.append("NOT running")
                case .unchecked, nil: break
                }
            }
            text += "- **\(sanitized(component.name))** — \(parts.joined(separator: " · "))\n"
        }
        return text + "\n"
    }

    /// A single field's worth of text taken straight from `system-map.json` — a file that may come
    /// from a cloned repository, so it is not trusted input. It must never be able to introduce
    /// markdown structure into a report an agent reads as instructions: a newline could open a
    /// forged heading or bullet, and `**`/backticks could forge emphasis or a code span that
    /// swallows text around it. It is also capped, so one field cannot balloon a tool result.
    private static let maxFieldLength = 200

    private static func sanitized(_ text: String) -> String {
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
        var neutralised = ""
        neutralised.reserveCapacity(collapsed.count)
        for character in collapsed {
            switch character {
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
