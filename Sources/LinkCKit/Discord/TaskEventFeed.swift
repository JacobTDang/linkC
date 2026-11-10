import Foundation

/// Finds each folder's task changes between two relay passes (spec §2.1), whichever process made them:
/// linkC's relay or a `linkc-mcp`. The first pass for a folder only records, so a restart never posts
/// the backlog.
struct TaskEventFeed {
    /// The states that raise an event; moves to any other state raise none.
    static let reportedStates: Set<TaskState> = [.delivered, .done, .failed, .expired, .cancelled]

    private var seen: [String: [String: TaskState]] = [:]

    /// The events for `folder` since the last pass: one per task that moved to, or appeared in, a
    /// reported state.
    mutating func events(in folder: String, tasks: [TaskRecord], at date: Date) -> [LinkCEvent] {
        let current = Dictionary(tasks.map { ($0.id, $0.state) }, uniquingKeysWith: { _, last in last })
        defer { seen[folder] = current }
        guard let previous = seen[folder] else { return [] }
        return tasks.compactMap { task in
            guard previous[task.id] != task.state, Self.reportedStates.contains(task.state) else { return nil }
            return Self.event(for: task, in: folder, at: date)
        }
    }

    /// Forgets folders the relay no longer serves; one served again starts over silently.
    mutating func retain(only folders: Set<String>) {
        seen = seen.filter { folders.contains($0.key) }
    }

    static func event(for task: TaskRecord, in folder: String, at date: Date) -> LinkCEvent {
        let (word, tone): (String, LinkCEvent.Tone) = switch task.state {
        case .delivered: ("delivered", .info)
        case .done: ("done", .done)
        case .failed: ("failed", .failed)
        case .expired: ("expired", .failed)
        case .cancelled: ("cancelled", .info)
        default: (task.state.rawValue, .info)
        }
        var lines = ["`\(task.shortId)` \(firstLine(of: task.prompt))"]
        let outcome: String? = switch task.state {
        case .done, .failed: task.report?.summary ?? task.cancelReason
        case .expired, .cancelled: task.cancelReason
        default: nil
        }
        if let outcome, !outcome.isEmpty { lines.append(outcome) }
        return LinkCEvent(
            kind: .task, tone: tone,
            title: "Task \(word) · \(task.fromAgent.shortName) → \(task.toAgent.shortName)",
            body: lines.joined(separator: "\n"), project: folder, at: date)
    }

    /// The prompt's first line, cut at 120 characters.
    static func firstLine(of prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }
}
