import Foundation

/// Incremental line reader over growing transcript files. Remembers a byte offset per path
/// and returns only complete lines appended since the last read — the offset never advances
/// past a partial trailing line, so a JSONL record mid-write is never handed out half-parsed.
/// A shrunken file (rotation/truncation) resets to the beginning. Missing files read as [].
public final class TranscriptTailReader {
    private var offsets: [String: UInt64] = [:]

    public init() {}

    /// Complete lines appended since the last read of `path`. On a path's *first* read,
    /// `firstReadTailCap` (bytes) optionally seeks to `size - cap` and drops the leading
    /// partial line — bounding the cost of scanning a large historical file.
    public func readNewLines(at path: String, firstReadTailCap: Int? = nil) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }

        var start: UInt64
        var dropFirstLine = false
        if let stored = offsets[path] {
            start = stored > size ? 0 : stored  // truncated → start over
        } else if let cap = firstReadTailCap, size > UInt64(cap) {
            start = size - UInt64(cap)
            dropFirstLine = true  // almost certainly lands mid-line
        } else {
            start = 0
        }
        guard start < size else { return [] }

        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else { return [] }

        // A capped first read almost certainly landed mid-line: skip through the first
        // newline. Unless the cap landed exactly *on* one — then the next line is whole.
        if dropFirstLine, text.first != "\n" {
            guard let firstNewline = text.firstIndex(of: "\n") else {
                offsets[path] = start
                return []
            }
            start += UInt64(text[...firstNewline].utf8.count)
            text = String(text[text.index(after: firstNewline)...])
        }

        // Consume only through the last newline; a partial trailing line stays for next time.
        guard let lastNewline = text.lastIndex(of: "\n") else {
            offsets[path] = start
            return []
        }
        offsets[path] = start + UInt64(text[...lastNewline].utf8.count)
        return text[..<lastNewline].split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
