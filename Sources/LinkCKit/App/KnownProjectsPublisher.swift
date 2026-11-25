import Foundation

/// What linkC reads first-hand about a live session from its agent's own reports and files, for its
/// row in `projects.json`. Each field is nil where the agent reports nothing.
public struct SessionLiveDetail: Equatable, Sendable {
    public var contextPercent: Int?

    public init(contextPercent: Int? = nil) {
        self.contextPercent = contextPercent
    }
}

/// Builds the known-projects list the app writes to `projects.json` (spec 2026-11-11 cross-project §4).
public enum KnownProjectsPublisher {
    /// Sidebar projects ∪ MCP folders ∪ live sessions' folders, canonical.
    public static func paths(sidebar: [String], mcpFolders: Set<String>, sessions: [Session]) -> Set<String> {
        resolve(sidebar: sidebar, mcpFolders: mcpFolders, sessions: sessions).paths
    }

    /// Sidebar projects ∪ MCP folders ∪ live sessions' folders, canonical, sorted by path. Each project's
    /// live sessions (state != .ended), sorted by id: .starting → .starting; ready/finished/waitingIdle → .idle;
    /// anything else → .busy. Each session also carries what its row shows; `action` reads the action
    /// line of a session working or waiting on a permission, and is never asked of another.
    /// `liveModel` is the model a session runs now where its agent reports one, else its launch model.
    /// `live` is what its agent reports first-hand (`SessionLiveDetail`).
    public static func projects(
        sidebar: [String], mcpFolders: Set<String>, sessions: [Session], action: (Session) -> String? = { _ in nil },
        subagents: (Session) -> Int = { _ in 0 }, liveModel: (Session) -> String? = { _ in nil },
        title: (Session) -> String? = { _ in nil }, cache: (Session) -> CacheExpiry? = { _ in nil },
        live: (Session) -> SessionLiveDetail = { _ in SessionLiveDetail() }
    ) -> [KnownProject] {
        let (paths, liveByPath) = resolve(sidebar: sidebar, mcpFolders: mcpFolders, sessions: sessions)
        return paths.sorted().map { path in
            let open = (liveByPath[path] ?? [])
                .sorted { $0.id < $1.id }
                .map { session in
                    let shown = ShownActivity.applies(to: session.state)
                        ? ShownActivity(activity: action(session), state: session.state) : nil
                    let running = subagents(session)
                    let cold = cache(session)
                    let detail = live(session)
                    return KnownProject.OpenSession(
                        id: session.id,
                        agent: session.agentKind.rawValue,
                        activity: activity(for: session.state),
                        title: title(session) ?? session.title,
                        state: session.state.rawValue,
                        since: session.stateChangedAt.formatted(.iso8601),
                        model: liveModel(session) ?? session.model,
                        worker: session.isWorker,
                        action: shown?.text,
                        subagents: running > 0 ? running : nil,
                        cacheExpiresAt: cold?.at.formatted(.iso8601),
                        cacheEstimate: cold?.isEstimate == true ? true : nil,
                        contextPercent: detail.contextPercent
                    )
                }
            return KnownProject(path: path, sessions: open)
        }
    }

    /// Each agent's plan limits for `projects.json`, keyed by `AgentKind.rawValue`: the windows of a
    /// fresh reading that give a percent and have not reset by `now`. A reading older than
    /// `AgentUsage.staleAfter`, or one with no such window, gives none: a figure that may no longer
    /// be true is not published as current.
    public static func limits(from usages: [AgentUsage], now: Date) -> [String: [KnownLimit]] {
        var limits: [String: [KnownLimit]] = [:]
        for usage in usages {
            guard let observedAt = usage.observedAt, now.timeIntervalSince(observedAt) <= AgentUsage.staleAfter else { continue }
            let windows = usage.windows.compactMap { window -> KnownLimit? in
                guard let percent = window.usedPercent else { return nil }
                if let resetsAt = window.resetsAt, resetsAt <= now { return nil }
                return KnownLimit(label: window.label, percent: Int(percent.rounded()),
                                  resets: window.resetsAt?.formatted(.iso8601))
            }
            if !windows.isEmpty { limits[usage.agent.rawValue] = windows }
        }
        return limits
    }

    /// The project paths, and each one's live sessions. Each session's folder is canonicalized once, not
    /// once for every project.
    private static func resolve(
        sidebar: [String], mcpFolders: Set<String>, sessions: [Session]
    ) -> (paths: Set<String>, liveByPath: [String: [Session]]) {
        var liveByPath: [String: [Session]] = [:]
        for session in sessions where session.state != .ended {
            liveByPath[ProjectPath.canonical(session.cwd), default: []].append(session)
        }
        var paths = Set(sidebar.map(ProjectPath.canonical))
        paths.formUnion(mcpFolders.map(ProjectPath.canonical))
        paths.formUnion(liveByPath.keys)
        return (paths, liveByPath)
    }

    private static func activity(for state: SessionState) -> KnownProject.OpenSession.Activity {
        switch state {
        case .starting: return .starting
        case .ready, .finished, .waitingIdle: return .idle
        case .working, .waitingPermission, .error, .ended: return .busy
        }
    }
}
