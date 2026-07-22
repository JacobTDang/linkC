import Foundation

/// Plan-window totals for the home footer — absolute numbers, no invented percentages
/// (Anthropic doesn't publish per-plan token limits).
public struct WindowUsage: Equatable, Sendable {
    /// Tokens consumed in the current 5-hour block; 0 when no block is active.
    public let blockTokens: Int
    /// When the current block's window resets; nil when no block is active.
    public let blockResetAt: Date?
    /// Tokens consumed in the trailing 7 days.
    public let weekTokens: Int

    public init(blockTokens: Int, blockResetAt: Date?, weekTokens: Int) {
        self.blockTokens = blockTokens
        self.blockResetAt = blockResetAt
        self.weekTokens = weekTokens
    }
}

/// The 5h-block approximation claude's own limits use (and ccusage popularized): a block
/// starts at the hour-floor of the first activity after the previous block's window, and
/// lasts 5 hours. We can't see Anthropic's real block boundaries, so this is best-effort.
public enum UsageWindows {
    private static let blockLength: TimeInterval = 5 * 3600
    private static let week: TimeInterval = 7 * 24 * 3600

    public static func compute(_ usages: [MessageUsage], now: Date) -> WindowUsage {
        let sorted = usages.sorted { $0.timestamp < $1.timestamp }

        var blockStart: Date?
        for entry in sorted {
            if let start = blockStart, entry.timestamp < start.addingTimeInterval(blockLength) {
                continue
            }
            blockStart = floorToHour(entry.timestamp)
        }

        let weekTokens = sorted
            .filter { $0.timestamp >= now.addingTimeInterval(-week) }
            .reduce(0) { $0 + $1.totalTokens }

        guard let start = blockStart, now < start.addingTimeInterval(blockLength) else {
            return WindowUsage(blockTokens: 0, blockResetAt: nil, weekTokens: weekTokens)
        }
        let blockTokens = sorted
            .filter { $0.timestamp >= start }
            .reduce(0) { $0 + $1.totalTokens }
        return WindowUsage(
            blockTokens: blockTokens,
            blockResetAt: start.addingTimeInterval(blockLength),
            weekTokens: weekTokens
        )
    }

    private static func floorToHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}
