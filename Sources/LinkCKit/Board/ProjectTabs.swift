import Foundation

/// One tab in a project's strip: its Board, its Split, one of its agent sessions, one of its terminals, or an app.
public struct ProjectTab: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case board
        case agent(AgentKind)
        case terminal
        case app
        case split
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// Mid-turn: closing it asks first.
    public let isWorking: Bool
    public let activity: ShownActivity?

    public init(id: String, kind: Kind, title: String, isWorking: Bool, activity: ShownActivity? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isWorking = isWorking
        self.activity = activity
    }
}

/// A project's tabs and how keys move between them. Pure: sessions and terminals come in as values.
public enum ProjectTabs {
    public static func standardized(_ path: String) -> String {
        ProjectPath.canonical(path)
    }

    public static func boardID(_ path: String) -> String {
        boardID(canonical: standardized(path))
    }

    /// The Board tab's id for a path that is already canonical — no filesystem lookup.
    public static func boardID(canonical path: String) -> String {
        "board:" + path
    }

    /// The Split tab's id for a canonical project path.
    public static func splitID(canonical path: String) -> String {
        "split:" + path
    }

    public static func appTabID(project: String, folder: String) -> String {
        "app:" + standardized(project) + "#" + standardized(folder)
    }

    /// The Board, then the Split when `split` holds two or more live terminals, then the project's agent sessions, then its terminals, then its open apps — each in the order they were opened. `titles` holds live
    /// session titles, which win over the stored ones. `activities` holds each working or permission-waiting session's current action, keyed by session id.
    ///
    /// - Precondition: Each `Session.cwd` is canonicalized upon creation (`Session.init`), so comparing
    ///   `session.cwd == folder` avoids per-session path normalization syscalls on every tab evaluation.
    public static func tabs(
        project path: String, sessions: [Session], shells: [ShellRow], filed: [String: String] = [:], titles: [String: String],
        activities: [String: String] = [:], openApps: [OpenApp] = [], split: ProjectSplit? = nil
    ) -> [ProjectTab] {
        let folder = standardized(path)
        var tabs = [ProjectTab(id: boardID(canonical: folder), kind: .board, title: "Board", isWorking: false)]
        for session in sessions where session.cwd == folder {
            tabs.append(ProjectTab(
                id: session.id, kind: .agent(session.agentKind),
                title: titles[session.id] ?? session.title,
                isWorking: session.state.bucket == .active,
                activity: ShownActivity(activity: activities[session.id], state: session.state)))
        }
        for shell in shells {
            if TerminalFiling.project(forTerminal: shell.id, cwd: shell.cwd, filed: filed, projects: [folder]) == folder {
                tabs.append(ProjectTab(id: shell.id, kind: .terminal, title: shell.title, isWorking: false))
            }
        }
        for app in openApps {
            tabs.append(ProjectTab(id: appTabID(project: folder, folder: app.folder), kind: .app, title: app.name, isWorking: false))
        }
        if let split, split.isActive(liveIDs: Set(terminalIDs(tabs))) {
            tabs.insert(ProjectTab(id: splitID(canonical: folder), kind: .split, title: "Split", isWorking: false), at: 1)
        }
        return tabs
    }

    /// The ids of `tabs` that are terminals — the agent sessions and shell terminals — in strip order. These
    /// are the terminals a project's split may hold; the Board, Split and app tabs are not.
    public static func terminalIDs(_ tabs: [ProjectTab]) -> [String] {
        tabs.compactMap { tab in
            switch tab.kind {
            case .agent, .terminal: return tab.id
            case .board, .app, .split: return nil
            }
        }
    }

    /// ⌘1 is the Board; ⌘2–⌘9 are the tabs after it in order: the Split first when the project has one, then its sessions.
    public static func tab(forDigit digit: Int, in tabs: [ProjectTab]) -> ProjectTab? {
        guard (1...9).contains(digit), digit <= tabs.count else { return nil }
        return tabs[digit - 1]
    }

    /// The next or previous tab, wrapping. An unknown current tab counts as the Board.
    public static func cycle(from current: String?, in tabs: [ProjectTab], backwards: Bool) -> ProjectTab? {
        guard !tabs.isEmpty else { return nil }
        let index = tabs.firstIndex { $0.id == current } ?? 0
        let next = backwards ? (index - 1 + tabs.count) % tabs.count : (index + 1) % tabs.count
        return tabs[next]
    }
}
