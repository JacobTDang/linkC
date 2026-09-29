import Foundation

/// How often the coordinator's sweep runs. Pure: the coordinator feeds it what it already holds
/// in memory, so choosing an interval never reads a file.
public enum TickCadence {
    /// While anything is moving, or someone is looking.
    public static let busy: Duration = .seconds(1)
    /// While the panel is hidden and nothing is in flight.
    public static let idle: Duration = .seconds(5)
    /// The least time between the starts of two passes when a wake asks for the second. A wake is an
    /// inbox write, and one agent can make a dozen in a moment, each otherwise a full pass of every
    /// session on the main thread. Ordinary ticks are at least `busy` apart and never see it.
    public static let minimumWakeGap: Duration = .milliseconds(250)

    /// `busy` when the panel is visible, a session is starting, working or waiting on a prompt,
    /// or a workspace has open tasks or queued messages; `idle` otherwise. Every state the
    /// turn-end debounce polls (`SessionState.working`) is in the busy set, so its polls keep
    /// their one-second spacing.
    public static func interval(
        panelVisible: Bool,
        sessionStates: some Sequence<SessionState>,
        hasRelayWork: Bool
    ) -> Duration {
        if panelVisible || hasRelayWork { return busy }
        return sessionStates.contains(where: isInMotion) ? busy : idle
    }

    /// How late a sleep may end so macOS can coalesce the wakeup with others: a tenth of it.
    public static func tolerance(for interval: Duration) -> Duration {
        interval / 10
    }

    private static func isInMotion(_ state: SessionState) -> Bool {
        switch state {
        case .starting, .working, .waitingPermission: return true
        case .ready, .waitingIdle, .finished, .error, .ended: return false
        }
    }
}

/// What the last relay pass learned about each workspace, kept so the cadence can be chosen
/// without another read: which have open tasks, which have queued messages a session could
/// take, and which pass ended early on a contended inbox lock (that one retries next tick).
struct RelayWork {
    private var openTasks: Set<String> = []
    private var queuedMessages: Set<String> = []
    private var contended: Set<String> = []

    var isEmpty: Bool { openTasks.isEmpty && queuedMessages.isEmpty && contended.isEmpty }

    /// A new pass recomputes everything it reads, so it starts from nothing for its workspace.
    mutating func beginPass(in workspace: String) {
        openTasks.remove(workspace)
        queuedMessages.remove(workspace)
        contended.remove(workspace)
    }

    mutating func noteOpenTasks(_ found: Bool, in workspace: String) {
        if found { openTasks.insert(workspace) } else { openTasks.remove(workspace) }
    }

    mutating func noteQueuedMessages(_ found: Bool, in workspace: String) {
        if found { queuedMessages.insert(workspace) } else { queuedMessages.remove(workspace) }
    }

    mutating func noteContention(in workspace: String) {
        contended.insert(workspace)
    }

    /// Forgets workspaces that no longer have a live session: nothing relays for them any more.
    mutating func retain(only workspaces: Set<String>) {
        openTasks.formIntersection(workspaces)
        queuedMessages.formIntersection(workspaces)
        contended.formIntersection(workspaces)
    }
}
