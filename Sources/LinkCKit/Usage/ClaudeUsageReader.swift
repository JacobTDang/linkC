import Foundation

/// Reads what Claude has left from its own transcripts under `~/.claude/projects`. Delegates
/// the arithmetic to the same pure pieces the panel footer uses (`TranscriptUsage`,
/// `UsageWindows`) — both are plain `Sendable` statics with no `@MainActor`, so this runs
/// unchanged in the MCP server's separate process. `TranscriptTailReader` is stateful (it
/// tracks a read offset per path), so this uses one fresh instance per file for a clean
/// one-shot read rather than reusing an instance across calls.
public struct ClaudeUsageReader {
    private let projectsDirectory: URL

    /// Only transcripts touched in the last week can contribute to either window; mirrors
    /// `UsageTracker`'s scan window for the same reason.
    private static let scanWindow: TimeInterval = 7 * 24 * 3600
    /// Bounds the cost of a large historical transcript to its trailing slice.
    private static let tailCapBytes = 4 * 1024 * 1024

    public init(projectsDirectory: URL) {
        self.projectsDirectory = projectsDirectory
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
        var newestModified: Date?
        var usages: [MessageUsage] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate else { continue }
            if newestModified == nil || modified > newestModified! { newestModified = modified }
            guard modified >= cutoff else { continue }

            let reader = TranscriptTailReader()
            for line in reader.readNewLines(at: url.path, firstReadTailCap: Self.tailCapBytes) {
                if let usage = TranscriptUsage.parseLine(line) {
                    usages.append(usage)
                }
            }
        }

        guard let observedAt = newestModified else {
            return unavailable("no session records found")
        }

        let window = UsageWindows.compute(usages, now: now)
        return AgentUsage(
            agent: .claude,
            windows: [
                UsageWindow(label: "5h", usedPercent: nil, tokens: window.blockTokens, resetsAt: window.blockResetAt),
                UsageWindow(label: "7d", usedPercent: nil, tokens: window.weekTokens, resetsAt: nil)
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
