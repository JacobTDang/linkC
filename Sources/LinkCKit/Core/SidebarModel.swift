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

/// One project row: a folder with at least one live session, or with at least one terminal filed
/// under it.
public struct SidebarProject: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let dot: ProjectDot
    public let isExpanded: Bool
    public let sessions: [SidebarSessionRow]
    public let terminals: [ShellRow]
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
    /// them in encounter order. Sessions stay in `inputs` order (opened order). Each of `shells` is
    /// filed under its project (`TerminalFiling.project`, using `filed`) or, with none, returned in
    /// `unfiled` instead. A project with no live session still shows as long as a live terminal is
    /// filed under it. A project is open when `expandOverrides` says so; with no override it is open
    /// only while it holds the selected session or terminal, so moving into a project opens it and
    /// collapsing it afterwards sticks.
    public static func projects(
        inputs: [Input], shells: [ShellRow] = [], filed: [String: String] = [:], order: [String], expandOverrides: [String: Bool], selectedId: String?
    ) -> (projects: [SidebarProject], unfiled: [ShellRow]) {
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })

        var projectPathsList: [String] = []
        var seenPaths: Set<String> = []

        for input in inputs {
            let path = (input.session.cwd as NSString).standardizingPath
            if seenPaths.insert(path).inserted {
                projectPathsList.append(path)
            }
        }
        var projectTerminals: [String: [ShellRow]] = [:]
        var unfiled: [ShellRow] = []

        for shell in shells {
            if let p = TerminalFiling.project(forTerminal: shell.id, cwd: shell.cwd, filed: filed, projects: seenPaths) {
                projectTerminals[p, default: []].append(shell)
                if seenPaths.insert(p).inserted {
                    projectPathsList.append(p)
                }
            } else {
                unfiled.append(shell)
            }
        }

        let groups = ProjectGroup.group(sessions: inputs.map(\.session))
        let groupMap = Dictionary(uniqueKeysWithValues: groups.map { ($0.workspacePath, $0) })

        let sorted = projectPathsList.enumerated().sorted { a, b in
            (rank[a.element] ?? order.count + a.offset)
                < (rank[b.element] ?? order.count + b.offset)
        }.map(\.element)

        let projectsList = sorted.map { path -> SidebarProject in
            let group = groupMap[path]
            let rows = inputs.filter { ($0.session.cwd as NSString).standardizingPath == path }
            let terms = projectTerminals[path] ?? []
            let holdsSelection = rows.contains { $0.session.id == selectedId } || terms.contains { $0.id == selectedId }
            let name = group?.title ?? URL(fileURLWithPath: path).lastPathComponent

            return SidebarProject(
                path: path,
                name: name,
                dot: dot(for: rows),
                isExpanded: expandOverrides[path] ?? holdsSelection,
                sessions: rows.map {
                    SidebarSessionRow(
                        id: $0.session.id, agentKind: $0.session.agentKind, title: $0.title, status: $0.status,
                        activity: ShownActivity(activity: $0.activity, state: $0.session.state))
                },
                terminals: terms
            )
        }

        return (projects: projectsList, unfiled: unfiled)
    }

    static func dot(for rows: [Input]) -> ProjectDot {
        if rows.contains(where: { $0.status.isCoral }) { return .attention }
        if rows.contains(where: { $0.status.tone == .working || $0.hasRunningSubagents }) { return .working }
        return .none
    }
}
