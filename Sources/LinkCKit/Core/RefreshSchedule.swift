import Foundation

public enum PanelRefresh: CaseIterable, Hashable, Sendable {
    case sessions
    case servers
    case window
    case updateCheck
    case cloud
    case codexUsage
    case health
}

/// Each refresh runs at its own interval from when it last ran, so a panel that comes and
/// goes (another Space, the app hidden) costs no more than one left open.
public struct RefreshSchedule: Sendable {
    private let intervals: [PanelRefresh: TimeInterval]
    private let showOnly: Set<PanelRefresh>
    private let tolerance: TimeInterval
    private var lastRun: [PanelRefresh: Date] = [:]

    public init(
        intervals: [PanelRefresh: TimeInterval],
        showOnly: Set<PanelRefresh> = [],
        tolerance: TimeInterval = 0.5
    ) {
        self.intervals = intervals
        self.showOnly = showOnly
        self.tolerance = tolerance
    }

    /// The default schedule for the panel.
    public static var panel: RefreshSchedule {
        RefreshSchedule(
            intervals: [
                .sessions: 5,
                // Docker state drifts slowly; every 15s keeps SERVERS honest cheaply.
                .servers: 15,
                // The global sweep is heavier — every 30s is live enough for a footer,
                .window: 30,
                // and enough for noticing a fresh build too.
                .updateCheck: 30,
                // Cloud is slowest and rate-limited: every 120s is plenty.
                .cloud: 120,
                // Codex writes its snapshot every turn; five minutes is live enough to read it.
                .codexUsage: 300,
                // Health checks are show-only: at most once a minute when the panel is shown.
                .health: 60,
            ],
            showOnly: [.health]
        )
    }

    /// Returns the refreshes due at `now`, in declaration order, and records them as run at `now`.
    ///
    /// A refresh is due when it has never run, or when `now` is at least its interval minus a 0.5 s
    /// tolerance after its last run. The tolerance is there because a timer tick can fire slightly early.
    public mutating func takeDue(at now: Date, showing: Bool) -> [PanelRefresh] {
        var due: [PanelRefresh] = []
        for refresh in PanelRefresh.allCases {
            if showOnly.contains(refresh) && !showing {
                continue
            }
            guard let interval = intervals[refresh] else { continue }
            if let previous = lastRun[refresh] {
                if now.timeIntervalSince(previous) >= interval - tolerance {
                    due.append(refresh)
                    lastRun[refresh] = now
                }
            } else {
                due.append(refresh)
                lastRun[refresh] = now
            }
        }
        return due
    }
}
