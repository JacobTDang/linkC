import Foundation

/// What the panel refreshes while it is on screen.
public enum PanelRefresh: CaseIterable, Hashable, Sendable {
    case sessions
    case servers
    case window
    case updateCheck
    case cloud
    case codexUsage
    case health

    /// How long a refresh's result stays fresh.
    var interval: TimeInterval {
        switch self {
        case .sessions: 5
        // Docker state drifts slowly; every 15s keeps SERVERS honest cheaply.
        case .servers: 15
        // The global sweep is heavier: every 30s is live enough for a footer, and for noticing a fresh build.
        case .window, .updateCheck: 30
        // Cloud is slowest and rate-limited: every 120s is plenty.
        case .cloud: 120
        // Codex writes its snapshot every turn; five minutes is live enough to read it.
        case .codexUsage: 300
        // Health has its own timer; showing the panel checks again at most once a minute.
        case .health: 60
        }
    }

    /// Runs only when the panel has just been shown, never on a tick.
    var isShowOnly: Bool { self == .health }
}

/// Each refresh runs at its own interval from when it last ran, so a panel that comes and goes (another
/// Space, the app hidden) costs no more than one left open, and still reaches its slow refreshes.
public struct RefreshSchedule: Sendable {
    /// A timer tick can fire slightly early.
    private static let tolerance: TimeInterval = 0.5
    private var lastRun: [PanelRefresh: Date] = [:]

    public static var panel: RefreshSchedule { RefreshSchedule() }

    /// The refreshes due at `now`, in declaration order, recorded as run at `now`. A refresh is due when it
    /// has never run, or its interval has passed since it last did. `showing` is true when the panel has
    /// just come on screen.
    public mutating func takeDue(at now: Date, showing: Bool) -> [PanelRefresh] {
        let due = PanelRefresh.allCases.filter { refresh in
            guard showing || !refresh.isShowOnly else { return false }
            guard let previous = lastRun[refresh] else { return true }
            return now.timeIntervalSince(previous) >= refresh.interval - Self.tolerance
        }
        for refresh in due { lastRun[refresh] = now }
        return due
    }
}
