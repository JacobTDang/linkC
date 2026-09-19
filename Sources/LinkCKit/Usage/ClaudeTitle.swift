import Foundation

/// Claude Code names each conversation by appending `{"type":"ai-title","aiTitle":"…","sessionId":"…"}`
/// lines to its transcript; the latest one is the current title. The substring check keeps every
/// other line (nearly all of them) from paying a JSON decode.
public enum ClaudeTitle {
    private struct Line: Decodable {
        let type: String
        let aiTitle: String?
    }

    /// The title a transcript line carries, or nil for any other line, a malformed one, or a blank title.
    public static func parse(_ line: String) -> String? {
        guard line.contains("\"ai-title\"") else { return nil }
        guard let decoded = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)),
              decoded.type == "ai-title",
              let title = decoded.aiTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return title
    }
}
