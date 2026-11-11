import Foundation

/// Builds the known-projects list the app writes to `projects.json` (spec 2026-11-11 cross-project §4).
public enum KnownProjectsPublisher {
    /// Sidebar projects ∪ MCP folders ∪ live sessions' folders, canonical.
    public static func paths(sidebar: [String], mcpFolders: Set<String>, sessions: [Session]) -> Set<String> {
        resolve(sidebar: sidebar, mcpFolders: mcpFolders, sessions: sessions).paths
    }

    /// Sidebar projects ∪ MCP folders ∪ live sessions' folders, canonical, sorted by path. Each project's
    /// live sessions (state != .ended), sorted by id: .starting → .starting; ready/finished/waitingIdle → .idle;
    /// anything else → .busy.
    public static func projects(sidebar: [String], mcpFolders: Set<String>, sessions: [Session]) -> [KnownProject] {
        let (paths, liveByPath) = resolve(sidebar: sidebar, mcpFolders: mcpFolders, sessions: sessions)
        return paths.sorted().map { path in
            let open = (liveByPath[path] ?? [])
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
