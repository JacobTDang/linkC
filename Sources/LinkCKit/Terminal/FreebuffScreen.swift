import Foundation

/// Freebuff 0.2.36's terminal UI, captured from the real CLI.
public enum FreebuffScreen {
    public static func activity(in rows: [String]) -> String? {
        let recent = rows.suffix(16).map { $0.trimmingCharacters(in: .whitespaces) }
        let status = recent.joined(separator: "\n")
        let isActive = recent.contains(where: { $0.contains("■ Esc") })
            || status.contains("retrying...")
            || status.contains("high demand — in line, starting soon...")
            || status.contains("Can't reach Freebuff's servers. Retrying… Try another network.")
            || (looksLikeFreebuff(rows) && recent.contains(where: isBareElapsedTimer))
        guard isActive else { return nil }
        if recent.contains(where: { $0.hasPrefix("thinking...") || $0.hasPrefix("Thinking") }) {
            return "Thinking"
        }
        return "Working"
    }

    public static func isWaitingForUser(in rows: [String]) -> Bool {
        let text = rows.joined(separator: "\n")
        return text.contains("Load and run these? [y/N]")
            || (text.contains("Some questions for you")
            && text.contains("Submit")
            && text.contains("Enter select"))
    }

    /// Distinctive Freebuff chrome/status text used to prevent another agent's generic reader from
    /// treating Freebuff prompts, ads, queue messages, or its bare timer as that agent's activity.
    public static func looksLikeFreebuff(_ rows: [String]) -> Bool {
        let text = rows.joined(separator: "\n")
        return (text.contains("DeepSeek V4.1 Flash") && text.contains("/model to change"))
            || text.contains("Freebuff's servers")
            || text.contains("Refer friends → earn hours")
            || text.contains("Some questions for you")
            || text.contains("Load and run these? [y/N]")
    }

    private static func isBareElapsedTimer(_ text: String) -> Bool {
        text.range(of: #"^\d+(?:\.\d+)?s$"#, options: .regularExpression) != nil
    }
}
