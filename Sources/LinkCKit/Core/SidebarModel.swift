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

    public init(id: String, agentKind: AgentKind, title: String, status: SessionRowStatus) {
        self.id = id
        self.agentKind = agentKind
        self.title = title
        self.status = status
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

        public init(session: Session, title: String, status: SessionRowStatus, hasRunningSubagents: Bool) {
            self.session = session
            self.title = title
            self.status = status
            self.hasRunningSubagents = hasRunningSubagents
        }
    }

    /// Projects in `order` (the order they were first opened); a project not in `order` goes after
    /// them in encounter order. Sessions stay in `inputs` order (opened order). The selected
    /// session's project is always expanded; otherwise `expandOverrides` decides, default collapsed.
    public static func projects(
        inputs: [Input], order: [String], expandOverrides: [String: Bool], selectedId: String?
    ) -> [SidebarProject] {
        let byId = Dictionary(uniqueKeysWithValues: inputs.map { ($0.session.id, $0) })
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let groups = ProjectGroup.group(sessions: inputs.map(\.session))
        let sorted = groups.enumerated().sorted { a, b in
            (rank[a.element.workspacePath] ?? order.count + a.offset)
                < (rank[b.element.workspacePath] ?? order.count + b.offset)
        }.map(\.element)
        return sorted.map { group in
            let rows = group.sessions.compactMap { byId[$0.id] }
            let holdsSelection = rows.contains { $0.session.id == selectedId }
            return SidebarProject(
                path: group.workspacePath,
                name: group.title,
                dot: dot(for: rows),
                isExpanded: holdsSelection || (expandOverrides[group.workspacePath] ?? false),
                sessions: rows.map {
                    SidebarSessionRow(id: $0.session.id, agentKind: $0.session.agentKind, title: $0.title, status: $0.status)
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
