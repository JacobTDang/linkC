import Foundation

/// Builds the known-projects list the app writes to `projects.json` (spec 2026-11-11 cross-project §4).
public enum KnownProjectsPublisher {
    /// Sidebar projects ∪ MCP folders ∪ live sessions' folders, canonical, sorted by path. Each project's
    /// live sessions (state != .ended), sorted by id: .starting → .starting; ready/finished/waitingIdle → .idle;
    /// anything else → .busy.
    public static func projects(sidebar: [String], mcpFolders: Set<String>, sessions: [Session]) -> [KnownProject] {
        var paths = Set(sidebar.map(ProjectPath.canonical))
        paths.formUnion(mcpFolders.map(ProjectPath.canonical))
        let live = sessions.filter { $0.state != .ended }
        paths.formUnion(live.map { ProjectPath.canonical($0.cwd) })

        return paths.sorted().map { path in
            let open = live
                .filter { ProjectPath.canonical($0.cwd) == path }
                .sorted { $0.id < $1.id }
                .map { session in
                    KnownProject.OpenSession(
                        id: session.id,
                        agent: session.agentKind.rawValue,
                        activity: activity(for: session.state)
                    )
                }
            return KnownProject(path: path, sessions: open)
        }
    }

    private static func activity(for state: SessionState) -> KnownProject.OpenSession.Activity {
        switch state {
        case .starting: return .starting
        case .ready, .finished, .waitingIdle: return .idle
        case .working, .waitingPermission, .error, .ended: return .busy
        }
    }
}
