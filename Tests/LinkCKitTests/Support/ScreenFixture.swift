import Foundation

/// A realistic tall screen for speed and read-count tests: scrolled tool output above a spinner
/// row, Claude's boxed input, and its status footer. No usage-limit text — a test that wants a
/// banner adds its own row.
enum ScreenFixture {
    static let height = 50

    /// The rows the screen shows, top to bottom, with the blanks a real screen has between tool calls.
    /// `spinnerSeconds` is the turn timer on the spinner row; nil is an idle screen, whose row above
    /// the input box is a finished turn's summary.
    static func rows(spinnerSeconds: Int? = 46) -> [String] {
        var rows: [String] = []
        for i in 0..<(height - 8) {
            switch i % 6 {
            case 0: rows.append("⏺ Read(Sources/LinkCKit/App/AppCoordinator.swift) — \(1200 + i) lines")
            case 1: rows.append("  ⎿  Read 200 lines (ctrl+r to expand)")
            case 2: rows.append("  func sampleAgentStates() { for session in store.sessions where session.state != .ended {")
            case 3: rows.append("⏺ Update(Sources/LinkCKit/Terminal/TerminalPreview.swift)")
            case 4: rows.append("  ⎿  Updated with 12 additions and 3 removals · 42 tests passed (12.4s)")
            default: rows.append("")
            }
        }
        if let spinnerSeconds {
            rows.append("✻ Percolating… (\(spinnerSeconds)s · ↓ 2.5k tokens · esc to interrupt)")
        } else {
            rows.append("✻ Brewed for 46s")
        }
        rows.append("")
        rows.append("╭──────────────────────────────────────────────────────────────────────────────────╮")
        rows.append("│ ❯                                                                                │")
        rows.append("╰──────────────────────────────────────────────────────────────────────────────────╯")
        rows.append("  ⏵⏵ bypass permissions on (shift+tab to cycle)")
        rows.append("  ? for shortcuts")
        return rows
    }

    /// `rows()` as terminal input that draws them on a fresh screen.
    static func terminalInput(spinnerSeconds: Int? = 46) -> String {
        "\u{1b}[2J\u{1b}[H" + rows(spinnerSeconds: spinnerSeconds).joined(separator: "\r\n")
    }
}
