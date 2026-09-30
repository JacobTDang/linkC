import Foundation

/// A request to close the session that carried a task, made by the agent that delegated it or by
/// the worker itself. `linkc-mcp` is a separate process and cannot see sessions, so the tool
/// records the request on the task and linkC's relay pass decides, acts, and records the outcome
/// here for the tool to read back.
public struct CloseRequest: Codable, Sendable, Equatable, Identifiable {
    public enum Requester: String, Codable, Sendable {
        case delegator
        case worker
    }

    /// What linkC did with a request.
    public enum Outcome: Sendable, Equatable {
        case closed(at: Date)
        case refused(String)
    }

    public let id: String
    public let by: Requester
    public let at: Date
    public var closedAt: Date?
    public var refusal: String?

    /// Not yet decided: linkC has neither closed the session nor refused.
    public var isPending: Bool { closedAt == nil && refusal == nil }

    public init(id: String = UUID().uuidString, by: Requester, at: Date = Date(),
                closedAt: Date? = nil, refusal: String? = nil) {
        self.id = id
        self.by = by
        self.at = at
        self.closedAt = closedAt
        self.refusal = refusal
    }

    /// Why the worker that carried `task` cannot be closed, judged from the tasks alone; nil when
    /// nothing in them stands in the way. The task must have reached a session and stopped
    /// running (reported, or in a final state), and the session must hold no other open task and
    /// wait on none it delegated (its report comes back to that session). Whether the session is a
    /// worker, idle, and off screen is only known to the app.
    static func refusal(for task: TaskRecord, among tasks: [TaskRecord]) -> String? {
        guard let session = task.assigneeSessionId else {
            return "task \(task.shortId) was never delivered to a session, so there is no worker to close."
        }
        switch task.state {
        case .reported, .done, .failed, .cancelled, .expired:
            break
        case .gating, .queued, .delivered, .started:
            return "task \(task.shortId) is still \(task.state.rawValue); cancel it (linkc_cancel_task) or wait for its report first."
        }
        let others = tasks.filter { $0.id != task.id && $0.state.isOpen && $0.assigneeSessionId == session }
        guard others.isEmpty else {
            return "the session also holds open task \(others.map(\.shortId).joined(separator: ", "))."
        }
        let delegated = tasks.filter { $0.state.isOpen && $0.fromSessionId == session }
        guard delegated.isEmpty else {
            return "the session is waiting on open task \(delegated.map(\.shortId).joined(separator: ", ")), which it delegated."
        }
        return nil
    }
}
