import Foundation

/// Reads what Claude has left from its own transcripts under `~/.claude/projects`. Delegates
/// the arithmetic to the same pure pieces the panel footer uses (`TranscriptUsage`,
/// `UsageWindows`) — both are plain `Sendable` statics with no `@MainActor`, so this runs
/// unchanged in the MCP server's separate process. `TranscriptTailReader` is stateful (it
/// tracks a read offset per path), so this uses one fresh instance per file for a clean
/// one-shot read rather than reusing an instance across calls.
///
/// A real `~/.claude/projects` can hold hundreds of transcripts and hundreds of megabytes —
/// reading it all on every call made this take over a minute. A total byte budget bounds the
/// work: transcripts are read newest-first, so the 5-hour window (which only needs files from
/// the last 5 hours) is complete whenever those files fit the budget, before anything older is
/// touched. If the budget runs out before every file inside the 7-day scan window is read, the
/// affected window's `tokens` is a floor, not the true total — `UsageWindow.tokensAreLowerBound`
/// says so explicitly rather than presenting a truncated sum as exact.
public struct ClaudeUsageReader {
    private let projectsDirectory: URL
    private let byteBudget: Int

    /// Only transcripts touched in the last week can contribute to either window; mirrors
    /// `UsageTracker`'s scan window for the same reason.
    private static let scanWindow: TimeInterval = 7 * 24 * 3600
    /// Only transcripts touched in the last 5 hours can contribute to the 5h block; reading
    /// this group first (still newest-first within it) is what guarantees the block is
    /// complete whenever its files fit the budget.
    private static let fiveHourWindow: TimeInterval = 5 * 3600
    /// Bounds the cost of a single large historical transcript to its trailing slice.
    private static let tailCapBytes = 4 * 1024 * 1024
    /// Default total budget spent across every file in one `read()`. Measured against a
    /// fixture shaped like a real machine's last 7 days (231 files, ~285 MB): the unbounded
    /// scan took ~40s there (76.8s reported against real transcripts), and 32 MB — the
    /// starting point suggested by the design — still took 4.3s, too slow for a tool call.
    /// 8 MB measured at ~1.0s: well under the two-second budget with headroom for a slower
    /// machine, while still covering several of the newest transcripts (see
    /// task-10-report.md for the full sweep).
    public static let defaultByteBudget = 8 * 1024 * 1024

    public init(projectsDirectory: URL, byteBudget: Int = defaultByteBudget) {
        self.projectsDirectory = projectsDirectory
        self.byteBudget = byteBudget
    }

    public func read() -> AgentUsage {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectsDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return unavailable("no ~/.claude/projects directory")
        }
        guard let enumerator = FileManager.default.enumerator(
            at: projectsDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else {
            return unavailable("no ~/.claude/projects directory")
        }

        let now = Date()
        let cutoff = now.addingTimeInterval(-Self.scanWindow)
        let fiveHourCutoff = now.addingTimeInterval(-Self.fiveHourWindow)

        var newestModified: Date?
        var candidates: [(url: URL, modified: Date, size: Int)] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate
            else { continue }
            if newestModified == nil || modified > newestModified! { newestModified = modified }
            guard modified >= cutoff else { continue }
            // A size that can't be read is treated as costing the full tail cap — the
            // conservative assumption, never an undercount that could silently blow the budget.
            let size = values.fileSize ?? Self.tailCapBytes
            candidates.append((url, modified, size))
        }

        guard let observedAt = newestModified else {
            return unavailable("no session records found")
        }

        // Newest-first overall puts every 5-hour-window file ahead of every older-but-within-
        // week file automatically (a newer mtime always sorts first), so one pass is enough:
        // the loop below spends the budget in exactly that priority order.
        let ordered = candidates.sorted { $0.modified > $1.modified }

        var usages: [MessageUsage] = []
        var bytesSpent = 0
        var fiveHourFullyRead = true
        var weekFullyRead = true

        for file in ordered {
            let fileCost = min(file.size, Self.tailCapBytes)
            guard bytesSpent + fileCost <= byteBudget else {
                weekFullyRead = false
                if file.modified >= fiveHourCutoff { fiveHourFullyRead = false }
                break
            }
            bytesSpent += fileCost

            let reader = TranscriptTailReader()
            for line in reader.readNewLines(at: file.url.path, firstReadTailCap: Self.tailCapBytes) {
                if let usage = TranscriptUsage.parseLine(line) {
                    usages.append(usage)
                }
            }
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
