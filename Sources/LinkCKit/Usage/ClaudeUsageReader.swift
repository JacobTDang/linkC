import Foundation

/// Reads what Claude has left from its own transcripts under `~/.claude/projects`. Delegates
/// the arithmetic to the same pure pieces the panel footer uses (`TranscriptUsage`,
/// `UsageWindows`), and the byte-level reading to `TranscriptBackwardReader` — both are plain
/// `Sendable` and hold no state, so this runs unchanged in the MCP server's separate process.
///
/// A real `~/.claude/projects` can hold thousands of transcripts and a gigabyte or more.
/// Transcripts are append-only JSONL, and each usage line carries a timestamp, so reading a
/// file backward from its end lets a scan *prove* it covered a window — by reaching the
/// file's start or a whole chunk of provably older lines — rather than guessing from a fixed
/// byte cut. The 5-hour window is exempt from the shared budget: every file modified in the
/// last 5 hours is read back to the 5-hour boundary under its own large, injectable safety
/// cap, which only protects against a pathological single file. The 7-day window spends a
/// shared budget continuing those same reads (and any older files) further back; when the
/// budget runs out before a file's read reaches its 7-day boundary or its start,
/// `UsageWindow.tokensAreLowerBound` says so rather than presenting a truncated sum as exact.
public struct ClaudeUsageReader: Sendable {
    private let projectsDirectory: URL
    private let byteBudget: Int
    private let fiveHourSafetyCapBytes: Int
    private let chunkSizeBytes: Int

    /// Only transcripts touched in the last week can contribute to either window; mirrors
    /// `UsageTracker`'s scan window for the same reason.
    private static let scanWindow: TimeInterval = 7 * 24 * 3600
    /// Only transcripts touched in the last 5 hours are read under the 5-hour exemption; a
    /// file modified before this always sorts, and is treated, as week-only.
    private static let fiveHourWindow: TimeInterval = 5 * 3600

    /// Chunk size for `TranscriptBackwardReader`'s backward reads. Measured against this
    /// machine's real projects directory (1,814 transcripts, 1.1 GB): 64 KB took 3.85s
    /// unbounded, 256 KB 3.15s, 1 MB 3.05s — most of the win is by 256 KB, with only marginal
    /// gains beyond it, so a bigger chunk mostly just risks reading further past a window
    /// boundary than needed. See task-10-report.md for the full sweep.
    public static let defaultChunkSizeBytes = 256 * 1024
    /// Per-file safety cap for the 5-hour exemption. Deliberately large — it exists only to
    /// bound a pathological single file (e.g. one huge tool-result-only transcript with no
    /// usage lines at all), not to constrain a normal 5-hour read. On this machine's real
    /// data, every 5-hour file's read finished within about 4 MB regardless of the cap
    /// (unflagged from 4 MB up to 64 MB, same token total each time); 64 MB leaves roughly
    /// 16x headroom over that observed need. See task-10-report.md for the sweep.
    public static let defaultFiveHourSafetyCapBytes = 64 * 1024 * 1024
    /// Shared budget spent across every file's 7-day read (including extending 5-hour files
    /// further back). Measured directly against this machine's real projects directory: an
    /// unbounded read finishes in ~3.1-3.5s; 64 MB reaches about 68% of the unbounded 7-day
    /// total in ~1.3s, versus 8 MB's ~34% in ~0.56s. The 5-hour figure is unaffected either
    /// way — it never spends this budget. See task-10-report.md for the full sweep.
    public static let defaultByteBudget = 64 * 1024 * 1024

    public init(
        projectsDirectory: URL,
        byteBudget: Int = defaultByteBudget,
        fiveHourSafetyCapBytes: Int = defaultFiveHourSafetyCapBytes,
        chunkSizeBytes: Int = defaultChunkSizeBytes
    ) {
        self.projectsDirectory = projectsDirectory
        self.byteBudget = byteBudget
        self.fiveHourSafetyCapBytes = fiveHourSafetyCapBytes
        self.chunkSizeBytes = chunkSizeBytes
    }

