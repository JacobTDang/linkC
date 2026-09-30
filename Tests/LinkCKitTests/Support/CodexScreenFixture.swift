import Foundation
import XCTest

/// Screens captured from Codex 0.159.0 with `tmux capture-pane -p`, launched with the argv linkC
/// uses and given linkC-style briefs (a bracketed paste, then Enter). Each `Fixtures/codex-*.txt`
/// is one frame as Codex drew it, with only trailing blanks trimmed.
enum CodexScreenFixture {
    private static func lines(_ name: String) throws -> [String] {
        let bundle = Bundle.module
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "txt")
                ?? bundle.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"),
            "test fixture \(name).txt not found in test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    /// The rows a `ScreenSnapshot` of the frame holds: every row that has any content.
    static func rows(_ name: String) throws -> [String] {
        try lines(name).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The frame as terminal input that draws it on a fresh screen. With `replacing`, the first row
    /// that contains that text is drawn as `row` instead.
    static func terminalInput(_ name: String, replacing marker: String? = nil, with row: String = "") throws -> String {
        var frame = try lines(name)
        if let marker {
            let index = try XCTUnwrap(frame.firstIndex { $0.contains(marker) }, "no row of \(name) contains \(marker)")
            frame[index] = row
        }
        return "\u{1b}[2J\u{1b}[H" + frame.joined(separator: "\r\n")
    }
}
