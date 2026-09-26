import Foundation

/// What each session's sidebar row is called. First match wins: the conversation's own title,
/// the task the session is holding, then the agent's short name — numbered " 2", " 3", … when a
/// project has several untitled sessions of one agent, in the order they were opened.
public enum SessionTitles {
    /// Titles for every session, keyed by session id. `sessions` must be in opened order (the
    /// session store's order).
    public static func resolve(
        sessions: [Session],
        claudeTitle: (String) -> String?,
        heldTask: (Session) -> TaskRecord?
    ) -> [String: String] {
        var titles: [String: String] = [:]
        var untitledCount: [String: Int] = [:]   // "<project path>|<agent>" → untitled so far
        for session in sessions {
            if let title = claudeTitle(session.id) {
                titles[session.id] = title
            } else if let task = heldTask(session) {
                titles[session.id] = taskTitle(task)
            } else {
                let key = session.cwd + "|" + session.agentKind.rawValue
                let n = (untitledCount[key] ?? 0) + 1
                untitledCount[key] = n
                titles[session.id] = n == 1 ? session.agentKind.shortName : "\(session.agentKind.shortName) \(n)"
            }
        }
        return titles
    }

    /// "Task <shortId>: <first non-empty line of the prompt>", or "Task <shortId>" for a blank prompt.
    public static func taskTitle(_ task: TaskRecord) -> String {
        let firstLine = task.prompt
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine else { return "Task \(task.shortId)" }
        return "Task \(task.shortId): \(firstLine)"
    }

    /// The task `session` is working on: assigned to it, and delivered or started.
    public static func heldTask(for session: Session, in tasks: [TaskRecord]) -> TaskRecord? {
        tasks.first { $0.assigneeSessionId == session.id && ($0.state == .delivered || $0.state == .started) }
    }
}
