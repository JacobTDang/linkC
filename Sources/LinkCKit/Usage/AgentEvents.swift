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

/// Parses subagent activity out of session-transcript lines. Spawns are `Agent`/`Task`
/// tool_use blocks (their input carries description + subagent_type). Completion differs by
/// agent style: sync agents complete via a real tool_result; async agents' immediate
/// tool_result is only launch metadata — their completion arrives later as a
/// task-notification that names the original tool-use id.
public enum AgentEvents {
    private static let asyncLaunchMarker = "Async agent launched"

    public static func parse(line: String) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawLine.self, from: data),
              let timestamp = raw.timestamp.flatMap(parseTimestamp) else { return [] }

        var events: [AgentEvent] = []
        switch raw.message?.content {
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
                    let text = block.content?.joinedText ?? ""
                    // Async agents' immediate tool_result is launch metadata, not a completion.
                    guard !text.hasPrefix(asyncLaunchMarker) else { continue }
                    // An empty result still completes the run — dropping it strands the run as running.
                    events.append(.completed(toolUseId: id, resultText: text.isEmpty ? nil : text, at: timestamp))
                }
                if block.type == "text", let text = block.text {
                    events.append(contentsOf: notificationCompletions(in: text, at: timestamp))
                }
            }
        case .text(let text):
            events.append(contentsOf: notificationCompletions(in: text, at: timestamp))
        case nil:
            break
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

    static func parseTimestamp(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: raw)
    }

    // MARK: - Raw shapes

    private struct RawLine: Decodable {
        let timestamp: String?
        let message: RawMessage?
    }

    private struct RawMessage: Decodable {
        let content: RawContent?
    }

    /// User-message content is a string OR a block array; both occur in real transcripts.
    /// Blocks decode individually — one malformed block is skipped alone rather than
    /// discarding every event in the line.
    private enum RawContent: Decodable {
        case text(String)
        case blocks([RawBlock])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                let failables = (try? container.decode([FailableBlock].self)) ?? []
                self = .blocks(failables.compactMap(\.block))
            }
        }
    }

    /// Always decodes; `block` is nil when the element didn't match `RawBlock`. Wrapping each
    /// element keeps the array's decode cursor advancing past bad entries.
    private struct FailableBlock: Decodable {
        let block: RawBlock?

        init(from decoder: Decoder) throws {
            block = try? RawBlock(from: decoder)
        }
    }

    private struct RawBlock: Decodable {
        let type: String?
        let id: String?
        let name: String?
        let text: String?
        let input: RawInput?
        let toolUseId: String?
        let content: RawResultPayload?

        enum CodingKeys: String, CodingKey {
            case type, id, name, text, input, content
            case toolUseId = "tool_use_id"
        }
    }

    private struct RawInput: Decodable {
        let description: String?
        let subagentType: String?

        enum CodingKeys: String, CodingKey {
            case description
            case subagentType = "subagent_type"
        }
    }

    private struct RawResultContent: Decodable {
        let text: String?
    }

    /// tool_result content: a block array in most transcripts, a bare string in some.
    private enum RawResultPayload: Decodable {
        case text(String)
        case blocks([RawResultContent])

        var joinedText: String {
            switch self {
            case .text(let string): return string
            case .blocks(let blocks): return blocks.compactMap(\.text).joined(separator: "\n")
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
            } else {
                self = .blocks(try container.decode([RawResultContent].self))
            }
        }
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
                // A real completion outranks the sweep's guess — take its timestamp so the run
                // surfaces in the recent-completion window. The first real end is otherwise kept.
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
