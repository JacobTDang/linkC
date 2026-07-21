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
    /// trimming whitespace — and that remainder is more than a bare prompt marker.
    static func hasContent(_ row: String) -> Bool {
        let stripped = row.unicodeScalars.filter { !isBoxDrawing($0) }
        let text = String(String.UnicodeScalarView(stripped))
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        return !barePrompts.contains(text)
    }

    /// Box Drawing (U+2500–U+257F) and Block Elements (U+2580–U+259F).
    private static func isBoxDrawing(_ scalar: Unicode.Scalar) -> Bool {
        (0x2500...0x259F).contains(scalar.value)
    }

    /// A prompt marker alone on its row promises input, not output — chrome either way.
    private static let barePrompts: Set<String> = ["❯", ">", "$", "›", "%"]
}
