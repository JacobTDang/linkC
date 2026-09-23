import Foundation

/// The map as an agent reads it, in the same markdown the project-context tool already returns.
public enum SystemMapReport {
    /// "" when the map names nothing — an empty section is noise in a tool result.
    public static func markdown(for map: SystemMap, statuses: [String: ComponentStatus]) -> String {
        guard !map.components.isEmpty else { return "" }
        var text = "## System\n"
        for component in map.components {
            var parts: [String] = [component.kind.raw]
            if let reachedBy = component.reachedBy, !reachedBy.isEmpty { parts.append("reached by \(reachedBy)") }
            if let runs = component.runs, !runs.isEmpty { parts.append("runs \(runs)") }
            if !component.usedBy.isEmpty { parts.append("used by \(component.usedBy.joined(separator: ", "))") }
            if component.intended {
                parts.append("INTENDED — does not exist yet")
            } else {
                switch statuses[component.name] {
                case .present: parts.append("running now")
                case .missing: parts.append("NOT running")
                case .unchecked, nil: break
                }
            }
            text += "- **\(component.name)** — \(parts.joined(separator: " · "))\n"
        }
        return text + "\n"
    }
}
