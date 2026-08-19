import Foundation

/// One subagent lifecycle event lifted from a transcript line.
public enum AgentEvent: Equatable, Sendable {
    case spawned(toolUseId: String, description: String, type: String?, at: Date)
    case completed(toolUseId: String, resultText: String?, at: Date)
}

/// A subagent's run, assembled from its spawn and (eventually) its completion.
public struct AgentRun: Equatable, Sendable, Identifiable {
    public let id: String            // the spawning tool_use id
    public let description: String   // the agent's own short description
    public let type: String?         // Explore / Plan / general-purpose / …
    public let startedAt: Date
    public var endedAt: Date?
    public var resultText: String?
    /// True when the turn-over backstop ended this run rather than a real completion.
    public var endedBySweep: Bool = false

    public var isRunning: Bool { endedAt == nil }
}

/// Parses subagent activity out of session-transcript lines (decoded via the shared
/// `TranscriptLine`). Spawns are `Agent`/`Task` tool_use blocks (their input carries
/// description + subagent_type). Completion differs by agent style: sync agents complete
/// via a real tool_result; async agents' immediate tool_result is only launch metadata —
/// their completion arrives later as a task-notification naming the original tool-use id.
public enum AgentEvents {
    private static let asyncLaunchMarker = "Async agent launched"

    public static func parse(line: String) -> [AgentEvent] {
        guard let decoded = TranscriptLine.decode(line) else { return [] }
        return events(from: decoded)
    }

    /// The pre-decoded path — `UsageTracker` decodes each line once and feeds every
    /// consumer the same `TranscriptLine`.
    static func events(from decoded: TranscriptLine) -> [AgentEvent] {
        guard let timestamp = decoded.timestamp else { return [] }

        var events: [AgentEvent] = []
        switch decoded.content {
        case .blocks(let blocks):
            for block in blocks {
                if block.type == "tool_use", block.name == "Agent" || block.name == "Task",
                   let id = block.id, let description = block.input?.description {
                    events.append(.spawned(
                        toolUseId: id, description: description,
                        type: block.input?.subagentType, at: timestamp
                    ))
                }
                if block.type == "tool_result", let id = block.toolUseId {
                    let text = block.resultText ?? ""
                    // Async agents' immediate tool_result is launch metadata, not a completion.
                    guard !text.hasPrefix(asyncLaunchMarker) else { continue }
                    // An empty result still completes the run — dropping it strands the run.
                    events.append(.completed(
                        toolUseId: id, resultText: text.isEmpty ? nil : text, at: timestamp
                    ))
                }
                if block.type == "text", let text = block.text {
                    events.append(contentsOf: notificationCompletions(in: text, at: timestamp))
                }
            }
        case .text(let text):
            events.append(contentsOf: notificationCompletions(in: text, at: timestamp))
        }
        return events
    }

    /// Task-notification bodies carry `<tool-use-id>` and (usually) `<result>` tags.
    private static func notificationCompletions(in text: String, at timestamp: Date) -> [AgentEvent] {
        guard text.contains("<task-notification>"),
              let id = tagged("tool-use-id", in: text) else { return [] }
        return [.completed(toolUseId: id, resultText: tagged("result", in: text), at: timestamp)]
    }

    private static func tagged(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        let value = String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Pairs spawns with completions across incremental feeds. Completions for unknown ids are
/// quiet no-ops (the spawn may predate the tail window).
public struct AgentAssembler: Sendable {
    public private(set) var runs: [AgentRun] = []

    public init() {}

    public mutating func feed(_ events: [AgentEvent]) {
        for event in events {
            switch event {
            case .spawned(let id, let description, let type, let at):
                guard !runs.contains(where: { $0.id == id }) else { continue }
                runs.append(AgentRun(id: id, description: description, type: type,
                                     startedAt: at, endedAt: nil, resultText: nil))
            case .completed(let id, let resultText, let at):
                guard let index = runs.firstIndex(where: { $0.id == id }) else { continue }
                // A real completion outranks the sweep's guess — take its timestamp so the
                // run surfaces in the recent-completion window. The first real end is kept.
                if runs[index].endedAt == nil || runs[index].endedBySweep {
                    runs[index].endedAt = at
                    runs[index].endedBySweep = false
                }
                if runs[index].resultText == nil { runs[index].resultText = resultText }
            }
        }
        // Bound memory on marathon sessions: keep the most recent 30 runs.
        if runs.count > 30 { runs.removeFirst(runs.count - 30) }
    }

    /// Turn-over backstop: the transcript never closed these runs out — end them now, so a
    /// lost completion can't show a subagent as running forever.
    public mutating func endAllRunning(at date: Date) {
        for index in runs.indices where runs[index].endedAt == nil {
            runs[index].endedAt = date
            runs[index].endedBySweep = true
        }
    }
}
