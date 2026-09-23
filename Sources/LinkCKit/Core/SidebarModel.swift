import Foundation

/// A project row's state dot: coral when any session wants you, teal when any is working or has a
/// running subagent, none when everything is idle.
public enum ProjectDot: Equatable, Sendable {
    case none, working, attention
}

/// One session nested under its project in the sidebar.
public struct SidebarSessionRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let agentKind: AgentKind
    public let title: String
    public let status: SessionRowStatus
    public let activity: ShownActivity?

    public init(id: String, agentKind: AgentKind, title: String, status: SessionRowStatus, activity: ShownActivity? = nil) {
        self.id = id
        self.agentKind = agentKind
        self.title = title
        self.status = status
        self.activity = activity
    }
}

/// One project row: a folder with at least one live session.
public struct SidebarProject: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let dot: ProjectDot
    public let isExpanded: Bool
    public let sessions: [SidebarSessionRow]
}

/// Builds the sidebar's Projects section from live sessions. Pure: every input is a value.
public enum SidebarModel {
    public struct Input: Equatable, Sendable {
        public let session: Session
        public let title: String
        public let status: SessionRowStatus
        public let hasRunningSubagents: Bool
        public let activity: String?

        public init(
            session: Session, title: String, status: SessionRowStatus, hasRunningSubagents: Bool,
            activity: String? = nil
        ) {
            self.session = session
            self.title = title
            self.status = status
            self.hasRunningSubagents = hasRunningSubagents
            self.activity = activity
        }
    }

    /// Projects in `order` (the order they were first opened); a project not in `order` goes after
    /// them in encounter order. Sessions stay in `inputs` order (opened order). A project is open
    /// when `expandOverrides` says so; with no override it is open only while it holds the selected
    /// session, so moving into a project opens it and collapsing it afterwards sticks.
    public static func projects(
        inputs: [Input], order: [String], expandOverrides: [String: Bool], selectedId: String?
    ) -> [SidebarProject] {
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let groups = ProjectGroup.group(sessions: inputs.map(\.session))
        let sorted = groups.enumerated().sorted { a, b in
            (rank[a.element.workspacePath] ?? order.count + a.offset)
                < (rank[b.element.workspacePath] ?? order.count + b.offset)
        }.map(\.element)
        return sorted.map { group in
            // Built from `inputs` rather than an id lookup: a duplicate session id (never expected)
            // shows as a visible second row instead of trapping the app.
            let rows = inputs.filter { ($0.session.cwd as NSString).standardizingPath == group.workspacePath }
            let holdsSelection = rows.contains { $0.session.id == selectedId }
            return SidebarProject(
                path: group.workspacePath,
                name: group.title,
                dot: dot(for: rows),
                isExpanded: expandOverrides[group.workspacePath] ?? holdsSelection,
                sessions: rows.map {
                    SidebarSessionRow(
                        id: $0.session.id, agentKind: $0.session.agentKind, title: $0.title, status: $0.status,
                        activity: ShownActivity(activity: $0.activity, state: $0.session.state))
                }
            )
        }
    }

    static func dot(for rows: [Input]) -> ProjectDot {
        if rows.contains(where: { $0.status.isCoral }) { return .attention }
        if rows.contains(where: { $0.status.tone == .working || $0.hasRunningSubagents }) { return .working }
        return .none
    }
}
