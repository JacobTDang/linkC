import Foundation

/// Represents an aggregated group of sessions operating in the same workspace directory.
public struct ProjectGroup: Sendable, Identifiable, Equatable {
    public var id: String { workspacePath }
    public let workspacePath: String
    public let title: String
    public var sessions: [Session]

    /// Urgency resolution across sessions:
    /// - `.needsYou` if any session needs attention (e.g. waiting permission/idle, error, finished)
    /// - `.active` if any session is actively working
    /// - else `.idle`
    public var bucket: SessionState.Bucket {
        if sessions.contains(where: { $0.state.bucket == .needsYou }) {
            return .needsYou
        }
        if sessions.contains(where: { $0.state.bucket == .active }) {
            return .active
        }
        return .idle
    }

    public init(
        workspacePath: String,
        title: String? = nil,
        sessions: [Session] = []
    ) {
        let standardized = (workspacePath as NSString).standardizingPath
        self.workspacePath = standardized
        if let title, !title.isEmpty {
            self.title = title
        } else if let firstTitle = sessions.first?.title, !firstTitle.isEmpty {
            self.title = firstTitle
        } else {
            let base = URL(fileURLWithPath: standardized).lastPathComponent
            self.title = (base.isEmpty || base == "/") ? (standardized.isEmpty ? "Workspace" : standardized) : base
        }
        self.sessions = sessions
    }

    /// Aggregates sessions by standardized cwd preserving encounter order.
    public static func group(sessions: [Session]) -> [ProjectGroup] {
        var groups: [ProjectGroup] = []
        var indexByPath: [String: Int] = [:]

        for session in sessions {
            let path = (session.cwd as NSString).standardizingPath
            if let idx = indexByPath[path] {
                groups[idx].sessions.append(session)
            } else {
                indexByPath[path] = groups.count
                let group = ProjectGroup(
                    workspacePath: path,
                    sessions: [session]
                )
                groups.append(group)
            }
        }

        return groups
    }
}
