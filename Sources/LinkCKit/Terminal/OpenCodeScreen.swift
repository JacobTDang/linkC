import Foundation

/// OpenCode's TUI, read from its screen rows (OpenCode 2.2.5 and 1.18.19; `Fixtures/opencode-*.txt`).
/// Kilo's TUI matches this chrome (`Fixtures/kilo-*.txt`), so Kilo sessions reuse the same reader.
/// Its input box ends on a heavy edge ("╹▀▀▀…") with a footer under it. While a turn runs, the
/// footer opens with an 8-glyph progress bar of "⬝"/"■" — followed by the interrupt hint, though a
/// narrow screen can show the bar alone; once the turn ends, the footer shows the folder path.
///
/// While the model thinks, a Braille spinner row sits right above the box and its turn header. On
/// 2.2.5 the session title row, the screen's first row, carries a spinner of its own all through a
/// turn (1.18.19 has no title row), and a tool call still pending draws one inside the "┃" block;
/// neither is the thinking row.
enum OpenCodeScreen {
    enum Turn: Equatable {
        case idle
        case working(phrase: String)

        var phrase: String? {
            if case .working(let phrase) = self { return phrase }
            return nil
        }
    }

    /// The turn an OpenCode screen shows; nil when `rows` are not OpenCode's.
    static func turn(in rows: [String]) -> Turn? {
        guard let edge = rows.lastIndex(where: isInputBoxEdge) else { return nil }
        let footer = rows[(edge + 1)...].map(TerminalPreview.visibleText).first { !$0.isEmpty }
        guard let footer, isProgressRow(footer) else { return .idle }
        return .working(phrase: thinkingPhrase(above: edge, in: rows) ?? "Working")
    }

    /// The row that closes OpenCode's input box: "╹" and then a run of "▀".
    static func isInputBoxEdge(_ row: String) -> Bool {
        let trimmed = row.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "╹" else { return false }
        let rest = trimmed.dropFirst()
        return rest.count >= 8 && rest.allSatisfy { $0 == "▀" }
    }

    private static let progressBar = try! NSRegularExpression(pattern: "^[⬝■]{8}")

    /// Whether `text` (a row's visible text) is OpenCode's working footer: it opens with the
    /// 8-glyph progress bar. The hint after it is not required — a narrow screen leaves it out.
    static func isProgressRow(_ text: String) -> Bool {
        progressBar.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The phrase of the thinking row right above the box ("⠋ Thinking" gives "Thinking"), nil when
    /// the row there is not a Braille spinner row. Going up from the box's edge, the rows that belong
    /// to the box and its turn header are skipped: each opens with "┃" (the box, and the transcript
    /// block directly above it, where a pending tool call's own spinner sits) or with "▣" (the
    /// assistant header "▣  Build · <model>" that OpenCode 1.18.19 draws between the spinner row and
    /// the box). The next row up is the only candidate. On 2.2.5 the screen's first row is the session
    /// title, so the first row is never one, however few rows sit between it and the box.
    private static func thinkingPhrase(above edge: Int, in rows: [String]) -> String? {
        guard let candidate = rows[..<edge].lastIndex(where: { !isBoxFurniture($0) }), candidate > 0 else { return nil }
        let text = TerminalPreview.visibleText(rows[candidate])
        guard let first = text.unicodeScalars.first, (0x2800...0x28FF).contains(first.value) else { return nil }
        let phrase = String(text.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
        return phrase.isEmpty ? nil : phrase
    }

    /// Whether a row belongs to the input box or its turn header: its first glyph is "┃" or "▣".
    private static func isBoxFurniture(_ row: String) -> Bool {
        let first = row.trimmingCharacters(in: .whitespaces).first
        return first == "┃" || first == "▣"
    }
}