    public func read() -> AgentUsage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectsDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return unavailable("no ~/.claude/projects directory")
        }
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return unavailable("no ~/.claude/projects directory")
        }

        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.scanWindow)
        let fiveHourCutoff = now.addingTimeInterval(-Self.fiveHourWindow)

        var newestModified: Date?
        var candidates: [(url: URL, modified: Date)] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate
            else { continue }
            if newestModified == nil || modified > newestModified! { newestModified = modified }
            guard modified >= cutoff else { continue }
            candidates.append((url, modified))
        }

        guard let observedAt = newestModified else {
            return unavailable("no session records found")
        }

        // Newest-first puts every 5-hour-window file ahead of every older-but-within-week
        // file automatically (a newer mtime always sorts first).
        let ordered = candidates.sorted { $0.modified > $1.modified }

        // Fed to `UsageWindows.compute` as one set, exactly like the old reader did: its own
        // block-boundary detection (`floorToHour` plus the gap logic) needs every message in
        // range to identify the true current block, not just what happens to be newer than a
        // naive cutoff. A still-active 5-hour block's start can never be more than 5 hours
        // before `now` (otherwise the block would already have expired), so every message
        // that can belong to it necessarily has a timestamp after `fiveHourCutoff` — reading
        // every 5-hour-classified file back to that cutoff is therefore always enough for the
        // block figure to be exact whenever `fiveHourFullyRead` holds, independent of whether
        // the week figure also finished.
        var usages: [MessageUsage] = []
        var fiveHourFullyRead = true
        var weekFullyRead = true
        var sharedBudgetRemaining = byteBudget

        for file in ordered {
            var resumeOffset: UInt64?
            var resumeLeftover = Data()

            if file.modified >= fiveHourCutoff {
                let block = TranscriptBackwardReader.scan(
                    path: file.url.path, windowStart: fiveHourCutoff,
                    chunkSize: chunkSizeBytes, maxBytes: fiveHourSafetyCapBytes)

                usages.append(contentsOf: block.usages.filter { $0.timestamp >= cutoff })
                if !block.reachedBoundary { fiveHourFullyRead = false }

                if block.reachedBoundary && block.stoppedAtOffset == 0 {
                    // The 5-hour safety cap already read this file to its start; nothing more
                    // to extend for the week window.
                    continue
                }
                resumeOffset = block.stoppedAtOffset
                resumeLeftover = block.pendingLeftover
            }

            guard sharedBudgetRemaining > 0 else {
                weekFullyRead = false
                continue
            }

            let week = TranscriptBackwardReader.scan(
                path: file.url.path, windowStart: cutoff,
                chunkSize: chunkSizeBytes, maxBytes: sharedBudgetRemaining,
                startOffset: resumeOffset, initialLeftover: resumeLeftover)

            usages.append(contentsOf: week.usages.filter { $0.timestamp >= cutoff })
            if !week.reachedBoundary { weekFullyRead = false }
            sharedBudgetRemaining -= week.bytesRead
        }

        let window = UsageWindows.compute(usages, now: now)
        return AgentUsage(
            agent: .claude,
            windows: [
                UsageWindow(label: "5h", usedPercent: nil, tokens: window.blockTokens,
                            resetsAt: window.blockResetAt, tokensAreLowerBound: !fiveHourFullyRead),
                UsageWindow(label: "7d", usedPercent: nil, tokens: window.weekTokens,
                            resetsAt: nil, tokensAreLowerBound: !weekFullyRead)
            ],
            planType: nil,
            observedAt: observedAt,
            unavailableReason: nil
        )
    }

    private func unavailable(_ reason: String) -> AgentUsage {
        AgentUsage(agent: .claude, windows: [], planType: nil, observedAt: nil, unavailableReason: reason)
    }
}
