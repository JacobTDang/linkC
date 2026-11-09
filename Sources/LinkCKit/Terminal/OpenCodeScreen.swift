import Foundation

/// OpenCode's TUI, read from its screen rows (OpenCode 2.2.5 and 1.18.19; `Fixtures/opencode-*.txt`).
/// Its input box ends on a heavy edge ("╹▀▀▀…") with a footer under it. While a turn runs, the
/// footer opens with an 8-glyph progress bar of "⬝"/"■" — followed by the interrupt hint, though a
/// narrow screen can show the bar alone; once the turn ends, the footer shows the folder path. A
/// Braille spinner row sits just above the box while the model thinks.
enum OpenCodeScreen {
    enum Turn: Equatable {
        case idle
        case working(phrase: String)

        var phrase: String? {
            if case .working(let phrase) = self { return phrase }
            return nil
        }
    }

    /// How far above the box's edge the spinner row can sit: the box's own rows, then the model row.
    private static let spinnerSearchRows = 10

    /// The turn an OpenCode screen shows; nil when `rows` are not OpenCode's.
    static func turn(in rows: [String]) -> Turn? {
        guard let edge = rows.lastIndex(where: isInputBoxEdge) else { return nil }
        let footer = rows[(edge + 1)...].map(TerminalPreview.visibleText).first { !$0.isEmpty }
        guard let footer, isProgressRow(footer) else { return .idle }
        let phrase = rows[..<edge].reversed().prefix(spinnerSearchRows).lazy.compactMap(spinnerPhrase).first
        return .working(phrase: phrase ?? "Working")
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

    /// The phrase on a Braille spinner row ("⠋ Thinking" gives "Thinking"); nil for any other row.
    /// A spinner inside a "┃" block is a tool call still pending ("┃  ⠋ Writing command…"), part of
    /// the transcript rather than the model's own thinking row, so it names no phrase.
    private static func spinnerPhrase(_ row: String) -> String? {
        guard !row.trimmingCharacters(in: .whitespaces).hasPrefix("┃") else { return nil }
        let text = TerminalPreview.visibleText(row)
        guard let first = text.unicodeScalars.first, (0x2800...0x28FF).contains(first.value) else { return nil }
        let phrase = String(text.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
        return phrase.isEmpty ? nil : phrase
    }
}
