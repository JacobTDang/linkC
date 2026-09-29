import Foundation

/// One read of a terminal's visible screen. A sweep takes one snapshot per session and hands it to
/// every check, instead of each check turning the emulator's buffer into row strings again.
public struct ScreenSnapshot: Sendable {
    /// The non-blank rows, top to bottom.
    public let rows: [String]
    /// A hash of `rows` and whether there is a screen at all: equal for two snapshots of an
    /// unchanged screen, so a consumer that has already worked out something from these rows can
    /// skip working it out again. In-process only — hashing is seeded per launch.
    public let fingerprint: Int
    /// False for a session whose PTY was never started. It has no screen at all, which is not the
    /// same as a blank one.
    private let hasScreen: Bool

    /// What a session that was never started shows.
    public static let none = ScreenSnapshot(rows: [], hasScreen: false)

    init(rows: [String], hasScreen: Bool = true) {
        self.rows = rows
        self.hasScreen = hasScreen
        var hasher = Hasher()
        hasher.combine(hasScreen)
        for var row in rows {
            // The bytes, not `String`'s own hash: that normalizes every non-ASCII row (box
            // drawing, spinner glyphs) before hashing, which is most of a Claude screen.
            row.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
            hasher.combine(0 as UInt8)
        }
        self.fingerprint = hasher.finalize()
    }

    /// The last `lines` content rows, as the Terminals screen's preview shows them.
    public func recentOutput(lines: Int) -> String {
        TerminalPreview.excerpt(rows: rows, lines: lines)
    }

    /// The last `count` non-blank rows, for a log line that has to show what the screen said.
    public func recentRows(_ count: Int) -> [String] {
        Array(rows.suffix(count))
    }

    /// The live activity or spinner phrase, nil when no turn is running.
    public func liveActivity() -> String? {
        TerminalPreview.liveActivity(from: rows)
    }

    /// Whether the screen is an agent's folder-trust dialog.
    public func showsTrustPrompt() -> Bool {
        TerminalPreview.isTrustPrompt(rows)
    }

    /// The watchdog's progress signal (see `TerminalPreview.progressSignature`). "" for a session
    /// that was never started.
    public func progressSignature() -> String {
        hasScreen ? TerminalPreview.progressSignature(rows: rows) : ""
    }
}
