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

    /// Only the first line counts. The command's `>` empties the file before it writes, so one run
    /// never leaves an older report's tail behind its own line end. Bytes after the first line
    /// end come from two runs overlapping (the CLI can start a refresh while the last one's shell is
    /// still writing): the later, shorter report ends where the earlier, longer one still has
    /// bytes. The first line is a whole report all the same.
    public static func read(at url: URL, receivedAt: Date) -> Outcome {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable("could not read \(url.path) — \(describe(error))")
        }
        guard !data.isEmpty else { return .empty }
        guard let lineEnd = data.firstIndex(of: UInt8(ascii: "\n")) else { return .torn }
        let body = Data(data[data.startIndex..<lineEnd])
        do {
            return .report(body: body, reading: try ClaudeRateLimits.decode(body, receivedAt: receivedAt))
        } catch {
            return .garbage("the report in \(url.path) is not Claude's status JSON — \(describe(error))")
        }
    }

    /// An error as text that reads the same every time it happens. `"\(error)"` prints a Cocoa error
    /// with its userInfo — an underlying error's address, a dictionary in no fixed order — so one
    /// unchanged bad file would read as a new failure on every refresh, and the feed, which logs a
    /// failure once by comparing messages, would log it every time.
    private static func describe(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let context) = error,
           let underlying = context.underlyingError as NSError? {
            let detail = underlying.userInfo[NSDebugDescriptionErrorKey] as? String ?? underlying.localizedDescription
            return "\(context.debugDescription) \(detail)"
        }
        if error is DecodingError { return "\(error)" }
        return (error as NSError).localizedDescription
    }
}
