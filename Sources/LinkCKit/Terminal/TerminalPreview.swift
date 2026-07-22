import Foundation

/// Turns raw terminal rows into home-card preview content. A Claude session's last rows are
/// usually its input-box furniture — box-drawing frames, horizontal rules, a bare prompt
/// marker — which read as noise in a 3-line preview. Rows are kept or dropped whole (kept
/// rows keep their original text); only chrome-only rows and blanks are removed.
public enum TerminalPreview {
    /// The last `lines` content rows, joined with newlines. "" when nothing qualifies.
    public static func excerpt(rows: [String], lines: Int) -> String {
        rows.filter(hasContent).suffix(lines).joined(separator: "\n")
    }

    /// A row has content when something remains after removing box-drawing/block glyphs and
    /// trimming whitespace — and that remainder is more than a bare prompt marker or one of
    /// Claude Code's status-bar banners.
    static func hasContent(_ row: String) -> Bool {
        let stripped = row.unicodeScalars.filter { !isBoxDrawing($0) }
        let text = String(String.UnicodeScalarView(stripped))
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        return !barePrompts.contains(text) && !isStatusFurniture(text)
    }

    /// Claude Code's status-bar banners — text-only chrome that sits by the input box and would
    /// otherwise dominate a 3-line preview. Patterns stay anchored so real output that carries
    /// a ⚠ or mentions MCP is never eaten.
    private static func isStatusFurniture(_ text: String) -> Bool {
        // Trailing hints are the strip's signature: the permission-mode line always ends with
        // "(shift+tab to cycle)", the spinner row with "esc to interrupt)".
        if text.hasSuffix("(shift+tab to cycle)") || text.hasSuffix("esc to interrupt)") {
            return true
        }
        if text == "? for shortcuts" { return true }

        // Banner rows, matched after any leading warning/failure glyph.
        var t = text
        if let first = t.first, "⚠✗✘".contains(first) {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let bannerPrefixes = [
            "Transcript saving is off",
            "Context left until auto-compact:",
            "Context low (",
            "Auto-update failed",
            "Press up to edit queued messages",
        ]
        if bannerPrefixes.contains(where: t.hasPrefix) { return true }
        return t.range(
            of: #"^(\d+ MCP servers? needs? authentication|Approaching [\w ]{0,24}usage limit)\b"#,
            options: .regularExpression
        ) != nil
    }

    /// Box Drawing (U+2500–U+257F) and Block Elements (U+2580–U+259F).
    private static func isBoxDrawing(_ scalar: Unicode.Scalar) -> Bool {
        (0x2500...0x259F).contains(scalar.value)
    }

    /// A prompt marker alone on its row promises input, not output — chrome either way.
    private static let barePrompts: Set<String> = ["❯", ">", "$", "›", "%"]
}
