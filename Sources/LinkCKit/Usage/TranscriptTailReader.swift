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
              var data = try? handle.readToEnd() else { return [] }

        // A capped first read almost certainly landed mid-line — and possibly mid multi-byte
        // UTF-8 character. Skip through the first newline BYTE, in the raw Data, before ever
        // decoding: a newline byte (0x0A) can never occur inside a multi-byte UTF-8 sequence,
        // so everything after it is guaranteed to start on a character boundary. Decoding
        // first and searching for "\n" in the resulting String would fail the whole buffer
        // the moment the cut splits a character, discarding a real record along with the
        // partial line. Unless the cap landed exactly *on* a newline — then nothing to skip.
        if dropFirstLine, data.first != 0x0A {
            guard let firstNewline = data.firstIndex(of: 0x0A) else {
                offsets[path] = start
                return []
            }
            let consumed = data.distance(from: data.startIndex, to: firstNewline) + 1
            start += UInt64(consumed)
            data = data[data.index(after: firstNewline)...]
        }

        guard var text = String(data: data, encoding: .utf8) else { return [] }

        // Consume only through the last newline; a partial trailing line stays for next time.
        guard let lastNewline = text.lastIndex(of: "\n") else {
            offsets[path] = start
            return []
        }
        offsets[path] = start + UInt64(text[...lastNewline].utf8.count)
        return text[..<lastNewline].split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
