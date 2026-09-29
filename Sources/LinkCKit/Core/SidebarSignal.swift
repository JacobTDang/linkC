import Foundation
import Observation

/// The sidebar inputs that no observation can see change. Everything else the sidebar reads is
/// observable state, which re-renders it the moment it changes; these come from a project's
/// inbox file, a terminal's screen and the clock instead, so they are sampled once a second and
/// summed up here. Deliberately no ages or line wording: those tick or scroll on their own
/// leaf timelines, so a quiet second yields an equal signal.
public struct SidebarSignal: Equatable, Sendable {
    /// Session id → the task it is holding, for each session holding one. A held task names the
    /// session's row while its conversation has no title of its own.
    public let heldTitles: [String: String]
    /// Errored sessions whose agent is under a live rate-limit cooldown: the row reads
    /// "rate limited" instead of "error" until it lapses.
    public let rateLimited: Set<String>
    /// Sessions with an action line to show in place of their name. Whether there is one is
    /// part of the signal; what it says is not — the row's own timeline reads that live.
    public let showingAction: Set<String>

    public init() {
        heldTitles = [:]
        rateLimited = []
        showingAction = []
    }

    /// Asks only what a session's state can show: a rate limit of an errored session, an action
    /// line of a working or permission-waiting one — so idle sessions cost no terminal read.
    public init(
        sessions: [Session],
        heldTitle: (Session) -> String?,
        isRateLimited: (Session) -> Bool,
        action: (Session) -> String?
    ) {
        var held: [String: String] = [:]
        var limited: Set<String> = []
        var acting: Set<String> = []
        for session in sessions {
            if let title = heldTitle(session) { held[session.id] = title }
            if session.state == .error, isRateLimited(session) { limited.insert(session.id) }
            if ShownActivity.applies(to: session.state),
               ShownActivity(activity: action(session), state: session.state) != nil {
                acting.insert(session.id)
            }
        }
        heldTitles = held
        rateLimited = limited
        showingAction = acting
    }
}

/// Hands the sidebar its `SidebarSignal`, and notifies it only when the signal changed. Whether
/// Observation itself skips an assignment of an equal value depends on the toolchain's library,
/// so the guard is explicit: a once-a-second sample must not re-render the sidebar once a second.
@MainActor
@Observable
public final class SidebarSignalFeed {
    public private(set) var signal = SidebarSignal()

    public init() {}

    public func publish(_ new: SidebarSignal) {
        guard new != signal else { return }
        signal = new
    }
}
