import Foundation

/// Reads one transcript file backward from its end, in fixed-size byte chunks, splitting
/// strictly on newline bytes (0x0A) before ever decoding UTF-8 — a chunk boundary can never
/// land inside a multi-byte character, because 0x0A cannot occur inside one. Used to prove how
/// much of a file's tail, back to some window start, has actually been read, without loading
/// a whole multi-hundred-megabyte transcript into memory at once.
///
/// Transcripts are append-only JSONL, and each usage line carries a timestamp, so lines are in
/// chronological order to within small disorder. The scan stops the moment an *entire* chunk
/// holds only lines older than the window start — never on the first older line, which would
/// break on a small out-of-order run — or when the file's start is reached; either is a proven
/// boundary. A caller-supplied byte cap can also stop the scan first, in which case nothing is
/// proven and the caller must say so rather than presenting the sum as exact.
///
/// This is deliberately separate from `TranscriptTailReader`: that class does forward,
/// offset-tracked incremental reads for the app's live usage footer, and must not change. This
/// is a one-shot, stateless, backward scan built for a single MCP tool call.
public enum TranscriptBackwardReader {
    /// One backward pass over part of a file. A single file can need more than one pass — its
    /// own 5-hour safety cap, then the shared 7-day budget — and `stoppedAtOffset` /
    /// `pendingLeftover` let a later pass resume exactly where an earlier one stopped, without
    /// re-reading or losing a byte at the seam.
    public struct ScanResult {
        /// Every usage line resolved during this pass, unfiltered by the window — a line
        /// older than `windowStart` can still appear here, when a chunk mixed it in with
        /// newer ones. The caller filters by whichever window it is summing.
        public let usages: [MessageUsage]
        /// True only when this pass proved coverage: it reached the file's start, or found a
        /// whole chunk with no usage line at or after `windowStart`. False means the byte cap
        /// stopped it first, and nothing is proven.
        public let reachedBoundary: Bool
        /// The file offset to resume from in a later pass. 0 when the file's start was reached.
        public let stoppedAtOffset: UInt64
        /// The unresolved fragment sitting at `stoppedAtOffset`'s right edge — feed to a later
        /// pass's `initialLeftover` so a line split across passes is never dropped.
        public let pendingLeftover: Data
        /// Bytes actually read from disk during this pass, for budget bookkeeping.
        public let bytesRead: Int
    }

    /// Scans `path` backward from `startOffset` (default: the file's end) until an entire
    /// chunk is provably older than `windowStart`, the file's start is reached, or `maxBytes`
    /// have been read from disk during this call — whichever comes first.
    public static func scan(
        path: String,
        windowStart: Date,
        chunkSize: Int,
        maxBytes: Int,
        startOffset: UInt64? = nil,
        initialLeftover: Data = Data()
    ) -> ScanResult {
        let notReadable = ScanResult(
            usages: [], reachedBoundary: true, stoppedAtOffset: 0, pendingLeftover: Data(), bytesRead: 0)
        guard let handle = FileHandle(forReadingAtPath: path) else { return notReadable }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return notReadable }

        var pos = min(startOffset ?? fileSize, fileSize)
        var leftover = initialLeftover
        var usages: [MessageUsage] = []
        var bytesRead = 0
        var reachedBoundary = false

        if pos == 0 {
            if let line = decode(leftover), let usage = TranscriptUsage.parseLine(line) {
                usages.append(usage)
            }
            return ScanResult(usages: usages, reachedBoundary: true, stoppedAtOffset: 0,
                               pendingLeftover: Data(), bytesRead: 0)
        }

        while pos > 0 {
            guard bytesRead < maxBytes else { break }
            let want = min(UInt64(chunkSize), pos, UInt64(maxBytes - bytesRead))
            guard want > 0 else { break }
            let start = pos - want
            guard (try? handle.seek(toOffset: start)) != nil,
                  let raw = try? handle.read(upToCount: Int(want)), !raw.isEmpty
            else { break }

            bytesRead += raw.count
            pos = start
            let atFileStart = pos == 0
            let combined = raw + leftover

            // `leftover` never itself contains a newline (see below), so every newline found
            // here lies within `raw`. Split on 0x0A; the trailing segment (after the last
            // newline) is bounded on the right by whatever boundary `leftover` already
            // carried — true EOF on a fresh scan's first chunk, or a previously found newline
            // on every chunk after.
            var segments: [Data] = []
            var cursor = combined.startIndex
            while let newlineIndex = combined[cursor...].firstIndex(of: 0x0A) {
                segments.append(combined[cursor..<newlineIndex])
                cursor = combined.index(after: newlineIndex)
            }
            segments.append(combined[cursor...])

            let resolvedThisPass: [Data]
            if segments.count == 1 {
                // No newline anywhere in `combined` yet — the whole thing is still pending,
                // unless we've now hit the file's start, which makes it a complete first line.
                if atFileStart {
                    resolvedThisPass = segments
                    leftover = Data()
                } else {
                    resolvedThisPass = []
                    leftover = combined
                }
            } else if atFileStart {
                // Every segment, including the leading one, is now left-bounded by file start.
                resolvedThisPass = segments
                leftover = Data()
            } else {
                resolvedThisPass = Array(segments.dropFirst())
                leftover = segments[0]  // still missing its left edge; carried to the next chunk
            }

            var sawInWindow = false
            var sawOlder = false
            for segment in resolvedThisPass {
                guard let line = decode(segment), let usage = TranscriptUsage.parseLine(line) else {
                    continue  // no parseable timestamp/usage: neither evidence nor a reason to stop
                }
                usages.append(usage)
                if usage.timestamp >= windowStart { sawInWindow = true } else { sawOlder = true }
            }

            if atFileStart {
                reachedBoundary = true
                break
            }
            if sawOlder && !sawInWindow {
                // The whole chunk's evidence is older than the window — a proven boundary that
                // tolerates a small out-of-order run inside a chunk that also saw newer lines.
                reachedBoundary = true
                break
            }
        }

        return ScanResult(usages: usages, reachedBoundary: reachedBoundary, stoppedAtOffset: pos,
                           pendingLeftover: leftover, bytesRead: bytesRead)
    }

    private static func decode(_ data: Data) -> String? {
        data.isEmpty ? nil : String(data: data, encoding: .utf8)
    }
}
