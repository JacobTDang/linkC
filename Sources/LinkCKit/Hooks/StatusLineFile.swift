import Foundation

/// The file a session's status-line command writes Claude's status JSON into: one line, ended by a
/// newline (`SettingsComposer.statusLineCommand`). The command opens the file, which empties it,
/// and then writes the line in one piece, so a read can land between the two, or in the middle of
/// the write. This reads the file and says which of those it found.
public enum StatusLineFile {
    public enum Outcome: Equatable, Sendable {
        /// One complete report, without its line end, and the rate-limit figures it carries — nil
        /// when it names no window (an API-key plan, or a session before its first reply).
        case report(body: Data, reading: AgentUsage?)
        /// Nothing in the file: no refresh yet, or emptied and not yet rewritten.
        case empty
        /// Bytes but no line end: a write caught in flight. The rest is on its way.
        case torn
        /// The file could not be read at all.
        case unreadable(String)
        /// A complete line that is not the JSON Claude sends.
        case garbage(String)
    }

    /// The command rewrites the file from its start without shortening it, so a shorter report
    /// leaves the tail of the previous, longer one behind its own line end. Only the first line
    /// counts.
    public static func read(at url: URL, receivedAt: Date) -> Outcome {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable("could not read \(url.path) — \(error)")
        }
        guard !data.isEmpty else { return .empty }
        guard let lineEnd = data.firstIndex(of: UInt8(ascii: "\n")) else { return .torn }
        let body = Data(data[data.startIndex..<lineEnd])
        do {
            return .report(body: body, reading: try ClaudeRateLimits.decode(body, receivedAt: receivedAt))
        } catch {
            return .garbage("the report in \(url.path) is not Claude's status JSON — \(error)")
        }
    }
}
