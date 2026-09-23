import Foundation

/// One tab in a project's strip: its Board, one of its agent sessions, or one of its terminals.
public struct ProjectTab: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case board
        case agent(AgentKind)
        case terminal
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// Mid-turn: closing it asks first.
    public let isWorking: Bool

    public init(id: String, kind: Kind, title: String, isWorking: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isWorking = isWorking
    }
}

/// A project's tabs and how keys move between them. Pure: sessions and terminals come in as values.
public enum ProjectTabs {
    public static func standardized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    public static func boardID(_ path: String) -> String {
        "board:" + standardized(path)
    }

    /// The Board, then the project's agent sessions, then its terminals — each in the order they
    /// were opened. `titles` holds live session titles, which win over the stored ones.
    public static func tabs(project path: String, sessions: [Session], shells: [ShellRow], titles: [String: String]) -> [ProjectTab] {
        let folder = standardized(path)
        var tabs = [ProjectTab(id: boardID(folder), kind: .board, title: "Board", isWorking: false)]
        for session in sessions where standardized(session.cwd) == folder {
            tabs.append(ProjectTab(
                id: session.id, kind: .agent(session.agentKind),
                title: titles[session.id] ?? session.title,
                isWorking: session.state.bucket == .active))
        }
        for shell in shells where standardized(shell.cwd) == folder {
            tabs.append(ProjectTab(id: shell.id, kind: .terminal, title: shell.title, isWorking: false))
        }
        return tabs
    }

    /// ⌘1 is the Board; ⌘2–⌘9 are the sessions in order.
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
