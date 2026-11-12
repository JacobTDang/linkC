import Foundation

/// Crush's TUI, read from its screen rows (Crush v0.101.0; `Fixtures/crush-0.101.0-*.txt`).
///
/// The screen's last row is a footer of key hints. While a turn runs it opens with "esc cancel"
/// ("esc press again to cancel" after one Esc, "esc clear queue" while a prompt waits in the queue),
/// behind an optional "YOLO MODE" tag; when the session is ready it opens with "tab focus chat" or
/// "tab change focus". An error replaces the footer for a few seconds, and then the screen is ready
/// again. Before the turn's first token a row of 15 scrambled glyphs and a clock ("%$(E*%B5F+f€b67 3s")
/// shows above the editor; it redraws on its own, so it is not progress.
///
/// A permission dialog covers the screen with a boxed "Permission Required" title, the tool, and the
/// choices "Allow", "Allow for Session" and "Deny"; its footer still says "esc cancel". Without a key,
/// Crush asks for a provider and a model ("To start, let's choose a provider and model.") and then for
/// the key ("Enter your OpenRouter Key."). None of these is a turn.
enum CrushScreen {
    enum State: Equatable {
        case idle
        case working
        case waitingPermission
        /// A provider, model or key dialog asks for something Crush needs before it can run a turn.
        case needsSetup
    }

    /// The state a Crush screen shows; nil when `rows` are not Crush's.
    static func state(in rows: [String]) -> State? {
        if isPermissionPrompt(rows) { return .waitingPermission }
        let texts = rows.map(TerminalPreview.visibleText).filter { !$0.isEmpty }
        guard isCrush(texts) else { return nil }
        if texts.contains(where: isSetupRow) { return .needsSetup }
        if let footer = texts.last, isWorkingFooter(footer) { return .working }
        return .idle
    }

    /// The provider whose key Crush asks for ("Enter your OpenRouter Key." gives "OpenRouter"); nil
    /// when the screen asks for none.
    static func keyRequested(in rows: [String]) -> String? {
        for text in rows.map(TerminalPreview.visibleText) {
            guard let match = keyRequest.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let name = Range(match.range(at: 1), in: text) else { continue }
            return String(text[name])
        }
        return nil
    }

    // MARK: - Recognising Crush

    /// Crush's logo and its compact header both carry "Charm™"; a permission dialog is recognised on
    /// its own, since it covers them.
    private static func isCrush(_ texts: [String]) -> Bool {
        texts.prefix(8).contains { $0.contains("Charm™") }
    }

    // MARK: - Footer

    private static let workingFooter = try! NSRegularExpression(
        pattern: #"^(?:YOLO MODE\s+)?esc (?:cancel|press again to cancel|clear queue)\b"#)

    /// Whether `text` (a row's visible text) is the footer of a running turn.
    static func isWorkingFooter(_ text: String) -> Bool {
        workingFooter.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - Spinner

    private static let spinnerRow = try! NSRegularExpression(
        pattern: #"^[0-9A-Za-z!@#$%^&*()_+=~€]{15} \d+[hms](?: \d+[ms])*$"#)

    /// Whether `text` (a row's visible text) is the spinner row: 15 scrambled glyphs, then the turn's
    /// clock. A real word of 15 letters, or a row of plain output ending in a duration, is not one:
    /// the glyphs always include a digit or a symbol.
    static func isSpinnerRow(_ text: String) -> Bool {
        guard spinnerRow.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return false }
        return text.prefix(15).contains { !$0.isLetter }
    }

    // MARK: - Dialogs

    private static let keyRequest = try! NSRegularExpression(pattern: #"^Enter your (.+) Key\.$"#)

    private static func isSetupRow(_ text: String) -> Bool {
        text == "To start, let's choose a provider and model."
            || keyRequest.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The permission dialog: a boxed "Permission Required" title with the choice row under it. On a
    /// wide screen the box sits over the transcript, so text can come before its edge on the same row.
    /// The title quoted in output has no box edge before it and no choices after it.
    /// Read from the raw rows: the box edge is what tells the dialog from a quotation of its title,
    /// and `visibleText` removes it.
    private static func isPermissionPrompt(_ rows: [String]) -> Bool {
        guard let title = rows.lastIndex(where: { $0.contains("│  Permission Required") }) else { return false }
        return rows[(title + 1)...].contains { $0.contains("Allow for Session") && $0.contains("Deny") }
    }
}
