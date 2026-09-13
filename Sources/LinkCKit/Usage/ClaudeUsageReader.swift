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
/// An incomplete week read can flag the 5-hour block too, not only the week total: the block's
/// start is found by walking every message forward from the earliest one available, so missing
/// older history can move that start later than a full read would. But a gap of at least 5
/// hours between two messages both proven read anchors everything from the later one onward
/// independent of anything older, so the block stays exact whenever such a gap exists at or
/// before it — see `blockIsLowerBound`.
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
        // block-boundary detection (`floorToHour` plus the 5-hour-span walk) needs every
        // message in range to identify the true current block, not just what happens to be
        // newer than a naive cutoff. A still-active block's start can never be more than 5
        // hours before `now`, so every message that can belong to it has a timestamp after
        // `fiveHourCutoff` — but the walk that finds that start is seeded by whichever message
        // is *earliest* in what it is given, and an incomplete week read can leave that earliest
        // message later than a full read's, shifting the detected start later too. Reading every
        // 5-hour-classified file back to `fiveHourCutoff` guarantees every message the block
        // could contain is present; it does not by itself guarantee the walk finds the true
        // start when older history is missing. See `blockIsLowerBound` below.
        var usages: [MessageUsage] = []
        var fiveHourFullyRead = true
        var weekFullyRead = true
        var sharedBudgetRemaining = byteBudget
        // The newest point below which the read can no longer prove every message was found:
        // nil while every file processed so far cleared its own bar (the 5-hour cap reaching
        // its boundary, or the week scan reaching `cutoff` or the file's own start). Frozen at
        // the first file that doesn't clear it — a file's mtime bounds only its *newest*
        // possible message, never how far back its content reaches, so a file the shared budget
        // never got to (or only partly read) can still hold a message anywhere up to its own
        // mtime, even one that lands inside a span some other file already proved empty. Used
        // below to tell a genuine multi-hour quiet stretch in what was actually read from a
        // budget-induced hole that only looks quiet.
        var provenFloor: Date?

        for (index, file) in ordered.enumerated() {
            var resumeOffset: UInt64?
            var resumeLeftover = Data()
            // How far back this file's own contiguous read actually got, when it didn't reach
            // a boundary that closes the file out entirely (the `continue` below).
            var fileFloor: Date?

            if file.modified >= fiveHourCutoff {
                let block = TranscriptBackwardReader.scan(
                    path: file.url.path, windowStart: fiveHourCutoff,
                    chunkSize: chunkSizeBytes, maxBytes: fiveHourSafetyCapBytes)

                usages.append(contentsOf: block.usages.filter { $0.timestamp >= cutoff })
                if !block.reachedBoundary { fiveHourFullyRead = false }

                if block.reachedBoundary && block.stoppedAtOffset == 0 {
                    // The 5-hour safety cap already read this file to its start; nothing more
                    // to extend for the week window, and nothing left unproven either.
                    continue
                }
                fileFloor = block.usages.map(\.timestamp).min()
                resumeOffset = block.stoppedAtOffset
                resumeLeftover = block.pendingLeftover
            }

            guard sharedBudgetRemaining > 0 else {
                weekFullyRead = false
                if provenFloor == nil {
                    let nextFileModified = index + 1 < ordered.count ? ordered[index + 1].modified : nil
                    provenFloor = [fileFloor ?? file.modified, nextFileModified].compactMap { $0 }.max()
                }
                continue
            }

            let week = TranscriptBackwardReader.scan(
                path: file.url.path, windowStart: cutoff,
                chunkSize: chunkSizeBytes, maxBytes: sharedBudgetRemaining,
                startOffset: resumeOffset, initialLeftover: resumeLeftover)

            usages.append(contentsOf: week.usages.filter { $0.timestamp >= cutoff })
            if !week.reachedBoundary {
                weekFullyRead = false
                if provenFloor == nil {
                    let thisFloor = week.usages.map(\.timestamp).min() ?? fileFloor ?? file.modified
                    let nextFileModified = index + 1 < ordered.count ? ordered[index + 1].modified : nil
                    provenFloor = [thisFloor, nextFileModified].compactMap { $0 }.max()
                }
            }
            sharedBudgetRemaining -= week.bytesRead
        }

        let window = UsageWindows.compute(usages, now: now)
        // `UsageWindows.compute` finds the active block by walking every message forward from
        // the earliest one it is given, starting a fresh block at the hour-floor of the first
        // message that lands outside the *previous* block's 5-hour span. A block's start is
        // always <= its own first message's timestamp (flooring only rounds down), so for any
        // two messages M then N with N.timestamp - M.timestamp >= 5 hours, N necessarily starts
        // a fresh block regardless of M's own block — which means: given a gap that size between
        // two messages *both proven read*, the entire block chain from N onward is exactly what
        // a full read would produce, independent of anything older than M, because nothing
        // between M and N was missed (both ends are proven) and nothing before M can reach past
        // a boundary that already restarts at N. So the block figure stays exact when the week
        // read is incomplete, as long as such a gap exists somewhere in what was actually proven
        // read — not only when the week read finished outright. `provenFloor` marks the oldest
        // point that proof still holds for; a gap is only trustworthy with both ends at or after
        // it, since a file the budget never reached could otherwise hide a message in between.
        // The 5-hour read's own safety cap stopping early is kept as an unconditional flag: it
        // means even the block's membership isn't proven, and no gap elsewhere fixes that.
        let blockIsLowerBound: Bool
        if !fiveHourFullyRead {
            blockIsLowerBound = true
        } else if weekFullyRead {
            blockIsLowerBound = false
        } else if let floor = provenFloor {
            let provenTimestamps = usages.map(\.timestamp).filter { $0 >= floor }.sorted()
            let hasAnchoringGap = zip(provenTimestamps, provenTimestamps.dropFirst())
                .contains { $1.timeIntervalSince($0) >= Self.fiveHourWindow }
            blockIsLowerBound = !hasAnchoringGap
        } else {
            // weekFullyRead false with no recorded floor shouldn't happen — the loop above
            // always sets `provenFloor` the first time it clears `weekFullyRead` — but fail
            // toward flagging rather than silently presenting an unproven figure as exact.
            blockIsLowerBound = true
        }
        return AgentUsage(
            agent: .claude,
            windows: [
                UsageWindow(label: "5h", usedPercent: nil, tokens: window.blockTokens,
                            resetsAt: window.blockResetAt, tokensAreLowerBound: blockIsLowerBound),
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
