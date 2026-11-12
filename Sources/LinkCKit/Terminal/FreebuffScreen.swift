import Foundation

/// Freebuff 0.2.36's terminal UI, captured from the real CLI.
public enum FreebuffScreen {
    public static func activity(in rows: [String]) -> String? {
        let recent = rows.suffix(16).map { $0.trimmingCharacters(in: .whitespaces) }
        guard recent.contains(where: { $0.contains("■ Esc") }) else { return nil }
        if recent.contains(where: { $0.hasPrefix("thinking...") || $0.hasPrefix("Thinking") }) {
            return "Thinking"
        }
        return "Working"
    }

    public static func isWaitingForUser(in rows: [String]) -> Bool {
        let text = rows.joined(separator: "\n")
        return text.contains("Some questions for you")
            && text.contains("Submit")
            && text.contains("Enter select")
    }
}
